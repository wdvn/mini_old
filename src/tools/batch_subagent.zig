//! tools/batch_subagent.zig — Chạy nhiều sub-agents song song.

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

fn runSubAgentThread(ctx: *WorkerContext) void {
    const exe_path = "/proc/self/exe";
    const argv = [_][]const u8{ exe_path, "-e", ctx.task };
    
    var child = std.process.spawn(ctx.io, .{
        .argv = &argv,
        .stdout = .pipe,
        .stderr = .pipe,
        .stdin = .ignore,
        .environ_map = main.getEnvironMap(),
    }) catch |e| {
        ctx.error_msg = std.fmt.allocPrint(ctx.alloc, "Lỗi khởi chạy: {s}", .{@errorName(e)}) catch null;
        return;
    };

    var stdout_buf = std.ArrayListUnmanaged(u8).empty;
    defer stdout_buf.deinit(ctx.alloc);
    var stderr_buf = std.ArrayListUnmanaged(u8).empty;
    defer stderr_buf.deinit(ctx.alloc);

    if (child.stdout) |out_pipe| {
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = out_pipe.readStreaming(ctx.io, &.{&chunk}) catch break;
            if (n == 0) break;
            stdout_buf.appendSlice(ctx.alloc, chunk[0..n]) catch break;
        }
    }

    if (child.stderr) |err_pipe| {
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = err_pipe.readStreaming(ctx.io, &.{&chunk}) catch break;
            if (n == 0) break;
            stderr_buf.appendSlice(ctx.alloc, chunk[0..n]) catch break;
        }
    }

    const term = child.wait(ctx.io) catch |e| {
        ctx.error_msg = std.fmt.allocPrint(ctx.alloc, "Lỗi wait: {s}", .{@errorName(e)}) catch null;
        return;
    };

    switch (term) {
        .exited => |code| {
            if (code != 0) {
                const err_detail = if (stderr_buf.items.len > 0) stderr_buf.items else stdout_buf.items;
                ctx.error_msg = std.fmt.allocPrint(ctx.alloc, "Lỗi exit code {d}: {s}", .{ code, err_detail }) catch null;
            } else {
                ctx.result = ctx.alloc.dupe(u8, stdout_buf.items) catch null;
            }
        },
        else => {
            const err_detail = if (stderr_buf.items.len > 0) stderr_buf.items else stdout_buf.items;
            ctx.error_msg = std.fmt.allocPrint(ctx.alloc, "Bị crash hoặc kill. Chi tiết: {s}", .{err_detail}) catch null;
        }
    }
}

pub fn executeTool(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    const current_depth = subagent.getCurrentDepth();
    const max_depth = subagent.getMaxDepth();

    if (current_depth >= max_depth) {
        return std.fmt.allocPrint(alloc, "Lỗi: Đã đạt giới hạn độ sâu subagent tối đa (depth={d}/{d}). Không thể tạo thêm batch subagent để phòng tránh đệ quy vô hạn.", .{ current_depth, max_depth });
    }

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, input_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    if (parsed.value != .object or !parsed.value.object.contains("tasks") or parsed.value.object.get("tasks").? != .array) {
        return std.fmt.allocPrint(alloc, "Lỗi: input phải chứa 'tasks' là một mảng chuỗi.", .{});
    }

    const tasks_arr = parsed.value.object.get("tasks").?.array;
    const num_tasks = tasks_arr.items.len;
    if (num_tasks == 0) {
        return std.fmt.allocPrint(alloc, "Lỗi: mảng 'tasks' trống.", .{});
    }

    // Thiết lập độ sâu cho các tiến trình con kế thừa (qua environ_map truyền vào spawn).
    var depth_buf: [16]u8 = undefined;
    const next_depth_str = std.fmt.bufPrintZ(&depth_buf, "{d}", .{current_depth + 1}) catch "1";
    const env_map = main.getEnvironMap();
    const prev_depth = if (env_map) |em| em.get("MINI_SUBAGENT_DEPTH") else null;
    if (env_map) |em| {
        em.put("MINI_SUBAGENT_DEPTH", next_depth_str) catch {};
    }
    defer {
        if (env_map) |em| {
            // Restore giá trị cũ; nếu không có, đặt "0" (tương đương không phải subagent).
            const restore = prev_depth orelse "0";
            em.put("MINI_SUBAGENT_DEPTH", restore) catch {};
        }
    }

    var contexts = try alloc.alloc(WorkerContext, num_tasks);
    var threads = try alloc.alloc(?std.Thread, num_tasks);
    defer alloc.free(contexts);
    defer alloc.free(threads);

    // Bật tất cả thread
    for (tasks_arr.items, 0..) |task_val, i| {
        if (task_val != .string) {
            // Phần tử sai kiểu: KHÔNG spawn thread/process (tránh chạy subagent
            // với task rác). Ghi lỗi trực tiếp vào context để báo cáo trong
            // kết quả gộp; join logic vẫn đơn giản nhờ threads[i] = null.
            contexts[i] = .{
                .alloc = alloc,
                .io = io,
                .task = "",
                .result = null,
                .error_msg = std.fmt.allocPrint(
                    alloc,
                    "Phần tử tasks[{d}] phải là chuỗi (schema: items.string) — đã bỏ qua, không thực thi.",
                    .{i},
                ) catch null,
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

    // Đợi các thread hoàn thành (bỏ qua slot bị bỏ do task sai kiểu)
    for (threads) |maybe_t| {
        if (maybe_t) |t| t.join();
    }

    // Gom kết quả
    var result_buf = utils.BufWriter.init(alloc);
    defer result_buf.deinit();

    try result_buf.print("Đã thực thi {d} tác vụ song song:\n", .{num_tasks});
    for (contexts) |*ctx| {
        try result_buf.print("\n--- [Tác vụ {d}] ---\n", .{ctx.index + 1});
        if (ctx.error_msg) |err| {
            try result_buf.print("LỖI:\n{s}\n", .{err});
            alloc.free(err);
        } else if (ctx.result) |res| {
            try result_buf.print("KẾT QUẢ:\n{s}\n", .{res});
            alloc.free(res);
        } else {
            try result_buf.print("KHÔNG RÕ KẾT QUẢ.\n", .{});
        }
    }

    return result_buf.toOwnedSlice();
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

    try testing.expect(std.mem.indexOf(u8, res, "Đã đạt giới hạn độ sâu subagent tối đa") != null);
}

test "batch_subagent: phần tử tasks sai kiểu bị bỏ qua, không spawn process" {
    const testing = std.testing;

    const env_map = main.getEnvironMap();
    if (env_map == null) return error.SkipZigTest;

    const em = env_map.?;
    const prev_depth = em.get("MINI_SUBAGENT_DEPTH");
    const prev_max = em.get("MINI_MAX_SUBAGENT_DEPTH");

    // Cho phép chạy (depth < max) nhưng toàn bộ task đều sai kiểu
    // => không được spawn bất kỳ process nào, chỉ ghi lỗi vào kết quả.
    em.put("MINI_SUBAGENT_DEPTH", "0") catch {};
    em.put("MINI_MAX_SUBAGENT_DEPTH", "2") catch {};
    defer {
        if (prev_depth) |v| em.put("MINI_SUBAGENT_DEPTH", v) catch {} else em.put("MINI_SUBAGENT_DEPTH", "0") catch {};
        if (prev_max) |v| em.put("MINI_MAX_SUBAGENT_DEPTH", v) catch {} else em.put("MINI_MAX_SUBAGENT_DEPTH", "0") catch {};
    }

    const res = try executeTool(testing.allocator, main.getIo(), "{\"tasks\":[123, {\"x\":1}]}");
    defer testing.allocator.free(res);

    // Cả 2 phần tử đều bị báo lỗi schema, không có KẾT QUẢ nào (không spawn).
    try testing.expect(std.mem.indexOf(u8, res, "tasks[0] phải là chuỗi") != null);
    try testing.expect(std.mem.indexOf(u8, res, "tasks[1] phải là chuỗi") != null);
    try testing.expect(std.mem.indexOf(u8, res, "KẾT QUẢ") == null);
}

