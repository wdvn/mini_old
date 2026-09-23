//! tools/batch_subagent.zig — Run multiple subagents in parallel.

const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("../core/utils.zig");
const subagent = @import("subagent.zig");
const main = @import("../main.zig");

// Thread worker context
const WorkerContext = struct {
    alloc: Allocator,
    io: std.Io,
    task: []const u8,
    result: ?[]const u8,
    error_msg: ?[]const u8,
    index: usize,
};

fn drainPipe(io: std.Io, alloc: Allocator, pipe_opt: ?std.Io.File, buf: *std.ArrayListUnmanaged(u8)) void {
    // PSEUDOCODE: Read streaming chunks from pipe into unmanaged buffer.
    const pipe = pipe_opt orelse return;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = pipe.readStreaming(io, &.{&chunk}) catch break;
        if (n == 0) break;
        buf.appendSlice(alloc, chunk[0..n]) catch break;
    }
}

fn evaluateChildTerm(ctx: *WorkerContext, term: std.process.Child.Term, stdout_buf: []const u8, stderr_buf: []const u8) void {
    // PSEUDOCODE: Assign ctx.result on zero exit code, or format ctx.error_msg.
    switch (term) {
        .exited => |code| {
            if (code != 0) {
                const err_detail = if (stderr_buf.len > 0) stderr_buf else stdout_buf;
                ctx.error_msg = std.fmt.allocPrint(ctx.alloc, "Error exit code {d}: {s}", .{ code, err_detail }) catch null;
            } else {
                ctx.result = ctx.alloc.dupe(u8, stdout_buf) catch null;
            }
        },
        else => {
            const err_detail = if (stderr_buf.len > 0) stderr_buf else stdout_buf;
            ctx.error_msg = std.fmt.allocPrint(ctx.alloc, "Crashed or killed. Details: {s}", .{err_detail}) catch null;
        },
    }
}

fn runSubAgentThread(ctx: *WorkerContext) void {
    // PSEUDOCODE:
    // 1. Spawn subagent child process.
    // 2. Drain stdout and stderr pipes via drainPipe.
    // 3. Await process exit and evaluate termination status.
    const argv = [_][]const u8{ "/proc/self/exe", "-e", ctx.task };
    var child = std.process.spawn(ctx.io, .{
        .argv = &argv,
        .stdout = .pipe,
        .stderr = .pipe,
        .stdin = .ignore,
        .environ_map = main.getEnvironMap(),
    }) catch |e| {
        ctx.error_msg = std.fmt.allocPrint(ctx.alloc, "Spawn error: {s}", .{@errorName(e)}) catch null;
        return;
    };

    var stdout_buf = std.ArrayListUnmanaged(u8).empty;
    defer stdout_buf.deinit(ctx.alloc);
    var stderr_buf = std.ArrayListUnmanaged(u8).empty;
    defer stderr_buf.deinit(ctx.alloc);

    drainPipe(ctx.io, ctx.alloc, child.stdout, &stdout_buf);
    drainPipe(ctx.io, ctx.alloc, child.stderr, &stderr_buf);

    const term = child.wait(ctx.io) catch |e| {
        ctx.error_msg = std.fmt.allocPrint(ctx.alloc, "Wait error: {s}", .{@errorName(e)}) catch null;
        return;
    };
    evaluateChildTerm(ctx, term, stdout_buf.items, stderr_buf.items);
}

fn spawnWorkerThreads(alloc: Allocator, io: std.Io, tasks: []const std.json.Value, contexts: []WorkerContext, threads: []?std.Thread) !void {
    // PSEUDOCODE: Spawn worker threads for string tasks; mark invalid elements directly.
    for (tasks, 0..) |task_val, i| {
        if (task_val != .string) {
            contexts[i] = .{
                .alloc = alloc,
                .io = io,
                .task = "",
                .result = null,
                .error_msg = std.fmt.allocPrint(alloc, "Element tasks[{d}] must be a string (schema: items.string) — skipped, not executed.", .{i}) catch null,
                .index = i,
            };
            threads[i] = null;
            continue;
        }

        contexts[i] = .{
            .alloc = alloc,
            .io = io,
            .task = task_val.string,
            .result = null,
            .error_msg = null,
            .index = i,
        };
        threads[i] = try std.Thread.spawn(.{}, runSubAgentThread, .{ &contexts[i] });
    }
}

fn aggregateWorkerResults(alloc: Allocator, contexts: []WorkerContext) ![]u8 {
    // PSEUDOCODE: Format result summary across all parallel worker contexts.
    var result_buf = utils.BufWriter.init(alloc);
    defer result_buf.deinit();

    try result_buf.print("Executed {d} parallel tasks:\n", .{contexts.len});
    for (contexts) |*ctx| {
        try result_buf.print("\n--- [Task {d}] ---\n", .{ctx.index + 1});
        if (ctx.error_msg) |err| {
            try result_buf.print("ERROR:\n{s}\n", .{err});
            alloc.free(err);
        } else if (ctx.result) |res| {
            try result_buf.print("RESULT:\n{s}\n", .{res});
            alloc.free(res);
        } else {
            try result_buf.print("NO OUTPUT RECORDED.\n", .{});
        }
    }
    return result_buf.toOwnedSlice();
}

pub fn executeTool(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    // PSEUDOCODE:
    // 1. Guard against depth limit.
    // 2. Parse input JSON tasks array.
    // 3. Set depth environment variable.
    // 4. Launch workers via spawnWorkerThreads and join.
    // 5. Aggregate results via aggregateWorkerResults.
    const current_depth = subagent.getCurrentDepth();
    const max_depth = subagent.getMaxDepth();
    if (current_depth >= max_depth) {
        return std.fmt.allocPrint(alloc, "Error: Maximum subagent depth limit reached (depth={d}/{d}). Cannot spawn further batch subagents.", .{ current_depth, max_depth });
    }

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, input_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    if (parsed.value != .object or !parsed.value.object.contains("tasks") or parsed.value.object.get("tasks").? != .array) {
        return std.fmt.allocPrint(alloc, "Error: input must contain 'tasks' as an array of strings.", .{});
    }

    const tasks_arr = parsed.value.object.get("tasks").?.array;
    if (tasks_arr.items.len == 0) {
        return std.fmt.allocPrint(alloc, "Error: 'tasks' array is empty.", .{});
    }

    var depth_buf: [16]u8 = undefined;
    const next_depth_str = std.fmt.bufPrintZ(&depth_buf, "{d}", .{current_depth + 1}) catch "1";
    const env_map = main.getEnvironMap();
    const prev_depth = if (env_map) |em| em.get("MINI_SUBAGENT_DEPTH") else null;
    if (env_map) |em| em.put("MINI_SUBAGENT_DEPTH", next_depth_str) catch {};
    defer {
        if (env_map) |em| em.put("MINI_SUBAGENT_DEPTH", prev_depth orelse "0") catch {};
    }

    const contexts = try alloc.alloc(WorkerContext, tasks_arr.items.len);
    const threads = try alloc.alloc(?std.Thread, tasks_arr.items.len);
    defer alloc.free(contexts);
    defer alloc.free(threads);

    try spawnWorkerThreads(alloc, io, tasks_arr.items, contexts, threads);
    for (threads) |maybe_t| {
        if (maybe_t) |t| t.join();
    }
    return aggregateWorkerResults(alloc, contexts);
}

// ---------------------------------------------------------------------------
// Unit Tests
// ---------------------------------------------------------------------------

test "batch_subagent: depth check logic" {
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

    const res = try executeTool(testing.allocator, main.getIo(), "{\"tasks\":[\"task1\",\"task2\"]}");
    defer testing.allocator.free(res);

    try testing.expect(std.mem.indexOf(u8, res, "Maximum subagent depth limit reached") != null);
}

test "batch_subagent: invalid tasks element skipped without spawning process" {
    const testing = std.testing;

    const env_map = main.getEnvironMap();
    if (env_map == null) return error.SkipZigTest;

    const em = env_map.?;
    const prev_depth = em.get("MINI_SUBAGENT_DEPTH");
    const prev_max = em.get("MINI_MAX_SUBAGENT_DEPTH");

    em.put("MINI_SUBAGENT_DEPTH", "0") catch {};
    em.put("MINI_MAX_SUBAGENT_DEPTH", "2") catch {};
    defer {
        if (prev_depth) |v| em.put("MINI_SUBAGENT_DEPTH", v) catch {} else em.put("MINI_SUBAGENT_DEPTH", "0") catch {};
        if (prev_max) |v| em.put("MINI_MAX_SUBAGENT_DEPTH", v) catch {} else em.put("MINI_MAX_SUBAGENT_DEPTH", "0") catch {};
    }

    const res = try executeTool(testing.allocator, main.getIo(), "{\"tasks\":[123, {\"x\":1}]}");
    defer testing.allocator.free(res);

    try testing.expect(std.mem.indexOf(u8, res, "tasks[0] must be a string") != null);
    try testing.expect(std.mem.indexOf(u8, res, "tasks[1] must be a string") != null);
    try testing.expect(std.mem.indexOf(u8, res, "RESULT") == null);
}
