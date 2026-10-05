//! core/protocol/types.zig — Basic conversation message, block, and usage types.
//!
//! Provides fundamental data structures for LLM conversation history:
//! Role, Message, ContentBlock, ToolUse, ToolResultBlock, ImageBlock, ThinkingBlock, Usage, Tier.

const std = @import("std");

// ---------------------------------------------------------------------------
// Message roles
// ---------------------------------------------------------------------------

/// Role of a message in the conversation.
pub const Role = enum {
    user,
    assistant,

    /// Returns JSON string: "user" or "assistant".
    pub fn toJson(self: Role) []const u8 {
        return switch (self) {
            .user => "user",
            .assistant => "assistant",
        };
    }
};

// ---------------------------------------------------------------------------
// Content blocks
// ---------------------------------------------------------------------------

/// Information for a tool call requested by the AI.
pub const ToolUse = struct {
    /// Unique ID for this call (returned in tool result).
    id: []const u8,
    /// Name of the invoked tool.
    name: []const u8,
    /// Parameters as a JSON string (object).
    input_json: []const u8,
};

/// Tool result attached to user message (responding to tool_use).
pub const ToolResultBlock = struct {
    /// Matches ToolUse.id.
    tool_use_id: []const u8,
    /// Return content (plain text or JSON).
    content: []const u8,
    /// Indicates whether tool execution failed.
    is_error: bool,
};

/// Image block attached in a message (RFC-010 Vision).
pub const ImageBlock = struct {
    /// Base64 data (WITHOUT prefix "data:...;base64,").
    data: []const u8,
    /// MIME type: "image/png", "image/jpeg", "image/webp", "image/gif".
    media_type: []const u8,
};

/// Thinking / reasoning block from the AI.
pub const ThinkingBlock = struct {
    /// Content of thinking stream.
    thinking: []const u8,
    /// Anthropic verification signature (if present, may be empty).
    signature: []const u8,
};

/// A content block within a message or response.
pub const ContentBlock = union(enum) {
    /// Regular text.
    text: []const u8,
    /// Image block attached in a message (RFC-010 Vision).
    image: ImageBlock,
    /// Thinking stream of the AI.
    thinking: ThinkingBlock,
    /// Tool execution requested by the AI.
    tool_use: ToolUse,
    /// Tool result sent back to the AI.
    tool_result: ToolResultBlock,
};

/// Context tier (MemAct RFC-003).
pub const Tier = enum {
    pinned,
    recent,
    summarized,
    archived,
};

/// A message in conversation history.
/// `content` is owned by History — do not free directly.
pub const Message = struct {
    role: Role,
    /// Content blocks of this message.
    content: []const ContentBlock,
    /// Context tier (MemAct). Null if created with legacy style.
    tier: ?Tier = null,
};

// ---------------------------------------------------------------------------
// Usage (RFC-006)
// ---------------------------------------------------------------------------

/// Token usage statistics returned by backend (OpenAI usage object format).
/// Shared across all backends (openai-compat, claude, ollama).
pub const Usage = struct {
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    total_tokens: u64 = 0,
    /// Prompt tokens priced as cache hit (prompt_tokens - cached_tokens).
    cached_tokens: u64 = 0,
    /// Tokens used for reasoning/thinking (DeepSeek reasoner, OpenAI o-series).
    reasoning_tokens: u64 = 0,
};

test "Role.toJson" {
    try std.testing.expectEqualStrings("user", Role.user.toJson());
    try std.testing.expectEqualStrings("assistant", Role.assistant.toJson());
}
