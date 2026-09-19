//! watchdog.zig — Thread 2 Watchdog Supervisor (RFC-015).
//!
//! Dedicated supervisor thread monitoring the active act on Thread 3:
//! 1. Act Observation: inspects what the active act is doing in real-time.
//! 2. 10s Act Tracking: emits progress tracking notifications every 10 seconds of active execution.
//! 3. Timeout Intervention: detects unresponsive or hung acts (> act_timeout_secs) and interrupts them.
//! 4. 3-Act Trajectory Recap: every 3 completed acts, analyzes tool trajectory for loops and hallucinations,
//!    generating a structured checkpoint advisory injected into the next act.

const std = @import("std");
const Allocator = std.mem.Allocator;
const act_queue = @import("act_queue.zig");
const utils = @import("utils.zig");
const signals = @import("signals.zig");

fn printStderr(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    w.interface.print(fmt, args) catch return;
    w.flush() catch {};
}

pub const WatchdogConfig = struct {
    /// Seconds between act progress tracking notifications (default: 10s).
    tracking_interval_s: u32 = 10,
    /// Seconds before an act is declared hung/timed out (default: 120s).
    act_timeout_secs: u32 = 120,
    /// Number of completed acts between trajectory recap evaluations (default: 3).
    recap_interval_acts: usize = 3,
    /// Watchdog polling interval in milliseconds (default: 200ms).
    poll_interval_ms: u32 = 200,
    /// If true, print notifications to stderr (default: true).
    verbose_stderr: bool = true,
};

pub const Watchdog = struct {
    alloc: Allocator,
    io: std.Io,
    coordinator: *act_queue.ActCoordinator,
    config: WatchdogConfig,

    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    last_evaluated_act_count: usize = 0,
    consecutive_loop_warnings: usize = 0,

    /// Optional external interrupt hook (e.g. QuickJS requestInterrupt).
    interrupt_fn: ?*const fn () void = null,

    pub fn init(alloc: Allocator, io: std.Io, coordinator: *act_queue.ActCoordinator, config: WatchdogConfig) *Watchdog {
        const self = alloc.create(Watchdog) catch @panic("OOM init Watchdog");
        self.* = Watchdog{
            .alloc = alloc,
            .io = io,
            .coordinator = coordinator,
            .config = config,
        };
        return self;
    }

    pub fn deinit(self: *Watchdog) void {
        self.stop();
        self.alloc.destroy(self);
    }

    /// Spawn Thread 2 (Watchdog monitor loop).
    pub fn start(self: *Watchdog) !void {
        if (self.running.load(.seq_cst)) return;
        self.running.store(true, .seq_cst);
        self.thread = try std.Thread.spawn(.{}, threadEntry, .{self});
    }

    /// Stop and join Thread 2.
    pub fn stop(self: *Watchdog) void {
        if (!self.running.load(.seq_cst)) return;
        self.running.store(false, .seq_cst);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn threadEntry(self: *Watchdog) void {
        while (self.running.load(.seq_cst)) {
            self.tick();
            // Sleep poll interval (200ms default)
            const ms: i64 = @intCast(self.config.poll_interval_ms);
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(ms), .awake) catch {
                // Fallback spin delay if Io.sleep interrupted
                var i: usize = 0;
                while (i < 100_000) : (i += 1) {
                    std.atomic.spinLoopHint();
                }
            };
        }
    }

    /// Execute a single evaluation tick (callable by thread or tests).
    pub fn tick(self: *Watchdog) void {
        const state = self.coordinator.getMonitorState();

        // 1. Act Progress Tracking & Timeout Check (for running acts)
        if (state.status != .idle and state.status != .completed and state.status != .failed) {
            const now = utils.milliTimestamp();
            const elapsed_ms = if (now >= state.act_start_ms) now - state.act_start_ms else 0;
            const elapsed_s: u32 = @intCast(@divFloor(elapsed_ms, 1000));

            // Tracking every 10s
            if (self.config.tracking_interval_s > 0) {
                const bucket = @divFloor(elapsed_s, self.config.tracking_interval_s);
                if (bucket > state.last_reported_10s and bucket > 0) {
                    self.coordinator.updateLastReported10s(bucket);
                    if (self.config.verbose_stderr) {
                        printStderr(
                            self.io,
                            "\x1b[36m[watchdog]\x1b[0m Act {d} in progress ({d}s): {s}\n",
                            .{ state.act_id, bucket * self.config.tracking_interval_s, state.getActionDesc() },
                        );
                    }
                }
            }

            // Timeout check
            if (self.config.act_timeout_secs > 0 and elapsed_s >= self.config.act_timeout_secs) {
                if (!state.is_timed_out) {
                    self.coordinator.setTimedOut(true);
                    signals.setInterrupted(true);
                    if (self.interrupt_fn) |int_fn| {
                        int_fn();
                    }
                    if (self.config.verbose_stderr) {
                        printStderr(
                            self.io,
                            "\n\x1b[31m[watchdog] ⚠️ Act {d} TIMEOUT ({d}s exceeded limit of {d}s)! Current action: {s}. Triggering interrupt.\x1b[0m\n",
                            .{ state.act_id, elapsed_s, self.config.act_timeout_secs, state.getActionDesc() },
                        );
                    }
                }
            }
        }

        // 2. 3-Act Trajectory Recap Evaluation (every 3 completed acts)
        const completed = state.completed_acts;
        if (completed >= self.config.recap_interval_acts and
            completed % self.config.recap_interval_acts == 0 and
            completed != self.last_evaluated_act_count)
        {
            self.last_evaluated_act_count = completed;
            self.evaluateAndInjectRecap(completed) catch {};
        }
    }

    /// Evaluates recent trajectory and stores recap advisory for the next act.
    fn evaluateAndInjectRecap(self: *Watchdog, completed_acts: usize) !void {
        var records: [16]act_queue.ToolRecord = undefined;
        const count = self.coordinator.getRecentToolRecords(&records);

        var traj_writer = utils.BufWriter.init(self.alloc);
        defer traj_writer.deinit();

        var read_only_count: usize = 0;
        var has_dup: bool = false;
        var has_cycle: bool = false;

        const eval_slice = if (count > 0) records[0..count] else &[_]act_queue.ToolRecord{};

        for (eval_slice, 0..) |rec, i| {
            if (i > 0) try traj_writer.writeAll(" → ");
            try traj_writer.writeAll(rec.toolName());

            if (rec.is_read_only) read_only_count += 1;
        }

        // Evaluate loop detection on the recent activity window (last recap interval)
        const recent_window = @min(count, self.config.recap_interval_acts + 1);
        const recent_start = if (count > recent_window) count - recent_window else 0;

        for (eval_slice[recent_start..], 0..) |rec, rel_i| {
            const abs_i = recent_start + rel_i;
            // Check duplicate consecutive tool with same args hash
            if (abs_i > 0 and rec.args_hash != 0 and rec.args_hash == eval_slice[abs_i - 1].args_hash and
                std.mem.eql(u8, rec.toolName(), eval_slice[abs_i - 1].toolName()))
            {
                has_dup = true;
            }

            // Check cycle A(args1) -> B(args2) -> A(args1) with identical args hash
            if (abs_i >= 2 and rec.args_hash != 0 and rec.args_hash == eval_slice[abs_i - 2].args_hash and
                std.mem.eql(u8, rec.toolName(), eval_slice[abs_i - 2].toolName()) and
                rec.args_hash != eval_slice[abs_i - 1].args_hash)
            {
                has_cycle = true;
            }
        }

        const display_traj = if (traj_writer.list.items.len > 0)
            traj_writer.list.items
        else
            "No tool calls (pure reasoning / text response)";

        const diagnosis = if (has_dup)
            "Duplicate action detected: identical tool call repeated with identical parameters."
        else if (has_cycle)
            "Alternating cycle detected: tool usage appears to oscillate back and forth."
        else if (count >= 3 and read_only_count == count)
            "Exploration saturation: multiple consecutive read-only operations without code mutation."
        else
            "Normal progression: actions are advancing across the workspace.";

        if (has_dup or has_cycle) {
            self.consecutive_loop_warnings += 1;
        } else {
            self.consecutive_loop_warnings = 0;
        }

        // Circuit Breaker: If the agent is stuck in repetitive loops for 3 consecutive
        // recap intervals (9 acts), force-abort turn to protect against infinite loops.
        if (self.consecutive_loop_warnings >= 3) {
            self.coordinator.setTimedOut(true);
            signals.setInterrupted(true);
            if (self.interrupt_fn) |int_fn| {
                int_fn();
            }
            if (self.config.verbose_stderr) {
                printStderr(
                    self.io,
                    "\n\x1b[31m[watchdog] 🛑 Circuit Breaker: 3 consecutive loop warnings ({d} acts trapped)! Terminating turn to prevent infinite loop.\x1b[0m\n",
                    .{completed_acts},
                );
            }
            return;
        }

        const advisory = if (has_dup or has_cycle)
            "⚠️ Trajectory Warning: You appear to be repeating actions without forward progress. Re-assess findings, break out of this loop, and proceed to modify files or respond to the user."
        else if (count >= 3 and read_only_count == count)
            "💡 Exploration Note: Sufficient context may have been gathered. Consider transitioning directly to code changes or synthesizing your final answer."
        else
            "✅ Progress Assessment: Continue with your planned next step, or deliver findings if the request has been fulfilled.";

        const full_message = try std.fmt.allocPrint(
            self.alloc,
            "[Watchdog Checkpoint & Recap (Act {d})]\n" ++
                "📍 Trajectory (last {d} acts): {s}\n" ++
                "🔍 Observation: {s}\n" ++
                "{s}\n",
            .{ completed_acts, self.config.recap_interval_acts, display_traj, diagnosis, advisory },
        );
        defer self.alloc.free(full_message);

        try self.coordinator.setPendingRecapAdvisory(full_message);

        if (self.config.verbose_stderr) {
            printStderr(
                self.io,
                "\n\x1b[33m[watchdog] 📍 Checkpoint & Recap (Act {d}): Trajectory: {s} | {s}\x1b[0m\n",
                .{ completed_acts, display_traj, diagnosis },
            );
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Watchdog: 10s tracking milestone" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var coord = act_queue.ActCoordinator.init(alloc);
    defer coord.deinit();

    var dog = Watchdog.init(alloc, io, coord, .{
        .tracking_interval_s = 10,
        .act_timeout_secs = 120,
        .verbose_stderr = false,
    });
    defer dog.deinit();

    coord.resetTurn();
    coord.updateStatus(1, .executing_tool, "bash: sleep 15");

    // Artificially backdate act_start_ms to 12s ago
    coord.lock();
    coord.state.act_start_ms -= 12_000;
    coord.unlock();

    dog.tick();

    const state = coord.getMonitorState();
    try std.testing.expectEqual(@as(u32, 1), state.last_reported_10s);
}

test "Watchdog: timeout intervention" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var coord = act_queue.ActCoordinator.init(alloc);
    defer coord.deinit();

    var dog = Watchdog.init(alloc, io, coord, .{
        .tracking_interval_s = 10,
        .act_timeout_secs = 5,
        .verbose_stderr = false,
    });
    defer dog.deinit();

    coord.resetTurn();
    coord.updateStatus(1, .calling_llm, "Calling API");

    // Artificially backdate act_start_ms to 8s ago (exceeding 5s timeout)
    coord.lock();
    coord.state.act_start_ms -= 8_000;
    coord.unlock();

    signals.setInterrupted(false);
    defer signals.setInterrupted(false);
    dog.tick();

    try std.testing.expect(coord.isTimedOut());
    try std.testing.expect(signals.isInterrupted());
}

test "Watchdog: 3-act recap analysis and advisory injection" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var coord = act_queue.ActCoordinator.init(alloc);
    defer coord.deinit();

    var dog = Watchdog.init(alloc, io, coord, .{
        .recap_interval_acts = 3,
        .verbose_stderr = false,
    });
    defer dog.deinit();

    coord.resetTurn();

    // Act 1
    coord.recordToolExecution("file_read", 111, true);
    coord.finishAct(1, true);

    // Act 2
    coord.recordToolExecution("grep", 222, true);
    coord.finishAct(2, true);

    // Act 3
    coord.recordToolExecution("file_read", 111, true); // Cycling back to file_read
    coord.finishAct(3, true);

    dog.tick();

    const adv_opt = coord.popPendingRecapAdvisory();
    try std.testing.expect(adv_opt != null);
    defer alloc.free(adv_opt.?);

    // Should detect trajectory and mention cycle or recap
    try std.testing.expect(std.mem.indexOf(u8, adv_opt.?, "[Watchdog Checkpoint & Recap (Act 3)]") != null);
    try std.testing.expect(std.mem.indexOf(u8, adv_opt.?, "file_read → grep → file_read") != null);
}
