//! test_subagent_wait_race.zig — Regression probe for the watchdog-SIGKILL /
//! child.wait BADF close race observed in production (src/tools/subagent.zig).
//!
//! PSEUDOCODE (mirrors subagent.executeTool exactly):
//! 1. spawnManaged(io, argv, null, .ignore, .pipe, .pipe) -> child (guardian
//!    process group on Linux production builds).
//! 2. Spawn stderr drain thread with raw std.Io.File (child.stderr).
//! 3. Worker drains stdout with raw std.Io.File (child.stdout).
//! 4. Watchdog thread: killAllTrackedProcesses(9) equivalent -> SIGKILL group.
//! 5. Worker joins stderr thread, then child.wait(io)  <- production panics
//!    here in childCleanupPosix closeFd(stderr) BADF.
//!
//! Run: zig build test-race   (add target in build.zig)  or
//!      zig run testcases/test_subagent_wait_race.zig [iterations]

const std = @import("std");
const builtin = @import("builtin");
const mini = @import("mini");

const process_manager = mini.process_manager;

fn drainAndStream(io: std.Io, pipe: std.Io.File, buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, tag: []const u8) void {
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = pipe.readStreaming(io, &.{&chunk}) catch break;
        if (n == 0) break;
        if (buf.items.len < 128 * 1024) buf.appendSlice(alloc, chunk[0..n]) catch break;
        _ = tag;
    }
}

fn drainStderrThread(io: std.Io, pipe: std.Io.File, buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator) void {
    drainAndStream(io, pipe, buf, alloc, "subagent:err");
}

/// Emulates the watchdog escalation: signal every tracked process group (same
/// as agent.zig watchdogForceKillHandler).
fn watchdogThread(pgid: i32) void {
    _ = process_manager.killAllTrackedProcesses(9);
    _ = pgid;
}

fn runOnce(io: std.Io, alloc: std.mem.Allocator) !void {
    const argv = [_][]const u8{ "/bin/sh", "-c", "echo stdout-line; echo stderr-line 1>&2; sleep 5" };
    var child = try process_manager.spawnManaged(io, &argv, null, .ignore, .pipe, .pipe);
    const managed_pid: i32 = @intCast(child.id.?);
    errdefer process_manager.abortManaged(io, &child);

    var stdout_buf = std.ArrayListUnmanaged(u8).empty;
    defer stdout_buf.deinit(alloc);
    var stderr_buf = std.ArrayListUnmanaged(u8).empty;
    defer stderr_buf.deinit(alloc);

    const stderr_thread = if (child.stderr) |err_pipe|
        std.Thread.spawn(.{}, drainStderrThread, .{ io, err_pipe, &stderr_buf, alloc }) catch null
    else
        null;

    if (child.stdout) |out_pipe| {
        drainAndStream(io, out_pipe, &stdout_buf, alloc, "subagent");
    }

    // Child is mid-"sleep 5"; escalate like the watchdog does.
    const wt = try std.Thread.spawn(.{}, watchdogThread, .{managed_pid});
    _ = wt.join();

    if (stderr_thread) |t| {
        t.join();
    }

    // Shipped subagent.executeTool path: close owned pipe fds on the owning
    // thread and null the Child fields so childCleanupPosix is a no-op.
    process_manager.closeOwnedPipes(&child);
    const term = try child.wait(io);
    process_manager.unregisterProcessGroup(managed_pid);
    _ = term;
}

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag != .linux) {
        std.debug.print("[SKIP] linux only\n", .{});
        return;
    }
    const io = init.io;
    const alloc = std.heap.page_allocator;
    const args = try init.minimal.args.toSlice(alloc);
    defer alloc.free(args);
    const iters: usize = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 300;

    for (0..iters) |i| {
        try runOnce(io, alloc);
        if (i % 25 == 0) std.debug.print("iter {d} ok\n", .{i});
    }
    std.debug.print("ALL OK ({d} iterations)\n", .{iters});
}
