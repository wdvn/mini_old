//! core/protocol/tools.zig — Tool definition and result data structures.
//!
//! Provides ToolDefinition (schema passed to model) and ToolResult (execution outcome).

const std = @import("std");

/// Tool definition sent to the API so AI knows available tools.
pub const ToolDefinition = struct {
    /// Tool name (used for dispatch).
    name: []const u8,
    /// Concise description for the AI.
    description: []const u8,
    /// JSON Schema of input parameters (object).
    input_schema_json: []const u8,
};

/// Tool execution result to append to history.
pub const ToolResult = struct {
    /// Matches ToolUse.id.
    tool_use_id: []const u8,
    /// Tool output.
    content: []const u8,
    /// True if tool reported an error.
    is_error: bool,
};

test "ToolResult basic fields" {
    const res = ToolResult{
        .tool_use_id = "call_1",
        .content = "output",
        .is_error = false,
    };
    try std.testing.expectEqualStrings("call_1", res.tool_use_id);
    try std.testing.expect(!res.is_error);
}
