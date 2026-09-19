//! act_queue.zig — 3-Thread Act Coordinator & State Monitor (RFC-015).
//!
//! Provides thread-safe coordination and state observation between:
//! - Thread 1: REPL Chat (Main Thread)
//! - Thread 2: Watchdog Monitor (Timeout Guardian & 3-Act Trajectory Recap)
//! - Thread 3: Act Executor (Worker Thread)
//!
//! Replaces legacy multi-worker/priority queue bloat from RFC-013 with a lean,
//! thread-safe coordinator tailored for single-turn code-centric execution.

const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");

// ---------------------------------------------------------------------------
// Act Status & Monitor State
// ---------------------------------------------------------------------------

/// Execution phase of the current act.
pub const ActStatus = enum {
    idle,
    preparing,
    calling_llm,
    executing_codeact,
    executing_tool,
    recap,
    completed,
    failed,

    pub fn asString(self: ActStatus) []const u8 {
        return switch (self) {
            .idle => "idle",
            .preparing => "preparing",
            .calling_llm => "calling_llm",
            .executing_codeact => "executing_codeact",
            .executing_tool => "executing_tool",
            .recap => "recap",
            .completed => "completed",
            .failed => "failed",
        };
    }
};

/// Snapshot of the running act's status, inspected by Thread 2 (Watchdog).
pub const ActMonitorState = struct {
    act_id: usize = 0,
    status: ActStatus = .idle,
    action_desc_buf: [128]u8 = [_]u8{0} ** 128,
    action_desc_len: usize = 0,
    act_start_ms: i64 = 0,
    last_heartbeat_ms: i64 = 0,
    last_reported_10s: u32 = 0,
    completed_acts: usize = 0,
    is_timed_out: bool = false,

    pub fn getActionDesc(self: *const ActMonitorState) []const u8 {
        return self.action_desc_buf[0..self.action_desc_len];
    }
};

/// Record of a tool execution for trajectory recap analysis.
pub const ToolRecord = struct {
    tool_name_buf: [48]u8 = [_]u8{0} ** 48,
    tool_name_len: usize = 0,
    args_hash: u64 = 0,
    is_read_only: bool = false,
    timestamp_ms: i64 = 0,

    pub fn toolName(self: *const ToolRecord) []const u8 {
        return self.tool_name_buf[0..self.tool_name_len];
    }
};

// ---------------------------------------------------------------------------
// Act Coordinator
// ---------------------------------------------------------------------------

/// Coordinates turn lifecycle and shared state across the 3 threads.
pub const ActCoordinator = struct {
    pub const MAX_TRAJECTORY: usize = 32;

    alloc: Allocator,
    mutex: std.atomic.Mutex = .unlocked,

    // Current state snapshot
    state: ActMonitorState = .{},

    // Trajectory circular buffer for 3-act recap
    trajectory: [MAX_TRAJECTORY]ToolRecord = undefined,
    trajectory_len: usize = 0,
    trajectory_head: usize = 0,

    // Watchdog recap advisory queue
    pending_recap_advisory: ?[]u8 = null,

    // Turn completion tracking
    turn_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    turn_completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(alloc: Allocator) *ActCoordinator {
        const self = alloc.create(ActCoordinator) catch @panic("OOM init ActCoordinator");
        self.* = ActCoordinator{
            .alloc = alloc,
        };
        return self;
    }

    pub fn deinit(self: *ActCoordinator) void {
        self.lock();
        if (self.pending_recap_advisory) |adv| {
            self.alloc.free(adv);
            self.pending_recap_advisory = null;
        }
        self.unlock();
        self.alloc.destroy(self);
    }

    pub fn lock(self: *ActCoordinator) void {
        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *ActCoordinator) void {
        self.mutex.unlock();
    }

    /// Reset state at the start of a new turn (Thread 1 / Thread 3).
    pub fn resetTurn(self: *ActCoordinator) void {
        self.lock();
        defer self.unlock();

        self.state.act_id = 0;
        self.state.status = .preparing;
        self.state.action_desc_len = 0;
        self.state.act_start_ms = utils.milliTimestamp();
        self.state.last_heartbeat_ms = self.state.act_start_ms;
        self.state.last_reported_10s = 0;
        self.state.completed_acts = 0;
        self.state.is_timed_out = false;

        self.trajectory_len = 0;
        self.trajectory_head = 0;

        if (self.pending_recap_advisory) |adv| {
            self.alloc.free(adv);
            self.pending_recap_advisory = null;
        }

        self.turn_active.store(true, .seq_cst);
        self.turn_completed.store(false, .seq_cst);
    }

    /// Update status of the current act (called by Thread 3 Act Executor).
    pub fn updateStatus(self: *ActCoordinator, act_id: usize, status: ActStatus, action_desc: []const u8) void {
        self.lock();
        defer self.unlock();

        const now = utils.milliTimestamp();
        if (self.state.act_id != act_id) {
            self.state.act_id = act_id;
            self.state.act_start_ms = now;
            self.state.last_reported_10s = 0;
        }
        self.state.status = status;
        self.state.last_heartbeat_ms = now;

        const copy_len = @min(action_desc.len, self.state.action_desc_buf.len);
        @memcpy(self.state.action_desc_buf[0..copy_len], action_desc[0..copy_len]);
        self.state.action_desc_len = copy_len;
    }

    /// Extend heartbeat during long streaming or tool execution.
    pub fn renewHeartbeat(self: *ActCoordinator) void {
        self.lock();
        defer self.unlock();
        self.state.last_heartbeat_ms = utils.milliTimestamp();
    }

    /// Record a tool execution into the trajectory history.
    pub fn recordToolExecution(self: *ActCoordinator, tool_name: []const u8, args_hash: u64, is_read_only: bool) void {
        self.lock();
        defer self.unlock();

        var rec: ToolRecord = .{
            .args_hash = args_hash,
            .is_read_only = is_read_only,
            .timestamp_ms = utils.milliTimestamp(),
        };
        const name_len = @min(tool_name.len, rec.tool_name_buf.len);
        @memcpy(rec.tool_name_buf[0..name_len], tool_name[0..name_len]);
        rec.tool_name_len = name_len;

        const idx = (self.trajectory_head + self.trajectory_len) % MAX_TRAJECTORY;
        self.trajectory[idx] = rec;
        if (self.trajectory_len < MAX_TRAJECTORY) {
            self.trajectory_len += 1;
        } else {
            self.trajectory_head = (self.trajectory_head + 1) % MAX_TRAJECTORY;
        }
    }

    /// Mark current act finished.
    pub fn finishAct(self: *ActCoordinator, act_id: usize, is_success: bool) void {
        self.lock();
        defer self.unlock();

        _ = act_id;
        self.state.status = if (is_success) .completed else .failed;
        self.state.completed_acts += 1;
        self.state.last_heartbeat_ms = utils.milliTimestamp();
    }

    /// Mark turn completed.
    pub fn notifyTurnComplete(self: *ActCoordinator) void {
        self.lock();
        self.state.status = .idle;
        self.unlock();

        self.turn_active.store(false, .seq_cst);
        self.turn_completed.store(true, .seq_cst);
    }

    /// Flag timeout intervention by Watchdog (Thread 2).
    pub fn setTimedOut(self: *ActCoordinator, timed_out: bool) void {
        self.lock();
        defer self.unlock();
        self.state.is_timed_out = timed_out;
    }

    /// Check if current act timed out.
    pub fn isTimedOut(self: *ActCoordinator) bool {
        self.lock();
        defer self.unlock();
        return self.state.is_timed_out;
    }

    /// Thread 2 (Watchdog) updates the 10s reporting milestone.
    pub fn updateLastReported10s(self: *ActCoordinator, bucket: u32) void {
        self.lock();
        defer self.unlock();
        self.state.last_reported_10s = bucket;
    }

    /// Store a Watchdog 3-act recap advisory to be injected into the next act.
    pub fn setPendingRecapAdvisory(self: *ActCoordinator, advisory: []const u8) !void {
        self.lock();
        defer self.unlock();

        if (self.pending_recap_advisory) |old| {
            self.alloc.free(old);
        }
        self.pending_recap_advisory = try self.alloc.dupe(u8, advisory);
    }

    /// Thread 3 (Act Executor) consumes any pending recap advisory before starting an act.
    pub fn popPendingRecapAdvisory(self: *ActCoordinator) ?[]u8 {
        self.lock();
        defer self.unlock();

        const adv = self.pending_recap_advisory;
        self.pending_recap_advisory = null;
        return adv;
    }

    /// Get current monitor state snapshot (Thread 2 Watchdog reads this).
    pub fn getMonitorState(self: *ActCoordinator) ActMonitorState {
        self.lock();
        defer self.unlock();
        return self.state;
    }

    /// Retrieve copy of recent tool records for trajectory analysis.
    pub fn getRecentToolRecords(self: *ActCoordinator, out: []ToolRecord) usize {
        self.lock();
        defer self.unlock();

        const count = @min(out.len, self.trajectory_len);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            // Read in chronological order starting from oldest in window
            const start_offset = self.trajectory_len - count;
            const ring_idx = (self.trajectory_head + start_offset + i) % MAX_TRAJECTORY;
            out[i] = self.trajectory[ring_idx];
        }
        return count;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "ActCoordinator: turn lifecycle and state updates" {
    const alloc = std.testing.allocator;
    var coord = ActCoordinator.init(alloc);
    defer coord.deinit();

    coord.resetTurn();
    var state = coord.getMonitorState();
    try std.testing.expectEqual(ActStatus.preparing, state.status);
    try std.testing.expectEqual(@as(usize, 0), state.completed_acts);

    coord.updateStatus(1, .calling_llm, "Calling OpenAI GPT-4o");
    state = coord.getMonitorState();
    try std.testing.expectEqual(ActStatus.calling_llm, state.status);
    try std.testing.expectEqualStrings("Calling OpenAI GPT-4o", state.getActionDesc());

    coord.recordToolExecution("file_read", 12345, true);
    coord.recordToolExecution("grep", 67890, true);
    coord.finishAct(1, true);

    state = coord.getMonitorState();
    try std.testing.expectEqual(ActStatus.completed, state.status);
    try std.testing.expectEqual(@as(usize, 1), state.completed_acts);

    var tools: [4]ToolRecord = undefined;
    const n = coord.getRecentToolRecords(&tools);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("file_read", tools[0].toolName());
    try std.testing.expectEqualStrings("grep", tools[1].toolName());
}

test "ActCoordinator: pending recap advisory queue" {
    const alloc = std.testing.allocator;
    var coord = ActCoordinator.init(alloc);
    defer coord.deinit();

    try coord.setPendingRecapAdvisory("[Watchdog Recap]: Checkpoint triggered");
    const adv_opt = coord.popPendingRecapAdvisory();
    try std.testing.expect(adv_opt != null);
    defer alloc.free(adv_opt.?);
    try std.testing.expectEqualStrings("[Watchdog Recap]: Checkpoint triggered", adv_opt.?);

    // Popping again should yield null
    try std.testing.expect(coord.popPendingRecapAdvisory() == null);
}
