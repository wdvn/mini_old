//! test_process_parent_death.zig — Regression test for managed-process parent death cleanup.

const std = @import("std");
const builtin = @import("builtin");

extern "c" fn kill(pid: std.c.pid_t, sig: c_int) c_int;

const Status = enum { passed, failed };

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag != .linux) {
        try writeLine(init.io, "[SKIP] parent-death protection is Linux-specific\n");
        return;
    }

    const alloc = std.heap.page_allocator;
    const args = try init.minimal.args.toSlice(alloc);
    defer alloc.free(args);
    if (args.len < 2) return error.MissingMiniBinaryPath;

    const mini_bin = args[1];
    const io = init.io;
    const pid_path = try std.fmt.allocPrint(alloc, "/tmp/mini_parent_death_{d}.pid", .{std.c.getpid()});
    defer alloc.free(pid_path);
    defer std.Io.Dir.cwd().deleteFile(io, pid_path) catch {};

    const script =
        \\"$1" --__process-guardian -- /bin/sh -c 'sleep 30 & child=$!; printf "%s" "$child" > "$1"; wait' sh "$2"
        \\sleep 30
    ;
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "mini-parent-death", mini_bin, pid_path };
    var parent = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const parent_pid = parent.id orelse return error.MissingParentPid;
    errdefer {
        std.posix.kill(parent_pid, .KILL) catch {};
        _ = parent.wait(io) catch {};
    }

    var descendant_pid: ?std.posix.pid_t = null;
    for (0..100) |_| {
        const contents = std.Io.Dir.cwd().readFileAlloc(io, pid_path, alloc, .limited(32)) catch |err| switch (err) {
            error.FileNotFound => {
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .awake) catch {};
                continue;
            },
            else => return err,
        };
        if (contents.len > 0) {
            descendant_pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, contents, " \t\r\n"), 10);
            alloc.free(contents);
            break;
        }
        alloc.free(contents);
    }
    const pid = descendant_pid orelse {
        try writeLine(io, "[FAIL] managed guardian did not start its descendant\n");
        return;
    };
    errdefer std.posix.kill(pid, .KILL) catch {};

    try std.posix.kill(parent_pid, .KILL);
    _ = parent.wait(io) catch {};

    var result: Status = .failed;
    for (0..100) |_| {
        if (kill(pid, 0) != 0) {
            result = .passed;
            break;
        }
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .awake) catch {};
    }

    switch (result) {
        .passed => try writeLine(io, "[PASS] managed descendant terminated after parent SIGKILL\n"),
        .failed => {
            const message = try std.fmt.allocPrint(alloc, "[FAIL] managed descendant {d} survived parent SIGKILL\n", .{pid});
            defer alloc.free(message);
            try std.Io.File.stderr().writeStreamingAll(io, message);
            return error.ManagedDescendantLeaked;
        },
    }
}

fn writeLine(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}
