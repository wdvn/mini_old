//! tools/subagent.zig — Gọi sub-agent con.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../core/json.zig");
const utils = @import("../core/utils.zig");
const main = @import("../main.zig");

pub fn executeTool(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    const task = (try json.findStringOwned(alloc, input_json, "task")) orelse {
        return std.fmt.allocPrint(alloc, "Lỗi: thiếu tham số 'task'", .{});
    };
    defer alloc.free(task);

    const exe_path = "/proc/self/exe";
    const argv = [_][]const u8{ exe_path, "-e", task };
    
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdout = .pipe,
        .stderr = .inherit,
        .stdin = .ignore,
    });

    // Đọc toàn bộ stdout
    var stdout_buf = std.ArrayListUnmanaged(u8).empty;
    defer stdout_buf.deinit(alloc);

    if (child.stdout) |out_pipe| {
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = out_pipe.readStreaming(io, &.{&chunk}) catch break;
            if (n == 0) break;
            try stdout_buf.appendSlice(alloc, chunk[0..n]);
        }
    }

    const term = try child.wait(io);

    switch (term) {
        .exited => |code| {
            if (code != 0) {
                return std.fmt.allocPrint(alloc, "Sub-agent kết thúc với mã lỗi: {d}. Output: {s}", .{ code, stdout_buf.items });
            }
        },
        else => {
            return std.fmt.allocPrint(alloc, "Sub-agent bị crash hoặc bị kill. Output: {s}", .{ stdout_buf.items });
        },
    }

    if (stdout_buf.items.len == 0) {
        return std.fmt.allocPrint(alloc, "Sub-agent chạy thành công nhưng không trả về nội dung.", .{});
    }

    return alloc.dupe(u8, stdout_buf.items);
}
