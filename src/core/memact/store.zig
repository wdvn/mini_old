//! store.zig — MemoryStore cho MemAct (RFC-003, M3 §4.4)
//! Long-term memory dạng append-only event log JSONL tại
//! `~/.mini/memory/<project_hash>/memory.jsonl`.
//!
//! ## Trách nhiệm
//! - `append`: ghi 1 memory event (1 dòng JSON) — không rewrite dòng cũ.
//! - `loadIndex`: đọc toàn bộ JSONL rebuild danh sách entries hiện hành;
//!   entry có `supersedes` sẽ THAY THẾ entry bị supersedes trong index
//!   (dòng cũ vẫn nằm trong file — giữ audit trail như event-sourcing).
//! - `touch`: tăng access_count + last_access, rewrite file từ index (v1).
//!
//! ## Keyword matching
//! So khớp ASCII case-insensitive.

const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("../utils.zig");

// ---------------------------------------------------------------------------
// Keyword matching (ASCII case-insensitive)
// ---------------------------------------------------------------------------

/// Kiểm tra keyword có xuất hiện trong text (ASCII case-insensitive).
pub fn matchKeyword(keyword: []const u8, text: []const u8) bool {
    if (keyword.len == 0 or keyword.len > text.len) return false;
    var i: usize = 0;
    while (i + keyword.len <= text.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(text[i .. i + keyword.len], keyword)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// MemoryEntry
// ---------------------------------------------------------------------------

/// Một bản ghi memory (1 dòng JSONL). Mọi slice heap-allocated; free bằng `deinit`.
pub const MemoryEntry = struct {
    /// ID unique, dạng "mem_<hex ts>_<hex counter>_<hex pid>".
    id: []u8,
    /// Epoch milliseconds.
    ts: i64,
    /// "semantic" | "episodic" | "project_state".
    type: []const u8,
    content: []u8,
    keywords: [][]u8,
    source_session: ?[]u8,
    confidence: f32,
    /// ID entry mà entry này thay thế (null nếu không supersedes ai).
    supersedes: ?[]u8,
    access_count: u32,
    last_access: i64,

    pub fn deinit(self: *MemoryEntry, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.type);
        alloc.free(self.content);
        for (self.keywords) |kw| alloc.free(kw);
        alloc.free(self.keywords);
        if (self.source_session) |s| alloc.free(s);
        if (self.supersedes) |s| alloc.free(s);
    }
};

// ---------------------------------------------------------------------------
// MemoryStore
// ---------------------------------------------------------------------------

pub const MemoryStore = struct {
    alloc: Allocator,
    /// Thư mục `~/.mini/memory/<project_hash>/`.
    dir_path: []const u8,
    /// `<dir_path>/memory.jsonl`.
    file_path: []const u8,
    /// Counter sinh id unique trong process.
    id_counter: u32 = 0,

    /// Khởi tạo store tại `dir_path` (kiểu `~/.mini/memory/<project_hash>/`).
    /// Tạo thư mục nếu thiếu. File JSONL tạo lazy ở lần append đầu.
    pub fn init(alloc: Allocator, io: std.Io, dir_path: []const u8) !MemoryStore {
        const dir_dup = try alloc.dupe(u8, dir_path);
        errdefer alloc.free(dir_dup);

        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(io, dir_dup) catch {}; // bỏ qua lỗi đã tồn tại

        const file_path = try std.fs.path.join(alloc, &.{ dir_dup, "memory.jsonl" });
        errdefer alloc.free(file_path);

        return .{
            .alloc = alloc,
            .dir_path = dir_dup,
            .file_path = file_path,
        };
    }

    pub fn deinit(self: *MemoryStore) void {
        self.alloc.free(self.file_path);
        self.alloc.free(self.dir_path);
    }

    /// Sinh id unique: timestamp hex + counter hex + pid hex.
    fn nextId(self: *MemoryStore) ![]u8 {
        return std.fmt.allocPrint(self.alloc, "mem_{x}_{x}_{x}", .{
            utils.milliTimestamp(),
            self.id_counter,
            std.os.linux.getpid(),
        });
    }

    /// Append 1 entry vào `memory.jsonl` (1 dòng JSON, append thuần).
    /// Nếu `entry.id` rỗng → tự sinh id unique và gán lại vào entry.
    pub fn append(self: *MemoryStore, io: std.Io, entry: *MemoryEntry) !void {
        if (entry.id.len == 0) {
            self.id_counter += 1;
            entry.id = try self.nextId();
        }

        // Serialize entry thành 1 dòng JSON
        var out_buf = std.ArrayList(u8).empty;
        var aw = std.Io.Writer.Allocating.fromArrayList(self.alloc, &out_buf);

        try stringifyEntry(&aw.writer, entry);
        try aw.writer.writeByte('\n');

        out_buf = aw.toArrayList();
        defer out_buf.deinit(self.alloc);

        // Mở read_write để append vào cuối file (pattern journal.zig)
        const cwd = std.Io.Dir.cwd();
        const file = cwd.openFile(io, self.file_path, .{ .mode = .read_write }) catch |err| blk: {
            if (err == error.FileNotFound) {
                break :blk try cwd.createFile(io, self.file_path, .{});
            }
            return err;
        };
        defer file.close(io);

        const end_offset = try file.length(io);
        try file.writePositionalAll(io, out_buf.items, end_offset);
        try file.sync(io);
    }

    /// Đọc toàn bộ JSONL, rebuild danh sách entries hiện hành.
    /// Entry có `supersedes != null` sẽ thay thế (loại khỏi index) entry bị
    /// trỏ; entry mới nằm cuối danh sách (thứ tự mới nhất).
    /// Caller sở hữu kết quả — free bằng `freeEntries`.
    pub fn loadIndex(self: *MemoryStore, io: std.Io) ![]MemoryEntry {
        var entries = std.ArrayList(MemoryEntry).empty;
        errdefer freeEntries(self.alloc, entries.items);

        const cwd = std.Io.Dir.cwd();
        const file = cwd.openFile(io, self.file_path, .{}) catch |err| {
            if (err == error.FileNotFound) return &.{};
            return err;
        };
        defer file.close(io);

        const stat = try file.stat(io);
        const buf = try self.alloc.alloc(u8, @intCast(stat.size));
        defer self.alloc.free(buf);
        const n = try utils.readAll(io, file, buf);

        var it = std.mem.splitScalar(u8, buf[0..n], '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0) continue;
            const entry = parseLine(self.alloc, line) catch continue; // dòng hỏng → bỏ
            try self.applySupersedes(&entries, entry);
        }

        return entries.toOwnedSlice(self.alloc);
    }

    /// Entry mới supersedes entry đang có → gỡ entry cũ ra khỏi index, append entry mới.
    fn applySupersedes(self: *MemoryStore, entries: *std.ArrayList(MemoryEntry), entry: MemoryEntry) !void {
        if (entry.supersedes) |target_id| {
            for (entries.items, 0..) |e, i| {
                if (std.mem.eql(u8, e.id, target_id)) {
                    var old = entries.items[i];
                    old.deinit(self.alloc);
                    _ = entries.orderedRemove(i);
                    break;
                }
            }
        }
        try entries.append(self.alloc, entry);
    }

    /// Tăng access_count + last_access của entry `id`, rewrite toàn bộ file
    /// từ index (v1 chấp nhận rewrite toàn file). Trả về false nếu id không có.
    pub fn touch(self: *MemoryStore, io: std.Io, id: []const u8) !bool {
        const entries = try self.loadIndex(io);
        defer freeEntries(self.alloc, entries);

        var found = false;
        for (entries) |*e| {
            if (std.mem.eql(u8, e.id, id)) {
                e.access_count += 1;
                e.last_access = utils.milliTimestamp();
                found = true;
                break;
            }
        }
        if (!found) return false;

        var out_buf = std.ArrayList(u8).empty;
        var aw = std.Io.Writer.Allocating.fromArrayList(self.alloc, &out_buf);

        for (entries) |*e| {
            try stringifyEntry(&aw.writer, e);
            try aw.writer.writeByte('\n');
        }
        out_buf = aw.toArrayList();
        defer out_buf.deinit(self.alloc);

        const cwd = std.Io.Dir.cwd();
        const file = try cwd.createFile(io, self.file_path, .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, out_buf.items);
        try file.sync(io);

        return true;
    }

    /// Giải phóng mảng entries (kèm từng entry bên trong).
    pub fn freeEntries(alloc: Allocator, entries: []MemoryEntry) void {
        for (entries) |*e| e.deinit(alloc);
        alloc.free(entries);
    }

    /// Ghi entry thành 1 JSON object trên 1 dòng (schema RFC-003 §4.4).
    fn stringifyEntry(writer: *std.Io.Writer, entry: *const MemoryEntry) !void {
        try writer.writeAll("{\"id\":");
        try std.json.Stringify.value(entry.id, .{}, writer);
        try writer.writeAll(",\"ts\":");
        try writer.print("{d}", .{entry.ts});
        try writer.writeAll(",\"type\":");
        try std.json.Stringify.value(entry.type, .{}, writer);
        try writer.writeAll(",\"content\":");
        try std.json.Stringify.value(entry.content, .{}, writer);
        try writer.writeAll(",\"keywords\":[");
        for (entry.keywords, 0..) |kw, i| {
            if (i > 0) try writer.writeByte(',');
            try std.json.Stringify.value(kw, .{}, writer);
        }
        try writer.writeAll("],\"source_session\":");
        if (entry.source_session) |s| {
            try std.json.Stringify.value(s, .{}, writer);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"confidence\":");
        try writer.print("{d}", .{entry.confidence});
        try writer.writeAll(",\"supersedes\":");
        if (entry.supersedes) |s| {
            try std.json.Stringify.value(s, .{}, writer);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"access_count\":");
        try writer.print("{d}", .{entry.access_count});
        try writer.writeAll(",\"last_access\":");
        try writer.print("{d}", .{entry.last_access});
        try writer.writeAll("}");
    }
};

/// Parse 1 dòng JSONL thành MemoryEntry (deep-copy, caller sở hữu).
fn parseLine(alloc: Allocator, line: []const u8) !MemoryEntry {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidFormat,
    };

    const id = try alloc.dupe(u8, jsonStr(obj.get("id") orelse return error.MissingField));
    errdefer alloc.free(id);

    const type_str = try alloc.dupe(u8, jsonStr(obj.get("type") orelse return error.MissingField));
    errdefer alloc.free(type_str);

    const content = try alloc.dupe(u8, jsonStr(obj.get("content") orelse return error.MissingField));
    errdefer alloc.free(content);

    const ts = jsonInt(obj.get("ts") orelse return error.MissingField, 0);

    var keywords = std.ArrayList([]u8).empty;
    errdefer {
        for (keywords.items) |kw| alloc.free(kw);
        keywords.deinit(alloc);
    }
    if (obj.get("keywords")) |v| {
        switch (v) {
            .array => |arr| for (arr.items) |item| {
                try keywords.append(alloc, try alloc.dupe(u8, jsonStr(item)));
            },
            else => return error.InvalidFormat,
        }
    }

    const source_session: ?[]u8 = switch (obj.get("source_session") orelse .null) {
        .string => |s| try alloc.dupe(u8, s),
        else => null,
    };

    const confidence: f32 = switch (obj.get("confidence") orelse .null) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => 0.0,
    };

    const supersedes: ?[]u8 = switch (obj.get("supersedes") orelse .null) {
        .string => |s| try alloc.dupe(u8, s),
        else => null,
    };

    const access_count: u32 = @intCast(@max(0, jsonInt(obj.get("access_count") orelse .null, 0)));
    const last_access = jsonInt(obj.get("last_access") orelse .null, 0);

    return .{
        .id = id,
        .ts = ts,
        .type = type_str,
        .content = content,
        .keywords = try keywords.toOwnedSlice(alloc),
        .source_session = source_session,
        .confidence = confidence,
        .supersedes = supersedes,
        .access_count = access_count,
        .last_access = last_access,
    };
}

/// Lấy string từ json.Value (trả rỗng nếu không phải string).
fn jsonStr(v: std.json.Value) []const u8 {
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

/// Lấy integer từ json.Value (trả default nếu không phải number).
fn jsonInt(v: std.json.Value, default: i64) i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => default,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "append → loadIndex round-trip đủ fields" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrint(&buf, "/tmp/mini_memstore_test_{d}", .{std.os.linux.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var store = try MemoryStore.init(alloc, io, dir);
    defer store.deinit();

    var entry = MemoryEntry{
        .id = &.{},
        .ts = 1700000000000,
        .type = "semantic",
        .content = @constCast("Project dùng Zig 0.16, test bằng zig build test"),
        .keywords = @constCast(&[_][]u8{ @constCast("Zig"), @constCast("build") }),
        .source_session = @constCast("sess_test_01"),
        .confidence = 0.9,
        .supersedes = null,
        .access_count = 0,
        .last_access = 0,
    };
    try store.append(io, &entry);
    defer alloc.free(entry.id); // id do store sinh

    const entries = try store.loadIndex(io);
    defer MemoryStore.freeEntries(alloc, entries);

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    const e = entries[0];
    try std.testing.expectEqualStrings(entry.id, e.id);
    try std.testing.expectEqual(entry.ts, e.ts);
    try std.testing.expectEqualStrings("semantic", e.type);
    try std.testing.expectEqualStrings("Project dùng Zig 0.16, test bằng zig build test", e.content);
    try std.testing.expectEqual(@as(usize, 2), e.keywords.len);
    try std.testing.expectEqualStrings("Zig", e.keywords[0]);
    try std.testing.expectEqualStrings("build", e.keywords[1]);
    try std.testing.expectEqualStrings("sess_test_01", e.source_session.?);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), e.confidence, 0.001);
    try std.testing.expect(e.supersedes == null);
    try std.testing.expectEqual(@as(u32, 0), e.access_count);
}

test "supersedes thay thế entry cũ trong index, file giữ audit trail" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrint(&buf, "/tmp/mini_memstore_test_{d}_sup", .{std.os.linux.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var store = try MemoryStore.init(alloc, io, dir);
    defer store.deinit();

    var e1 = MemoryEntry{
        .id = &.{},
        .ts = 1000,
        .type = "project_state",
        .content = @constCast("Branch main"),
        .keywords = @constCast(&[_][]u8{@constCast("branch")}),
        .source_session = null,
        .confidence = 0.8,
        .supersedes = null,
        .access_count = 0,
        .last_access = 0,
    };
    try store.append(io, &e1);
    defer alloc.free(e1.id);

    var e2 = MemoryEntry{
        .id = &.{},
        .ts = 2000,
        .type = "project_state",
        .content = @constCast("Branch feat/memact"),
        .keywords = @constCast(&[_][]u8{@constCast("branch")}),
        .source_session = null,
        .confidence = 0.95,
        .supersedes = e1.id, // thay thế e1
        .access_count = 0,
        .last_access = 0,
    };
    try store.append(io, &e2);
    defer alloc.free(e2.id);

    const entries = try store.loadIndex(io);
    defer MemoryStore.freeEntries(alloc, entries);

    // e1 bị loại khỏi index → chỉ còn e2
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings(e2.id, entries[0].id);
    try std.testing.expectEqualStrings("Branch feat/memact", entries[0].content);
    try std.testing.expectEqualStrings(e1.id, entries[0].supersedes.?);

    // File JSONL vẫn đủ 2 dòng (audit trail không mất)
    try std.testing.expectEqual(@as(usize, 2), try countLines(alloc, io, store.file_path));
}

test "touch tăng access_count và last_access, id lạ trả false" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrint(&buf, "/tmp/mini_memstore_test_{d}_touch", .{std.os.linux.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var store = try MemoryStore.init(alloc, io, dir);
    defer store.deinit();

    var entry = MemoryEntry{
        .id = &.{},
        .ts = 1000,
        .type = "episodic",
        .content = @constCast("Session fix leak trong ollama streaming"),
        .keywords = @constCast(&[_][]u8{@constCast("ollama")}),
        .source_session = @constCast("sess_t"),
        .confidence = 0.7,
        .supersedes = null,
        .access_count = 0,
        .last_access = 0,
    };
    try store.append(io, &entry);
    defer alloc.free(entry.id);

    try std.testing.expect(try store.touch(io, entry.id));
    try std.testing.expect(try store.touch(io, entry.id));
    try std.testing.expect(!(try store.touch(io, "mem_khong_ton_tai")));

    const entries = try store.loadIndex(io);
    defer MemoryStore.freeEntries(alloc, entries);

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(@as(u32, 2), entries[0].access_count);
    try std.testing.expect(entries[0].last_access > 0);
}

test "2 append → file JSONL có đúng 2 dòng" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrint(&buf, "/tmp/mini_memstore_test_{d}_jsonl", .{std.os.linux.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var store = try MemoryStore.init(alloc, io, dir);
    defer store.deinit();

    const contents = [_][]const u8{ "entry thứ nhất", "entry thứ hai" };
    var owned_ids: [2][]u8 = undefined;
    for (contents, 0..) |c, i| {
        var entry = MemoryEntry{
            .id = &.{},
            .ts = 1000 + @as(i64, @intCast(i)),
            .type = "semantic",
            .content = @constCast(c),
            .keywords = @constCast(&[_][]u8{@constCast("kw")}),
            .source_session = null,
            .confidence = 0.5,
            .supersedes = null,
            .access_count = 0,
            .last_access = 0,
        };
        try store.append(io, &entry);
        owned_ids[i] = entry.id;
    }
    defer alloc.free(owned_ids[0]);
    defer alloc.free(owned_ids[1]);

    try std.testing.expectEqual(@as(usize, 2), try countLines(alloc, io, store.file_path));
}

test "matchKeyword ASCII case-insensitive" {
    try std.testing.expect(matchKeyword("zig", "Project dùng Zig build"));
    try std.testing.expect(matchKeyword("ZIG", "project zig 0.16"));
    try std.testing.expect(matchKeyword("Build", "zig BUILD test"));
    try std.testing.expect(!matchKeyword("rust", "Dùng Zig build"));
    try std.testing.expect(!matchKeyword("", "abc"));
    try std.testing.expect(!matchKeyword("toolong", "abc"));
}

/// Đếm số dòng không rỗng trong file (helper cho tests).
fn countLines(alloc: Allocator, io: std.Io, path: []const u8) !usize {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    const buf = try alloc.alloc(u8, @intCast(stat.size));
    defer alloc.free(buf);
    const n = try utils.readAll(io, file, buf);

    var count: usize = 0;
    var it = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (it.next()) |l| {
        if (std.mem.trim(u8, l, " \r").len > 0) count += 1;
    }
    return count;
}
