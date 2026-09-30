//! tools/subagent.zig — Subagent invocation tool.
//!
//! Spawns `mini -e <task>` with stdout/stderr pipes, reads both streams concurrently
//! (avoiding pipe deadlocks if child writes extensively) and STREAMS each line
//! to the parent's stderr prefixed with `[subagent]` so the user observes inner progress
//! rather than suspecting a hang.
//! The full output is buffered and returned as the tool result for the LLM.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../core/json.zig");
const main = @import("../main.zig");
const signals_mod = @import("../core/signals.zig");
const process_manager = @import("../runtime/process_manager.zig");

/// Maximum default subagent depth allowed to prevent infinite recursion.
pub const DEFAULT_MAX_SUBAGENT_DEPTH: usize = 2;

/// Maximum output buffer limit (bytes) retained for tool results.
const MAX_OUTPUT = 128 * 1024;

/// Retrieve current subagent recursion depth from environment.
pub fn getCurrentDepth() usize {
    if (main.getEnvironMap()) |em| {
        if (em.get("MINI_SUBAGENT_DEPTH")) |v| {
            return std.fmt.parseInt(usize, v, 10) catch 0;
        }
    }
    return 0;
}

/// Retrieve maximum allowed subagent depth from configuration or default.
pub fn getMaxDepth() usize {
    if (main.getEnvironMap()) |em| {
        if (em.get("MINI_MAX_SUBAGENT_DEPTH")) |v| {
            return std.fmt.parseInt(usize, v, 10) catch DEFAULT_MAX_SUBAGENT_DEPTH;
        }
    }
    return DEFAULT_MAX_SUBAGENT_DEPTH;
}

fn resolveSubagentTask(alloc: Allocator, input_json: []const u8) !?[]u8 {
    // PSEUDOCODE: Extract task description from task, prompt, instruction, or description field.
    return (try json.findStringOwned(alloc, input_json, "task")) orelse
        (try json.findStringOwned(alloc, input_json, "prompt")) orelse
        (try json.findStringOwned(alloc, input_json, "instruction")) orelse
        (try json.findStringOwned(alloc, input_json, "description"));
}

fn drainChildPipes(io: std.Io, alloc: Allocator, child: *std.process.Child, stdout_buf: *std.ArrayListUnmanaged(u8), stderr_buf: *std.ArrayListUnmanaged(u8)) void {
    // PSEUDOCODE: Concurrently drain stderr in background thread while reading stdout in main thread.
    const stderr_thread = if (child.stderr) |err_pipe|
        std.Thread.spawn(.{}, drainAndStreamStderr, .{ io, err_pipe, stderr_buf, alloc }) catch null
    else
        null;

    if (child.stdout) |out_pipe| {
        _ = drainAndStream(io, out_pipe, stdout_buf, alloc, "subagent");
    }

    if (stderr_thread) |t| {
        t.join();
    } else if (child.stderr) |err_pipe| {
        _ = drainAndStream(io, err_pipe, stderr_buf, alloc, "subagent:err");
    }
}

fn formatSubagentResult(alloc: Allocator, term: std.process.Child.Term, stdout_buf: []const u8, stderr_buf: []const u8) ![]u8 {
    // PSEUDOCODE: Format result message based on termination status and captured output.
    switch (term) {
        .exited => |code| {
            if (code != 0) {
                const err_detail = if (stderr_buf.len > 0) stderr_buf else stdout_buf;
                return std.fmt.allocPrint(alloc, "Subagent terminated with error code: {d}. Details: {s}", .{ code, err_detail });
            }
        },
        else => {
            const err_detail = if (stderr_buf.len > 0) stderr_buf else stdout_buf;
            return std.fmt.allocPrint(alloc, "Subagent crashed or was killed. Details: {s}", .{err_detail});
        },
    }

    if (stdout_buf.len == 0) {
        return std.fmt.allocPrint(alloc, "Subagent completed successfully but returned no content.", .{});
    }
    return alloc.dupe(u8, stdout_buf);
}

pub fn executeTool(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    // PSEUDOCODE:
    // 1. Guard against exceeding maximum subagent depth.
    // 2. Extract task string and propagate depth in environment.
    // 3. Spawn child mini process and drain pipes concurrently.
    // 4. Format and return outcome.
    const current_depth = getCurrentDepth();
    const max_depth = getMaxDepth();
    if (current_depth >= max_depth) {
        return std.fmt.allocPrint(alloc, "Error: Maximum subagent depth limit reached (depth={d}/{d}). Cannot spawn further subagents.", .{ current_depth, max_depth });
    }

    const task = (try resolveSubagentTask(alloc, input_json)) orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'task' parameter", .{});
    defer alloc.free(task);

    var depth_buf: [16]u8 = undefined;
    const next_depth_str = std.fmt.bufPrintZ(&depth_buf, "{d}", .{current_depth + 1}) catch "1";
    const env_map = main.getEnvironMap();
    const prev_depth = if (env_map) |em| em.get("MINI_SUBAGENT_DEPTH") else null;
    if (env_map) |em| em.put("MINI_SUBAGENT_DEPTH", next_depth_str) catch {};
    defer {
        if (env_map) |em| em.put("MINI_SUBAGENT_DEPTH", prev_depth orelse "0") catch {};
    }

    // PSEUDOCODE: Spawn the subagent in a dedicated managed process group.
    const argv = [_][]const u8{ "/proc/self/exe", "-e", task };
    var child = try process_manager.spawnManaged(
        io,
        &argv,
        env_map,
        .ignore,
        .pipe,
        .pipe,
    );
    const managed_pid = if (child.id) |pid| @as(i32, @intCast(pid)) else 0;
    errdefer process_manager.abortManaged(io, &child);

    var stdout_buf = std.ArrayListUnmanaged(u8).empty;
    defer stdout_buf.deinit(alloc);
    var stderr_buf = std.ArrayListUnmanaged(u8).empty;
    defer stderr_buf.deinit(alloc);

    drainChildPipes(io, alloc, &child, &stdout_buf, &stderr_buf);
    // Close the child's owned pipe fds on the owning thread BEFORE child.wait,
    // so the stdlib's childCleanupPosix will not re-close an already-released
    // fd (a double close trips std.Io.Threaded's use-after-free detector and
    // panics with BADF when a cross-thread drain read the pipe to EOF).
    process_manager.closeOwnedPipes(&child);
    const term = child.wait(io) catch |e| {
        if (signals_mod.isInterrupted()) return error.Interrupted;
        return e;
    };
    process_manager.unregisterProcessGroup(managed_pid);
    return formatSubagentResult(alloc, term, stdout_buf.items, stderr_buf.items);
}

// ---------------------------------------------------------------------------
// Concurrent pipe I/O + real-time streaming
// ---------------------------------------------------------------------------

/// Reads pipe concurrently, appends into buffer (capped at MAX_OUTPUT, excess drained)
/// and streams completed lines to parent's stderr prefixed with `tag`.
fn drainAndStream(io: std.Io, pipe: std.Io.File, buf: *std.ArrayListUnmanaged(u8), alloc: Allocator, tag: []const u8) void {
    var line_buf: [4096]u8 = undefined;
    var line_len: usize = 0;
    var stored: usize = 0;

    while (true) {
        var chunk: [4096]u8 = undefined;
        const n = pipe.readStreaming(io, &.{&chunk}) catch break;
        if (n == 0) break;

        // Keep buffer bounded up to MAX_OUTPUT; remainder still drained so child doesn't block.
        if (stored < MAX_OUTPUT) {
            const room = MAX_OUTPUT - stored;
            const take = @min(room, n);
            buf.appendSlice(alloc, chunk[0..take]) catch break;
            stored += take;
        }

        // Real-time stream: aggregate chunks into lines, print completed lines with prefix.
        for (chunk[0..n]) |c| {
            if (c == '\n') {
                emitLine(tag, line_buf[0..line_len]);
                line_len = 0;
            } else if (line_len < line_buf.len) {
                line_buf[line_len] = c;
                line_len += 1;
            }
        }
    }

    // Flush last line if no trailing newline.
    if (line_len > 0) {
        emitLine(tag, line_buf[0..line_len]);
    }
}

/// Wrapper for stderr reader thread — matching Thread.spawn signature.
fn drainAndStreamStderr(io: std.Io, pipe: std.Io.File, buf: *std.ArrayListUnmanaged(u8), alloc: Allocator) void {
    drainAndStream(io, pipe, buf, alloc, "subagent:err");
}

/// Print one subagent output line to parent's stderr with dim prefix.
fn emitLine(tag: []const u8, line: []const u8) void {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return;

    var truncated_buf: [512]u8 = undefined;
    const display = if (trimmed.len > 500) blk: {
        const n = std.fmt.bufPrint(&truncated_buf, "{s}...", .{trimmed[0..500]}) catch trimmed;
        break :blk n;
    } else trimmed;

    if (std.mem.eql(u8, tag, "subagent:err")) {
        main.stderrPrint("\x1b[2;90m[subagent:err]\x1b[0m {s}\n", .{display});
    } else {
        main.stderrPrint("\x1b[2;90m[subagent]\x1b[0m {s}\n", .{display});
    }
}

// ---------------------------------------------------------------------------
// Unit Tests
// ---------------------------------------------------------------------------

test "subagent: depth check logic" {
    const testing = std.testing;

    const env_map = main.getEnvironMap();
    if (env_map == null) return error.SkipZigTest;

    const em = env_map.?;
    const prev_depth = em.get("MINI_SUBAGENT_DEPTH");
    const prev_max = em.get("MINI_MAX_SUBAGENT_DEPTH");

    em.put("MINI_SUBAGENT_DEPTH", "2") catch {};
    em.put("MINI_MAX_SUBAGENT_DEPTH", "2") catch {};
    defer {
        if (prev_depth) |v| em.put("MINI_SUBAGENT_DEPTH", v) catch {} else em.put("MINI_SUBAGENT_DEPTH", "0") catch {};
        if (prev_max) |v| em.put("MINI_MAX_SUBAGENT_DEPTH", v) catch {} else em.put("MINI_MAX_SUBAGENT_DEPTH", "0") catch {};
    }

    try testing.expectEqual(@as(usize, 2), getCurrentDepth());
    try testing.expectEqual(@as(usize, 2), getMaxDepth());

    const res = try executeTool(testing.allocator, main.getIo(), "{\"task\":\"test infinite loop\"}");
    defer testing.allocator.free(res);

    try testing.expect(std.mem.indexOf(u8, res, "Maximum subagent depth limit reached") != null);
}
