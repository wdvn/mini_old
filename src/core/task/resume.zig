//! core/task/resume.zig — Resume flows for the durable task layer (RFC-030 §4.5).
//!
//! `--resume <task_id>`: restore the full history of a specific resumable task
//! and continue the act loop with it.
//! `--continue`: resume the most recent resumable task of this project.
//!
//! Resume restores the *entire* prior conversation (snapshot + deltas) — the
//! model sees the full context and decides the next step itself. Tool dispatch
//! is untouched; an interruption note derived from the journal tail is injected
//! as an ephemeral user message when the last act was incomplete.

const std = @import("std");
const Allocator = std.mem.Allocator;
const task_types = @import("types.zig");
const TaskRecord = task_types.TaskRecord;
const store_mod = @import("store.zig");
const TaskStore = store_mod.TaskStore;
const history_log_mod = @import("history_log.zig");
const HistoryLog = history_log_mod.HistoryLog;
const History = @import("../history.zig").History;
const proto = @import("../protocol.zig");
const utils = @import("../utils.zig");

/// Resolves the tasks base dir for the current project
/// (`$MINI_HOME|~/.mini/tasks/<project_hash>`). Caller owns the result.
pub fn resolveTasksBaseDir(alloc: Allocator) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cur_cwd = if (std.c.getcwd(&cwd_buf, cwd_buf.len)) |ptr| std.mem.sliceTo(ptr, 0) else ".";
    const prj_hash = std.hash.Fnv1a_64.hash(cur_cwd);
    var base_buf: [512]u8 = undefined;
    const tasks_base: []const u8 = blk: {
        if (utils.getEnvSlice("MINI_HOME")) |mh| break :blk std.fmt.bufPrint(&base_buf, "{s}/tasks", .{mh}) catch "/tmp/mini_tasks";
        const home_dir = utils.getEnvSlice("HOME") orelse ".";
        break :blk std.fmt.bufPrint(&base_buf, "{s}/.mini/tasks", .{home_dir}) catch "/tmp/mini_tasks";
    };
    return std.fmt.allocPrint(alloc, "{s}/{x}", .{ tasks_base, prj_hash });
}

/// Restores the full history of `task_id` into a freshly allocated History.
/// Caller frees via `HistoryLog.freeRestored`.
pub fn restoreTaskHistory(alloc: Allocator, io: std.Io, tasks_base: []const u8, task_id: []const u8) !*History {
    return HistoryLog.restoreHistory(alloc, io, tasks_base, task_id);
}

/// Builds the interruption note for a resumed task (§4.3): the TaskRecord
/// status phrased for the model. Journal-tail tool details are appended by the
/// caller when available.
pub fn buildInterruptionNote(alloc: Allocator, rec: *const TaskRecord) ![]u8 {
    const status_line: []const u8 = switch (rec.status) {
        .interrupted => "The previous session was interrupted (crash or Ctrl+C).",
        .failed => "The previous session ended in a failure.",
        .stalled => "The previous session stalled without reaching a final answer.",
        .running => "The previous session exited while running (crash or termination).",
        .completed => "The previous session was completed.",
    };
    return std.fmt.allocPrint(alloc, "[Task Resumed — {s}]\n{s} Your full conversation history up to the last completed step has been restored above. The completion state of any in-flight work at the moment of interruption is unknown — verify before relying on prior outcomes, then continue the task from where it stopped.\n", .{ rec.task_id, status_line });
}
