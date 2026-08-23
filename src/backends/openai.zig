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
// Client
// ---------------------------------------------------------------------------

/// OpenAI-compatible streaming client.
pub const Client = struct {
    alloc: Allocator,
    /// Base URL của API (ví dụ: "https://api.openai.com/v1" hoặc
    /// "http://localhost:11434/v1"). Sẽ append "/chat/completions" nếu cần.
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
        };
    }

    /// Gửi messages lên API và nhận phản hồi streaming.
    /// `text_cb` được gọi với mỗi text chunk khi AI đang sinh text.
    /// Trả về Response đầy đủ sau khi stream kết thúc.
    pub fn sendMessage(
        self: *Client,
        system_prompt: []const u8,
        msgs: []const proto.Message,
        tools: []const proto.ToolDefinition,
        text_cb: ?*const fn ([]const u8) void,
        think_cb: ?*const fn ([]const u8) void,
    ) !proto.Response {
        var retry_count: u32 = 0;
        while (retry_count < 3) : (retry_count += 1) {
            const body = try buildRequestBody(self.alloc, self.model, self.max_tokens, self.use_completion_tokens, self.disable_reasoning_effort, system_prompt, msgs, tools);
            defer self.alloc.free(body);

            // Build URL
            var url_buf: [512]u8 = undefined;
            const url = blk: {
                if (std.mem.endsWith(u8, self.base_url, "/chat/completions")) {
                    break :blk self.base_url;
                }
                const sep = if (std.mem.endsWith(u8, self.base_url, "/")) "" else "/";
                break :blk std.fmt.bufPrint(&url_buf, "{s}{s}chat/completions", .{ self.base_url, sep }) catch self.base_url;
            };

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

            const headers = [_][]const u8{ auth_header, "Content-Type: application/json" };
            const req_http_code = try http_lib.postStream(self.alloc, main.g_io, .{
                .url = url,
                .headers = &headers,
                .body = body,
                .timeout_secs = 120,
            }, StreamCtx.onChunk, &ctx);

            try ctx.finalizeToolCalls();
            ctx.response.http_code = req_http_code;

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
                
                if (should_retry) {
                    if (ctx.raw_accum_init) ctx.raw_accum.deinit(self.alloc);
                    ctx.response.deinit();
                    continue; // Retry
                }
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

fn buildRequestBody(
    alloc: Allocator,
    model: []const u8,
    max_tokens: u32,
    use_completion_tokens: bool,
    disable_reasoning_effort: bool,
    system_prompt: []const u8,
    msgs: []const proto.Message,
    tools: []const proto.ToolDefinition,
) ![]u8 {
    var buf = utils.BufWriter.init(alloc);
    errdefer buf.deinit();
    const w = &buf;

    const reasoning_effort_str = if (disable_reasoning_effort) "\"reasoning_effort\":\"none\"," else "";

    if (use_completion_tokens) {
        try w.print(
            \\{{"model":"{s}","max_completion_tokens":{d},{s}"stream":true,"stream_options":{{"include_usage":true}}
        , .{ model, max_tokens, reasoning_effort_str });
    } else {
        try w.print(
            \\{{"model":"{s}","max_tokens":{d},{s}"stream":true,"stream_options":{{"include_usage":true}}
        , .{ model, max_tokens, reasoning_effort_str });
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
        if (!std.mem.startsWith(u8, trimmed, "data: ")) return;

        const data = trimmed["data: ".len..];
        if (std.mem.eql(u8, data, "[DONE]")) {
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
        };

        const parsed = std.json.parseFromSlice(Chunk, self.alloc, data, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();

        const chunk = parsed.value;
        if (chunk.choices) |choices| {
            for (choices) |choice| {
                if (choice.delta) |delta| {
                    if (delta.reasoning_content) |reasoning| {
                        if (reasoning.len > 0) {
                            if (!self.think_accum_init) {
                                self.think_accum = .empty;
                                self.think_accum_init = true;
                            }
                            try self.think_accum.appendSlice(self.alloc, reasoning);
                            if (self.think_cb) |cb| cb(reasoning);
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
                        for (tool_calls) |tc_obj| {
                            if (tc_obj.id) |id| {
                                _ = try self.findOrCreateToolCall(id);
                            }
                            if (tc_obj.function) |func| {
                                if (func.name) |name| {
                                    if (self.tool_calls.items.len > 0) {
                                        const last = &self.tool_calls.items[self.tool_calls.items.len - 1];
                                        try last.name.appendSlice(self.alloc, name);
                                    }
                                }
                                if (func.arguments) |args| {
                                    if (self.tool_calls.items.len > 0) {
                                        const last = &self.tool_calls.items[self.tool_calls.items.len - 1];
                                        try last.args.appendSlice(self.alloc, args);
                                    }
                                }
                            }
                        }
                    }
                }
                if (choice.finish_reason) |reason| {
                    if (std.mem.eql(u8, reason, "tool_calls")) {
                        self.response.stop_reason = .tool_use;
                    } else if (std.mem.eql(u8, reason, "stop")) {
                        self.response.stop_reason = .end_turn;
                    } else if (std.mem.eql(u8, reason, "length")) {
                        self.response.stop_reason = .max_tokens;
                    }
                }
            }
        }
    }

    fn findOrCreateToolCall(self: *StreamCtx, id: []const u8) !usize {
        for (self.tool_calls.items, 0..) |tc, i| {
            if (std.mem.eql(u8, tc.id.items, id)) return i;
        }
        var tc = PartialToolCall.init();
        try tc.id.appendSlice(self.alloc, id);
        try self.tool_calls.append(self.alloc, tc);
        return self.tool_calls.items.len - 1;
    }

    fn finalizeToolCalls(self: *StreamCtx) !void {
        for (self.tool_calls.items) |*tc| {
            defer tc.deinit(self.alloc);
            if (tc.name.items.len == 0) continue;
            const id = try self.alloc.dupe(u8, tc.id.items);
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

test "openai buildRequestBody includes stream_options, static tools prefix and clean system message" {
    const alloc = testing.allocator;
    const msgs = [_]proto.Message{};
    const tools = [_]proto.ToolDefinition{
        .{ .name = "test_tool", .description = "desc", .input_schema_json = "{}" },
    };

    const body = try buildRequestBody(alloc, "gpt-4o", 1024, false, false, "System prompt test", &msgs, &tools);
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
