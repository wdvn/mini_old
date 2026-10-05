//! core/protocol/decision.zig — Agent Decision, Turn Outcome, and Recovery logic.
//!
//! Provides StepOutcome, TurnOutcome, TurnResult, AgentDecision, RecoveryClass,
//! ResponseRecoveryBudget, classifyResponse, decideAgentAction, and related helpers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const ToolUse = types.ToolUse;
const ContentBlock = types.ContentBlock;

const response_mod = @import("response.zig");
const GenerationStop = response_mod.GenerationStop;
const StopReason = response_mod.StopReason;
const Response = response_mod.Response;
const ResponseValidity = response_mod.ResponseValidity;
const toGenerationStop = response_mod.toGenerationStop;

// ---------------------------------------------------------------------------
// Outcomes & Decisions
// ---------------------------------------------------------------------------

/// StepOutcome describing the immediate action taken for a step.
pub const StepOutcome = enum {
    actions_executed,
    final_answer,
    continuation_requested,
    transient_retry,
    protocol_failure,
    provider_failure,
    cancelled,
};

/// Terminal outcome of a complete user turn.
pub const TurnOutcome = enum {
    completed,
    stalled,
    failed,
    blocked,
    cancelled,
};

/// Public result returned after a normal terminal turn path.
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

/// Agent-level action selected after response classification.
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
// Tests
// ---------------------------------------------------------------------------

test "thinking-only natural end retries then stalls" {
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

test "native tool takes precedence over final text" {
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

test "explicit GenerationStop overrides legacy StopReason" {
    const alloc = std.testing.allocator;
    var response = Response.init(alloc);
    defer response.deinit();
    response.stop_reason = .end_turn;
    response.generation_stop = .missing_terminal_event;

    try std.testing.expectEqual(GenerationStop.missing_terminal_event, response.getGenerationStop());
}

test "missing terminal event never becomes natural completion" {
    const alloc = std.testing.allocator;
    var response = Response.init(alloc);
    defer response.deinit();
    response.stop_reason = .missing_terminal_event;
    try response.content.append(alloc, .{ .text = try alloc.dupe(u8, "partial output") });

    try std.testing.expectEqual(GenerationStop.missing_terminal_event, response.getGenerationStop());
    try std.testing.expectEqual(ResponseValidity.partial_text, classifyResponse(&response, false));
    try std.testing.expectEqual(AgentDecision.request_continuation, decideAgentAction(response.getGenerationStop(), .partial_text, false));
}

test "whitespace-only and empty responses never become final answers" {
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

test "resumable partial transport text stays outside recovery budget" {
    try std.testing.expectEqual(@as(?RecoveryClass, null), responseRecoveryClass(.partial_text, .missing_terminal_event));
    try std.testing.expectEqual(@as(?RecoveryClass, null), responseRecoveryClass(.partial_text, .stream_aborted));
    try std.testing.expectEqual(@as(?RecoveryClass, null), responseRecoveryClass(.partial_text, .max_tokens));
    try std.testing.expectEqual(@as(?RecoveryClass, null), responseRecoveryClass(.partial_text, .stop_sequence));
    try std.testing.expectEqual(RecoveryClass.missing_terminal, responseRecoveryClass(.thinking_only, .missing_terminal_event) orelse unreachable);
    try std.testing.expectEqual(RecoveryClass.stream_aborted, responseRecoveryClass(.empty, .stream_aborted) orelse unreachable);
}

test "tool arguments must be valid JSON objects" {
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
    try std.testing.expect(!isValidJsonObject("{\"name\": \"plan.md\", \"title\": \"plan\""));
    try std.testing.expect(!isValidJsonObject("[1,2,3]"));
    try std.testing.expect(!isValidJsonObject("\"string\""));
    try std.testing.expect(!isValidJsonObject(""));
    try std.testing.expect(!isValidJsonObject("not a json"));
}

test "malformed tool call yields malformed_tool_call and bounded retry" {
    const alloc = std.testing.allocator;
    var response = Response.init(alloc);
    defer response.deinit();
    response.stop_reason = .tool_use;
    try response.content.append(alloc, .{ .tool_use = .{
        .id = try alloc.dupe(u8, "call_bad"),
        .name = try alloc.dupe(u8, "bash"),
        .input_json = try alloc.dupe(u8, "not a json"),
    } });

    try std.testing.expectEqual(ResponseValidity.malformed_tool_call, classifyResponse(&response, false));
    try std.testing.expectEqual(AgentDecision.retry_transient, decideAgentAction(.tool_call, .malformed_tool_call, false));
    try std.testing.expectEqual(AgentDecision.cancel, decideAgentAction(.tool_call, .malformed_tool_call, true));
}

test "malformed tool call maps to its own bounded recovery budget" {
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

test "interrupted tool_call stop with partial tool payload is bounded-retriable" {
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

    try std.testing.expectEqual(AgentDecision.cancel, decideAgentAction(.tool_call, .partial_text, true));

    for ([_]GenerationStop{ .max_tokens, .stop_sequence, .missing_terminal_event, .stream_aborted }) |stop| {
        try std.testing.expectEqual(
            AgentDecision.request_continuation,
            decideAgentAction(stop, .partial_text, false),
        );
        try std.testing.expectEqual(@as(?RecoveryClass, null), responseRecoveryClass(.partial_text, stop));
    }
}

test "text plus truncated tool call at tool_call stop classifies as partial_text" {
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

test "max_tokens with thinking-only retries transiently (P0-B)" {
    try std.testing.expectEqual(AgentDecision.retry_transient, decideAgentAction(.max_tokens, .thinking_only, false));
    try std.testing.expectEqual(
        RecoveryClass.thinking_only,
        responseRecoveryClass(.thinking_only, .max_tokens) orelse unreachable,
    );
    try std.testing.expectEqual(AgentDecision.retry_transient, decideAgentAction(.max_tokens, .empty, false));
}

test "incomplete max-tokens tool call requests continuation" {
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

test "interrupted tool payloads are non-executable partial responses" {
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

test "non-resumable stop-sequence response stalls" {
    try std.testing.expectEqual(AgentDecision.fail_stalled, decideAgentAction(.stop_sequence, .thinking_only, false));
    try std.testing.expectEqual(AgentDecision.fail_stalled, decideAgentAction(.stop_sequence, .empty, false));
}

test "CodeAct takes precedence over meaningful final text" {
    const alloc = std.testing.allocator;
    var response = Response.init(alloc);
    defer response.deinit();
    response.stop_reason = .end_turn;
    try response.content.append(alloc, .{ .text = try alloc.dupe(u8, "Here is the code: ```js\nmini.echo('hi');\n```") });

    try std.testing.expectEqual(ResponseValidity.codeact, classifyResponse(&response, true));
    try std.testing.expectEqual(AgentDecision.execute_codeact, decideAgentAction(.natural_end, .codeact, false));
}

test "tool-only responses never deliver final answers" {
    try std.testing.expectEqual(
        AgentDecision.execute_native_tools,
        decideAgentAction(.tool_call, .native_tool_calls, false),
    );
    try std.testing.expectEqual(
        AgentDecision.execute_codeact,
        decideAgentAction(.natural_end, .codeact, false),
    );
}

test "valid actions produce next-Act transitions without a global limit" {
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

test "cancellation takes absolute precedence" {
    try std.testing.expectEqual(AgentDecision.cancel, decideAgentAction(.cancelled, .final_text, false));
    try std.testing.expectEqual(AgentDecision.cancel, decideAgentAction(.natural_end, .final_text, true));
    try std.testing.expectEqual(AgentDecision.cancel, decideAgentAction(.tool_call, .native_tool_calls, true));
}
