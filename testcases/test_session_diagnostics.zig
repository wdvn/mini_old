const std = @import("std");
const testing = std.testing;
const mini = @import("mini");
const session_diag = @import("../src/tools/session_diagnostics.zig");

test "session_diagnostics: listSessions returns non-empty result" {
    const alloc = testing.allocator;
    const result = try session_diag.listSessions(alloc, testing.io);
    defer alloc.free(result);

    try testing.expect(result.len > 0);
    try testing.expect(std.mem.indexOf(u8, result, "Danh sách Sessions") != null);
}

test "session_diagnostics: executeTool operation=list and invalid op handling" {
    const alloc = testing.allocator;
    const res_list = try session_diag.executeTool(alloc, testing.io, "{\"operation\":\"list\"}");
    defer alloc.free(res_list);
    try testing.expect(std.mem.indexOf(u8, res_list, "Danh sách Sessions") != null);

    const res_invalid = try session_diag.executeTool(alloc, testing.io, "{\"operation\":\"unknown_op\"}");
    defer alloc.free(res_invalid);
    try testing.expect(std.mem.indexOf(u8, res_invalid, "Lỗi: operation không hợp lệ") != null);
}

test "session_diagnostics: detail of current process" {
    const alloc = testing.allocator;
    const my_pid: i32 = @intCast(std.os.linux.getpid());
    const res = try session_diag.executeTool(alloc, testing.io, try std.fmt.allocPrint(alloc, "{{\"operation\":\"detail\",\"pid\":{d}}}", .{my_pid}));
    defer alloc.free(res);

    // Không crash, trả về kết quả
    try testing.expect(res.len > 0);
}
