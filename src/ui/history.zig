//! history.zig — Persistent prompt input history (RFC-000 nhóm 5).
//!
//! Ring in-memory (max 500 mục) + lưu JSONL tại <MINI_HOME>/history.jsonl
//! (mặc định ~/.mini/history.jsonl). Đây là **prompt input history** — những
//! gì user gõ vào composer, không phải conversation history (RFC-003).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const MAX_ENTRIES = 500;

pub const PromptHistory = struct {
    alloc: Allocator,
    entries: std.ArrayListUnmanaged([]const u8),
    dirty: bool,

    pub fn init(alloc: Allocator) PromptHistory {
        return .{ .alloc = alloc, .entries = .empty, .dirty = false };
    }

    pub fn deinit(self: *PromptHistory) void {
        for (self.entries.items) |e| self.alloc.free(e);
        self.entries.deinit(self.alloc);
    }

    /// Thêm entry (dedupe với entry liền trước, bỏ empty).
    pub fn add(self: *PromptHistory, line: []const u8) !void {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) return;
        if (self.entries.items.len > 0) {
            const last = self.entries.items[self.entries.items.len - 1];
            if (std.mem.eql(u8, last, trimmed)) return;
        }
        // Dedupe toàn cục: nếu đã có entry giống hệt thì xóa entry cũ, đưa lên cuối
        var i: usize = 0;
        while (i < self.entries.items.len) : (i += 1) {
            if (std.mem.eql(u8, self.entries.items[i], trimmed)) {
                const old = self.entries.orderedRemove(i);
                self.alloc.free(old);
                break;
            }
        }
        const dup = try self.alloc.dupe(u8, trimmed);
        errdefer self.alloc.free(dup);
        try self.entries.append(self.alloc, dup);
        // Cap ring
        while (self.entries.items.len > MAX_ENTRIES) {
            const old = self.entries.orderedRemove(0);
            self.alloc.free(old);
        }
        self.dirty = true;
    }

    /// Load từ file JSONL (mỗi dòng 1 JSON string escaped). Bỏ qua dòng lỗi.
    pub fn loadFromFile(self: *PromptHistory, io: std.Io, path: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        const f = cwd.openFile(io, path, .{}) catch return;
        defer f.close(io);
        const stat = try f.stat(io);
        const buf = try self.alloc.alloc(u8, @intCast(stat.size));
        defer self.alloc.free(buf);
        var got: usize = 0;
        while (got < buf.len) {
            const n = f.readStreaming(io, &.{buf[got..]}) catch break;
            if (n == 0) break;
            got += n;
        }
        var it = std.mem.splitScalar(u8, buf[0..got], '\n');
        while (it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \r");
            if (line.len < 2 or line[0] != '"') continue;
            const decoded = decodeJsonString(self.alloc, line[1 .. line.len - 1]) catch continue;
            defer self.alloc.free(decoded);
            self.add(decoded) catch {};
        }
        self.dirty = false;
    }

    /// Append các entry mới vào file JSONL. Chỉ ghi khi dirty.
    pub fn saveToFile(self: *PromptHistory, io: std.Io, path: []const u8) !void {
        if (!self.dirty) return;
        const cwd = std.Io.Dir.cwd();
        if (std.fs.path.dirname(path)) |dir| {
            cwd.createDirPath(io, dir) catch {};
        }
        // Ghi đè toàn bộ (đơn giản, đúng sau dedupe)
        const f = try cwd.createFile(io, path, .{ .truncate = true });
        defer f.close(io);
        var buf: [4096]u8 = undefined;
        var w = f.writer(io, &buf);
        for (self.entries.items) |e| {
            w.interface.writeByte('"') catch break;
            for (e) |c| {
                switch (c) {
                    '"' => w.interface.writeAll("\\\"") catch break,
                    '\\' => w.interface.writeAll("\\\\") catch break,
                    '\n' => w.interface.writeAll("\\n") catch break,
                    '\r' => w.interface.writeAll("\\r") catch break,
                    '\t' => w.interface.writeAll("\\t") catch break,
                    else => {
                        if (c < 0x20) {
                            w.interface.print("\\u{x:0>4}", .{c}) catch break;
                        } else {
                            w.interface.writeByte(c) catch break;
                        }
                    },
                }
            }
            w.interface.writeAll("\"\n") catch break;
        }
        try w.interface.flush();
        self.dirty = false;
    }

    pub fn len(self: *const PromptHistory) usize {
        return self.entries.items.len;
    }

    pub fn get(self: *const PromptHistory, i: usize) ?[]const u8 {
        if (i >= self.entries.items.len) return null;
        return self.entries.items[i];
    }
};

/// Decode JSON string body (không có quote bao) đơn giản.
fn decodeJsonString(alloc: Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            switch (s[i]) {
                'n' => try out.append(alloc, '\n'),
                'r' => try out.append(alloc, '\r'),
                't' => try out.append(alloc, '\t'),
                '"' => try out.append(alloc, '"'),
                '\\' => try out.append(alloc, '\\'),
                '/' => try out.append(alloc, '/'),
                'u' => {
                    if (i + 4 >= s.len) return error.Invalid;
                    const hex = s[i + 1 .. i + 5];
                    const cp = try std.fmt.parseInt(u21, hex, 16);
                    var tmp: [4]u8 = undefined;
                    const n = try std.unicode.utf8Encode(cp, &tmp);
                    try out.appendSlice(alloc, tmp[0..n]);
                    i += 4;
                },
                else => return error.Invalid,
            }
            i += 1;
        } else {
            try out.append(alloc, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Đường dẫn file history: <MINI_HOME>/history.jsonl (MINI_HOME đã là thư mục .mini),
/// fallback ~/.mini/history.jsonl — nhất quán với artifacts.zig / main.zig.
pub fn resolveHistoryPath(alloc: Allocator, io: std.Io, env_map: *const std.process.Environ.Map) ![]u8 {
    _ = io;
    if (env_map.get("MINI_HOME")) |mh| {
        if (mh.len > 0) return std.fmt.allocPrint(alloc, "{s}/history.jsonl", .{mh});
    }
    if (env_map.get("HOME")) |home| {
        if (home.len > 0) return std.fmt.allocPrint(alloc, "{s}/.mini/history.jsonl", .{home});
    }
    return alloc.dupe(u8, ".mini/history.jsonl");
}

test "add + dedupe" {
    var h = PromptHistory.init(std.testing.allocator);
    defer h.deinit();
    try h.add("abc");
    try h.add("abc"); // dedupe
    try h.add("xyz");
    try std.testing.expectEqual(@as(usize, 2), h.len());
}

test "multiline entry" {
    var h = PromptHistory.init(std.testing.allocator);
    defer h.deinit();
    try h.add("line1\nline2");
    try std.testing.expectEqualStrings("line1\nline2", h.get(0).?);
}

test "resolveHistoryPath: MINI_HOME không double-nest" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("MINI_HOME", "/tmp/minihome");
    const p = try resolveHistoryPath(alloc, io, &env);
    defer alloc.free(p);
    try std.testing.expectEqualStrings("/tmp/minihome/history.jsonl", p);
}
