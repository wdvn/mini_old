//! test_parse2.zig — Unit tests for JSON choices and finish_reason parsing.

const std = @import("std");
const testing = std.testing;
const mini = @import("mini");
const json = mini.json_mod;

test "json parse: choices and finish_reason extraction" {
    const chunk = "{\"id\":\"resp_xyz\",\"choices\":[{\"index\":0,\"delta\":{\"role\":null,\"content\":null,\"reasoning_content\":null,\"tool_calls\":null},\"finish_reason\":\"tool_calls\",\"native_finish_reason\":\"tool_calls\"}],\"usage\":{}}";

    const choices = json.findArray(chunk, "choices");
    try testing.expect(choices != null);
    const reason = json.findString(choices.?, "finish_reason");
    try testing.expect(reason != null);
    try testing.expectEqualStrings("tool_calls", reason.?);
}
