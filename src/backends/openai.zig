//! backend/openai.zig — OpenAI-compatible streaming client.
//!
//! Hỗ trợ bất kỳ API nào tương thích OpenAI Chat Completions:
//!   - OpenAI (api.openai.com)
//!   - Ollama (qua /v1/chat/completions)
//!   - LM Studio, vLLM, OpenRouter, các endpoint custom...
//!
//! ## Định dạng request
//! POST {base_url}/chat/completions (nếu base_url chưa có /chat/completions)
//! ```json
//! { "model": "...", "stream": true, "messages": [...], "tools": [...] }
//! ```
//!
//! ## Định dạng SSE response
//! ```
//! data: {"choices":[{"delta":{"content":"hello"},"finish_reason":null}]}
//! data: {"choices":[{"delta":{"tool_calls":[{"id":"...","function":{"name":"bash","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}
//! data: [DONE]
//! ```
//!
//! ## Tool calls
//! Tool calls được tích lũy qua nhiều chunk (arguments có thể đến theo từng mảnh).
//! Sau khi nhận `[DONE]`, danh sách tool calls hoàn chỉnh được thêm vào Response.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const proto = @import("../core/protocol.zig");
const json = @import("../core/json.zig");
const http_lib = @import("../lib/http_request.zig");
const main = @import("../main.zig");
const utils = @import("../core/utils.zig");

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Protocol Mode & Auto-Negotiation (ISSUE-BACKEND-001)
// ---------------------------------------------------------------------------

/// Chế độ giao thức cho OpenAI-compatible backend.
pub const ProtocolMode = enum {
    auto,
    chat_completions,
    responses,
};

/// Trích xuất root base URL (bỏ /chat/completions hoặc /responses nếu có).
pub fn getRootApiUrl(base_url: []const u8) []const u8 {
    var url = std.mem.trimEnd(u8, base_url, "/ \t\r\n");
    if (std.mem.endsWith(u8, url, "/chat/completions")) {
        return std.mem.trimEnd(u8, url[0 .. url.len - "/chat/completions".len], "/");
    }
    if (std.mem.endsWith(u8, url, "/responses")) {
        return std.mem.trimEnd(u8, url[0 .. url.len - "/responses".len], "/");
    }
    if (std.mem.endsWith(u8, url, "/response")) {
        return std.mem.trimEnd(u8, url[0 .. url.len - "/response".len], "/");
    }
    return url;
}

/// Nhận diện model dòng mới ưu tiên dùng Responses API (GPT-5.6, o3-pro, v.v.).
pub fn shouldUseResponsesApi(model: []const u8) bool {
    if (std.mem.startsWith(u8, model, "gpt-5.6") or
        std.mem.startsWith(u8, model, "gpt-5-sol") or
        std.mem.startsWith(u8, model, "gpt-5-terra") or
        std.mem.startsWith(u8, model, "gpt-5-luna") or
        std.mem.startsWith(u8, model, "o3-pro") or
        std.mem.startsWith(u8, model, "o1-pro"))
    {
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

/// OpenAI-compatible streaming client (hỗ trợ cả Chat Completions API & Responses API).
pub const Client = struct {
    alloc: Allocator,
    /// Base URL của API (ví dụ: "https://api.openai.com/v1" hoặc
    /// "http://localhost:11434/v1").
    base_url: []const u8,
    /// API key. Có thể là chuỗi rỗng nếu endpoint không cần.
    api_key: []const u8,
    /// Header để gửi API key.
    api_header: []const u8,
    /// Tên model (ví dụ: "gpt-4o-mini", "llama3").
    model: []const u8,
    /// Số token tối đa trong response.
    max_tokens: u32,
    /// Sử dụng max_completion_tokens thay vì max_tokens.
    use_completion_tokens: bool,
    /// Vô hiệu hóa reasoning_effort nếu API không hỗ trợ cùng với tool calls.
    disable_reasoning_effort: bool,
    /// Vô hiệu hóa stream_options nếu API compat không hỗ trợ (RFC-006 §3.6).
    disable_stream_options: bool,
    /// Chế độ giao thức (auto, chat_completions, responses).
    protocol_mode: ProtocolMode,
    /// Cache giao thức đã đàm phán thành công (Tier 3: Session Protocol Memory).
    cached_protocol: ?ProtocolMode,

    /// Khởi tạo client.
    pub fn init(alloc: Allocator, base_url: []const u8, api_key: []const u8, api_header: []const u8, model: []const u8, max_tokens: u32) Client {
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
            .protocol_mode = .auto,
            .cached_protocol = null,
        };
    }

    /// Khởi tạo client với chế độ protocol rõ ràng.
    pub fn initWithProtocol(alloc: Allocator, base_url: []const u8, api_key: []const u8, api_header: []const u8, model: []const u8, max_tokens: u32, protocol_mode: ProtocolMode) Client {
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
        };
    }

    /// Gửi messages lên API và nhận phản hồi streaming.
    /// Hỗ trợ 3-Tier Dual-Protocol Auto-Negotiation & Adaptive Fallback.
    pub fn sendMessage(
        self: *Client,
        system_prompt: []const u8,
        msgs: []const proto.Message,
        tools: []const proto.ToolDefinition,
        text_cb: ?*const fn ([]const u8) void,
        think_cb: ?*const fn ([]const u8) void,
    ) !proto.Response {
        const root_url = getRootApiUrl(self.base_url);
        var active_protocol: ProtocolMode = blk: {
            if (self.protocol_mode == .chat_completions) break :blk .chat_completions;
            if (self.protocol_mode == .responses) break :blk .responses;
            if (self.cached_protocol) |p| break :blk p;
            if (shouldUseResponsesApi(self.model)) break :blk .responses;
            break :blk .chat_completions;
        };

        var retry_count: u32 = 0;
        while (retry_count < 4) : (retry_count += 1) {
            const body = if (active_protocol == .responses)
                try buildResponsesRequestBody(self.alloc, self.model, self.max_tokens, self.disable_reasoning_effort, system_prompt, msgs, tools)
            else
                try buildRequestBody(self.alloc, self.model, self.max_tokens, self.use_completion_tokens, self.disable_reasoning_effort, self.disable_stream_options, system_prompt, msgs, tools);
            defer self.alloc.free(body);

            // Build URL theo giao thức đang kích hoạt
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
            const req_http_code = try http_lib.postStream(self.alloc, main.g_io, .{
                .url = url,
                .headers = &headers,
                .body = body,
                .timeout_secs = 120,
            }, StreamCtx.onChunk, &ctx);

            try ctx.finalizeToolCalls();
            ctx.response.http_code = req_http_code;

            // Auto-Negotiation & Adaptive Cross-Protocol Fallback (Tier 2)
            if (self.protocol_mode == .auto and ctx.raw_accum_init) {
                const raw_resp = ctx.raw_accum.items;
                
                // Fallback 1: Chat Completions -> Responses API khi bị lỗi 400 do không hỗ trợ hoặc xung đột tools/reasoning
                if (active_protocol == .chat_completions and req_http_code == 400) {
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

                // Fallback 2: Responses API -> Chat Completions khi server cũ trả 404 (chưa có endpoint /responses)
                if (active_protocol == .responses and (req_http_code == 404 or (req_http_code == 400 and std.mem.indexOf(u8, raw_resp, "not found") != null))) {
                    active_protocol = .chat_completions;
                    self.cached_protocol = .chat_completions;
                    if (ctx.raw_accum_init) ctx.raw_accum.deinit(self.alloc);
                    ctx.response.deinit();
                    continue;
                }
            }

            // Retry adaptive parameters trong Chat Completions
            if (req_http_code == 400 and ctx.raw_accum_init) {
                const raw_resp = ctx.raw_accum.items;
                var should_retry = false;
                
                if (std.mem.indexOf(u8, raw_resp, "unsupported_parameter") != null and
                    (std.mem.indexOf(u8, raw_resp, "max_tokens") != null or std.mem.indexOf(u8, raw_resp, "max_completion_tokens") != null)) {
                    self.use_completion_tokens = !self.use_completion_tokens;
                    should_retry = true;
                }
                
                if (std.mem.indexOf(u8, raw_resp, "reasoning_effort") != null) {
                    self.disable_reasoning_effort = true;
                    should_retry = true;
                }

                // RFC-006 §3.6: stream_options không được hỗ trợ bởi API compat cũ
                if (std.mem.indexOf(u8, raw_resp, "stream_options") != null or
                    std.mem.indexOf(u8, raw_resp, "include_usage") != null) {
                    self.disable_stream_options = true;
                    should_retry = true;
                }

                // Tự động hạ max_tokens nếu provider báo vượt trần model (ví dụ: Groq giới hạn qwen3.8-27b ở 16384 hoặc compound-mini ở 8192)
                if (std.mem.indexOf(u8, raw_resp, "max_tokens") != null and
                    (std.mem.indexOf(u8, raw_resp, "less than or equal to") != null or
                     std.mem.indexOf(u8, raw_resp, "must be less than") != null or
                     std.mem.indexOf(u8, raw_resp, "\"param\":\"max_tokens\"") != null or
                     std.mem.indexOf(u8, raw_resp, "\"param\": \"max_tokens\"") != null))
                {
                    var new_limit: ?u32 = null;
                    if (std.mem.indexOf(u8, raw_resp, "less than or equal to")) |pos| {
                        var idx = pos + "less than or equal to".len;
                        while (idx < raw_resp.len and (raw_resp[idx] == ' ' or raw_resp[idx] == '`' or raw_resp[idx] == '\'')) : (idx += 1) {}
                        var end_idx = idx;
                        while (end_idx < raw_resp.len and raw_resp[end_idx] >= '0' and raw_resp[end_idx] <= '9') : (end_idx += 1) {}
                        if (end_idx > idx) {
                            new_limit = std.fmt.parseInt(u32, raw_resp[idx..end_idx], 10) catch null;
                        }
                    }
                    if (new_limit) |lim| {
                        if (lim < self.max_tokens) {
                            self.max_tokens = lim;
                            should_retry = true;
                        }
                    } else if (self.max_tokens > 16384) {
                        self.max_tokens = 16384;
                        should_retry = true;
                    } else if (self.max_tokens > 8192) {
                        self.max_tokens = 8192;
                        should_retry = true;
                    } else if (self.max_tokens > 4096) {
                        self.max_tokens = 4096;
                        should_retry = true;
                    }
                }
                
                if (should_retry) {
                    if (ctx.raw_accum_init) ctx.raw_accum.deinit(self.alloc);
                    ctx.response.deinit();
                    continue; // Retry
                }
            }

            // Ghi nhớ giao thức thành công (Tier 3: Protocol Memory Caching)
            if (req_http_code == 200 and self.protocol_mode == .auto) {
                self.cached_protocol = active_protocol;
            }

            if (ctx.response.stop_reason == .unknown and ctx.raw_accum_init) {
                ctx.response.raw_debug_info = ctx.alloc.dupe(u8, ctx.raw_accum.items) catch null;
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

/// Xây dựng request body cho OpenAI Responses API (POST /v1/responses).
fn buildResponsesRequestBody(
    alloc: Allocator,
    model: []const u8,
    max_tokens: u32,
    disable_reasoning_effort: bool,
    system_prompt: []const u8,
    msgs: []const proto.Message,
    tools: []const proto.ToolDefinition,
) ![]u8 {
    var buf = utils.BufWriter.init(alloc);
    errdefer buf.deinit();
    const w = &buf;

    _ = max_tokens;

    try w.print("{{\"model\":\"{s}\",\"stream\":true", .{model});

    if (!disable_reasoning_effort) {
        try w.writeAll(",\"reasoning\":{\"effort\":\"medium\"}");
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
                .thinking => {},
            }
        }
    }
    try w.writeAll("]}");

    return buf.toOwnedSlice();
}

fn buildRequestBody(
    alloc: Allocator,
    model: []const u8,
    max_tokens: u32,
    use_completion_tokens: bool,
    disable_reasoning_effort: bool,
    disable_stream_options: bool,
    system_prompt: []const u8,
    msgs: []const proto.Message,
    tools: []const proto.ToolDefinition,
) ![]u8 {
    var buf = utils.BufWriter.init(alloc);
    errdefer buf.deinit();
    const w = &buf;

    const reasoning_effort_str = if (disable_reasoning_effort) "\"reasoning_effort\":\"none\"," else "";
    // RFC-006 §3.6: stream_options adaptive — bỏ nếu API compat không hỗ trợ
    const stream_options_str = if (disable_stream_options) "" else ",\"stream_options\":{\"include_usage\":true}";

    if (use_completion_tokens) {
        try w.print(
            \\{{"model":"{s}","max_completion_tokens":{d},{s}"stream":true{s}
        , .{ model, max_tokens, reasoning_effort_str, stream_options_str });
    } else {
        try w.print(
            \\{{"model":"{s}","max_tokens":{d},{s}"stream":true{s}
        , .{ model, max_tokens, reasoning_effort_str, stream_options_str });
    }

    // Tool definitions (đặt trước messages để đảm bảo JSON prefix là tĩnh 100% giữa các lượt)
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
        if (!first_msg) try w.writeByte(',');
        first_msg = false;

        // Check if message is entirely tool_results
        var all_tool_results = true;
        for (msg.content) |block| {
            if (block != .tool_result) {
                all_tool_results = false;
                break;
            }
        }

        if (all_tool_results and msg.content.len > 0) {
            // Encode as multiple "tool" role messages
            for (msg.content, 0..) |block, bi| {
                if (bi > 0) try w.writeByte(',');
                if (block == .tool_result) {
                    const tr = block.tool_result;
                    const escaped = try json.escape(alloc, tr.content);
                    defer alloc.free(escaped);
                    try w.print(
                        \\{{"role":"tool","tool_call_id":"{s}","content":"{s}"}}
                    , .{ tr.tool_use_id, escaped });
                }
            }
            continue;
        }

        // Standard user or assistant message
        try w.print("{{\"role\":\"{s}\",", .{msg.role.toJson()});

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
    text_cb: ?*const fn ([]const u8) void,
    think_cb: ?*const fn ([]const u8) void,
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

    fn onChunk(chunk: []const u8, userdata: *anyopaque) void {
        const self: *StreamCtx = @ptrCast(@alignCast(userdata));

        if (!self.raw_accum_init) {
            self.raw_accum = .empty;
            self.raw_accum_init = true;
        }
        if (self.raw_accum.items.len < 4096) {
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

        if (std.mem.startsWith(u8, trimmed, "event: ")) {
            const ev = trimmed["event: ".len..];
            const n = @min(ev.len, self.event_type.len);
            @memcpy(self.event_type[0..n], ev[0..n]);
            self.event_type_len = n;
            return;
        }

        if (!std.mem.startsWith(u8, trimmed, "data: ")) return;

        const data = trimmed["data: ".len..];
        const ev = self.event_type[0..self.event_type_len];

        // Xử lý [DONE] hoặc event kết thúc của Responses API
        if (std.mem.eql(u8, data, "[DONE]") or std.mem.eql(u8, ev, "response.done") or std.mem.eql(u8, ev, "response.completed")) {
            // Check usage trong Responses API payload nếu có
            if (std.mem.startsWith(u8, data, "{")) {
                if (json.findObject(data, "response")) |resp_obj| {
                    if (json.findObject(resp_obj, "usage")) |u_obj| {
                        const pt = if (json.findInt(u_obj, "input_tokens", u64)) |v| v else (json.findInt(u_obj, "prompt_tokens", u64) orelse 0);
                        const ct = if (json.findInt(u_obj, "output_tokens", u64)) |v| v else (json.findInt(u_obj, "completion_tokens", u64) orelse 0);
                        const tt = if (json.findInt(u_obj, "total_tokens", u64)) |v| v else (pt + ct);
                        self.response.usage.prompt_tokens = pt;
                        self.response.usage.completion_tokens = ct;
                        self.response.usage.total_tokens = tt;
                    }
                }
            }

            // Lưu thinking đã tích lũy
            if (self.think_accum_init and self.think_accum.items.len > 0) {
                const think_text = try self.alloc.dupe(u8, self.think_accum.items);
                try self.response.content.append(self.alloc, .{ .thinking = .{ .thinking = think_text, .signature = "" } });
                self.think_accum.clearRetainingCapacity();
            }
            // Lưu text đã tích lũy vào response
            if (self.text_accum_init and self.text_accum.items.len > 0) {
                const text = try self.alloc.dupe(u8, self.text_accum.items);
                try self.response.content.append(self.alloc, .{ .text = text });
                self.text_accum.clearRetainingCapacity();
            }
            // Chỉ set thành end_turn nếu chưa set tool_use hay max_tokens
            if (self.response.stop_reason == .unknown) {
                self.response.stop_reason = .end_turn;
            }
            return;
        }

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
                    try self.text_accum.appendSlice(self.alloc, unescaped);
                    if (self.text_cb) |cb| cb(unescaped);
                }
                return;
            }
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
                    try self.think_accum.appendSlice(self.alloc, unescaped);
                    if (self.think_cb) |cb| cb(unescaped);
                }
                return;
            }
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
            const ChoiceDelta = struct {
                content: ?[]const u8 = null,
                reasoning_content: ?[]const u8 = null,
                // RFC-006 §3.3: OpenAI o-series/GPT-5.x dùng field "reasoning"
                reasoning: ?[]const u8 = null,
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
            // RFC-006 §3.1: usage chunk (gửi ở chunk cuối khi include_usage=true)
            usage: ?UsageJson = null,
        };

        const parsed = std.json.parseFromSlice(Chunk, self.alloc, data, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();

        const chunk = parsed.value;
        if (chunk.choices) |choices| {
            for (choices) |choice| {
                if (choice.delta) |delta| {
                    // RFC-006 §3.3: nhận reasoning từ cả hai biến thể
                    // DeepSeek-style: delta.reasoning_content
                    // OpenAI o-series/GPT-5.x: delta.reasoning
                    const reasoning = delta.reasoning_content orelse delta.reasoning;
                    if (reasoning) |r| {
                        if (r.len > 0) {
                            if (!self.think_accum_init) {
                                self.think_accum = .empty;
                                self.think_accum_init = true;
                            }
                            try self.think_accum.appendSlice(self.alloc, r);
                            if (self.think_cb) |cb| cb(r);
                        }
                    }
                    if (delta.content) |text| {
                        if (text.len > 0) {
                            if (!self.text_accum_init) {
                                self.text_accum = .empty;
                                self.text_accum_init = true;
                            }
                            try self.text_accum.appendSlice(self.alloc, text);
                            if (self.text_cb) |cb| cb(text);
                        }
                    }
                    if (delta.tool_calls) |tool_calls| {
                        // Gộp theo index (chuẩn OpenAI streaming): DeepSeek và đa số
                        // provider compat chỉ gửi id ở chunk đầu, các chunk sau chỉ có
                        // index + arguments — không được append mù vào item cuối.
                        for (tool_calls) |tc_obj| {
                            const fname = if (tc_obj.function) |f| f.name else null;
                            const fargs = if (tc_obj.function) |f| f.arguments else null;
                            try self.mergeToolCallDelta(tc_obj.index, tc_obj.id, fname, fargs);
                        }
                    }
                }
                if (choice.finish_reason) |reason| {
                    // RFC-006 §3.4: map đầy đủ finish_reason của OpenAI
                    if (std.mem.eql(u8, reason, "tool_calls")) {
                        self.response.stop_reason = .tool_use;
                    } else if (std.mem.eql(u8, reason, "stop")) {
                        self.response.stop_reason = .end_turn;
                    } else if (std.mem.eql(u8, reason, "length")) {
                        self.response.stop_reason = .max_tokens;
                    } else if (std.mem.eql(u8, reason, "function")) {
                        // Legacy function calling → map như tool_calls
                        self.response.stop_reason = .tool_use;
                    } else if (std.mem.eql(u8, reason, "content_filter")) {
                        // Content filter → .unknown + debug info (không phải end_turn)
                        self.response.stop_reason = .unknown;
                    }
                }
            }
        }

        // RFC-006 §3.1: parse usage từ chunk cuối
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

    /// Gộp 1 tool_call delta vào danh sách, định vị slot theo index (chuẩn
    /// OpenAI streaming). Fallback: match id, rồi item cuối. DeepSeek-style:
    /// chunk đầu mang id+name, các chunk sau chỉ index+arguments.
    fn mergeToolCallDelta(self: *StreamCtx, index: ?u32, id: ?[]const u8, name: ?[]const u8, args: ?[]const u8) !void {
        var slot: ?usize = null;

        // 1. Ưu tiên match theo id (định danh toàn cục duy nhất của tool call)
        if (id) |tcid| {
            for (self.tool_calls.items, 0..) |tc, i| {
                if (tc.id.items.len > 0 and std.mem.eql(u8, tc.id.items, tcid)) {
                    slot = i;
                    break;
                }
            }
        }
        // 2. Match theo index nếu nằm trong phạm vi tool_calls hiện có
        if (slot == null and index != null) {
            const idx = index.?;
            if (idx < self.tool_calls.items.len) slot = idx;
        }
        // 3. Fallback: item cuối cùng đang mở
        if (slot == null and index == null and id == null and self.tool_calls.items.len > 0) {
            slot = self.tool_calls.items.len - 1;
        }

        // Chưa có slot → tạo item mới
        if (slot == null) {
            var tc = PartialToolCall.init();
            if (id) |tcid| try tc.id.appendSlice(self.alloc, tcid);
            try self.tool_calls.append(self.alloc, tc);
            slot = self.tool_calls.items.len - 1;
        } else if (id) |tcid| {
            // Slot đã tồn tại nhưng chưa có id → cập nhật
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

    /// Cập nhật hoặc ghi đè thông tin hoàn chỉnh của tool_call khi nhận event done
    fn setToolCallFinal(self: *StreamCtx, index: ?u32, id: ?[]const u8, name: ?[]const u8, args: ?[]const u8) !void {
        var slot: ?usize = null;

        // 1. Ưu tiên match theo id
        if (id) |tcid| {
            for (self.tool_calls.items, 0..) |tc, i| {
                if (tc.id.items.len > 0 and std.mem.eql(u8, tc.id.items, tcid)) {
                    slot = i;
                    break;
                }
            }
        }
        // 2. Match theo index nếu nằm trong phạm vi
        if (slot == null and index != null) {
            const idx = index.?;
            if (idx < self.tool_calls.items.len) slot = idx;
        }
        // 3. Fallback: item cuối cùng đang mở
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
        for (self.tool_calls.items, 0..) |*tc, ti| {
            defer tc.deinit(self.alloc);
            if (tc.name.items.len == 0) continue;
            // Provider không gửi id (một số compat/proxy) → sinh id dự phòng
            // để tool_result luôn khớp tool_call_id (tránh 400 từ API).
            const id = if (tc.id.items.len > 0)
                try self.alloc.dupe(u8, tc.id.items)
            else
                try std.fmt.allocPrint(self.alloc, "call_{d}", .{ti});
            const name = try self.alloc.dupe(u8, tc.name.items);
            const args = if (tc.args.items.len > 0)
                try self.alloc.dupe(u8, tc.args.items)
            else
                try self.alloc.dupe(u8, "{}");
            try self.response.content.append(self.alloc, .{ .tool_use = .{
                .id = id,
                .name = name,
                .input_json = args,
            }});
        }
        if (self.tool_calls.items.len > 0 and self.response.stop_reason != .tool_use) {
            self.response.stop_reason = .tool_use;
        }
        if (self.think_accum_init) self.think_accum.deinit(self.alloc);
        if (self.text_accum_init) self.text_accum.deinit(self.alloc);
    }
};

// ---------------------------------------------------------------------------
// Unit Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// --- Tests: streaming tool_calls gop theo index (DeepSeek style) ---

fn feedLines(ctx: anytype, lines: []const []const u8) !void {
    for (lines) |ln| try ctx.processLine(ln);
}

test "openai stream: parallel tool calls gop theo index (DeepSeek style)" {
    const alloc = testing.allocator;
    var resp = proto.Response.init(alloc);
    defer resp.deinit();
    var ctx = StreamCtx{
        .alloc = alloc,
        .response = resp,
        .line_buf = .empty,
        .tool_calls = .empty,
    };
    defer ctx.line_buf.deinit(alloc);
    defer ctx.tool_calls.deinit(alloc);

    // Chunk dau: id+name; cac chunk sau chi index+arguments (DeepSeek khong lap id)
    try feedLines(&ctx, &.{
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","function":{"name":"bash","arguments":"{\"com"}}]}}]}
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_b","function":{"name":"file_read","arguments":"{\"pa"}}]}}]}
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"mand\":\"ls\"}"}}]}}]}
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":"th\":\"a.zig\"}"}}]}}]}
        \\data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}
        \\data: [DONE]
    });

    try ctx.finalizeToolCalls();
    try testing.expectEqual(proto.StopReason.tool_use, ctx.response.stop_reason);
    try testing.expectEqual(@as(usize, 2), ctx.response.content.len);

    const first = ctx.response.content[0].tool_use;
    try testing.expectEqualStrings("bash", first.name);
    try testing.expectEqualStrings("call_a", first.id);
    try testing.expectEqualStrings("{\"command\":\"ls\"}", first.input_json);

    const second = ctx.response.content[1].tool_use;
    try testing.expectEqualStrings("file_read", second.name);
    try testing.expectEqualStrings("call_b", second.id);
    try testing.expectEqualStrings("{\"path\":\"a.zig\"}", second.input_json);
}

test "openai stream: tool call khong co id — sinh id du phong" {
    const alloc = testing.allocator;
    var resp = proto.Response.init(alloc);
    defer resp.deinit();
    var ctx = StreamCtx{
        .alloc = alloc,
        .response = resp,
        .line_buf = .empty,
        .tool_calls = .empty,
    };
    defer ctx.line_buf.deinit(alloc);
    defer ctx.tool_calls.deinit(alloc);

    // Provider compat khong gui id, chi index
    try feedLines(&ctx, &.{
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"glob","arguments":"{\"pat"}}]}}]}
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"tern\":\"*.zig\"}"}}]}}]}
        \\data: [DONE]
    });

    try ctx.finalizeToolCalls();
    try testing.expectEqual(proto.StopReason.tool_use, ctx.response.stop_reason);
    try testing.expectEqual(@as(usize, 1), ctx.response.content.len);
    const tu = ctx.response.content[0].tool_use;
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

    const body = try buildRequestBody(alloc, "gpt-4o", 1024, false, false, false, "System prompt test", &msgs, &tools);
    defer alloc.free(body);

    // Kiểm tra có stream_options include_usage
    try testing.expect(std.mem.indexOf(u8, body, "\"stream_options\":{\"include_usage\":true}") != null);
    // Kiểm tra System message được format sạch không có tab
    try testing.expect(std.mem.indexOf(u8, body, "{\"role\":\"system\",\"content\":\"System prompt test\"}") != null);

    // Kiểm tra "tools" xuất hiện TRƯỚC "messages" để giữ prefix tĩnh 100%
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

    // disable_stream_options = true → không có stream_options
    const body = try buildRequestBody(alloc, "gpt-4o", 1024, false, false, true, "test", &msgs, &tools);
    defer alloc.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "stream_options") == null);
    try testing.expect(std.mem.indexOf(u8, body, "include_usage") == null);
}

test "openai stream: parse usage chunk (RFC-006 §3.1)" {
    const alloc = testing.allocator;
    var resp = proto.Response.init(alloc);
    defer resp.deinit();
    var ctx = StreamCtx{
        .alloc = alloc,
        .response = resp,
        .line_buf = .empty,
        .tool_calls = .empty,
    };
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
    var resp = proto.Response.init(alloc);
    defer resp.deinit();
    var ctx = StreamCtx{
        .alloc = alloc,
        .response = resp,
        .line_buf = .empty,
        .tool_calls = .empty,
    };
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
    var resp = proto.Response.init(alloc);
    defer resp.deinit();
    var ctx = StreamCtx{
        .alloc = alloc,
        .response = resp,
        .line_buf = .empty,
        .tool_calls = .empty,
    };
    defer ctx.line_buf.deinit(alloc);
    defer ctx.tool_calls.deinit(alloc);

    // OpenAI o-series/GPT-5.x sử dụng field "reasoning" thay vì "reasoning_content"
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
    // Có 2 content blocks: thinking + text
    try testing.expectEqual(@as(usize, 2), ctx.response.content.items.len);
    // Block đầu: thinking
    const think_block = ctx.response.content.items[0].thinking;
    try testing.expectEqualStrings("Let me think about this", think_block.thinking);
    // Block thứ 2: text
    const text_block = ctx.response.content.items[1].text;
    try testing.expectEqualStrings("The answer is 42", text_block);
}

test "openai stream: finish_reason content_filter maps to unknown (RFC-006 §3.4)" {
    const alloc = testing.allocator;
    var resp = proto.Response.init(alloc);
    defer resp.deinit();
    var ctx = StreamCtx{
        .alloc = alloc,
        .response = resp,
        .line_buf = .empty,
        .tool_calls = .empty,
    };
    defer ctx.line_buf.deinit(alloc);
    defer ctx.tool_calls.deinit(alloc);

    try feedLines(&ctx, &.{
        \\data: {"choices":[{"delta":{"content":"I can't"},"finish_reason":"content_filter"}]}
        ,
        \\data: [DONE]
    });

    try ctx.finalizeToolCalls();
    // content_filter → .unknown, KHÔNG phải .end_turn
    try testing.expectEqual(proto.StopReason.unknown, ctx.response.stop_reason);
}

test "openai stream: finish_reason function maps to tool_use (RFC-006 §3.4)" {
    const alloc = testing.allocator;
    var resp = proto.Response.init(alloc);
    defer resp.deinit();
    var ctx = StreamCtx{
        .alloc = alloc,
        .response = resp,
        .line_buf = .empty,
        .tool_calls = .empty,
    };
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

test "openai auto-negotiation: shouldUseResponsesApi model detection" {
    try testing.expect(shouldUseResponsesApi("gpt-5.6-sol"));
    try testing.expect(shouldUseResponsesApi("gpt-5.6-terra"));
    try testing.expect(shouldUseResponsesApi("gpt-5.6-luna"));
    try testing.expect(shouldUseResponsesApi("gpt-5-sol"));
    try testing.expect(shouldUseResponsesApi("o3-pro"));
    try testing.expect(shouldUseResponsesApi("o1-pro"));

    try testing.expect(!shouldUseResponsesApi("gpt-4o"));
    try testing.expect(!shouldUseResponsesApi("gpt-4o-mini"));
    try testing.expect(!shouldUseResponsesApi("deepseek-chat"));
    try testing.expect(!shouldUseResponsesApi("qwen2.5-coder"));
}

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

    const body = try buildResponsesRequestBody(alloc, "gpt-5.6-terra", 4096, false, "System instructions", &msgs, &tools);
    defer alloc.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"model\":\"gpt-5.6-terra\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"instructions\":\"System instructions\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":{\"effort\":\"medium\"}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"tools\":[{\"type\":\"function\",\"name\":\"bash\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"input\":[{\"role\":\"user\",\"content\":\"Solve problem\"}]") != null);
}

test "openai stream: Responses API event-based streaming parse" {
    const alloc = testing.allocator;
    var resp = proto.Response.init(alloc);
    defer resp.deinit();
    var ctx = StreamCtx{
        .alloc = alloc,
        .response = resp,
        .line_buf = .empty,
        .tool_calls = .empty,
    };
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
                .{ .text = "Liệt kê files" },
            },
        },
        .{
            .role = .assistant,
            .content = &.{
                .{ .text = "Tôi sẽ chạy lệnh ls." },
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

    const body = try buildResponsesRequestBody(alloc, "gpt-5.6-luna", 4096, false, "System prompt", &msgs, &tools);
    defer alloc.free(body);

    // Kiểm tra đã phát sinh đúng format input: user msg -> assistant text -> assistant function_call -> function_call_output
    try testing.expect(std.mem.indexOf(u8, body, "{\"role\":\"user\",\"content\":\"Liệt kê files\"}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "{\"role\":\"assistant\",\"content\":\"Tôi sẽ chạy lệnh ls.\"}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "{\"type\":\"function_call\",\"call_id\":\"call_abc123\",\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "{\"type\":\"function_call_output\",\"call_id\":\"call_abc123\",\"output\":\"main.zig\\nbuild.zig\"}") != null);
}

test "openai stream: Responses API output_item.added and output_item.done does not duplicate arguments" {
    const alloc = testing.allocator;
    var resp = proto.Response.init(alloc);
    defer resp.deinit();
    var ctx = StreamCtx{
        .alloc = alloc,
        .response = resp,
        .line_buf = .empty,
        .tool_calls = .empty,
    };
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
    // Phải là {"command":"ls"} duy nhất, không bị nhân đôi thành {"command":"ls"}{"command":"ls"}
    try testing.expectEqualStrings("{\"command\":\"ls\"}", tu.input_json);
}

