//! core/task/types.zig — Durable task data model (RFC-030).
//!
//! Provides the durable task record schema shared by the TaskStore,
//! HistoryLog, and resume flows:
//! - `TaskStatus` — task lifecycle states
//! - `TaskRecord` — per-task metadata persisted in tasks.jsonl
//! - `HistoryLineType` — history-log line discriminator (snapshot | delta)

const std = @import("std");
const utils = @import("../utils.zig");

/// Status of a durable task.
pub const TaskStatus = enum {
    /// Task currently executing.
    running,
    /// Task finished with a final answer.
    completed,
    /// Task terminated by unrecoverable failure.
    failed,
    /// Task interrupted (e.g. Ctrl+C / crash).
    interrupted,
    /// Task ended without reaching a final answer (stall/blocked).
    stalled,

    /// Parses a status from its JSON representation.
    pub fn fromJson(name: []const u8) ?TaskStatus {
        inline for (std.meta.fields(TaskStatus)) |f| {
            if (std.mem.eql(u8, name, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

/// Discriminator for history-log lines.
pub const HistoryLineType = enum {
    /// Full history baseline (pinned on MemAct compaction).
    snapshot,
    /// Messages appended since the previous line.
    delta,

    pub fn fromJson(name: []const u8) ?HistoryLineType {
        inline for (std.meta.fields(HistoryLineType)) |f| {
            if (std.mem.eql(u8, name, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

/// Per-task metadata persisted in tasks.jsonl (append-only, last line wins).
/// Owned strings are duped on parse; see `deinit`.
pub const TaskRecord = struct {
    /// Unique task id (32-char lowercase hex uuid4).
    task_id: []const u8 = "",
    /// FNV-1a hash of cwd (project identity), links to memory/plan stores.
    project_hash: u64 = 0,
    /// FNV-1a hash of the user request (links to PlanStore).
    request_hash: u64 = 0,
    status: TaskStatus = .running,
    /// Creation timestamp (unix seconds).
    created_at: i64 = 0,
    /// Last update timestamp (unix seconds).
    updated_at: i64 = 0,
    /// Monotonically increasing history-log line count.
    history_seq: u64 = 0,
    /// Aggregated counters for post-hoc analytics.
    llm_calls: u64 = 0,
    tool_calls: u64 = 0,
    /// Short human-readable title (first ~80 chars of the request).
    title: []const u8 = "",

    /// Creates a default record for a task id with fresh timestamps.
    pub fn default(task_id: []const u8) TaskRecord {
        const now = utils.milliTimestamp(); // epoch ms
        return .{
            .task_id = task_id,
            .project_hash = 0,
            .request_hash = 0,
            .status = .running,
            .created_at = now,
            .updated_at = now,
            .history_seq = 0,
            .llm_calls = 0,
            .tool_calls = 0,
            .title = "",
        };
    }

    /// Frees owned strings produced by `parse`.
    pub fn deinit(self: *TaskRecord, alloc: std.mem.Allocator) void {
        alloc.free(self.task_id);
        alloc.free(self.title);
    }
};

test "task status round-trips through json name" {
    try std.testing.expectEqual(TaskStatus.completed, TaskStatus.fromJson("completed").?);
    try std.testing.expectEqual(TaskStatus.interrupted, TaskStatus.fromJson("interrupted").?);
    try std.testing.expect(TaskStatus.fromJson("bogus") == null);
}
