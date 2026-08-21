//! backend/ollama.zig — Ollama local AI client.
//!
//! Giao tiếp với Ollama qua API `/api/chat` với NDJSON streaming.
//! Ollama chạy local, không cần API key, phù hợp để dùng offline.
//!
//! ## Endpoint
//! POST {ollama_host}/api/chat
//!
//! ## Định dạng response (NDJSON)
//! Mỗi dòng là một JSON object:
//! ```json
//! {"message":{"role":"assistant","content":"Xin chào"},"done":false}
//! {"message":{"role":"assistant","content":"!"},"done":true}
//! ```
//!
//! ## Tool calls
//! Ollama hỗ trợ tool calls từ phiên bản 0.3.0+.
//! Format giống OpenAI: `message.tool_calls[0].function.{name,arguments}`.
//!
//! ## Cấu hình
//!   `OLLAMA_HOST`   URL base (mặc định: http://localhost:11434)
//!   `OLLAMA_MODEL`  Tên model (mặc định: llama3)

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const proto = @import("../core/protocol.zig");
const json = @import("../core/json.zig");
const sse = @import("sse.zig");
const utils = @import("../core/utils.zig");

/// Ollama streaming client.
pub const Client = struct {
    alloc: Allocator,
    /// Base URL của Ollama server.
    base_url: []const u8,
    /// Tên model.
    model: []const u8,
    /// Số token tối đa trong response.
    max_tokens: u32,

    /// Khởi tạo client.
    pub fn init(alloc: Allocator, base_url: []const u8, model: []const u8, max_tokens: u32) Client {
        return .{ .alloc = alloc, .base_url = base_url, .model = model, .max_tokens = max_tokens };
    }

    /// Gửi messages và nhận phản hồi NDJSON streaming.
    pub fn sendMessage(
        self: *Client,
        system_prompt: []const u8,
        msgs: []const proto.Message,
        tools: []const proto.ToolDefinition,
        text_cb: ?*const fn ([]const u8) void,
        think_cb: ?*const fn ([]const u8) void,
    ) !proto.Response {
        _ = think_cb;
        const body = try buildRequestBody(self.alloc, self.model, system_prompt, msgs, tools);
        defer self.alloc.free(body);

        // Build endpoint URL
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

        const headers = [_][]const u8{"Content-Type: application/json"};
        _ = try sse.post(self.alloc, .{
            .url = url,
            .headers = &headers,
            .body = body,
        }, StreamCtx.onChunk, &ctx);

        // Lưu text còn lại
        if (ctx.text_accum.items.len > 0) {
            const text = try self.alloc.dupe(u8, ctx.text_accum.items);
            try ctx.response.content.append(ctx.alloc, .{ .text = text });
        }
        if (ctx.response.stop_reason == .unknown) ctx.response.stop_reason = .end_turn;

        return ctx.response;
    }
};

// ---------------------------------------------------------------------------
// Request building
// ---------------------------------------------------------------------------

fn buildRequestBody(
    alloc: Allocator,
    model: []const u8,
    system_prompt: []const u8,
    msgs: []const proto.Message,
    tools: []const proto.ToolDefinition,
) ![]u8 {
    var buf = utils.BufWriter.init(alloc);
    errdefer buf.deinit();
    const w = &buf;

    try w.print("{{\"model\":\"{s}\",\"stream\":true,\"messages\":[", .{model});

    // System
    if (system_prompt.len > 0) {
        const e = try json.escape(alloc, system_prompt);
        defer alloc.free(e);
        try w.print("{{\"role\":\"system\",\"content\":\"{s}\"}}", .{e});
        if (msgs.len > 0) try w.writeByte(',');
    }

    // Messages (Ollama dùng content string, không phải array)
    for (msgs, 0..) |msg, mi| {
        var content_buf = ArrayList(u8).empty;
        defer content_buf.deinit(alloc);
        for (msg.content) |block| {
            switch (block) {
                .text => |t| try content_buf.appendSlice(alloc, t),
                .tool_result => |tr| {
                    const s = try std.fmt.allocPrint(alloc, "[tool_result: {s}]", .{tr.content});
                    defer alloc.free(s);
                    try content_buf.appendSlice(alloc, s);
                },
                else => {},
            }
        }
        const escaped = try json.escape(alloc, content_buf.items);
        defer alloc.free(escaped);
        try w.print("{{\"role\":\"{s}\",\"content\":\"{s}\"}}", .{ msg.role.toJson(), escaped });
        if (mi + 1 < msgs.len) try w.writeByte(',');
    }
    try w.writeByte(']');

    // Tools (Ollama 0.3.0+)
    if (tools.len > 0) {
        try w.writeAll(",\"tools\":[");
        for (tools, 0..) |td, ti| {
            if (ti > 0) try w.writeByte(',');
            try w.print(
                \\{{"type":"function","function":{{"name":"{s}","description":"{s}","parameters":{s}}}}}
            , .{ td.name, td.description, td.input_schema_json });
        }
        try w.writeByte(']');
    }

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

    fn onChunk(chunk: []const u8, userdata: *anyopaque) void {
        const self: *StreamCtx = @ptrCast(@alignCast(userdata));
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
                    defer self.alloc.free(unescaped);
                    try self.text_accum.appendSlice(self.alloc, unescaped);
                    if (self.text_cb) |cb| cb(unescaped);
                }
            }

            // Tool calls
            if (json.findArray(msg_obj, "tool_calls")) |tc_arr| {
                // Lưu text trước khi xử lý tool calls
                if (self.text_accum.items.len > 0) {
                    const text = try self.alloc.dupe(u8, self.text_accum.items);
                    try self.response.content.append(self.alloc, .{ .text = text });
                    self.text_accum.clearRetainingCapacity();
                }
                _ = tc_arr;
                // Parse tool call từ full line
                if (json.findString(trimmed, "name")) |name| {
                    const args = json.findObject(trimmed, "arguments") orelse "{}";
                    const id = try std.fmt.allocPrint(self.alloc, "call_{d}", .{self.response.content.items.len});
                    try self.response.content.append(self.alloc, .{ .tool_use = .{
                        .id = id,
                        .name = try self.alloc.dupe(u8, name),
                        .input_json = try self.alloc.dupe(u8, args),
                    }});
                    self.response.stop_reason = .tool_use;
                }
            }
        }

        // done flag
        if (json.findBool(trimmed, "done")) {
            if (self.text_accum.items.len > 0) {
                const text = try self.alloc.dupe(u8, self.text_accum.items);
                try self.response.content.append(self.alloc, .{ .text = text });
                self.text_accum.clearRetainingCapacity();
            }
            if (self.response.stop_reason == .unknown) self.response.stop_reason = .end_turn;
        }
    }
};
