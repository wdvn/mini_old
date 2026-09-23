//! mcp.zig — Model Context Protocol (MCP) client.
//!
//! Connects to external MCP servers via stdio JSON-RPC 2.0.
//! Each server is spawned as a child process communicating over
//! stdin/stdout following the MCP protocol specification.
//!
//! ## Configuration
//! File `~/.mini/mcp.json` (or `$MINI_MCP_CONFIG`):
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
//! Tool names carry a server prefix: `filesystem__read_file`, `database__query`.
//!
//! ## MCP Protocol (JSON-RPC 2.0 over stdio)
//! 1. Spawn process
//! 2. Send `initialize` request
//! 3. Receive response
//! 4. Send `notifications/initialized`
//! 5. Send `tools/list` → receive tool list
//! 6. Send `tools/call` when AI executes tool

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const Child = std.process.Child;
const proto = @import("../core/protocol.zig");
const json = @import("../core/json.zig");
const utils = @import("../core/utils.zig");
const main = @import("../main.zig");
const hooks = @import("../core/hooks.zig");
const signals = @import("../core/signals.zig");
const builtin = @import("builtin");

// ---------------------------------------------------------------------------
// I/O helper
// ---------------------------------------------------------------------------

/// Read a line byte-by-byte from File, stripping '\r'. Returns null on EOF.
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

/// A tool discovered from an external MCP server.
pub const RemoteTool = struct {
    /// Server name (used as prefix).
    server_name: []const u8,
    /// Original tool name (without prefix).
    tool_name: []const u8,
    /// Prefixed name: `"server__tool"`.
    prefixed_name: []const u8,
    /// Short description.
    description: []const u8,
    /// JSON Schema of input parameters.
    input_schema_json: []const u8,
};

// ---------------------------------------------------------------------------
// MCP Server
// ---------------------------------------------------------------------------

/// A connected MCP server communicating via child process stdio.
pub const McpServer = struct {
    alloc: Allocator,
    /// Server name (from config).
    name: []const u8,
    child: Child,
    child_pid: std.process.Child.Id = 0,
    stdin_file: std.Io.File,
    stdout_file: std.Io.File,
    /// List of discovered tools.
    tools: ArrayList(RemoteTool),
    next_id: i64 = 1,
    /// Argv slice (owned) to be freed upon shutdown.
    argv_owned: []const []const u8 = &.{},
    /// Stream buffer for line reader.
    recv_buf: ArrayList(u8) = .empty,

    /// Read 1 line from stdout_file (regardless of length), buffering 8KB chunks.
    /// Returns slice owned by caller (must free via self.alloc) or error.McpEof on EOF.
    fn readLine(self: *McpServer) ![]u8 {
        var loop_count: usize = 0;
        while (true) {
            if (signals.isInterrupted()) return error.Interrupted;
            loop_count += 1;
            if (loop_count % 50 == 0) {
                std.Io.sleep(main.g_io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
            }
            if (std.mem.indexOfScalar(u8, self.recv_buf.items, '\n')) |idx| {
                const raw_line = self.recv_buf.items[0..idx];
                var end = idx;
                if (end > 0 and raw_line[end - 1] == '\r') {
                    end -= 1;
                }
                const result = try self.alloc.dupe(u8, raw_line[0..end]);
                const remaining = self.recv_buf.items[idx + 1 ..];
                std.mem.copyForwards(u8, self.recv_buf.items[0..remaining.len], remaining);
                self.recv_buf.items.len = remaining.len;
                return result;
            }

            var chunk: [8192]u8 = undefined;
            const n = self.stdout_file.readStreaming(main.g_io, &.{&chunk}) catch |e| {
                if (self.recv_buf.items.len > 0) {
                    const result = try self.alloc.dupe(u8, self.recv_buf.items);
                    self.recv_buf.clearRetainingCapacity();
                    return result;
                }
                return e;
            };
            if (n == 0) {
                if (self.recv_buf.items.len > 0) {
                    const result = try self.alloc.dupe(u8, self.recv_buf.items);
                    self.recv_buf.clearRetainingCapacity();
                    return result;
                }
                return error.McpEof;
            }
            try self.recv_buf.appendSlice(self.alloc, chunk[0..n]);
        }
    }

    fn dispatchError(self: *McpServer, method: []const u8, err: anyerror) void {
        // PSEUDOCODE: Dispatch OnError hook event for this MCP method.
        hooks.dispatch(self.alloc, main.g_io, .{
            .event = "OnError",
            .mcp_server = self.name,
            .mcp_method = method,
            .error_message = @errorName(err),
        });
    }

    fn writeRequest(self: *McpServer, req: []const u8, method: []const u8) !void {
        // PSEUDOCODE: Write request JSON and newline delimiter to server stdin.
        self.stdin_file.writeStreamingAll(main.g_io, req) catch |e| {
            self.dispatchError(method, e);
            return e;
        };
        self.stdin_file.writeStreamingAll(main.g_io, "\n") catch |e| {
            self.dispatchError(method, e);
            return e;
        };
    }

    /// Send JSON-RPC request and synchronously read response.
    /// Returns JSON response string (owned).
    fn call(self: *McpServer, method: []const u8, params_json: ?[]const u8) ![]u8 {
        // PSEUDOCODE:
        // 1. Dispatch OnRequest hook event.
        // 2. Format JSON-RPC 2.0 request payload and write to stdin.
        // 3. Read response line and return trimmed slice.
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

        try self.writeRequest(req, method);

        const line = self.readLine() catch |e| {
            self.dispatchError(method, e);
            return e;
        };
        defer self.alloc.free(line);
        return try self.alloc.dupe(u8, std.mem.trim(u8, line, " \t\r"));
    }

    /// Send notification (without awaiting response).
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

    /// Perform MCP handshake: initialize → initialized notification.
    pub fn handshake(self: *McpServer) !void {
        const params =
            \\{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"mini-agent","version":"1.0.0"}}
        ;
        const resp = try self.call("initialize", params);
        defer self.alloc.free(resp);

        main.stderrPrint("[mcp] {s}: handshake OK\n", .{self.name});
        try self.notify("notifications/initialized");
    }

    fn findNextJsonObject(text: []const u8, start_idx: usize) ?struct { obj: []const u8, next_idx: usize } {
        // PSEUDOCODE: Scan string starting at start_idx for balanced { ... } object boundaries.
        var i = start_idx;
        while (i < text.len and text[i] != '{') : (i += 1) {}
        if (i >= text.len) return null;

        const obj_start = i;
        var depth: i32 = 0;
        while (i < text.len) : (i += 1) {
            switch (text[i]) {
                '"' => {
                    i += 1;
                    while (i < text.len) : (i += 1) {
                        if (text[i] == '\\') {
                            i += 1;
                            continue;
                        }
                        if (text[i] == '"') break;
                    }
                },
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if (depth == 0) {
                        return .{ .obj = text[obj_start .. i + 1], .next_idx = i + 1 };
                    }
                },
                else => {},
            }
        }
        return null;
    }

    fn registerDiscoveredTool(self: *McpServer, tool_json: []const u8) !void {
        // PSEUDOCODE: Extract tool name, description, schema, and append to server tools list.
        const name = json.findString(tool_json, "name") orelse return;
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

    /// Discover tools from server via tools/list.
    pub fn discoverTools(self: *McpServer) !void {
        // PSEUDOCODE:
        // 1. Call tools/list on MCP server.
        // 2. Parse result.tools JSON array.
        // 3. Extract and register each tool object.
        const resp = try self.call("tools/list", "{}");
        defer self.alloc.free(resp);

        const result_obj = json.findObject(resp, "result") orelse return;
        const tools_arr = json.findArray(result_obj, "tools") orelse return;

        var idx: usize = 1; // skip [
        while (findNextJsonObject(tools_arr, idx)) |match| {
            try self.registerDiscoveredTool(match.obj);
            idx = match.next_idx;
        }

        main.stderrPrint("[mcp] {s}: {d} tools discovered\n", .{ self.name, self.tools.items.len });
    }

    /// Call tool by raw name (without prefix). Returns owned result.
    pub fn callTool(self: *McpServer, tool_name: []const u8, arguments_json: []const u8) ![]u8 {
        const esc_tool = try json.escape(self.alloc, tool_name);
        defer self.alloc.free(esc_tool);

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

        // Extract text from result.content[0].text
        if (json.findObject(resp, "result")) |result_obj| {
            if (json.findString(result_obj, "text")) |text| {
                return self.alloc.dupe(u8, text);
            }
            return self.alloc.dupe(u8, result_obj);
        }
        return self.alloc.dupe(u8, "MCP: No result");
    }

    /// Shut down server and release resources.
    pub fn shutdown(self: *McpServer) void {
        if (self.child_pid > 0) {
            if (comptime builtin.os.tag != .windows) {
                _ = std.posix.kill(-self.child_pid, std.posix.SIG.TERM) catch {
                    _ = std.posix.kill(self.child_pid, std.posix.SIG.TERM) catch {};
                };
                const deadline = utils.milliTimestamp() + 500;
                while (utils.milliTimestamp() < deadline) {
                    if (self.child.wait(main.g_io) catch null) |_| break;
                    
                }
            }
        }
        for (self.tools.items) |t| {
            self.alloc.free(t.tool_name);
            self.alloc.free(t.prefixed_name);
            self.alloc.free(t.description);
            self.alloc.free(t.input_schema_json);
        }
        self.tools.deinit(self.alloc);

        // Close pipes then null-out handle on child
        self.stdin_file.close(main.g_io);
        self.stdout_file.close(main.g_io);
        self.child.stdin = null;
        self.child.stdout = null;
        _ = self.child.wait(main.g_io) catch {};

        // Free argv items, recv_buf, and server name.
        self.recv_buf.deinit(self.alloc);
        for (self.argv_owned) |arg| self.alloc.free(arg);
        if (self.argv_owned.len > 0) self.alloc.free(self.argv_owned);
        self.alloc.free(self.name);
    }
};

// ---------------------------------------------------------------------------
// MCP Client Manager
// ---------------------------------------------------------------------------

/// Manages multiple MCP servers, providing unified interface for tool dispatch.
pub const McpClientManager = struct {
    alloc: Allocator,
    /// List of connected servers.
    servers: ArrayList(McpServer),

    /// Initialize empty manager.
    pub fn init(alloc: Allocator) McpClientManager {
        return .{
            .alloc = alloc,
            .servers = ArrayList(McpServer).empty,
        };
    }

    /// Load and connect all servers from configuration file.
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
                main.stderrPrint("[mcp] Error reading {s}: {s}\n", .{ config_path, @errorName(e) });
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
        // PSEUDOCODE:
        // 1. Locate servers JSON object
        // 2. Scan each key (server name) and value (server config object)
        // 3. Extract command and spawn server
        const servers_obj = json.findObject(config_json, "servers") orelse return;

        var i: usize = 1; // skip {
        while (i < servers_obj.len) {
            if (servers_obj[i] != '"') {
                i += 1;
                continue;
            }

            const name_start = i + 1;
            const name_end = std.mem.indexOfScalarPos(u8, servers_obj, name_start, '"') orelse break;
            const server_name = servers_obj[name_start..name_end];
            i = name_end + 1;

            const match = McpServer.findNextJsonObject(servers_obj, i) orelse break;
            const server_cfg = match.obj;
            i = match.next_idx;

            const command = json.findString(server_cfg, "command") orelse continue;
            self.spawnServer(server_name, command, server_cfg) catch |e| {
                main.stderrPrint("[mcp] Error spawning {s}: {s}\n", .{ server_name, @errorName(e) });
            };
        }
    }

    fn parseArgvList(alloc: Allocator, command: []const u8, config_json: []const u8) ![]const []const u8 {
        var argv = ArrayList([]const u8).empty;
        errdefer {
            for (argv.items) |arg| alloc.free(arg);
            argv.deinit(alloc);
        }
        try argv.append(alloc, try alloc.dupe(u8, command));

        if (json.findArray(config_json, "args")) |args_arr| {
            var j: usize = 1;
            while (j < args_arr.len) {
                if (args_arr[j] == '"') {
                    const arg_start = j + 1;
                    j += 1;
                    while (j < args_arr.len) : (j += 1) {
                        if (args_arr[j] == '\\') {
                            j += 1;
                            continue;
                        }
                        if (args_arr[j] == '"') break;
                    }
                    try argv.append(alloc, try alloc.dupe(u8, args_arr[arg_start..j]));
                    j += 1;
                } else j += 1;
            }
        }
        return try argv.toOwnedSlice(alloc);
    }

    fn spawnServer(self: *McpClientManager, name: []const u8, command: []const u8, config_json: []const u8) !void {
        // PSEUDOCODE:
        // 1. Build argv from command and args array
        // 2. Spawn child process with piped stdin/stdout
        // 3. Complete handshake and discover tools
        const argv_slice = try parseArgvList(self.alloc, command, config_json);

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
            .child_pid = if (child.id) |pid| pid else 0,
            .stdin_file = child.stdin.?,
            .stdout_file = child.stdout.?,
            .tools = .empty,
            .argv_owned = argv_slice,
        };

        server.handshake() catch |e| {
            main.stderrPrint("[mcp] {s}: handshake failed ({s}), skipping.\n", .{ name, @errorName(e) });
            server.shutdown();
            return;
        };
        server.discoverTools() catch {};

        try self.servers.append(self.alloc, server);
    }

    /// Find and invoke tool by prefixed name. Returns null if not found.
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

    /// Get list of all remote tools as ToolDefinition to send to API.
    /// Result must be freed by caller.
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

    /// Total count of available MCP tools.
    pub fn toolCount(self: *const McpClientManager) usize {
        var n: usize = 0;
        for (self.servers.items) |s| n += s.tools.items.len;
        return n;
    }

    /// Terminate all servers and free memory.
    pub fn deinit(self: *McpClientManager) void {
        for (self.servers.items) |*s| s.shutdown();
        self.servers.deinit(self.alloc);
    }
};
