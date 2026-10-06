//! core/task/manager.zig — TaskManager: agent-facing facade over the durable
//! task primitives (RFC-030 Phase 1 integration).
//!
//! Owns the per-task HistoryLog and the shared TaskStore; provides:
//! - `ensureTask` — lazily create a task (multi-act requests only)
//! - `appendActDelta` — append new messages at act boundaries
//! - `snapshotAfterCompaction` — pin full history after MemAct compaction
//! - `finish` — write terminal status + flush pending delta
//! - `restoreHistory` — static full-context restore (used by --resume)

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const TaskRecord = types.TaskRecord;
const TaskStatus = types.TaskStatus;
const store_mod = @import("store.zig");
const TaskStore = store_mod.TaskStore;
const history_log_mod = @import("history_log.zig");
const HistoryLog = history_log_mod.HistoryLog;
const History = @import("../history.zig").History;
const proto = @import("../protocol.zig");
const utils = @import("../utils.zig");

pub const TaskManager = struct {
    alloc: Allocator,
    /// Base dir for tasks of this project (owned).
    base_dir: []u8,
    /// Shared per-project TaskStore (owned).
    store: TaskStore,
    /// Current task id (owned, empty = no active task).
    task_id: []u8,
    /// Current task record (owned strings).
    record: ?TaskRecord = null,
    /// Per-task history log (created lazily with the task).
    log: ?HistoryLog = null,
    /// Number of history messages already persisted to the log.
    persisted_len: usize = 0,

    /// Creates a TaskManager rooted at `base_dir`
    /// (e.g. `~/.mini/tasks/<project_hash>/`).
    pub fn init(alloc: Allocator, io: std.Io, base_dir: []const u8) !*TaskManager {
        // PSEUDOCODE:
        // 1. Allocate self, dupe base dir
        // 2. Init shared TaskStore
        const self = try alloc.create(TaskManager);
        errdefer alloc.destroy(self);
        const dir_dup = try alloc.dupe(u8, base_dir);
        errdefer alloc.free(dir_dup);
        const store = try TaskStore.init(alloc, io, dir_dup);
        errdefer alloc.free(dir_dup); // store contents freed with dir_dup cleanup path
        self.* = .{
            .alloc = alloc,
            .base_dir = dir_dup,
            .store = store,
            .task_id = try alloc.dupe(u8, ""),
        };
        return self;
    }
    pub fn deinit(self: *TaskManager) void {
        if (self.log) |*l| l.deinit();
        if (self.record) |*rec| rec.deinit(self.alloc);
        self.alloc.free(self.task_id);
        self.store.deinit();
        self.alloc.free(self.base_dir);
        self.alloc.destroy(self);
    }

    /// Lazily starts a task for a multi-act request. No-op when already active.
    pub fn ensureTask(self: *TaskManager, io: std.Io, request_text: []const u8) void {
        // PSEUDOCODE:
        // 1. Skip when a task is already active
        // 2. Generate uuid4 hex id; build record (title = first line, <= 80 chars)
        // 3. Append record; create history log
        if (self.record != null) return;
        // Zig 0.16: no std.crypto.random — derive 128-bit entropy from
        // timestamp + pid + address entropy (task ids are local, not secrets).
        var uuid: [16]u8 = undefined;
        std.mem.writeInt(u64, uuid[0..8], @bitCast(utils.milliTimestamp()), .little);
        std.mem.writeInt(u64, uuid[8..16], @as(u64, std.math.cast(u64, std.c.getpid()) orelse 0) ^ @intFromPtr(&uuid), .little);
        // Set version 4 / variant bits for a uuid4-shaped id.
        uuid[6] = (uuid[6] & 0x0f) | 0x40;
        uuid[8] = (uuid[8] & 0x3f) | 0x80;
        var id_buf: [32]u8 = undefined;
        const digits = "0123456789abcdef";
        for (uuid, 0..) |b, i| {
            id_buf[i * 2] = digits[b >> 4];
            id_buf[i * 2 + 1] = digits[b & 0x0f];
        }
        const task_id = self.alloc.dupe(u8, &id_buf) catch return;
        self.alloc.free(self.task_id);
        self.task_id = task_id;

        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cur_cwd = if (std.c.getcwd(&cwd_buf, cwd_buf.len)) |ptr| std.mem.sliceTo(ptr, 0) else ".";

        var rec = TaskRecord.default(self.task_id);
        rec.project_hash = std.hash.Fnv1a_64.hash(cur_cwd);
        rec.request_hash = std.hash.Fnv1a_64.hash(request_text);
        rec.title = firstLine(self.alloc, request_text, 80) catch return;
        self.store.append(io, &rec) catch {
            self.alloc.free(rec.title);
            return;
        };
        if (self.record) |*prev| prev.deinit(self.alloc);
        // Keep owned copies in the record (rec.title already owned).
        self.record = rec;

        self.log = HistoryLog.init(self.alloc, io, self.base_dir, self.task_id) catch null;
        self.persisted_len = 0;
    }

    /// Appends history messages not yet persisted (act-boundary flush).
    /// Also refreshes the TaskRecord (timestamps/seq).
    pub fn appendActDelta(self: *TaskManager, io: std.Io, history: *const History) void {
        // PSEUDOCODE:
        // 1. No-op when no task/log
        // 2. Slice new messages [persisted_len..]; skip when none
        // 3. appendDelta + update record line
        const log = &(self.log orelse return);
        const msgs = history.messages();
        if (self.persisted_len >= msgs.len) return;
        log.appendDelta(io, msgs[self.persisted_len..]) catch return;
        self.persisted_len = msgs.len;
        self.touchRecord(io, null);
    }

    /// Pins the full (post-compaction) history as a snapshot line and
    /// marks all messages as persisted.
    pub fn snapshotAfterCompaction(self: *TaskManager, io: std.Io, history: *const History) void {
        const log = &(self.log orelse return);
        log.writeSnapshot(io, history.messages()) catch return;
        self.persisted_len = history.messages().len;
        self.touchRecord(io, null);
    }

    /// Writes the terminal status for the active task.
    pub fn finish(self: *TaskManager, io: std.Io, status: TaskStatus) void {
        self.touchRecord(io, status);
    }

    fn touchRecord(self: *TaskManager, io: std.Io, status: ?TaskStatus) void {
        // PSEUDOCODE:
        // 1. Clone current record with fresh updated_at + seq
        // 2. Append as the new latest line (dupes freed after append)
        var rec = self.record orelse return;
        var updated = rec;
        updated.updated_at = utils.milliTimestamp();
        updated.history_seq = if (self.log) |*l| l.seq else rec.history_seq;
        if (status) |s| updated.status = s;
        const id_copy = self.alloc.dupe(u8, updated.task_id) catch return;
        const title_copy = self.alloc.dupe(u8, updated.title) catch {
            self.alloc.free(id_copy);
            return;
        };
        updated.task_id = id_copy;
        updated.title = title_copy;
        self.store.append(io, &updated) catch {};
        self.alloc.free(id_copy);
        self.alloc.free(title_copy);
        if (status) |s| rec.status = s;
        rec.updated_at = updated.updated_at;
        rec.history_seq = updated.history_seq;
    }

    /// Most recent resumable record (interrupted | failed | stalled), if any.
    /// Caller frees via `freeRecord`.
    pub fn latestResumable(self: *TaskManager, io: std.Io) ?TaskRecord {
        return self.store.readLatestResumable(self.alloc, io) catch null;
    }

    /// Frees a record returned by `latestResumable`.
    pub fn freeRecord(self: *TaskManager, rec: ?TaskRecord) void {
        if (rec) |*r| r.deinit(self.alloc);
    }
};

/// Duplicates the first line of `text`, truncated to at most `max` bytes
/// (owned by caller).
fn firstLine(alloc: Allocator, text: []const u8, max: usize) ![]u8 {
    var end: usize = 0;
    while (end < text.len and text[end] != '\n') end += 1;
    const slice = text[0..end];
    const len = @min(slice.len, max);
    return alloc.dupe(u8, slice[0..len]);
}
