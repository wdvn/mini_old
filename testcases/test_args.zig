//! test_args.zig — Standalone test helper for command-line argument iteration.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args_raw = try init.minimal.args.toSlice(alloc);
    defer alloc.free(args_raw);

    if (args_raw.len > 0) {
        std.debug.print("Args: {s}\n", .{args_raw[0]});
    }
}
