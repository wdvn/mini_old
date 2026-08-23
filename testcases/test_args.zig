const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    
    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    
    std.debug.print("Args: {s}\n", .{args.next().?});
}
