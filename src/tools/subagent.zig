//! tools/subagent.zig — Gọi sub-agent con.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../core/json.zig");
const utils = @import("../core/utils.zig");
const main = @import("../main.zig");

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn unsetenv(name: [*:0]const u8) c_int;

/// Độ sâu sub-agent mặc định tối đa cho phép để phòng tránh đệ quy vô hạn.
pub const DEFAULT_MAX_SUBAGENT_DEPTH: usize = 2;

/// Lấy độ sâu hiện tại của subagent từ biến môi trường.
pub fn getCurrentDepth() usize {
    if (getenv("MINI_SUBAGENT_DEPTH")) |ptr| {
        const span = std.mem.span(ptr);
        return std.fmt.parseInt(usize, span, 10) catch 0;
    }
    return 0;
}

/// Lấy độ sâu tối đa cho phép từ cấu hình hoặc mặc định.
pub fn getMaxDepth() usize {
    if (getenv("MINI_MAX_SUBAGENT_DEPTH")) |ptr| {
        const span = std.mem.span(ptr);
        return std.fmt.parseInt(usize, span, 10) catch DEFAULT_MAX_SUBAGENT_DEPTH;
    }
    return DEFAULT_MAX_SUBAGENT_DEPTH;
}

pub fn executeTool(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    const current_depth = getCurrentDepth();
    const max_depth = getMaxDepth();

    if (current_depth >= max_depth) {
        return std.fmt.allocPrint(alloc, "Lỗi: Đã đạt giới hạn độ sâu subagent tối đa (depth={d}/{d}). Không thể tạo thêm subagent để phòng tránh đệ quy vô hạn.", .{ current_depth, max_depth });
    }

    const task = (try json.findStringOwned(alloc, input_json, "task")) orelse
        (try json.findStringOwned(alloc, input_json, "prompt")) orelse
        (try json.findStringOwned(alloc, input_json, "instruction")) orelse
        (try json.findStringOwned(alloc, input_json, "description")) orelse {
        return std.fmt.allocPrint(alloc, "Lỗi: thiếu tham số 'task'", .{});
    };
    defer alloc.free(task);

    // Thiết lập độ sâu cho tiến trình con kế thừa
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

    const exe_path = "/proc/self/exe";
    const argv = [_][]const u8{ exe_path, "-e", task };
    
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdout = .pipe,
        .stderr = .pipe,
        .stdin = .ignore,
    });

    // Đọc toàn bộ stdout và stderr
    var stdout_buf = std.ArrayListUnmanaged(u8).empty;
    defer stdout_buf.deinit(alloc);
    var stderr_buf = std.ArrayListUnmanaged(u8).empty;
    defer stderr_buf.deinit(alloc);

    if (child.stdout) |out_pipe| {
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = out_pipe.readStreaming(io, &.{&chunk}) catch break;
            if (n == 0) break;
            try stdout_buf.appendSlice(alloc, chunk[0..n]);
        }
    }

    if (child.stderr) |err_pipe| {
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = err_pipe.readStreaming(io, &.{&chunk}) catch break;
            if (n == 0) break;
            try stderr_buf.appendSlice(alloc, chunk[0..n]);
        }
    }

    const term = try child.wait(io);

    switch (term) {
        .exited => |code| {
            if (code != 0) {
                const err_detail = if (stderr_buf.items.len > 0) stderr_buf.items else stdout_buf.items;
                return std.fmt.allocPrint(alloc, "Sub-agent kết thúc với mã lỗi: {d}. Chi tiết: {s}", .{ code, err_detail });
            }
        },
        else => {
            const err_detail = if (stderr_buf.items.len > 0) stderr_buf.items else stdout_buf.items;
            return std.fmt.allocPrint(alloc, "Sub-agent bị crash hoặc bị kill. Chi tiết: {s}", .{err_detail});
        },
    }

    if (stdout_buf.items.len == 0) {
        return std.fmt.allocPrint(alloc, "Sub-agent chạy thành công nhưng không trả về nội dung.", .{});
    }

    return alloc.dupe(u8, stdout_buf.items);
}

// ---------------------------------------------------------------------------
// Unit Tests
// ---------------------------------------------------------------------------

test "subagent: depth check logic" {
    const testing = std.testing;

    _ = setenv("MINI_SUBAGENT_DEPTH", "2", 1);
    defer _ = unsetenv("MINI_SUBAGENT_DEPTH");

    _ = setenv("MINI_MAX_SUBAGENT_DEPTH", "2", 1);
    defer _ = unsetenv("MINI_MAX_SUBAGENT_DEPTH");

    try testing.expectEqual(@as(usize, 2), getCurrentDepth());
    try testing.expectEqual(@as(usize, 2), getMaxDepth());

    const res = try executeTool(testing.allocator, main.getIo(), "{\"task\":\"test infinite loop\"}");
    defer testing.allocator.free(res);

    try testing.expect(std.mem.indexOf(u8, res, "Đã đạt giới hạn độ sâu subagent tối đa") != null);
}

