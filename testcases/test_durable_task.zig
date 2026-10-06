//! test_durable_task.zig — Unit tests for the durable task layer (RFC-030).
//!
//! Validates:
//! 1. TaskStore append / latest-wins restore / compact (fold to one line per task_id)
//! 2. HistoryLog delta append + restore round-trip (full-context preservation)
//! 3. Snapshot line pins baseline; deltas apply on top
//! 4. Torn last line (crash mid-write) is truncated and ignored
//! 5. Retention GC removes expired terminal task directories

const std = @import("std");
const mini = @import("mini");
const task_types = mini.task_types_mod;
const task_store_mod = mini.task_store_mod;
const history_log_mod = mini.task_history_log_mod;
const retention_mod = mini.task_retention_mod;

const TaskStore = task_store_mod.TaskStore;
const HistoryLog = history_log_mod.HistoryLog;

// PSEUDOCODE:
// 1. Set up temp directories under /tmp, cleaned via deleteTree
// 2. Exercise TaskStore append/restore/compact
// 3. Exercise HistoryLog delta/snapshot/restore/torn-line
// 4. Exercise retention GC
// 5. Free all resources; verify no leaks (testing.allocator)

test "task store: append and latest-wins restore" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const dir = "/tmp/test_mini_task_store";
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};

    var store = try TaskStore.init(alloc, io, dir);
    defer store.deinit();

    var rec1 = task_types.TaskRecord.default("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    rec1.status = .running;
    var rec2 = task_types.TaskRecord.default("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    rec2.status = .interrupted;
    try store.append(io, &rec1);
    try store.append(io, &rec2);

    var loaded = (try store.readLatest(alloc, io, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")).?;
    defer loaded.deinit(alloc);
    try std.testing.expect(loaded.status == .interrupted);
}

test "task store: compact folds to one line per task_id" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const dir = "/tmp/test_mini_task_store_compact";
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};

    var store = try TaskStore.init(alloc, io, dir);
    defer store.deinit();

    var rec1 = task_types.TaskRecord.default("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    rec1.status = .running;
    var rec2 = task_types.TaskRecord.default("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    rec2.status = .completed;
    try store.append(io, &rec1);
    try store.append(io, &rec2);
    try store.compact(io);

    // Re-open and verify the folded file still restores the latest state.
    var store2 = try TaskStore.init(alloc, io, dir);
    defer store2.deinit();
    var loaded = (try store2.readLatest(alloc, io, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")).?;
    defer loaded.deinit(alloc);
    try std.testing.expect(loaded.status == .completed);
}

test "history log: delta restore round-trip preserves full context" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const dir = "/tmp/test_mini_task_hlog";
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};

    var log = try HistoryLog.init(alloc, io, dir, "cccccccccccccccccccccccccccccccc");
    defer log.deinit();

    const msgs1 = [_]mini.protocol_mod.Message{
        try textMessage(alloc, "hello"),
        try textMessage(alloc, "hi there"),
    };
    defer freeMessages(alloc, &msgs1);
    try log.appendDelta(io, &msgs1);

    const msgs2 = [_]mini.protocol_mod.Message{
        try textMessage(alloc, "more"),
    };
    defer freeMessages(alloc, &msgs2);
    try log.appendDelta(io, &msgs2);

    var restored = try HistoryLog.restoreHistory(alloc, io, dir, "cccccccccccccccccccccccccccccccc");
    defer HistoryLog.freeRestored(alloc, restored);
    try std.testing.expectEqual(@as(usize, 3), restored.len());
    try std.testing.expectEqual(mini.protocol_mod.Role.user, restored.messages()[0].role);
    try std.testing.expectEqualStrings("hello", restored.messages()[0].content[0].text);
    try std.testing.expectEqualStrings("hi there", restored.messages()[1].content[0].text);
    try std.testing.expectEqualStrings("more", restored.messages()[2].content[0].text);
}

test "history log: snapshot line pins baseline and deltas apply on top" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const dir = "/tmp/test_mini_task_snap";
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};

    var log = try HistoryLog.init(alloc, io, dir, "dddddddddddddddddddddddddddddddd");
    defer log.deinit();

    const base = [_]mini.protocol_mod.Message{
        try textMessage(alloc, "orig"),
    };
    defer freeMessages(alloc, &base);
    try log.writeSnapshot(io, &base);

    const more = [_]mini.protocol_mod.Message{
        try textMessage(alloc, "reply"),
    };
    defer freeMessages(alloc, &more);
    try log.appendDelta(io, &more);

    var restored = try HistoryLog.restoreHistory(alloc, io, dir, "dddddddddddddddddddddddddddddddd");
    defer HistoryLog.freeRestored(alloc, restored);
    try std.testing.expectEqual(@as(usize, 2), restored.len());
    try std.testing.expectEqualStrings("orig", restored.messages()[0].content[0].text);
    try std.testing.expectEqualStrings("reply", restored.messages()[1].content[0].text);
}

test "history log: torn last line is truncated and ignored" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const dir = "/tmp/test_mini_task_torn";
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};

    var log = try HistoryLog.init(alloc, io, dir, "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee");
    defer log.deinit();

    const m = [_]mini.protocol_mod.Message{
        try textMessage(alloc, "good line"),
    };
    defer freeMessages(alloc, &m);
    try log.appendDelta(io, &m);

    // Simulate a crash mid-write: append a partial JSON line.
    const f = try cwd.openFile(io, log.file_path, .{ .mode = .read_write });
    defer f.close(io);
    const tail_offset = try f.length(io);
    try f.writePositionalAll(io, "\n{\"type\": \"delta\", \"seq\": 99, \"mess", tail_offset);

    var restored = try HistoryLog.restoreHistory(alloc, io, dir, "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee");
    defer HistoryLog.freeRestored(alloc, restored);
    try std.testing.expectEqual(@as(usize, 1), restored.len());
    try std.testing.expectEqualStrings("good line", restored.messages()[0].content[0].text);
}

test "retention: old terminal task directories are removed" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const dir = "/tmp/test_mini_task_retain";
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};

    var store = try TaskStore.init(alloc, io, dir);
    defer store.deinit();

    var rec = task_types.TaskRecord.default("ffffffffffffffffffffffffffffffff");
    rec.status = .completed;
    rec.updated_at = mini.utils.milliTimestamp() - (15 * 24 * 3600 * 1000); // 15 days old (ms)
    try store.append(io, &rec);

    // Create the task directory so retention has something to remove.
    var log = try HistoryLog.init(alloc, io, dir, "ffffffffffffffffffffffffffffffff");
    defer log.deinit();

    try retention_mod.applyRetention(alloc, io, dir, 14);

    // TaskRecord line is kept for analytics...
    var store2 = try TaskStore.init(alloc, io, dir);
    defer store2.deinit();
    var loaded = (try store2.readLatest(alloc, io, "ffffffffffffffffffffffffffffffff")).?;
    defer loaded.deinit(alloc);
    try std.testing.expect(loaded.status == .completed);

    // ...but the task directory is gone.
    var exists = true;
    if (cwd.openDir(io, log.task_dir, .{})) |d| {
        var dd = d;
        dd.close(io);
        exists = true;
    } else |_| {
        exists = false;
    }
    try std.testing.expect(!exists);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn textMessage(alloc: std.mem.Allocator, text: []const u8) !mini.protocol_mod.Message {
    const blocks = try alloc.alloc(mini.protocol_mod.ContentBlock, 1);
    blocks[0] = .{ .text = try alloc.dupe(u8, text) };
    return .{ .role = .user, .content = blocks };
}

fn freeMessages(alloc: std.mem.Allocator, msgs: []const mini.protocol_mod.Message) void {
    for (msgs) |msg| {
        for (msg.content) |block| {
            switch (block) {
                .text => |t| alloc.free(t),
                else => {},
            }
        }
        alloc.free(msg.content);
    }
}
