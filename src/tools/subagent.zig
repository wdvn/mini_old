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

pub fn executeTool(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    const current_depth = getCurrentDepth();
    const max_depth = getMaxDepth();

    if (current_depth >= max_depth) {
        return std.fmt.allocPrint(alloc, "Error: Maximum subagent depth limit reached (depth={d}/{d}). Cannot spawn further subagents.", .{ current_depth, max_depth });
    }

    const task = (try json.findStringOwned(alloc, input_json, "task")) orelse
        (try json.findStringOwned(alloc, input_json, "prompt")) orelse
        (try json.findStringOwned(alloc, input_json, "instruction")) orelse
        (try json.findStringOwned(alloc, input_json, "description")) orelse {
        return std.fmt.allocPrint(alloc, "Error: missing 'task' parameter", .{});
    };
    defer alloc.free(task);

    // Set depth for child process inheritance via environ_map passed into spawn.
    var depth_buf: [16]u8 = undefined;
    const next_depth_str = std.fmt.bufPrintZ(&depth_buf, "{d}", .{current_depth + 1}) catch "1";
    const env_map = main.getEnvironMap();
    const prev_depth = if (env_map) |em| em.get("MINI_SUBAGENT_DEPTH") else null;
    if (env_map) |em| {
        em.put("MINI_SUBAGENT_DEPTH", next_depth_str) catch {};
    }
    defer {
        if (env_map) |em| {
            // Restore previous value; if absent, set "0" (not a subagent).
            const restore = prev_depth orelse "0";
            em.put("MINI_SUBAGENT_DEPTH", restore) catch {};
        }
    }

    const exe_path = "/proc/self/exe";
    const argv = [_][]const u8{ exe_path, "-e", task };

    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdout = .pipe,
        .stderr = .pipe,
        .stdin = .ignore,
        .environ_map = env_map,
    });

    // Buffer complete output for the agent (bounded by MAX_OUTPUT, excess drained).
    var stdout_buf = std.ArrayListUnmanaged(u8).empty;
    defer stdout_buf.deinit(alloc);
    var stderr_buf = std.ArrayListUnmanaged(u8).empty;
    defer stderr_buf.deinit(alloc);

    // Concurrently read stderr alongside stdout to avoid pipe deadlock.
    const stderr_thread = if (child.stderr) |err_pipe|
        std.Thread.spawn(.{}, drainAndStreamStderr, .{ io, err_pipe, &stderr_buf, alloc }) catch null
    else
        null;

    // Main thread reads + streams stdout.
    if (child.stdout) |out_pipe| {
        _ = drainAndStream(io, out_pipe, &stdout_buf, alloc, "subagent");
    }

    // Await stderr thread completion.
    if (stderr_thread) |t| {
        t.join();
    } else if (child.stderr) |err_pipe| {
        _ = drainAndStream(io, err_pipe, &stderr_buf, alloc, "subagent:err");
    }

    const term = try child.wait(io);

    switch (term) {
        .exited => |code| {
            if (code != 0) {
                const err_detail = if (stderr_buf.items.len > 0) stderr_buf.items else stdout_buf.items;
                return std.fmt.allocPrint(alloc, "Subagent terminated with error code: {d}. Details: {s}", .{ code, err_detail });
            }
        },
        else => {
            const err_detail = if (stderr_buf.items.len > 0) stderr_buf.items else stdout_buf.items;
            return std.fmt.allocPrint(alloc, "Subagent crashed or was killed. Details: {s}", .{err_detail});
        },
    }

    if (stdout_buf.items.len == 0) {
        return std.fmt.allocPrint(alloc, "Subagent completed successfully but returned no content.", .{});
    }

    return alloc.dupe(u8, stdout_buf.items);
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
