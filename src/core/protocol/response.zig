//! core/protocol/response.zig — AI backend response, diagnostics, and termination state types.
//!
//! Provides Response, GenerationStop, StopReason, ModelResponse, and ResponseDiagnostics.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const types = @import("types.zig");
const ContentBlock = types.ContentBlock;
const Usage = types.Usage;

// ---------------------------------------------------------------------------
// Response & Stop Reasons
// ---------------------------------------------------------------------------

/// Normalized provider generation termination state.
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
    /// Stream aborted by idle stall watchdog — partial
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

/// Validated shape of a backend response payload.
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

/// Complete response from an AI backend.
/// Call `deinit` when finished to free memory.
pub const Response = struct {
    allocator: Allocator,
    /// All content blocks in the response.
    content: ArrayList(ContentBlock),
    /// Legacy provider stop reason retained for wire/log compatibility.
    stop_reason: StopReason,
    /// Normalized generation termination state.
    /// Null means the legacy backend adapter has not normalized a terminal event yet.
    generation_stop: ?GenerationStop = null,
    /// HTTP status code (in case of error/unknown)
    http_code: u32 = 200,
    /// Raw debug info from backend (when stop_reason == .unknown)
    raw_debug_info: ?[]const u8,
    /// Actual token usage from backend. Zero if not reported.
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

test "provider response diagnostics are bounded" {
    const raw = "secret-bearing-response" ** 1000;
    try std.testing.expectEqual(MAX_RESPONSE_SNIPPET_LEN, boundedResponseSnippet(raw).len);
}
