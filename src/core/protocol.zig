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
    /// Provider stream ended without an explicit terminal event.
    missing_terminal_event,
    /// Provider explicitly filtered or rejected the response.
    content_filter,
    /// Provider failed before producing a usable response.
    provider_error,
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

/// RFC-023: Validated shape of a backend response payload.
pub const ResponseValidity = enum {
    final_text,
    native_tool_calls,
    codeact,
    thinking_only,
    whitespace_only,
    partial_text,
    malformed_tool_call,
    empty,
};

/// RFC-023: Terminal outcome of a complete user turn.
pub const TurnOutcome = enum {
    completed,
    stalled,
    failed,
    blocked,
    cancelled,
};

/// RFC-023: Public result returned after a normal terminal turn path.
pub const TurnResult = struct {
    outcome: TurnOutcome,
    generation_stop: StopReason,
    response_validity: ResponseValidity,
    last_agent_message: ?[]const u8,
    act_count: usize,
    recovery_attempts: usize,
};

/// RFC-023: Agent-level action selected after response classification.
pub const AgentDecision = enum {
    execute_native_tools,
    execute_codeact,
    deliver_final_answer,
    request_continuation,
    retry_transient,
    fail_stalled,
    fail_protocol,
    cancel,
};

pub const RecoveryClass = enum {
    thinking_only,
    empty_response,
    missing_terminal,
    stream_aborted,
};

pub const RecoveryDecision = enum {
    retry,
    stalled,
};

/// Bounded recovery for unusable responses in the current Act.
/// This is not a task-duration or total-Act limit.
pub const ResponseRecoveryBudget = struct {
    thinking_only_retries: u8 = 2,
    empty_response_retries: u8 = 2,
    missing_terminal_retries: u8 = 1,
    stream_aborted_retries: u8 = 2,

    pub fn consume(self: *ResponseRecoveryBudget, class: RecoveryClass) RecoveryDecision {
        // PSEUDOCODE:
        // 1. Select the budget for this response failure class.
        // 2. Consume one retry while capacity remains.
        // 3. Return stalled once the bounded class is exhausted.
        const counter = switch (class) {
            .thinking_only => &self.thinking_only_retries,
            .empty_response => &self.empty_response_retries,
            .missing_terminal => &self.missing_terminal_retries,
            .stream_aborted => &self.stream_aborted_retries,
        };
        if (counter.* == 0) return .stalled;
        counter.* -= 1;
        return .retry;
    }
};

/// Classifies normalized content before stop-reason dispatch.
pub fn classifyResponse(response: *const Response, has_codeact: bool) ResponseValidity {
    // PSEUDOCODE:
    // 1. Native tool calls and CodeAct are actions and take precedence over text.
    // 2. Partial transport text is never treated as a final answer.
    // 3. Thinking-only, whitespace-only, and empty payloads remain distinct.
    var has_tool = false;
    var has_meaningful_text = false;
    var has_text = false;
    var has_thinking = false;
    for (response.content.items) |block| switch (block) {
        .tool_use => |tool| {
            if (tool.name.len == 0) return .malformed_tool_call;
            has_tool = true;
        },
        .text => |text| {
            has_text = true;
            if (std.mem.trim(u8, text, " \r\n\t").len > 0) has_meaningful_text = true;
        },
        .thinking => has_thinking = true,
        else => {},
    };
    if (has_tool) return .native_tool_calls;
    if (has_codeact) return .codeact;
    if (has_meaningful_text) {
        if (response.stop_reason == .stream_aborted or
            response.stop_reason == .missing_terminal_event or
            response.stop_reason == .max_tokens or
            response.stop_reason == .stop_sequence)
        {
            return .partial_text;
        }
        return .final_text;
    }
    if (has_thinking) return .thinking_only;
    if (has_text) return .whitespace_only;
    return .empty;
}

/// Maps validated provider state to an agent-level action.
pub fn decideAgentAction(
    stop_reason: StopReason,
    validity: ResponseValidity,
    has_codeact: bool,
) AgentDecision {
    // PSEUDOCODE:
    // 1. Executable actions take precedence over provider termination.
    // 2. Only natural end with meaningful text can deliver a final answer.
    // 3. Partial/no-action responses use bounded recovery or protocol failure.
    _ = has_codeact;
    return switch (validity) {
        .native_tool_calls => .execute_native_tools,
        .codeact => .execute_codeact,
        .malformed_tool_call => .fail_protocol,
        .final_text => if (stop_reason == .end_turn) .deliver_final_answer else .request_continuation,
        .partial_text => if (stop_reason == .stream_aborted or
            stop_reason == .missing_terminal_event or
            stop_reason == .max_tokens) .request_continuation else .fail_protocol,
        .thinking_only => if (stop_reason == .end_turn) .retry_transient else .request_continuation,
        .whitespace_only, .empty => if (stop_reason == .end_turn) .retry_transient else .fail_protocol,
    };
}

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

// RFC-023 RED tests: response classification and bounded recovery.

test "RFC-023: thinking-only natural end retries then stalls" {
    const alloc = std.testing.allocator;
    var response = Response.init(alloc);
    defer response.deinit();
    response.stop_reason = .end_turn;
    try response.content.append(alloc, .{ .thinking = .{
        .thinking = try alloc.dupe(u8, "partial reasoning"),
        .signature = try alloc.dupe(u8, ""),
    } });

    try std.testing.expectEqual(ResponseValidity.thinking_only, classifyResponse(&response, false));
    try std.testing.expectEqual(AgentDecision.retry_transient, decideAgentAction(.end_turn, .thinking_only, false));

    var budget = ResponseRecoveryBudget{};
    try std.testing.expectEqual(RecoveryDecision.retry, budget.consume(.thinking_only));
    try std.testing.expectEqual(RecoveryDecision.retry, budget.consume(.thinking_only));
    try std.testing.expectEqual(RecoveryDecision.stalled, budget.consume(.thinking_only));
}

test "RFC-023: native tool takes precedence over final text" {
    const alloc = std.testing.allocator;
    var response = Response.init(alloc);
    defer response.deinit();
    response.stop_reason = .end_turn;
    try response.content.append(alloc, .{ .text = try alloc.dupe(u8, "working") });
    try response.content.append(alloc, .{ .tool_use = .{
        .id = try alloc.dupe(u8, "call_1"),
        .name = try alloc.dupe(u8, "bash"),
        .input_json = try alloc.dupe(u8, "{}"),
    } });

    try std.testing.expectEqual(ResponseValidity.native_tool_calls, classifyResponse(&response, true));
    try std.testing.expectEqual(AgentDecision.execute_native_tools, decideAgentAction(.end_turn, .native_tool_calls, true));
}
