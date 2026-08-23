const std = @import("std");

pub fn main() !void {
    const stdin_fd = std.posix.STDIN_FILENO;
    var termios = try std.posix.tcgetattr(stdin_fd);
    std.debug.print("LFLAG: {}\n", .{termios.lflag});
}
