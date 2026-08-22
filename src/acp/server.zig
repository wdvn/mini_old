//! acp.zig — Agent Client Protocol (ACP) server cho mini-agent.
//!
//! Giao thức Agent Client Protocol (ACP) là chuẩn mở (JSON-RPC 2.0 over stdio)
//! cho phép mini-agent tích hợp trực tiếp với các IDE/Editor như Zed AI,
//! JetBrains, và các client ACP khác.
//!
//! ## Các phương thức được hỗ trợ:
//!   - `initialize`        — Bắt tay, đàm phán protocolVersion và capabilities
//!   - `session/new`        — Tạo phiên làm việc mới, thiết lập cwd, cấp phát sessionId
//!   - `session/load`       — Nạp lại phiên làm việc đã lưu từ trước
//!   - `session/prompt`     — Xử lý turn prompt của người dùng, stream `session/update`
//!   - `session/cancel`     — Huỷ lượt xử lý hiện tại
//!   - `session/close`      — Đóng và lưu phiên làm việc
//!   - `ping`               — Kiểm tra kết nối liveness
//!
//! ## Thông báo streaming (`session/update`):
//!   - `agent_message_chunk` — Stream các đoạn text phản hồi của AI
//!   - `agent_thought_chunk` — Stream các đoạn suy nghĩ (thinking/reasoning)
//!   - `tool_call`           — Báo hiệu khi AI bắt đầu gọi tool
//!   - `tool_call_update`    — Báo cáo kết quả/trạng thái hoàn thành của tool

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const proto = @import("../core/protocol.zig");
const agent_mod = @import("../core/agent.zig");
const config_mod = @import("../core/config.zig");
const history_mod = @import("../core/history.zig");
const hooks_mod = @import("../core/hooks.zig");
const json_mod = @import("../core/json.zig");
const utils = @import("../core/utils.zig");
const artifacts_mod = @import("../core/artifacts.zig");
const main = @import("../main.zig");

pub const ACP_PROTOCOL_VERSION: i64 = 1;
pub const AGENT_NAME = "mini-agent";
pub const AGENT_VERSION = "1.0.0";

// ---------------------------------------------------------------------------
// JSON-RPC Types
// ---------------------------------------------------------------------------

pub const JsonId = union(enum) {
    integer: i64,
    string: []const u8,
    null_id,

    pub fn formatJson(self: JsonId, alloc: Allocator) ![]u8 {
        return switch (self) {
            .integer => |n| std.fmt.allocPrint(alloc, "{d}", .{n}),
            .string => |s| blk: {
                const esc = try json_mod.escape(alloc, s);
                defer alloc.free(esc);
                break :blk try std.fmt.allocPrint(alloc, "\"{s}\"", .{esc});
            },
            .null_id => alloc.dupe(u8, "null"),
        };
    }
};

pub const JsonRpcMessage = struct {
    jsonrpc: []const u8,
    id: ?JsonId,
    method: ?[]const u8,
    params_json: ?[]const u8,
};

// ---------------------------------------------------------------------------
// Global active server instance for streaming callbacks & hook listeners
// ---------------------------------------------------------------------------

var g_active_server: ?*AcpServer = null;

fn acpTextCallback(text: []const u8) void {
    if (g_active_server) |srv| {
        srv.sendAgentMessageChunk(text) catch {};
    }
}

fn acpThinkCallback(text: []const u8) void {
    if (g_active_server) |srv| {
        srv.sendAgentThoughtChunk(text) catch {};
    }
}

fn acpHookListener(payload: hooks_mod.HookPayload) void {
    if (g_active_server) |srv| {
        if (std.mem.eql(u8, payload.event, "pre-tool-use")) {
            srv.sendToolCall(payload.tool_id orelse "tool_call", payload.tool_name orelse "unknown", payload.input_json orelse "{}") catch {};
        } else if (std.mem.eql(u8, payload.event, "post-tool-use")) {
            srv.sendToolCallUpdate(payload.tool_id orelse "tool_call", payload.tool_result orelse "", payload.is_error) catch {};
        }
    }
}

// ---------------------------------------------------------------------------
// ACP Server
// ---------------------------------------------------------------------------

pub const AcpServer = struct {
    alloc: Allocator,
    io: std.Io,
    agent: *agent_mod.AgentLoop,
    config: *const config_mod.Config,
    current_session_id: ?[]u8 = null,
    is_cancelled: bool = false,
    session_counter: usize = 0,

    pub fn init(alloc: Allocator, io: std.Io, agent: *agent_mod.AgentLoop, config: *const config_mod.Config) AcpServer {
        return .{
            .alloc = alloc,
            .io = io,
            .agent = agent,
            .config = config,
            .current_session_id = null,
            .is_cancelled = false,
            .session_counter = 0,
        };
    }

    pub fn deinit(self: *AcpServer) void {
        if (self.current_session_id) |sid| {
            self.alloc.free(sid);
            self.current_session_id = null;
        }
    }

    /// Chạy server vòng lặp đọc JSON-RPC từ stdin và phản hồi trên stdout.
    pub fn run(self: *AcpServer) !void {
        main.stderrPrint("[acp] Khởi động ACP server (stdin/stdout JSON-RPC 2.0)...\n", .{});
        hooks_mod.setHookListener(acpHookListener);
        defer hooks_mod.setHookListener(null);

        const stdin_file = std.Io.File.stdin();

        while (true) {
            // Xử lý client đóng stdin (EOF) như kết thúc bình thường thay vì propagate error
            const line_opt = readLineAlloc(self.alloc, self.io, stdin_file) catch |e| switch (@as(anyerror, e)) {
                error.EndOfStream, error.BrokenPipe => null,
                else => return e,
            };
            const line = line_opt orelse break;
            defer self.alloc.free(line);

            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;

            self.handleMessage(trimmed) catch |e| {
                main.stderrPrint("[acp] Lỗi xử lý message: {s}\n", .{@errorName(e)});
            };
        }

        main.stderrPrint("[acp] Đã dừng ACP server (stdin EOF).\n", .{});
    }

    // -----------------------------------------------------------------------
    // Message Dispatcher
    // -----------------------------------------------------------------------

    fn handleMessage(self: *AcpServer, raw_json: []const u8) !void {
        const msg = parseJsonRpcMessage(self.alloc, raw_json) catch |e| {
            main.stderrPrint("[acp] JSON-RPC parse error: {s}\n", .{@errorName(e)});
            try self.sendErrorRaw("null", -32700, "Parse error: Invalid JSON");
            return;
        };
        defer {
            if (msg.id) |id| {
                switch (id) {
                    .string => |s| self.alloc.free(s),
                    else => {},
                }
            }
            if (msg.method) |m| self.alloc.free(m);
            if (msg.params_json) |p| self.alloc.free(p);
        }

        const method = msg.method orelse {
            // Notification response hoặc message không hợp lệ
            return;
        };

        if (std.mem.eql(u8, method, "initialize")) {
            try self.handleInitialize(msg.id);
        } else if (std.mem.eql(u8, method, "notifications/initialized") or std.mem.eql(u8, method, "initialized")) {
            main.stderrPrint("[acp] Client initialized acknowledgement nhận được.\n", .{});
        } else if (std.mem.eql(u8, method, "session/new")) {
            try self.handleSessionNew(msg.id, msg.params_json);
        } else if (std.mem.eql(u8, method, "session/load")) {
            try self.handleSessionLoad(msg.id, msg.params_json);
        } else if (std.mem.eql(u8, method, "session/prompt")) {
            try self.handleSessionPrompt(msg.id, msg.params_json);
        } else if (std.mem.eql(u8, method, "session/cancel")) {
            try self.handleSessionCancel(msg.id, msg.params_json);
        } else if (std.mem.eql(u8, method, "session/close")) {
            try self.handleSessionClose(msg.id, msg.params_json);
        } else if (std.mem.eql(u8, method, "ping")) {
            try self.sendResult(msg.id, "{}");
        } else {
            main.stderrPrint("[acp] Method không xác định: {s}\n", .{method});
            if (msg.id) |id| {
                try self.sendError(id, -32601, "Method not found");
            }
        }
    }

    // -----------------------------------------------------------------------
    // Method Handlers
    // -----------------------------------------------------------------------

    fn handleInitialize(self: *AcpServer, id_opt: ?JsonId) !void {
        const result_json =
            \\{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"mcp":true},"agentInfo":{"name":"mini-agent","version":"1.0.0"}}
        ;
        try self.sendResult(id_opt, result_json);
    }

    fn handleSessionNew(self: *AcpServer, id_opt: ?JsonId, params_json: ?[]const u8) !void {
        var req_session_id: ?[]const u8 = null;
        // Tùy chọn cwd và mcpServers từ params
        if (params_json) |p| {
            if (json_mod.findString(p, "cwd")) |cwd_path| {
                main.stderrPrint("[acp] Session new cwd: {s}\n", .{cwd_path});
            }
            req_session_id = json_mod.findString(p, "sessionId");
        }

        const new_id = if (req_session_id) |sid|
            try self.alloc.dupe(u8, sid)
        else blk: {
            self.session_counter += 1;
            var ts: std.os.linux.timespec = undefined;
            _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
            break :blk try std.fmt.allocPrint(self.alloc, "sess_{d}_{d}", .{ ts.sec, self.session_counter });
        };
        if (self.current_session_id) |old| self.alloc.free(old);
        self.current_session_id = new_id;

        // Reset agent history cho session mới
        self.agent.clearHistory();
        artifacts_mod.setSessionId(new_id);

        const esc_id = try json_mod.escape(self.alloc, new_id);
        defer self.alloc.free(esc_id);

        const result_json = try std.fmt.allocPrint(self.alloc, "{{\"sessionId\":\"{s}\"}}", .{esc_id});
        defer self.alloc.free(result_json);

        try self.sendResult(id_opt, result_json);
    }

    fn handleSessionLoad(self: *AcpServer, id_opt: ?JsonId, params_json: ?[]const u8) !void {
        const params = params_json orelse {
            try self.sendError(id_opt, -32602, "Missing params");
            return;
        };

        const session_id = json_mod.findString(params, "sessionId") orelse {
            try self.sendError(id_opt, -32602, "Missing sessionId in params");
            return;
        };

        if (self.current_session_id) |old| self.alloc.free(old);
        self.current_session_id = try self.alloc.dupe(u8, session_id);
        artifacts_mod.setSessionId(session_id);

        // Khôi phục session từ file nếu có
        const session_file_path = try self.resolveSessionFilePath(session_id);
        defer self.alloc.free(session_file_path);

        const cwd = std.Io.Dir.cwd();
        if (cwd.openFile(self.io, session_file_path, .{})) |f| {
            f.close(self.io);
            self.agent.history.restoreFromFile(self.io, session_file_path) catch |e| {
                main.stderrPrint("[acp] Cảnh báo: Lỗi restore session file '{s}': {s}\n", .{ session_file_path, @errorName(e) });
            };
        } else |_| {}

        try self.sendResult(id_opt, "{}");
    }

    fn handleSessionPrompt(self: *AcpServer, id_opt: ?JsonId, params_json: ?[]const u8) !void {
        const params = params_json orelse {
            try self.sendError(id_opt, -32602, "Missing params");
            return;
        };

        const prompt_text = try extractPromptText(self.alloc, params);
        defer self.alloc.free(prompt_text);

        if (prompt_text.len == 0) {
            try self.sendResult(id_opt, "{\"stopReason\":\"end_turn\"}");
            return;
        }

        // Mở rộng tham chiếu @artifact nếu có
        const expanded_prompt = try artifacts_mod.expandArtifactReferences(self.alloc, self.io, prompt_text);
        defer self.alloc.free(expanded_prompt);

        // Kích hoạt active server cho callbacks
        g_active_server = self;
        self.is_cancelled = false;
        defer {
            g_active_server = null;
        }

        // Chạy agent loop
        var stop_reason: []const u8 = "end_turn";
        self.agent.processInput(expanded_prompt, acpTextCallback, acpThinkCallback) catch |e| {
            main.stderrPrint("[acp] Agent error during prompt: {s}\n", .{@errorName(e)});
            stop_reason = "error";
        };

        if (self.is_cancelled) {
            stop_reason = "cancelled";
        }

        // Tự động sao lưu session history
        if (self.current_session_id) |sid| {
            const session_file_path = try self.resolveSessionFilePath(sid);
            defer self.alloc.free(session_file_path);
            self.agent.history.backupToFile(self.io, session_file_path) catch {};
        }

        const result_json = try std.fmt.allocPrint(self.alloc, "{{\"stopReason\":\"{s}\"}}", .{stop_reason});
        defer self.alloc.free(result_json);

        try self.sendResult(id_opt, result_json);
    }

    fn handleSessionCancel(self: *AcpServer, id_opt: ?JsonId, params_json: ?[]const u8) !void {
        _ = params_json;
        self.is_cancelled = true;
        main.stderrPrint("[acp] Đã nhận tín hiệu session/cancel.\n", .{});
        if (id_opt) |id| {
            try self.sendResult(id, "{}");
        }
    }

    fn handleSessionClose(self: *AcpServer, id_opt: ?JsonId, params_json: ?[]const u8) !void {
        _ = params_json;
        if (self.current_session_id) |sid| {
            const session_file_path = try self.resolveSessionFilePath(sid);
            defer self.alloc.free(session_file_path);
            self.agent.history.backupToFile(self.io, session_file_path) catch {};
        }
        self.agent.clearHistory();
        try self.sendResult(id_opt, "{}");
    }

    // -----------------------------------------------------------------------
    // Streaming Notifications
    // -----------------------------------------------------------------------

    pub fn sendAgentMessageChunk(self: *AcpServer, text: []const u8) !void {
        if (text.len == 0) return;
        const sid = self.current_session_id orelse "default";

        const esc_sid = try json_mod.escape(self.alloc, sid);
        defer self.alloc.free(esc_sid);

        const esc_text = try json_mod.escape(self.alloc, text);
        defer self.alloc.free(esc_text);

        var msg = utils.BufWriter.init(self.alloc);
        defer msg.deinit();

        try msg.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"");
        try msg.writeAll(esc_sid);
        try msg.writeAll("\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"");
        try msg.writeAll(esc_text);
        try msg.writeAll("\"}}}}");

        try self.writeStdoutLine(msg.list.items);
    }

    pub fn sendAgentThoughtChunk(self: *AcpServer, text: []const u8) !void {
        if (text.len == 0) return;
        const sid = self.current_session_id orelse "default";

        const esc_sid = try json_mod.escape(self.alloc, sid);
        defer self.alloc.free(esc_sid);

        const esc_text = try json_mod.escape(self.alloc, text);
        defer self.alloc.free(esc_text);

        var msg = utils.BufWriter.init(self.alloc);
        defer msg.deinit();

        try msg.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"");
        try msg.writeAll(esc_sid);
        try msg.writeAll("\",\"update\":{\"sessionUpdate\":\"agent_thought_chunk\",\"content\":{\"type\":\"text\",\"text\":\"");
        try msg.writeAll(esc_text);
        try msg.writeAll("\"}}}}");

        try self.writeStdoutLine(msg.list.items);
    }

    pub fn sendToolCall(self: *AcpServer, tool_id: []const u8, tool_name: []const u8, input_json: []const u8) !void {
        const sid = self.current_session_id orelse "default";

        const esc_sid = try json_mod.escape(self.alloc, sid);
        defer self.alloc.free(esc_sid);

        const esc_id = try json_mod.escape(self.alloc, tool_id);
        defer self.alloc.free(esc_id);

        const esc_title = try json_mod.escape(self.alloc, tool_name);
        defer self.alloc.free(esc_title);

        const safe_input = if (input_json.len > 0 and input_json[0] == '{') input_json else "{}";

        var msg = utils.BufWriter.init(self.alloc);
        defer msg.deinit();

        try msg.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"");
        try msg.writeAll(esc_sid);
        try msg.writeAll("\",\"update\":{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"");
        try msg.writeAll(esc_id);
        try msg.writeAll("\",\"title\":\"");
        try msg.writeAll(esc_title);
        try msg.writeAll("\",\"status\":\"in_progress\",\"rawInput\":");
        try msg.writeAll(safe_input);
        try msg.writeAll("}}}");

        try self.writeStdoutLine(msg.list.items);
    }

    pub fn sendToolCallUpdate(self: *AcpServer, tool_id: []const u8, output: []const u8, is_error: bool) !void {
        const sid = self.current_session_id orelse "default";

        const esc_sid = try json_mod.escape(self.alloc, sid);
        defer self.alloc.free(esc_sid);

        const esc_id = try json_mod.escape(self.alloc, tool_id);
        defer self.alloc.free(esc_id);

        const esc_output = try json_mod.escape(self.alloc, output);
        defer self.alloc.free(esc_output);

        const status_str: []const u8 = if (is_error) "failed" else "completed";

        var msg = utils.BufWriter.init(self.alloc);
        defer msg.deinit();

        try msg.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"");
        try msg.writeAll(esc_sid);
        try msg.writeAll("\",\"update\":{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"");
        try msg.writeAll(esc_id);
        try msg.writeAll("\",\"status\":\"");
        try msg.writeAll(status_str);
        try msg.writeAll("\",\"output\":\"");
        try msg.writeAll(esc_output);
        try msg.writeAll("\"}}}");

        try self.writeStdoutLine(msg.list.items);
    }

    // -----------------------------------------------------------------------
    // JSON-RPC Response Writers
    // -----------------------------------------------------------------------

    fn sendResult(self: *AcpServer, id_opt: ?JsonId, result_json: []const u8) !void {
        const id = id_opt orelse return; // Notifications do not receive responses
        const id_str = try id.formatJson(self.alloc);
        defer self.alloc.free(id_str);

        var msg = utils.BufWriter.init(self.alloc);
        defer msg.deinit();

        try msg.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try msg.writeAll(id_str);
        try msg.writeAll(",\"result\":");
        try msg.writeAll(result_json);
        try msg.writeAll("}");

        try self.writeStdoutLine(msg.list.items);
    }

    fn sendError(self: *AcpServer, id_opt: ?JsonId, code: i32, message: []const u8) !void {
        const id = id_opt orelse return;
        const id_str = try id.formatJson(self.alloc);
        defer self.alloc.free(id_str);

        try self.sendErrorRaw(id_str, code, message);
    }

    fn sendErrorRaw(self: *AcpServer, id_str: []const u8, code: i32, message: []const u8) !void {
        const esc_msg = try json_mod.escape(self.alloc, message);
        defer self.alloc.free(esc_msg);

        var msg = utils.BufWriter.init(self.alloc);
        defer msg.deinit();

        try msg.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":\"", .{ id_str, code });
        try msg.writeAll(esc_msg);
        try msg.writeAll("\"}}");

        try self.writeStdoutLine(msg.list.items);
    }

    fn writeStdoutLine(self: *AcpServer, bytes: []const u8) !void {
        const stdout_file = std.Io.File.stdout();
        try stdout_file.writeStreamingAll(self.io, bytes);
        try stdout_file.writeStreamingAll(self.io, "\n");
    }

    fn resolveSessionFilePath(self: *AcpServer, session_id: []const u8) ![]u8 {
        const dir_path = if (getEnvVar("MINI_HOME")) |mh| blk: {
            if (mh.len > 0) break :blk try std.fmt.allocPrint(self.alloc, "{s}/sessions", .{mh});
            const home = getEnvVar("HOME") orelse ".";
            break :blk try std.fmt.allocPrint(self.alloc, "{s}/.mini/sessions", .{home});
        } else blk: {
            const home = getEnvVar("HOME") orelse ".";
            break :blk try std.fmt.allocPrint(self.alloc, "{s}/.mini/sessions", .{home});
        };
        defer self.alloc.free(dir_path);

        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(self.io, dir_path) catch {};

        return try std.fmt.allocPrint(self.alloc, "{s}/{s}.json", .{ dir_path, session_id });
    }
};

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

fn getEnvVar(name: [*:0]const u8) ?[]const u8 {
    if (getenv(name)) |ptr| {
        return std.mem.sliceTo(ptr, 0);
    }
    return null;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Đọc một dòng hoàn chỉnh (cấp phát động) từ File. Trả về null nếu EOF.
pub fn readLineAlloc(alloc: Allocator, io: std.Io, file: std.Io.File) !?[]u8 {
    var list = ArrayList(u8).empty;
    errdefer list.deinit(alloc);

    var byte_buf: [1]u8 = undefined;
    while (true) {
        const n = file.readStreaming(io, &.{&byte_buf}) catch |e| {
            if (list.items.len > 0) break;
            return e;
        };
        if (n == 0) {
            if (list.items.len == 0) return null;
            break;
        }
        const b = byte_buf[0];
        if (b == '\n') break;
        if (b != '\r') {
            try list.append(alloc, b);
        }
    }
    return try list.toOwnedSlice(alloc);
}

/// Phân tích cú pháp cơ bản JSON-RPC 2.0 message.
pub fn parseJsonRpcMessage(alloc: Allocator, json_text: []const u8) !JsonRpcMessage {
    const jsonrpc = json_mod.findString(json_text, "jsonrpc") orelse "2.0";

    var parsed_id: ?JsonId = null;
    if (json_mod.findString(json_text, "id")) |s_id| {
        parsed_id = .{ .string = try alloc.dupe(u8, s_id) };
    } else if (findInteger(json_text, "id")) |int_id| {
        parsed_id = .{ .integer = int_id };
    }

    var parsed_method: ?[]const u8 = null;
    if (json_mod.findString(json_text, "method")) |m| {
        parsed_method = try alloc.dupe(u8, m);
    }

    var parsed_params: ?[]const u8 = null;
    if (json_mod.findObject(json_text, "params")) |p_obj| {
        parsed_params = try alloc.dupe(u8, p_obj);
    } else if (json_mod.findArray(json_text, "params")) |p_arr| {
        parsed_params = try alloc.dupe(u8, p_arr);
    }

    return .{
        .jsonrpc = jsonrpc,
        .id = parsed_id,
        .method = parsed_method,
        .params_json = parsed_params,
    };
}

/// Tìm giá trị integer theo key trong JSON.
pub fn findInteger(json_text: []const u8, key: []const u8) ?i64 {
    var pattern_buf: [256]u8 = undefined;
    if (key.len + 4 > pattern_buf.len) return null;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\":", .{key}) catch return null;

    const kpos = std.mem.indexOf(u8, json_text, pattern) orelse return null;
    var i = kpos + pattern.len;

    // Skip whitespace
    while (i < json_text.len and (json_text[i] == ' ' or json_text[i] == '\t' or json_text[i] == '\n')) : (i += 1) {}
    if (i >= json_text.len) return null;

    const start = i;
    if (json_text[i] == '-') i += 1;
    while (i < json_text.len and json_text[i] >= '0' and json_text[i] <= '9') : (i += 1) {}

    if (i == start or (i == start + 1 and json_text[start] == '-')) return null;
    return std.fmt.parseInt(i64, json_text[start..i], 10) catch null;
}

/// Trích xuất text từ prompt trong params (hỗ trợ prompt array, content array, hoặc plain string).
pub fn extractPromptText(alloc: Allocator, params_json: []const u8) ![]u8 {
    // 1. Kiểm tra array params.prompt hoặc params.content trước
    const arr_json = json_mod.findArray(params_json, "prompt") orelse
        json_mod.findArray(params_json, "content") orelse null;

    if (arr_json) |arr| {
        var result = utils.BufWriter.init(alloc);
        defer result.deinit();

        var i: usize = 0;
        while (i < arr.len) : (i += 1) {
            if (arr[i] != '{') continue;
            const obj_start = i;
            var depth: i32 = 0;
            while (i < arr.len) : (i += 1) {
                switch (arr[i]) {
                    '"' => {
                        i += 1;
                        while (i < arr.len) : (i += 1) {
                            if (arr[i] == '\\') { i += 1; continue; }
                            if (arr[i] == '"') break;
                        }
                    },
                    '{' => depth += 1,
                    '}' => {
                        depth -= 1;
                        if (depth == 0) break;
                    },
                    else => {},
                }
            }
            if (i < arr.len) {
                const item_json = arr[obj_start .. i + 1];
                if (json_mod.findString(item_json, "text")) |txt| {
                    if (result.list.items.len > 0) {
                        try result.writeAll("\n");
                    }
                    try result.writeAll(txt);
                }
            }
        }

        if (result.list.items.len > 0) {
            return try alloc.dupe(u8, result.list.items);
        }
    }

    // 2. Kiểm tra nếu có params.prompt string trực tiếp
    if (json_mod.findString(params_json, "prompt")) |pr| {
        return try alloc.dupe(u8, pr);
    }

    // 3. Kiểm tra nếu có params.message string trực tiếp
    if (json_mod.findString(params_json, "message")) |msg| {
        return try alloc.dupe(u8, msg);
    }

    // 4. Kiểm tra nếu có params.text string trực tiếp
    if (json_mod.findString(params_json, "text")) |txt| {
        return try alloc.dupe(u8, txt);
    }

    return try alloc.dupe(u8, "");
}

/// Khởi chạy ACP server
pub fn runServer(alloc: Allocator, io: std.Io, agent: *agent_mod.AgentLoop, config: *const config_mod.Config) !void {
    var server = AcpServer.init(alloc, io, agent, config);
    defer server.deinit();
    try server.run();
}

// ---------------------------------------------------------------------------
// Unit Tests
// ---------------------------------------------------------------------------

test "ACP JSON-RPC message parser" {
    const alloc = std.testing.allocator;

    // Test with integer ID
    const raw1 = "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"initialize\",\"params\":{\"protocolVersion\":1}}";
    const msg1 = try parseJsonRpcMessage(alloc, raw1);
    defer {
        if (msg1.method) |m| alloc.free(m);
        if (msg1.params_json) |p| alloc.free(p);
    }
    try std.testing.expectEqualStrings("2.0", msg1.jsonrpc);
    try std.testing.expect(msg1.id != null);
    try std.testing.expectEqual(@as(i64, 42), msg1.id.?.integer);
    try std.testing.expectEqualStrings("initialize", msg1.method.?);

    // Test with string ID
    const raw2 = "{\"jsonrpc\":\"2.0\",\"id\":\"req_abc\",\"method\":\"session/new\",\"params\":{\"cwd\":\"/home/user\"}}";
    const msg2 = try parseJsonRpcMessage(alloc, raw2);
    defer {
        if (msg2.id) |id| alloc.free(id.string);
        if (msg2.method) |m| alloc.free(m);
        if (msg2.params_json) |p| alloc.free(p);
    }
    try std.testing.expectEqualStrings("req_abc", msg2.id.?.string);
    try std.testing.expectEqualStrings("session/new", msg2.method.?);

    // Test notification without ID
    const raw3 = "{\"jsonrpc\":\"2.0\",\"method\":\"session/cancel\",\"params\":{\"sessionId\":\"s1\"}}";
    const msg3 = try parseJsonRpcMessage(alloc, raw3);
    defer {
        if (msg3.method) |m| alloc.free(m);
        if (msg3.params_json) |p| alloc.free(p);
    }
    try std.testing.expect(msg3.id == null);
    try std.testing.expectEqualStrings("session/cancel", msg3.method.?);
}

test "ACP extractPromptText variants" {
    const alloc = std.testing.allocator;

    // Plain message string
    const p1 = "{\"sessionId\":\"s1\",\"message\":\"Xin chao\"}";
    const res1 = try extractPromptText(alloc, p1);
    defer alloc.free(res1);
    try std.testing.expectEqualStrings("Xin chao", res1);

    // Prompt content blocks array
    const p2 = "{\"sessionId\":\"s1\",\"prompt\":[{\"type\":\"text\",\"text\":\"First line\"},{\"type\":\"text\",\"text\":\"Second line\"}]}";
    const res2 = try extractPromptText(alloc, p2);
    defer alloc.free(res2);
    try std.testing.expectEqualStrings("First line\nSecond line", res2);
}
