//! js_bindings.zig — C-ABI Export toàn bộ công cụ của mini sang object `mini.*` trong CodeAct.
//!
//! Cung cấp các API:
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

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

const bash_tool = @import("../tools/bash.zig");
const file_tool = @import("../tools/file.zig");
const glob_tool = @import("../tools/glob.zig");
const grep_tool = @import("../tools/grep.zig");
const http_lib = @import("../lib/http_request.zig");
const artifact_tool = @import("../tools/artifact.zig");
const artifacts_mod = @import("../core/artifacts.zig");
const utils = @import("../core/utils.zig");
const json_mod = @import("../core/json.zig");
const main = @import("../main.zig");
const registry = @import("../tooling/registry.zig");
const hooks = @import("../core/hooks.zig");
const snapshot_mod = @import("../core/snapshot.zig");

// ---------------------------------------------------------------------------
// Security & auditing guard (ISSUE-CODEACT-001 M2/M3/M4)
// Mọi binding mini.* nguy hiểm phải đi qua guard này trước khi thực thi.
// ---------------------------------------------------------------------------

/// Kiểm tra policy (allowlist/blocklist) (ISSUE-CODEACT-001 M2).
/// Map tên mini.* -> tên tool policy. True = BỊ CHẶN.
fn guardPolicy(engine: *Engine, tool_name: []const u8) bool {
    _ = engine;
    return !registry.isPermitted(tool_name);
}

fn getEngine(ctx: ?*c.JSContext) ?*Engine {
    const ptr = c.JS_GetContextOpaque(ctx) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn jsStringSlice(ctx: ?*c.JSContext, val: c.JSValue, alloc: Allocator) ?[]u8 {
    const c_str = c.JS_ToCString(ctx, val);
    if (c_str == null) return null;
    defer c.JS_FreeCString(ctx, c_str);
    return alloc.dupe(u8, std.mem.span(c_str)) catch null;
}

// ---------------------------------------------------------------------------
// mini.glob(pattern, basePath?)
// ---------------------------------------------------------------------------
fn jsMiniGlob(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    const engine = getEngine(ctx) orelse return JS_UNDEFINED;
    engine.renewActivity();
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "mini.glob requires at least 1 argument (pattern)");

    const pattern = jsStringSlice(ctx, argv[0], engine.alloc) orelse return c.JS_ThrowTypeError(ctx, "invalid pattern");
    defer engine.alloc.free(pattern);

    const base_path = if (argc >= 2 and c.JS_IsUndefined(argv[1]) == 0 and c.JS_IsNull(argv[1]) == 0)
        jsStringSlice(ctx, argv[1], engine.alloc)
    else
        null;
    defer if (base_path) |p| engine.alloc.free(p);

    // Build input JSON for glob tool
    var json_w = utils.BufWriter.init(engine.alloc);
    defer json_w.deinit();
    const pattern_escaped = json_mod.escape(engine.alloc, pattern) catch return JS_EXCEPTION;
    defer engine.alloc.free(pattern_escaped);
    json_w.print("{{\"pattern\":\"{s}\"", .{pattern_escaped}) catch return JS_EXCEPTION;
    if (base_path) |p| {
        const p_escaped = json_mod.escape(engine.alloc, p) catch return JS_EXCEPTION;
        defer engine.alloc.free(p_escaped);
        json_w.print(",\"path\":\"{s}\"", .{p_escaped}) catch return JS_EXCEPTION;
    }
    json_w.writeAll("}") catch return JS_EXCEPTION;

    const res = glob_tool.executeTool(engine.alloc, engine.io, json_w.list.items) catch |e| {
        return c.JS_ThrowInternalError(ctx, "glob error: %s", @errorName(e).ptr);
    };
    defer engine.alloc.free(res);

    // Parse lines in res into JS Array of strings
    const arr = c.JS_NewArray(ctx);
    var it = std.mem.splitScalar(u8, res, '\n');
    var idx: u32 = 0;
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len > 0 and !std.mem.startsWith(u8, trimmed, "Tìm thấy 0") and !std.mem.startsWith(u8, trimmed, "Không tìm thấy")) {
            const str_val = c.JS_NewStringLen(ctx, trimmed.ptr, trimmed.len);
            _ = c.JS_SetPropertyUint32(ctx, arr, idx, str_val);
            idx += 1;
        }
    }

    return arr;
}

// ---------------------------------------------------------------------------
// mini.grep(pattern, path?, options?)
// ---------------------------------------------------------------------------
fn jsMiniGrep(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    const engine = getEngine(ctx) orelse return JS_UNDEFINED;
    engine.renewActivity();
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "mini.grep requires at least 1 argument (pattern)");

    const pattern = jsStringSlice(ctx, argv[0], engine.alloc) orelse return c.JS_ThrowTypeError(ctx, "invalid pattern");
    defer engine.alloc.free(pattern);

    const path = if (argc >= 2 and c.JS_IsUndefined(argv[1]) == 0 and c.JS_IsNull(argv[1]) == 0)
        jsStringSlice(ctx, argv[1], engine.alloc)
    else
        null;
    defer if (path) |p| engine.alloc.free(p);

    var json_w = utils.BufWriter.init(engine.alloc);
    defer json_w.deinit();
    const pattern_escaped = json_mod.escape(engine.alloc, pattern) catch return JS_EXCEPTION;
    defer engine.alloc.free(pattern_escaped);
    json_w.print("{{\"pattern\":\"{s}\"", .{pattern_escaped}) catch return JS_EXCEPTION;
    if (path) |p| {
        const p_escaped = json_mod.escape(engine.alloc, p) catch return JS_EXCEPTION;
        defer engine.alloc.free(p_escaped);
        json_w.print(",\"path\":\"{s}\"", .{p_escaped}) catch return JS_EXCEPTION;
    }
    json_w.writeAll("}") catch return JS_EXCEPTION;

    const res = grep_tool.executeTool(engine.alloc, engine.io, json_w.list.items) catch |e| {
        return c.JS_ThrowInternalError(ctx, "grep error: %s", @errorName(e).ptr);
    };
    defer engine.alloc.free(res);

    const arr = c.JS_NewArray(ctx);
    var it = std.mem.splitScalar(u8, res, '\n');
    var idx: u32 = 0;
    while (it.next()) |line| {
        if (line.len == 0) continue;
        // Parse "file:line:content"
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

        _ = c.JS_SetPropertyUint32(ctx, arr, idx, obj);
        idx += 1;
    }

    return arr;
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

    // M2: policy check — mini.write map sang tool 'file_write'
    if (guardPolicy(engine, "file_write")) {
        hooks.dispatch(engine.alloc, engine.io, .{
            .event = "post-tool-use", .tool_name = "file_write",
            .input_json = path, .tool_result = "blocked by policy", .is_error = true,
        });
        return c.JS_ThrowTypeError(ctx, "Security Policy Error: mini.write (file_write) is blocked");
    }
    hooks.dispatch(engine.alloc, engine.io, .{
        .event = "pre-tool-use", .tool_name = "file_write", .input_json = path,
    });

    // M4: snapshot nội dung cũ vào CAS/journal TRƯỚC khi ghi
    if (snapshot_mod.getTracker()) |t| t.beforeFileWrite(path);

    const res = file_tool.writeFile(engine.alloc, engine.io, path, content) catch |e| {
        const obj = c.JS_NewObject(ctx);
        _ = c.JS_SetPropertyStr(ctx, obj, "ok", c.JS_NewBool(ctx, 0));
        const err_name = @errorName(e);
        _ = c.JS_SetPropertyStr(ctx, obj, "message", c.JS_NewStringLen(ctx, err_name.ptr, err_name.len));
        return obj;
    };
    defer engine.alloc.free(res);

    // M4: flush snapshot sau khi ghi
    if (snapshot_mod.getTracker()) |t| t.afterFileWrite(0, path);

    // M3: post-hook
    hooks.dispatch(engine.alloc, engine.io, .{
        .event = "post-tool-use", .tool_name = "file_write",
        .input_json = path, .tool_result = res,
    });

    const obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, obj, "ok", c.JS_NewBool(ctx, 1));
    _ = c.JS_SetPropertyStr(ctx, obj, "message", c.JS_NewStringLen(ctx, res.ptr, res.len));
    return obj;
}

// ---------------------------------------------------------------------------
// mini.patch(path, oldStr, newStr, opts?)
// ---------------------------------------------------------------------------
fn jsMiniPatch(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
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

    // M2: policy check — mini.patch map sang tool 'file_edit'
    if (guardPolicy(engine, "file_edit")) {
        hooks.dispatch(engine.alloc, engine.io, .{
            .event = "post-tool-use", .tool_name = "file_edit",
            .input_json = path, .tool_result = "blocked by policy", .is_error = true,
        });
        return c.JS_ThrowTypeError(ctx, "Security Policy Error: mini.patch (file_edit) is blocked");
    }
    hooks.dispatch(engine.alloc, engine.io, .{
        .event = "pre-tool-use", .tool_name = "file_edit", .input_json = path,
    });

    // M4: snapshot trước khi sửa
    if (snapshot_mod.getTracker()) |t| t.beforeFileWrite(path);

    const res = file_tool.editFile(engine.alloc, engine.io, path, old_str, new_str) catch |e| {
        const obj = c.JS_NewObject(ctx);
        _ = c.JS_SetPropertyStr(ctx, obj, "ok", c.JS_NewBool(ctx, 0));
        const err_name = @errorName(e);
        _ = c.JS_SetPropertyStr(ctx, obj, "message", c.JS_NewStringLen(ctx, err_name.ptr, err_name.len));
        return obj;
    };
    defer engine.alloc.free(res);

    if (snapshot_mod.getTracker()) |t| t.afterFileWrite(0, path);
    hooks.dispatch(engine.alloc, engine.io, .{
        .event = "post-tool-use", .tool_name = "file_edit",
        .input_json = path, .tool_result = res,
    });

    const is_ok = std.mem.indexOf(u8, res, "Đã sửa file") != null;
    const obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, obj, "ok", c.JS_NewBool(ctx, if (is_ok) 1 else 0));
    _ = c.JS_SetPropertyStr(ctx, obj, "message", c.JS_NewStringLen(ctx, res.ptr, res.len));
    return obj;
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

// ---------------------------------------------------------------------------
// mini.sh(command, opts?)
// ---------------------------------------------------------------------------
fn jsMiniSh(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    const engine = getEngine(ctx) orelse return JS_UNDEFINED;
    engine.renewActivity();
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "mini.sh requires command argument");

    const command = jsStringSlice(ctx, argv[0], engine.alloc) orelse return c.JS_ThrowTypeError(ctx, "invalid command");
    defer engine.alloc.free(command);

    // Xây dựng JSON cho bash tool — escape chuỗi command (có thể chứa
    // quote/newline) để round-trip JSON được parse đúng phía tool.
    var json_w = utils.BufWriter.init(engine.alloc);
    defer json_w.deinit();
    const cmd_escaped = json_mod.escape(engine.alloc, command) catch return JS_EXCEPTION;
    defer engine.alloc.free(cmd_escaped);
    json_w.print("{{\"command\":\"{s}\"}}", .{cmd_escaped}) catch return JS_EXCEPTION;

    // M2: policy check — mini.sh map sang tool 'bash'
    if (guardPolicy(engine, "bash")) {
        hooks.dispatch(engine.alloc, engine.io, .{
            .event = "post-tool-use", .tool_name = "bash",
            .input_json = command, .tool_result = "blocked by policy", .is_error = true,
        });
        return c.JS_ThrowTypeError(ctx, "Security Policy Error: mini.sh (bash) is blocked");
    }
    hooks.dispatch(engine.alloc, engine.io, .{
        .event = "pre-tool-use", .tool_name = "bash", .input_json = command,
    });

    // M4: snapshot các path có nguy cơ bị lệnh ghi (sed -i, >, tee, mv, cp, rm...)
    {
        var arena = std.heap.ArenaAllocator.init(engine.alloc);
        defer arena.deinit();
        if (snapshot_mod.extractWritablePaths(arena.allocator(), command)) |writable| {
            for (writable) |p| {
                if (snapshot_mod.getTracker()) |t| t.beforeFileWrite(p);
            }
        } else |_| {}
    }

    const out = bash_tool.executeTool(engine.alloc, engine.io, json_w.list.items) catch |e| {
        const obj = c.JS_NewObject(ctx);
        _ = c.JS_SetPropertyStr(ctx, obj, "exitCode", c.JS_NewInt32(ctx, 1));
        _ = c.JS_SetPropertyStr(ctx, obj, "ok", c.JS_NewBool(ctx, 0));
        const err_name = @errorName(e);
        _ = c.JS_SetPropertyStr(ctx, obj, "stderr", c.JS_NewStringLen(ctx, err_name.ptr, err_name.len));
        _ = c.JS_SetPropertyStr(ctx, obj, "stdout", c.JS_NewStringLen(ctx, "", 0));
        return obj;
    };
    defer engine.alloc.free(out);

    engine.renewActivity();

    hooks.dispatch(engine.alloc, engine.io, .{
        .event = "post-tool-use", .tool_name = "bash",
        .input_json = command, .tool_result = out,
    });

    const obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, obj, "exitCode", c.JS_NewInt32(ctx, 0));
    _ = c.JS_SetPropertyStr(ctx, obj, "ok", c.JS_NewBool(ctx, 1));
    _ = c.JS_SetPropertyStr(ctx, obj, "stdout", c.JS_NewStringLen(ctx, out.ptr, out.len));
    _ = c.JS_SetPropertyStr(ctx, obj, "stderr", c.JS_NewStringLen(ctx, "", 0));
    return obj;
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
//   Trả về: { status: int, body: string, truncated: bool, headers: {k:v} }
// ---------------------------------------------------------------------------
/// Đọc property string từ JS object. Trả null nếu property không tồn tại.
fn jsOptString(ctx: ?*c.JSContext, obj: c.JSValue, key: [*:0]const u8, alloc: Allocator) ?[]u8 {
    const v = c.JS_GetPropertyStr(ctx, obj, key);
    defer c.JS_FreeValue(ctx, v);
    if (c.JS_IsUndefined(v) != 0 or c.JS_IsNull(v) != 0) return null;
    return jsStringSlice(ctx, v, alloc);
}

/// Đọc property int từ JS object. Trả null nếu property không tồn tại / lỗi.
fn jsOptInt(ctx: ?*c.JSContext, obj: c.JSValue, key: [*:0]const u8) ?i64 {
    const v = c.JS_GetPropertyStr(ctx, obj, key);
    defer c.JS_FreeValue(ctx, v);
    if (c.JS_IsUndefined(v) != 0 or c.JS_IsNull(v) != 0) return null;
    var out: i64 = 0;
    if (c.JS_ToInt64(ctx, &out, v) != 0) return null;
    return out;
}

/// Stringify JS object (argv) thành JSON string cho headers_json của lib.
/// Dùng JS_JSONStringify của QuickJS — đảm bảo escape đúng mọi giá trị.
fn jsObjectToJsonString(ctx: ?*c.JSContext, obj: c.JSValue, alloc: Allocator) ?[]u8 {
    const s = c.JS_JSONStringify(ctx, obj, JS_UNDEFINED, JS_UNDEFINED);
    defer c.JS_FreeValue(ctx, s);
    if (c.JS_IsString(s) == 0) return null;
    return jsStringSlice(ctx, s, alloc);
}

fn jsMiniHttp(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    const engine = getEngine(ctx) orelse return JS_UNDEFINED;
    engine.renewActivity();
    if (argc < 2) return c.JS_ThrowTypeError(ctx, "mini.http requires method and url arguments");

    const method = jsStringSlice(ctx, argv[0], engine.alloc) orelse return c.JS_ThrowTypeError(ctx, "invalid method");
    defer engine.alloc.free(method);

    const url = jsStringSlice(ctx, argv[1], engine.alloc) orelse return c.JS_ThrowTypeError(ctx, "invalid url");
    defer engine.alloc.free(url);

    // opts: { body?, headers?, max_body_size?, timeout_s? }
    var body_opt: ?[]u8 = null;
    defer if (body_opt) |b| engine.alloc.free(b);
    var headers_json_opt: ?[]u8 = null;
    defer if (headers_json_opt) |h| engine.alloc.free(h);
    var max_body_size_opt: ?usize = null;
    var timeout_s_opt: ?u32 = null;

    if (argc >= 3 and c.JS_IsObject(argv[2]) != 0) {
        const opts = argv[2];
        body_opt = jsOptString(ctx, opts, "body", engine.alloc);
        const hv = c.JS_GetPropertyStr(ctx, opts, "headers");
        defer c.JS_FreeValue(ctx, hv);
        if (c.JS_IsObject(hv) != 0) {
            headers_json_opt = jsObjectToJsonString(ctx, hv, engine.alloc);
        }
        if (jsOptInt(ctx, opts, "max_body_size")) |v| {
            if (v > 0) max_body_size_opt = @intCast(v);
        }
        if (jsOptInt(ctx, opts, "timeout_s")) |v| {
            if (v > 0) timeout_s_opt = @intCast(v);
        }
    }

    // M2: policy check — mini.http map sang tool 'http_request'
    if (guardPolicy(engine, "http_request")) {
        hooks.dispatch(engine.alloc, engine.io, .{
            .event = "post-tool-use", .tool_name = "http_request",
            .input_json = url, .tool_result = "blocked by policy", .is_error = true,
        });
        return c.JS_ThrowTypeError(ctx, "Security Policy Error: mini.http (http_request) is blocked");
    }
    hooks.dispatch(engine.alloc, engine.io, .{
        .event = "pre-tool-use", .tool_name = "http_request", .input_json = url,
    });

    var res = http_lib.fetch(engine.alloc, engine.io, .{
        .url = url,
        .method = method,
        .body = body_opt,
        .headers_json = headers_json_opt,
        .max_body_size = max_body_size_opt orelse http_lib.DEFAULT_MAX_BODY_SIZE,
        .timeout_s = timeout_s_opt orelse http_lib.DEFAULT_TIMEOUT_S,
    }) catch |e| {
        return c.JS_ThrowInternalError(ctx, "http error: %s", @errorName(e).ptr);
    };
    defer res.deinit(engine.alloc);

    engine.renewActivity();

    hooks.dispatch(engine.alloc, engine.io, .{
        .event = "post-tool-use", .tool_name = "http_request",
        .input_json = url, .tool_result = res.body,
    });

    const obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, obj, "status", c.JS_NewInt32(ctx, @intCast(res.status)));
    _ = c.JS_SetPropertyStr(ctx, obj, "body", c.JS_NewStringLen(ctx, res.body.ptr, res.body.len));
    _ = c.JS_SetPropertyStr(ctx, obj, "truncated", c.JS_NewBool(ctx, if (res.truncated) 1 else 0));

    const headers_obj = c.JS_NewObject(ctx);
    for (res.headers) |h| {
        // JS_SetProperty steal val và không steal atom — theo chuẩn QuickJS:
        // tạo string → chuyển atom (atom giữ string sống) → set → free atom ref.
        const name = c.JS_NewStringLen(ctx, h.name.ptr, h.name.len);
        const atom = c.JS_ValueToAtom(ctx, name);
        c.JS_FreeValue(ctx, name);
        const val = c.JS_NewStringLen(ctx, h.value.ptr, h.value.len);
        _ = c.JS_SetProperty(ctx, headers_obj, atom, val); // steal val
        c.JS_FreeAtom(ctx, atom);
    }
    _ = c.JS_SetPropertyStr(ctx, obj, "headers", headers_obj);
    return obj;
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

    const val = getenv(var_name_z.ptr);
    if (val) |v| {
        const slice = std.mem.span(v);
        return c.JS_NewStringLen(ctx, slice.ptr, slice.len);
    }
    return JS_NULL;
}

/// Đăng ký object toàn cục `mini` vào JSContext
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

    // 3. network & session
    _ = c.JS_SetPropertyStr(ctx, mini_obj, "http", c.JS_NewCFunction(ctx, jsMiniHttp, "http", 3));
    _ = c.JS_SetPropertyStr(ctx, mini_obj, "artifact", c.JS_NewCFunction(ctx, jsMiniArtifact, "artifact", 3));
    _ = c.JS_SetPropertyStr(ctx, mini_obj, "env", c.JS_NewCFunction(ctx, jsMiniEnv, "env", 1));

    // 4. metadata props
    const pwd_val = getenv("PWD");
    const cwd_str = if (pwd_val) |p| std.mem.span(p) else ".";
    _ = c.JS_SetPropertyStr(ctx, mini_obj, "workspaceRoot", c.JS_NewStringLen(ctx, cwd_str.ptr, cwd_str.len));

    const session_id = artifacts_mod.getSessionId();
    _ = c.JS_SetPropertyStr(ctx, mini_obj, "sessionId", c.JS_NewStringLen(ctx, session_id.ptr, session_id.len));

    _ = c.JS_SetPropertyStr(ctx, global_obj, "mini", mini_obj);
}
