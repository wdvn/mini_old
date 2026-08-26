//! tools/batch_subagent.zig — Chạy nhiều sub-agents song song.

const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("../core/utils.zig");
const subagent = @import("subagent.zig");
const main = @import("../main.zig");

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn unsetenv(name: [*:0]const u8) c_int;

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
        .stderr = .inherit,
        .stdin = .ignore,
    }) catch |e| {
        ctx.error_msg = std.fmt.allocPrint(ctx.alloc, "Lỗi khởi chạy: {s}", .{@errorName(e)}) catch null;
        return;
    };

    var stdout_buf = std.ArrayListUnmanaged(u8).empty;
    defer stdout_buf.deinit(ctx.alloc);

    if (child.stdout) |out_pipe| {
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = out_pipe.readStreaming(ctx.io, &.{&chunk}) catch break;
            if (n == 0) break;
            stdout_buf.appendSlice(ctx.alloc, chunk[0..n]) catch break;
        }
    }

    const term = child.wait(ctx.io) catch |e| {
        ctx.error_msg = std.fmt.allocPrint(ctx.alloc, "Lỗi wait: {s}", .{@errorName(e)}) catch null;
        return;
    };

    switch (term) {
        .exited => |code| {
            if (code != 0) {
                ctx.error_msg = std.fmt.allocPrint(ctx.alloc, "Lỗi exit code {d}: {s}", .{ code, stdout_buf.items }) catch null;
            } else {
                ctx.result = ctx.alloc.dupe(u8, stdout_buf.items) catch null;
            }
        },
        else => {
            ctx.error_msg = std.fmt.allocPrint(ctx.alloc, "Bị crash hoặc kill. Output: {s}", .{ stdout_buf.items }) catch null;
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

    // Thiết lập độ sâu cho các tiến trình con kế thừa
    var depth_buf: [16]u8 = undefined;
    const next_depth_str = std.fmt.bufPrintZ(&depth_buf, "{d}", .{current_depth + 1}) catch "1";
    _ = setenv("MINI_SUBAGENT_DEPTH", next_depth_str.ptr, 1);
    defer {
        if (current_depth == 0) {
            _ = unsetenv("MINI_SUBAGENT_DEPTH");
        } else {
            var prev_buf: [16]u8 = undefined;
            const prev_str = std.fmt.bufPrintZ(&prev_buf, "{d}", .{current_depth}) catch "0";
            _ = setenv("MINI_SUBAGENT_DEPTH", prev_str.ptr, 1);
        }
    }

    var contexts = try alloc.alloc(WorkerContext, num_tasks);
    var threads = try alloc.alloc(std.Thread, num_tasks);
    defer alloc.free(contexts);
    defer alloc.free(threads);

    // Bật tất cả thread
    for (tasks_arr.items, 0..) |task_val, i| {
        if (task_val != .string) {
            contexts[i] = .{ .alloc = alloc, .io = io, .task = "Invalid task format", .result = null, .error_msg = null, .index = i };
            // Tạo dummy thread để join logic đơn giản
            threads[i] = try std.Thread.spawn(.{}, runSubAgentThread, .{ &contexts[i] });
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

    // Đợi các thread hoàn thành
    for (threads) |t| {
        t.join();
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

    _ = setenv("MINI_SUBAGENT_DEPTH", "2", 1);
    defer _ = unsetenv("MINI_SUBAGENT_DEPTH");

    _ = setenv("MINI_MAX_SUBAGENT_DEPTH", "2", 1);
    defer _ = unsetenv("MINI_MAX_SUBAGENT_DEPTH");

    const res = try executeTool(testing.allocator, main.getIo(), "{\"tasks\":[\"task1\",\"task2\"]}");
    defer testing.allocator.free(res);

    try testing.expect(std.mem.indexOf(u8, res, "Đã đạt giới hạn độ sâu subagent tối đa") != null);
}

