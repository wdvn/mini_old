const std = @import("std");

pub fn main() !void {
    const fd = std.posix.STDIN_FILENO;
    var termios = try std.posix.tcgetattr(fd);
    
    var raw = termios;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    
    try std.posix.tcsetattr(fd, .FLUSH, raw);
    
    var buf: [1]u8 = undefined;
    _ = try std.posix.read(fd, &buf);
    std.debug.print("Got: {d}\n", .{buf[0]});
    
    try std.posix.tcsetattr(fd, .FLUSH, termios);
}
