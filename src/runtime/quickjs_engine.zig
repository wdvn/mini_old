//! quickjs_engine.zig — Embedded Runtime Engine for mini-agent.
//!
//! Manages in-process CodeAct JavaScript virtual machine:
//!   - Sandbox Isolation & Resource Limits (128MB RAM, 1MB Stack)
//!   - Heartbeat Activity Watchdog (catches CPU Infinite Loops > 5s burst time, automatically extended on I/O)
//!   - Output Buffer Capture (console.log redirected to 64KB buffer with head-truncation)
//!   - Stack Trace & Detailed Error Extraction for Self-Correction Loops

const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("../core/utils.zig");
const main = @import("../main.zig");
const hooks = @import("../core/hooks.zig");

pub const c = @cImport({
    @cInclude("quickjs.h");
});

pub const JS_UNDEFINED = c.JSValue{
    .u = .{ .int32 = 0 },
    .tag = c.JS_TAG_UNDEFINED,
};

pub const JS_NULL = c.JSValue{
    .u = .{ .int32 = 0 },
    .tag = c.JS_TAG_NULL,
};

pub const JS_EXCEPTION = c.JSValue{
    .u = .{ .int32 = 0 },
    .tag = c.JS_TAG_EXCEPTION,
};

pub const ExecutionResult = struct {
    alloc: Allocator,
    stdout: []const u8,
    is_error: bool,
    return_value_json: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
    stack_trace: ?[]const u8 = null,

    pub fn deinit(self: *ExecutionResult) void {
        self.alloc.free(self.stdout);
        if (self.return_value_json) |v| self.alloc.free(v);
        if (self.error_message) |m| self.alloc.free(m);
        if (self.stack_trace) |s| self.alloc.free(s);
    }
};

pub const Engine = struct {
    alloc: Allocator,
    io: std.Io,
    rt: ?*c.JSRuntime,
    ctx: ?*c.JSContext,
    output_buf: std.ArrayListUnmanaged(u8),
    last_activity_time: i64,
    is_paused: bool = false,
    is_interrupted: bool = false,
    max_cpu_burst_ms: i64 = 5000,

    const MAX_OUTPUT_BUFFER = 64 * 1024;

    pub fn init(alloc: Allocator, io: std.Io) !*Engine {
        const self = try alloc.create(Engine);
        errdefer alloc.destroy(self);

        self.* = Engine{
            .alloc = alloc,
            .io = io,
            .rt = null,
            .ctx = null,
            .output_buf = .empty,
            .last_activity_time = utils.milliTimestamp(),
            .is_paused = false,
            .is_interrupted = false,
            .max_cpu_burst_ms = 5000,
        };

        // Initialize fresh runtime & context initially
        try self.resetContext();

        return self;
    }

    /// Initialize fresh JSRuntime & JSContext before each eval for complete isolation (Per-Act VM Isolation)
    pub fn resetContext(self: *Engine) !void {
        if (self.ctx) |ctx| {
            c.JS_FreeContext(ctx);
            self.ctx = null;
        }
        if (self.rt) |rt| {
            c.JS_FreeRuntime(rt);
            self.rt = null;
        }

        const rt = c.JS_NewRuntime() orelse return error.QuickJSRuntimeInitFailed;
        errdefer c.JS_FreeRuntime(rt);

        c.JS_SetMemoryLimit(rt, 128 * 1024 * 1024);
        c.JS_SetMaxStackSize(rt, 1024 * 1024);

        const ctx = c.JS_NewContext(rt) orelse return error.QuickJSContextInitFailed;
        errdefer c.JS_FreeContext(ctx);

        self.rt = rt;
        self.ctx = ctx;

        c.JS_SetInterruptHandler(rt, interruptCallback, self);
        c.JS_SetContextOpaque(ctx, self);
        try self.setupEnvironment();
        const js_bindings = @import("js_bindings.zig");
        try js_bindings.registerBindings(self);
    }

    pub fn deinit(self: *Engine) void {
        if (self.ctx) |ctx| {
            c.JS_FreeContext(ctx);
            self.ctx = null;
        }
        if (self.rt) |rt| {
            c.JS_FreeRuntime(rt);
            self.rt = null;
        }
        self.output_buf.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    /// Extend watchdog on I/O or output activity
    pub fn renewActivity(self: *Engine) void {
        self.last_activity_time = utils.milliTimestamp();
    }

    /// Pause watchdog while awaiting interactive user prompt
    pub fn pauseWatchdog(self: *Engine) void {
        self.is_paused = true;
    }

    /// Resume watchdog after user completes input
    pub fn resumeWatchdog(self: *Engine) void {
        self.renewActivity();
        self.is_paused = false;
    }

    /// Flag execution interrupt (Ctrl+C / SIGINT)
    pub fn requestInterrupt(self: *Engine) void {
        self.is_interrupted = true;
    }

    /// Append content to output buffer (bounded at 64KB with head truncation)
    pub fn appendOutput(self: *Engine, text: []const u8) void {
        self.renewActivity();
        if (self.output_buf.items.len + text.len > MAX_OUTPUT_BUFFER) {
            // Truncate head if exceeding 64KB
            const excess = (self.output_buf.items.len + text.len) - MAX_OUTPUT_BUFFER;
            const drop = @min(excess + 1024, self.output_buf.items.len);
            if (drop > 0) {
                const remaining = self.output_buf.items.len - drop;
                std.mem.copyForwards(u8, self.output_buf.items[0..remaining], self.output_buf.items[drop..]);
                self.output_buf.items.len = remaining;
            }
        }
        self.output_buf.appendSlice(self.alloc, text) catch {};
        hooks.appendExecutionOutput(text);
    }

    fn interruptCallback(rt: ?*c.JSRuntime, opaque_ptr: ?*anyopaque) callconv(.c) c_int {
        _ = rt;
        const self: *Engine = @ptrCast(@alignCast(opaque_ptr orelse return 0));
        if (self.is_interrupted) return 1;
        if (self.is_paused) return 0;

        const now = utils.milliTimestamp();
        if (now - self.last_activity_time > self.max_cpu_burst_ms) {
            return 1; // Interrupt CPU Starvation
        }
        return 0;
    }

    fn jsConsoleLog(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        _ = this_val;
        const engine: *Engine = @ptrCast(@alignCast(c.JS_GetContextOpaque(ctx) orelse return JS_UNDEFINED));
        
        var i: usize = 0;
        const count: usize = if (argc > 0) @intCast(argc) else 0;
        while (i < count) : (i += 1) {
            if (i > 0) engine.appendOutput(" ");
            const str_c = c.JS_ToCString(ctx, argv[i]);
            if (str_c != null) {
                defer c.JS_FreeCString(ctx, str_c);
                const slice = std.mem.span(str_c);
                engine.appendOutput(slice);
            }
        }
        engine.appendOutput("\n");
        return JS_UNDEFINED;
    }

    fn setupEnvironment(self: *Engine) !void {
        const ctx = self.ctx.?;
        const global_obj = c.JS_GetGlobalObject(ctx);
        defer c.JS_FreeValue(ctx, global_obj);

        // Create console object
        const console_obj = c.JS_NewObject(ctx);
        const log_func = c.JS_NewCFunction(ctx, jsConsoleLog, "log", 1);
        const error_func = c.JS_NewCFunction(ctx, jsConsoleLog, "error", 1);
        const warn_func = c.JS_NewCFunction(ctx, jsConsoleLog, "warn", 1);
        const info_func = c.JS_NewCFunction(ctx, jsConsoleLog, "info", 1);

        _ = c.JS_SetPropertyStr(ctx, console_obj, "log", log_func);
        _ = c.JS_SetPropertyStr(ctx, console_obj, "error", error_func);
        _ = c.JS_SetPropertyStr(ctx, console_obj, "warn", warn_func);
        _ = c.JS_SetPropertyStr(ctx, console_obj, "info", info_func);

        _ = c.JS_SetPropertyStr(ctx, global_obj, "console", console_obj);

        // Register global print function
        const print_func = c.JS_NewCFunction(ctx, jsConsoleLog, "print", 1);
        _ = c.JS_SetPropertyStr(ctx, global_obj, "print", print_func);
    }

    fn drainPendingJobs(self: *Engine) void {
        var pctx: ?*c.JSContext = null;
        while (true) {
            const err = c.JS_ExecutePendingJob(self.rt, &pctx);
            if (err <= 0) break;
        }
    }

    fn extractExceptionResult(self: *Engine, ctx: *c.JSContext) !ExecutionResult {
        const exc = c.JS_GetException(ctx);
        defer c.JS_FreeValue(ctx, exc);

        var err_msg: ?[]u8 = null;
        var stack_trace: ?[]u8 = null;

        const exc_str = c.JS_ToCString(ctx, exc);
        if (exc_str != null) {
            defer c.JS_FreeCString(ctx, exc_str);
            err_msg = try self.alloc.dupe(u8, std.mem.span(exc_str));
        }

        const stack_val = c.JS_GetPropertyStr(ctx, exc, "stack");
        defer c.JS_FreeValue(ctx, stack_val);
        if (c.JS_IsUndefined(stack_val) == 0 and c.JS_IsNull(stack_val) == 0) {
            const stack_str = c.JS_ToCString(ctx, stack_val);
            if (stack_str != null) {
                defer c.JS_FreeCString(ctx, stack_str);
                stack_trace = try self.alloc.dupe(u8, std.mem.span(stack_str));
            }
        }

        const stdout_out = try self.alloc.dupe(u8, self.output_buf.items);
        return ExecutionResult{
            .alloc = self.alloc,
            .stdout = stdout_out,
            .is_error = true,
            .return_value_json = null,
            .error_message = err_msg,
            .stack_trace = stack_trace,
        };
    }

    fn stringifyReturnValue(self: *Engine, ctx: *c.JSContext, val: c.JSValue) !?[]u8 {
        if (c.JS_IsUndefined(val) != 0) return null;
        const json_val = c.JS_JSONStringify(ctx, val, JS_UNDEFINED, JS_UNDEFINED);
        defer c.JS_FreeValue(ctx, json_val);
        if (c.JS_IsException(json_val) != 0) return null;

        const json_str = c.JS_ToCString(ctx, json_val);
        if (json_str == null) return null;
        defer c.JS_FreeCString(ctx, json_str);
        return try self.alloc.dupe(u8, std.mem.span(json_str));
    }

    /// Execute JavaScript code snippet in engine
    pub fn eval(self: *Engine, code: []const u8, filename: []const u8) !ExecutionResult {
        try self.resetContext();
        const ctx = self.ctx.?;
        self.output_buf.clearRetainingCapacity();
        self.renewActivity();
        self.is_interrupted = false;

        const code_null_terminated = try self.alloc.dupeZ(u8, code);
        defer self.alloc.free(code_null_terminated);

        const filename_null_terminated = try self.alloc.dupeZ(u8, filename);
        defer self.alloc.free(filename_null_terminated);

        const val = c.JS_Eval(
            ctx,
            code_null_terminated.ptr,
            code.len,
            filename_null_terminated.ptr,
            c.JS_EVAL_TYPE_GLOBAL,
        );

        drainPendingJobs(self);

        if (c.JS_IsException(val) != 0) {
            return extractExceptionResult(self, ctx);
        }
        defer c.JS_FreeValue(ctx, val);

        const return_json = try stringifyReturnValue(self, ctx, val);
        const stdout_out = try self.alloc.dupe(u8, self.output_buf.items);
        return ExecutionResult{
            .alloc = self.alloc,
            .stdout = stdout_out,
            .is_error = false,
            .return_value_json = return_json,
            .error_message = null,
            .stack_trace = null,
        };
    }
};

test "quickjs_engine - basic eval & console.log" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var engine = try Engine.init(alloc, io);
    defer engine.deinit();

    var res = try engine.eval("console.log('Hello from CodeAct'); 1 + 2 * 3;", "test.js");
    defer res.deinit();

    try std.testing.expect(!res.is_error);
    try std.testing.expectEqualStrings("Hello from CodeAct\n", res.stdout);
    if (res.return_value_json) |v| {
        try std.testing.expectEqualStrings("7", v);
    } else {
        return error.ExpectedReturnValue;
    }
}

test "quickjs_engine - error stack trace extraction" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var engine = try Engine.init(alloc, io);
    defer engine.deinit();

    var res = try engine.eval(
        \\function foo() {
        \\    throw new Error("test error in foo");
        \\}
        \\foo();
    , "test_err.js");
    defer res.deinit();

    try std.testing.expect(res.is_error);
    try std.testing.expect(res.error_message != null);
    try std.testing.expect(std.mem.indexOf(u8, res.error_message.?, "test error in foo") != null);
    try std.testing.expect(res.stack_trace != null);
    try std.testing.expect(std.mem.indexOf(u8, res.stack_trace.?, "foo") != null);
}

test "quickjs_engine - mini bindings" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const js_bindings = @import("js_bindings.zig");

    var engine = try Engine.init(alloc, io);
    defer engine.deinit();
    try js_bindings.registerBindings(engine);

    var res = try engine.eval(
        \\const exists = mini.exists("build.zig");
        \\const stat = mini.stat("build.zig");
        \\console.log("build.zig exists:", exists, "size:", stat.size > 0);
        \\exists;
    , "test_mini.js");
    defer res.deinit();

    try std.testing.expect(!res.is_error);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "build.zig exists: true size: true") != null);
}

test "quickjs_engine - background job management" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const js_bindings = @import("js_bindings.zig");
    const pm = @import("process_manager.zig");
    defer pm.deinitGlobal();

    var engine = try Engine.init(alloc, io);
    defer engine.deinit();
    try js_bindings.registerBindings(engine);

    var res = try engine.eval(
        \\const job = mini.shBackground("echo 'job test log line 1' && echo 'job test log line 2'");
        \\console.log("spawned:", job.jobId.length > 0, "pid:", job.pid > 0);
        \\job.jobId;
    , "test_job.js");
    defer res.deinit();

    try std.testing.expect(!res.is_error);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "spawned: true pid: true") != null);
}


// --- Test helper: Single-request HTTP server running on a separate thread for mini.http ---

const HttpTestServer = struct {
    io: std.Io,
    port: u16,
    thread: ?std.Thread,
    done: std.Io.Event,

    fn run(self: *@This()) void {
        const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", self.port) catch return;
        var server = addr.listen(self.io, .{ .reuse_address = true }) catch return;
        defer server.deinit(self.io);

        var stream = server.accept(self.io) catch return;
        defer stream.close(self.io);

        var read_buf: [16384]u8 = undefined;
        var s_reader = stream.reader(self.io, &read_buf);
        var write_buf: [16384]u8 = undefined;
        var s_writer = stream.writer(self.io, &write_buf);

        _ = s_reader.interface.peekGreedy(1) catch {};
        const body = "{\"ok\":true}";
        s_writer.interface.print(
            "HTTP/1.1 201 Created\r\ncontent-type: application/json\r\nx-custom: hi\r\ncontent-length: {d}\r\n\r\n{s}",
            .{ body.len, body },
        ) catch {};
        s_writer.interface.flush() catch {};
        self.done.set(self.io);
    }
};

test "quickjs_engine - mini.http returns status/headers/body via lib" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const js_bindings = @import("js_bindings.zig");
    const http_lib = @import("../lib/http_request.zig");
    _ = http_lib; // ensure lib is linked into test root

    // Bind ephemeral port then close to reuse
    const probe_addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable;
    var probe = probe_addr.listen(io, .{ .reuse_address = true }) catch unreachable;
    const port = probe.socket.address.getPort();
    probe.deinit(io);

    var srv = HttpTestServer{ .io = io, .port = port, .thread = null, .done = .unset };
    srv.thread = std.Thread.spawn(.{}, HttpTestServer.run, .{&srv}) catch unreachable;
    defer {
        srv.done.waitUncancelable(io);
        srv.thread.?.join();
    }

    var engine = try Engine.init(alloc, io);
    defer engine.deinit();
    try js_bindings.registerBindings(engine);

    const code = try std.fmt.allocPrint(alloc,
        \\const r = mini.http("GET", "http://127.0.0.1:{d}/ping");
        \\console.log("status=" + r.status);
        \\console.log("truncated=" + r.truncated);
        \\console.log("ct=" + r.headers["content-type"]);
        \\console.log("xc=" + r.headers["x-custom"]);
        \\console.log("body=" + r.body);
        \\r.status;
    , .{port});
    defer alloc.free(code);

    var res = try engine.eval(code, "test_mini_http.js");
    defer res.deinit();

    try std.testing.expect(!res.is_error);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "status=201") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "truncated=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "ct=application/json") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "xc=hi") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "body={\"ok\":true}") != null);
}

test "quickjs_engine - per-act fresh context isolation (no top-level const collision)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var engine = try Engine.init(alloc, io);
    defer engine.deinit();

    // Turn 1: Declare top-level const
    var res1 = try engine.eval("const data = 'turn 1'; console.log(data);", "turn1.js");
    defer res1.deinit();
    try std.testing.expect(!res1.is_error);
    try std.testing.expectEqualStrings("turn 1\n", res1.stdout);

    // Turn 2: Declare SAME-NAMED top-level const 'data' (no scope collision due to resetContext)
    var res2 = try engine.eval("const data = 'turn 2'; console.log(data);", "turn2.js");
    defer res2.deinit();
    try std.testing.expect(!res2.is_error);
    try std.testing.expectEqualStrings("turn 2\n", res2.stdout);
}


// ---------------------------------------------------------------------------
// ISSUE-CODEACT-001 M2/M3: policy + hook qua mini.* bindings
// ---------------------------------------------------------------------------

var g_hook_log_buf: [1024]u8 = undefined;
var g_hook_log_len: usize = 0;

fn testHookListener(payload: @import("../core/hooks.zig").HookPayload) void {
    const s = std.fmt.bufPrint(g_hook_log_buf[g_hook_log_len..], "{s}:{s}|", .{ payload.event, payload.tool_name orelse "?" }) catch return;
    g_hook_log_len += s.len;
}

test "codeact security - blocklist chan mini.sh va mini.write (M2)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const js_bindings = @import("js_bindings.zig");
    const registry = @import("../tooling/registry.zig");

    registry.setPolicy(null, "bash,file_write");
    defer registry.setPolicy(null, null);

    var engine = try Engine.init(alloc, io);
    defer engine.deinit();
    try js_bindings.registerBindings(engine);

    var res = try engine.eval(
        \\let sh_blocked = false, wr_blocked = false;
        \\try { mini.sh("echo x"); } catch (e) { sh_blocked = true; }
        \\try { mini.write("/tmp/mini_m2_test.txt", "x"); } catch (e) { wr_blocked = true; }
        \\"sh=" + sh_blocked + " write=" + wr_blocked;
    , "test_policy_block.js");
    defer res.deinit();

    try std.testing.expect(!res.is_error);
    if (res.return_value_json) |rv| {
        try std.testing.expect(std.mem.indexOf(u8, rv, "sh=true") != null);
        try std.testing.expect(std.mem.indexOf(u8, rv, "write=true") != null);
    }
}

test "codeact hooks - pre/post hook quanh mini.write (M3)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const js_bindings = @import("js_bindings.zig");

    hooks.setHookListener(testHookListener);
    defer hooks.setHookListener(null);
    g_hook_log_len = 0;

    var engine = try Engine.init(alloc, io);
    defer engine.deinit();
    try js_bindings.registerBindings(engine);

    var res = try engine.eval(
        \\const w = mini.write("/tmp/mini_hook_test_m3.txt", "hello");
        \\w.ok;
    , "test_hook_write.js");
    defer res.deinit();

    try std.testing.expect(!res.is_error);
    const log = g_hook_log_buf[0..g_hook_log_len];
    try std.testing.expect(std.mem.indexOf(u8, log, "pre-tool-use:file_write") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "post-tool-use:file_write") != null);
}
