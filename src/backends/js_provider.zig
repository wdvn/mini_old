//! js_provider.zig — Dynamic JavaScript Provider Adapter (RFC-012 Extension).
//!
//! Executes a user-provided or dynamically loaded JavaScript provider script via embedded QuickJS.
//! Allows custom providers to hook into:
//! - extractReasoning(chunk): extract reasoning content from non-standard JSON (e.g. delta.detail.reasoning_content)
//! - extractContent(chunk): extract text content from custom fields
//! - transformRequest(request): modify request payload before HTTP dispatch

const std = @import("std");
const Allocator = std.mem.Allocator;
const provider_mod = @import("provider.zig");
const ProviderProfile = provider_mod.ProviderProfile;
const main = @import("../main.zig");
const utils = @import("../core/utils.zig");

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

fn isException(v: c.JSValue) bool {
    return c.JS_IsException(v) != 0;
}

fn isObject(v: c.JSValue) bool {
    return c.JS_IsObject(v) != 0;
}

fn isString(v: c.JSValue) bool {
    return c.JS_IsString(v) != 0;
}

fn isFunction(ctx: *c.JSContext, v: c.JSValue) bool {
    return c.JS_IsFunction(ctx, v) != 0;
}

/// Heuristic: input looks like a file path if it ends with .js and
/// does not contain obvious JS syntax characters.
fn looksLikeFilePath(input: []const u8) bool {
    if (input.len == 0 or input.len > 4096) return false;
    if (!std.mem.endsWith(u8, input, ".js")) return false;
    for (input) |ch| {
        if (ch == '{' or ch == '(' or ch == ';' or ch == '\n') return false;
    }
    return true;
}

pub const JsProviderAdapter = struct {
    alloc: Allocator,
    rt: *c.JSRuntime,
    ctx: *c.JSContext,
    export_obj: c.JSValue,
    fn_extract_reasoning: ?c.JSValue = null,
    fn_extract_content: ?c.JSValue = null,
    fn_transform_request: ?c.JSValue = null,
    profile: ProviderProfile,
    name_owned: ?[]const u8 = null,
    deadline_ms: i64 = 0,

    fn nowMs() i64 {
        var ts: std.os.linux.timespec = undefined;
        if (std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts) != 0) return std.math.maxInt(i64);
        return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(ts.nsec, 1000000);
    }

    fn interrupt(_: ?*c.JSRuntime, opaque_ptr: ?*anyopaque) callconv(.c) c_int {
        const deadline: *i64 = @ptrCast(@alignCast(opaque_ptr orelse return 1));
        return if (nowMs() >= deadline.*) 1 else 0;
    }

    fn beginCall(self: *JsProviderAdapter) void {
        self.deadline_ms = nowMs() + 100;
    }

    /// Initialize adapter from JS source code or file path (auto-detected).
    pub fn initFromSource(alloc: Allocator, source: []const u8) !*JsProviderAdapter {
        // Auto-detect: if source looks like a file path, load from file.
        const trimmed_input = std.mem.trim(u8, source, " \t\r\n");
        if (looksLikeFilePath(trimmed_input)) {
            return initFromFileWithProfile(alloc, trimmed_input, null);
        }
        return initFromSourceWithProfile(alloc, source, null);
    }

    /// Initialize adapter from JS source code, with an optional
    /// base profile to inherit from (defaults to "generic" if null).
    /// This function always treats input as raw JS source (no file path detection).
    pub fn initFromSourceWithProfile(alloc: Allocator, source: []const u8, base_profile: ?ProviderProfile) !*JsProviderAdapter {

        const rt = c.JS_NewRuntime() orelse return error.QuickJSRuntimeInitFailed;
        errdefer c.JS_FreeRuntime(rt);

        // Limit RAM for safety (32MB is plenty for provider adapters)
        c.JS_SetMemoryLimit(rt, 32 * 1024 * 1024);
        c.JS_SetMaxStackSize(rt, 512 * 1024);
        var deadline = nowMs() + 100;
        c.JS_SetInterruptHandler(rt, interrupt, &deadline);

        const ctx = c.JS_NewContext(rt) orelse return error.QuickJSContextInitFailed;
        errdefer c.JS_FreeContext(ctx);

        // Normalize source: if it starts with export default, replace with return
        var normalized_source = std.ArrayListUnmanaged(u8).empty;
        defer normalized_source.deinit(alloc);

        const trimmed = std.mem.trim(u8, source, " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, "export default")) {
            try normalized_source.appendSlice(alloc, "return ");
            try normalized_source.appendSlice(alloc, trimmed["export default".len..]);
        } else {
            try normalized_source.appendSlice(alloc, trimmed);
        }

        // Wrap in self-invoking function that supports:
        // 1. return { ... }
        // 2. module.exports = { ... }
        // 3. provider = { ... }
        // 4. ({ ... })
        var wrapper = std.ArrayListUnmanaged(u8).empty;
        defer wrapper.deinit(alloc);

        try wrapper.appendSlice(alloc,
            \\(function() {
            \\    var module = { exports: {} };
            \\    var exports = module.exports;
            \\    var provider = null;
            \\    var __fn = function() {
            \\
        );
        try wrapper.appendSlice(alloc, normalized_source.items);
        try wrapper.appendSlice(alloc,
            \\
            \\    };
            \\    var __res = __fn();
            \\    if (__res && typeof __res === 'object') return __res;
            \\    if (typeof provider !== 'undefined' && provider) return provider;
            \\    if (typeof module !== 'undefined' && module.exports && Object.keys(module.exports).length > 0) {
            \\        return module.exports.default || module.exports;
            \\    }
            \\    return null;
            \\})()
        );
        try wrapper.append(alloc, 0);

        // Sentinel null-terminator for QuickJS C eval
        var eval_val = c.JS_Eval(ctx, wrapper.items.ptr, wrapper.items.len - 1, "<provider_js>", c.JS_EVAL_TYPE_GLOBAL);
        if (isException(eval_val)) {
            const exc = c.JS_GetException(ctx);
            c.JS_FreeValue(ctx, exc);
            return error.JsEvaluationFailed;
        }

        // If wrapper didn't produce an object, try direct expression `( <source> )`
        if (!isObject(eval_val)) {
            c.JS_FreeValue(ctx, eval_val);

            const expr_body = if (std.mem.startsWith(u8, trimmed, "export default"))
                std.mem.trim(u8, trimmed["export default".len..], " \t\r\n")
            else
                trimmed;

            var expr_wrapper = std.ArrayListUnmanaged(u8).empty;
            defer expr_wrapper.deinit(alloc);
            try expr_wrapper.append(alloc, '(');
            try expr_wrapper.appendSlice(alloc, expr_body);
            try expr_wrapper.appendSlice(alloc, ")\x00");

            eval_val = c.JS_Eval(ctx, expr_wrapper.items.ptr, expr_wrapper.items.len - 1, "<provider_expr>", c.JS_EVAL_TYPE_GLOBAL);
            if (isException(eval_val)) {
                const exc = c.JS_GetException(ctx);
                defer c.JS_FreeValue(ctx, exc);
                return error.JsEvaluationFailed;
            }

            if (!isObject(eval_val)) {
                c.JS_FreeValue(ctx, eval_val);
                return error.JsProviderExportMissing;
            }
        }

        const self = alloc.create(JsProviderAdapter) catch |err| {
            c.JS_FreeValue(ctx, eval_val);
            return err;
        };
        errdefer alloc.destroy(self);

        self.* = JsProviderAdapter{
            .alloc = alloc,
            .rt = rt,
            .ctx = ctx,
            .export_obj = eval_val,
            .profile = base_profile orelse provider_mod.getProfile("generic"),
        };

        // Transfer ownership before parsing getters (which may execute JS).
        c.JS_SetInterruptHandler(rt, interrupt, &self.deadline_ms);
        self.beginCall();
        self.parseExportedObject() catch |err| {
            if (self.name_owned) |n| alloc.free(n);
            c.JS_FreeValue(ctx, self.export_obj);
            return err;
        };

        return self;
    }

    /// Initialize adapter from a JS file path.
    pub fn initFromFile(alloc: Allocator, path: []const u8) !*JsProviderAdapter {
        return initFromFileWithProfile(alloc, path, null);
    }

    /// Initialize adapter from a JS file path with optional base profile.
    fn initFromFileWithProfile(alloc: Allocator, path: []const u8, base_profile: ?ProviderProfile) !*JsProviderAdapter {
        const io = main.getIo();
        const cwd = std.Io.Dir.cwd();
        const file = cwd.openFile(io, path, .{}) catch return error.JsProviderFileNotFound;
        defer file.close(io);

        // Provider JS files are small; 1MB fixed buffer is plenty.
        var buf: [1024 * 1024]u8 = undefined;
        const n = utils.readAll(io, file, &buf) catch return error.JsProviderFileReadFailed;
        if (n == 0) return error.JsProviderExportMissing;

        // Delegate to initFromSourceWithProfile — content won't trigger file-path
        // auto-detect because it contains JS syntax characters.
        return try initFromSourceWithProfile(alloc, buf[0..n], base_profile);
    }

    fn parseExportedObject(self: *JsProviderAdapter) !void {
        const ctx = self.ctx;
        const obj = self.export_obj;

        // 1. Name
        const name_val = c.JS_GetPropertyStr(ctx, obj, "name");
        defer c.JS_FreeValue(ctx, name_val);
        if (isString(name_val)) {
            const cstr = c.JS_ToCString(ctx, name_val);
            if (cstr != null) {
                defer c.JS_FreeCString(ctx, cstr);
                self.name_owned = try self.alloc.dupe(u8, std.mem.span(cstr));
                self.profile.name = self.name_owned.?;
            }
        }

        // 2. Protocol
        const proto_val = c.JS_GetPropertyStr(ctx, obj, "protocol");
        defer c.JS_FreeValue(ctx, proto_val);
        if (isString(proto_val)) {
            const cstr = c.JS_ToCString(ctx, proto_val);
            if (cstr != null) {
                defer c.JS_FreeCString(ctx, cstr);
                const s = std.mem.span(cstr);
                if (std.mem.eql(u8, s, "chat_completions")) {
                    self.profile.protocol = .chat_completions;
                } else if (std.mem.eql(u8, s, "responses")) {
                    self.profile.protocol = .responses;
                } else if (std.mem.eql(u8, s, "auto")) {
                    self.profile.protocol = .auto;
                }
            }
        }

        // 3. Echo Policy
        const echo_val = c.JS_GetPropertyStr(ctx, obj, "echo_policy");
        defer c.JS_FreeValue(ctx, echo_val);
        if (isString(echo_val)) {
            const cstr = c.JS_ToCString(ctx, echo_val);
            if (cstr != null) {
                defer c.JS_FreeCString(ctx, cstr);
                const s = std.mem.span(cstr);
                if (std.mem.eql(u8, s, "echo_required")) {
                    self.profile.echo_policy = .echo_required;
                } else if (std.mem.eql(u8, s, "echo_optional")) {
                    self.profile.echo_policy = .echo_optional;
                } else if (std.mem.eql(u8, s, "drop")) {
                    self.profile.echo_policy = .drop;
                }
            }
        }

        // 4. Thinking Tags
        const tags_val = c.JS_GetPropertyStr(ctx, obj, "thinking_tags");
        defer c.JS_FreeValue(ctx, tags_val);
        if (isString(tags_val)) {
            const cstr = c.JS_ToCString(ctx, tags_val);
            if (cstr != null) {
                defer c.JS_FreeCString(ctx, cstr);
                const s = std.mem.span(cstr);
                if (std.mem.eql(u8, s, "none")) {
                    self.profile.thinking_tags = .none;
                } else if (std.mem.eql(u8, s, "english_and_chinese")) {
                    self.profile.thinking_tags = .english_and_chinese;
                } else if (std.mem.eql(u8, s, "english_only")) {
                    self.profile.thinking_tags = .english_only;
                }
            }
        }

        const param_val = c.JS_GetPropertyStr(ctx, obj, "reasoning_param");
        defer c.JS_FreeValue(ctx, param_val);
        if (isString(param_val)) {
            const str = c.JS_ToCString(ctx, param_val);
            if (str != null) {
                defer c.JS_FreeCString(ctx, str);
                self.profile.reasoning_param = std.meta.stringToEnum(provider_mod.ReasoningParamFormat, std.mem.span(str)) orelse return error.InvalidReasoningParam;
            }
        }

        // 5. Hooks: extractReasoning
        const fn_er = c.JS_GetPropertyStr(ctx, obj, "extractReasoning");
        if (isFunction(ctx, fn_er)) {
            self.fn_extract_reasoning = fn_er;
        } else {
            c.JS_FreeValue(ctx, fn_er);
        }

        // 6. Hooks: extractContent
        const fn_ec = c.JS_GetPropertyStr(ctx, obj, "extractContent");
        if (isFunction(ctx, fn_ec)) {
            self.fn_extract_content = fn_ec;
        } else {
            c.JS_FreeValue(ctx, fn_ec);
        }

        // 7. Hooks: transformRequest
        const fn_tr = c.JS_GetPropertyStr(ctx, obj, "transformRequest");
        if (isFunction(ctx, fn_tr)) {
            self.fn_transform_request = fn_tr;
        } else {
            c.JS_FreeValue(ctx, fn_tr);
        }
    }

    /// Extract reasoning tokens from raw SSE JSON chunk.
    /// Returns allocated slice owned by caller if reasoning was found, or null.
    pub fn extractReasoning(self: *JsProviderAdapter, alloc: Allocator, raw_chunk_json: []const u8) ?[]const u8 {
        self.beginCall();
        const fn_hook = self.fn_extract_reasoning orelse return null;
        if (raw_chunk_json.len == 0) return null;

        const chunk_val = c.JS_ParseJSON(self.ctx, raw_chunk_json.ptr, raw_chunk_json.len, "<chunk>");
        if (isException(chunk_val)) {
            const exc = c.JS_GetException(self.ctx);
            c.JS_FreeValue(self.ctx, exc);
            return null;
        }
        defer c.JS_FreeValue(self.ctx, chunk_val);

        var args = [_]c.JSValue{chunk_val};
        const ret_val = c.JS_Call(self.ctx, fn_hook, self.export_obj, 1, &args);
        defer c.JS_FreeValue(self.ctx, ret_val);

        if (isException(ret_val)) {
            const exc = c.JS_GetException(self.ctx);
            c.JS_FreeValue(self.ctx, exc);
            return null;
        }

        if (isString(ret_val)) {
            const cstr = c.JS_ToCString(self.ctx, ret_val);
            if (cstr != null) {
                defer c.JS_FreeCString(self.ctx, cstr);
                const s = std.mem.span(cstr);
                if (s.len > 0) {
                    return alloc.dupe(u8, s) catch null;
                }
            }
        }

        return null;
    }

    /// Extract text content from raw SSE JSON chunk.
    pub fn extractContent(self: *JsProviderAdapter, alloc: Allocator, raw_chunk_json: []const u8) ?[]const u8 {
        self.beginCall();
        const fn_hook = self.fn_extract_content orelse return null;
        if (raw_chunk_json.len == 0) return null;

        const chunk_val = c.JS_ParseJSON(self.ctx, raw_chunk_json.ptr, raw_chunk_json.len, "<chunk>");
        if (isException(chunk_val)) {
            const exc = c.JS_GetException(self.ctx);
            c.JS_FreeValue(self.ctx, exc);
            return null;
        }
        defer c.JS_FreeValue(self.ctx, chunk_val);

        var args = [_]c.JSValue{chunk_val};
        const ret_val = c.JS_Call(self.ctx, fn_hook, self.export_obj, 1, &args);
        defer c.JS_FreeValue(self.ctx, ret_val);

        if (isException(ret_val)) {
            const exc = c.JS_GetException(self.ctx);
            c.JS_FreeValue(self.ctx, exc);
            return null;
        }

        if (isString(ret_val)) {
            const cstr = c.JS_ToCString(self.ctx, ret_val);
            if (cstr != null) {
                defer c.JS_FreeCString(self.ctx, cstr);
                const s = std.mem.span(cstr);
                if (s.len > 0) {
                    return alloc.dupe(u8, s) catch null;
                }
            }
        }

        return null;
    }

    /// Transform outgoing request JSON string before dispatch.
    /// Caller owns returned memory.
    pub fn transformRequest(self: *JsProviderAdapter, alloc: Allocator, raw_request_json: []const u8) ![]const u8 {
        self.beginCall();
        const fn_hook = self.fn_transform_request orelse return try alloc.dupe(u8, raw_request_json);
        if (raw_request_json.len == 0) return try alloc.dupe(u8, raw_request_json);

        const req_val = c.JS_ParseJSON(self.ctx, raw_request_json.ptr, raw_request_json.len, "<req>");
        if (isException(req_val)) {
            const exc = c.JS_GetException(self.ctx);
            c.JS_FreeValue(self.ctx, exc);
            return error.InvalidRequestJson;
        }
        defer c.JS_FreeValue(self.ctx, req_val);

        var args = [_]c.JSValue{req_val};
        const ret_val = c.JS_Call(self.ctx, fn_hook, self.export_obj, 1, &args);
        defer c.JS_FreeValue(self.ctx, ret_val);

        if (isException(ret_val)) {
            const exc = c.JS_GetException(self.ctx);
            c.JS_FreeValue(self.ctx, exc);
            return error.JsRequestTransformFailed;
        }

        if (isObject(ret_val)) {
            const str_val = c.JS_JSONStringify(self.ctx, ret_val, JS_UNDEFINED, JS_UNDEFINED);
            defer c.JS_FreeValue(self.ctx, str_val);
            if (isString(str_val)) {
                const cstr = c.JS_ToCString(self.ctx, str_val);
                if (cstr != null) {
                    defer c.JS_FreeCString(self.ctx, cstr);
                    return try alloc.dupe(u8, std.mem.span(cstr));
                }
            }
        }

        return error.JsRequestTransformFailed;
    }

    pub fn deinit(self: *JsProviderAdapter) void {
        const ctx = self.ctx;
        if (self.fn_extract_reasoning) |f| c.JS_FreeValue(ctx, f);
        if (self.fn_extract_content) |f| c.JS_FreeValue(ctx, f);
        if (self.fn_transform_request) |f| c.JS_FreeValue(ctx, f);
        c.JS_FreeValue(ctx, self.export_obj);

        c.JS_FreeContext(ctx);
        c.JS_FreeRuntime(self.rt);

        if (self.name_owned) |n| self.alloc.free(n);
        self.alloc.destroy(self);
    }
};
