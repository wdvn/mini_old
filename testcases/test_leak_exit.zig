const std = @import("std");
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .stack_trace_frames = 10,
    }){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    _ = try alloc.create(i32);
}
