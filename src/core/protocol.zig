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

/// RFC-023: normalized provider generation termination state.
///
/// PSEUDOCODE:
/// 1. Record the provider's terminal generation event.
/// 2. Keep an absent terminal event distinct from natural completion.
/// 3. Let the agent layer decide whether a usable response completes a turn.
pub const GenerationStop = enum {
    natural_end,
    tool_call,
    max_tokens,
    stop_sequence,
    stream_aborted,
    missing_terminal_event,
    content_filter,
    provider_error,
    cancelled,

    pub fn fromStopReason(stop: StopReason, http_code: u32) GenerationStop {
        return toGenerationStop(stop, http_code);
    }
};

/// Reason why the AI stopped generating text.
///
/// Deprecated provider-compatible field; new agent logic uses GenerationStop.
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

pub const MAX_RESPONSE_SNIPPET_LEN: usize = 2048;

pub fn boundedResponseSnippet(raw: []const u8) []const u8 {
    // PSEUDOCODE:
    // 1. Keep diagnostics useful for session debugging.
    // 2. Never retain an unbounded network/provider payload.
    return raw[0..@min(raw.len, MAX_RESPONSE_SNIPPET_LEN)];
}

test "RFC-023: provider response diagnostics are bounded" {
    const raw = "secret-bearing-response" ** 1000;
    try std.testing.expectEqual(MAX_RESPONSE_SNIPPET_LEN, boundedResponseSnippet(raw).len);
}

pub fn toGenerationStop(stop_reason: StopReason, http_code: u32) GenerationStop {
    // PSEUDOCODE:
    // 1. Distinguish between provider errors (HTTP 5xx) and transport errors (http_code == 0 or custom codes).
    // 2. http_code == 0 indicates stream was aborted before any HTTP response (idle timeout, connection reset).
    // 3. Custom codes like 598 are internal markers and should not be treated as provider errors.
    // 4. Only map to provider_error when actual HTTP 5xx is returned.
    if (http_code >= 500) {
        if (stop_reason == .missing_terminal_event or stop_reason == .unknown or stop_reason == .provider_error) {
            return .provider_error;
        }
    }
    return switch (stop_reason) {
        .end_turn => .natural_end,
        .tool_use => .tool_call,
        .max_tokens => .max_tokens,
        .stop_sequence => .stop_sequence,
        .stream_aborted => .stream_aborted,
        .missing_terminal_event => .missing_terminal_event,
        .content_filter => .content_filter,
        .provider_error => .provider_error,
        .unknown => .missing_terminal_event,
    };
}

/// Complete response from an AI backend.
/// Call `deinit` when finished to free memory.
pub const Response = struct {
    allocator: Allocator,
    /// All content blocks in the response.
    content: ArrayList(ContentBlock),
    /// Legacy provider stop reason retained for wire/log compatibility.
    stop_reason: StopReason,
    /// RFC-023 normalized generation termination state.
    /// Null means the legacy backend adapter has not normalized a terminal event yet.
    generation_stop: ?GenerationStop = null,
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
            .generation_stop = null,
            .http_code = 200,
            .raw_debug_info = null,
        };
    }

    /// Resolve canonical GenerationStop, falling back only when no normalized value exists.
    pub fn getGenerationStop(self: *const Response) GenerationStop {
        return self.generation_stop orelse toGenerationStop(self.stop_reason, self.http_code);
    }

    pub fn toModelResponse(self: *const Response, validity: ResponseValidity, backend_name: []const u8, model_name: []const u8) ModelResponse {
        var has_txt = false;
        var has_tools = false;
        var thinking_len: usize = 0;
        for (self.content.items) |b| {
            switch (b) {
                .text => |t| if (t.len > 0) {
                    has_txt = true;
                },
                .tool_use => has_tools = true,
                .thinking => |th| thinking_len += th.thinking.len,
                else => {},
            }
        }
        const gen_stop = self.getGenerationStop();
        return .{
            .generation_stop = gen_stop,
            .validity = validity,
            .content = self.content.items,
            .usage = self.usage,
            .diagnostics = .{
                .http_code = self.http_code,
                .backend = backend_name,
                .model = model_name,
                .terminal_event_received = (gen_stop == .natural_end or gen_stop == .tool_call or gen_stop == .max_tokens or gen_stop == .stop_sequence),
                .finish_reason_received = (self.stop_reason != .unknown and self.stop_reason != .missing_terminal_event),
                .thinking_length = thinking_len,
                .has_text = has_txt,
                .has_tool_calls = has_tools,
                .raw_snippet = self.raw_debug_info,
            },
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

/// RFC-023: StepOutcome describing the immediate action taken for a step.
pub const StepOutcome = enum {
    actions_executed,
    final_answer,
    continuation_requested,
    transient_retry,
    protocol_failure,
    provider_failure,
    cancelled,
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
    generation_stop: GenerationStop,
    response_validity: ResponseValidity,
    step_outcome: StepOutcome,
    failure_reason: ?FailureReason = null,
    last_agent_message: ?[]const u8,
    act_count: usize,
    recovery_attempts: usize,

    pub fn deinit(self: *TurnResult, alloc: Allocator) void {
        if (self.last_agent_message) |m| alloc.free(m);
        self.last_agent_message = null;
    }
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
    malformed_tool_call,
    truncated_tool_call,
};

pub const RecoveryDecision = enum {
    retry,
    stalled,
};

pub const StallReason = enum {
    recovery_budget_exhausted,
    plan_stalled,
    action_loop,
};

pub const FailureReason = enum {
    protocol_error,
    provider_error,
    rate_limit_exhausted,
    provider_unavailable,
    tool_error,
};

pub const ActTransition = union(enum) {
    next_act: void,
    retry_same_act: void,
    complete: void,
    stall: StallReason,
    fail: FailureReason,
    cancel: void,
};

pub const ResponseDiagnostics = struct {
    http_code: u32 = 200,
    backend: []const u8 = "",
    model: []const u8 = "",
    terminal_event_received: bool = false,
    finish_reason_received: bool = false,
    thinking_length: usize = 0,
    has_text: bool = false,
    has_tool_calls: bool = false,
    raw_snippet: ?[]const u8 = null,
};

pub const ModelResponse = struct {
    generation_stop: GenerationStop,
    validity: ResponseValidity,
    content: []ContentBlock,
    usage: Usage = .{},
    diagnostics: ResponseDiagnostics,
};

/// Bounded recovery for unusable responses in the current Act.
/// This is not a task-duration or total-Act limit.
pub const ResponseRecoveryBudget = struct {
    thinking_only: u8 = 2,
    empty_response: u8 = 20,
    missing_terminal: u8 = 20,
    stream_aborted: u8 = 20,
    malformed_tool_call: u8 = 2,
    truncated_tool_call: u8 = 2,

    pub fn consume(self: *ResponseRecoveryBudget, class: RecoveryClass) RecoveryDecision {
        // PSEUDOCODE:
        // 1. Select the budget for this response failure class.
        // 2. Consume one retry while capacity remains.
        // 3. Return stalled once the bounded class is exhausted.
        const counter = switch (class) {
            .thinking_only => &self.thinking_only,
            .empty_response => &self.empty_response,
            .missing_terminal => &self.missing_terminal,
            .stream_aborted => &self.stream_aborted,
            .malformed_tool_call => &self.malformed_tool_call,
            .truncated_tool_call => &self.truncated_tool_call,
        };
        if (counter.* == 0) return .stalled;
        counter.* -= 1;
        return .retry;
    }
};

/// A tool call is executable only when it has a valid terminal event,
/// a non-empty sanitized name, complete arguments, and JSON-object arguments.
pub fn isExecutableToolUse(tool: ToolUse, stop: GenerationStop) bool {
    // PSEUDOCODE:
    // 1. Require a provider terminal state that can contain an executable tool call.
    // 2. Require a non-empty tool name and complete JSON-object arguments.
    // 3. Reject malformed JSON even when its braces happen to be balanced.
    if (stop != .tool_call and stop != .natural_end) return false;
    if (std.mem.trim(u8, tool.name, " \r\n\t").len == 0) return false;

    return isValidJsonObject(tool.input_json);
}

/// Returns true when `raw` parses as a JSON object.
/// Truncated tool-call arguments (invalid JSON) must never be sent to
/// upstreams verbatim — OpenAI-compatible providers reject the whole
/// request with HTTP 400 "tool call arguments must be valid JSON".
pub fn isValidJsonObject(raw: []const u8) bool {
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        std.heap.page_allocator,
        raw,
        .{},
    ) catch return false;
    defer parsed.deinit();
    return parsed.value == .object;
}

pub fn responseRecoveryClass(validity: ResponseValidity, gen_stop: GenerationStop) ?RecoveryClass {
    // PSEUDOCODE:
    // 1. Keep transport-specific recovery classes independent.
    // 2. Use content-shape budgets only for thinking-only and empty responses.
    // 3. Leave valid final/action responses outside response recovery.
    return switch (gen_stop) {
        .stream_aborted => if (validity == .partial_text) null else .stream_aborted,
        .missing_terminal_event => if (validity == .partial_text) null else .missing_terminal,
        else => switch (validity) {
            .thinking_only => .thinking_only,
            .empty, .whitespace_only => .empty_response,
            .malformed_tool_call => .malformed_tool_call,
            // P-INTERRUPT: a tool_call stop with a truncated tool payload
            // (classified partial_text) is bounded-retriable.
            .partial_text => if (gen_stop == .tool_call) .truncated_tool_call else null,
            else => null,
        },
    };
}

/// Classifies normalized content before stop-reason dispatch.
/// Precedence:
/// 1. Native tools.
/// 2. CodeAct.
/// 3. Meaningful final text.
/// 4. Partial text.
/// 5. Thinking-only.
/// 6. Whitespace-only.
/// 7. Malformed tool call.
/// 8. Empty.
pub fn classifyResponse(response: *const Response, has_codeact: bool) ResponseValidity {
    const gen_stop = response.getGenerationStop();
    var has_valid_tools = false;
    var has_malformed_tools = false;
    var has_meaningful_text = false;
    var has_text = false;
    var has_thinking = false;

    for (response.content.items) |block| switch (block) {
        .tool_use => |tool| {
            if (isExecutableToolUse(tool, gen_stop)) {
                has_valid_tools = true;
            } else {
                has_malformed_tools = true;
            }
        },
        .text => |text| {
            if (text.len > 0) has_text = true;
            if (std.mem.trim(u8, text, " \r\n\t").len > 0) has_meaningful_text = true;
        },
        .thinking => |th| {
            if (std.mem.trim(u8, th.thinking, " \r\n\t").len > 0) has_thinking = true;
        },
        else => {},
    };

    if (has_valid_tools and !has_malformed_tools) return .native_tool_calls;
    if (has_codeact and !has_malformed_tools) return .codeact;
    if (has_meaningful_text and !has_malformed_tools) {
        if (gen_stop == .natural_end) {
            return .final_text;
        }
        return .partial_text;
    }
    // PSEUDOCODE:
    // 1. An interrupted tool payload cannot be executed safely.
    // 2. Preserve it as partial response state so the agent can continue.
    if (has_malformed_tools and switch (gen_stop) {
        .max_tokens, .stop_sequence, .missing_terminal_event, .stream_aborted => true,
        else => false,
    }) return .partial_text;
    if (has_meaningful_text) {
        return .partial_text;
    }
    if (has_thinking and !has_text and !has_valid_tools and !has_malformed_tools) return .thinking_only;
    if (has_text and !has_meaningful_text and !has_valid_tools and !has_malformed_tools) return .whitespace_only;
    if (has_malformed_tools or (has_valid_tools and has_malformed_tools)) return .malformed_tool_call;
    if (has_thinking) return .thinking_only;
    return .empty;
}

/// Maps validated provider state to an agent-level action.
/// Decision precedence:
/// cancellation -> malformed payload -> native tools -> CodeAct -> meaningful final text -> partial continuation -> thinking/empty recovery -> provider/protocol failure.
pub fn decideAgentAction(
    generation_stop: GenerationStop,
    validity: ResponseValidity,
    is_cancelled: bool,
) AgentDecision {
    if (is_cancelled or generation_stop == .cancelled) return .cancel;
    if (validity == .malformed_tool_call) return .retry_transient;
    if (validity == .native_tool_calls) return .execute_native_tools;
    if (validity == .codeact) return .execute_codeact;
    if (validity == .final_text) {
        if (generation_stop == .natural_end) return .deliver_final_answer;
        return .request_continuation;
    }
    if (validity == .partial_text) {
        // PSEUDOCODE:
        // 1. A partial payload interrupted at a tool_call stop is bounded-retriable.
        // 2. Other resumable partial payloads request continuation.
        // 3. Non-resumable partial payloads fail the protocol.
        if (generation_stop == .tool_call) return .retry_transient;
        if (generation_stop == .stream_aborted or
            generation_stop == .missing_terminal_event or
            generation_stop == .max_tokens or
            generation_stop == .stop_sequence)
        {
            return .request_continuation;
        }
        return .fail_protocol;
    }
    if (validity == .thinking_only or validity == .whitespace_only or validity == .empty) {
        if (generation_stop == .stop_sequence) return .fail_stalled;
        if (generation_stop == .natural_end or
            generation_stop == .stream_aborted or
            generation_stop == .missing_terminal_event or
            generation_stop == .provider_error or
            generation_stop == .max_tokens)
        {
            return .retry_transient;
        }
        return .fail_protocol;
    }
    if (generation_stop == .provider_error) return .retry_transient;
    return .fail_protocol;
}

pub fn decideAgentActionFromStopReason(
    stop_reason: StopReason,
    validity: ResponseValidity,
    has_codeact: bool,
) AgentDecision {
    _ = has_codeact;
    const gen_stop = toGenerationStop(stop_reason, 200);
    return decideAgentAction(gen_stop, validity, false);
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
    try std.testing.expectEqual(AgentDecision.retry_transient, decideAgentAction(.natural_end, .thinking_only, false));

    var budget = ResponseRecoveryBudget{};
    try std.testing.expectEqual(RecoveryDecision.retry, budget.consume(.thinking_only));
    try std.testing.expectEqual(RecoveryDecision.retry, budget.consume(.thinking_only));
    try std.testing.expectEqual(RecoveryDecision.stalled, budget.consume(.thinking_only));
}

test "RFC-023: native tool takes precedence over final text" {
    const alloc = std.testing.allocator;
    var response = Response.init(alloc);
    defer response.deinit();
    response.stop_reason = .tool_use;
    try response.content.append(alloc, .{ .text = try alloc.dupe(u8, "working") });
    try response.content.append(alloc, .{ .tool_use = .{
        .id = try alloc.dupe(u8, "call_1"),
        .name = try alloc.dupe(u8, "bash"),
        .input_json = try alloc.dupe(u8, "{}"),
    } });

    try std.testing.expectEqual(ResponseValidity.native_tool_calls, classifyResponse(&response, true));
    try std.testing.expectEqual(AgentDecision.execute_native_tools, decideAgentAction(.tool_call, .native_tool_calls, false));
}

test "RFC-023: explicit GenerationStop overrides legacy StopReason" {
    const alloc = std.testing.allocator;
    var response = Response.init(alloc);
    defer response.deinit();
    response.stop_reason = .end_turn;
    response.generation_stop = .missing_terminal_event;

    try std.testing.expectEqual(GenerationStop.missing_terminal_event, response.getGenerationStop());
}

test "RFC-023: missing terminal event never becomes natural completion" {
    const alloc = std.testing.allocator;
    var response = Response.init(alloc);
    defer response.deinit();
    response.stop_reason = .missing_terminal_event;
    try response.content.append(alloc, .{ .text = try alloc.dupe(u8, "partial output") });

    try std.testing.expectEqual(GenerationStop.missing_terminal_event, response.getGenerationStop());
    try std.testing.expectEqual(ResponseValidity.partial_text, classifyResponse(&response, false));
    try std.testing.expectEqual(AgentDecision.request_continuation, decideAgentAction(response.getGenerationStop(), .partial_text, false));
}

test "RFC-023: whitespace-only and empty responses never become final answers" {
    const alloc = std.testing.allocator;
    var response = Response.init(alloc);
    defer response.deinit();
    response.stop_reason = .end_turn;
    try response.content.append(alloc, .{ .text = try alloc.dupe(u8, "   \n\t  ") });

    try std.testing.expectEqual(ResponseValidity.whitespace_only, classifyResponse(&response, false));
    try std.testing.expectEqual(AgentDecision.retry_transient, decideAgentAction(.natural_end, .whitespace_only, false));

    var empty_resp = Response.init(alloc);
    defer empty_resp.deinit();
    empty_resp.stop_reason = .end_turn;
    try std.testing.expectEqual(ResponseValidity.empty, classifyResponse(&empty_resp, false));
    try std.testing.expectEqual(AgentDecision.retry_transient, decideAgentAction(.natural_end, .empty, false));
}

test "RFC-023: resumable partial transport text stays outside recovery budget" {
    try std.testing.expectEqual(@as(?RecoveryClass, null), responseRecoveryClass(.partial_text, .missing_terminal_event));
    try std.testing.expectEqual(@as(?RecoveryClass, null), responseRecoveryClass(.partial_text, .stream_aborted));
    try std.testing.expectEqual(@as(?RecoveryClass, null), responseRecoveryClass(.partial_text, .max_tokens));
    try std.testing.expectEqual(@as(?RecoveryClass, null), responseRecoveryClass(.partial_text, .stop_sequence));
    try std.testing.expectEqual(RecoveryClass.missing_terminal, responseRecoveryClass(.thinking_only, .missing_terminal_event) orelse unreachable);
    try std.testing.expectEqual(RecoveryClass.stream_aborted, responseRecoveryClass(.empty, .stream_aborted) orelse unreachable);
}

test "RFC-023: tool arguments must be valid JSON objects" {
    const alloc = std.testing.allocator;
    var response = Response.init(alloc);
    defer response.deinit();
    response.stop_reason = .tool_use;
    response.generation_stop = .tool_call;
    try response.content.append(alloc, .{ .tool_use = .{
        .id = try alloc.dupe(u8, "call_bad_json"),
        .name = try alloc.dupe(u8, "bash"),
        .input_json = try alloc.dupe(u8, "{\"command\":tru}"),
    } });

    try std.testing.expectEqual(ResponseValidity.malformed_tool_call, classifyResponse(&response, false));
}

test "isValidJsonObject accepts objects, rejects truncated and non-object JSON" {
    try std.testing.expect(isValidJsonObject("{\"command\":\"ls\"}"));
    try std.testing.expect(isValidJsonObject("{}"));
    // Truncated tool-call arguments (the exact case that triggers upstream HTTP 400).
    try std.testing.expect(!isValidJsonObject("{\"name\": \"plan.md\", \"title\": \"plan\""));
    // Valid JSON but not an object.
    try std.testing.expect(!isValidJsonObject("[1,2,3]"));
    try std.testing.expect(!isValidJsonObject("\"string\""));
    try std.testing.expect(!isValidJsonObject(""));
    try std.testing.expect(!isValidJsonObject("not a json"));
}

test "RFC-023: malformed tool call yields malformed_tool_call and bounded retry" {
    const alloc = std.testing.allocator;
    var response = Response.init(alloc);
    defer response.deinit();
    response.stop_reason = .tool_use;
    // Malformed: arguments not a JSON object
    try response.content.append(alloc, .{ .tool_use = .{
        .id = try alloc.dupe(u8, "call_bad"),
        .name = try alloc.dupe(u8, "bash"),
        .input_json = try alloc.dupe(u8, "not a json"),
    } });

    try std.testing.expectEqual(ResponseValidity.malformed_tool_call, classifyResponse(&response, false));
    // P0-A: malformed payloads are now bounded-retriable (no more hard fail_protocol).
    try std.testing.expectEqual(AgentDecision.retry_transient, decideAgentAction(.tool_call, .malformed_tool_call, false));
    // Cancellation still wins over malformed payloads.
    try std.testing.expectEqual(AgentDecision.cancel, decideAgentAction(.tool_call, .malformed_tool_call, true));
}

test "RFC-023: malformed tool call maps to its own bounded recovery budget" {
    try std.testing.expectEqual(
        RecoveryClass.malformed_tool_call,
        responseRecoveryClass(.malformed_tool_call, .tool_call) orelse unreachable,
    );
    try std.testing.expectEqual(
        RecoveryClass.malformed_tool_call,
        responseRecoveryClass(.malformed_tool_call, .natural_end) orelse unreachable,
    );
    var budget = ResponseRecoveryBudget{};
    try std.testing.expectEqual(RecoveryDecision.retry, budget.consume(.malformed_tool_call));
    try std.testing.expectEqual(RecoveryDecision.retry, budget.consume(.malformed_tool_call));
    try std.testing.expectEqual(RecoveryDecision.stalled, budget.consume(.malformed_tool_call));
}

// P-INTERRUPT: a tool_call stop with a truncated tool payload (e.g. provider
// returned stop_reason "tool_calls" but the arguments stream was cut) is
// partial_text. It must be bounded-retriable instead of hard fail_protocol.
test "interrupted tool_call stop with partial tool payload is bounded-retriable" {
    // Interrupted tool_call stop: retriable with its own class.
    try std.testing.expectEqual(
        AgentDecision.retry_transient,
        decideAgentAction(.tool_call, .partial_text, false),
    );
    try std.testing.expectEqual(
        RecoveryClass.truncated_tool_call,
        responseRecoveryClass(.partial_text, .tool_call) orelse unreachable,
    );
    var budget = ResponseRecoveryBudget{};
    try std.testing.expectEqual(RecoveryDecision.retry, budget.consume(.truncated_tool_call));
    try std.testing.expectEqual(RecoveryDecision.retry, budget.consume(.truncated_tool_call));
    try std.testing.expectEqual(RecoveryDecision.stalled, budget.consume(.truncated_tool_call));

    // Cancellation still takes absolute precedence.
    try std.testing.expectEqual(AgentDecision.cancel, decideAgentAction(.tool_call, .partial_text, true));

    // Resumable stops remain on the continuation path (no recovery class).
    for ([_]GenerationStop{ .max_tokens, .stop_sequence, .missing_terminal_event, .stream_aborted }) |stop| {
        try std.testing.expectEqual(
            AgentDecision.request_continuation,
            decideAgentAction(stop, .partial_text, false),
        );
        try std.testing.expectEqual(@as(?RecoveryClass, null), responseRecoveryClass(.partial_text, stop));
    }
}

test "text plus truncated tool call at tool_call stop classifies as partial_text" {
    // Observed in session journal_3152517 act 20: the response carried meaningful
    // text alongside a truncated tool payload, and the stream stopped at tool_call.
    const alloc = std.testing.allocator;
    var response = Response.init(alloc);
    defer response.deinit();
    response.stop_reason = .tool_use;
    response.generation_stop = .tool_call;
    try response.content.append(alloc, .{ .text = try alloc.dupe(u8, "Let me run the build") });
    try response.content.append(alloc, .{ .tool_use = .{
        .id = try alloc.dupe(u8, "call_interrupted"),
        .name = try alloc.dupe(u8, "bash"),
        .input_json = try alloc.dupe(u8, "{\"command\":\"zig build "),
    } });

    try std.testing.expectEqual(ResponseValidity.partial_text, classifyResponse(&response, false));
}

test "RFC-023: max_tokens with thinking-only retries transiently (P0-B)" {
    try std.testing.expectEqual(AgentDecision.retry_transient, decideAgentAction(.max_tokens, .thinking_only, false));
    // Thinking-only responses map to the thinking_only content-shape budget on max_tokens.
    try std.testing.expectEqual(
        RecoveryClass.thinking_only,
        responseRecoveryClass(.thinking_only, .max_tokens) orelse unreachable,
    );
    // Empty responses hit the same max_tokens retry path.
    try std.testing.expectEqual(AgentDecision.retry_transient, decideAgentAction(.max_tokens, .empty, false));
}

test "RFC-023: incomplete max-tokens tool call requests continuation" {
    const alloc = std.testing.allocator;
    var response = Response.init(alloc);
    defer response.deinit();
    response.stop_reason = .max_tokens;
    response.generation_stop = .max_tokens;
    try response.content.append(alloc, .{ .tool_use = .{
        .id = try alloc.dupe(u8, "call_partial"),
        .name = try alloc.dupe(u8, "bash"),
        .input_json = try alloc.dupe(u8, "{\"command\":tru"),
    } });

    const validity = classifyResponse(&response, false);
    try std.testing.expectEqual(ResponseValidity.partial_text, validity);
    try std.testing.expectEqual(
        AgentDecision.request_continuation,
        decideAgentAction(.max_tokens, validity, false),
    );
}

test "RFC-023: interrupted tool payloads are non-executable partial responses" {
    const alloc = std.testing.allocator;
    for ([_]GenerationStop{ .max_tokens, .stop_sequence, .missing_terminal_event, .stream_aborted }) |stop| {
        var response = Response.init(alloc);
        defer response.deinit();
        response.generation_stop = stop;
        try response.content.append(alloc, .{ .tool_use = .{
            .id = try alloc.dupe(u8, "call_partial"),
            .name = try alloc.dupe(u8, "bash"),
            .input_json = try alloc.dupe(u8, "{\"command\":tru"),
        } });
        try std.testing.expectEqual(ResponseValidity.partial_text, classifyResponse(&response, false));
        try std.testing.expectEqual(AgentDecision.request_continuation, decideAgentAction(stop, .partial_text, false));
    }
}

test "RFC-023: non-resumable stop-sequence response stalls" {
    try std.testing.expectEqual(AgentDecision.fail_stalled, decideAgentAction(.stop_sequence, .thinking_only, false));
    try std.testing.expectEqual(AgentDecision.fail_stalled, decideAgentAction(.stop_sequence, .empty, false));
}

test "RFC-023: CodeAct takes precedence over meaningful final text" {
    const alloc = std.testing.allocator;
    var response = Response.init(alloc);
    defer response.deinit();
    response.stop_reason = .end_turn;
    try response.content.append(alloc, .{ .text = try alloc.dupe(u8, "Here is the code: ```js\nmini.echo('hi');\n```") });

    try std.testing.expectEqual(ResponseValidity.codeact, classifyResponse(&response, true));
    try std.testing.expectEqual(AgentDecision.execute_codeact, decideAgentAction(.natural_end, .codeact, false));
}

test "RFC-023: tool-only responses never deliver final answers" {
    try std.testing.expectEqual(
        AgentDecision.execute_native_tools,
        decideAgentAction(.tool_call, .native_tool_calls, false),
    );
    try std.testing.expectEqual(
        AgentDecision.execute_codeact,
        decideAgentAction(.natural_end, .codeact, false),
    );
}

test "RFC-023: valid actions produce next-Act transitions without a global limit" {
    const native = proto_act_next_action(.execute_native_tools);
    try std.testing.expect(native == .next_act);
    const codeact = proto_act_next_action(.execute_codeact);
    try std.testing.expect(codeact == .next_act);

    var acts: usize = 0;
    while (acts < 10_000) : (acts += 1) {
        const transition = proto_act_next_action(.execute_native_tools);
        if (transition != .next_act) break;
    }
    try std.testing.expectEqual(@as(usize, 10_000), acts);
}

fn proto_act_next_action(decision: AgentDecision) ActTransition {
    return switch (decision) {
        .execute_native_tools, .execute_codeact => .{ .next_act = {} },
        else => unreachable,
    };
}

test "RFC-023: cancellation takes absolute precedence" {
    try std.testing.expectEqual(AgentDecision.cancel, decideAgentAction(.cancelled, .final_text, false));
    try std.testing.expectEqual(AgentDecision.cancel, decideAgentAction(.natural_end, .final_text, true));
    try std.testing.expectEqual(AgentDecision.cancel, decideAgentAction(.tool_call, .native_tool_calls, true));
}
