//! js_bindings.zig — C-ABI export of all mini tools to the `mini.*` object in CodeAct.
//!
//! Provides the following APIs:
//!   - mini.glob(pattern, basePath?)
//!   - mini.grep(pattern, path?, opts?)
//!   - mini.read(path, offset?, limit?)
//!   - mini.write(path, content)
//!   - mini.patch(path, oldStr, newStr, opts?)
//!   - mini.exists(path)
//!   - mini.stat(path)
//!   - mini.sh(command, opts?)
//!   - mini.shStream(command, opts?)
//!   - mini.shBackground(command, opts?)
//!   - mini.jobStatus(jobId)
//!   - mini.jobLogs(jobId, lines?)
//!   - mini.jobKill(jobId, signal?)
//!   - mini.http(method, url, opts?) → { status, body, truncated, headers }
//!   - mini.artifact(name, content, metadata?)
//!   - mini.env(varName)
//!   - mini.setThinking(levelOrTokens)
//!   - mini.workspaceRoot, mini.sessionId

const std = @import("std");
const Allocator = std.mem.Allocator;
const quickjs = @import("quickjs_engine.zig");
const process_manager = @import("process_manager.zig");
const c = quickjs.c;
const Engine = quickjs.Engine;
const JS_UNDEFINED = quickjs.JS_UNDEFINED;
const JS_NULL = quickjs.JS_NULL;
const JS_EXCEPTION = quickjs.JS_EXCEPTION;

const bash_tool = @import("../tools/bash.zig");
const file_tool = @import("../tools/file.zig");
const glob_tool = @import("../tools/glob.zig");
const grep_tool = @import("../tools/grep.zig");
const http_lib = @import("../lib/http_request.zig");
const artifact_tool = @import("../tools/artifact.zig");
const session_diag = @import("../tools/session_diagnostics.zig");
const media_gen_tool = @import("../tools/media_gen.zig");
const artifacts_mod = @import("../core/artifacts.zig");
const utils = @import("../core/utils.zig");
const json_mod = @import("../core/json.zig");
const main = @import("../main.zig");
const registry = @import("../tooling/registry.zig");
const hooks = @import("../core/hooks.zig");
const snapshot_mod = @import("../core/snapshot.zig");
const agent_loop_monitor = @import("../core/agent_loop_monitor.zig");

// ---------------------------------------------------------------------------
// Security & auditing guard (ISSUE-CODEACT-001 M2/M3/M4)
// All dangerous mini.* bindings must pass through this guard before execution.
// ---------------------------------------------------------------------------

/// Check policy (allowlist/blocklist) (ISSUE-CODEACT-001 M2).
/// Map mini.* name -> tool policy name. True = BLOCKED.
fn guardPolicy(engine: *Engine, tool_name: []const u8) bool {
    _ = engine;
    return !registry.isPermitted(tool_name);
}

fn guardAndDispatchPre(
    engine: *Engine,
    ctx: ?*c.JSContext,
    tool_name: []const u8,
    input: []const u8,
    err_msg: [*c]const u8,
) ?c.JSValue {
    if (guardPolicy(engine, tool_name)) {
        hooks.dispatch(engine.alloc, engine.io, .{
            .event = "post-tool-use",
            .tool_name = tool_name,
            .input_json = input,
            .tool_result = "blocked by policy",
            .is_error = true,
        });
        return c.JS_ThrowTypeError(ctx, err_msg);
    }
    // Same-response dedup guard: skip duplicate tool calls within a single script.
    const args_hash = agent_loop_monitor.fuzzyArgsHash(input);
    if (engine.isSeenCall(tool_name, args_hash)) {
        return c.JS_ThrowTypeError(ctx, err_msg);
    }
    hooks.dispatch(engine.alloc, engine.io, .{
        .event = "pre-tool-use",
        .tool_name = tool_name,
        .input_json = input,
    });
    _ = engine.addSeenCall(engine.alloc, tool_name, args_hash) catch return JS_EXCEPTION;
    return null;
}

fn getEngine(ctx: ?*c.JSContext) ?*Engine {
    const ptr = c.JS_GetContextOpaque(ctx) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn jsStringSlice(ctx: ?*c.JSContext, val: c.JSValue, alloc: Allocator) ?[]u8 {
    const c_str = c.JS_ToCString(ctx, val);
    if (c_str == null) return null;
    defer c.JS_FreeCString(ctx, c_str);
    return alloc.dupe(u8, if (c_str) |p| std.mem.sliceTo(p, 0) else "") catch null;
}

fn buildPatternPathJson(alloc: Allocator, pattern: []const u8, path: ?[]const u8) ![]u8 {
    // PSEUDOCODE:
    // 1. Escape pattern and path
    // 2. Format JSON string {"pattern":"...","path":"..."}
    var json_w = utils.BufWriter.init(alloc);
    defer json_w.deinit();
    const pattern_escaped = try json_mod.escape(alloc, pattern);
    defer alloc.free(pattern_escaped);
    try json_w.print("{{\"pattern\":\"{s}\"", .{pattern_escaped});
    if (path) |p| {
        const p_escaped = try json_mod.escape(alloc, p);
        defer alloc.free(p_escaped);
        try json_w.print(",\"path\":\"{s}\"", .{p_escaped});
    }
    try json_w.writeAll("}");
    return json_w.toOwnedSlice();
}

fn parseGlobLinesToArray(ctx: ?*c.JSContext, res: []const u8) c.JSValue {
    // PSEUDOCODE:
    // 1. Split tool output by newlines
    // 2. Filter out informational lines
    // 3. Populate and return JS Array of strings
    const arr = c.JS_NewArray(ctx);
    var it = std.mem.splitScalar(u8, res, '\n');
    var idx: u32 = 0;
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len > 0 and !std.mem.startsWith(u8, trimmed, "No files") and !std.mem.endsWith(u8, trimmed, "file(s) found.") and !std.mem.startsWith(u8, trimmed, "... (limited to")) {
            const str_val = c.JS_NewStringLen(ctx, trimmed.ptr, trimmed.len);
            _ = c.JS_SetPropertyUint32(ctx, arr, idx, str_val);
            idx += 1;
        }
    }
    return arr;
}

// ---------------------------------------------------------------------------
// mini.glob(pattern, basePath?)
// ---------------------------------------------------------------------------
fn jsMiniGlob(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    // PSEUDOCODE:
    // 1. Validate argument count and parse pattern/base_path
    // 2. Check security policy and dispatch pre/post hooks
    // 3. Build JSON payload, execute glob tool, and parse results into JS array
    _ = this_val;
    const engine = getEngine(ctx) orelse return JS_UNDEFINED;
    engine.renewActivity();
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "mini.glob requires at least 1 argument (pattern)");

    const pattern = jsStringSlice(ctx, argv[0], engine.alloc) orelse return c.JS_ThrowTypeError(ctx, "invalid pattern");
    defer engine.alloc.free(pattern);

    if (guardPolicy(engine, "glob")) {
        hooks.dispatch(engine.alloc, engine.io, .{
            .event = "post-tool-use",
            .tool_name = "glob",
            .input_json = pattern,
            .tool_result = "blocked by policy",
            .is_error = true,
        });
        return c.JS_ThrowTypeError(ctx, "Security Policy Error: mini.glob (glob) is blocked");
    }
    // Same-response dedup guard for read-only tools.
    const glob_hash = agent_loop_monitor.fuzzyArgsHash(pattern);
    if (engine.isSeenCall("glob", glob_hash)) return c.JS_ThrowTypeError(ctx, "Security Policy Error: mini.glob duplicate");
    hooks.dispatch(engine.alloc, engine.io, .{
        .event = "pre-tool-use",
        .tool_name = "glob",
        .input_json = pattern,
    });
    _ = engine.addSeenCall(engine.alloc, "glob", glob_hash) catch return JS_EXCEPTION;

    const base_path = if (argc >= 2 and c.JS_IsUndefined(argv[1]) == 0 and c.JS_IsNull(argv[1]) == 0)
        jsStringSlice(ctx, argv[1], engine.alloc)
    else
        null;
    defer if (base_path) |p| engine.alloc.free(p);

    const input_json = buildPatternPathJson(engine.alloc, pattern, base_path) catch return JS_EXCEPTION;
    defer engine.alloc.free(input_json);

    const res = glob_tool.executeTool(engine.alloc, engine.io, input_json) catch |e| {
        return c.JS_ThrowInternalError(ctx, "glob error: %s", @errorName(e).ptr);
    };
    defer engine.alloc.free(res);

    return parseGlobLinesToArray(ctx, res);
}

fn parseGrepLine(ctx: ?*c.JSContext, line: []const u8) c.JSValue {
    // PSEUDOCODE:
    // 1. Split line by ':' into path, line_num, rest
    // 2. Build JS object with path, line, text
    var parts = std.mem.splitScalar(u8, line, ':');
    const f = parts.next();
    const l_str = parts.next();
    const rest = if (f != null and l_str != null) line[f.?.len + l_str.?.len + 2 ..] else line;

    const obj = c.JS_NewObject(ctx);
    if (f) |file_path| {
        _ = c.JS_SetPropertyStr(ctx, obj, "path", c.JS_NewStringLen(ctx, file_path.ptr, file_path.len));
    }
    if (l_str) |ls| {
        const line_num = std.fmt.parseInt(i32, ls, 10) catch 0;
        _ = c.JS_SetPropertyStr(ctx, obj, "line", c.JS_NewInt32(ctx, line_num));
    }
    _ = c.JS_SetPropertyStr(ctx, obj, "text", c.JS_NewStringLen(ctx, rest.ptr, rest.len));
    return obj;
}

fn parseGrepLinesToArray(ctx: ?*c.JSContext, res: []const u8) c.JSValue {
    // PSEUDOCODE:
    // 1. Split tool output by newlines
    // 2. Parse each line into object and add to array
    const arr = c.JS_NewArray(ctx);
    var it = std.mem.splitScalar(u8, res, '\n');
    var idx: u32 = 0;
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const obj = parseGrepLine(ctx, line);
        _ = c.JS_SetPropertyUint32(ctx, arr, idx, obj);
        idx += 1;
    }
    return arr;
}

// ---------------------------------------------------------------------------
// mini.grep(pattern, path?, options?)
// ---------------------------------------------------------------------------
fn jsMiniGrep(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    // PSEUDOCODE:
    // 1. Validate argument count and parse pattern/path
    // 2. Check security policy and dispatch pre/post hooks
    // 3. Build JSON payload, execute grep tool, and parse results into JS array
    _ = this_val;
    const engine = getEngine(ctx) orelse return JS_UNDEFINED;
    engine.renewActivity();
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "mini.grep requires at least 1 argument (pattern)");

    const pattern = jsStringSlice(ctx, argv[0], engine.alloc) orelse return c.JS_ThrowTypeError(ctx, "invalid pattern");
    defer engine.alloc.free(pattern);

    if (guardPolicy(engine, "grep")) {
        hooks.dispatch(engine.alloc, engine.io, .{
            .event = "post-tool-use",
            .tool_name = "grep",
            .input_json = pattern,
            .tool_result = "blocked by policy",
            .is_error = true,
        });
        return c.JS_ThrowTypeError(ctx, "Security Policy Error: mini.grep (grep) is blocked");
    }
    const grep_hash = agent_loop_monitor.fuzzyArgsHash(pattern);
    if (engine.isSeenCall("grep", grep_hash)) return c.JS_ThrowTypeError(ctx, "Security Policy Error: mini.grep duplicate");
    hooks.dispatch(engine.alloc, engine.io, .{
        .event = "pre-tool-use",
        .tool_name = "grep",
        .input_json = pattern,
    });
    _ = engine.addSeenCall(engine.alloc, "grep", grep_hash) catch return JS_EXCEPTION;

    const path = if (argc >= 2 and c.JS_IsUndefined(argv[1]) == 0 and c.JS_IsNull(argv[1]) == 0)
        jsStringSlice(ctx, argv[1], engine.alloc)
    else
        null;
    defer if (path) |p| engine.alloc.free(p);

    const input_json = buildPatternPathJson(engine.alloc, pattern, path) catch return JS_EXCEPTION;
    defer engine.alloc.free(input_json);

    const res = grep_tool.executeTool(engine.alloc, engine.io, input_json) catch |e| {
        return c.JS_ThrowInternalError(ctx, "grep error: %s", @errorName(e).ptr);
    };
    defer engine.alloc.free(res);

    return parseGrepLinesToArray(ctx, res);
}

// ---------------------------------------------------------------------------
// mini.read(path, offsetLine?, limitLines?)
// ---------------------------------------------------------------------------
fn jsMiniRead(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    const engine = getEngine(ctx) orelse return JS_UNDEFINED;
    engine.renewActivity();
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "mini.read requires path argument");

    const path = jsStringSlice(ctx, argv[0], engine.alloc) orelse return c.JS_ThrowTypeError(ctx, "invalid path");
    defer engine.alloc.free(path);

    // M2: policy check — mini.read maps to 'file_read' tool
    if (guardPolicy(engine, "file_read")) {
        hooks.dispatch(engine.alloc, engine.io, .{
            .event = "post-tool-use",
            .tool_name = "file_read",
            .input_json = path,
            .tool_result = "blocked by policy",
            .is_error = true,
        });
        return c.JS_ThrowTypeError(ctx, "Security Policy Error: mini.read (file_read) is blocked");
    }
    const read_hash = agent_loop_monitor.fuzzyArgsHash(path);
    if (engine.isSeenCall("file_read", read_hash)) return c.JS_ThrowTypeError(ctx, "Security Policy Error: mini.read duplicate");
    hooks.dispatch(engine.alloc, engine.io, .{
        .event = "pre-tool-use",
        .tool_name = "file_read",
        .input_json = path,
    });
    _ = engine.addSeenCall(engine.alloc, "file_read", read_hash) catch return JS_EXCEPTION;

    var offset: usize = 1;
    var limit: usize = 2000;

    if (argc >= 2 and c.JS_IsNumber(argv[1]) != 0) {
        var v: i32 = 1;
        _ = c.JS_ToInt32(ctx, &v, argv[1]);
        if (v > 0) offset = @intCast(v);
    }
    if (argc >= 3 and c.JS_IsNumber(argv[2]) != 0) {
        var v: i32 = 2000;
        _ = c.JS_ToInt32(ctx, &v, argv[2]);
        if (v > 0) limit = @intCast(v);
    }

    const content = file_tool.readFile(engine.alloc, engine.io, path, offset, limit) catch |e| {
        return c.JS_ThrowInternalError(ctx, "read error: %s", @errorName(e).ptr);
    };
    defer engine.alloc.free(content);

    return c.JS_NewStringLen(ctx, content.ptr, content.len);
}

// ---------------------------------------------------------------------------
// mini.write(path, content)
// ---------------------------------------------------------------------------
fn jsMiniWrite(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    const engine = getEngine(ctx) orelse return JS_UNDEFINED;
    engine.renewActivity();
    if (argc < 2) return c.JS_ThrowTypeError(ctx, "mini.write requires path and content arguments");

    const path = jsStringSlice(ctx, argv[0], engine.alloc) orelse return c.JS_ThrowTypeError(ctx, "invalid path");
    defer engine.alloc.free(path);

    const content = jsStringSlice(ctx, argv[1], engine.alloc) orelse return c.JS_ThrowTypeError(ctx, "invalid content");
    defer engine.alloc.free(content);

    if (guardAndDispatchPre(engine, ctx, "file_write", path, "Security Policy Error: mini.write (file_write) is blocked")) |v| return v;
    if (snapshot_mod.getTracker()) |t| t.beforeFileWrite(path);

    const res = file_tool.writeFile(engine.alloc, engine.io, path, content) catch |e| {
        return makeOkResult(ctx, false, @errorName(e));
    };
    defer engine.alloc.free(res);

    if (snapshot_mod.getTracker()) |t| t.afterFileWrite(0, path);
    hooks.dispatch(engine.alloc, engine.io, .{
        .event = "post-tool-use",
        .tool_name = "file_write",
        .input_json = path,
        .tool_result = res,
    });

    return makeOkResult(ctx, true, res);
}

fn makeOkResult(ctx: ?*c.JSContext, ok: bool, msg: []const u8) c.JSValue {
    const obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, obj, "ok", c.JS_NewBool(ctx, if (ok) 1 else 0));
    _ = c.JS_SetPropertyStr(ctx, obj, "message", c.JS_NewStringLen(ctx, msg.ptr, msg.len));
    return obj;
}

// ---------------------------------------------------------------------------
// mini.patch(path, oldStr, newStr, opts?)
// ---------------------------------------------------------------------------
fn jsMiniPatch(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    // PSEUDOCODE:
    // 1. Validate argument count and parse path, oldStr, newStr
    // 2. Check security policy and create CAS snapshot
    // 3. Edit file and return status object
    _ = this_val;
    const engine = getEngine(ctx) orelse return JS_UNDEFINED;
    engine.renewActivity();
    if (argc < 3) return c.JS_ThrowTypeError(ctx, "mini.patch requires path, oldStr, and newStr arguments");

    const path = jsStringSlice(ctx, argv[0], engine.alloc) orelse return c.JS_ThrowTypeError(ctx, "invalid path");
    defer engine.alloc.free(path);

    const old_str = jsStringSlice(ctx, argv[1], engine.alloc) orelse return c.JS_ThrowTypeError(ctx, "invalid oldStr");
    defer engine.alloc.free(old_str);

    const new_str = jsStringSlice(ctx, argv[2], engine.alloc) orelse return c.JS_ThrowTypeError(ctx, "invalid newStr");
    defer engine.alloc.free(new_str);

    if (guardAndDispatchPre(engine, ctx, "file_edit", path, "Security Policy Error: mini.patch (file_edit) is blocked")) |v| return v;
    if (snapshot_mod.getTracker()) |t| t.beforeFileWrite(path);

    const res = file_tool.editFile(engine.alloc, engine.io, path, old_str, new_str) catch |e| {
        return makeOkResult(ctx, false, @errorName(e));
    };
    defer engine.alloc.free(res);

    if (snapshot_mod.getTracker()) |t| t.afterFileWrite(0, path);
    hooks.dispatch(engine.alloc, engine.io, .{
        .event = "post-tool-use",
        .tool_name = "file_edit",
        .input_json = path,
        .tool_result = res,
    });

    const is_ok = std.mem.indexOf(u8, res, "Modified") != null;
    return makeOkResult(ctx, is_ok, res);
}

// ---------------------------------------------------------------------------
// mini.exists(path)
// ---------------------------------------------------------------------------
fn jsMiniExists(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    const engine = getEngine(ctx) orelse return JS_UNDEFINED;
    engine.renewActivity();
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "mini.exists requires path argument");

    const path = jsStringSlice(ctx, argv[0], engine.alloc) orelse return c.JS_ThrowTypeError(ctx, "invalid path");
    defer engine.alloc.free(path);

    const cwd = std.Io.Dir.cwd();
    const exists = if (cwd.statFile(engine.io, path, .{})) |_| true else |_| false;
    return c.JS_NewBool(ctx, if (exists) 1 else 0);
}

// ---------------------------------------------------------------------------
// mini.stat(path)
// ---------------------------------------------------------------------------
fn jsMiniStat(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    const engine = getEngine(ctx) orelse return JS_UNDEFINED;
    engine.renewActivity();
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "mini.stat requires path argument");

    const path = jsStringSlice(ctx, argv[0], engine.alloc) orelse return c.JS_ThrowTypeError(ctx, "invalid path");
    defer engine.alloc.free(path);

    const cwd = std.Io.Dir.cwd();
    const stat_res = cwd.statFile(engine.io, path, .{}) catch |e| {
        return c.JS_ThrowInternalError(ctx, "stat error: %s", @errorName(e).ptr);
    };

    const obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, obj, "size", c.JS_NewInt64(ctx, @intCast(stat_res.size)));
    _ = c.JS_SetPropertyStr(ctx, obj, "isFile", c.JS_NewBool(ctx, if (stat_res.kind == .file) 1 else 0));
    _ = c.JS_SetPropertyStr(ctx, obj, "isDir", c.JS_NewBool(ctx, if (stat_res.kind == .directory) 1 else 0));
    _ = c.JS_SetPropertyStr(ctx, obj, "modified", c.JS_NewInt64(ctx, @as(i64, @truncate(stat_res.mtime.nanoseconds))));
    return obj;
}

fn snapshotWritablePaths(alloc: Allocator, command: []const u8) void {
    // PSEUDOCODE:
    // 1. Extract writable file paths from shell command
    // 2. Snapshot each path before executing command
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    if (snapshot_mod.extractWritablePaths(arena.allocator(), command)) |writable| {
        for (writable) |p| {
            if (snapshot_mod.getTracker()) |t| t.beforeFileWrite(p);
        }
    } else |_| {}
}

fn makeShResult(ctx: ?*c.JSContext, ok: bool, exit_code: i32, stdout: []const u8, stderr: []const u8) c.JSValue {
    // PSEUDOCODE:
    // 1. Allocate JS object
    // 2. Populate exitCode, ok, stdout, stderr
    const obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, obj, "exitCode", c.JS_NewInt32(ctx, exit_code));
    _ = c.JS_SetPropertyStr(ctx, obj, "ok", c.JS_NewBool(ctx, if (ok) 1 else 0));
    _ = c.JS_SetPropertyStr(ctx, obj, "stdout", c.JS_NewStringLen(ctx, stdout.ptr, stdout.len));
    _ = c.JS_SetPropertyStr(ctx, obj, "stderr", c.JS_NewStringLen(ctx, stderr.ptr, stderr.len));
    return obj;
}

fn buildShCommandJson(alloc: Allocator, command: []const u8) ![]u8 {
    // PSEUDOCODE:
    // 1. Escape shell command string
    // 2. Format JSON payload {"command":"..."}
    var json_w = utils.BufWriter.init(alloc);
    defer json_w.deinit();
    const cmd_escaped = try json_mod.escape(alloc, command);
    defer alloc.free(cmd_escaped);
    try json_w.print("{{\"command\":\"{s}\"}}", .{cmd_escaped});
    return json_w.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// mini.sh(command, opts?)
// ---------------------------------------------------------------------------
fn jsMiniSh(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    // PSEUDOCODE:
    // 1. Validate argument count and parse command
    // 2. Check security policy and snapshot target files
    // 3. Execute command via bash tool and return result
    _ = this_val;
    const engine = getEngine(ctx) orelse return JS_UNDEFINED;
    engine.renewActivity();
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "mini.sh requires command argument");

    const command = jsStringSlice(ctx, argv[0], engine.alloc) orelse return c.JS_ThrowTypeError(ctx, "invalid command");
    defer engine.alloc.free(command);

    const input_json = buildShCommandJson(engine.alloc, command) catch return JS_EXCEPTION;
    defer engine.alloc.free(input_json);

    if (guardPolicy(engine, "bash")) {
        hooks.dispatch(engine.alloc, engine.io, .{
            .event = "post-tool-use",
            .tool_name = "bash",
            .input_json = command,
            .tool_result = "blocked by policy",
            .is_error = true,
        });
        return c.JS_ThrowTypeError(ctx, "Security Policy Error: mini.sh (bash) is blocked");
    }
    const bash_hash = agent_loop_monitor.fuzzyArgsHash(command);
    if (engine.isSeenCall("bash", bash_hash)) return c.JS_ThrowTypeError(ctx, "Security Policy Error: mini.sh (bash) duplicate");
    hooks.dispatch(engine.alloc, engine.io, .{
        .event = "pre-tool-use",
        .tool_name = "bash",
        .input_json = command,
    });
    _ = engine.addSeenCall(engine.alloc, "bash", bash_hash) catch return JS_EXCEPTION;

    snapshotWritablePaths(engine.alloc, command);

    const out = bash_tool.executeTool(engine.alloc, engine.io, input_json) catch |e| {
        return makeShResult(ctx, false, 1, "", @errorName(e));
    };
    defer engine.alloc.free(out);

    engine.renewActivity();

    hooks.dispatch(engine.alloc, engine.io, .{
        .event = "post-tool-use",
        .tool_name = "bash",
        .input_json = command,
        .tool_result = out,
    });

    return makeShResult(ctx, true, 0, out, "");
}

// ---------------------------------------------------------------------------
// mini.shStream(command, opts?)
// ---------------------------------------------------------------------------
fn jsMiniShStream(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    const engine = getEngine(ctx) orelse return JS_UNDEFINED;
    engine.renewActivity();
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "mini.shStream requires command argument");

    const command = jsStringSlice(ctx, argv[0], engine.alloc) orelse return c.JS_ThrowTypeError(ctx, "invalid command");
    defer engine.alloc.free(command);

    const argv_cmd = [_][]const u8{ "/bin/sh", "-c", command };
    var child = std.process.spawn(engine.io, .{
        .argv = &argv_cmd,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |e| {
        return c.JS_ThrowInternalError(ctx, "shStream spawn error: %s", @errorName(e).ptr);
    };

    const term = child.wait(engine.io) catch |e| {
        return c.JS_ThrowInternalError(ctx, "shStream wait error: %s", @errorName(e).ptr);
    };

    engine.renewActivity();

    const exit_code: i32 = switch (term) {
        .exited => |code| code,
        .signal => |sig| @intCast(@intFromEnum(sig)),
        else => 1,
    };

    return c.JS_NewInt32(ctx, exit_code);
}

// ---------------------------------------------------------------------------
// mini.shBackground(command, opts?)
// ---------------------------------------------------------------------------
fn jsMiniShBackground(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    const engine = getEngine(ctx) orelse return JS_UNDEFINED;
    engine.renewActivity();
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "mini.shBackground requires command argument");

    const command = jsStringSlice(ctx, argv[0], engine.alloc) orelse return c.JS_ThrowTypeError(ctx, "invalid command");
    defer engine.alloc.free(command);

    const pm = process_manager.getProcessManager(engine.alloc);
    const info = pm.spawnBackground(engine.io, command) catch |e| {
        return c.JS_ThrowInternalError(ctx, "shBackground spawn error: %s", @errorName(e).ptr);
    };

    const obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, obj, "jobId", c.JS_NewStringLen(ctx, info.job_id.ptr, info.job_id.len));
    _ = c.JS_SetPropertyStr(ctx, obj, "pid", c.JS_NewInt32(ctx, info.pid));
    _ = c.JS_SetPropertyStr(ctx, obj, "logPath", c.JS_NewStringLen(ctx, info.log_path.ptr, info.log_path.len));
    return obj;
}

// ---------------------------------------------------------------------------
// mini.jobStatus(jobId)
// ---------------------------------------------------------------------------
fn jsMiniJobStatus(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    const engine = getEngine(ctx) orelse return JS_UNDEFINED;
    engine.renewActivity();
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "mini.jobStatus requires jobId argument");

    const job_id = jsStringSlice(ctx, argv[0], engine.alloc) orelse return c.JS_ThrowTypeError(ctx, "invalid jobId");
    defer engine.alloc.free(job_id);

    const pm = process_manager.getProcessManager(engine.alloc);
    const status = pm.getJobStatus(job_id) orelse return JS_NULL;

    const obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, obj, "running", c.JS_NewBool(ctx, if (status.running) 1 else 0));
    _ = c.JS_SetPropertyStr(ctx, obj, "pid", c.JS_NewInt32(ctx, status.pid));
    if (status.exit_code) |ec| {
        _ = c.JS_SetPropertyStr(ctx, obj, "exitCode", c.JS_NewInt32(ctx, ec));
    }
    return obj;
}

// ---------------------------------------------------------------------------
// mini.jobLogs(jobId, lines?)
// ---------------------------------------------------------------------------
fn jsMiniJobLogs(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    const engine = getEngine(ctx) orelse return JS_UNDEFINED;
    engine.renewActivity();
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "mini.jobLogs requires jobId argument");

    const job_id = jsStringSlice(ctx, argv[0], engine.alloc) orelse return c.JS_ThrowTypeError(ctx, "invalid jobId");
    defer engine.alloc.free(job_id);

    var max_lines: usize = 50;
    if (argc >= 2 and c.JS_IsNumber(argv[1]) != 0) {
        var v: i32 = 50;
        _ = c.JS_ToInt32(ctx, &v, argv[1]);
        if (v > 0) max_lines = @intCast(v);
    }

    const pm = process_manager.getProcessManager(engine.alloc);
    const logs = pm.readJobLogs(engine.io, job_id, max_lines) catch |e| {
        return c.JS_ThrowInternalError(ctx, "jobLogs error: %s", @errorName(e).ptr);
    };
    defer engine.alloc.free(logs);

    return c.JS_NewStringLen(ctx, logs.ptr, logs.len);
}

// ---------------------------------------------------------------------------
// mini.jobKill(jobId, signal?)
// ---------------------------------------------------------------------------
fn jsMiniJobKill(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    const engine = getEngine(ctx) orelse return JS_UNDEFINED;
    engine.renewActivity();
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "mini.jobKill requires jobId argument");

    const job_id = jsStringSlice(ctx, argv[0], engine.alloc) orelse return c.JS_ThrowTypeError(ctx, "invalid jobId");
    defer engine.alloc.free(job_id);

    const sig = if (argc >= 2 and c.JS_IsString(argv[1]) != 0)
        jsStringSlice(ctx, argv[1], engine.alloc)
    else
        null;
    defer if (sig) |s| engine.alloc.free(s);

    const pm = process_manager.getProcessManager(engine.alloc);
    const ok = pm.killJob(job_id, sig);
    return c.JS_NewBool(ctx, if (ok) 1 else 0);
}

// ---------------------------------------------------------------------------
// mini.http(method, url, opts?)
//   opts: { body?: string, headers?: {k:v}, max_body_size?: int, timeout_s?: int }
//   Returns: { status: int, body: string, truncated: bool, headers: {k:v} }
// ---------------------------------------------------------------------------
/// Read string property from JS object. Returns null if property does not exist.
fn jsOptString(ctx: ?*c.JSContext, obj: c.JSValue, key: [*:0]const u8, alloc: Allocator) ?[]u8 {
    const v = c.JS_GetPropertyStr(ctx, obj, key);
    defer c.JS_FreeValue(ctx, v);
    if (c.JS_IsUndefined(v) != 0 or c.JS_IsNull(v) != 0) return null;
    return jsStringSlice(ctx, v, alloc);
}

/// Read int property from JS object. Returns null if property does not exist / error.
fn jsOptInt(ctx: ?*c.JSContext, obj: c.JSValue, key: [*:0]const u8) ?i64 {
    const v = c.JS_GetPropertyStr(ctx, obj, key);
    defer c.JS_FreeValue(ctx, v);
    if (c.JS_IsUndefined(v) != 0 or c.JS_IsNull(v) != 0) return null;
    var out: i64 = 0;
    if (c.JS_ToInt64(ctx, &out, v) != 0) return null;
    return out;
}

/// Stringify JS object (argv) to JSON string for library headers_json.
/// Uses QuickJS JS_JSONStringify — ensures proper escaping of all values.
fn jsObjectToJsonString(ctx: ?*c.JSContext, obj: c.JSValue, alloc: Allocator) ?[]u8 {
    const s = c.JS_JSONStringify(ctx, obj, JS_UNDEFINED, JS_UNDEFINED);
    defer c.JS_FreeValue(ctx, s);
    if (c.JS_IsString(s) == 0) return null;
    return jsStringSlice(ctx, s, alloc);
}

const HttpJsOptions = struct {
    body_opt: ?[]u8 = null,
    headers_json_opt: ?[]u8 = null,
    max_body_size_opt: ?usize = null,
    timeout_s_opt: ?u32 = null,

    fn deinit(self: *HttpJsOptions, alloc: Allocator) void {
        if (self.body_opt) |b| alloc.free(b);
        if (self.headers_json_opt) |h| alloc.free(h);
    }
};

fn parseHttpJsOptions(ctx: ?*c.JSContext, opts_val: c.JSValue, alloc: Allocator) HttpJsOptions {
    var opts = HttpJsOptions{};
    if (c.JS_IsObject(opts_val) == 0) return opts;
    opts.body_opt = jsOptString(ctx, opts_val, "body", alloc);
    const hv = c.JS_GetPropertyStr(ctx, opts_val, "headers");
    defer c.JS_FreeValue(ctx, hv);
    if (c.JS_IsObject(hv) != 0) {
        opts.headers_json_opt = jsObjectToJsonString(ctx, hv, alloc);
    }
    if (jsOptInt(ctx, opts_val, "max_body_size")) |v| {
        if (v > 0) opts.max_body_size_opt = @intCast(v);
    }
    if (jsOptInt(ctx, opts_val, "timeout_s")) |v| {
        if (v > 0) opts.timeout_s_opt = @intCast(v);
    }
    return opts;
}

fn buildHttpHeadersObject(ctx: ?*c.JSContext, headers: []const http_lib.Response.Header) c.JSValue {
    const headers_obj = c.JS_NewObject(ctx);
    for (headers) |h| {
        const name = c.JS_NewStringLen(ctx, h.name.ptr, h.name.len);
        const atom = c.JS_ValueToAtom(ctx, name);
        c.JS_FreeValue(ctx, name);
        const val = c.JS_NewStringLen(ctx, h.value.ptr, h.value.len);
        _ = c.JS_SetProperty(ctx, headers_obj, atom, val);
        c.JS_FreeAtom(ctx, atom);
    }
    return headers_obj;
}

fn makeHttpResult(ctx: ?*c.JSContext, res: *const http_lib.Response) c.JSValue {
    const obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, obj, "status", c.JS_NewInt32(ctx, @intCast(res.status)));
    _ = c.JS_SetPropertyStr(ctx, obj, "body", c.JS_NewStringLen(ctx, res.body.ptr, res.body.len));
    _ = c.JS_SetPropertyStr(ctx, obj, "truncated", c.JS_NewBool(ctx, if (res.truncated) 1 else 0));
    _ = c.JS_SetPropertyStr(ctx, obj, "headers", buildHttpHeadersObject(ctx, res.headers));
    return obj;
}

fn executeHttpFetch(alloc: Allocator, io: std.Io, method: []const u8, url: []const u8, opts: *const HttpJsOptions) !http_lib.Response {
    return http_lib.fetch(alloc, io, .{
        .url = url,
        .method = method,
        .body = opts.body_opt,
        .headers_json = opts.headers_json_opt,
        .max_body_size = opts.max_body_size_opt orelse http_lib.DEFAULT_MAX_BODY_SIZE,
        .timeout_s = opts.timeout_s_opt orelse http_lib.DEFAULT_TIMEOUT_S,
    });
}

fn jsMiniHttp(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    // PSEUDOCODE:
    // 1. Validate argument count and parse method and url
    // 2. Parse optional request options (body, headers, timeout, max size)
    // 3. Check security policy and execute fetch
    // 4. Format and return response object
    _ = this_val;
    const engine = getEngine(ctx) orelse return JS_UNDEFINED;
    engine.renewActivity();
    if (argc < 2) return c.JS_ThrowTypeError(ctx, "mini.http requires method and url arguments");

    const method = jsStringSlice(ctx, argv[0], engine.alloc) orelse return c.JS_ThrowTypeError(ctx, "invalid method");
    defer engine.alloc.free(method);

    const url = jsStringSlice(ctx, argv[1], engine.alloc) orelse return c.JS_ThrowTypeError(ctx, "invalid url");
    defer engine.alloc.free(url);

    var opts = if (argc >= 3) parseHttpJsOptions(ctx, argv[2], engine.alloc) else HttpJsOptions{};
    defer opts.deinit(engine.alloc);

    if (guardAndDispatchPre(engine, ctx, "http_request", url, "Security Policy Error: mini.http (http_request) is blocked")) |v| return v;

    var res = executeHttpFetch(engine.alloc, engine.io, method, url, &opts) catch |e| {
        return c.JS_ThrowInternalError(ctx, "http error: %s", @errorName(e).ptr);
    };
    defer res.deinit(engine.alloc);

    engine.renewActivity();

    hooks.dispatch(engine.alloc, engine.io, .{
        .event = "post-tool-use",
        .tool_name = "http_request",
        .input_json = url,
        .tool_result = res.body,
    });

    return makeHttpResult(ctx, &res);
}

// ---------------------------------------------------------------------------
// mini.artifact(name, content, metadata?)
// ---------------------------------------------------------------------------
fn jsMiniArtifact(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    const engine = getEngine(ctx) orelse return JS_UNDEFINED;
    engine.renewActivity();
    if (argc < 2) return c.JS_ThrowTypeError(ctx, "mini.artifact requires name and content arguments");

    const name = jsStringSlice(ctx, argv[0], engine.alloc) orelse return c.JS_ThrowTypeError(ctx, "invalid name");
    defer engine.alloc.free(name);

    const content = jsStringSlice(ctx, argv[1], engine.alloc) orelse return c.JS_ThrowTypeError(ctx, "invalid content");
    defer engine.alloc.free(content);

    const escaped = json_mod.escape(engine.alloc, content) catch return JS_EXCEPTION;
    defer engine.alloc.free(escaped);

    var json_w = utils.BufWriter.init(engine.alloc);
    defer json_w.deinit();
    const name_escaped = json_mod.escape(engine.alloc, name) catch return JS_EXCEPTION;
    defer engine.alloc.free(name_escaped);
    json_w.print("{{\"name\":\"{s}\",\"content\":\"{s}\"}}", .{ name_escaped, escaped }) catch return JS_EXCEPTION;

    const res = artifact_tool.writeTool(engine.alloc, engine.io, json_w.list.items) catch |e| {
        return c.JS_ThrowInternalError(ctx, "artifact error: %s", @errorName(e).ptr);
    };
    defer engine.alloc.free(res);

    return c.JS_NewStringLen(ctx, res.ptr, res.len);
}

// ---------------------------------------------------------------------------
// mini.env(varName)
// ---------------------------------------------------------------------------
fn jsMiniEnv(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    const engine = getEngine(ctx) orelse return JS_UNDEFINED;
    engine.renewActivity();
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "mini.env requires varName argument");

    const var_name = jsStringSlice(ctx, argv[0], engine.alloc) orelse return c.JS_ThrowTypeError(ctx, "invalid varName");
    defer engine.alloc.free(var_name);

    const var_name_z = engine.alloc.dupeZ(u8, var_name) catch return JS_EXCEPTION;
    defer engine.alloc.free(var_name_z);

    const val = utils.getEnvSlice(var_name_z.ptr);
    if (val) |v| {
        const slice = v;
        return c.JS_NewStringLen(ctx, slice.ptr, slice.len);
    }
    return JS_NULL;
}

// ---------------------------------------------------------------------------
// mini.sessions()
// ---------------------------------------------------------------------------
fn jsMiniSessions(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    _ = argc;
    _ = argv;
    const engine = getEngine(ctx) orelse return JS_UNDEFINED;
    engine.renewActivity();

    const res = session_diag.listSessions(engine.alloc, engine.io) catch |e| {
        return c.JS_ThrowInternalError(ctx, "session error: %s", @errorName(e).ptr);
    };
    defer engine.alloc.free(res);

    return c.JS_NewStringLen(ctx, res.ptr, res.len);
}

// ---------------------------------------------------------------------------
// mini.sessionDetail(pid)
// ---------------------------------------------------------------------------
fn jsMiniSessionDetail(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    const engine = getEngine(ctx) orelse return JS_UNDEFINED;
    engine.renewActivity();
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "mini.sessionDetail requires pid argument");

    var pid: i32 = 0;
    if (c.JS_ToInt32(ctx, &pid, argv[0]) != 0) {
        return c.JS_ThrowTypeError(ctx, "pid must be an integer");
    }

    const res = session_diag.detailSession(engine.alloc, engine.io, pid) catch |e| {
        return c.JS_ThrowInternalError(ctx, "sessionDetail error: %s", @errorName(e).ptr);
    };
    defer engine.alloc.free(res);

    return c.JS_NewStringLen(ctx, res.ptr, res.len);
}

// ---------------------------------------------------------------------------
// mini.sessionKill(pid, signal?)
// ---------------------------------------------------------------------------
fn jsMiniSessionKill(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    const engine = getEngine(ctx) orelse return JS_UNDEFINED;
    engine.renewActivity();
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "mini.sessionKill requires pid argument");

    var pid: i32 = 0;
    if (c.JS_ToInt32(ctx, &pid, argv[0]) != 0) {
        return c.JS_ThrowTypeError(ctx, "pid must be an integer");
    }

    const signal = if (argc >= 2 and c.JS_IsUndefined(argv[1]) == 0 and c.JS_IsNull(argv[1]) == 0)
        jsStringSlice(ctx, argv[1], engine.alloc)
    else
        null;
    defer if (signal) |s| engine.alloc.free(s);

    const res = session_diag.killSession(engine.alloc, pid, signal) catch |e| {
        return c.JS_ThrowInternalError(ctx, "sessionKill error: %s", @errorName(e).ptr);
    };
    defer engine.alloc.free(res);

    return c.JS_NewStringLen(ctx, res.ptr, res.len);
}

// ---------------------------------------------------------------------------
// Dynamic Thinking Budget & Reasoning Effort (mini.setThinking)
// ---------------------------------------------------------------------------

pub const ThinkingOverride = struct {
    effort: ?[]const u8 = null,
    budget_tokens: ?u32 = null,
};

/// Mutex protecting g_pending_thinking.
pub var g_thinking_mutex = std.atomic.Mutex.unlocked;

var g_pending_thinking: ?ThinkingOverride = null;

pub fn consumePendingThinkingOverride() ?ThinkingOverride {
    while (!g_thinking_mutex.tryLock()) {}
    const val = g_pending_thinking;
    g_pending_thinking = null;
    g_thinking_mutex.unlock();
    return val;
}

pub fn setPendingThinkingOverride(override: ?ThinkingOverride) void {
    while (!g_thinking_mutex.tryLock()) {}
    g_pending_thinking = override;
    g_thinking_mutex.unlock();
}

fn setThinkingBudget(budget: i32) void {
    if (budget <= 0) {
        setPendingThinkingOverride(.{ .effort = "none", .budget_tokens = 0 });
        return;
    }
    const b: u32 = @intCast(budget);
    const eff: []const u8 = if (b <= 1024) "low" else if (b <= 4096) "medium" else "high";
    setPendingThinkingOverride(.{ .effort = eff, .budget_tokens = b });
}

fn parseEffortString(str: []const u8) ?ThinkingOverride {
    if (std.mem.eql(u8, str, "low")) return .{ .effort = "low", .budget_tokens = 1024 };
    if (std.mem.eql(u8, str, "medium")) return .{ .effort = "medium", .budget_tokens = 4096 };
    if (std.mem.eql(u8, str, "high")) return .{ .effort = "high", .budget_tokens = 8192 };
    if (std.mem.eql(u8, str, "none") or std.mem.eql(u8, str, "off")) return .{ .effort = "none", .budget_tokens = 0 };
    if (std.mem.eql(u8, str, "minimal")) return .{ .effort = "minimal", .budget_tokens = 512 };
    return null;
}

// ---------------------------------------------------------------------------
// mini.setThinking(levelOrTokens)
// ---------------------------------------------------------------------------
fn jsMiniSetThinking(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    // PSEUDOCODE:
    // 1. Validate argument count and check if number or string
    // 2. If number, convert to token budget and effort level
    // 3. If string, map effort name to budget and set pending thinking
    _ = this_val;
    const engine = getEngine(ctx) orelse return JS_UNDEFINED;
    engine.renewActivity();
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "mini.setThinking requires 1 argument (string level or number budget)");

    if (c.JS_IsNumber(argv[0]) != 0) {
        var budget: i32 = 0;
        if (c.JS_ToInt32(ctx, &budget, argv[0]) == 0) {
            setThinkingBudget(budget);
            return c.JS_NewBool(ctx, 1);
        }
    }

    if (c.JS_IsString(argv[0]) != 0) {
        const str = jsStringSlice(ctx, argv[0], engine.alloc) orelse return c.JS_ThrowTypeError(ctx, "invalid string argument");
        defer engine.alloc.free(str);

        if (parseEffortString(str)) |override| {
            setPendingThinkingOverride(override);
            return c.JS_NewBool(ctx, 1);
        }
        return c.JS_ThrowTypeError(ctx, "level must be 'low', 'medium', 'high', 'none', or a token budget number");
    }

    return c.JS_ThrowTypeError(ctx, "argument must be string or number");
}

const MediaJsOptions = struct {
    size_opt: ?[]u8 = null,
    filename_opt: ?[]u8 = null,
    model_opt: ?[]u8 = null,
    seconds: u32 = 4,

    fn deinit(self: *MediaJsOptions, alloc: Allocator) void {
        if (self.size_opt) |s| alloc.free(s);
        if (self.filename_opt) |f| alloc.free(f);
        if (self.model_opt) |m| alloc.free(m);
    }
};

fn parseMediaJsOptions(ctx: ?*c.JSContext, opts_val: c.JSValue, alloc: Allocator) MediaJsOptions {
    var opts = MediaJsOptions{};
    if (c.JS_IsObject(opts_val) == 0) return opts;
    opts.size_opt = jsOptString(ctx, opts_val, "size", alloc);
    opts.filename_opt = jsOptString(ctx, opts_val, "filename", alloc);
    opts.model_opt = jsOptString(ctx, opts_val, "model", alloc);
    if (jsOptInt(ctx, opts_val, "seconds")) |sec| {
        if (sec > 0) opts.seconds = @intCast(sec);
    }
    return opts;
}

fn executeMediaGeneration(
    engine: *Engine,
    kind: []const u8,
    prompt_or_path: []const u8,
    opts: *const MediaJsOptions,
) !media_gen_tool.MediaResult {
    if (std.mem.eql(u8, kind, "video")) {
        return media_gen_tool.generateVideoDirect(engine.alloc, engine.io, prompt_or_path, opts.seconds, opts.filename_opt, opts.model_opt);
    } else if (std.mem.eql(u8, kind, "attach")) {
        return media_gen_tool.attachImageDirect(engine.alloc, engine.io, prompt_or_path);
    } else {
        return media_gen_tool.generateImageDirect(engine.alloc, engine.io, prompt_or_path, opts.size_opt, opts.filename_opt, opts.model_opt);
    }
}

fn makeMediaResult(ctx: ?*c.JSContext, res: media_gen_tool.MediaResult) c.JSValue {
    const obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, obj, "ok", c.JS_NewBool(ctx, if (res.ok) 1 else 0));
    _ = c.JS_SetPropertyStr(ctx, obj, "path", c.JS_NewStringLen(ctx, res.path.ptr, res.path.len));
    _ = c.JS_SetPropertyStr(ctx, obj, "media_type", c.JS_NewStringLen(ctx, res.media_type.ptr, res.media_type.len));
    _ = c.JS_SetPropertyStr(ctx, obj, "bytes", c.JS_NewInt64(ctx, @intCast(res.bytes)));
    if (res.message.len > 0) {
        _ = c.JS_SetPropertyStr(ctx, obj, "message", c.JS_NewStringLen(ctx, res.message.ptr, res.message.len));
    }
    return obj;
}

fn mediaKindToToolName(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "video")) return "generate_video";
    if (std.mem.eql(u8, kind, "attach")) return "image_attach";
    return "generate_image";
}

// ---------------------------------------------------------------------------
// mini.media(kind, promptOrPath, opts?)
//   kind: "image" | "video" | "attach"
//   opts: { size?: string, filename?: string, model?: string, seconds?: int }
//   Returns: { ok: bool, path: string, media_type: string, bytes: int, message?: string }
// ---------------------------------------------------------------------------
fn jsMiniMedia(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    // PSEUDOCODE:
    // 1. Validate argument count and parse kind and prompt/path
    // 2. Map kind to tool name and enforce security policy
    // 3. Parse options and execute media generation
    // 4. Return result object to JS
    _ = this_val;
    const engine = getEngine(ctx) orelse return JS_UNDEFINED;
    engine.renewActivity();
    if (argc < 2) return c.JS_ThrowTypeError(ctx, "mini.media requires kind ('image'|'video'|'attach') and prompt/path arguments");

    const kind = jsStringSlice(ctx, argv[0], engine.alloc) orelse return c.JS_ThrowTypeError(ctx, "invalid kind");
    defer engine.alloc.free(kind);

    const prompt_or_path = jsStringSlice(ctx, argv[1], engine.alloc) orelse return c.JS_ThrowTypeError(ctx, "invalid prompt or path");
    defer engine.alloc.free(prompt_or_path);

    const tool_name = mediaKindToToolName(kind);
    if (guardAndDispatchPre(engine, ctx, tool_name, prompt_or_path, "Security Policy Error: mini.media is blocked by policy")) |v| return v;

    var opts = if (argc >= 3) parseMediaJsOptions(ctx, argv[2], engine.alloc) else MediaJsOptions{};
    defer opts.deinit(engine.alloc);

    const res = executeMediaGeneration(engine, kind, prompt_or_path, &opts) catch |e| {
        return c.JS_ThrowTypeError(ctx, @errorName(e));
    };
    defer {
        engine.alloc.free(res.path);
        engine.alloc.free(res.media_type);
        if (res.message.len > 0) engine.alloc.free(res.message);
    }

    hooks.dispatch(engine.alloc, engine.io, .{
        .event = "post-tool-use",
        .tool_name = tool_name,
        .input_json = prompt_or_path,
        .tool_result = res.path,
        .is_error = !res.ok,
    });

    return makeMediaResult(ctx, res);
}

/// Register global `mini` object into JSContext
pub fn registerBindings(engine: *Engine) !void {
    const ctx = engine.ctx.?;
    const global_obj = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global_obj);

    const mini_obj = c.JS_NewObject(ctx);

    // 1. fs & search
    _ = c.JS_SetPropertyStr(ctx, mini_obj, "glob", c.JS_NewCFunction(ctx, jsMiniGlob, "glob", 2));
    _ = c.JS_SetPropertyStr(ctx, mini_obj, "grep", c.JS_NewCFunction(ctx, jsMiniGrep, "grep", 3));
    _ = c.JS_SetPropertyStr(ctx, mini_obj, "read", c.JS_NewCFunction(ctx, jsMiniRead, "read", 3));
    _ = c.JS_SetPropertyStr(ctx, mini_obj, "write", c.JS_NewCFunction(ctx, jsMiniWrite, "write", 2));
    _ = c.JS_SetPropertyStr(ctx, mini_obj, "patch", c.JS_NewCFunction(ctx, jsMiniPatch, "patch", 4));
    _ = c.JS_SetPropertyStr(ctx, mini_obj, "exists", c.JS_NewCFunction(ctx, jsMiniExists, "exists", 1));
    _ = c.JS_SetPropertyStr(ctx, mini_obj, "stat", c.JS_NewCFunction(ctx, jsMiniStat, "stat", 1));

    // 2. shell & jobs (OpenHands Pattern)
    _ = c.JS_SetPropertyStr(ctx, mini_obj, "sh", c.JS_NewCFunction(ctx, jsMiniSh, "sh", 2));
    _ = c.JS_SetPropertyStr(ctx, mini_obj, "shStream", c.JS_NewCFunction(ctx, jsMiniShStream, "shStream", 2));
    _ = c.JS_SetPropertyStr(ctx, mini_obj, "shBackground", c.JS_NewCFunction(ctx, jsMiniShBackground, "shBackground", 2));
    _ = c.JS_SetPropertyStr(ctx, mini_obj, "jobStatus", c.JS_NewCFunction(ctx, jsMiniJobStatus, "jobStatus", 1));
    _ = c.JS_SetPropertyStr(ctx, mini_obj, "jobLogs", c.JS_NewCFunction(ctx, jsMiniJobLogs, "jobLogs", 2));
    _ = c.JS_SetPropertyStr(ctx, mini_obj, "jobKill", c.JS_NewCFunction(ctx, jsMiniJobKill, "jobKill", 2));

    // 3. network & session telemetry & agent cognitive modulation
    _ = c.JS_SetPropertyStr(ctx, mini_obj, "http", c.JS_NewCFunction(ctx, jsMiniHttp, "http", 3));
    _ = c.JS_SetPropertyStr(ctx, mini_obj, "artifact", c.JS_NewCFunction(ctx, jsMiniArtifact, "artifact", 3));
    _ = c.JS_SetPropertyStr(ctx, mini_obj, "env", c.JS_NewCFunction(ctx, jsMiniEnv, "env", 1));
    _ = c.JS_SetPropertyStr(ctx, mini_obj, "sessions", c.JS_NewCFunction(ctx, jsMiniSessions, "sessions", 0));
    _ = c.JS_SetPropertyStr(ctx, mini_obj, "sessionDetail", c.JS_NewCFunction(ctx, jsMiniSessionDetail, "sessionDetail", 1));
    _ = c.JS_SetPropertyStr(ctx, mini_obj, "sessionKill", c.JS_NewCFunction(ctx, jsMiniSessionKill, "sessionKill", 2));
    _ = c.JS_SetPropertyStr(ctx, mini_obj, "setThinking", c.JS_NewCFunction(ctx, jsMiniSetThinking, "setThinking", 1));
    _ = c.JS_SetPropertyStr(ctx, mini_obj, "media", c.JS_NewCFunction(ctx, jsMiniMedia, "media", 3));

    // 4. metadata props
    const pwd_val = utils.getEnvSlice("PWD");
    const cwd_str = if (pwd_val) |p| p else ".";
    _ = c.JS_SetPropertyStr(ctx, mini_obj, "workspaceRoot", c.JS_NewStringLen(ctx, cwd_str.ptr, cwd_str.len));

    const session_id = artifacts_mod.getSessionId();
    _ = c.JS_SetPropertyStr(ctx, mini_obj, "sessionId", c.JS_NewStringLen(ctx, session_id.ptr, session_id.len));

    _ = c.JS_SetPropertyStr(ctx, global_obj, "mini", mini_obj);
}
