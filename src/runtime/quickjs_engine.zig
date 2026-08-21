//! quickjs_engine.zig — QuickJS-ng Embedded Runtime Engine cho mini-agent.
//!
//! Quản lý máy ảo JavaScript nhúng (In-Process QuickJS-ng VM):
//!   - Sandbox Isolation & Resource Limits (128MB RAM, 1MB Stack)
//!   - Heartbeat Activity Watchdog (bắt CPU Infinite Loops > 5s burst time, tự động gia hạn khi có I/O)
//!   - Output Buffer Capture (console.log redirect vào buffer 64KB kèm head-truncation)
//!   - Stack Trace & Detailed Error Extraction phục vụ Self-Correction Loop

const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("../core/utils.zig");
const main = @import("../main.zig");

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

        const rt = c.JS_NewRuntime() orelse return error.QuickJSRuntimeInitFailed;
        errdefer c.JS_FreeRuntime(rt);

        // 1. Resource Limits (128MB RAM, 1MB Stack)
        c.JS_SetMemoryLimit(rt, 128 * 1024 * 1024);
        c.JS_SetMaxStackSize(rt, 1024 * 1024);

        const ctx = c.JS_NewContext(rt) orelse return error.QuickJSContextInitFailed;
        errdefer c.JS_FreeContext(ctx);

        self.* = Engine{
            .alloc = alloc,
            .io = io,
            .rt = rt,
            .ctx = ctx,
            .output_buf = .empty,
            .last_activity_time = utils.milliTimestamp(),
            .is_paused = false,
            .is_interrupted = false,
            .max_cpu_burst_ms = 5000,
        };

        // Thiết lập interrupt handler cho watchdog
        c.JS_SetInterruptHandler(rt, interruptCallback, self);

        // Thiết lập opaque data cho context
        c.JS_SetContextOpaque(ctx, self);

        // Thiết lập standard built-in objects & console
        try self.setupEnvironment();

        return self;
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

    /// Gia hạn watchdog khi có I/O hoặc Output
    pub fn renewActivity(self: *Engine) void {
        self.last_activity_time = utils.milliTimestamp();
    }

    /// Tạm dừng watchdog khi chờ prompt tương tác người dùng
    pub fn pauseWatchdog(self: *Engine) void {
        self.is_paused = true;
    }

    /// Tiếp tục watchdog sau khi người dùng nhập xong
    pub fn resumeWatchdog(self: *Engine) void {
        self.renewActivity();
        self.is_paused = false;
    }

    /// Đánh dấu ngắt thực thi (Ctrl+C / SIGINT)
    pub fn requestInterrupt(self: *Engine) void {
        self.is_interrupted = true;
    }

    /// Ghi nội dung vào output buffer (có giới hạn 64KB + head truncation)
    pub fn appendOutput(self: *Engine, text: []const u8) void {
        self.renewActivity();
        if (self.output_buf.items.len + text.len > MAX_OUTPUT_BUFFER) {
            // Cắt bớt phần đầu nếu vượt quá 64KB
            const excess = (self.output_buf.items.len + text.len) - MAX_OUTPUT_BUFFER;
            const drop = @min(excess + 1024, self.output_buf.items.len);
            if (drop > 0) {
                const remaining = self.output_buf.items.len - drop;
                std.mem.copyForwards(u8, self.output_buf.items[0..remaining], self.output_buf.items[drop..]);
                self.output_buf.items.len = remaining;
            }
        }
        self.output_buf.appendSlice(self.alloc, text) catch {};
    }

    fn interruptCallback(rt: ?*c.JSRuntime, opaque_ptr: ?*anyopaque) callconv(.c) c_int {
        _ = rt;
        const self: *Engine = @ptrCast(@alignCast(opaque_ptr orelse return 0));
        if (self.is_interrupted) return 1;
        if (self.is_paused) return 0;

        const now = utils.milliTimestamp();
        if (now - self.last_activity_time > self.max_cpu_burst_ms) {
            return 1; // Ngắt CPU Starvation
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

        // Tạo console object
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

        // Đăng ký hàm print toàn cục
        const print_func = c.JS_NewCFunction(ctx, jsConsoleLog, "print", 1);
        _ = c.JS_SetPropertyStr(ctx, global_obj, "print", print_func);
    }

    /// Thực thi đoạn mã JavaScript trong engine
    pub fn eval(self: *Engine, code: []const u8, filename: []const u8) !ExecutionResult {
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

        // Chạy các Promise pending jobs nếu có
        var pctx: ?*c.JSContext = null;
        while (true) {
            const err = c.JS_ExecutePendingJob(self.rt, &pctx);
            if (err <= 0) {
                if (err < 0) {
                    // Lỗi trong async job
                }
                break;
            }
        }

        const is_exception = c.JS_IsException(val) != 0;

        if (is_exception) {
            const exc = c.JS_GetException(ctx);
            defer c.JS_FreeValue(ctx, exc);

            var err_msg: ?[]u8 = null;
            var stack_trace: ?[]u8 = null;

            // Lấy message / toString của exception
            const exc_str = c.JS_ToCString(ctx, exc);
            if (exc_str != null) {
                defer c.JS_FreeCString(ctx, exc_str);
                err_msg = try self.alloc.dupe(u8, std.mem.span(exc_str));
            }

            // Lấy stack trace nếu có
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

        defer c.JS_FreeValue(ctx, val);

        // Format return value thành JSON nếu không phải undefined
        var return_json: ?[]u8 = null;
        if (c.JS_IsUndefined(val) == 0) {
            const json_val = c.JS_JSONStringify(ctx, val, JS_UNDEFINED, JS_UNDEFINED);
            defer c.JS_FreeValue(ctx, json_val);
            if (c.JS_IsException(json_val) == 0) {
                const json_str = c.JS_ToCString(ctx, json_val);
                if (json_str != null) {
                    defer c.JS_FreeCString(ctx, json_str);
                    return_json = try self.alloc.dupe(u8, std.mem.span(json_str));
                }
            }
        }

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

    var res = try engine.eval("console.log('Hello from QuickJS-ng'); 1 + 2 * 3;", "test.js");
    defer res.deinit();

    try std.testing.expect(!res.is_error);
    try std.testing.expectEqualStrings("Hello from QuickJS-ng\n", res.stdout);
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

