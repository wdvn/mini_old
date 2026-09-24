//! test_parse.zig — Unit tests for JSON tool call chunk parsing.

const std = @import("std");
const testing = std.testing;
const mini = @import("mini");
const json = mini.json_mod;

test "json parse: tool_calls chunk id extraction" {
    const chunk = "{\"tool_calls\":[{\"index\":0,\"id\":\"call_A\",\"type\":\"function\",\"function\":{\"name\":\"http_request\",\"arguments\":\"\"}}]}";

    const tc_arr = json.findArray(chunk, "tool_calls");
    try testing.expect(tc_arr != null);
    const id = json.findString(tc_arr.?, "id");
    try testing.expect(id != null);
    try testing.expectEqualStrings("call_A", id.?);
}
