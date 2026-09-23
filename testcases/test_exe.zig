//! test_exe.zig — Standalone test for executable self-path resolution via /proc/self/exe.

const std = @import("std");

pub fn main() !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = std.os.linux.readlink("/proc/self/exe", &buf, buf.len);
    if (len > 0 and len <= buf.len) {
        std.debug.print("path: {s}\n", .{buf[0..len]});
    }
}
