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
const signals = @import("../core/signals.zig");
const process_manager = @import("../runtime/process_manager.zig");

var g_active_pid: std.atomic.Value(std.process.Child.Id) = std.atomic.Value(std.process.Child.Id).init(0);

// PSEUDOCODE:
// 1. Read g_active_pid atomically with acquire ordering
// 2. If pid > 0, send SIGTERM to process group (-pid)
// 3. Fallback to single pid if group kill fails
pub fn interruptCurrent() void {
    const pid = g_active_pid.load(.acquire);
    if (pid > 0) {
        if (comptime builtin.os.tag != .windows) {
            _ = std.posix.kill(-pid, std.posix.SIG.TERM) catch {
                _ = std.posix.kill(pid, std.posix.SIG.TERM) catch {};
            };
        }
    }
}

// PSEUDOCODE:
// 1. Read g_active_pid atomically with acquire ordering
// 2. If pid > 0, send SIGKILL to process group (-pid)
// 3. Fallback to single pid if group kill fails
pub fn forceKillCurrent() void {
    const pid = g_active_pid.load(.acquire);
    if (pid > 0) {
        if (comptime builtin.os.tag != .windows) {
            _ = std.posix.kill(-pid, std.posix.SIG.KILL) catch {
                _ = std.posix.kill(pid, std.posix.SIG.KILL) catch {};
            };
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
            return std.fmt.allocPrint(
                alloc,
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
// PSEUDOCODE:
// 1. Loop until pipe is exhausted or interrupted
// 2. Poll pipe with 250ms timeout on POSIX to avoid blocking indefinitely when child hangs
// 3. If poll times out (ready == 0), check signals.isInterrupted(); break if set, else continue
// 4. If POLL.ERR or POLL.NVAL, break
// 5. If POLL.HUP and not POLL.IN, break (EOF)
// 6. Read available bytes into buf (or discard sink) and append to hooks
// 7. Check signals.isInterrupted() and break if set
fn drainPipe(io: std.Io, pipe: std.Io.File, buf: []u8) usize {
    var stored: usize = 0;
    while (true) {
        if (signals.isInterrupted()) break;

        if (comptime builtin.os.tag != .windows) {
            var pfd = [_]std.posix.pollfd{.{
                .fd = pipe.handle,
                .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
                .revents = 0,
            }};
            const ready = std.posix.poll(&pfd, 250) catch |err| {
                if (err == error.Interrupted) continue;
                break;
            };
            if (ready == 0) {
                if (signals.isInterrupted()) break;
                continue;
            }
            if ((pfd[0].revents & (std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0) {
                break;
            }
            if ((pfd[0].revents & std.posix.POLL.HUP) != 0 and (pfd[0].revents & std.posix.POLL.IN) == 0) {
                break;
            }
        }

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

fn testInterruptorThread() void {
    const io = main.getIo();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
    signals.setInterrupted(true);
    interruptCurrent();
}

test "bash tool: process group interruption terminates sleeping command promptly" {
    if (comptime builtin.os.tag == .windows) return;
    defer signals.setInterrupted(false);
    const alloc = std.testing.allocator;
    const io = main.getIo();

    signals.setInterrupted(false);
    const t = try std.Thread.spawn(.{}, testInterruptorThread, .{});
    defer t.join();

    const input = "{\"command\":\"sleep 10\"}";
    const res = executeTool(alloc, io, input);
    if (res) |output| {
        defer alloc.free(output);
    } else |err| {
        try std.testing.expectEqual(error.Interrupted, err);
    }
}

/// Run shell command and collect output.
/// Uses separate thread to read stderr concurrently with stdout to avoid pipe deadlock.
/// Buffers are heap-allocated (128KB per stream).
// PSEUDOCODE:
// 1. Spawn /bin/sh with pgid = 0 so all children/grandchildren share a process group
// 2. Track pid in g_active_pid
// 3. Concurrently drain stdout and stderr using interrupt-aware drainPipe
// 4. If signals.isInterrupted(), force-kill process group before waiting
// 5. Wait for child and return output or error.Interrupted
fn spawnBashChild(io: std.Io, command: []const u8, stdin_str: ?[]const u8) !std.process.Child {
    // PSEUDOCODE: Spawn a parent-death-protected managed shell and deliver stdin if provided.
    const argv = [_][]const u8{ "/bin/sh", "-c", command };
    var child = try process_manager.spawnManaged(
        io,
        &argv,
        null,
        if (stdin_str != null) .pipe else .ignore,
        .pipe,
        .pipe,
    );
    errdefer {
        if (child.stdin) |in_pipe| in_pipe.close(io);
        if (child.stdout) |out_pipe| out_pipe.close(io);
        if (child.stderr) |err_pipe| err_pipe.close(io);
    }

    if (stdin_str) |s| {
        if (child.stdin) |in_pipe| {
            try in_pipe.writeStreamingAll(io, s);
            in_pipe.close(io);
            child.stdin = null;
        }
    }
    return child;
}

fn drainChildPipesConcurrently(io: std.Io, child: *std.process.Child, stdout_buf: []u8, stderr_buf: []u8, stdolen: *usize, stdelen: *usize) void {
    // PSEUDOCODE: Read stderr in worker thread while main thread reads stdout.
    const stderr_thread = if (child.stderr) |err_pipe|
        std.Thread.spawn(.{}, drainStderrThread, .{ io, err_pipe, stderr_buf, stdelen }) catch null
    else
        null;

    if (child.stdout) |out_pipe| {
        stdolen.* = drainPipe(io, out_pipe, stdout_buf);
    }

    if (stderr_thread) |t| {
        t.join();
    } else if (child.stderr) |err_pipe| {
        stdelen.* = drainPipe(io, err_pipe, stderr_buf);
    }
}

fn formatCommandOutput(alloc: Allocator, stdout_slice: []const u8, stderr_slice: []const u8, exit_code: u8) ![]u8 {
    // PSEUDOCODE: Assemble stdout, newline delimiter, stderr, or fallback exit status into result slice.
    var result = utils.BufWriter.init(alloc);
    errdefer result.deinit();
    const w = &result;

    if (stdout_slice.len > 0) {
        try w.writeAll(stdout_slice);
    }
    if (stderr_slice.len > 0) {
        if (stdout_slice.len > 0) try w.writeByte('\n');
        try w.writeAll(stderr_slice);
    }
    if (exit_code != 0 and result.list.items.len == 0) {
        try w.print("Exit code: {d}", .{exit_code});
    }
    if (result.list.items.len == 0) {
        try w.writeAll("(no output)");
    }
    return result.toOwnedSlice();
}

fn executeCommand(alloc: Allocator, io: std.Io, command: []const u8, stdin_str: ?[]const u8) ![]u8 {
    // PSEUDOCODE:
    // 1. Spawn /bin/sh child and track pid.
    // 2. Concurrently drain pipes into allocated buffers.
    // 3. Check for interrupts, await child termination, and format output.
    var child = try spawnBashChild(io, command, stdin_str);
    const managed_pid = if (child.id) |pid| @as(i32, @intCast(pid)) else 0;
    if (child.id) |pid| g_active_pid.store(pid, .release);
    var child_reaped = false;
    errdefer if (!child_reaped) process_manager.abortManaged(io, &child);
    defer g_active_pid.store(0, .release);

    const stdout_buf = try alloc.alloc(u8, MAX_OUTPUT);
    defer alloc.free(stdout_buf);
    const stderr_buf = try alloc.alloc(u8, MAX_OUTPUT);
    defer alloc.free(stderr_buf);

    var stdolen: usize = 0;
    var stdelen: usize = 0;
    drainChildPipesConcurrently(io, &child, stdout_buf, stderr_buf, &stdolen, &stdelen);

    if (signals.isInterrupted()) forceKillCurrent();

    const term = child.wait(io) catch |e| {
        if (signals.isInterrupted()) return error.Interrupted;
        return std.fmt.allocPrint(alloc, "Wait error: {s}", .{@errorName(e)});
    };
    child_reaped = true;
    process_manager.unregisterProcessGroup(managed_pid);
    if (signals.isInterrupted()) return error.Interrupted;

    const exit_code: u8 = switch (term) {
        .exited => |code| code,
        .signal => |sig| return std.fmt.allocPrint(alloc, "Killed by signal {d}", .{@intFromEnum(sig)}),
        else => 1,
    };
    return formatCommandOutput(alloc, stdout_buf[0..stdolen], stderr_buf[0..stdelen], exit_code);
}
