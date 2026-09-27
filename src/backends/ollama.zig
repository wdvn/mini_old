//! backend/ollama.zig — Ollama local AI client.
//!
//! Communicates with Ollama via `/api/chat` endpoint using NDJSON streaming.
//! Ollama runs locally without requiring an API key, suitable for offline usage.
//!
//! ## Endpoint
//! POST {ollama_host}/api/chat
//!
//! ## Response format (NDJSON)
//! Each line is a JSON object:
//! ```json
//! {"message":{"role":"assistant","content":"Hello"},"done":false}
//! {"message":{"role":"assistant","content":"!"},"done":true}
//! ```
//!
//! ## Tool calls
//! Ollama supports tool calls starting from version 0.3.0+.
//! Same format as OpenAI: `message.tool_calls[0].function.{name,arguments}`.
//!
//! ## Configuration
//!   `OLLAMA_HOST`   Base URL (default: http://localhost:11434)
//!   `OLLAMA_MODEL`  Model name (default: llama3)

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const proto = @import("../core/protocol.zig");
const json = @import("../core/json.zig");
const http_lib = @import("../lib/http_request.zig");
const main = @import("../main.zig");
const utils = @import("../core/utils.zig");

/// Ollama streaming client.
pub const Client = struct {
    alloc: Allocator,
    /// Ollama server base URL.
    base_url: []const u8,
    /// Model name.
    model: []const u8,
    /// Maximum tokens in response.
    max_tokens: u32,

    /// Initializes client.
    pub fn init(alloc: Allocator, base_url: []const u8, model: []const u8, max_tokens: u32) Client {
        return .{ .alloc = alloc, .base_url = base_url, .model = model, .max_tokens = max_tokens };
    }

    fn getIdleTimeoutSecs() u32 {
        const s = utils.getEnvSlice("MINI_WATCHDOG_ENABLED") orelse return 30;
        const v = std.mem.trim(u8, s, " \t");
        const disabled = std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "off");
        return if (disabled) 0 else 30;
    }

    fn finalizeResponse(self: *Client, ctx: *StreamCtx, req_http_code: u32, idle_aborted: bool) !proto.Response {
        _ = self;
        ctx.response.http_code = req_http_code;
        if (idle_aborted) {
            ctx.response.stop_reason = .stream_aborted;
            ctx.response.generation_stop = .stream_aborted;
        } else if (!ctx.seen_done and req_http_code < 400) {
            ctx.response.stop_reason = .unknown;
        }

        if (ctx.text_accum.items.len > 0) {
            const text = try ctx.alloc.dupe(u8, ctx.text_accum.items);
            try ctx.response.content.append(ctx.alloc, .{ .text = text });
        }
        if (req_http_code >= 400 or ctx.response.stop_reason == .unknown) {
            if (ctx.raw_accum_init and ctx.response.raw_debug_info == null) {
                ctx.response.raw_debug_info = ctx.alloc.dupe(u8, ctx.raw_accum.items) catch null;
            }
        }
        if (ctx.raw_accum_init) ctx.raw_accum.deinit(ctx.alloc);
        return ctx.response;
    }

    /// Sends messages and receives streaming NDJSON response.
    pub fn sendMessage(
        self: *Client,
        system_prompt: []const u8,
        msgs: []const proto.Message,
        tools: []const proto.ToolDefinition,
        text_cb: ?*const fn ([]const u8) void,
        think_cb: ?*const fn ([]const u8) void,
    ) !proto.Response {
        // PSEUDOCODE:
        // 1. Build request body and endpoint URL
        // 2. Setup streaming context and watchdog
        // 3. Post HTTP request and parse NDJSON stream
        // 4. Finalize and return proto.Response
        _ = think_cb;
        const body = try buildRequestBody(self.alloc, self.model, system_prompt, msgs, tools);
        defer self.alloc.free(body);

        var url_buf: [512]u8 = undefined;
        const base_no_slash = std.mem.trimEnd(u8, self.base_url, "/");
        const url = std.fmt.bufPrint(&url_buf, "{s}/api/chat", .{base_no_slash}) catch return error.UrlBufOverflow;

        var ctx = StreamCtx{
            .alloc = self.alloc,
            .response = proto.Response.init(self.alloc),
            .text_cb = text_cb,
            .line_buf = .empty,
            .text_accum = .empty,
        };
        defer ctx.line_buf.deinit(self.alloc);
        defer ctx.text_accum.deinit(self.alloc);
        errdefer ctx.response.deinit();
        errdefer if (ctx.raw_accum_init) ctx.raw_accum.deinit(self.alloc);

        const headers = [_][]const u8{"Content-Type: application/json"};
        var idle_aborted = false;
        const stream_result = http_lib.postStream(self.alloc, main.g_io, .{
            .url = url,
            .headers = &headers,
            .body = body,
            .idle_timeout_secs = getIdleTimeoutSecs(),
            .out_idle_aborted = &idle_aborted,
        }, StreamCtx.onChunk, &ctx);

        const req_http_code = if (stream_result) |c| c else |e| switch (e) {
            error.StreamIdleTimeout => 598,
            else => return e,
        };

        return self.finalizeResponse(&ctx, req_http_code, idle_aborted);
    }
};

// ---------------------------------------------------------------------------
// Request building
// ---------------------------------------------------------------------------

fn appendOllamaTools(w: *utils.BufWriter, tools: []const proto.ToolDefinition) !void {
    if (tools.len == 0) return;
    try w.writeAll(",\"tools\":[");
    for (tools, 0..) |td, ti| {
        if (ti > 0) try w.writeByte(',');
        try w.print(
            \\{{"type":"function","function":{{"name":"{s}","description":"{s}","parameters":{s}}}}}
        , .{ td.name, td.description, td.input_schema_json });
    }
    try w.writeByte(']');
}

fn appendOllamaMessage(w: *utils.BufWriter, alloc: Allocator, msg: *const proto.Message) !void {
    var content_buf = ArrayList(u8).empty;
    defer content_buf.deinit(alloc);
    var image_list = ArrayList([]const u8).empty;
    defer image_list.deinit(alloc);
    for (msg.content) |block| {
        switch (block) {
            .text => |t| try content_buf.appendSlice(alloc, t),
            .tool_result => |tr| {
                const s = try std.fmt.allocPrint(alloc, "[tool_result: {s}]", .{tr.content});
                defer alloc.free(s);
                try content_buf.appendSlice(alloc, s);
            },
            .image => |img| try image_list.append(alloc, img.data),
            else => {},
        }
    }
    const escaped = try json.escape(alloc, content_buf.items);
    defer alloc.free(escaped);
    try w.print("{{\"role\":\"{s}\",\"content\":\"{s}\"", .{ msg.role.toJson(), escaped });
    if (image_list.items.len > 0) {
        try w.writeAll(",\"images\":[");
        for (image_list.items, 0..) |img_data, ii| {
            if (ii > 0) try w.writeByte(',');
            try w.print("\"{s}\"", .{img_data});
        }
        try w.writeByte(']');
    }
    try w.writeByte('}');
}

pub fn buildRequestBody(
    alloc: Allocator,
    model: []const u8,
    system_prompt: []const u8,
    msgs: []const proto.Message,
    tools: []const proto.ToolDefinition,
) ![]u8 {
    // PSEUDOCODE:
    // 1. Write model and stream flag
    // 2. Append tools if any
    // 3. Append system prompt and message history
    var buf = utils.BufWriter.init(alloc);
    errdefer buf.deinit();
    const w = &buf;

    try w.print("{{\"model\":\"{s}\",\"stream\":true", .{model});
    try appendOllamaTools(w, tools);
    try w.writeAll(",\"messages\":[");

    if (system_prompt.len > 0) {
        const e = try json.escape(alloc, system_prompt);
        defer alloc.free(e);
        try w.print("{{\"role\":\"system\",\"content\":\"{s}\"}}", .{e});
        if (msgs.len > 0) try w.writeByte(',');
    }

    for (msgs, 0..) |*msg, mi| {
        try appendOllamaMessage(w, alloc, msg);
        if (mi + 1 < msgs.len) try w.writeByte(',');
    }
    try w.writeByte(']');
    try w.writeByte('}');
    return buf.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// NDJSON stream parser
// ---------------------------------------------------------------------------

const StreamCtx = struct {
    alloc: Allocator,
    response: proto.Response,
    text_cb: ?*const fn ([]const u8) void,
    line_buf: ArrayList(u8),
    text_accum: ArrayList(u8),
    seen_done: bool = false,
    raw_accum: ArrayList(u8) = undefined,
    raw_accum_init: bool = false,

    fn onChunk(chunk: []const u8, userdata: *anyopaque) void {
        const self: *StreamCtx = @ptrCast(@alignCast(userdata));
        if (!self.raw_accum_init) {
            self.raw_accum = .empty;
            self.raw_accum_init = true;
        }
        const remaining = proto.MAX_RESPONSE_SNIPPET_LEN - @min(self.raw_accum.items.len, proto.MAX_RESPONSE_SNIPPET_LEN);
        if (remaining > 0) {
            self.raw_accum.appendSlice(self.alloc, chunk[0..@min(chunk.len, remaining)]) catch {};
        }

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
        if (trimmed.len == 0) return;

        // Extract message.content
        if (json.findObject(trimmed, "message")) |msg_obj| {
            if (json.findString(msg_obj, "content")) |content| {
                if (content.len > 0) {
                    const unescaped = json.unescape(self.alloc, content) catch content;
                    defer if (unescaped.ptr != content.ptr) self.alloc.free(unescaped);
                    try self.text_accum.appendSlice(self.alloc, unescaped);
                    if (self.text_cb) |cb| cb(unescaped);
                }
            }

            // Tool calls
            if (json.findArray(msg_obj, "tool_calls")) |tc_arr| {
                // Save text before handling tool calls
                if (self.text_accum.items.len > 0) {
                    const text = try self.alloc.dupe(u8, self.text_accum.items);
                    try self.response.content.append(self.alloc, .{ .text = text });
                    self.text_accum.clearRetainingCapacity();
                }
                _ = tc_arr;
                // Parse tool call from full line
                if (json.findString(trimmed, "name")) |name| {
                    const args = json.findObject(trimmed, "arguments") orelse "";
                    const id = try std.fmt.allocPrint(self.alloc, "call_{d}", .{self.response.content.items.len});
                    try self.response.content.append(self.alloc, .{ .tool_use = .{
                        .id = id,
                        .name = try self.alloc.dupe(u8, name),
                        .input_json = try self.alloc.dupe(u8, args),
                    } });
                    self.response.stop_reason = .tool_use;
                }
            }
        }

        // done flag
        if (json.findBool(trimmed, "done")) {
            self.seen_done = true;
            if (self.text_accum.items.len > 0) {
                const text = try self.alloc.dupe(u8, self.text_accum.items);
                try self.response.content.append(self.alloc, .{ .text = text });
                self.text_accum.clearRetainingCapacity();
            }
            if (self.response.stop_reason == .unknown) self.response.stop_reason = .end_turn;
            self.response.generation_stop = proto.toGenerationStop(self.response.stop_reason, 200);
        }
    }
};

const testing = std.testing;

test "RFC-023: Ollama idle abort overrides earlier terminal state" {
    const alloc = testing.allocator;
    var ctx = StreamCtx{
        .alloc = alloc,
        .response = proto.Response.init(alloc),
        .text_cb = null,
        .line_buf = .empty,
        .text_accum = .empty,
    };
    ctx.response.stop_reason = .end_turn;
    ctx.response.generation_stop = .natural_end;
    defer ctx.line_buf.deinit(alloc);
    defer ctx.text_accum.deinit(alloc);

    var client = Client.init(alloc, "http://localhost:11434", "test", 1024);
    var response = try client.finalizeResponse(&ctx, 200, true);
    defer response.deinit();

    try testing.expectEqual(proto.GenerationStop.stream_aborted, response.getGenerationStop());
}

test "RFC-023: Ollama done populates generation stop" {
    const alloc = testing.allocator;
    var ctx = StreamCtx{
        .alloc = alloc,
        .response = proto.Response.init(alloc),
        .text_cb = null,
        .line_buf = .empty,
        .text_accum = .empty,
    };
    defer ctx.response.deinit();
    defer ctx.line_buf.deinit(alloc);
    defer ctx.text_accum.deinit(alloc);

    try ctx.processLine("{\"message\":{\"role\":\"assistant\",\"content\":\"done\"},\"done\":true}");

    try testing.expectEqual(proto.StopReason.end_turn, ctx.response.stop_reason);
    try testing.expectEqual(proto.GenerationStop.natural_end, ctx.response.generation_stop);
}
