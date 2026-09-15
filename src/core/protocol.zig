//! protocol.zig — Shared data types for mini-agent.
//!
//! This module defines the structs and enums shared between backends,
//! the agent loop, and the tool dispatcher. No business logic resides here.
//!
//! ## Core types
//!   - `Message`        — a message in conversation history
//!   - `ContentBlock`   — content block (text, tool_use, tool_result)
//!   - `Response`       — response from an AI backend
//!   - `ToolDefinition` — tool definition sent to the API
//!   - `ToolResult`     — tool execution result

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;

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

// ---------------------------------------------------------------------------
// Response
// ---------------------------------------------------------------------------

/// Reason why the AI stopped generating text.
pub const StopReason = enum {
    /// Natural completion.
    end_turn,
    /// AI requested a tool call.
    tool_use,
    /// Reached token limit.
    max_tokens,
    /// Stop sequence triggered.
    stop_sequence,
    /// Stream aborted by idle stall watchdog (RFC-009 Phase 5) — partial
    /// content may have been preserved; agent decides how to recover.
    stream_aborted,
    /// Unknown stop reason.
    unknown,
};


/// Complete response from an AI backend.
/// Call `deinit` when finished to free memory.
pub const Response = struct {
    allocator: Allocator,
    /// All content blocks in the response.
    content: ArrayList(ContentBlock),
    /// Stop reason.
    stop_reason: StopReason,
    /// HTTP status code (in case of error/unknown)
    http_code: u32 = 200,
    /// Raw debug info from backend (when stop_reason == .unknown)
    raw_debug_info: ?[]const u8,
    /// Actual token usage from backend (RFC-006). Zero if not reported.
    usage: Usage = .{},

    /// Initialize an empty Response.
    pub fn init(alloc: Allocator) Response {
        return .{
            .allocator = alloc,
            .content = .empty,
            .stop_reason = .unknown,
            .http_code = 200,
            .raw_debug_info = null,
        };
    }

    /// Free all allocated memory.
    pub fn deinit(self: *Response) void {
        for (self.content.items) |block| {
            switch (block) {
                .text => |t| self.allocator.free(t),
                .thinking => |th| {
                    if (th.thinking.len > 0) self.allocator.free(th.thinking);
                    if (th.signature.len > 0) self.allocator.free(th.signature);
                },
                .tool_use => |tu| {
                    self.allocator.free(tu.id);
                    self.allocator.free(tu.name);
                    self.allocator.free(tu.input_json);
                },
                .tool_result => |tr| {
                    self.allocator.free(tr.tool_use_id);
                    self.allocator.free(tr.content);
                },
                .image => |img| {
                    self.allocator.free(img.data);
                    self.allocator.free(img.media_type);
                },
            }
        }
        self.content.deinit(self.allocator);
        if (self.raw_debug_info) |raw| self.allocator.free(raw);
    }
};

// ---------------------------------------------------------------------------
// Tool types
// ---------------------------------------------------------------------------

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
