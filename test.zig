const std = @import("std");
pub fn main() !void {
    const model = "gpt-5.6-luna";
    const use = std.mem.indexOf(u8, model, "o1") != null or
        std.mem.indexOf(u8, model, "o3") != null or
        std.mem.indexOf(u8, model, "luna") != null;
    std.debug.print("Result: {}\n", .{use});
}
