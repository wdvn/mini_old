//! backend/claude.zig — Anthropic Claude streaming client.
//!
//! Communicates with the Anthropic Messages API using Claude-specific SSE format.
//!
//! ## Endpoint
//! POST https://api.anthropic.com/v1/messages
//!
//! ## Key SSE events
//!   `content_block_start`  — starts text or tool_use block
//!   `content_block_delta`  — delta of text or input_json
//!   `content_block_stop`   — ends block
//!   `message_delta`        — stop_reason upon completion
//!   `message_stop`         — full message complete
//!
//! ## Default model
//! `claude-opus-4-5` — can be overridden via `CLAUDE_MODEL`.

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
    /// Maximum tokens.
    max_tokens: u32,
    /// Dynamic thinking budget tokens override.
    active_thinking_budget: ?u32,

    /// Initializes client.
    pub fn init(alloc: Allocator, api_key: []const u8, model: []const u8, max_tokens: u32) Client {
        return .{
            .alloc = alloc,
            .api_key = api_key,
            .model = model,
            .max_tokens = max_tokens,
            .active_thinking_budget = null,
        };
    }

    /// Set dynamic thinking budget tokens override.
    pub fn setThinkingBudget(self: *Client, budget: ?u32) void {
        self.active_thinking_budget = budget;
    }

    /// Idle watchdog timeout scaled by active thinking budget (RFC-009 Phase 5).
    fn effectiveIdleTimeout(self: *const Client) u32 {
        // Disabled? Return 0 to skip idle polling entirely.
        if (utils.getEnvSlice("MINI_WATCHDOG_ENABLED")) |s| {
            const v = std.mem.trim(u8, s, " \t");
            if (std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "off")) return 0;
        }
        if (utils.getEnvSlice("MINI_STREAM_IDLE_TIMEOUT")) |s| {
            return std.fmt.parseInt(u32, std.mem.trim(u8, s, " \t"), 10) catch 0;
        }
        const b = self.active_thinking_budget orelse return 30;
        if (b <= 1024) return 15;
        if (b > 4096) return 60;
        return 30;
    }

    fn finalizeClaudeResponse(self: *Client, ctx: *StreamCtx, req_http_code: u16, idle_aborted: bool) !proto.Response {
        ctx.response.http_code = req_http_code;
        if (idle_aborted) ctx.response.stop_reason = .stream_aborted;

        if (ctx.text_accum.items.len > 0) {
            const text = try self.alloc.dupe(u8, ctx.text_accum.items);
            try ctx.response.content.append(self.alloc, .{ .text = text });
        }

        hooks.dispatch(self.alloc, main.g_io, .{
            .event = "message_stop",
            .role = "assistant",
            .model = self.model,
            .stop_reason = @tagName(ctx.response.stop_reason),
        });

        if (ctx.raw_accum_init and ctx.raw_accum.items.len > 0) {
            ctx.response.raw_debug_info = ctx.raw_accum.toOwnedSlice(self.alloc) catch null;
        }

        return ctx.response;
    }

    fn executeStreamRequest(
        self: *Client,
        body: []const u8,
        auth_hdr: []const u8,
        ctx: *StreamCtx,
        idle_aborted: *bool,
    ) !u32 {
        const headers = [_][]const u8{
            auth_hdr,
            "anthropic-version: " ++ CLAUDE_API_VERSION,
            "anthropic-beta: prompt-caching-2024-07-31",
            "Content-Type: application/json",
        };
        const stream_result = http_lib.postStream(self.alloc, main.g_io, .{
            .url = CLAUDE_API_URL,
            .headers = &headers,
            .body = body,
            .idle_timeout_secs = self.effectiveIdleTimeout(),
            .out_idle_aborted = idle_aborted,
        }, StreamCtx.onChunk, ctx);

        return if (stream_result) |c| c else |e| switch (e) {
            error.StreamIdleTimeout => 598,
            else => return e,
        };
    }

    /// Sends messages and receives streaming response via Claude SSE.
    pub fn sendMessage(
        self: *Client,
        system_prompt: []const u8,
        msgs: []const proto.Message,
        tools: []const proto.ToolDefinition,
        text_cb: ?*const fn ([]const u8) void,
        think_cb: ?*const fn ([]const u8) void,
    ) !proto.Response {
        const body = try buildRequestBody(self.alloc, self.model, self.max_tokens, self.active_thinking_budget, system_prompt, msgs, tools);
        defer self.alloc.free(body);

        hooks.dispatch(self.alloc, main.g_io, .{ .event = "message_start", .role = "assistant", .model = self.model });

        var auth_buf: [512]u8 = undefined;
        const auth_hdr = std.fmt.bufPrint(&auth_buf, "x-api-key: {s}", .{self.api_key}) catch return error.AuthBufOverflow;

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
        errdefer ctx.response.deinit();
        errdefer if (ctx.raw_accum_init) ctx.raw_accum.deinit(self.alloc);

        var idle_aborted = false;
        const req_http_code = try self.executeStreamRequest(body, auth_hdr, &ctx, &idle_aborted);
        return self.finalizeClaudeResponse(&ctx, req_http_code, idle_aborted);
    }
};

// ---------------------------------------------------------------------------
// Request building
// ---------------------------------------------------------------------------


fn appendClaudeContentBlock(w: *utils.BufWriter, alloc: Allocator, block: proto.ContentBlock) !void {
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
            try w.print("{{\"type\":\"thinking\",\"thinking\":\"{s}\",\"signature\":\"{s}\"}}", .{ t, s });
        },
        .tool_use => |tu| {
            try w.print("{{\"type\":\"tool_use\",\"id\":\"{s}\",\"name\":\"{s}\",\"input\":{s}}}", .{ tu.id, tu.name, tu.input_json });
        },
        .tool_result => |tr| {
            const e = try json.escape(alloc, tr.content);
            defer alloc.free(e);
            try w.print("{{\"type\":\"tool_result\",\"tool_use_id\":\"{s}\",\"content\":\"{s}\",\"is_error\":{s}}}", .{ tr.tool_use_id, e, if (tr.is_error) "true" else "false" });
        },
        .image => |img| {
            try w.print("{{\"type\":\"image\",\"source\":{{\"type\":\"base64\",\"media_type\":\"{s}\",\"data\":\"{s}\"}}}}", .{ img.media_type, img.data });
        },
    }
}

fn appendClaudeSingleBlock(w: *utils.BufWriter, alloc: Allocator, block: proto.ContentBlock) !void {
    if (block == .text) {
        const e = try json.escape(alloc, block.text);
        defer alloc.free(e);
        try w.print("\"{s}\"", .{e});
    } else {
        try w.writeByte('[');
        try appendClaudeContentBlock(w, alloc, block);
        try w.writeByte(']');
    }
}

fn appendClaudeMultiBlock(w: *utils.BufWriter, alloc: Allocator, content: []const proto.ContentBlock) !void {
    try w.writeByte('[');
    var first_block = true;
    for (content) |block| {
        if (block == .text and block.text.len == 0) continue;
        if (!first_block) try w.writeByte(',');
        first_block = false;
        try appendClaudeContentBlock(w, alloc, block);
    }
    try w.writeByte(']');
}

fn appendClaudeMessage(w: *utils.BufWriter, alloc: Allocator, msg: *const proto.Message) !void {
    try w.print("{{\"role\":\"{s}\",\"content\":", .{msg.role.toJson()});
    if (msg.content.len == 1) {
        try appendClaudeSingleBlock(w, alloc, msg.content[0]);
    } else {
        try appendClaudeMultiBlock(w, alloc, msg.content);
    }
    try w.writeByte('}');
}

fn appendClaudeTools(w: *utils.BufWriter, tools: []const proto.ToolDefinition) !void {
    if (tools.len == 0) return;
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
    try w.writeAll("],\"tool_choice\":{\"type\":\"auto\"}");
}

pub fn buildRequestBody(
    alloc: Allocator,
    model: []const u8,
    max_tokens: u32,
    thinking_budget: ?u32,
    system_prompt: []const u8,
    msgs: []const proto.Message,
    tools: []const proto.ToolDefinition,
) ![]const u8 {
    // PSEUDOCODE:
    // 1. Compute effective max tokens and thinking config string
    // 2. Format model, system prompt with ephemeral caching
    // 3. Append messages and tools
    var buf = utils.BufWriter.init(alloc);
    errdefer buf.deinit();
    const w = &buf;

    const escaped_sys = try json.escape(alloc, system_prompt);
    defer alloc.free(escaped_sys);

    var effective_max_tokens = max_tokens;
    var thinking_str_buf: [128]u8 = undefined;
    const thinking_str: []const u8 = blk: {
        if (thinking_budget) |budget| {
            if (budget >= 1024) {
                if (effective_max_tokens <= budget) effective_max_tokens = budget + 4096;
                break :blk std.fmt.bufPrint(&thinking_str_buf, ",\"thinking\":{{\"type\":\"enabled\",\"budget_tokens\":{d}}}", .{budget}) catch "";
            }
        }
        break :blk "";
    };

    try w.print(
        \\{{"model":"{s}","max_tokens":{d},"stream":true{s},"system":[{{"type":"text","text":"{s}","cache_control":{{"type":"ephemeral"}}}}],"messages":[
    , .{ model, effective_max_tokens, thinking_str, escaped_sys });

    for (msgs, 0..) |*msg, mi| {
        try appendClaudeMessage(w, alloc, msg);
        if (mi + 1 < msgs.len) try w.writeByte(',');
    }
    try w.writeByte(']');

    try appendClaudeTools(w, tools);
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
    raw_accum: ArrayList(u8) = undefined,
    raw_accum_init: bool = false,

    fn onChunk(chunk: []const u8, userdata: *anyopaque) void {
        const self: *StreamCtx = @ptrCast(@alignCast(userdata));
        if (!self.raw_accum_init) {
            self.raw_accum = .empty;
            self.raw_accum_init = true;
        }
        if (self.raw_accum.items.len < 64 * 1024) {
            self.raw_accum.appendSlice(self.alloc, chunk) catch {};
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

    fn handleContentBlockStart(self: *StreamCtx, data: []const u8) void {
        hooks.dispatch(self.alloc, main.g_io, .{ .event = "content_block_start" });
        const t = json.findString(data, "type") orelse return;
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

    fn handleContentBlockDelta(self: *StreamCtx, data: []const u8) !void {
        if (self.in_tool_block) {
            if (json.findString(data, "partial_json")) |pj| {
                try self.args_accum.appendSlice(self.alloc, pj);
                hooks.dispatch(self.alloc, main.g_io, .{
                    .event = "content_block_delta", .block_type = "tool_use", .delta_text = pj,
                });
            }
            return;
        }
        if (self.in_think_block) {
            if (json.findString(data, "thinking")) |thinking| {
                if (thinking.len > 0) {
                    const unescaped = json.unescape(self.alloc, thinking) catch thinking;
                    defer self.alloc.free(unescaped);
                    try self.think_accum.appendSlice(self.alloc, unescaped);
                    if (self.think_cb) |cb| cb(unescaped);
                    hooks.dispatch(self.alloc, main.g_io, .{
                        .event = "content_block_delta", .block_type = "thinking", .delta_text = unescaped,
                    });
                }
            }
            return;
        }
        if (json.findString(data, "text")) |text| {
            if (text.len > 0) {
                const unescaped = json.unescape(self.alloc, text) catch text;
                defer self.alloc.free(unescaped);
                try self.text_accum.appendSlice(self.alloc, unescaped);
                if (self.text_cb) |cb| cb(unescaped);
                hooks.dispatch(self.alloc, main.g_io, .{
                    .event = "content_block_delta", .block_type = "text", .delta_text = unescaped,
                });
            }
        }
    }

    fn handleContentBlockStop(self: *StreamCtx) !void {
        hooks.dispatch(self.alloc, main.g_io, .{ .event = "content_block_stop" });
        if (self.in_tool_block) {
            const id = try self.alloc.dupe(u8, self.current_tool_id[0..self.current_tool_id_len]);
            const name = try self.alloc.dupe(u8, self.current_tool_name[0..self.current_tool_name_len]);
            const args = if (self.args_accum.items.len > 0)
                json.unescape(self.alloc, self.args_accum.items) catch try self.alloc.dupe(u8, self.args_accum.items)
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
    }

    fn handleMessageDelta(self: *StreamCtx, data: []const u8) void {
        if (json.findString(data, "stop_reason")) |reason| {
            self.response.stop_reason = parseStopReason(reason);
            hooks.dispatch(self.alloc, main.g_io, .{
                .event = "message_delta", .stop_reason = reason,
            });
        }
    }

    fn processLine(self: *StreamCtx, line: []const u8) !void {
        // PSEUDOCODE:
        // 1. Trim line and update event_type if event prefix
        // 2. Check for data prefix and dispatch to event handler
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
            self.handleContentBlockStart(data);
        } else if (std.mem.eql(u8, ev, "content_block_delta")) {
            try self.handleContentBlockDelta(data);
        } else if (std.mem.eql(u8, ev, "content_block_stop")) {
            try self.handleContentBlockStop();
        } else if (std.mem.eql(u8, ev, "message_delta")) {
            self.handleMessageDelta(data);
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

    const body = try buildRequestBody(alloc, "claude-3-5-sonnet", 1024, null, "System prompt test", &msgs, &tools);
    defer alloc.free(body);

    // Verify cache_control exists in system prompt
    try testing.expect(std.mem.indexOf(u8, body, "\"cache_control\":{\"type\":\"ephemeral\"}") != null);
    // Verify system prompt formatted as array block
    try testing.expect(std.mem.indexOf(u8, body, "\"system\":[{\"type\":\"text\",\"text\":\"System prompt test\",\"cache_control\":{\"type\":\"ephemeral\"}}]") != null);
    // Verify tool2 (last tool) has cache_control
    try testing.expect(std.mem.indexOf(u8, body, "\"name\":\"tool2\",\"description\":\"desc2\",\"input_schema\":{},\"cache_control\":{\"type\":\"ephemeral\"}") != null);
}

test "claude buildRequestBody dynamic thinking budget" {
    const alloc = testing.allocator;
    const msgs = [_]proto.Message{};
    const tools = [_]proto.ToolDefinition{};

    // With thinking budget = 2048, max_tokens = 1024 -> effective_max_tokens auto-adjusted > budget (2048 + 4096 = 6144)
    const body = try buildRequestBody(alloc, "claude-3-7-sonnet", 1024, 2048, "test", &msgs, &tools);
    defer alloc.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":2048}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":6144") != null);
}
