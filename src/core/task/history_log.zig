//! core/task/history_log.zig — Per-task durable history log (RFC-030).
//!
//! Append-only `history.jsonl` per task directory. Two line shapes:
//! - `snapshot`: full serialized history baseline (written on MemAct compaction)
//! - `delta`: messages appended since the previous line (act boundary)
//!
//! Restore = last snapshot + all subsequent deltas → history byte-identical to
//! the in-memory state at the last completed act boundary (full-context resume).
//! A torn last line (crash mid-write) is detected via JSON parse failure and
//! truncated on init.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const utils = @import("../utils.zig");
const proto = @import("../protocol.zig");
const history_mod = @import("../history.zig");
const History = history_mod.History;

/// One history-log line (owned strings after parse; see `deinit`).
pub const HistoryLine = struct {
    line_type: types.HistoryLineType,
    /// Monotonically increasing sequence number.
    seq: u64,
    /// For delta lines: the appended messages.
    messages: []proto.Message = &.{},
    /// For snapshot lines: full message array.
    snapshot_messages: []proto.Message = &.{},

    pub fn deinit(self: *HistoryLine, alloc: Allocator) void {
        for (self.messages) |msg| History.freeContentBlocks(alloc, @constCast(msg.content));
        if (self.messages.len > 0) alloc.free(self.messages);
        if (self.snapshot_messages.ptr != self.messages.ptr) {
            for (self.snapshot_messages) |msg| History.freeContentBlocks(alloc, @constCast(msg.content));
            if (self.snapshot_messages.len > 0) alloc.free(self.snapshot_messages);
        }
    }
};

/// Per-task history log writer/reader bound to one task directory.
pub const HistoryLog = struct {
    alloc: Allocator,
    /// Absolute path of history.jsonl (owned).
    file_path: []u8,
    /// Absolute path of the task directory (owned).
    task_dir: []u8,
    /// Number of lines written so far.
    seq: u64 = 0,

    /// Initializes the log under `base_dir/<task_id>/`, creating directories
    /// and truncating a torn last line if present.
    pub fn init(alloc: Allocator, io: std.Io, base_dir: []const u8, task_id: []const u8) !HistoryLog {
        // PSEUDOCODE:
        // 1. Create task dir <base_dir>/<task_id>
        // 2. Join history.jsonl path
        // 3. If file exists with content, validate last line; truncate torn tail
        const task_dir = try std.fs.path.join(alloc, &.{ base_dir, task_id });
        errdefer alloc.free(task_dir);
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(io, task_dir) catch {};
        const file_path = try std.fs.path.join(alloc, &.{ task_dir, "history.jsonl" });
        errdefer alloc.free(file_path);

        var log = HistoryLog{ .alloc = alloc, .file_path = file_path, .task_dir = task_dir };
        // Create empty file if missing (append path expects it to exist).
        if (cwd.openFile(io, file_path, .{})) |f| {
            f.close(io);
        } else |err| {
            if (err == error.FileNotFound) {
                const f = try cwd.createFile(io, file_path, .{});
                f.close(io);
            } else {
                return err;
            }
        }
        log.seq = countLines(alloc, io, file_path);
        try truncateTornTail(io, file_path);
        return log;
    }

    pub fn deinit(self: *HistoryLog) void {
        self.alloc.free(self.file_path);
        self.alloc.free(self.task_dir);
    }

    /// Appends a delta line with the given messages.
    pub fn appendDelta(self: *HistoryLog, io: std.Io, msgs: []const proto.Message) !void {
        // PSEUDOCODE:
        // 1. Serialize {"type":"delta","seq":n,"messages":[...]}
        // 2. Append one line to history.jsonl
        self.seq += 1;
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.alloc);
        var aw = std.Io.Writer.Allocating.fromArrayList(self.alloc, &buf);
        try std.json.Stringify.value(msgs, .{}, &aw.writer);
        buf = aw.toArrayList();

        const line = try std.fmt.allocPrint(self.alloc, "{{\"type\":\"delta\",\"seq\":{d},\"messages\":{s}}}\n", .{ self.seq, buf.items });
        defer self.alloc.free(line);
        try appendBytes(io, self.file_path, line);
    }

    /// Writes a snapshot line pinning the full current history.
    /// Writes a snapshot line pinning the given messages (full baseline).
    pub fn writeSnapshot(self: *HistoryLog, io: std.Io, msgs: []const proto.Message) !void {
        self.seq += 1;
        var msg_buf = std.ArrayList(u8).empty;
        defer msg_buf.deinit(self.alloc);
        var aw = std.Io.Writer.Allocating.fromArrayList(self.alloc, &msg_buf);
        try std.json.Stringify.value(msgs, .{}, &aw.writer);
        msg_buf = aw.toArrayList();

        const line = try std.fmt.allocPrint(self.alloc, "{{\"type\":\"snapshot\",\"seq\":{d},\"messages\":{s}}}\n", .{ self.seq, msg_buf.items });
        defer self.alloc.free(line);
        try appendBytes(io, self.file_path, line);
    }

    /// Restores the full history (last snapshot + deltas) into `history`.
    pub fn restoreInto(self: *HistoryLog, io: std.Io, history: *History) !void {
        const content = try readFileAlloc(self.alloc, io, self.file_path);
        defer self.alloc.free(content);
        try applyLogContent(self.alloc, content, history);
    }

    /// Static restore: builds a fresh History from the task log.
    /// Caller owns the returned History struct allocation and its messages;
    /// free via `alloc.destroy` + `History.deinit` (see `freeRestored`).
    pub fn restoreHistory(alloc: Allocator, io: std.Io, base_dir: []const u8, task_id: []const u8) !*History {
        const task_dir = try std.fs.path.join(alloc, &.{ base_dir, task_id });
        defer alloc.free(task_dir);
        const file_path = try std.fs.path.join(alloc, &.{ task_dir, "history.jsonl" });
        defer alloc.free(file_path);
        const content = try readFileAlloc(alloc, io, file_path);
        defer alloc.free(content);
        const history = try alloc.create(History);
        errdefer alloc.destroy(history);
        history.* = History.init(alloc);
        try applyLogContent(alloc, content, history);
        return history;
    }

    /// Frees a History returned by `restoreHistory` (struct + messages).
    pub fn freeRestored(alloc: Allocator, history: *History) void {
        history.deinit();
        alloc.destroy(history);
    }
};

// ---------------------------------------------------------------------------
// Line-level helpers (shared by instance & static paths)
// ---------------------------------------------------------------------------

fn readFileAlloc(alloc: Allocator, io: std.Io, file_path: []const u8) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    const f = try cwd.openFile(io, file_path, .{});
    defer f.close(io);
    const stat_size = try f.length(io);
    const buf = try alloc.alloc(u8, @intCast(stat_size));
    errdefer alloc.free(buf);
    const n = try utils.readAll(io, f, buf);
    return buf[0..n];
}

fn applyLogContent(alloc: Allocator, content: []const u8, history: *History) !void {
    // PSEUDOCODE:
    // 1. Parse each line as JSON
    // 2. snapshot line → clear history, load snapshot messages
    // 3. delta line → append messages
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const parsed = std.json.parseFromSlice(HistoryLinePayload, alloc, trimmed, .{
            .ignore_unknown_fields = true,
        }) catch continue; // torn/garbled interior lines are skipped
        defer parsed.deinit();
        switch (parsed.value.lineType()) {
            .snapshot => {
                history.clear();
                for (parsed.value.messages) |msg| {
                    try appendCloned(alloc, history, msg);
                }
            },
            .delta => {
                for (parsed.value.messages) |msg| {
                    try appendCloned(alloc, history, msg);
                }
            },
        }
    }
}

/// Internal wire format: `type` is a string, `messages` an array of proto.Message.
const HistoryLinePayload = struct {
    type: []const u8 = "",
    seq: u64 = 0,
    messages: []proto.Message = &.{},

    fn lineType(self: *const HistoryLinePayload) types.HistoryLineType {
        return types.HistoryLineType.fromJson(self.type) orelse .delta;
    }
};

fn appendCloned(alloc: Allocator, history: *History, msg: proto.Message) !void {
    const content_copy = try History.cloneContent(alloc, msg.content);
    try history.msgs.append(alloc, .{
        .role = msg.role,
        .content = content_copy,
        .tier = msg.tier,
    });
}

fn appendBytes(io: std.Io, file_path: []const u8, bytes: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const f = try cwd.openFile(io, file_path, .{ .mode = .read_write });
    defer f.close(io);
    // Zig 0.16: positional write to end-of-file for append semantics.
    const end_offset = try f.length(io);
    try f.writePositionalAll(io, bytes, end_offset);
    try f.sync(io);
}

fn countLines(alloc: Allocator, io: std.Io, file_path: []const u8) u64 {
    const content = readFileAlloc(alloc, io, file_path) catch return 0;
    defer alloc.free(content);
    var n: u64 = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len > 0) n += 1;
    }
    return n;
}

/// Truncates a torn last line: if the file's final non-empty line fails to
/// parse as JSON, the file is cut back to the end of the previous good line.
fn truncateTornTail(io: std.Io, file_path: []const u8) !void {
    // PSEUDOCODE:
    // 1. Read content; find last good JSON line end offset
    // 2. If trailing bytes exist after it, truncate file at that offset
    const alloc = std.heap.page_allocator;
    const content = readFileAlloc(alloc, io, file_path) catch return;
    defer alloc.free(content);
    if (content.len == 0) return;

    // Find start of the last non-empty line.
    var end = content.len;
    while (end > 0 and (content[end - 1] == '\n' or content[end - 1] == '\r')) end -= 1;
    if (end == 0) return;
    var start = end;
    while (start > 0 and content[start - 1] != '\n') start -= 1;
    const last_line = std.mem.trim(u8, content[start..end], " \t\r");
    if (last_line.len == 0) return;

    // Parse check: does the last line form complete JSON?
    const ok = blk: {
        _ = std.json.parseFromSlice(std.json.Value, alloc, last_line, .{}) catch break :blk false;
        break :blk true;
    };
    if (ok) return; // intact — nothing to truncate

    // Truncate to the end of the previous line (or 0).
    var cut: usize = 0;
    if (start > 0) cut = start; // includes the newline of the previous line
    const cwd = std.Io.Dir.cwd();
    const f = try cwd.openFile(io, file_path, .{ .mode = .read_write });
    defer f.close(io);
    try f.setLength(io, cut);
}
