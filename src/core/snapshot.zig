//! snapshot.zig — SnapshotTracker: CAS snapshot trước/sau khi file bị thay đổi.
//!
//! Mở rộng coverage của RFC-002: mọi đường ghi file (tool file_write/file_edit,
//! mini.write/mini.patch trong QuickJS, bash command chứa redirect, subagent)
//! đều lưu nội dung cũ vào CAS (~/.mini/cas) và ghi FileSnapshot vào journal.
//!
//! Toàn cục singleton vì js_bindings (QuickJS C-ABI) không giữ con trỏ AgentLoop.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cas_mod = @import("cas.zig");
const journal_mod = @import("journal.zig");

/// Tracker toàn cục. Null = no-op (test, chế độ không journal).
var g_tracker: ?*SnapshotTracker = null;

/// Gắn tracker toàn cục (agent.zig gọi lúc init).
pub fn setTracker(t: ?*SnapshotTracker) void {
    g_tracker = t;
}

pub fn getTracker() ?*SnapshotTracker {
    return g_tracker;
}

/// 1 file đã được snapshot trong tracker.
pub const TrackedFile = struct {
    path: []const u8,
    /// Hash nội dung TRƯỚC thay đổi. Null nếu file chưa tồn tại.
    previous_content_hash: ?[]const u8 = null,
};

pub const SnapshotTracker = struct {
    alloc: Allocator,
    io: std.Io,
    cas: *cas_mod.CAS,
    /// Journal ghi act_completed + StateDelta. Null = chỉ CAS, không journal.
    journal: ?*journal_mod.ActJournal,
    /// Danh sách file đang track trong act hiện tại.
    tracked: std.ArrayListUnmanaged(TrackedFile),
    /// Kích thước file tối đa snapshot (32MB).
    max_snapshot_size: usize = 32 * 1024 * 1024,

    pub fn init(alloc: Allocator, io: std.Io, cas: *cas_mod.CAS, journal: ?*journal_mod.ActJournal) SnapshotTracker {
        return .{
            .alloc = alloc,
            .io = io,
            .cas = cas,
            .journal = journal,
            .tracked = .empty,
        };
    }

    pub fn deinit(self: *SnapshotTracker) void {
        self.reset();
        self.tracked.deinit(self.alloc);
    }

    /// Xóa danh sách track (cuối act, sau khi đã flush).
    pub fn reset(self: *SnapshotTracker) void {
        for (self.tracked.items) |tf| {
            self.alloc.free(tf.path);
            if (tf.previous_content_hash) |h| self.alloc.free(h);
        }
        self.tracked.clearRetainingCapacity();
    }

    fn findByPath(self: *SnapshotTracker, path: []const u8) ?usize {
        for (self.tracked.items, 0..) |tf, i| {
            if (std.mem.eql(u8, tf.path, path)) return i;
        }
        return null;
    }

    /// Đọc nội dung file hiện tại vào buffer (null nếu không tồn tại / quá lớn).
    fn readFileContent(self: *SnapshotTracker, path: []const u8) ?[]u8 {
        const cwd = std.Io.Dir.cwd();
        const file = cwd.openFile(self.io, path, .{}) catch return null;
        defer file.close(self.io);
        const stat = file.stat(self.io) catch return null;
        if (stat.size > self.max_snapshot_size) return null;
        const buf = self.alloc.alloc(u8, @intCast(stat.size)) catch return null;
        const n = readAllFile(self.io, file, buf) catch {
            self.alloc.free(buf);
            return null;
        };
        return buf[0..n];
    }

    /// Gọi TRƯỚC khi file sắp bị thay đổi. CAS-store nội dung cũ.
    /// Idempotent: path đã track thì bỏ qua (giữ hash cũ nhất).
    pub fn beforeFileWrite(self: *SnapshotTracker, path: []const u8) void {
        if (self.findByPath(path) != null) return;
        var prev_hash: ?[]u8 = null;
        if (self.readFileContent(path)) |content| {
            defer self.alloc.free(content);
            if (self.cas.store(self.io, content)) |h| {
                prev_hash = h;
            } else |_| {}
        }
        const path_dup = self.alloc.dupe(u8, path) catch {
            if (prev_hash) |h| self.alloc.free(h);
            return;
        };
        self.tracked.append(self.alloc, .{ .path = path_dup, .previous_content_hash = prev_hash }) catch {
            self.alloc.free(path_dup);
            if (prev_hash) |h| self.alloc.free(h);
        };
    }

    /// Gọi SAU khi file đã thay đổi. Flush snapshots đã thu vào journal
    /// (chỉ những file thực sự đổi hash so với previous). Trả về số snapshot ghi.
    pub fn afterFileWrite(self: *SnapshotTracker, act_id: usize, path: []const u8) void {
        // Không flush ngay — agent flush toàn bộ cuối act với act_id thật (tránh event trùng).
        _ = act_id;
        _ = self;
        _ = path;
    }

    /// Ghi toàn bộ snapshots đang track vào journal (1 event act_completed phụ).
    pub fn flush(self: *SnapshotTracker, act_id: usize) void {
        const j = self.journal orelse return;
        if (self.tracked.items.len == 0) return;

        var snaps: []journal_mod.FileSnapshot = self.alloc.alloc(journal_mod.FileSnapshot, self.tracked.items.len) catch return;
        defer self.alloc.free(snaps);
        var n: usize = 0;
        for (self.tracked.items) |tf| {
            snaps[n] = .{
                .path = tf.path,
                .previous_content_hash = tf.previous_content_hash,
            };
            n += 1;
        }
        j.recordActComplete(self.io, act_id, .{
            .act_id = act_id,
            .file_snapshots = snaps[0..n],
        }) catch {};
    }
};

// Helper: đọc toàn bộ file (tránh circular import utils — dùng std trực tiếp).
fn readAllFile(io: std.Io, file: std.Io.File, buf: []u8) !usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try file.readStreaming(io, &.{buf[total..]});
        if (n == 0) break;
        total += n;
    }
    return total;
}

// ---------------------------------------------------------------------------
// Bash command path extraction
// ---------------------------------------------------------------------------

/// Token có vẻ là path không? (chứa '/', hoặc có extension, hoặc tồn tại trên disk).
/// Heuristic, chỉ dùng để quyết định có đáng snapshot không.
fn looksLikePath(token: []const u8) bool {
    if (token.len == 0 or token.len > 4096) return false;
    if (std.mem.indexOfScalar(u8, token, '/') != null) return true;
    // file.ext (không phải option/flag)
    if (token[0] == '-') return false;
    if (std.mem.lastIndexOfScalar(u8, token, '.')) |dot| {
        return dot > 0 and dot < token.len - 1;
    }
    return false;
}

/// Các pattern lệnh ghi file. Token sau pattern là path đích.
const WRITE_VERBS = [_][]const u8{
    "sed -i",
    "> ",
    ">> ",
    "tee ",
    "tee -a ",
    "mv ",
    "cp ",
    "rm ",
    "touch ",
    "truncate ",
    "chmod ",
    "chown ",
    "install ",
    "g++ ",
    "gcc ",
    "-o ",
    "zig build",
    "cargo build",
    "npm install",
    "git checkout",
    "git restore",
    "git stash",
};

/// Bóc các path có nguy cơ bị bash command thay đổi.
/// Trả về slice được cấp phát từ arena — caller không cần free riêng từng phần.
pub fn extractWritablePaths(arena: std.mem.Allocator, command: []const u8) ![][]const u8 {
    var paths = std.ArrayListUnmanaged([]const u8).empty;

    var lines = std.mem.splitScalar(u8, command, '\n');
    while (lines.next()) |line| {
        // Tách theo '&&', ';', '|'
        var segs = std.mem.tokenizeAny(u8, line, "&;|");
        while (segs.next()) |seg_raw| {
            const seg = std.mem.trim(u8, seg_raw, " \t");
            if (seg.len == 0) continue;

            // 1. Redirect: > file, >> file, 2> file
            if (std.mem.indexOf(u8, seg, ">")) |gt| {
                // bỏ qua 2> / &>
                var i = gt;
                while (i < seg.len and seg[i] == '>') i += 1;
                const rest = std.mem.trim(u8, seg[i..], " \t");
                var tok = std.mem.tokenizeAny(u8, rest, " \t");
                if (tok.next()) |target| {
                    const cleaned = stripQuotes(target);
                    if (looksLikePath(cleaned) and !isDevNull(cleaned)) {
                        try appendUnique(arena, &paths, cleaned);
                    }
                }
            }

            // 2. tee <file>
            if (std.mem.indexOf(u8, seg, "tee ") != null or std.mem.indexOf(u8, seg, "tee\t") != null) {
                var tok = std.mem.tokenizeAny(u8, seg, " \t");
                while (tok.next()) |t| {
                    if (std.mem.eql(u8, t, "tee") or std.mem.eql(u8, t, "-a") or std.mem.eql(u8, t, "-i")) continue;
                    if (t.len > 0 and t[0] == '-') continue;
                    const cleaned = stripQuotes(t);
                    if (looksLikePath(cleaned) and !isDevNull(cleaned)) {
                        try appendUnique(arena, &paths, cleaned);
                        break;
                    }
                }
            }

            // 3. Verb + path arguments: mv/cp/rm/touch/sed -i...
            for (WRITE_VERBS) |verb| {
                if (std.mem.indexOf(u8, seg, verb)) |_| {
                    // Lấy các token sau verb
                    const after = seg[std.mem.indexOf(u8, seg, verb).? + verb.len ..];
                    var tok = std.mem.tokenizeAny(u8, after, " \t");
                    var count: usize = 0;
                    while (tok.next()) |t| {
                        defer count += 1;
                        if (t.len == 0 or t[0] == '-') continue;
                        const cleaned = stripQuotes(t);
                        if (isDevNull(cleaned)) continue;
                        // Với mv/cp: bỏ source đầu (count 0 là src), đích là count 1
                        if ((std.mem.startsWith(u8, verb, "mv ") or std.mem.startsWith(u8, verb, "cp ")) and count == 0) continue;
                        if (looksLikePath(cleaned) or std.mem.indexOfScalar(u8, cleaned, '/') != null) {
                            try appendUnique(arena, &paths, cleaned);
                        }
                    }
                    break; // 1 verb match đủ cho segment này
                }
            }
        }
    }
    return paths.toOwnedSlice(arena);
}

fn isDevNull(p: []const u8) bool {
    return std.mem.eql(u8, p, "/dev/null") or std.mem.eql(u8, p, "2>") or std.mem.eql(u8, p, "&>");
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and ((s[0] == '"' and s[s.len - 1] == '"') or (s[0] == '\'' and s[s.len - 1] == '\''))) {
        return s[1 .. s.len - 1];
    }
    return s;
}

fn appendUnique(arena: std.mem.Allocator, list: *std.ArrayListUnmanaged([]const u8), s: []const u8) !void {
    for (list.items) |item| {
        if (std.mem.eql(u8, item, s)) return;
    }
    try list.append(arena, try arena.dupe(u8, s));
}

test "extractWritablePaths redirect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paths = try extractWritablePaths(arena.allocator(), "echo hi > /tmp/out.txt && cat x >> log/run.log");
    try std.testing.expectEqual(@as(usize, 2), paths.len);
    try std.testing.expectEqualStrings("/tmp/out.txt", paths[0]);
    try std.testing.expectEqualStrings("log/run.log", paths[1]);
}

test "extractWritablePaths mv cp rm" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paths = try extractWritablePaths(arena.allocator(), "mv src/a.txt dst/b.txt; cp orig.txt backup.txt; rm -f junk");
    var found_mv = false;
    var found_cp = false;
    for (paths) |p| {
        if (std.mem.eql(u8, p, "dst/b.txt")) found_mv = true;
        if (std.mem.eql(u8, p, "backup.txt")) found_cp = true;
    }
    try std.testing.expect(found_mv);
    try std.testing.expect(found_cp);
}

test "extractWritablePaths ignores /dev/null và echo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paths = try extractWritablePaths(arena.allocator(), "echo x > /dev/null");
    try std.testing.expectEqual(@as(usize, 0), paths.len);
}
