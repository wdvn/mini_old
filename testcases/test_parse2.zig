const std = @import("std");
const json = @import("src/json.zig");

pub fn main() !void {
    const chunk = "{\"id\":\"resp_xyz\",\"choices\":[{\"index\":0,\"delta\":{\"role\":null,\"content\":null,\"reasoning_content\":null,\"tool_calls\":null},\"finish_reason\":\"tool_calls\",\"native_finish_reason\":\"tool_calls\"}],\"usage\":{}}";
    
    if (json.findArray(chunk, "choices")) |choices| {
        std.debug.print("choices: {s}\n", .{choices});
        if (json.findString(choices, "finish_reason")) |reason| {
            std.debug.print("reason: '{s}'\n", .{reason});
        } else {
            std.debug.print("reason NOT FOUND\n", .{});
        }
    } else {
        std.debug.print("choices NOT FOUND\n", .{});
    }
}
