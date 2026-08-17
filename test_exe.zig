const std = @import("std");
pub fn main() !void {
    const alloc = std.heap.page_allocator;
    const cwd = std.Io.Dir.cwd();
    // readlink is usually in posix
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.posix.readlink("/proc/self/exe", &buf);
    std.debug.print("path: {s}\n", .{path});
}
