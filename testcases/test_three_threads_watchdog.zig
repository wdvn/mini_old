//! test_three_threads_watchdog.zig — Integration tests for -thread runtime and watchdog.
//!
//! Validates:
//!   1. ActCoordinator state tracking and thread-safe monitor state snapshots.
//!   2. Trajectory recording and 3-act loop/hallucination recap advisory generation.
//!   3. Milestone tracking notifications and timeout intervention.
//!   4. Concurrent multi-threaded execution across Main Thread, Watchdog, and Worker Thread.

const std = @import("std");
const testing = std.testing;
const mini = @import("mini");

const act_queue = mini.act_queue_mod;
const watchdog_mod = mini.watchdog_mod;
const signals = mini.signals_mod;

test "ActCoordinator: turn and act lifecycle tracking" {
    const alloc = testing.allocator;
    var coordinator = act_queue.ActCoordinator.init(alloc);
    defer coordinator.deinit();

    // Initially idle
    const snap0 = coordinator.getMonitorState();
    try testing.expectEqual(act_queue.ActStatus.idle, snap0.status);
    try testing.expectEqual(@as(usize, 0), snap0.act_id);
    try testing.expectEqual(@as(usize, 0), snap0.completed_acts);

    // Start turn
    coordinator.resetTurn();
    const snap1 = coordinator.getMonitorState();
    try testing.expectEqual(act_queue.ActStatus.preparing, snap1.status);
    try testing.expect(coordinator.turn_active.load(.seq_cst));

    // Update Act 1 status
    coordinator.updateStatus(1, .executing_tool, "file_edit: src/main.zig");
    const snap2 = coordinator.getMonitorState();
    try testing.expectEqual(act_queue.ActStatus.executing_tool, snap2.status);
    try testing.expectEqual(@as(usize, 1), snap2.act_id);
    try testing.expectEqualStrings("file_edit: src/main.zig", snap2.getActionDesc());

    // Record tool execution
    coordinator.recordToolExecution("file_edit", 12345, false);

    // Act 1 finishes successfully
    coordinator.finishAct(1, true);
    const snap3 = coordinator.getMonitorState();
    try testing.expectEqual(act_queue.ActStatus.completed, snap3.status);
    try testing.expectEqual(@as(usize, 1), snap3.completed_acts);

    coordinator.notifyTurnComplete();
    const snap4 = coordinator.getMonitorState();
    try testing.expectEqual(act_queue.ActStatus.idle, snap4.status);
    try testing.expect(!coordinator.turn_active.load(.seq_cst));
    try testing.expect(coordinator.turn_completed.load(.seq_cst));
}

test "ActCoordinator & Watchdog: 3-act trajectory recap for loops and hallucinations" {
    const alloc = testing.allocator;
    const io = testing.io;

    var coordinator = act_queue.ActCoordinator.init(alloc);
    defer coordinator.deinit();

    var watchdog = watchdog_mod.Watchdog.init(alloc, io, coordinator, .{
        .recap_interval_acts = 3,
        .tracking_interval_s = 10,
        .act_timeout_secs = 120,
        .verbose_stderr = false,
        .prompt_enforcement_enabled = true,
    });
    defer watchdog.deinit();

    coordinator.resetTurn();

    // Act 1: bash "cargo build"
    coordinator.updateStatus(1, .executing_tool, "bash: cargo build");
    coordinator.recordToolExecution("bash", 55555, false);
    coordinator.finishAct(1, false);

    // Act 2: bash "cargo build" (duplicate call)
    coordinator.updateStatus(2, .executing_tool, "bash: cargo build");
    coordinator.recordToolExecution("bash", 55555, false);
    coordinator.finishAct(2, false);

    // Act 3: bash "cargo build" (duplicate call again -> loop/hallucination)
    coordinator.updateStatus(3, .executing_tool, "bash: cargo build");
    coordinator.recordToolExecution("bash", 55555, false);
    coordinator.finishAct(3, false);

    // Trigger watchdog tick
    watchdog.tick();

    // Consume advisory injected by watchdog
    const advisory_opt = coordinator.popPendingRecapAdvisory();
    try testing.expect(advisory_opt != null);
    const advisory = advisory_opt.?;
    defer alloc.free(advisory);

    // Verify advisory detects duplicate action / loop
    try testing.expect(std.mem.indexOf(u8, advisory, "Watchdog Checkpoint & Recap") != null);
    try testing.expect(std.mem.indexOf(u8, advisory, "Duplicate action detected") != null);
    try testing.expect(std.mem.indexOf(u8, advisory, "Trajectory Warning") != null);
}

test "Watchdog: milestone tracking and timeout intervention" {
    defer signals.setInterrupted(false);

    const alloc = testing.allocator;
    const io = testing.io;

    var coordinator = act_queue.ActCoordinator.init(alloc);
    defer coordinator.deinit();

    var watchdog = watchdog_mod.Watchdog.init(alloc, io, coordinator, .{
        .tracking_interval_s = 1,
        .act_timeout_secs = 3,
        .verbose_stderr = false,
    });
    defer watchdog.deinit();

    coordinator.resetTurn();
    coordinator.updateStatus(1, .executing_tool, "bash: sleep 10");

    // 1. Backdate start time by 1.5s -> should hit 1s tracking bucket
    coordinator.lock();
    coordinator.state.act_start_ms -= 1500;
    coordinator.unlock();

    watchdog.tick();
    const snap1 = coordinator.getMonitorState();
    try testing.expectEqual(@as(u32, 1), snap1.last_reported_10s);
    try testing.expect(!signals.isInterrupted());
    try testing.expect(!coordinator.isTimedOut());

    // 2. Backdate start time by 4s -> should exceed 3s timeout
    coordinator.lock();
    coordinator.state.act_start_ms -= 4000;
    coordinator.unlock();

    watchdog.tick();
    const snap2 = coordinator.getMonitorState();
    try testing.expect(snap2.is_timed_out);
    try testing.expect(signals.isInterrupted());

    // Clean up signal for other tests
    signals.setInterrupted(false);
}

test "Concurrent 3-Thread Architecture: Main, Watchdog, and Worker threads" {
    const alloc = testing.allocator;
    const io = testing.io;

    var coordinator = act_queue.ActCoordinator.init(alloc);
    defer coordinator.deinit();

    var watchdog = watchdog_mod.Watchdog.init(alloc, io, coordinator, .{
        .poll_interval_ms = 20,
        .tracking_interval_s = 10,
        .act_timeout_secs = 120,
        .verbose_stderr = false,
    });
    defer watchdog.deinit();

    // 1. Thread 1 starts Thread 2 (Watchdog)
    try watchdog.start();

    // 2. Thread 1 initiates a turn
    coordinator.resetTurn();

    // 3. Spawn Thread 3 (Worker) to execute acts
    const WorkerContext = struct {
        coord: *act_queue.ActCoordinator,
        test_io: std.Io,

        fn run(ctx: *@This()) void {
            // Act 1
            ctx.coord.updateStatus(1, .executing_tool, "glob: **/*.zig");
            ctx.coord.recordToolExecution("glob", 111, true);
            std.Io.sleep(ctx.test_io, std.Io.Duration.fromMilliseconds(30), .awake) catch {};
            ctx.coord.finishAct(1, true);

            // Act 2
            ctx.coord.updateStatus(2, .executing_tool, "file_read: src/main.zig");
            ctx.coord.recordToolExecution("file_read", 222, true);
            std.Io.sleep(ctx.test_io, std.Io.Duration.fromMilliseconds(30), .awake) catch {};
            ctx.coord.finishAct(2, true);

            ctx.coord.notifyTurnComplete();
        }
    };

    var worker_ctx = WorkerContext{
        .coord = coordinator,
        .test_io = io,
    };

    const worker_thread = try std.Thread.spawn(.{}, WorkerContext.run, .{&worker_ctx});
    worker_thread.join();

    // 4. Thread 1 stops Thread 2 (Watchdog)
    watchdog.stop();

    // Verify final stats
    const snap = coordinator.getMonitorState();
    try testing.expectEqual(act_queue.ActStatus.idle, snap.status);
    try testing.expectEqual(@as(usize, 2), snap.completed_acts);
    try testing.expect(!coordinator.turn_active.load(.seq_cst));
    try testing.expect(coordinator.turn_completed.load(.seq_cst));
}

fn mockDecisionWait(ctx: watchdog_mod.DecisionContext) watchdog_mod.TimeoutDecision {
    _ = ctx;
    var d = watchdog_mod.TimeoutDecision{
        .should_kill = false,
        .extend_seconds = 10,
    };
    const r = "Compilation in progress";
    @memcpy(d.reason_buf[0..r.len], r);
    d.reason_len = r.len;
    return d;
}

fn mockDecisionKill(ctx: watchdog_mod.DecisionContext) watchdog_mod.TimeoutDecision {
    _ = ctx;
    var d = watchdog_mod.TimeoutDecision{
        .should_kill = true,
        .extend_seconds = 0,
    };
    const r = "Hung waiting for stdin";
    @memcpy(d.reason_buf[0..r.len], r);
    d.reason_len = r.len;
    return d;
}

test "Watchdog: decision function choosing WAIT extends timeout without interrupt" {
    defer signals.setInterrupted(false);
    const alloc = testing.allocator;
    const io = testing.io;

    var coordinator = act_queue.ActCoordinator.init(alloc);
    defer coordinator.deinit();

    var watchdog = watchdog_mod.Watchdog.init(alloc, io, coordinator, .{
        .tracking_interval_s = 10,
        .act_timeout_secs = 5,
        .verbose_stderr = false,
    });
    defer watchdog.deinit();
    watchdog.decision_fn = &mockDecisionWait;

    coordinator.resetTurn();
    coordinator.updateStatus(1, .executing_tool, "bash: compile");

    // Exceed initial 5s timeout
    coordinator.lock();
    coordinator.state.act_start_ms -= 6000;
    coordinator.unlock();

    watchdog.tick();

    // Must NOT be timed out or interrupted because decision was WAIT (+10s)
    const state = coordinator.getMonitorState();
    try testing.expect(!state.is_timed_out);
    try testing.expect(!signals.isInterrupted());
    try testing.expectEqual(@as(u32, 16), watchdog.current_act_timeout_s);
}

test "Watchdog: decision function choosing KILL triggers interrupt and sets timeout context" {
    defer signals.setInterrupted(false);
    const alloc = testing.allocator;
    const io = testing.io;

    var coordinator = act_queue.ActCoordinator.init(alloc);
    defer coordinator.deinit();

    var watchdog = watchdog_mod.Watchdog.init(alloc, io, coordinator, .{
        .tracking_interval_s = 10,
        .act_timeout_secs = 5,
        .verbose_stderr = false,
    });
    defer watchdog.deinit();
    watchdog.decision_fn = &mockDecisionKill;

    coordinator.resetTurn();
    coordinator.updateStatus(1, .executing_tool, "bash: hung");

    // Exceed initial 5s timeout
    coordinator.lock();
    coordinator.state.act_start_ms -= 6000;
    coordinator.unlock();

    watchdog.tick();

    // Must be timed out and interrupted because decision was KILL
    const state = coordinator.getMonitorState();
    try testing.expect(state.is_timed_out);
    try testing.expect(signals.isInterrupted());

    // Verify pending timeout context was populated
    const timeout_ctx = coordinator.popPendingTimeoutContext();
    try testing.expect(timeout_ctx != null);
    defer alloc.free(timeout_ctx.?);
    try testing.expectEqualStrings("Hung waiting for stdin", timeout_ctx.?);
}

var g_force_kill_invoked: bool = false;
fn mockForceKillHook() void {
    g_force_kill_invoked = true;
}

test "Watchdog: escalation invokes force_kill_fn when act remains running past timeout" {
    defer signals.setInterrupted(false);
    const alloc = testing.allocator;
    const io = testing.io;

    var coordinator = act_queue.ActCoordinator.init(alloc);
    defer coordinator.deinit();

    var watchdog = watchdog_mod.Watchdog.init(alloc, io, coordinator, .{
        .tracking_interval_s = 10,
        .act_timeout_secs = 5,
        .verbose_stderr = false,
    });
    defer watchdog.deinit();
    watchdog.decision_fn = &mockDecisionKill;
    watchdog.force_kill_fn = &mockForceKillHook;

    coordinator.resetTurn();
    coordinator.updateStatus(1, .executing_tool, "bash: hung");

    // Exceed initial 5s timeout
    coordinator.lock();
    coordinator.state.act_start_ms -= 6000;
    coordinator.unlock();

    // First tick: triggers interrupt (KILL decision)
    g_force_kill_invoked = false;
    watchdog.tick();
    try testing.expect(coordinator.getMonitorState().is_timed_out);
    try testing.expect(!g_force_kill_invoked);

    // Second tick: act is still running past timeout -> triggers force_kill_fn escalation!
    // Note: with default cooldown (10s), this fires immediately since no time has passed
    watchdog.tick();
    try testing.expect(g_force_kill_invoked);
    try testing.expect(signals.isInterrupted());
}

test "Watchdog: escalation cooldown prevents log spam" {
    defer signals.setInterrupted(false);
    const alloc = testing.allocator;
    const io = testing.io;

    var coordinator = act_queue.ActCoordinator.init(alloc);
    defer coordinator.deinit();

    // Use short cooldown (1s) for this test
    var watchdog = watchdog_mod.Watchdog.init(alloc, io, coordinator, .{
        .tracking_interval_s = 10,
        .act_timeout_secs = 5,
        .verbose_stderr = false,
        .escalation_cooldown_s = 1,
    });
    defer watchdog.deinit();
    watchdog.decision_fn = &mockDecisionKill;
    watchdog.force_kill_fn = &mockForceKillHook;

    coordinator.resetTurn();
    coordinator.updateStatus(1, .executing_tool, "bash: hung");

    // Exceed initial 5s timeout
    coordinator.lock();
    coordinator.state.act_start_ms -= 6000;
    coordinator.unlock();

    // First tick: LLM KILL decision triggers interrupt (not force_kill yet)
    g_force_kill_invoked = false;
    watchdog.tick();
    try testing.expect(coordinator.getMonitorState().is_timed_out);
    try testing.expect(signals.isInterrupted());
    try testing.expect(!g_force_kill_invoked); // force_kill only on escalation

    // Second tick: act still running past timeout -> triggers force_kill escalation
    watchdog.tick();
    try testing.expect(g_force_kill_invoked);

    // Third tick: should be suppressed by cooldown
    g_force_kill_invoked = false;
    watchdog.tick();
    try testing.expect(!g_force_kill_invoked);

    // After cooldown expires (manually expire):
    watchdog.last_escalation_ms = 0;
    watchdog.tick();
    try testing.expect(g_force_kill_invoked);
}
