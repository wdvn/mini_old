//! mcp.zig — Model Context Protocol (MCP) client.
//!
//! Kết nối với các MCP server bên ngoài qua stdio JSON-RPC 2.0.
//! Mỗi server được spawn như một child process, giao tiếp qua
//! stdin/stdout theo giao thức MCP.
//!
//! ## Cấu hình
//! File `~/.mini/mcp.json` (hoặc `$MINI_MCP_CONFIG`):
//! ```json
//! {
//!   "servers": {
//!     "filesystem": {
//!       "command": "npx",
//!       "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home/user"]
//!     },
//!     "database": {
//!       "command": "python3",
//!       "args": ["-m", "mcp_server_sqlite", "mydb.sqlite"]
//!     }
//!   }
//! }
//! ```
//!
//! ## Tool naming
//! Tên tool có prefix server: `filesystem__read_file`, `database__query`.
//!
//! ## Giao thức MCP (JSON-RPC 2.0 over stdio)
//! 1. Spawn process
//! 2. Gửi `initialize` request
//! 3. Nhận response
//! 4. Gửi `notifications/initialized`
//! 5. Gửi `tools/list` → nhận danh sách tool
//! 6. Gửi `tools/call` khi AI muốn dùng tool

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const Child = std.process.Child;
const proto = @import("../core/protocol.zig");
const json = @import("../core/json.zig");
const utils = @import("../core/utils.zig");
const main = @import("../main.zig");
const hooks = @import("../core/hooks.zig");

// ---------------------------------------------------------------------------
// I/O helper
// ---------------------------------------------------------------------------

/// Đọc một dòng byte-by-byte từ File, bỏ '\r'. Trả về null nếu EOF.
fn readLineFrom(file: std.Io.File, buf: []u8) ?[]u8 {
    var i: usize = 0;
    while (i < buf.len) {
        var byte: [1]u8 = undefined;
        const n = file.readStreaming(main.g_io, &.{&byte}) catch return null;
        if (n == 0) {
            if (i == 0) return null;
            return buf[0..i];
        }
        if (byte[0] == '\n') return buf[0..i];
        if (byte[0] != '\r') {
            buf[i] = byte[0];
            i += 1;
        }
    }
    return buf[0..i];
}

// ---------------------------------------------------------------------------
// Remote tool
// ---------------------------------------------------------------------------

/// Một tool được discover từ MCP server bên ngoài.
pub const RemoteTool = struct {
    /// Tên server (dùng làm prefix).
    server_name: []const u8,
    /// Tên gốc của tool (không có prefix).
    tool_name: []const u8,
    /// Tên có prefix: `"server__tool"`.
    prefixed_name: []const u8,
    /// Mô tả ngắn.
    description: []const u8,
    /// JSON Schema của input.
    input_schema_json: []const u8,
};

// ---------------------------------------------------------------------------
// MCP Server
// ---------------------------------------------------------------------------

/// Một MCP server đang kết kết nối, giao tiếp qua child process stdio.
pub const McpServer = struct {
    alloc: Allocator,
    /// Tên server (từ config).
    name: []const u8,
    child: Child,
    stdin_file: std.Io.File,
    stdout_file: std.Io.File,
    /// Danh sách tool discover được.
    tools: ArrayList(RemoteTool),
    next_id: i64 = 1,
    /// Argv slice (owned) cần free khi shutdown.
    argv_owned: []const []const u8 = &.{},
    /// Buffer đọc response line.
    line_buf: [65536]u8 = undefined,

    /// Gửi JSON-RPC request và đọc response đồng bộ.
    /// Trả về JSON response string (owned).
    fn call(self: *McpServer, method: []const u8, params_json: ?[]const u8) ![]u8 {
        hooks.dispatch(self.alloc, main.g_io, .{
            .event = "OnRequest",
            .mcp_server = self.name,
            .mcp_method = method,
            .input_json = params_json,
        });

        const id = self.next_id;
        self.next_id += 1;

        const req = if (params_json) |p|
            try std.fmt.allocPrint(self.alloc,
                \\{{"jsonrpc":"2.0","id":{d},"method":"{s}","params":{s}}}
            , .{ id, method, p })
        else
            try std.fmt.allocPrint(self.alloc,
                \\{{"jsonrpc":"2.0","id":{d},"method":"{s}"}}
            , .{ id, method });
        defer self.alloc.free(req);

        self.stdin_file.writeStreamingAll(main.g_io, req) catch |e| {
            hooks.dispatch(self.alloc, main.g_io, .{
                .event = "OnError",
                .mcp_server = self.name,
                .mcp_method = method,
                .error_message = @errorName(e),
            });
            return e;
        };
        self.stdin_file.writeStreamingAll(main.g_io, "\n") catch |e| {
            hooks.dispatch(self.alloc, main.g_io, .{
                .event = "OnError",
                .mcp_server = self.name,
                .mcp_method = method,
                .error_message = @errorName(e),
            });
            return e;
        };

        const line = readLineFrom(self.stdout_file, &self.line_buf) orelse {
            hooks.dispatch(self.alloc, main.g_io, .{
                .event = "OnError",
                .mcp_server = self.name,
                .mcp_method = method,
                .error_message = "McpEof",
            });
            return error.McpEof;
        };
        return try self.alloc.dupe(u8, std.mem.trim(u8, line, " \t\r"));
    }

    /// Gửi notification (không chờ response).
    fn notify(self: *McpServer, method: []const u8) !void {
        hooks.dispatch(self.alloc, main.g_io, .{
            .event = "OnNotification",
            .mcp_server = self.name,
            .mcp_method = method,
        });

        const msg = try std.fmt.allocPrint(self.alloc,
            \\{{"jsonrpc":"2.0","method":"{s}"}}
        , .{method});
        defer self.alloc.free(msg);
        try self.stdin_file.writeStreamingAll(main.g_io, msg);
        try self.stdin_file.writeStreamingAll(main.g_io, "\n");
    }

    /// Thực hiện MCP handshake: initialize → initialized notification.
    pub fn handshake(self: *McpServer) !void {
        const params =
            \\{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"mini-agent","version":"1.0.0"}}
        ;
        const resp = try self.call("initialize", params);
        defer self.alloc.free(resp);

        main.stderrPrint("[mcp] {s}: handshake OK\n", .{self.name});
        try self.notify("notifications/initialized");
    }

    /// Discover tools từ server bằng tools/list.
    pub fn discoverTools(self: *McpServer) !void {
        const resp = try self.call("tools/list", "{}");
        defer self.alloc.free(resp);

        // Parse tools array từ result.tools
        const result_obj = json.findObject(resp, "result") orelse return;
        const tools_arr = json.findArray(result_obj, "tools") orelse return;

        var i: usize = 1; // skip [
        while (i < tools_arr.len) {
            if (tools_arr[i] != '{') { i += 1; continue; }

            // Tìm object end
            var depth: i32 = 0;
            const obj_start = i;
            while (i < tools_arr.len) : (i += 1) {
                switch (tools_arr[i]) {
                    '"' => {
                        i += 1;
                        while (i < tools_arr.len) : (i += 1) {
                            if (tools_arr[i] == '\\') { i += 1; continue; }
                            if (tools_arr[i] == '"') break;
                        }
                    },
                    '{' => depth += 1,
                    '}' => {
                        depth -= 1;
                        if (depth == 0) { i += 1; break; }
                    },
                    else => {},
                }
            }
            const tool_json = tools_arr[obj_start..i];

            const name = json.findString(tool_json, "name") orelse continue;
            const desc = json.findString(tool_json, "description") orelse "";
            const schema = json.findObject(tool_json, "inputSchema") orelse "{}";

            const prefixed = try std.fmt.allocPrint(self.alloc, "{s}__{s}", .{ self.name, name });
            try self.tools.append(self.alloc, .{
                .server_name = self.name,
                .tool_name = try self.alloc.dupe(u8, name),
                .prefixed_name = prefixed,
                .description = try self.alloc.dupe(u8, desc),
                .input_schema_json = try self.alloc.dupe(u8, schema),
            });
        }

        main.stderrPrint("[mcp] {s}: {d} tools discovered\n", .{ self.name, self.tools.items.len });
    }

    /// Gọi tool theo tên gốc (không prefix). Trả về kết quả (owned).
    ///
    /// LƯU Ý: `arguments_json` là chuỗi JSON object đã được unescape ở lớp
    /// findStringOwned (có thể chứa newline/quote thật từ nội dung tool, VD
    /// `{"prompt":"Dòng 1\nDòng 2"}`). Nhét thẳng vào JSON-RPC sẽ làm vỡ wire
    /// format. Ta parse thành `std.json.Value` rồi stringify lại để chuẩn
    /// hoá escape, giữ `arguments` là một object (đúng MCP spec).
    pub fn callTool(self: *McpServer, tool_name: []const u8, arguments_json: []const u8) ![]u8 {
        const esc_tool = try json.escape(self.alloc, tool_name);
        defer self.alloc.free(esc_tool);

        // Ưu tiên: parse JSON rồi stringify lại (chuẩn hoá mọi escape).
        // Nếu parse fail (ví dụ raw newline trong string → invalid JSON),
        // fallback sang reserializeJson (chỉ re-escape control chars trong
        // string values, giữ nguyên JSON structure).
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, arguments_json, .{ .ignore_unknown_fields = true }) catch null;
        var args_buf: ?[]u8 = null;
        if (parsed) |*p| {
            defer p.deinit();
            args_buf = std.json.Stringify.valueAlloc(self.alloc, p.value, .{}) catch null;
        }
        if (args_buf == null) {
            args_buf = json.reserializeJson(self.alloc, arguments_json) catch null;
        }
        defer if (args_buf) |b| self.alloc.free(b);
        const final_args = args_buf orelse arguments_json;

        const params = try std.fmt.allocPrint(self.alloc,
            \\{{"name":"{s}","arguments":{s}}}
        , .{ esc_tool, final_args });
        defer self.alloc.free(params);

        const resp = try self.call("tools/call", params);
        defer self.alloc.free(resp);

        // Trích xuất text từ result.content[0].text
        if (json.findObject(resp, "result")) |result_obj| {
            if (json.findString(result_obj, "text")) |text| {
                return self.alloc.dupe(u8, text);
            }
            return self.alloc.dupe(u8, result_obj);
        }
        return self.alloc.dupe(u8, "MCP: Không có kết quả");
    }

    /// Tắt server và giải phóng tài nguyên.
    pub fn shutdown(self: *McpServer) void {
        for (self.tools.items) |t| {
            self.alloc.free(t.tool_name);
            self.alloc.free(t.prefixed_name);
            self.alloc.free(t.description);
            self.alloc.free(t.input_schema_json);
        }
        self.tools.deinit(self.alloc);

        // Đóng stdin/stdout pipe, sau đó null-out handle trên child
        // để child.wait() → cleanupStreams() không cố close lại (EBADF).
        self.stdin_file.close(main.g_io);
        self.stdout_file.close(main.g_io);
        self.child.stdin = null;
        self.child.stdout = null;
        _ = self.child.wait(main.g_io) catch {};

        // Giải phóng argv items + slice, và server name.
        for (self.argv_owned) |arg| self.alloc.free(arg);
        if (self.argv_owned.len > 0) self.alloc.free(self.argv_owned);
        self.alloc.free(self.name);
    }
};

// ---------------------------------------------------------------------------
// MCP Client Manager
// ---------------------------------------------------------------------------

/// Quản lý nhiều MCP server, cung cấp unified interface cho tool dispatch.
pub const McpClientManager = struct {
    alloc: Allocator,
    /// Danh sách server đang kết nối.
    servers: ArrayList(McpServer),

    /// Khởi tạo manager rỗng.
    pub fn init(alloc: Allocator) McpClientManager {
        return .{
            .alloc = alloc,
            .servers = ArrayList(McpServer).empty,
        };
    }

    /// Load và kết nối tất cả server từ file cấu hình.
    /// Không báo lỗi nếu file không tồn tại (chỉ log).
    pub fn loadFromConfig(self: *McpClientManager, env_map: *const std.process.Environ.Map, io: std.Io, config_path_override: ?[]const u8) void {
        var path_buf: [512]u8 = undefined;
        const config_path = config_path_override orelse blk: {
            if (env_map.get("MINI_HOME")) |mh| {
                if (mh.len > 0) break :blk std.fmt.bufPrint(&path_buf, "{s}/mcp.json", .{mh}) catch return;
            }
            const home = env_map.get("HOME") orelse "/root";
            break :blk std.fmt.bufPrint(&path_buf, "{s}/.mini/mcp.json", .{home}) catch return;
        };

        const cwd = std.Io.Dir.cwd();
        const file = cwd.openFile(io, config_path, .{}) catch |e| {
            if (e != error.FileNotFound) {
                main.stderrPrint("[mcp] Lỗi đọc {s}: {s}\n", .{ config_path, @errorName(e) });
            }
            return;
        };
        defer file.close(io);

        const stat = file.stat(io) catch return;
        if (stat.size > 64 * 1024) return;

        const content = self.alloc.alloc(u8, @intCast(stat.size)) catch return;
        defer self.alloc.free(content);
        const n = utils.readAll(io, file, content) catch return;

        self.parseConfig(content[0..n]);
    }

    fn parseConfig(self: *McpClientManager, config_json: []const u8) void {
        const servers_obj = json.findObject(config_json, "servers") orelse return;

        var i: usize = 1; // skip {
        while (i < servers_obj.len) {
            if (servers_obj[i] != '"') { i += 1; continue; }

            // Server name
            const name_start = i + 1;
            const name_end = std.mem.indexOfScalarPos(u8, servers_obj, name_start, '"') orelse break;
            const server_name = servers_obj[name_start..name_end];
            i = name_end + 1;

            // Skip to {
            while (i < servers_obj.len and servers_obj[i] != '{') : (i += 1) {}
            if (i >= servers_obj.len) break;

            // Find server config object
            var depth: i32 = 0;
            const cfg_start = i;
            while (i < servers_obj.len) : (i += 1) {
                switch (servers_obj[i]) {
                    '"' => {
                        i += 1;
                        while (i < servers_obj.len) : (i += 1) {
                            if (servers_obj[i] == '\\') { i += 1; continue; }
                            if (servers_obj[i] == '"') break;
                        }
                    },
                    '{' => depth += 1,
                    '}' => {
                        depth -= 1;
                        if (depth == 0) { i += 1; break; }
                    },
                    else => {},
                }
            }
            const server_cfg = servers_obj[cfg_start..i];

            const command = json.findString(server_cfg, "command") orelse continue;
            self.spawnServer(server_name, command, server_cfg) catch |e| {
                main.stderrPrint("[mcp] Lỗi spawn {s}: {s}\n", .{ server_name, @errorName(e) });
            };
        }
    }

    fn spawnServer(self: *McpClientManager, name: []const u8, command: []const u8, config_json: []const u8) !void {
        // Build argv
        var argv = ArrayList([]const u8).empty;
        defer argv.deinit(self.alloc);
        try argv.append(self.alloc, try self.alloc.dupe(u8, command));

        if (json.findArray(config_json, "args")) |args_arr| {
            var j: usize = 1;
            while (j < args_arr.len) {
                if (args_arr[j] == '"') {
                    const arg_start = j + 1;
                    j += 1;
                    while (j < args_arr.len) : (j += 1) {
                        if (args_arr[j] == '\\') { j += 1; continue; }
                        if (args_arr[j] == '"') break;
                    }
                    try argv.append(self.alloc, try self.alloc.dupe(u8, args_arr[arg_start..j]));
                    j += 1;
                } else j += 1;
            }
        }

        const argv_slice = try argv.toOwnedSlice(self.alloc);

        const child = try std.process.spawn(main.g_io, .{
            .argv = argv_slice,
            .stdin = .pipe,
            .stdout = .pipe,
        });

        const name_copy = try self.alloc.dupe(u8, name);
        var server = McpServer{
            .alloc = self.alloc,
            .name = name_copy,
            .child = child,
            .stdin_file = child.stdin.?,
            .stdout_file = child.stdout.?,
            .tools = .empty,
            .argv_owned = argv_slice,
        };

        server.handshake() catch |e| {
            main.stderrPrint("[mcp] {s}: handshake thất bại ({s}), bỏ qua.\n", .{ name, @errorName(e) });
            server.shutdown();
            return;
        };
        server.discoverTools() catch {};

        try self.servers.append(self.alloc, server);
    }

    /// Tìm và gọi tool theo prefixed name. Trả về null nếu không tìm thấy.
    pub fn callTool(self: *McpClientManager, prefixed_name: []const u8, arguments_json: []const u8) ?[]u8 {
        for (self.servers.items) |*server| {
            for (server.tools.items) |tool| {
                if (std.mem.eql(u8, tool.prefixed_name, prefixed_name)) {
                    return server.callTool(tool.tool_name, arguments_json) catch null;
                }
            }
        }
        return null;
    }

    /// Lấy danh sách tất cả remote tools dạng ToolDefinition để gửi lên API.
    /// Kết quả cần được free bởi caller.
    pub fn getToolDefinitions(self: *const McpClientManager, alloc: Allocator) []proto.ToolDefinition {
        var total: usize = 0;
        for (self.servers.items) |s| total += s.tools.items.len;
        if (total == 0) return &.{};

        const defs = alloc.alloc(proto.ToolDefinition, total) catch return &.{};
        var idx: usize = 0;
        for (self.servers.items) |s| {
            for (s.tools.items) |t| {
                defs[idx] = .{
                    .name = t.prefixed_name,
                    .description = t.description,
                    .input_schema_json = t.input_schema_json,
                };
                idx += 1;
            }
        }
        return defs;
    }

    /// Tổng số tool MCP đang có.
    pub fn toolCount(self: *const McpClientManager) usize {
        var n: usize = 0;
        for (self.servers.items) |s| n += s.tools.items.len;
        return n;
    }

    /// Tắt tất cả server và giải phóng bộ nhớ.
    pub fn deinit(self: *McpClientManager) void {
        for (self.servers.items) |*s| s.shutdown();
        self.servers.deinit(self.alloc);
    }
};
