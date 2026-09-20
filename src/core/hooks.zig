//! hooks.zig — Comprehensive Lifecycle, Streaming, and MCP Hooks system for mini-agent.
//!
//! Supports 3 groups of hooks:
//! 1. Claude Code CLI Hooks: pre-prompt, post-response, pre-tool-use, post-tool-use
//! 2. API Streaming Events: message_start, content_block_start, content_block_delta,
//!                           content_block_stop, message_delta, message_stop
//! 3. MCP Hooks: OnNotification, OnRequest, OnError

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("json.zig");
const utils = @import("utils.zig");
const main = @import("../main.zig");

/// Global shell command for hook. Null = disabled.
var g_hook_cmd: ?[]const u8 = null;

/// Callback type for in-memory hook listener.
pub const HookListener = *const fn (payload: HookPayload) void;
var g_hook_listener: ?HookListener = null;

/// Set global hook command.
pub fn setHookCommand(cmd: ?[]const u8) void {
    g_hook_cmd = cmd;
}

/// Get current hook command.
pub fn getHookCommand() ?[]const u8 {
    return g_hook_cmd;
}

/// Set in-memory hook listener.
pub fn setHookListener(listener: ?HookListener) void {
    g_hook_listener = listener;
}

/// Get current in-memory hook listener.
pub fn getHookListener() ?HookListener {
    return g_hook_listener;
}

/// Callback type for tool lifecycle listener (RFC-010 Procedural Graph).
pub const ToolListener = *const fn (tool_name: []const u8, input_json: ?[]const u8, is_error: bool) void;
var g_tool_listener: ?ToolListener = null;

/// Set in-memory tool lifecycle listener.
pub fn setToolListener(listener: ?ToolListener) void {
    g_tool_listener = listener;
}

/// Get current in-memory tool lifecycle listener.
pub fn getToolListener() ?ToolListener {
    return g_tool_listener;
}

/// Callback type for execution output chunks (Thread 3 tool/codeact execution -> ActCoordinator).
pub const OutputListener = *const fn (chunk: []const u8) void;
var g_output_listener: ?OutputListener = null;

/// Set in-memory execution output chunk listener.
pub fn setOutputListener(listener: ?OutputListener) void {
    g_output_listener = listener;
}

/// Get current in-memory execution output chunk listener.
pub fn getOutputListener() ?OutputListener {
    return g_output_listener;
}

/// Forward an execution output chunk (stdout/stderr) to the active output listener.
pub fn appendExecutionOutput(chunk: []const u8) void {
    if (g_output_listener) |listener| {
        listener(chunk);
    }
}

/// Struct holding payload data emitted by hook events.
pub const HookPayload = struct {
    event: []const u8,
    tool_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    input_json: ?[]const u8 = null,
    tool_result: ?[]const u8 = null,
    is_error: bool = false,
    user_prompt: ?[]const u8 = null,
    response_text: ?[]const u8 = null,
    stop_reason: ?[]const u8 = null,
    delta_text: ?[]const u8 = null,
    block_type: ?[]const u8 = null,
    role: ?[]const u8 = null,
    model: ?[]const u8 = null,
    mcp_server: ?[]const u8 = null,
    mcp_method: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
    artifact_name: ?[]const u8 = null,
    artifact_path: ?[]const u8 = null,
    artifact_type: ?[]const u8 = null,
    artifact_title: ?[]const u8 = null,
    // Fields for hook events RFC-003 §4.6 (session/memory context)
    ctx_budget: ?u64 = null,
    ctx_used: ?u64 = null,
    session_file: ?[]const u8 = null,
    memory_dir: ?[]const u8 = null,
};

/// Dispatch hook event. Executes without interrupting main command if hook fails.
pub fn dispatch(alloc: Allocator, io: std.Io, payload: HookPayload) void {
    if (g_hook_listener) |listener| {
        listener(payload);
    }
    if (g_tool_listener) |tl| {
        if (std.mem.eql(u8, payload.event, "post-tool-use")) {
            if (payload.tool_name) |tname| {
                tl(tname, payload.input_json, payload.is_error);
            }
        }
    }

    const cmd = g_hook_cmd orelse return;
    if (cmd.len == 0) return;

    const pid = std.os.linux.getpid();
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
    const timestamp = ts.sec;

    // 1. Build JSON payload on stdin
    var json_w = utils.BufWriter.init(alloc);
    defer json_w.deinit();

    json_w.print("{{\"event\":\"{s}\",\"pid\":{d},\"timestamp\":{d}", .{ payload.event, pid, timestamp }) catch return;

    if (payload.tool_name) |v| appendJsonString(alloc, &json_w, "tool_name", v);
    if (payload.input_json) |v| appendJsonString(alloc, &json_w, "input_json", v);
    if (payload.tool_result) |v| appendJsonString(alloc, &json_w, "tool_result", v);
    if (payload.is_error) json_w.writeAll(",\"is_error\":true") catch return;
    if (payload.user_prompt) |v| appendJsonString(alloc, &json_w, "user_prompt", v);
    if (payload.response_text) |v| appendJsonString(alloc, &json_w, "response_text", v);
    if (payload.stop_reason) |v| appendJsonString(alloc, &json_w, "stop_reason", v);
    if (payload.delta_text) |v| appendJsonString(alloc, &json_w, "delta_text", v);
    if (payload.block_type) |v| appendJsonString(alloc, &json_w, "block_type", v);
    if (payload.role) |v| appendJsonString(alloc, &json_w, "role", v);
    if (payload.model) |v| appendJsonString(alloc, &json_w, "model", v);
    if (payload.mcp_server) |v| appendJsonString(alloc, &json_w, "mcp_server", v);
    if (payload.mcp_method) |v| appendJsonString(alloc, &json_w, "mcp_method", v);
    if (payload.error_message) |v| appendJsonString(alloc, &json_w, "error_message", v);
    if (payload.artifact_name) |v| appendJsonString(alloc, &json_w, "artifact_name", v);
    if (payload.artifact_path) |v| appendJsonString(alloc, &json_w, "artifact_path", v);
    if (payload.artifact_type) |v| appendJsonString(alloc, &json_w, "artifact_type", v);
    if (payload.artifact_title) |v| appendJsonString(alloc, &json_w, "artifact_title", v);
    // Serialize context fields RFC-003 §4.6: numbers formatted directly, strings via appendJsonString
    if (payload.ctx_budget) |v| json_w.print(",\"ctx_budget\":{d}", .{v}) catch return;
    if (payload.ctx_used) |v| json_w.print(",\"ctx_used\":{d}", .{v}) catch return;
    if (payload.session_file) |v| appendJsonString(alloc, &json_w, "session_file", v);
    if (payload.memory_dir) |v| appendJsonString(alloc, &json_w, "memory_dir", v);

    json_w.writeAll("}\n") catch return;
    const json_bytes = json_w.list.items;

    // 2. Build shell command with environment variables
    var sh_w = utils.BufWriter.init(alloc);
    defer sh_w.deinit();

    sh_w.print("export MINI_HOOK_EVENT='{s}'; export MINI_PID='{d}'; export MINI_TIMESTAMP='{d}'; ", .{
        payload.event, pid, timestamp,
    }) catch return;

    appendEnvString(alloc, &sh_w, "MINI_TOOL_NAME", payload.tool_name);
    appendEnvString(alloc, &sh_w, "MINI_TOOL_INPUT", payload.input_json);
    appendEnvString(alloc, &sh_w, "MINI_TOOL_RESULT", payload.tool_result);
    appendEnvString(alloc, &sh_w, "MINI_USER_PROMPT", payload.user_prompt);
    appendEnvString(alloc, &sh_w, "MINI_RESPONSE_TEXT", payload.response_text);
    appendEnvString(alloc, &sh_w, "MINI_STOP_REASON", payload.stop_reason);
    appendEnvString(alloc, &sh_w, "MINI_DELTA_TEXT", payload.delta_text);
    appendEnvString(alloc, &sh_w, "MINI_BLOCK_TYPE", payload.block_type);
    appendEnvString(alloc, &sh_w, "MINI_ROLE", payload.role);
    appendEnvString(alloc, &sh_w, "MINI_MODEL", payload.model);
    appendEnvString(alloc, &sh_w, "MINI_MCP_SERVER", payload.mcp_server);
    appendEnvString(alloc, &sh_w, "MINI_MCP_METHOD", payload.mcp_method);
    appendEnvString(alloc, &sh_w, "MINI_ERROR_MESSAGE", payload.error_message);
    appendEnvString(alloc, &sh_w, "MINI_ARTIFACT_NAME", payload.artifact_name);
    appendEnvString(alloc, &sh_w, "MINI_ARTIFACT_PATH", payload.artifact_path);
    appendEnvString(alloc, &sh_w, "MINI_ARTIFACT_TYPE", payload.artifact_type);
    appendEnvString(alloc, &sh_w, "MINI_ARTIFACT_TITLE", payload.artifact_title);
    // Export env for context RFC-003 §4.6: numbers formatted manually via sh_w.print
    if (payload.ctx_budget) |v| sh_w.print("export MINI_CTX_BUDGET='{d}'; ", .{v}) catch return;
    if (payload.ctx_used) |v| sh_w.print("export MINI_CTX_USED='{d}'; ", .{v}) catch return;
    appendEnvString(alloc, &sh_w, "MINI_SESSION_FILE", payload.session_file);
    appendEnvString(alloc, &sh_w, "MINI_MEMORY_DIR", payload.memory_dir);

    sh_w.writeAll(cmd) catch return;
    const sh_cmd = sh_w.list.items;

    const argv = [_][]const u8{ "/bin/sh", "-c", sh_cmd };
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .pipe,
    }) catch |e| {
        main.stderrPrint("[hooks] Warning: unable to spawn hook command: {s}\n", .{@errorName(e)});
        return;
    };

    if (child.stdin) |in_pipe| {
        in_pipe.writeStreamingAll(io, json_bytes) catch {};
        in_pipe.close(io);
        child.stdin = null;
    }

    var err_buf: [1024]u8 = undefined;
    var err_len: usize = 0;
    if (child.stderr) |err_pipe| {
        err_len = utils.drainPipe(io, err_pipe, &err_buf);
    }

    const term = child.wait(io) catch |e| {
        main.stderrPrint("[hooks] Warning: error waiting for hook: {s}\n", .{@errorName(e)});
        return;
    };

    switch (term) {
        .exited => |code| {
            if (code != 0) {
                if (err_len > 0) {
                    main.stderrPrint("[hooks] Warning: hook '{s}' exited with code {d}: {s}\n", .{ payload.event, code, err_buf[0..err_len] });
                } else {
                    main.stderrPrint("[hooks] Warning: hook '{s}' exited with code {d}\n", .{ payload.event, code });
                }
            }
        },
        .signal => |sig| {
            main.stderrPrint("[hooks] Warning: hook process terminated by signal {d}\n", .{@intFromEnum(sig)});
        },
        else => {},
    }
}

fn appendJsonString(alloc: Allocator, writer: *utils.BufWriter, key: []const u8, val: []const u8) void {
    const escaped = json.escape(alloc, val) catch return;
    defer alloc.free(escaped);
    writer.print(",\"{s}\":\"{s}\"", .{ key, escaped }) catch {};
}

fn appendEnvString(alloc: Allocator, writer: *utils.BufWriter, key: []const u8, val: ?[]const u8) void {
    if (val) |v| {
        const escaped = escapeSingleQuotes(alloc, v) catch return;
        defer alloc.free(escaped);
        writer.print("export {s}='{s}'; ", .{ key, escaped }) catch {};
    } else {
        writer.print("export {s}=''; ", .{key}) catch {};
    }
}

fn escapeSingleQuotes(alloc: Allocator, s: []const u8) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(alloc);
    for (s) |c| {
        if (c == '\'') {
            try buf.appendSlice(alloc, "'\\''");
        } else {
            try buf.append(alloc, c);
        }
    }
    return buf.toOwnedSlice(alloc);
}
