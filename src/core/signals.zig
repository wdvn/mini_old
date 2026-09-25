//! signals.zig — OS signal handling (SIGINT/Ctrl+C) and interrupt coordination for mini-agent.
//!
//! Ensures that when the user presses Ctrl+C:
//! - Marks the atomic `interrupted` flag
//! - Interrupts HTTP streaming (SSE)
//! - Interrupts CodeAct Engine execution
//! - Preserves REPL process and returns to prompt instead of crashing/exiting abruptly.

const std = @import("std");
const builtin = @import("builtin");
const quickjs_engine = @import("../runtime/quickjs_engine.zig");
const process_manager = @import("../runtime/process_manager.zig");

pub var interrupted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
pub var active_engine: ?*quickjs_engine.Engine = null;

/// Check whether the current task was interrupted by Ctrl+C.
pub fn isInterrupted() bool {
    return interrupted.load(.acquire);
}

/// Set the interrupted flag state.
pub fn setInterrupted(val: bool) void {
    interrupted.store(val, .release);
}

/// Check and reset the interrupted flag to false (atomic swap).
pub fn checkAndResetInterrupted() bool {
    return interrupted.swap(false, .acq_rel);
}

/// Register currently running CodeAct Engine to interrupt upon receiving SIGINT.
pub fn registerActiveEngine(engine: ?*quickjs_engine.Engine) void {
    active_engine = engine;
}

fn handleSigInt(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    interrupted.store(true, .release);
    if (active_engine) |eng| {
        eng.requestInterrupt();
    }
}

fn handleTermination(sig: std.posix.SIG) callconv(.c) void {
    _ = process_manager.killAllTrackedProcesses(9);
    std.c._exit(128 + @as(c_int, @intCast(@intFromEnum(sig))));
}

/// Initialize and register OS signal handlers.
pub fn initSignalHandlers() void {
    if (comptime builtin.os.tag != .windows) {
        const act = std.posix.Sigaction{
            .handler = .{ .handler = handleSigInt },
            .mask = std.mem.zeroes(std.posix.sigset_t),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &act, null);
        const term_act = std.posix.Sigaction{
            .handler = .{ .handler = handleTermination },
            .mask = std.mem.zeroes(std.posix.sigset_t),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.TERM, &term_act, null);
        std.posix.sigaction(std.posix.SIG.HUP, &term_act, null);
    }
}

test "signals: atomic set and check" {
    setInterrupted(false);
    try std.testing.expect(!isInterrupted());

    setInterrupted(true);
    try std.testing.expect(isInterrupted());

    try std.testing.expect(checkAndResetInterrupted());
    try std.testing.expect(!isInterrupted());
}
