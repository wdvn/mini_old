//! tools/bash.zig — Shell command execution tool.
//!
//! Runs shell commands via `/bin/sh -c` and returns stdout + stderr.
//! Includes safety checks to block hazardous commands.
//!
//! ## Concurrent I/O
//! Uses a dedicated thread to read stderr concurrently with stdout, avoiding deadlock
//! when a child process writes significant data to both pipes simultaneously.
//! Pipes are drained completely (excess discarded) so the child never blocks.
//!
//! ## Safety blocklist
//! The following patterns are unconditionally blocked:
//!   - `rm -rf /` or `rm -rf ~`
//!   - `dd if=`, `mkfs`, `wipefs`
//!   - `shutdown`, `reboot`, `halt`, `init 0`, `init 6`
//!   - `git push --force`, `git push -f`
//!
//! ## Tool input schema
//! ```json
//! { "command": "ls -la /tmp" }
//! ```
//!
//! ## Limits
//!   - Output truncated at 128KB
//!   - Working directory: process CWD

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const json = @import("../core/json.zig");
const utils = @import("../core/utils.zig");
const main = @import("../main.zig");
const hooks = @import("../core/hooks.zig");

var g_active_pid: std.atomic.Value(std.process.Child.Id) = std.atomic.Value(std.process.Child.Id).init(0);

/// Interrupt the currently executing bash child process (if any).
pub fn interruptCurrent() void {
    const pid = g_active_pid.swap(0, .acq_rel);
    if (pid > 0) {
        if (comptime builtin.os.tag != .windows) {
            _ = std.posix.kill(pid, std.posix.SIG.TERM) catch {};
        }
    }
}

/// List of blocked command patterns.
const BLOCKED_PATTERNS = [_][]const u8{
    "rm -rf /",
    "rm -rf ~",
    "dd if=",
    "mkfs",
    "wipefs",
    "shutdown",
    "reboot",
    "halt",
    "init 0",
    "init 6",
    "git push --force",
    "git push -f",
    "git reset --hard",
    "git clean -f",
};

/// Output buffer limit (bytes). Heap-allocated.
const MAX_OUTPUT = 128 * 1024;

/// Execute the bash tool.
/// Input: JSON string with "command" field.
/// Output: stdout/stderr of command, or error message.
pub fn executeTool(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    // Unescape JSON string: command containing \" \n must become literals
    // before being passed to /bin/sh.
    const command = (try json.findStringOwned(alloc, input_json, "command")) orelse
        (try json.findStringOwned(alloc, input_json, "cmd")) orelse
        (try json.findStringOwned(alloc, input_json, "script")) orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'command' parameter", .{});
    defer alloc.free(command);

    // Safety check
    for (&BLOCKED_PATTERNS) |pattern| {
        if (std.mem.indexOf(u8, command, pattern) != null) {
            return std.fmt.allocPrint(alloc,
                "BLOCKED: Command blocked by safety policy.\nCommand: {s}\nPattern: {s}",
                .{ command, pattern },
            );
        }
    }

    const stdin_str = try json.findStringOwned(alloc, input_json, "stdin");
    defer if (stdin_str) |s| alloc.free(s);

    return executeCommand(alloc, io, command, stdin_str);
}

// ---------------------------------------------------------------------------
// Concurrent pipe I/O
// ---------------------------------------------------------------------------

/// Drain pipe completely into buffer. Retain at most first buf.len bytes.
/// Excess data is drained so child process does not block on pipe.
fn drainPipe(io: std.Io, pipe: std.Io.File, buf: []u8) usize {
    var stored: usize = 0;
    while (true) {
        if (stored < buf.len) {
            // Buffer has room — read into buffer
            const n = pipe.readStreaming(io, &.{buf[stored..]}) catch break;
            if (n == 0) break;
            hooks.appendExecutionOutput(buf[stored .. stored + n]);
            stored += n;
        } else {
            // Buffer full — drain remainder to prevent deadlock
            var sink: [4096]u8 = undefined;
            const n = pipe.readStreaming(io, &.{&sink}) catch break;
            if (n == 0) break;
            hooks.appendExecutionOutput(sink[0..n]);
        }
    }
    return stored;
}

/// Wrapper for stderr thread — matching Thread.spawn signature.
fn drainStderrThread(io: std.Io, pipe: std.Io.File, buf: []u8, len_out: *usize) void {
    len_out.* = drainPipe(io, pipe, buf);
}

// ---------------------------------------------------------------------------
// Command execution
// ---------------------------------------------------------------------------

test "bash tool: command JSON escape unescaped before execution" {
    const alloc = std.testing.allocator;
    const input = "{\"command\":\"echo \\\"hello world\\\"\"}";
    const res = try executeTool(alloc, main.getIo(), input);
    defer alloc.free(res);
    try std.testing.expectEqualStrings("hello world", std.mem.trim(u8, res, " \n\r\t\""));
}

/// Run shell command and collect output.
/// Uses separate thread to read stderr concurrently with stdout to avoid pipe deadlock.
/// Buffers are heap-allocated (128KB per stream).
fn executeCommand(alloc: Allocator, io: std.Io, command: []const u8, stdin_str: ?[]const u8) ![]u8 {
    const argv = [_][]const u8{ "/bin/sh", "-c", command };
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = if (stdin_str != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    if (child.id) |pid| {
        g_active_pid.store(pid, .release);
    }
    defer g_active_pid.store(0, .release);

    if (stdin_str) |s| {
        if (child.stdin) |in_pipe| {
            try in_pipe.writeStreamingAll(io, s);
            in_pipe.close(io);
            child.stdin = null;
        }
    }

    // Heap-allocate buffers
    const stdout_buf = try alloc.alloc(u8, MAX_OUTPUT);
    defer alloc.free(stdout_buf);
    const stderr_buf = try alloc.alloc(u8, MAX_OUTPUT);
    defer alloc.free(stderr_buf);

    var stdolen: usize = 0;
    var stdelen: usize = 0;

    // Spawn thread to read stderr concurrently
    const stderr_thread = if (child.stderr) |err_pipe|
        std.Thread.spawn(.{}, drainStderrThread, .{ io, err_pipe, stderr_buf, &stdelen }) catch null
    else
        null;

    // Main thread reads stdout
    if (child.stdout) |out_pipe| {
        stdolen = drainPipe(io, out_pipe, stdout_buf);
    }

    // Await stderr thread completion
    if (stderr_thread) |t| {
        t.join();
    } else if (child.stderr) |err_pipe| {
        // Fallback sequential if thread spawn fails
        stdelen = drainPipe(io, err_pipe, stderr_buf);
    }

    // Await child process termination after draining pipes
    const term = child.wait(io) catch |e| {
        return std.fmt.allocPrint(alloc, "Wait error: {s}", .{@errorName(e)});
    };

    const exit_code: u8 = switch (term) {
        .exited => |code| code,
        .signal => |sig| {
            return std.fmt.allocPrint(alloc, "Killed by signal {d}", .{@intFromEnum(sig)});
        },
        else => 1,
    };

    // Build result
    var result = utils.BufWriter.init(alloc);
    errdefer result.deinit();
    const w = &result;

    if (stdolen > 0) {
        try w.writeAll(stdout_buf[0..stdolen]);
    }
    if (stdelen > 0) {
        if (stdolen > 0) try w.writeByte('\n');
        try w.writeAll(stderr_buf[0..stdelen]);
    }
    if (exit_code != 0 and result.list.items.len == 0) {
        try w.print("Exit code: {d}", .{exit_code});
    }
    if (result.list.items.len == 0) {
        try w.writeAll("(no output)");
    }

    return result.toOwnedSlice();
}
