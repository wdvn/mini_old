//! test_mcp_pipe_race.zig — Regression test: per-server pipe mutex (McpServer.mu / closePipesOnce).
//!
//! Background: the watchdog/SIGINT thread and the agent worker thread could both
//! mutate McpServer child pipe fds concurrently (close fds / null child.stdin/stdout
//! cross-thread) while the worker was blocked in readStreaming on the same fds —
//! a cross-thread double-close / use-after-free race (a second close of an already
//! closed fd hits std Threaded backend's recoverableOsBugDetected BADF path).
//!
//! The kill path now only signals the child process; every fd close happens
//! exactly once, under the per-server mutex, from closePipesOnce on the owning
//! thread. This test exercises:
//!   1. Idempotency: closePipesOnce() twice → only the first call returns true,
//!      no double-close (no BADF).
//!   2. Concurrency: 8 threads hammer closePipesOnce() on the same server →
//!      exactly one returns true, the rest false, no crash.
//!
//! Run via `zig build test` (included in the tier-2 testcases bundle).

const std = @import("std");
const builtin = @import("builtin");
const mini = @import("mini");
const mcp_mod = mini.mcp_mod;

const testing = std.testing;
const File = std.Io.File;

const CloseWorkerArgs = struct {
    server: *mcp_mod.McpServer,
    index: usize,
    results: []bool,
};

fn closeWorkerThreadEntry(args: CloseWorkerArgs) void {
    args.results[args.index] = args.server.closePipesOnce();
}

fn makeServer(alloc: std.mem.Allocator, name: []const u8, read_fd: std.c.fd_t, write_fd: std.c.fd_t) !*mcp_mod.McpServer {
    const server = try alloc.create(mcp_mod.McpServer);
    server.* = .{
        .alloc = alloc,
        .name = try alloc.dupe(u8, name),
        .child = undefined,
        .child_pid = 0,
        .stdin_file = File{ .handle = write_fd, .flags = .{ .nonblocking = false } },
        .stdout_file = File{ .handle = read_fd, .flags = .{ .nonblocking = false } },
        .tools = .empty,
    };
    return server;
}

test "mcp closePipesOnce: idempotent and thread-safe" {
    if (comptime builtin.os.tag == .windows) return;

    // closePipesOnce routes fd close through main.g_io — must be a valid Io in test mode.
    mini.g_io = std.testing.io;
    const alloc = testing.allocator;

    // 1. Idempotency: two real pipe pairs; first close returns true, second false.
    {
        var fds: [2]std.c.fd_t = undefined;
        if (std.c.pipe(&fds) != 0) return error.TestError;

        const server = try makeServer(alloc, "mcp-test-a", fds[0], fds[1]);
        defer {
            alloc.free(server.name);
            alloc.destroy(server);
        }

        try testing.expect(server.closePipesOnce() == true);
        try testing.expect(server.closePipesOnce() == false);

        // Both ends must now be closed: re-close reports BADF.
        try testing.expect(std.posix.errno(std.c.close(fds[0])) == .BADF);
        try testing.expect(std.posix.errno(std.c.close(fds[1])) == .BADF);
    }

    // 2. Concurrency: 8 threads race closePipesOnce on one server → exactly one true.
    {
        var fds: [2]std.c.fd_t = undefined;
        if (std.c.pipe(&fds) != 0) return error.TestError;

        const server = try makeServer(alloc, "mcp-test-b", fds[0], fds[1]);
        defer {
            alloc.free(server.name);
            alloc.destroy(server);
        }

        const n_threads: usize = 8;
        const results = try alloc.alloc(bool, n_threads);
        defer alloc.free(results);
        for (results) |*r| r.* = false;

        var threads: [n_threads]std.Thread = undefined;
        for (0..n_threads) |i| {
            const wargs = CloseWorkerArgs{
                .server = server,
                .index = @intCast(i),
                .results = results,
            };
            threads[i] = try std.Thread.spawn(.{}, closeWorkerThreadEntry, .{ wargs });
        }
        var true_count: usize = 0;
        for (0..n_threads) |i| {
            threads[i].join();
            if (results[i]) true_count += 1;
        }
        try testing.expect(true_count == 1);

        // Exactly-once close: re-close reports BADF on both ends.
        try testing.expect(std.posix.errno(std.c.close(fds[0])) == .BADF);
        try testing.expect(std.posix.errno(std.c.close(fds[1])) == .BADF);
    }
}
