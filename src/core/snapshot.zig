//! snapshot.zig — SnapshotTracker: CAS snapshot before/after file modifications.
//!
//! Extends coverage of RFC-002: all file-write pathways (tool file_write/file_edit,
//! mini.write/mini.patch in CodeAct, bash command with redirects, subagents)
//! save old contents to CAS (~/.mini/cas) and record FileSnapshot to the journal.
//!
//! Global singleton because js_bindings (CodeAct C-ABI) does not hold an AgentLoop pointer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cas_mod = @import("cas.zig");
const journal_mod = @import("journal.zig");

/// Global tracker. Null = no-op (test, non-journal mode).
var g_tracker: ?*SnapshotTracker = null;

/// Attach global tracker (called by agent.zig during init).
pub fn setTracker(t: ?*SnapshotTracker) void {
    g_tracker = t;
}

pub fn getTracker() ?*SnapshotTracker {
    return g_tracker;
}

/// A single file snapshot tracked in the tracker.
pub const TrackedFile = struct {
    path: []const u8,
    /// Hash of content BEFORE modification. Null if file did not exist.
    previous_content_hash: ?[]const u8 = null,
};

pub const SnapshotTracker = struct {
    alloc: Allocator,
    io: std.Io,
    cas: *cas_mod.CAS,
    /// Journal recording act_completed + StateDelta. Null = CAS only, no journal.
    journal: ?*journal_mod.ActJournal,
    /// List of files being tracked in the current act.
    tracked: std.ArrayListUnmanaged(TrackedFile),
    /// Maximum file size to snapshot (32MB).
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

    /// Clear tracked files list (end of act, after flush).
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

    /// Read current file content into buffer (null if non-existent / too large).
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

    /// Called BEFORE file is modified. CAS-stores previous content.
    /// Idempotent: already tracked paths are ignored (preserving oldest hash).
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

    /// Called AFTER file has been modified. Flush collected snapshots to journal
    /// (only files that actually changed hash compared to previous). Returns count of written snapshots.
    pub fn afterFileWrite(self: *SnapshotTracker, act_id: usize, path: []const u8) void {
        // Do not flush immediately — agent flushes all at the end of act with the real act_id (avoids duplicate events).
        _ = act_id;
        _ = self;
        _ = path;
    }

    /// Flush all tracked snapshots to journal (1 secondary act_completed event).
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

// Helper: read entire file (avoids circular import utils — uses std directly).
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

/// Does token look like a path? (contains '/', has extension, or exists on disk).
/// Heuristic, used only to decide if worth snapshotting.
fn looksLikePath(token: []const u8) bool {
    if (token.len == 0 or token.len > 4096) return false;
    if (std.mem.indexOfScalar(u8, token, '/') != null) return true;
    // file.ext (not option/flag)
    if (token[0] == '-') return false;
    if (std.mem.lastIndexOfScalar(u8, token, '.')) |dot| {
        return dot > 0 and dot < token.len - 1;
    }
    return false;
}

/// Write-command patterns. Token following pattern is target path.
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

fn extractRedirectPath(arena: Allocator, paths: *std.ArrayListUnmanaged([]const u8), seg: []const u8) !void {
    // PSEUDOCODE:
    // 1. Locate '>' character in segment.
    // 2. Skip consecutive '>' chars (e.g. '>>').
    // 3. Extract target token, strip quotes, and append if valid path.
    const gt = std.mem.indexOf(u8, seg, ">") orelse return;
    var i = gt;
    while (i < seg.len and seg[i] == '>') i += 1;
    const rest = std.mem.trim(u8, seg[i..], " \t");
    var tok = std.mem.tokenizeAny(u8, rest, " \t");
    if (tok.next()) |target| {
        const cleaned = stripQuotes(target);
        if (looksLikePath(cleaned) and !isDevNull(cleaned)) {
            try appendUnique(arena, paths, cleaned);
        }
    }
}

fn extractTeePaths(arena: Allocator, paths: *std.ArrayListUnmanaged([]const u8), seg: []const u8) !void {
    // PSEUDOCODE:
    // 1. Check if segment contains "tee ".
    // 2. Tokenize and extract target files, ignoring options like -a, -i.
    if (std.mem.indexOf(u8, seg, "tee ") == null and std.mem.indexOf(u8, seg, "tee\t") == null) return;
    var tok = std.mem.tokenizeAny(u8, seg, " \t");
    while (tok.next()) |t| {
        if (std.mem.eql(u8, t, "tee") or std.mem.eql(u8, t, "-a") or std.mem.eql(u8, t, "-i")) continue;
        if (t.len > 0 and t[0] == '-') continue;
        const cleaned = stripQuotes(t);
        if (looksLikePath(cleaned) and !isDevNull(cleaned)) {
            try appendUnique(arena, paths, cleaned);
            break;
        }
    }
}

fn extractVerbPaths(arena: Allocator, paths: *std.ArrayListUnmanaged([]const u8), seg: []const u8) !void {
    // PSEUDOCODE:
    // 1. Check against WRITE_VERBS.
    // 2. Tokenize tokens after verb; for mv/cp skip source file (count 0).
    // 3. Append valid paths.
    for (WRITE_VERBS) |verb| {
        const idx = std.mem.indexOf(u8, seg, verb) orelse continue;
        const after = seg[idx + verb.len ..];
        var tok = std.mem.tokenizeAny(u8, after, " \t");
        var count: usize = 0;
        while (tok.next()) |t| {
            defer count += 1;
            if (t.len == 0 or t[0] == '-') continue;
            const cleaned = stripQuotes(t);
            if (isDevNull(cleaned)) continue;
            if ((std.mem.startsWith(u8, verb, "mv ") or std.mem.startsWith(u8, verb, "cp ")) and count == 0) continue;
            if (looksLikePath(cleaned) or std.mem.indexOfScalar(u8, cleaned, '/') != null) {
                try appendUnique(arena, paths, cleaned);
            }
        }
        break;
    }
}

/// Extract paths at risk of being modified by bash command.
/// Returns slice allocated from arena — caller does not need to free elements individually.
pub fn extractWritablePaths(arena: std.mem.Allocator, command: []const u8) ![][]const u8 {
    // PSEUDOCODE:
    // 1. Split command into lines and segments by delimiters (&, ;, |).
    // 2. Extract paths from redirections (>), tee, and write verbs.
    // 3. Return unique paths as owned slice.
    var paths = std.ArrayListUnmanaged([]const u8).empty;

    var lines = std.mem.splitScalar(u8, command, '\n');
    while (lines.next()) |line| {
        var segs = std.mem.tokenizeAny(u8, line, "&;|");
        while (segs.next()) |seg_raw| {
            const seg = std.mem.trim(u8, seg_raw, " \t");
            if (seg.len == 0) continue;

            try extractRedirectPath(arena, &paths, seg);
            try extractTeePaths(arena, &paths, seg);
            try extractVerbPaths(arena, &paths, seg);
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

test "extractWritablePaths ignores /dev/null and echo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paths = try extractWritablePaths(arena.allocator(), "echo x > /dev/null");
    try std.testing.expectEqual(@as(usize, 0), paths.len);
}
