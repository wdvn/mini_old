//! backend/claude.zig — Anthropic Claude streaming client.
//!
//! Giao tiếp với Anthropic Messages API sử dụng SSE theo chuẩn riêng của Claude.
//!
//! ## Endpoint
//! POST https://api.anthropic.com/v1/messages
//!
//! ## SSE events chính
//!   `content_block_start`  — bắt đầu khối text hoặc tool_use
//!   `content_block_delta`  — delta của text hoặc input_json
//!   `content_block_stop`   — kết thúc khối
//!   `message_delta`        — stop_reason khi kết thúc
//!   `message_stop`         — toàn bộ message hoàn thành
//!
//! ## Model mặc định
//! `claude-opus-4-5` — có thể override bằng biến `CLAUDE_MODEL`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const proto = @import("../core/protocol.zig");
const json = @import("../core/json.zig");
const http_lib = @import("../lib/http_request.zig");
const utils = @import("../core/utils.zig");
const hooks = @import("../core/hooks.zig");
const main = @import("../main.zig");

pub const CLAUDE_API_URL = "https://api.anthropic.com/v1/messages";
pub const CLAUDE_API_VERSION = "2023-06-01";

/// Anthropic Claude streaming client.
pub const Client = struct {
    alloc: Allocator,
    /// Anthropic API key (sk-ant-...).
    api_key: []const u8,
    /// Claude model ID.
    model: []const u8,
    /// Số token tối đa.
    max_tokens: u32,

    /// Khởi tạo client.
    pub fn init(alloc: Allocator, api_key: []const u8, model: []const u8, max_tokens: u32) Client {
        return .{ .alloc = alloc, .api_key = api_key, .model = model, .max_tokens = max_tokens };
    }

    /// Gửi messages và nhận phản hồi streaming theo SSE của Claude.
    pub fn sendMessage(
        self: *Client,
        system_prompt: []const u8,
        msgs: []const proto.Message,
        tools: []const proto.ToolDefinition,
        text_cb: ?*const fn ([]const u8) void,
        think_cb: ?*const fn ([]const u8) void,
    ) !proto.Response {
        const body = try buildRequestBody(self.alloc, self.model, self.max_tokens, system_prompt, msgs, tools);
        defer self.alloc.free(body);

        hooks.dispatch(self.alloc, main.g_io, .{
            .event = "message_start",
            .role = "assistant",
            .model = self.model,
        });

        var auth_buf: [512]u8 = undefined;
        const auth_hdr = std.fmt.bufPrint(&auth_buf, "x-api-key: {s}", .{self.api_key}) catch return error.AuthBufOverflow;
        const api_ver_hdr = "anthropic-version: " ++ CLAUDE_API_VERSION;

        var ctx = StreamCtx{
            .alloc = self.alloc,
            .response = proto.Response.init(self.alloc),
            .text_cb = text_cb,
            .think_cb = think_cb,
            .line_buf = .empty,
            .text_accum = .empty,
            .think_accum = .empty,
            .args_accum = .empty,
        };
        defer ctx.line_buf.deinit(self.alloc);
        defer ctx.text_accum.deinit(self.alloc);
        defer ctx.think_accum.deinit(self.alloc);
        defer ctx.args_accum.deinit(self.alloc);

        const headers = [_][]const u8{
            auth_hdr,
            api_ver_hdr,
            "anthropic-beta: prompt-caching-2024-07-31",
            "Content-Type: application/json",
        };
        _ = try http_lib.postStream(self.alloc, main.g_io, .{
            .url = CLAUDE_API_URL,
            .headers = &headers,
            .body = body,
        }, StreamCtx.onChunk, &ctx);

        // Lưu text còn lại nếu có
        if (ctx.text_accum.items.len > 0) {
            const text = try self.alloc.dupe(u8, ctx.text_accum.items);
            try ctx.response.content.append(ctx.alloc, .{ .text = text });
        }

        hooks.dispatch(self.alloc, main.g_io, .{
            .event = "message_stop",
            .model = self.model,
            .stop_reason = @tagName(ctx.response.stop_reason),
        });

        return ctx.response;
    }
};

// ---------------------------------------------------------------------------
// Request building
// ---------------------------------------------------------------------------

fn buildRequestBody(
    alloc: Allocator,
    model: []const u8,
    max_tokens: u32,
    system_prompt: []const u8,
    msgs: []const proto.Message,
    tools: []const proto.ToolDefinition,
) ![]u8 {
    var buf = utils.BufWriter.init(alloc);
    errdefer buf.deinit();
    const w = &buf;

    // System prompt (với cache_control cho Anthropic Prompt Caching)
    const escaped_sys = try json.escape(alloc, system_prompt);
    defer alloc.free(escaped_sys);

    try w.print(
        \\{{"model":"{s}","max_tokens":{d},"stream":true,"system":[{"type":"text","text":"{s}","cache_control":{{"type":"ephemeral"}}}],"messages":[
    , .{ model, max_tokens, escaped_sys });

    for (msgs, 0..) |msg, mi| {
        try w.print("{{\"role\":\"{s}\",\"content\":", .{msg.role.toJson()});

        if (msg.content.len == 1) {
            switch (msg.content[0]) {
                .text => |t| {
                    const e = try json.escape(alloc, t);
                    defer alloc.free(e);
                    try w.print("\"{s}\"", .{e});
                },
                .thinking => |th| {
                    const t = try json.escape(alloc, th.thinking);
                    defer alloc.free(t);
                    const s = try json.escape(alloc, th.signature);
                    defer alloc.free(s);
                    try w.print(
                        \\[{{"type":"thinking","thinking":"{s}","signature":"{s}"}}]
                    , .{ t, s });
                },
                .tool_use => |tu| {
                    try w.print(
                        \\[{{"type":"tool_use","id":"{s}","name":"{s}","input":{s}}}]
                    , .{ tu.id, tu.name, tu.input_json });
                },
                .tool_result => |tr| {
                    const e = try json.escape(alloc, tr.content);
                    defer alloc.free(e);
                    try w.print(
                        \\[{{"type":"tool_result","tool_use_id":"{s}","content":"{s}","is_error":{s}}}]
                    , .{ tr.tool_use_id, e, if (tr.is_error) "true" else "false" });
                },
            }
        } else {
            try w.writeByte('[');
            for (msg.content, 0..) |block, bi| {
                if (bi > 0) try w.writeByte(',');
                switch (block) {
                    .text => |t| {
                        const e = try json.escape(alloc, t);
                        defer alloc.free(e);
                        try w.print("{{\"type\":\"text\",\"text\":\"{s}\"}}", .{e});
                    },
                    .thinking => |th| {
                        const t = try json.escape(alloc, th.thinking);
                        defer alloc.free(t);
                        const s = try json.escape(alloc, th.signature);
                        defer alloc.free(s);
                        try w.print(
                            \\{{"type":"thinking","thinking":"{s}","signature":"{s}"}}
                        , .{ t, s });
                    },
                    .tool_use => |tu| {
                        try w.print(
                            \\{{"type":"tool_use","id":"{s}","name":"{s}","input":{s}}}
                        , .{ tu.id, tu.name, tu.input_json });
                    },
                    .tool_result => |tr| {
                        const e = try json.escape(alloc, tr.content);
                        defer alloc.free(e);
                        try w.print(
                            \\{{"type":"tool_result","tool_use_id":"{s}","content":"{s}","is_error":{s}}}
                        , .{ tr.tool_use_id, e, if (tr.is_error) "true" else "false" });
                    },
                }
            }
            try w.writeByte(']');
        }
        try w.writeByte('}');
        if (mi + 1 < msgs.len) try w.writeByte(',');
    }
    try w.writeByte(']');

    if (tools.len > 0) {
        try w.writeAll(",\"tools\":[");
        for (tools, 0..) |td, ti| {
            if (ti > 0) try w.writeByte(',');
            if (ti == tools.len - 1) {
                try w.print(
                    \\{{"name":"{s}","description":"{s}","input_schema":{s},"cache_control":{{"type":"ephemeral"}}}}
                , .{ td.name, td.description, td.input_schema_json });
            } else {
                try w.print(
                    \\{{"name":"{s}","description":"{s}","input_schema":{s}}}
                , .{ td.name, td.description, td.input_schema_json });
            }
        }
        try w.writeByte(']');
        try w.writeAll(",\"tool_choice\":{\"type\":\"auto\"}");
    }

    try w.writeByte('}');
    return buf.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// SSE stream parser
// ---------------------------------------------------------------------------

const StreamCtx = struct {
    alloc: Allocator,
    response: proto.Response,
    text_cb: ?*const fn ([]const u8) void,
    think_cb: ?*const fn ([]const u8) void,
    line_buf: ArrayList(u8),
    text_accum: ArrayList(u8),
    think_accum: ArrayList(u8),
    args_accum: ArrayList(u8),
    current_tool_id: [128]u8 = undefined,
    current_tool_id_len: usize = 0,
    current_tool_name: [128]u8 = undefined,
    current_tool_name_len: usize = 0,
    current_think_sig: [128]u8 = undefined,
    current_think_sig_len: usize = 0,
    in_tool_block: bool = false,
    in_think_block: bool = false,
    event_type: [64]u8 = undefined,
    event_type_len: usize = 0,

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

        if (std.mem.eql(u8, ev, "content_block_start")) {
            hooks.dispatch(self.alloc, main.g_io, .{
                .event = "content_block_start",
            });
            if (json.findString(data, "type")) |t| {
                if (std.mem.eql(u8, t, "tool_use")) {
                    self.in_tool_block = true;
                    self.args_accum.clearRetainingCapacity();
                    if (json.findString(data, "id")) |id| {
                        const n = @min(id.len, self.current_tool_id.len);
                        @memcpy(self.current_tool_id[0..n], id[0..n]);
                        self.current_tool_id_len = n;
                    }
                    if (json.findString(data, "name")) |name| {
                        const n = @min(name.len, self.current_tool_name.len);
                        @memcpy(self.current_tool_name[0..n], name[0..n]);
                        self.current_tool_name_len = n;
                    }
                } else if (std.mem.eql(u8, t, "thinking")) {
                    self.in_think_block = true;
                    self.think_accum.clearRetainingCapacity();
                    if (json.findString(data, "signature")) |sig| {
                        const n = @min(sig.len, self.current_think_sig.len);
                        @memcpy(self.current_think_sig[0..n], sig[0..n]);
                        self.current_think_sig_len = n;
                    }
                }
            }
        } else if (std.mem.eql(u8, ev, "content_block_delta")) {
            if (self.in_tool_block) {
                if (json.findString(data, "partial_json")) |pj| {
                    try self.args_accum.appendSlice(self.alloc, pj);
                    hooks.dispatch(self.alloc, main.g_io, .{
                        .event = "content_block_delta",
                        .block_type = "tool_use",
                        .delta_text = pj,
                    });
                }
            } else if (self.in_think_block) {
                if (json.findString(data, "thinking")) |thinking| {
                    if (thinking.len > 0) {
                        const unescaped = json.unescape(self.alloc, thinking) catch thinking;
                        defer self.alloc.free(unescaped);
                        try self.think_accum.appendSlice(self.alloc, unescaped);
                        if (self.think_cb) |cb| cb(unescaped);
                        hooks.dispatch(self.alloc, main.g_io, .{
                            .event = "content_block_delta",
                            .block_type = "thinking",
                            .delta_text = unescaped,
                        });
                    }
                }
            } else {
                if (json.findString(data, "text")) |text| {
                    if (text.len > 0) {
                        const unescaped = json.unescape(self.alloc, text) catch text;
                        defer self.alloc.free(unescaped);
                        try self.text_accum.appendSlice(self.alloc, unescaped);
                        if (self.text_cb) |cb| cb(unescaped);
                        hooks.dispatch(self.alloc, main.g_io, .{
                            .event = "content_block_delta",
                            .block_type = "text",
                            .delta_text = unescaped,
                        });
                    }
                }
            }
        } else if (std.mem.eql(u8, ev, "content_block_stop")) {
            hooks.dispatch(self.alloc, main.g_io, .{
                .event = "content_block_stop",
            });
            if (self.in_tool_block) {
                const id = try self.alloc.dupe(u8, self.current_tool_id[0..self.current_tool_id_len]);
                const name = try self.alloc.dupe(u8, self.current_tool_name[0..self.current_tool_name_len]);
                const args = if (self.args_accum.items.len > 0)
                    try self.alloc.dupe(u8, self.args_accum.items)
                else
                    try self.alloc.dupe(u8, "{}");
                try self.response.content.append(self.alloc, .{ .tool_use = .{
                    .id = id, .name = name, .input_json = args,
                }});
                self.in_tool_block = false;
            } else if (self.in_think_block) {
                const think_text = try self.alloc.dupe(u8, self.think_accum.items);
                const sig = try self.alloc.dupe(u8, self.current_think_sig[0..self.current_think_sig_len]);
                try self.response.content.append(self.alloc, .{ .thinking = .{
                    .thinking = think_text, .signature = sig,
                }});
                self.in_think_block = false;
                self.think_accum.clearRetainingCapacity();
            } else if (self.text_accum.items.len > 0) {
                const text = try self.alloc.dupe(u8, self.text_accum.items);
                try self.response.content.append(self.alloc, .{ .text = text });
                self.text_accum.clearRetainingCapacity();
            }
        } else if (std.mem.eql(u8, ev, "message_delta")) {
            if (json.findString(data, "stop_reason")) |reason| {
                self.response.stop_reason = parseStopReason(reason);
                hooks.dispatch(self.alloc, main.g_io, .{
                    .event = "message_delta",
                    .stop_reason = reason,
                });
            }
        } else if (std.mem.eql(u8, ev, "message_stop")) {
            if (self.response.stop_reason == .unknown) self.response.stop_reason = .end_turn;
        }
    }

    fn parseStopReason(s: []const u8) proto.StopReason {
        if (std.mem.eql(u8, s, "end_turn")) return .end_turn;
        if (std.mem.eql(u8, s, "tool_use")) return .tool_use;
        if (std.mem.eql(u8, s, "max_tokens")) return .max_tokens;
        if (std.mem.eql(u8, s, "stop_sequence")) return .stop_sequence;
        return .unknown;
    }
};

// ---------------------------------------------------------------------------
// Unit Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "claude buildRequestBody contains cache_control" {
    const alloc = testing.allocator;
    const msgs = [_]proto.Message{};
    const tools = [_]proto.ToolDefinition{
        .{ .name = "tool1", .description = "desc1", .input_schema_json = "{}" },
        .{ .name = "tool2", .description = "desc2", .input_schema_json = "{}" },
    };

    const body = try buildRequestBody(alloc, "claude-3-5-sonnet", 1024, "System prompt test", &msgs, &tools);
    defer alloc.free(body);

    // Kiểm tra có cache_control trong system prompt
    try testing.expect(std.mem.indexOf(u8, body, "\"cache_control\":{\"type\":\"ephemeral\"}") != null);
    // Kiểm tra system prompt formatted như array block
    try testing.expect(std.mem.indexOf(u8, body, "\"system\":[{\"type\":\"text\",\"text\":\"System prompt test\",\"cache_control\":{\"type\":\"ephemeral\"}}]") != null);
    // Kiểm tra tool2 (tool cuối) có cache_control
    try testing.expect(std.mem.indexOf(u8, body, "\"name\":\"tool2\",\"description\":\"desc2\",\"input_schema\":{},\"cache_control\":{\"type\":\"ephemeral\"}") != null);
}
