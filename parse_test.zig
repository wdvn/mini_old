const std = @import("std");
const json = @import("src/json.zig");

pub fn main() !void {
    const chunk = "{\"tool_calls\":[{\"index\":0,\"id\":\"call_A\",\"type\":\"function\",\"function\":{\"name\":\"http_request\",\"arguments\":\"\"}}]}";
    
    if (json.findArray(chunk, "tool_calls")) |tc_arr| {
        std.debug.print("tc_arr: {s}\n", .{tc_arr});
        if (json.findString(tc_arr, "id")) |id| {
            std.debug.print("id: {s}\n", .{id});
        } else {
            std.debug.print("id NOT FOUND\n", .{});
        }
    } else {
        std.debug.print("tc_arr NOT FOUND\n", .{});
    }
}
