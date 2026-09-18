//! backend/openai.zig — OpenAI-compatible streaming client.
//!
//! Supports any API compatible with OpenAI Chat Completions:
//!   - OpenAI (api.openai.com)
//!   - Ollama (via /v1/chat/completions)
//!   - LM Studio, vLLM, OpenRouter, custom endpoints...
//!
//! ## Request format
//! POST {base_url}/chat/completions (if base_url does not already include /chat/completions)
//! ```json
//! { "model": "...", "stream": true, "messages": [...], "tools": [...] }
//! ```
//!
//! ## SSE response format
//! ```
//! data: {"choices":[{"delta":{"content":"hello"},"finish_reason":null}]}
//! data: {"choices":[{"delta":{"tool_calls":[{"id":"...","function":{"name":"bash","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}
//! data: [DONE]
//! ```
//!
//! ## Tool calls
//! Tool calls are accumulated across multiple chunks (arguments may arrive in fragments).
//! After receiving `[DONE]`, the complete list of tool calls is appended to Response.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const proto = @import("../core/protocol.zig");
const json = @import("../core/json.zig");
const http_lib = @import("../lib/http_request.zig");
const main = @import("../main.zig");
const utils = @import("../core/utils.zig");
const provider = @import("provider.zig");
const JsProviderAdapter = @import("js_provider.zig").JsProviderAdapter;
const ThinkingFilter = @import("thinking_filter.zig").Filter;

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Protocol Mode & Auto-Negotiation (ISSUE-BACKEND-001)
// ---------------------------------------------------------------------------

/// Protocol mode for OpenAI-compatible backend.
pub const ProtocolMode = enum {
    auto,
    chat_completions,
    responses,

    pub fn fromString(s: []const u8) ProtocolMode {
        if (std.mem.eql(u8, s, "chat") or std.mem.eql(u8, s, "chat_completions") or std.mem.eql(u8, s, "completions")) return .chat_completions;
        if (std.mem.eql(u8, s, "responses") or std.mem.eql(u8, s, "response")) return .responses;
        return .auto;
    }
};

/// Extracts root base URL (strips endpoint suffixes if present).
pub fn getRootApiUrl(base_url: []const u8) []const u8 {
    const url = std.mem.trimEnd(u8, base_url, "/ \t\r\n");
    const suffixes = [_][]const u8{ "/chat/completions", "/responses", "/response" };
    for (suffixes) |suffix| {
        if (std.mem.endsWith(u8, url, suffix)) {
            return std.mem.trimEnd(u8, url[0 .. url.len - suffix.len], "/");
        }
    }
    return url;
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

/// OpenAI-compatible streaming client (supports both Chat Completions API & Responses API).
pub const Client = struct {
    alloc: Allocator,
    /// API base URL (e.g. "https://api.openai.com/v1" or
    /// "http://localhost:11434/v1").
    base_url: []const u8,
    /// API key. May be empty string if endpoint does not require authentication.
    api_key: []const u8,
    /// Header name to send API key.
    api_header: []const u8,
    /// Model name (e.g. "gpt-4o-mini", "llama3").
    model: []const u8,
    /// Maximum tokens in response.
    max_tokens: u32,
    /// Use max_completion_tokens instead of max_tokens.
    use_completion_tokens: bool,
    /// Disable reasoning_effort if API does not support it alongside tool calls.
    disable_reasoning_effort: bool,
    /// Disable stream_options if compat API does not support it (RFC-006 §3.6).
    disable_stream_options: bool,
    /// Protocol mode (auto, chat_completions, responses).
    protocol_mode: ProtocolMode,
    /// Cached successfully negotiated protocol (Tier 3: Session Protocol Memory).
    cached_protocol: ?ProtocolMode,
    /// Dynamic reasoning effort override for next request ("minimal" | "low" | "medium" | "high" | "none" | null).
    active_reasoning_effort: ?[]const u8,
    /// Provider key for wire protocol quirks normalization (RFC-012).
    provider_key: []const u8 = "generic",
    /// Explicit trusted adapter source; never loaded from model output.
    provider_js: ?[]const u8 = null,

    fn loadAdapter(self: *const Client) !?*JsProviderAdapter {
        return if (self.provider_js) |source| try JsProviderAdapter.initFromSource(self.alloc, source) else null;
    }

    fn transformBody(self: *const Client, adapter: ?*JsProviderAdapter, body: []const u8) ![]const u8 {
        return if (adapter) |a| try a.transformRequest(self.alloc, body) else try self.alloc.dupe(u8, body);
    }

    /// Initialize client.
    pub fn init(alloc: Allocator, base_url: []const u8, api_key: []const u8, api_header: []const u8, model: []const u8, max_tokens: u32) Client {
        return initWithProvider(alloc, base_url, api_key, api_header, model, max_tokens, .auto, "generic");
    }

    /// Set dynamic reasoning effort override.
    pub fn setReasoningEffort(self: *Client, effort: ?[]const u8) void {
        self.active_reasoning_effort = effort;
    }

    /// Idle watchdog timeout scaled by active reasoning effort (RFC-009 Phase 5).
    /// low/minimal → tight window (routine acts finish fast); high → generous.
    fn effectiveIdleTimeout(self: *const Client) u32 {
        // Disabled? Return 0 to skip idle polling entirely.
        if (utils.getEnvSlice("MINI_WATCHDOG_ENABLED")) |s| {
            const v = std.mem.trim(u8, s, " \t");
            if (std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "off")) return 0;
        }
        if (utils.getEnvSlice("MINI_STREAM_IDLE_TIMEOUT")) |s| {
            return std.fmt.parseInt(u32, std.mem.trim(u8, s, " \t"), 10) catch 0;
        }
        const eff = self.active_reasoning_effort orelse return 30;
        if (std.mem.eql(u8, eff, "low") or std.mem.eql(u8, eff, "minimal")) return 15;
        if (std.mem.eql(u8, eff, "high")) return 60;
        return 30;
    }

    /// Initialize client with explicit protocol mode.
    pub fn initWithProtocol(alloc: Allocator, base_url: []const u8, api_key: []const u8, api_header: []const u8, model: []const u8, max_tokens: u32, protocol_mode: ProtocolMode) Client {
        return initWithProvider(alloc, base_url, api_key, api_header, model, max_tokens, protocol_mode, "generic");
    }

    /// Initialize client with explicit provider key and protocol mode (RFC-012).
    pub fn initWithProvider(alloc: Allocator, base_url: []const u8, api_key: []const u8, api_header: []const u8, model: []const u8, max_tokens: u32, protocol_mode: ProtocolMode, provider_key: []const u8) Client {
        return .{
            .alloc = alloc,
            .base_url = base_url,
            .api_key = api_key,
            .api_header = api_header,
            .model = model,
            .max_tokens = max_tokens,
            .use_completion_tokens = false,
            .disable_reasoning_effort = false,
            .disable_stream_options = false,
            .protocol_mode = protocol_mode,
            .cached_protocol = null,
            .active_reasoning_effort = null,
            .provider_key = provider_key,
        };
    }

    /// Send messages to API and receive streaming response.
    /// Supports 3-Tier Dual-Protocol Auto-Negotiation & Adaptive Fallback.
    pub fn sendMessage(
        self: *Client,
        system_prompt: []const u8,
        msgs: []const proto.Message,
        tools: []const proto.ToolDefinition,
        text_cb: ?*const fn ([]const u8) void,
        think_cb: ?*const fn ([]const u8) void,
    ) !proto.Response {
        const root_url = getRootApiUrl(self.base_url);
        const adapter = try self.loadAdapter();
        defer if (adapter) |a| a.deinit();
        const profile = if (adapter) |a| a.profile else provider.resolveProfile(self.provider_key, self.base_url);
        var active_protocol: ProtocolMode = blk: {
            // RFC-012 §7 priority: explicit OPENAI_PROTOCOL > ProviderProfile.protocol > cached auto-negotiate.
            if (self.protocol_mode == .chat_completions) break :blk .chat_completions;
            if (self.protocol_mode == .responses) break :blk .responses;
            switch (profile.protocol) {
                .chat_completions => break :blk .chat_completions,
                .responses => break :blk .responses,
                .auto => {
                    if (self.cached_protocol) |p| break :blk p;
                    break :blk .responses; // existing auto-negotiate default
                },
            }
        };

        var retry_count: u32 = 0;
        while (retry_count < 4) : (retry_count += 1) {
            const native_body = if (active_protocol == .responses)
                try buildResponsesRequestBody(self.alloc, self.model, self.max_tokens, self.disable_reasoning_effort, self.active_reasoning_effort, system_prompt, msgs, tools, profile)
            else
                try buildRequestBodyWithProfile(self.alloc, profile, self.model, self.max_tokens, self.use_completion_tokens, self.disable_reasoning_effort, self.active_reasoning_effort, self.disable_stream_options, system_prompt, msgs, tools);
            defer self.alloc.free(native_body);
            const body = try self.transformBody(adapter, native_body);
            defer self.alloc.free(body);

            // Build URL according to active protocol
            var url_buf: [512]u8 = undefined;
            const endpoint_suffix = if (active_protocol == .responses) "responses" else "chat/completions";
            const sep = if (std.mem.endsWith(u8, root_url, "/")) "" else "/";
            const url = std.fmt.bufPrint(&url_buf, "{s}{s}{s}", .{ root_url, sep, endpoint_suffix }) catch self.base_url;

            // Build auth header
            var auth_buf: [512]u8 = undefined;
            const api_key_str = if (self.api_key.len > 0) self.api_key else "nokey";
            const auth_header = if (std.mem.eql(u8, self.api_header, "Authorization"))
                std.fmt.bufPrint(&auth_buf, "Authorization: Bearer {s}", .{api_key_str}) catch "Authorization: Bearer nokey"
            else
                std.fmt.bufPrint(&auth_buf, "{s}: {s}", .{ self.api_header, api_key_str }) catch "Authorization: Bearer nokey";

            var ctx = StreamCtx{
                .alloc = self.alloc,
                .response = proto.Response.init(self.alloc),
                .adapter = adapter,
                .filter = .{ .tags = profile.thinking_tags },
                .text_cb = text_cb,
                .think_cb = think_cb,
                .line_buf = .empty,
                .tool_calls = .empty,
            };
            defer ctx.line_buf.deinit(self.alloc);
            defer ctx.tool_calls.deinit(self.alloc);
            errdefer ctx.response.deinit();
            errdefer if (ctx.raw_accum_init) ctx.raw_accum.deinit(self.alloc);

            const headers = [_][]const u8{ auth_header, "Content-Type: application/json" };
            var idle_aborted = false;
            const stream_result = http_lib.postStream(self.alloc, main.g_io, .{
                .url = url,
                .headers = &headers,
                .body = body,
                .timeout_secs = 120,
                .idle_timeout_secs = self.effectiveIdleTimeout(),
                .out_idle_aborted = &idle_aborted,
            }, StreamCtx.onChunk, &ctx);
            const req_http_code = if (stream_result) |c| c else |e| switch (e) {
                error.StreamIdleTimeout => 0, // watchdog fired; finalize below
                else => return e,
            };

            if (idle_aborted) {
                ctx.response.stop_reason = .stream_aborted;
            }

            if (ctx.line_buf.items.len > 0) {
                ctx.processLine(ctx.line_buf.items) catch {};
                ctx.line_buf.clearRetainingCapacity();
            }

            try ctx.finalizeToolCalls();
            ctx.response.http_code = if (req_http_code == 0) 598 else req_http_code; // 598 = watchdog-aborted marker

            // Auto-Negotiation & Adaptive Cross-Protocol Fallback (Tier 2)
            if (self.protocol_mode == .auto and ctx.raw_accum_init) {
                const raw_resp = ctx.raw_accum.items;

                // Fallback 1: Chat Completions -> Responses API on 400 error due to lack of support or tools/reasoning conflict
                // RFC-012 §3.6: profile-pinned protocol (e.g. deepseek/qwen/minimax/glm/kimi/vllm) must NOT cross-fallback;
                // only profiles with .auto wire protocol are allowed to negotiate up.
                if (active_protocol == .chat_completions and profile.protocol == .auto and req_http_code == 400) {
                    if (std.mem.indexOf(u8, raw_resp, "responses") != null or
                        std.mem.indexOf(u8, raw_resp, "unsupported_model") != null or
                        (std.mem.indexOf(u8, raw_resp, "reasoning") != null and tools.len > 0))
                    {
                        active_protocol = .responses;
                        self.cached_protocol = .responses;
                        if (ctx.raw_accum_init) ctx.raw_accum.deinit(self.alloc);
                        ctx.response.deinit();
                        continue;
                    }
                }

                // Fallback 2: Responses API -> Chat Completions when:
                //   - Server returns 404 (endpoint /responses does not exist), OR
                //   - Server returns 400 + "not found" (endpoint exists but model not found), OR
                //   - Server returns 400 + json_parse_error / ResponseInput (endpoint exists but does not
                //     understand Responses API JSON format — e.g. OpenAI-compat proxies like agnes).
                const responses_format_rejected = req_http_code == 400 and (std.mem.indexOf(u8, raw_resp, "not found") != null or
                    std.mem.indexOf(u8, raw_resp, "json_parse_error") != null or
                    std.mem.indexOf(u8, raw_resp, "ResponseInput") != null);
                if (active_protocol == .responses and profile.protocol == .auto and (req_http_code == 404 or responses_format_rejected)) {
                    active_protocol = .chat_completions;
                    self.cached_protocol = .chat_completions;
                    if (ctx.raw_accum_init) ctx.raw_accum.deinit(self.alloc);
                    ctx.response.deinit();
                    continue;
                }
            }

            // Retry adaptive parameters in Chat Completions
            if (req_http_code == 400 and ctx.raw_accum_init) {
                const raw_resp = ctx.raw_accum.items;
                var should_retry = false;

                if (std.mem.indexOf(u8, raw_resp, "unsupported_parameter") != null and
                    (std.mem.indexOf(u8, raw_resp, "max_tokens") != null or std.mem.indexOf(u8, raw_resp, "max_completion_tokens") != null))
                {
                    self.use_completion_tokens = !self.use_completion_tokens;
                    should_retry = true;
                }

                if (std.mem.indexOf(u8, raw_resp, "reasoning_effort") != null) {
                    self.disable_reasoning_effort = true;
                    should_retry = true;
                }

                // RFC-006 §3.6: stream_options not supported by older compat APIs
                if (std.mem.indexOf(u8, raw_resp, "stream_options") != null or
                    std.mem.indexOf(u8, raw_resp, "include_usage") != null)
                {
                    self.disable_stream_options = true;
                    should_retry = true;
                }

                if (should_retry) {
                    if (ctx.raw_accum_init) ctx.raw_accum.deinit(self.alloc);
                    ctx.response.deinit();
                    continue; // Retry
                }
            }

            // Remember successful protocol (Tier 3: Protocol Memory Caching)
            if (req_http_code == 200 and self.protocol_mode == .auto) {
                self.cached_protocol = active_protocol;
            }

            if ((ctx.response.stop_reason == .unknown or req_http_code >= 400) and ctx.raw_accum_init) {
                if (ctx.response.raw_debug_info == null) {
                    ctx.response.raw_debug_info = ctx.alloc.dupe(u8, ctx.raw_accum.items) catch null;
                }
            }
            if (ctx.raw_accum_init) ctx.raw_accum.deinit(self.alloc);

            return ctx.response;
        }
        return error.MaxRetriesExceeded;
    }
};

// ---------------------------------------------------------------------------
// Request building
// ---------------------------------------------------------------------------

/// Build request body for OpenAI Responses API (POST /v1/responses).
pub fn buildResponsesRequestBody(
    alloc: Allocator,
    model: []const u8,
    max_tokens: u32,
    disable_reasoning_effort: bool,
    reasoning_effort: ?[]const u8,
    system_prompt: []const u8,
    msgs: []const proto.Message,
    tools: []const proto.ToolDefinition,
    profile: provider.ProviderProfile,
) ![]u8 {
    var buf = utils.BufWriter.init(alloc);
    errdefer buf.deinit();
    const w = &buf;

    _ = max_tokens;

    try w.print("{{\"model\":\"{s}\",\"stream\":true", .{model});

    if (!disable_reasoning_effort) {
        // RFC-012: providers with unsupported reasoning_param (deepseek/minimax/glm)
        // must never emit any reasoning field, even when forced onto the Responses API.
        if (profile.reasoning_param != .unsupported) {
            if (reasoning_effort) |effort| {
                if (!std.mem.eql(u8, effort, "none")) {
                    try w.print(",\"reasoning\":{{\"effort\":\"{s}\"}}", .{effort});
                }
            } else {
                try w.writeAll(",\"reasoning\":{\"effort\":\"medium\"}");
            }
        }
    }

    if (system_prompt.len > 0) {
        const escaped_sys = try json.escape(alloc, system_prompt);
        defer alloc.free(escaped_sys);
        try w.print(",\"instructions\":\"{s}\"", .{escaped_sys});
    }

    if (tools.len > 0) {
        try w.writeAll(",\"tools\":[");
        for (tools, 0..) |td, ti| {
            if (ti > 0) try w.writeByte(',');
            const escaped_desc = try json.escape(alloc, td.description);
            defer alloc.free(escaped_desc);
            try w.print(
                \\{{"type":"function","name":"{s}","description":"{s}","parameters":{s}}}
            , .{ td.name, escaped_desc, td.input_schema_json });
        }
        try w.writeAll("]");
    }

    try w.writeAll(",\"input\":[");
    var first_item = true;
    for (msgs) |msg| {
        for (msg.content) |block| {
            switch (block) {
                .text => |t| {
                    if (t.len == 0) continue;
                    if (!first_item) try w.writeByte(',');
                    first_item = false;
                    const escaped = try json.escape(alloc, t);
                    defer alloc.free(escaped);
                    try w.print("{{\"role\":\"{s}\",\"content\":\"{s}\"}}", .{ msg.role.toJson(), escaped });
                },
                .tool_use => |tu| {
                    if (!first_item) try w.writeByte(',');
                    first_item = false;
                    const escaped_args = try json.escape(alloc, tu.input_json);
                    defer alloc.free(escaped_args);
                    try w.print(
                        \\{{"type":"function_call","call_id":"{s}","name":"{s}","arguments":"{s}"}}
                    , .{ tu.id, tu.name, escaped_args });
                },
                .tool_result => |tr| {
                    if (!first_item) try w.writeByte(',');
                    first_item = false;
                    const escaped = try json.escape(alloc, tr.content);
                    defer alloc.free(escaped);
                    try w.print(
                        \\{{"type":"function_call_output","call_id":"{s}","output":"{s}"}}
                    , .{ tr.tool_use_id, escaped });
                },
                .image => |img| {
                    if (!first_item) try w.writeByte(',');
                    first_item = false;
                    try w.print(
                        \\{{"type":"input_image","image_url":"data:{s};base64,{s}"}}
                    , .{ img.media_type, img.data });
                },
                .thinking => {},
            }
        }
    }
    try w.writeAll("]}");

    return buf.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Chat Completions Request building
// ---------------------------------------------------------------------------

/// Build request body for OpenAI Chat Completions API with a specific ProviderProfile (RFC-012).
pub fn buildRequestBodyWithProfile(
    alloc: Allocator,
    profile: provider.ProviderProfile,
    model: []const u8,
    max_tokens: u32,
    use_completion_tokens: bool,
    disable_reasoning_effort: bool,
    reasoning_effort: ?[]const u8,
    disable_stream_options: bool,
    system_prompt: []const u8,
    msgs: []const proto.Message,
    tools: []const proto.ToolDefinition,
) ![]u8 {
    var buf = utils.BufWriter.init(alloc);
    errdefer buf.deinit();
    const w = &buf;

    var reasoning_buf: [64]u8 = undefined;
    const reasoning_effort_str: []const u8 = blk: {
        if (disable_reasoning_effort) break :blk "";
        if (profile.reasoning_param == .unsupported) break :blk "";
        if (reasoning_effort) |effort| {
            if (std.mem.eql(u8, effort, "none")) break :blk "";
            if (profile.reasoning_param == .top_level_effort) {
                break :blk std.fmt.bufPrint(&reasoning_buf, "\"reasoning_effort\":\"{s}\",", .{effort}) catch "";
            } else if (profile.reasoning_param == .nested_reasoning_object) {
                break :blk std.fmt.bufPrint(&reasoning_buf, "\"reasoning\":{{\"effort\":\"{s}\"}},", .{effort}) catch "";
            }
        }
        break :blk "";
    };
    // RFC-006 §3.6: adaptive stream_options — omit if compat API or provider does not support it
    const effective_stream_opts = !disable_stream_options and profile.supports_stream_options;
    const stream_options_str = if (effective_stream_opts) ",\"stream_options\":{\"include_usage\":true}" else "";

    const effective_use_completion_tokens = use_completion_tokens or profile.use_completion_tokens;
    if (effective_use_completion_tokens) {
        try w.print(
            \\{{"model":"{s}","max_completion_tokens":{d},{s}"stream":true{s}
        , .{ model, max_tokens, reasoning_effort_str, stream_options_str });
    } else {
        try w.print(
            \\{{"model":"{s}","max_tokens":{d},{s}"stream":true{s}
        , .{ model, max_tokens, reasoning_effort_str, stream_options_str });
    }

    // Tool definitions (placed before messages to ensure static 100% JSON prefix between turns)
    if (tools.len > 0) {
        try w.writeAll(",\"tools\":[");
        for (tools, 0..) |td, ti| {
            if (ti > 0) try w.writeByte(',');
            const escaped_desc = try json.escape(alloc, td.description);
            defer alloc.free(escaped_desc);
            try w.print(
                \\{{"type":"function","function":{{"name":"{s}","description":"{s}","parameters":{s}}}}}
            , .{ td.name, escaped_desc, td.input_schema_json });
        }
        try w.writeAll("],\"tool_choice\":\"auto\"");
    }

    try w.writeAll(",\"messages\":[");

    // System message
    if (system_prompt.len > 0) {
        const escaped_sys = try json.escape(alloc, system_prompt);
        defer alloc.free(escaped_sys);
        try w.print("{{\"role\":\"system\",\"content\":\"{s}\"}}", .{escaped_sys});
        if (msgs.len > 0) try w.writeByte(',');
    }

    // Messages
    var first_msg = true;
    for (msgs) |msg| {
        // Check if message has tool_results
        var has_tool_results = false;
        var has_other_blocks = false;
        for (msg.content) |block| {
            if (block == .tool_result) {
                has_tool_results = true;
            } else {
                has_other_blocks = true;
            }
        }

        if (has_tool_results) {
            // Encode all tool_results as "tool" role messages
            for (msg.content) |block| {
                if (block == .tool_result) {
                    if (!first_msg) try w.writeByte(',');
                    first_msg = false;
                    const tr = block.tool_result;
                    const escaped = try json.escape(alloc, tr.content);
                    defer alloc.free(escaped);
                    try w.print(
                        \\{{"role":"tool","tool_call_id":"{s}","content":"{s}"}}
                    , .{ tr.tool_use_id, escaped });
                }
            }
            if (!has_other_blocks) continue;
            // Otherwise, continue to encode non-tool blocks (e.g. attached images) as standard message
        }

        // Standard user or assistant message
        if (!first_msg) try w.writeByte(',');
        first_msg = false;
        try w.print("{{\"role\":\"{s}\",", .{msg.role.toJson()});

        var has_images = false;
        var reasoning_text: ?[]const u8 = null;
        for (msg.content) |block| {
            if (block == .image) {
                has_images = true;
            } else if (block == .thinking) {
                reasoning_text = block.thinking.thinking;
            }
        }

        if (has_images) {
            try w.writeAll("\"content\":[");
            var first_cb = true;
            for (msg.content) |block| {
                switch (block) {
                    .text => |t| {
                        if (t.len == 0) continue;
                        if (!first_cb) try w.writeByte(',');
                        first_cb = false;
                        const escaped = try json.escape(alloc, t);
                        defer alloc.free(escaped);
                        try w.print("{{\"type\":\"text\",\"text\":\"{s}\"}}", .{escaped});
                    },
                    .image => |img| {
                        if (!first_cb) try w.writeByte(',');
                        first_cb = false;
                        try w.print(
                            \\{{"type":"image_url","image_url":{{"url":"data:{s};base64,{s}"}}}}
                        , .{ img.media_type, img.data });
                    },
                    else => {},
                }
            }
            try w.writeByte(']');
        } else {
            var has_text = false;
            var text_content: ?[]const u8 = null;
            for (msg.content) |block| {
                if (block == .text) {
                    has_text = true;
                    text_content = block.text;
                    break;
                }
            }

            if (has_text and text_content != null) {
                const escaped = try json.escape(alloc, text_content.?);
                defer alloc.free(escaped);
                try w.print("\"content\":\"{s}\"", .{escaped});
            } else {
                try w.print("\"content\":null", .{});
            }
        }

        // Echo reasoning_content for providers requiring it in assistant history (DeepSeek)
        if (msg.role == .assistant and reasoning_text != null) {
            if (profile.echo_policy == .echo_required or profile.echo_policy == .echo_optional) {
                const escaped_rt = try json.escape(alloc, reasoning_text.?);
                defer alloc.free(escaped_rt);
                try w.print(",\"reasoning_content\":\"{s}\"", .{escaped_rt});
            }
        }

        // Handle tool_calls
        var has_tool_calls = false;
        for (msg.content) |block| {
            if (block == .tool_use) {
                has_tool_calls = true;
                break;
            }
        }

        if (has_tool_calls) {
            try w.print(",\"tool_calls\":[", .{});
            var first_tc = true;
            for (msg.content) |block| {
                if (block == .tool_use) {
                    const tu = block.tool_use;
                    if (!first_tc) try w.writeByte(',');
                    first_tc = false;
                    const escaped_args = try json.escape(alloc, tu.input_json);
                    defer alloc.free(escaped_args);
                    try w.print(
                        \\{{"type":"function","id":"{s}","function":{{"name":"{s}","arguments":"{s}"}}}}
                    , .{ tu.id, tu.name, escaped_args });
                }
            }
            try w.writeByte(']');
        }

        try w.writeByte('}');
    }

    try w.writeByte(']');
    try w.writeByte('}');
    return buf.toOwnedSlice();
}

/// Backward compatible wrapper defaulting to generic profile.
pub fn buildRequestBody(
    alloc: Allocator,
    model: []const u8,
    max_tokens: u32,
    use_completion_tokens: bool,
    disable_reasoning_effort: bool,
    reasoning_effort: ?[]const u8,
    disable_stream_options: bool,
    system_prompt: []const u8,
    msgs: []const proto.Message,
    tools: []const proto.ToolDefinition,
) ![]u8 {
    return buildRequestBodyWithProfile(
        alloc,
        provider.getProfile("generic"),
        model,
        max_tokens,
        use_completion_tokens,
        disable_reasoning_effort,
        reasoning_effort,
        disable_stream_options,
        system_prompt,
        msgs,
        tools,
    );
}

// ---------------------------------------------------------------------------
// Streaming parser
// ---------------------------------------------------------------------------

const PartialToolCall = struct {
    id: ArrayList(u8),
    name: ArrayList(u8),
    args: ArrayList(u8),

    fn init() PartialToolCall {
        return .{
            .id = .empty,
            .name = .empty,
            .args = .empty,
        };
    }
    fn deinit(self: *PartialToolCall, alloc: std.mem.Allocator) void {
        self.id.deinit(alloc);
        self.name.deinit(alloc);
        self.args.deinit(alloc);
    }
};

const StreamCtx = struct {
    alloc: Allocator,
    response: proto.Response,
    adapter: ?*JsProviderAdapter = null,
    filter: ThinkingFilter = .{},

    text_cb: ?*const fn ([]const u8) void = null,
    think_cb: ?*const fn ([]const u8) void = null,
    line_buf: ArrayList(u8),
    tool_calls: ArrayList(PartialToolCall),
    text_accum: ArrayList(u8) = undefined,
    text_accum_init: bool = false,
    think_accum: ArrayList(u8) = undefined,
    think_accum_init: bool = false,
    raw_accum: ArrayList(u8) = undefined,
    raw_accum_init: bool = false,
    event_type: [64]u8 = undefined,
    event_type_len: usize = 0,
    finish_reason_received: bool = false,

    pub fn emitNormalized(self: *StreamCtx, text: []const u8, thinking: bool) !void {
        if (text.len == 0) return;
        if (thinking) {
            if (!self.think_accum_init) {
                self.think_accum = .empty;
                self.think_accum_init = true;
            }
            try self.think_accum.appendSlice(self.alloc, text);
            if (self.think_cb) |cb| cb(text);
        } else {
            if (!self.text_accum_init) {
                self.text_accum = .empty;
                self.text_accum_init = true;
            }
            try self.text_accum.appendSlice(self.alloc, text);
            if (self.text_cb) |cb| cb(text);
        }
    }

    fn onChunk(chunk: []const u8, userdata: *anyopaque) void {
        const self: *StreamCtx = @ptrCast(@alignCast(userdata));

        if (!self.raw_accum_init) {
            self.raw_accum = .empty;
            self.raw_accum_init = true;
        }
        if (self.raw_accum.items.len < 64 * 1024) {
            self.raw_accum.appendSlice(self.alloc, chunk) catch {};
        }

        // Init text_accum lazily
        if (!self.text_accum_init) {
            self.text_accum = .empty;
            self.text_accum_init = true;
        }

        // Feed chunk into line buffer, process complete lines
        for (chunk) |c| {
            if (c == '\n') {
                self.processLine(self.line_buf.items) catch {};
                self.line_buf.clearRetainingCapacity();
            } else {
                self.line_buf.append(self.alloc, c) catch {};
            }
        }
    }

    fn processLine(self: *StreamCtx, line: []const u8) !void {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (trimmed.len == 0) {
            self.event_type_len = 0;
            return;
        }

        if (std.mem.startsWith(u8, trimmed, "event: ")) {
            const ev = trimmed["event: ".len..];
            const n = @min(ev.len, self.event_type.len);
            @memcpy(self.event_type[0..n], ev[0..n]);
            self.event_type_len = n;
            return;
        }

        if (!std.mem.startsWith(u8, trimmed, "data: ")) return;

        const data = trimmed["data: ".len..];
        var ev: []const u8 = self.event_type[0..self.event_type_len];
        if (json.findString(data, "type")) |t| {
            if (std.mem.startsWith(u8, t, "response.")) {
                ev = t;
            }
        }

        // Handle [DONE] or Responses API completion event
        if (std.mem.eql(u8, data, "[DONE]") or std.mem.eql(u8, ev, "response.done") or std.mem.eql(u8, ev, "response.completed")) {
            // Check usage in Responses API payload if present
            if (std.mem.startsWith(u8, data, "{")) {
                const usage_obj = blk: {
                    if (json.findObject(data, "response")) |resp_obj| {
                        if (json.findObject(resp_obj, "usage")) |u| break :blk u;
                    }
                    break :blk json.findObject(data, "usage");
                };
                if (usage_obj) |u_obj| {
                    const pt = if (json.findInt(u_obj, "input_tokens", u64)) |v| v else (json.findInt(u_obj, "prompt_tokens", u64) orelse 0);
                    const ct = if (json.findInt(u_obj, "output_tokens", u64)) |v| v else (json.findInt(u_obj, "completion_tokens", u64) orelse 0);
                    const tt = if (json.findInt(u_obj, "total_tokens", u64)) |v| v else (pt + ct);
                    self.response.usage.prompt_tokens = pt;
                    self.response.usage.completion_tokens = ct;
                    self.response.usage.total_tokens = tt;
                    if (json.findObject(u_obj, "input_tokens_details")) |itd| {
                        if (json.findInt(itd, "cached_tokens", u64)) |cv| {
                            self.response.usage.cached_tokens = cv;
                        }
                    }
                    if (json.findObject(u_obj, "output_tokens_details")) |otd| {
                        if (json.findInt(otd, "reasoning_tokens", u64)) |rv| {
                            self.response.usage.reasoning_tokens = rv;
                        }
                    }
                }
            }

            try self.filter.finish(self);
            // Save accumulated thinking
            if (self.think_accum_init and self.think_accum.items.len > 0) {
                const think_text = try self.alloc.dupe(u8, self.think_accum.items);
                try self.response.content.append(self.alloc, .{ .thinking = .{ .thinking = think_text, .signature = "" } });
                self.think_accum.clearRetainingCapacity();
            }
            // Save accumulated text into response
            if (self.text_accum_init and self.text_accum.items.len > 0) {
                const text = try self.alloc.dupe(u8, self.text_accum.items);
                try self.response.content.append(self.alloc, .{ .text = text });
                self.text_accum.clearRetainingCapacity();
            }
            // Only set to end_turn if tool_use or max_tokens not already set
            if (self.response.stop_reason == .unknown and !self.finish_reason_received) {
                self.response.stop_reason = .end_turn;
            }
            return;
        }

        // Adapter overrides are evaluated once per JSON event. Null/failed extraction
        // falls back to native fields; tool calls and usage always use native parsing.
        const custom_text = if (self.adapter) |a| a.extractContent(self.alloc, data) else null;
        defer if (custom_text) |s| self.alloc.free(s);
        const custom_reasoning = if (self.adapter) |a| a.extractReasoning(self.alloc, data) else null;
        defer if (custom_reasoning) |s| self.alloc.free(s);
        if (custom_text) |s| try self.filter.feed(s, self);
        if (custom_reasoning) |s| try self.emitNormalized(s, true);

        // Responses API event handlers
        if (std.mem.eql(u8, ev, "response.output_text.delta") or std.mem.eql(u8, ev, "response.text.delta")) {
            if (json.findString(data, "delta")) |delta_text| {
                if (delta_text.len > 0) {
                    const unescaped = json.unescape(self.alloc, delta_text) catch delta_text;
                    defer if (unescaped.ptr != delta_text.ptr) self.alloc.free(unescaped);
                    if (!self.text_accum_init) {
                        self.text_accum = .empty;
                        self.text_accum_init = true;
                    }
                    if (custom_text == null) try self.filter.feed(unescaped, self);
                }
            }
            return;
        }

        if (std.mem.eql(u8, ev, "response.reasoning_text.delta") or std.mem.eql(u8, ev, "response.reasoning.delta")) {
            if (json.findString(data, "delta")) |delta_text| {
                if (delta_text.len > 0) {
                    const unescaped = json.unescape(self.alloc, delta_text) catch delta_text;
                    defer if (unescaped.ptr != delta_text.ptr) self.alloc.free(unescaped);
                    if (!self.think_accum_init) {
                        self.think_accum = .empty;
                        self.think_accum_init = true;
                    }
                    if (custom_reasoning == null) try self.emitNormalized(unescaped, true);
                }
            }
            return;
        }

        if (std.mem.eql(u8, ev, "response.output_item.added")) {
            if (json.findObject(data, "item")) |item_obj| {
                const item_type = json.findString(item_obj, "type") orelse "";
                if (std.mem.eql(u8, item_type, "function_call") or std.mem.eql(u8, item_type, "tool_call")) {
                    const call_id = (try json.findStringOwned(self.alloc, item_obj, "call_id")) orelse (try json.findStringOwned(self.alloc, item_obj, "id"));
                    defer if (call_id) |cid| self.alloc.free(cid);
                    const name = try json.findStringOwned(self.alloc, item_obj, "name");
                    defer if (name) |n| self.alloc.free(n);
                    const index = json.findInt(data, "output_index", u32);
                    try self.mergeToolCallDelta(index, call_id, name, null);
                }
            }
            return;
        }

        if (std.mem.eql(u8, ev, "response.tool_call.delta") or std.mem.eql(u8, ev, "response.function_call_arguments.delta")) {
            const index = json.findInt(data, "output_index", u32) orelse json.findInt(data, "index", u32);
            const call_id = (try json.findStringOwned(self.alloc, data, "call_id")) orelse (try json.findStringOwned(self.alloc, data, "id"));
            defer if (call_id) |cid| self.alloc.free(cid);
            const name = try json.findStringOwned(self.alloc, data, "name");
            defer if (name) |n| self.alloc.free(n);
            const args = (try json.findStringOwned(self.alloc, data, "delta")) orelse (try json.findStringOwned(self.alloc, data, "arguments"));
            defer if (args) |a| self.alloc.free(a);
            try self.mergeToolCallDelta(index, call_id, name, args);
            return;
        }

        if (std.mem.eql(u8, ev, "response.output_item.done") or std.mem.eql(u8, ev, "response.tool_call.done") or std.mem.eql(u8, ev, "response.function_call_arguments.done")) {
            if (json.findObject(data, "item")) |item_obj| {
                const item_type = json.findString(item_obj, "type") orelse "";
                if (std.mem.eql(u8, item_type, "function_call") or std.mem.eql(u8, item_type, "tool_call")) {
                    const call_id = (try json.findStringOwned(self.alloc, item_obj, "call_id")) orelse (try json.findStringOwned(self.alloc, item_obj, "id"));
                    defer if (call_id) |cid| self.alloc.free(cid);
                    const name = try json.findStringOwned(self.alloc, item_obj, "name");
                    defer if (name) |n| self.alloc.free(n);
                    const args = try json.findStringOwned(self.alloc, item_obj, "arguments");
                    defer if (args) |a| self.alloc.free(a);
                    const index = json.findInt(data, "output_index", u32);
                    try self.setToolCallFinal(index, call_id, name, args);
                }
            } else {
                const call_id = (try json.findStringOwned(self.alloc, data, "call_id")) orelse (try json.findStringOwned(self.alloc, data, "id"));
                defer if (call_id) |cid| self.alloc.free(cid);
                const name = try json.findStringOwned(self.alloc, data, "name");
                defer if (name) |n| self.alloc.free(n);
                const args = try json.findStringOwned(self.alloc, data, "arguments");
                defer if (args) |a| self.alloc.free(a);
                const index = json.findInt(data, "output_index", u32);
                if (args != null or call_id != null or name != null) {
                    try self.setToolCallFinal(index, call_id, name, args);
                }
            }
            return;
        }

        // All other Responses API events (e.g. response.created, response.in_progress, response.content_part.added, etc.)
        if (std.mem.startsWith(u8, ev, "response.")) return;

        // RFC-006 §3.1: Usage JSON parse struct (nested optional)
        const UsagePromptDetails = struct {
            cached_tokens: ?u64 = null,
        };
        const UsageCompletionDetails = struct {
            reasoning_tokens: ?u64 = null,
        };
        const UsageJson = struct {
            prompt_tokens: ?u64 = null,
            completion_tokens: ?u64 = null,
            total_tokens: ?u64 = null,
            prompt_tokens_details: ?UsagePromptDetails = null,
            completion_tokens_details: ?UsageCompletionDetails = null,
            // DeepSeek alias (RFC-006 §3.1)
            prompt_cache_hit_tokens: ?u64 = null,
        };

        const Chunk = struct {
            const ChoiceDeltaToolCallFunction = struct {
                name: ?[]const u8 = null,
                arguments: ?[]const u8 = null,
            };
            const ChoiceDeltaToolCall = struct {
                index: ?u32 = null,
                id: ?[]const u8 = null,
                type: ?[]const u8 = null,
                function: ?ChoiceDeltaToolCallFunction = null,
            };
            const ChoiceDeltaDetail = struct {
                reasoning_content: ?[]const u8 = null,
                reasoning: ?[]const u8 = null,
            };
            const ChoiceDelta = struct {
                content: ?[]const u8 = null,
                reasoning_content: ?[]const u8 = null,
                // RFC-006 §3.3: OpenAI o-series/GPT-5.x uses field "reasoning"
                reasoning: ?[]const u8 = null,
                // Nested proxy/aggregator wrappers: delta.detail.reasoning_content or delta.details
                detail: ?ChoiceDeltaDetail = null,
                details: ?ChoiceDeltaDetail = null,
                tool_calls: ?[]ChoiceDeltaToolCall = null,
            };
            const Choice = struct {
                index: ?u32 = null,
                delta: ?ChoiceDelta = null,
                finish_reason: ?[]const u8 = null,
            };
            id: ?[]const u8 = null,
            object: ?[]const u8 = null,
            created: ?u64 = null,
            model: ?[]const u8 = null,
            choices: ?[]Choice = null,
            // RFC-006 §3.1: usage chunk (sent in last chunk when include_usage=true)
            usage: ?UsageJson = null,
        };

        const parsed = std.json.parseFromSlice(Chunk, self.alloc, data, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();

        const chunk = parsed.value;
        if (chunk.choices) |choices| {
            for (choices) |choice| {
                if (choice.delta) |delta| {
                    // Receive reasoning from variants:
                    // 1. DeepSeek-style: delta.reasoning_content
                    // 2. OpenAI o-series/GPT-5.x: delta.reasoning
                    // 3. Nested proxy/aggregator wrappers: delta.detail.reasoning_content / delta.details
                    const detail_reasoning = if (delta.detail) |d|
                        (d.reasoning_content orelse d.reasoning)
                    else if (delta.details) |d|
                        (d.reasoning_content orelse d.reasoning)
                    else
                        null;
                    const reasoning = delta.reasoning_content orelse delta.reasoning orelse detail_reasoning;
                    if (if (custom_reasoning == null) reasoning else null) |r| {
                        if (r.len > 0) {
                            if (!self.think_accum_init) {
                                self.think_accum = .empty;
                                self.think_accum_init = true;
                            }
                            try self.think_accum.appendSlice(self.alloc, r);
                            if (self.think_cb) |cb| cb(r);
                        }
                    }
                    if (if (custom_text == null) delta.content else null) |text| {
                        if (text.len > 0) {
                            if (!self.text_accum_init) {
                                self.text_accum = .empty;
                                self.text_accum_init = true;
                            }
                            try self.filter.feed(text, self);
                        }
                    }
                    if (delta.tool_calls) |tool_calls| {
                        // Merge by index (OpenAI streaming standard): DeepSeek and most
                        // compat providers only send id in the first chunk; subsequent chunks
                        // have only index + arguments — cannot blindly append to last item.
                        for (tool_calls) |tc_obj| {
                            const fname = if (tc_obj.function) |f| f.name else null;
                            const fargs = if (tc_obj.function) |f| f.arguments else null;
                            try self.mergeToolCallDelta(tc_obj.index, tc_obj.id, fname, fargs);
                        }
                    }
                }
                if (choice.finish_reason) |reason| {
                    self.finish_reason_received = true;
                    // RFC-006 §3.4: fully map OpenAI finish_reason
                    if (std.mem.eql(u8, reason, "tool_calls")) {
                        self.response.stop_reason = .tool_use;
                    } else if (std.mem.eql(u8, reason, "stop")) {
                        self.response.stop_reason = .end_turn;
                    } else if (std.mem.eql(u8, reason, "length")) {
                        self.response.stop_reason = .max_tokens;
                    } else if (std.mem.eql(u8, reason, "function")) {
                        // Legacy function calling → map as tool_calls
                        self.response.stop_reason = .tool_use;
                    } else if (std.mem.eql(u8, reason, "content_filter")) {
                        // Content filter → .unknown + debug info (not end_turn)
                        self.response.stop_reason = .unknown;
                    }
                }
            }
        }

        // RFC-006 §3.1: parse usage from last chunk
        if (chunk.usage) |u| {
            const cached = if (u.prompt_tokens_details) |ptd| (ptd.cached_tokens orelse 0) else (u.prompt_cache_hit_tokens orelse 0);
            const reasoning_tok = if (u.completion_tokens_details) |ctd| (ctd.reasoning_tokens orelse 0) else 0;
            self.response.usage = .{
                .prompt_tokens = u.prompt_tokens orelse 0,
                .completion_tokens = u.completion_tokens orelse 0,
                .total_tokens = u.total_tokens orelse 0,
                .cached_tokens = cached,
                .reasoning_tokens = reasoning_tok,
            };
        }
    }

    /// Merge 1 tool_call delta into the list, locating slot by index (standard
    /// OpenAI streaming). Fallback: match id, then last item. DeepSeek-style:
    /// first chunk has id+name, subsequent chunks only index+arguments.
    fn mergeToolCallDelta(self: *StreamCtx, index: ?u32, id: ?[]const u8, name: ?[]const u8, args: ?[]const u8) !void {
        var slot: ?usize = null;

        // 1. Prioritize match by id (globally unique identifier of tool call)
        if (id) |tcid| {
            for (self.tool_calls.items, 0..) |tc, i| {
                if (tc.id.items.len > 0 and std.mem.eql(u8, tc.id.items, tcid)) {
                    slot = i;
                    break;
                }
            }
        }
        // 2. Match by index if within range of existing tool_calls
        if (slot == null and index != null) {
            const idx = index.?;
            if (idx < self.tool_calls.items.len) slot = idx;
        }
        // 3. Fallback: last open item
        if (slot == null and index == null and id == null and self.tool_calls.items.len > 0) {
            slot = self.tool_calls.items.len - 1;
        }

        // No slot yet → create new item
        if (slot == null) {
            var tc = PartialToolCall.init();
            if (id) |tcid| try tc.id.appendSlice(self.alloc, tcid);
            try self.tool_calls.append(self.alloc, tc);
            slot = self.tool_calls.items.len - 1;
        } else if (id) |tcid| {
            // Slot already exists but has no id → update
            const tc = &self.tool_calls.items[slot.?];
            if (tc.id.items.len == 0) try tc.id.appendSlice(self.alloc, tcid);
        }

        const tc = &self.tool_calls.items[slot.?];
        if (name) |n| {
            if (n.len > 0) try tc.name.appendSlice(self.alloc, n);
        }
        if (args) |a| {
            if (a.len > 0) try tc.args.appendSlice(self.alloc, a);
        }
    }

    /// Update or overwrite complete tool_call information upon receiving done event
    fn setToolCallFinal(self: *StreamCtx, index: ?u32, id: ?[]const u8, name: ?[]const u8, args: ?[]const u8) !void {
        var slot: ?usize = null;

        // 1. Prioritize match by id
        if (id) |tcid| {
            for (self.tool_calls.items, 0..) |tc, i| {
                if (tc.id.items.len > 0 and std.mem.eql(u8, tc.id.items, tcid)) {
                    slot = i;
                    break;
                }
            }
        }
        // 2. Match by index if within range
        if (slot == null and index != null) {
            const idx = index.?;
            if (idx < self.tool_calls.items.len) slot = idx;
        }
        // 3. Fallback: last open item
        if (slot == null and index == null and id == null and self.tool_calls.items.len > 0) {
            slot = self.tool_calls.items.len - 1;
        }

        if (slot == null) {
            var tc = PartialToolCall.init();
            if (id) |tcid| try tc.id.appendSlice(self.alloc, tcid);
            if (name) |n| try tc.name.appendSlice(self.alloc, n);
            if (args) |a| try tc.args.appendSlice(self.alloc, a);
            try self.tool_calls.append(self.alloc, tc);
        } else {
            const tc = &self.tool_calls.items[slot.?];
            if (id) |tcid| {
                if (tc.id.items.len == 0) try tc.id.appendSlice(self.alloc, tcid);
            }
            if (name) |n| {
                if (tc.name.items.len == 0) try tc.name.appendSlice(self.alloc, n);
            }
            if (args) |a| {
                if (a.len > 0) {
                    tc.args.clearRetainingCapacity();
                    try tc.args.appendSlice(self.alloc, a);
                }
            }
        }
    }

    fn finalizeToolCalls(self: *StreamCtx) !void {
        try self.filter.finish(self);
        // Fallback: if server closed stream without [DONE] or response.completed
        if (self.think_accum_init and self.think_accum.items.len > 0) {
            const think_text = try self.alloc.dupe(u8, self.think_accum.items);
            try self.response.content.append(self.alloc, .{ .thinking = .{ .thinking = think_text, .signature = "" } });
            self.think_accum.clearRetainingCapacity();
        }
        if (self.text_accum_init and self.text_accum.items.len > 0) {
            const text = try self.alloc.dupe(u8, self.text_accum.items);
            try self.response.content.append(self.alloc, .{ .text = text });
            self.text_accum.clearRetainingCapacity();
        }
        if (self.response.content.items.len > 0 and self.response.stop_reason == .unknown and !self.finish_reason_received) {
            self.response.stop_reason = .end_turn;
        }

        for (self.tool_calls.items, 0..) |*tc, ti| {
            defer tc.deinit(self.alloc);
            if (tc.name.items.len == 0) continue;
            const clean_name = sanitizeToolName(tc.name.items) orelse continue;
            // Provider did not send id (some compat/proxies) → generate fallback id
            // so tool_result always matches tool_call_id (avoiding 400 from API).
            const id = if (tc.id.items.len > 0)
                try self.alloc.dupe(u8, tc.id.items)
            else
                try std.fmt.allocPrint(self.alloc, "call_{d}", .{ti});
            const name = try self.alloc.dupe(u8, clean_name);
            const args = if (tc.args.items.len > 0)
                try self.alloc.dupe(u8, tc.args.items)
            else
                try self.alloc.dupe(u8, "{}");
            try self.response.content.append(self.alloc, .{ .tool_use = .{
                .id = id,
                .name = name,
                .input_json = args,
            } });
        }
        if (self.tool_calls.items.len > 0 and self.response.stop_reason != .tool_use) {
            self.response.stop_reason = .tool_use;
        }
        if (self.think_accum_init) self.think_accum.deinit(self.alloc);
        if (self.text_accum_init) self.text_accum.deinit(self.alloc);
    }
};

/// Sanitize raw tool name from streaming chunks:
/// Strips trailing XML/DSML tags (`<...`), newlines, and non-identifier characters.
/// Returns null if name is empty or completely malformed.
pub fn sanitizeToolName(raw: []const u8) ?[]const u8 {
    var name = raw;
    if (std.mem.indexOfScalar(u8, name, '<')) |idx| {
        name = name[0..idx];
    }
    if (std.mem.indexOfScalar(u8, name, '\n')) |idx| {
        name = name[0..idx];
    }
    name = std.mem.trim(u8, name, " \t\r");
    if (name.len == 0) return null;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return null;
    }
    return name;
}

// ---------------------------------------------------------------------------
// Unit Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "js_provider: client loads configured adapter and transforms outgoing body" {
    var client = Client.init(testing.allocator, "http://localhost/v1", "", "Authorization", "mock", 100);
    client.provider_js =
        \\export default { protocol: "chat_completions", transformRequest(req) { req.model = "adapted"; return req; } };
    ;
    const adapter = (try client.loadAdapter()).?;
    defer adapter.deinit();
    try testing.expectEqual(provider.WireProtocol.chat_completions, adapter.profile.protocol);
    const body = try client.transformBody(adapter, "{\"model\":\"original\"}");
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("{\"model\":\"adapted\"}", body);
}

// --- Tests: streaming tool_calls gop theo index (DeepSeek style) ---

fn feedLines(ctx: anytype, lines: []const []const u8) !void {
    for (lines) |ln| try ctx.processLine(ln);
}

test "openai stream: parallel tool calls gop theo index (DeepSeek style)" {
    const alloc = testing.allocator;
    var ctx = StreamCtx{
        .alloc = alloc,
        .response = proto.Response.init(alloc),
        .line_buf = .empty,
        .tool_calls = .empty,
    };
    defer ctx.response.deinit();
    defer ctx.line_buf.deinit(alloc);
    defer ctx.tool_calls.deinit(alloc);

    // Chunk dau: id+name; cac chunk sau chi index+arguments (DeepSeek khong lap id)
    try feedLines(&ctx, &.{
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","function":{"name":"bash","arguments":"{\"com"}}]}}]}
        ,
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_b","function":{"name":"file_read","arguments":"{\"pa"}}]}}]}
        ,
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"mand\":\"ls\"}"}}]}}]}
        ,
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":"th\":\"a.zig\"}"}}]}}]}
        ,
        \\data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}
        ,
        \\data: [DONE]
    });

    try ctx.finalizeToolCalls();
    try testing.expectEqual(proto.StopReason.tool_use, ctx.response.stop_reason);
    try testing.expectEqual(@as(usize, 2), ctx.response.content.items.len);

    const first = ctx.response.content.items[0].tool_use;
    try testing.expectEqualStrings("bash", first.name);
    try testing.expectEqualStrings("call_a", first.id);
    try testing.expectEqualStrings("{\"command\":\"ls\"}", first.input_json);

    const second = ctx.response.content.items[1].tool_use;
    try testing.expectEqualStrings("file_read", second.name);
    try testing.expectEqualStrings("call_b", second.id);
    try testing.expectEqualStrings("{\"path\":\"a.zig\"}", second.input_json);
}

test "openai stream: tool call khong co id — sinh id du phong" {
    const alloc = testing.allocator;
    var ctx = StreamCtx{
        .alloc = alloc,
        .response = proto.Response.init(alloc),
        .line_buf = .empty,
        .tool_calls = .empty,
    };
    defer ctx.response.deinit();
    defer ctx.line_buf.deinit(alloc);
    defer ctx.tool_calls.deinit(alloc);

    // Provider compat khong gui id, chi index
    try feedLines(&ctx, &.{
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"glob","arguments":"{\"pat"}}]}}]}
        ,
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"tern\":\"*.zig\"}"}}]}}]}
        ,
        \\data: [DONE]
    });

    try ctx.finalizeToolCalls();
    try testing.expectEqual(proto.StopReason.tool_use, ctx.response.stop_reason);
    try testing.expectEqual(@as(usize, 1), ctx.response.content.items.len);
    const tu = ctx.response.content.items[0].tool_use;
    try testing.expectEqualStrings("glob", tu.name);
    try testing.expectEqualStrings("{\"pattern\":\"*.zig\"}", tu.input_json);
    try testing.expect(std.mem.startsWith(u8, tu.id, "call_"));
}

test "openai buildRequestBody includes stream_options, static tools prefix and clean system message" {
    const alloc = testing.allocator;
    const msgs = [_]proto.Message{};
    const tools = [_]proto.ToolDefinition{
        .{ .name = "test_tool", .description = "desc", .input_schema_json = "{}" },
    };

    const body = try buildRequestBody(alloc, "gpt-4o", 1024, false, false, null, false, "System prompt test", &msgs, &tools);
    defer alloc.free(body);

    // Check for stream_options include_usage
    try testing.expect(std.mem.indexOf(u8, body, "\"stream_options\":{\"include_usage\":true}") != null);
    // Check that System message is cleanly formatted without tabs
    try testing.expect(std.mem.indexOf(u8, body, "{\"role\":\"system\",\"content\":\"System prompt test\"}") != null);

    // Verify "tools" appears BEFORE "messages" to keep prefix 100% static
    const tools_pos = std.mem.indexOf(u8, body, "\"tools\":[");
    const msgs_pos = std.mem.indexOf(u8, body, "\"messages\":[");
    try testing.expect(tools_pos != null and msgs_pos != null);
    try testing.expect(tools_pos.? < msgs_pos.?);
}

// --- RFC-006 Tests ---

test "openai buildRequestBody: disable_stream_options omits stream_options" {
    const alloc = testing.allocator;
    const msgs = [_]proto.Message{};
    const tools = [_]proto.ToolDefinition{};

    // disable_stream_options = true → no stream_options
    const body = try buildRequestBody(alloc, "gpt-4o", 1024, false, false, null, true, "test", &msgs, &tools);
    defer alloc.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "stream_options") == null);
    try testing.expect(std.mem.indexOf(u8, body, "include_usage") == null);
}

test "openai stream: parse usage chunk (RFC-006 §3.1)" {
    const alloc = testing.allocator;
    var ctx = StreamCtx{
        .alloc = alloc,
        .response = proto.Response.init(alloc),
        .line_buf = .empty,
        .tool_calls = .empty,
    };
    defer ctx.response.deinit();
    defer ctx.line_buf.deinit(alloc);
    defer ctx.tool_calls.deinit(alloc);

    try feedLines(&ctx, &.{
        \\data: {"choices":[{"delta":{"content":"Hello"},"finish_reason":null}]}
        ,
        \\data: {"choices":[{"delta":{},"finish_reason":"stop"}]}
        ,
        \\data: {"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":50,"total_tokens":150,"prompt_tokens_details":{"cached_tokens":30},"completion_tokens_details":{"reasoning_tokens":10}}}
        ,
        \\data: [DONE]
    });

    try ctx.finalizeToolCalls();
    try testing.expectEqual(proto.StopReason.end_turn, ctx.response.stop_reason);
    try testing.expectEqual(@as(u64, 100), ctx.response.usage.prompt_tokens);
    try testing.expectEqual(@as(u64, 50), ctx.response.usage.completion_tokens);
    try testing.expectEqual(@as(u64, 150), ctx.response.usage.total_tokens);
    try testing.expectEqual(@as(u64, 30), ctx.response.usage.cached_tokens);
    try testing.expectEqual(@as(u64, 10), ctx.response.usage.reasoning_tokens);
}

test "openai stream: DeepSeek usage alias prompt_cache_hit_tokens (RFC-006 §3.1)" {
    const alloc = testing.allocator;
    var ctx = StreamCtx{
        .alloc = alloc,
        .response = proto.Response.init(alloc),
        .line_buf = .empty,
        .tool_calls = .empty,
    };
    defer ctx.response.deinit();
    defer ctx.line_buf.deinit(alloc);
    defer ctx.tool_calls.deinit(alloc);

    try feedLines(&ctx, &.{
        \\data: {"choices":[{"delta":{},"finish_reason":"stop"}]}
        ,
        \\data: {"choices":[],"usage":{"prompt_tokens":200,"completion_tokens":80,"total_tokens":280,"prompt_cache_hit_tokens":60}}
        ,
        \\data: [DONE]
    });

    try ctx.finalizeToolCalls();
    try testing.expectEqual(@as(u64, 200), ctx.response.usage.prompt_tokens);
    try testing.expectEqual(@as(u64, 60), ctx.response.usage.cached_tokens);
}

test "openai stream: delta.reasoning parsed as thinking (RFC-006 §3.3)" {
    const alloc = testing.allocator;
    var ctx = StreamCtx{
        .alloc = alloc,
        .response = proto.Response.init(alloc),
        .line_buf = .empty,
        .tool_calls = .empty,
    };
    defer ctx.response.deinit();
    defer ctx.line_buf.deinit(alloc);
    defer ctx.tool_calls.deinit(alloc);

    // OpenAI o-series/GPT-5.x uses field "reasoning" instead of "reasoning_content"
    try feedLines(&ctx, &.{
        \\data: {"choices":[{"delta":{"reasoning":"Let me think"}}]}
        ,
        \\data: {"choices":[{"delta":{"reasoning":" about this"}}]}
        ,
        \\data: {"choices":[{"delta":{"content":"The answer is 42"}}]}
        ,
        \\data: {"choices":[{"delta":{},"finish_reason":"stop"}]}
        ,
        \\data: [DONE]
    });

    try ctx.finalizeToolCalls();
    try testing.expectEqual(proto.StopReason.end_turn, ctx.response.stop_reason);
    // Has 2 content blocks: thinking + text
    try testing.expectEqual(@as(usize, 2), ctx.response.content.items.len);
    // First block: thinking
    const think_block = ctx.response.content.items[0].thinking;
    try testing.expectEqualStrings("Let me think about this", think_block.thinking);
    // Second block: text
    const text_block = ctx.response.content.items[1].text;
    try testing.expectEqualStrings("The answer is 42", text_block);
}

test "openai stream: finish_reason content_filter maps to unknown (RFC-006 §3.4)" {
    const alloc = testing.allocator;
    var ctx = StreamCtx{
        .alloc = alloc,
        .response = proto.Response.init(alloc),
        .line_buf = .empty,
        .tool_calls = .empty,
    };
    defer ctx.response.deinit();
    defer ctx.line_buf.deinit(alloc);
    defer ctx.tool_calls.deinit(alloc);

    try feedLines(&ctx, &.{
        \\data: {"choices":[{"delta":{"content":"I can't"},"finish_reason":"content_filter"}]}
        ,
        \\data: [DONE]
    });

    try ctx.finalizeToolCalls();
    // content_filter → .unknown, NOT .end_turn
    try testing.expectEqual(proto.StopReason.unknown, ctx.response.stop_reason);
}

test "openai stream: finish_reason function maps to tool_use (RFC-006 §3.4)" {
    const alloc = testing.allocator;
    var ctx = StreamCtx{
        .alloc = alloc,
        .response = proto.Response.init(alloc),
        .line_buf = .empty,
        .tool_calls = .empty,
    };
    defer ctx.response.deinit();
    defer ctx.line_buf.deinit(alloc);
    defer ctx.tool_calls.deinit(alloc);

    try feedLines(&ctx, &.{
        \\data: {"choices":[{"delta":{},"finish_reason":"function"}]}
        ,
        \\data: [DONE]
    });

    try ctx.finalizeToolCalls();
    // Legacy "function" → .tool_use
    try testing.expectEqual(proto.StopReason.tool_use, ctx.response.stop_reason);
}

// --- ISSUE-BACKEND-001 (Responses API & Auto-Negotiation Tests) ---

test "openai auto-negotiation: getRootApiUrl normalizes endpoints" {
    try testing.expectEqualStrings("https://api.openai.com/v1", getRootApiUrl("https://api.openai.com/v1"));
    try testing.expectEqualStrings("https://api.openai.com/v1", getRootApiUrl("https://api.openai.com/v1/"));
    try testing.expectEqualStrings("https://api.openai.com/v1", getRootApiUrl("https://api.openai.com/v1/chat/completions"));
    try testing.expectEqualStrings("https://api.openai.com/v1", getRootApiUrl("https://api.openai.com/v1/chat/completions/"));
    try testing.expectEqualStrings("https://api.openai.com/v1", getRootApiUrl("https://api.openai.com/v1/responses"));
    try testing.expectEqualStrings("http://localhost:11434/v1", getRootApiUrl("http://localhost:11434/v1/chat/completions"));
}

// Note: removed shouldUseResponsesApi() — auto mode defaults to prioritizing
// Responses API for all models; older backends not supporting it will automatically
// fallback to chat_completions via Adaptive Cross-Protocol Fallback (Tier 2) and
// cache the result (Tier 3). No hardcoded model list to maintain.

test "openai auto-negotiation: buildResponsesRequestBody format" {
    const alloc = testing.allocator;
    const msgs = [_]proto.Message{
        .{
            .role = .user,
            .content = &.{
                .{ .text = "Solve problem" },
            },
        },
    };
    const tools = [_]proto.ToolDefinition{
        .{ .name = "bash", .description = "Run shell", .input_schema_json = "{\"type\":\"object\"}" },
    };

    const body = try buildResponsesRequestBody(alloc, "gpt-5.6-terra", 4096, false, null, "System instructions", &msgs, &tools, provider.getProfile("openai"));
    defer alloc.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"model\":\"gpt-5.6-terra\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"instructions\":\"System instructions\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":{\"effort\":\"medium\"}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"tools\":[{\"type\":\"function\",\"name\":\"bash\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"input\":[{\"role\":\"user\",\"content\":\"Solve problem\"}]") != null);
}

test "openai stream: Responses API event-based streaming parse" {
    const alloc = testing.allocator;
    var ctx = StreamCtx{
        .alloc = alloc,
        .response = proto.Response.init(alloc),
        .line_buf = .empty,
        .tool_calls = .empty,
    };
    defer ctx.response.deinit();
    defer ctx.line_buf.deinit(alloc);
    defer ctx.tool_calls.deinit(alloc);

    try feedLines(&ctx, &.{
        \\event: response.reasoning_text.delta
        ,
        \\data: {"delta":"Thinking step 1. "}
        ,
        \\event: response.reasoning_text.delta
        ,
        \\data: {"delta":"Thinking step 2."}
        ,
        \\event: response.output_text.delta
        ,
        \\data: {"delta":"Here is the output."}
        ,
        \\event: response.tool_call.delta
        ,
        \\data: {"call_id":"call_resp_1","name":"bash","delta":"{\"command\":\"ls\"}"}
        ,
        \\event: response.done
        ,
        \\data: {"response":{"usage":{"input_tokens":120,"output_tokens":60,"total_tokens":180}}}
    });

    try ctx.finalizeToolCalls();

    try testing.expectEqual(proto.StopReason.tool_use, ctx.response.stop_reason);
    try testing.expectEqual(@as(usize, 3), ctx.response.content.items.len);

    // Block 1: Thinking
    const think = ctx.response.content.items[0].thinking;
    try testing.expectEqualStrings("Thinking step 1. Thinking step 2.", think.thinking);

    // Block 2: Text
    const text = ctx.response.content.items[1].text;
    try testing.expectEqualStrings("Here is the output.", text);

    // Block 3: Tool use
    const tu = ctx.response.content.items[2].tool_use;
    try testing.expectEqualStrings("bash", tu.name);
    try testing.expectEqualStrings("call_resp_1", tu.id);
    try testing.expectEqualStrings("{\"command\":\"ls\"}", tu.input_json);

    // Usage check
    try testing.expectEqual(@as(u64, 120), ctx.response.usage.prompt_tokens);
    try testing.expectEqual(@as(u64, 60), ctx.response.usage.completion_tokens);
    try testing.expectEqual(@as(u64, 180), ctx.response.usage.total_tokens);
}

test "openai auto-negotiation: buildResponsesRequestBody multi-turn with function_call and tool_result" {
    const alloc = testing.allocator;
    const msgs = [_]proto.Message{
        .{
            .role = .user,
            .content = &.{
                .{ .text = "List files" },
            },
        },
        .{
            .role = .assistant,
            .content = &.{
                .{ .text = "I will run the ls command." },
                .{ .tool_use = .{ .id = "call_abc123", .name = "bash", .input_json = "{\"command\":\"ls\"}" } },
            },
        },
        .{
            .role = .user,
            .content = &.{
                .{ .tool_result = .{ .tool_use_id = "call_abc123", .content = "main.zig\nbuild.zig", .is_error = false } },
            },
        },
    };
    const tools = [_]proto.ToolDefinition{
        .{ .name = "bash", .description = "Run shell", .input_schema_json = "{\"type\":\"object\"}" },
    };

    const body = try buildResponsesRequestBody(alloc, "gpt-5.6-luna", 4096, false, null, "System prompt", &msgs, &tools, provider.getProfile("openai"));
    defer alloc.free(body);

    // Verify correct input format generated: user msg -> assistant text -> assistant function_call -> function_call_output
    try testing.expect(std.mem.indexOf(u8, body, "{\"role\":\"user\",\"content\":\"List files\"}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "{\"role\":\"assistant\",\"content\":\"I will run the ls command.\"}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "{\"type\":\"function_call\",\"call_id\":\"call_abc123\",\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "{\"type\":\"function_call_output\",\"call_id\":\"call_abc123\",\"output\":\"main.zig\\nbuild.zig\"}") != null);
}

test "openai stream: Responses API output_item.added and output_item.done does not duplicate arguments" {
    const alloc = testing.allocator;
    var ctx = StreamCtx{
        .alloc = alloc,
        .response = proto.Response.init(alloc),
        .line_buf = .empty,
        .tool_calls = .empty,
    };
    defer ctx.response.deinit();
    defer ctx.line_buf.deinit(alloc);
    defer ctx.tool_calls.deinit(alloc);

    try feedLines(&ctx, &.{
        \\event: response.output_item.added
        ,
        \\data: {"output_index":0,"item":{"id":"item_1","type":"function_call","call_id":"call_test_1","name":"bash","arguments":""}}
        ,
        \\event: response.function_call_arguments.delta
        ,
        \\data: {"output_index":0,"call_id":"call_test_1","delta":"{\"command\":"}
        ,
        \\event: response.function_call_arguments.delta
        ,
        \\data: {"output_index":0,"call_id":"call_test_1","delta":"\"ls\"}"}
        ,
        \\event: response.output_item.done
        ,
        \\data: {"output_index":0,"item":{"id":"item_1","type":"function_call","call_id":"call_test_1","name":"bash","arguments":"{\"command\":\"ls\"}"}}
        ,
        \\event: response.done
        ,
        \\data: {"response":{"usage":{"input_tokens":50,"output_tokens":20,"total_tokens":70}}}
    });

    try ctx.finalizeToolCalls();

    try testing.expectEqual(proto.StopReason.tool_use, ctx.response.stop_reason);
    try testing.expectEqual(@as(usize, 1), ctx.response.content.items.len);

    const tu = ctx.response.content.items[0].tool_use;
    try testing.expectEqualStrings("bash", tu.name);
    try testing.expectEqualStrings("call_test_1", tu.id);
    // Must be unique {"command":"ls"}, not duplicated into {"command":"ls"}{"command":"ls"}
    try testing.expectEqualStrings("{\"command\":\"ls\"}", tu.input_json);
}

test "openai dynamic reasoning_effort in buildRequestBody" {
    const alloc = testing.allocator;
    const msgs = [_]proto.Message{};
    const tools = [_]proto.ToolDefinition{};

    // 1. With reasoning_effort = "low"
    const body_low = try buildRequestBody(alloc, "o3-mini", 2048, true, false, "low", false, "", &msgs, &tools);
    defer alloc.free(body_low);
    try testing.expect(std.mem.indexOf(u8, body_low, "\"reasoning_effort\":\"low\"") != null);

    // 2. With reasoning_effort = "high"
    const body_high = try buildRequestBody(alloc, "o3-mini", 2048, true, false, "high", false, "", &msgs, &tools);
    defer alloc.free(body_high);
    try testing.expect(std.mem.indexOf(u8, body_high, "\"reasoning_effort\":\"high\"") != null);

    // 3. With reasoning_effort = "none"
    const body_none = try buildRequestBody(alloc, "o3-mini", 2048, true, false, "none", false, "", &msgs, &tools);
    defer alloc.free(body_none);
    try testing.expect(std.mem.indexOf(u8, body_none, "\"reasoning_effort\"") == null);

    // 4. With disable_reasoning_effort = true
    const body_disabled = try buildRequestBody(alloc, "o3-mini", 2048, true, true, "high", false, "", &msgs, &tools);
    defer alloc.free(body_disabled);
    try testing.expect(std.mem.indexOf(u8, body_disabled, "\"reasoning_effort\"") == null);
}

test "openai dynamic reasoning_effort in buildResponsesRequestBody" {
    const alloc = testing.allocator;
    const msgs = [_]proto.Message{};
    const tools = [_]proto.ToolDefinition{};

    // 1. With reasoning_effort = "low"
    const body_low = try buildResponsesRequestBody(alloc, "gpt-5.6-terra", 4096, false, "low", "", &msgs, &tools, provider.getProfile("openai"));
    defer alloc.free(body_low);
    try testing.expect(std.mem.indexOf(u8, body_low, "\"reasoning\":{\"effort\":\"low\"}") != null);

    // 2. With reasoning_effort = "high"
    const body_high = try buildResponsesRequestBody(alloc, "gpt-5.6-terra", 4096, false, "high", "", &msgs, &tools, provider.getProfile("openai"));
    defer alloc.free(body_high);
    try testing.expect(std.mem.indexOf(u8, body_high, "\"reasoning\":{\"effort\":\"high\"}") != null);

    // 3. With default null (falls back to medium)
    const body_default = try buildResponsesRequestBody(alloc, "gpt-5.6-terra", 4096, false, null, "", &msgs, &tools, provider.getProfile("openai"));
    defer alloc.free(body_default);
    try testing.expect(std.mem.indexOf(u8, body_default, "\"reasoning\":{\"effort\":\"medium\"}") != null);
}

test "openai stream: Responses API embedded type in data without event prefix (OpenRouter style)" {
    const alloc = testing.allocator;
    var ctx = StreamCtx{
        .alloc = alloc,
        .response = proto.Response.init(alloc),
        .line_buf = .empty,
        .tool_calls = .empty,
    };
    defer ctx.response.deinit();
    defer ctx.line_buf.deinit(alloc);
    defer ctx.tool_calls.deinit(alloc);

    try feedLines(&ctx, &.{
        \\data: {"type":"response.reasoning_text.delta","delta":"Let me think."}
        ,
        \\data: {"type":"response.output_text.delta","delta":"Hello "}
        ,
        \\data: {"type":"response.output_text.delta","delta":"world!"}
        ,
        \\data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":10,"output_tokens":20,"total_tokens":30,"input_tokens_details":{"cached_tokens":5},"output_tokens_details":{"reasoning_tokens":8}}}}
        ,
        \\data: [DONE]
    });

    try ctx.finalizeToolCalls();

    try testing.expectEqual(proto.StopReason.end_turn, ctx.response.stop_reason);
    try testing.expectEqual(@as(usize, 2), ctx.response.content.items.len);

    // Thinking block
    try testing.expectEqualStrings("Let me think.", ctx.response.content.items[0].thinking.thinking);
    // Text block
    try testing.expectEqualStrings("Hello world!", ctx.response.content.items[1].text);

    // Usage check
    try testing.expectEqual(@as(u64, 10), ctx.response.usage.prompt_tokens);
    try testing.expectEqual(@as(u64, 20), ctx.response.usage.completion_tokens);
    try testing.expectEqual(@as(u64, 30), ctx.response.usage.total_tokens);
    try testing.expectEqual(@as(u64, 5), ctx.response.usage.cached_tokens);
    try testing.expectEqual(@as(u64, 8), ctx.response.usage.reasoning_tokens);
}

test "openai buildResponsesRequestBody: unsupported reasoning_param omits reasoning" {
    const alloc = testing.allocator;
    const msgs = [_]proto.Message{};
    const tools = [_]proto.ToolDefinition{};

    // RFC-012: profile-pinned .unsupported reasoning_param (deepseek) must never
    // emit any reasoning field, even when forced onto the Responses API.
    const body = try buildResponsesRequestBody(alloc, "deepseek-chat", 4096, false, "high", "", &msgs, &tools, provider.getProfile("deepseek"));
    defer alloc.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "reasoning") == null);
}

test "openai sanitizeToolName: strips DSML tags and rejects invalid tool names" {
    // Normal tool names
    try testing.expectEqualStrings("bash", sanitizeToolName("bash").?);
    try testing.expectEqualStrings("file_read", sanitizeToolName("file_read").?);
    try testing.expectEqualStrings("my-custom_tool1", sanitizeToolName("my-custom_tool1").?);

    // DeepSeek DSML leaked tag stripping
    try testing.expectEqualStrings("read", sanitizeToolName("read</｜DSML｜parameter>\n</｜DSML｜invoke>\n</｜DSML｜tool_calls>").?);
    try testing.expectEqualStrings("file_read", sanitizeToolName("file_read<any_tag>").?);

    // Empty or pure tags
    try testing.expect(sanitizeToolName("</｜DSML｜tool_calls>") == null);
    try testing.expect(sanitizeToolName("   ") == null);
    try testing.expect(sanitizeToolName("invalid tool with spaces") == null);
}

