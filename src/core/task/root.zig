//! core/task/root.zig — Durable task layer (RFC-030).
//!
//! Re-exports the durable task primitives for main.zig DI:
//! - types.zig     — TaskRecord, TaskStatus, HistoryLineType
//! - store.zig     — TaskStore (tasks.jsonl, append-only, last line wins)
//! - history_log.zig — per-task history.jsonl (snapshot + delta, full-context restore)
//! - retention.zig — GC of expired terminal task directories

pub const types = @import("types.zig");
pub const store = @import("store.zig");
pub const history_log = @import("history_log.zig");
pub const retention = @import("retention.zig");
pub const manager = @import("manager.zig");

pub const TaskRecord = types.TaskRecord;
pub const TaskStatus = types.TaskStatus;
pub const TaskStore = store.TaskStore;
pub const HistoryLog = history_log.HistoryLog;
pub const TaskManager = manager.TaskManager;
