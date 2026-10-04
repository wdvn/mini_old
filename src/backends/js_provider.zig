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

fn isBoolean(v: c.JSValue) bool {
    return c.JS_IsBool(v) != 0;
}

/// Heuristic: input looks like a file path if it ends with .js or .json and
/// does not contain obvious JS syntax characters.
fn looksLikeFilePath(input: []const u8) bool {
    if (input.len == 0 or input.len > 4096) return false;
    if (!std.mem.endsWith(u8, input, ".js") and !std.mem.endsWith(u8, input, ".json")) return false;
    for (input) |ch| {
        if (ch == '{' or ch == '(' or ch == ';' or ch == '\n') return false;
    }
    return true;
}

fn skipJsComment(source: []const u8, i: *usize) bool {
    const c0 = source[i.*];
    if (c0 == '/' and i.* + 1 < source.len and source[i.* + 1] == '/') {
        i.* += 2;
        while (i.* < source.len and source[i.*] != '\n') : (i.* += 1) {}
        return true;
    }
    if (c0 == '/' and i.* + 1 < source.len and source[i.* + 1] == '*') {
        i.* += 2;
        while (i.* + 1 < source.len and !(source[i.*] == '*' and source[i.* + 1] == '/')) : (i.* += 1) {}
        if (i.* + 1 < source.len) i.* += 2;
        return true;
    }
    return false;
}

fn skipJsString(source: []const u8, i: *usize) bool {
    const quote = source[i.*];
    if (quote != '\'' and quote != '"' and quote != '`') return false;
    i.* += 1;
    while (i.* < source.len and source[i.*] != quote) {
        if (source[i.*] == '\\' and i.* + 1 < source.len) i.* += 1;
        i.* += 1;
    }
    if (i.* < source.len) i.* += 1;
    return true;
}

/// Locates "export default" keyword in JavaScript source code outside of
/// single-line comments (//...), multi-line comments (/*...*/), and string literals.
fn findExportDefault(source: []const u8) ?usize {
    var i: usize = 0;
    while (i < source.len) {
        if (skipJsComment(source, &i)) continue;
        if (skipJsString(source, &i)) continue;

        if (std.mem.startsWith(u8, source[i..], "export default")) {
            const before_ok = (i == 0) or (!std.ascii.isAlphanumeric(source[i - 1]) and source[i - 1] != '_');
            const after_idx = i + "export default".len;
            const after_ok = (after_idx >= source.len) or (!std.ascii.isAlphanumeric(source[after_idx]) and source[after_idx] != '_');
            if (before_ok and after_ok) {
                return i;
            }
        }
        i += 1;
    }
    return null;
}

/// Logs QuickJS exception message and stack trace to stderr.
fn logJsException(ctx: *c.JSContext, prefix: []const u8) void {
    const exc = c.JS_GetException(ctx);
    defer c.JS_FreeValue(ctx, exc);

    const exc_str = c.JS_ToCString(ctx, exc);
    if (exc_str != null) {
        defer c.JS_FreeCString(ctx, exc_str);
        main.stderrPrint("[js_provider] {s}: {s}\n", .{ prefix, std.mem.span(exc_str) });
    } else {
        main.stderrPrint("[js_provider] {s}: unknown QuickJS exception\n", .{prefix});
    }

    const stack_val = c.JS_GetPropertyStr(ctx, exc, "stack");
    defer c.JS_FreeValue(ctx, stack_val);
    if (c.JS_IsUndefined(stack_val) == 0 and c.JS_IsNull(stack_val) == 0) {
        const stack_str = c.JS_ToCString(ctx, stack_val);
        if (stack_str != null) {
            defer c.JS_FreeCString(ctx, stack_str);
            main.stderrPrint("[js_provider] Stack: {s}\n", .{std.mem.span(stack_str)});
        }
    }
}

pub const JsProviderAdapter = struct {
    alloc: Allocator,
    rt: *c.JSRuntime,
    ctx: *c.JSContext,
    export_obj: c.JSValue,
    fn_extract_reasoning: ?c.JSValue = null,
    fn_extract_content: ?c.JSValue = null,
    fn_transform_request: ?c.JSValue = null,
    fn_generate_image: ?c.JSValue = null,
    fn_generate_video: ?c.JSValue = null,
    profile: ProviderProfile,
    name_owned: ?[]const u8 = null,
    deadline_ms: i64 = 0,

    fn nowMs() i64 {
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return std.math.maxInt(i64);
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
        return initFromSourceWithProfile(alloc, source, null);
    }

    /// Initialize adapter from JS source code or file path (auto-detected),
    /// with an optional base profile to inherit from (defaults to "generic" if null).
    pub fn initFromSourceWithProfile(alloc: Allocator, source: []const u8, base_profile: ?ProviderProfile) !*JsProviderAdapter {
        const trimmed_input = std.mem.trim(u8, source, " \t\r\n");
        if (looksLikeFilePath(trimmed_input)) {
            return initFromFileWithProfile(alloc, trimmed_input, base_profile);
        }
        return initFromRawSourceWithProfile(alloc, source, base_profile);
    }

    /// Initialize adapter from a JS file path with default profile.
    pub fn initFromFile(alloc: Allocator, path: []const u8) !*JsProviderAdapter {
        return initFromFileWithProfile(alloc, path, null);
    }

    /// Initialize adapter from a JS file path with optional base profile.
    pub fn initFromFileWithProfile(alloc: Allocator, path: []const u8, base_profile: ?ProviderProfile) !*JsProviderAdapter {
        const io = main.getIo();
        const cwd = std.Io.Dir.cwd();
        const file = cwd.openFile(io, path, .{}) catch |err| {
            main.stderrPrint("[js_provider] Failed to open provider JS file '{s}': {s}\n", .{ path, @errorName(err) });
            return error.JsProviderFileNotFound;
        };
        defer file.close(io);

        const len_u64 = file.length(io) catch |err| {
            main.stderrPrint("[js_provider] Failed to get length of provider JS file '{s}': {s}\n", .{ path, @errorName(err) });
            return error.JsProviderFileReadFailed;
        };
        if (len_u64 == 0) return error.JsProviderExportMissing;
        if (len_u64 > 1024 * 1024) return error.JsProviderFileTooLarge;

        const len: usize = @intCast(len_u64);
        const buf = alloc.alloc(u8, len) catch return error.OutOfMemory;
        defer alloc.free(buf);

        const n = file.readPositionalAll(io, buf, 0) catch |err| {
            main.stderrPrint("[js_provider] Failed to read provider JS file '{s}': {s}\n", .{ path, @errorName(err) });
            return error.JsProviderFileReadFailed;
        };
        if (n == 0) return error.JsProviderExportMissing;

        return try initFromRawSourceWithProfile(alloc, buf[0..n], base_profile);
    }

    /// Normalize source: replace "export default" with "return " outside comments/strings,
    /// or wrap raw JSON objects in "return ( ... );"
    fn normalizeSource(alloc: Allocator, source: []const u8) ![]u8 {
        // PSEUDOCODE:
        // 1. Allocate buffer for normalized source
        // 2. If 'export default' found, replace with 'return '
        // 3. Else if starts with '{', wrap in 'return ( ... );\n'
        // 4. Else keep original source
        var buf = std.ArrayListUnmanaged(u8).empty;
        errdefer buf.deinit(alloc);
        const trimmed = std.mem.trim(u8, source, " \t\r\n");
        if (findExportDefault(source)) |idx| {
            try buf.appendSlice(alloc, source[0..idx]);
            try buf.appendSlice(alloc, "return ");
            try buf.appendSlice(alloc, source[idx + "export default".len ..]);
        } else if (std.mem.startsWith(u8, trimmed, "{")) {
            try buf.appendSlice(alloc, "return (");
            try buf.appendSlice(alloc, trimmed);
            try buf.appendSlice(alloc, ");\n");
        } else {
            try buf.appendSlice(alloc, source);
        }
        return buf.toOwnedSlice(alloc);
    }

    fn evalWrappedSource(alloc: Allocator, ctx: *c.JSContext, norm: []const u8) !c.JSValue {
        // PSEUDOCODE:
        // 1. Build self-invoking function wrapper supporting module.exports / return
        // 2. Evaluate wrapper in global context
        // 3. Return JSValue or error on exception
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
        try wrapper.appendSlice(alloc, norm);
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

        const eval_val = c.JS_Eval(ctx, wrapper.items.ptr, wrapper.items.len - 1, "<provider_js>", c.JS_EVAL_TYPE_GLOBAL);
        if (isException(eval_val)) {
            logJsException(ctx, "Failed to evaluate provider wrapper");
            return error.JsEvaluationFailed;
        }
        return eval_val;
    }

    fn evalDirectExpression(alloc: Allocator, ctx: *c.JSContext, source: []const u8) !c.JSValue {
        // PSEUDOCODE:
        // 1. Extract expression body after 'export default' or trimmed source
        // 2. Wrap in parentheses and evaluate
        // 3. Validate object result, return or free and error
        const body = if (findExportDefault(source)) |idx|
            std.mem.trim(u8, source[idx + "export default".len ..], " \t\r\n")
        else
            std.mem.trim(u8, source, " \t\r\n");
        var expr = std.ArrayListUnmanaged(u8).empty;
        defer expr.deinit(alloc);
        try expr.append(alloc, '(');
        try expr.appendSlice(alloc, body);
        try expr.appendSlice(alloc, ")\x00");
        const val = c.JS_Eval(ctx, expr.items.ptr, expr.items.len - 1, "<provider_expr>", c.JS_EVAL_TYPE_GLOBAL);
        if (isException(val)) {
            logJsException(ctx, "Failed to evaluate provider expression");
            return error.JsEvaluationFailed;
        }
        if (!isObject(val)) {
            c.JS_FreeValue(ctx, val);
            return error.JsProviderExportMissing;
        }
        return val;
    }

    fn evalProviderExport(alloc: Allocator, ctx: *c.JSContext, source: []const u8) !c.JSValue {
        // PSEUDOCODE:
        // 1. Try evaluating wrapped source
        // 2. If result not an object, fall back to direct expression eval
        const norm = try normalizeSource(alloc, source);
        defer alloc.free(norm);
        var eval_val = try evalWrappedSource(alloc, ctx, norm);
        if (!isObject(eval_val)) {
            c.JS_FreeValue(ctx, eval_val);
            eval_val = try evalDirectExpression(alloc, ctx, source);
        }
        return eval_val;
    }

    /// Initialize adapter from raw JS source code (always treats input as JS source).
    fn initFromRawSourceWithProfile(alloc: Allocator, source: []const u8, base_profile: ?ProviderProfile) !*JsProviderAdapter {
        // PSEUDOCODE:
        // 1. Initialize QuickJS runtime and context with memory limits
        // 2. Evaluate provider source export
        // 3. Allocate and initialize JsProviderAdapter struct
        // 4. Parse exported properties and hooks
        const rt = c.JS_NewRuntime() orelse return error.QuickJSRuntimeInitFailed;
        errdefer c.JS_FreeRuntime(rt);

        c.JS_SetMemoryLimit(rt, 32 * 1024 * 1024);
        c.JS_SetMaxStackSize(rt, 512 * 1024);
        var deadline = nowMs() + 100;
        c.JS_SetInterruptHandler(rt, interrupt, &deadline);

        const ctx = c.JS_NewContext(rt) orelse return error.QuickJSContextInitFailed;
        errdefer c.JS_FreeContext(ctx);

        const eval_val = try evalProviderExport(alloc, ctx, source);
        errdefer c.JS_FreeValue(ctx, eval_val);

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

        c.JS_SetInterruptHandler(rt, interrupt, &self.deadline_ms);
        self.beginCall();
        self.parseExportedObject() catch |err| {
            if (self.name_owned) |n| alloc.free(n);
            c.JS_FreeValue(ctx, self.export_obj);
            return err;
        };
        return self;
    }

    fn parseNameAndProtocol(self: *JsProviderAdapter) !void {
        // PSEUDOCODE:
        // 1. Read 'name' property from JS object
        // 2. Read 'protocol' property and set enum
        const ctx = self.ctx;
        const obj = self.export_obj;

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
    }

    fn parsePolicyAndTags(self: *JsProviderAdapter) void {
        // PSEUDOCODE:
        // 1. Read echo_policy if present and map to enum
        // 2. Read thinking_tags if present and map to enum
        const ctx = self.ctx;
        const obj = self.export_obj;

        const echo_val = c.JS_GetPropertyStr(ctx, obj, "echo_policy");
        defer c.JS_FreeValue(ctx, echo_val);
        if (isString(echo_val)) {
            if (c.JS_ToCString(ctx, echo_val)) |cstr| {
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

        const tags_val = c.JS_GetPropertyStr(ctx, obj, "thinking_tags");
        defer c.JS_FreeValue(ctx, tags_val);
        if (isString(tags_val)) {
            if (c.JS_ToCString(ctx, tags_val)) |cstr| {
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
    }

    fn parseReasoningAndOptions(self: *JsProviderAdapter) !void {
        // PSEUDOCODE:
        // 1. Read reasoning_param & reasoning_field
        // 2. Read supports_stream_options & use_completion_tokens
        const ctx = self.ctx;
        const obj = self.export_obj;

        const param_val = c.JS_GetPropertyStr(ctx, obj, "reasoning_param");
        defer c.JS_FreeValue(ctx, param_val);
        if (isString(param_val)) {
            if (c.JS_ToCString(ctx, param_val)) |str| {
                defer c.JS_FreeCString(ctx, str);
                self.profile.reasoning_param = std.meta.stringToEnum(provider_mod.ReasoningParamFormat, std.mem.span(str)) orelse return error.InvalidReasoningParam;
            }
        }

        const rf_val = c.JS_GetPropertyStr(ctx, obj, "reasoning_field");
        defer c.JS_FreeValue(ctx, rf_val);
        if (isString(rf_val)) {
            if (c.JS_ToCString(ctx, rf_val)) |str| {
                defer c.JS_FreeCString(ctx, str);
                if (std.meta.stringToEnum(provider_mod.ReasoningField, std.mem.span(str))) |rf| {
                    self.profile.reasoning_field = rf;
                }
            }
        }

        const sso_val = c.JS_GetPropertyStr(ctx, obj, "supports_stream_options");
        defer c.JS_FreeValue(ctx, sso_val);
        if (isBoolean(sso_val)) {
            self.profile.supports_stream_options = (c.JS_ToBool(ctx, sso_val) != 0);
        }

        const uct_val = c.JS_GetPropertyStr(ctx, obj, "use_completion_tokens");
        defer c.JS_FreeValue(ctx, uct_val);
        if (isBoolean(uct_val)) {
            self.profile.use_completion_tokens = (c.JS_ToBool(ctx, uct_val) != 0);
        }
    }

    fn parseExportedHooks(self: *JsProviderAdapter) void {
        // PSEUDOCODE:
        // 1. Read extractReasoning, extractContent, and transformRequest functions
        const ctx = self.ctx;
        const obj = self.export_obj;

        const fn_er = c.JS_GetPropertyStr(ctx, obj, "extractReasoning");
        if (isFunction(ctx, fn_er)) {
            self.fn_extract_reasoning = fn_er;
        } else {
            c.JS_FreeValue(ctx, fn_er);
        }

        const fn_ec = c.JS_GetPropertyStr(ctx, obj, "extractContent");
        if (isFunction(ctx, fn_ec)) {
            self.fn_extract_content = fn_ec;
        } else {
            c.JS_FreeValue(ctx, fn_ec);
        }

        const fn_tr = c.JS_GetPropertyStr(ctx, obj, "transformRequest");
        if (isFunction(ctx, fn_tr)) {
            self.fn_transform_request = fn_tr;
        } else {
            c.JS_FreeValue(ctx, fn_tr);
        }

        const fn_gi = c.JS_GetPropertyStr(ctx, obj, "generateImage");
        if (isFunction(ctx, fn_gi)) {
            self.fn_generate_image = fn_gi;
        } else {
            c.JS_FreeValue(ctx, fn_gi);
        }

        const fn_gv = c.JS_GetPropertyStr(ctx, obj, "generateVideo");
        if (isFunction(ctx, fn_gv)) {
            self.fn_generate_video = fn_gv;
        } else {
            c.JS_FreeValue(ctx, fn_gv);
        }
    }

    fn parseExportedObject(self: *JsProviderAdapter) !void {
        // PSEUDOCODE:
        // 1. Parse name and protocol
        // 2. Parse policy and tags
        // 3. Parse reasoning params and stream options
        // 4. Parse custom JS hooks
        try self.parseNameAndProtocol();
        self.parsePolicyAndTags();
        try self.parseReasoningAndOptions();
        self.parseExportedHooks();
    }

    /// Parses a JSON buffer with QuickJS, ensuring null-termination as required by QuickJS.
    /// QuickJS requires `buf[buf_len] == 0`; passing a non-null-terminated slice causes
    /// QuickJS to read past buf_len and fail with SyntaxError on trailing bytes (e.g. 0xAA).
    fn parseJsonZeroTerminated(ctx: *c.JSContext, alloc: Allocator, json_bytes: []const u8, filename: [*:0]const u8) ?c.JSValue {
        const trimmed = std.mem.trim(u8, json_bytes, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] != '{') return null;

        var stack_buf: [4096]u8 = undefined;
        const val = if (trimmed.len < stack_buf.len) blk: {
            @memcpy(stack_buf[0..trimmed.len], trimmed);
            stack_buf[trimmed.len] = 0;
            break :blk c.JS_ParseJSON(ctx, &stack_buf, trimmed.len, filename);
        } else blk: {
            const z = alloc.dupeZ(u8, trimmed) catch return null;
            defer alloc.free(z);
            break :blk c.JS_ParseJSON(ctx, z.ptr, z.len, filename);
        };

        if (isException(val)) {
            const exc = c.JS_GetException(ctx);
            c.JS_FreeValue(ctx, exc);
            return null;
        }
        return val;
    }

    /// Extract reasoning tokens from raw SSE JSON chunk.
    /// Returns allocated slice owned by caller if reasoning was found, or null.
    pub fn extractReasoning(self: *JsProviderAdapter, alloc: Allocator, raw_chunk_json: []const u8) ?[]const u8 {
        self.beginCall();
        const fn_hook = self.fn_extract_reasoning orelse return null;
        if (raw_chunk_json.len == 0) return null;

        const chunk_val = parseJsonZeroTerminated(self.ctx, alloc, raw_chunk_json, "<chunk>") orelse return null;
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

        const chunk_val = parseJsonZeroTerminated(self.ctx, alloc, raw_chunk_json, "<chunk>") orelse return null;
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

        const req_val = parseJsonZeroTerminated(self.ctx, alloc, raw_request_json, "<req>") orelse return error.InvalidRequestJson;
        defer c.JS_FreeValue(self.ctx, req_val);

        var args = [_]c.JSValue{req_val};
        const ret_val = c.JS_Call(self.ctx, fn_hook, self.export_obj, 1, &args);
        defer c.JS_FreeValue(self.ctx, ret_val);

        if (isException(ret_val)) {
            logJsException(self.ctx, "transformRequest hook execution failed");
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

    /// Generate image via JS provider hook.
    /// Returns: JSON string with {path, media_type, bytes, width, height, ok, message}
    pub fn generateImage(self: *JsProviderAdapter, alloc: Allocator, input_json: []const u8) ![]const u8 {
        self.beginCall();
        const fn_hook = self.fn_generate_image orelse return error.NoGenerateImageHook;
        if (input_json.len == 0) return error.EmptyInput;

        const input_val = parseJsonZeroTerminated(self.ctx, alloc, input_json, "<image_input>") orelse return error.InvalidInputJson;
        defer c.JS_FreeValue(self.ctx, input_val);

        var args = [_]c.JSValue{input_val};
        const ret_val = c.JS_Call(self.ctx, fn_hook, self.export_obj, 1, &args);
        defer c.JS_FreeValue(self.ctx, ret_val);

        if (isException(ret_val)) {
            logJsException(self.ctx, "generateImage hook execution failed");
            return error.JsGenerateImageFailed;
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

        return error.JsGenerateImageFailed;
    }

    /// Generate video via JS provider hook.
    /// Returns: JSON string with {path, media_type, bytes, ok, message}
    pub fn generateVideo(self: *JsProviderAdapter, alloc: Allocator, input_json: []const u8) ![]const u8 {
        self.beginCall();
        const fn_hook = self.fn_generate_video orelse return error.NoGenerateVideoHook;
        if (input_json.len == 0) return error.EmptyInput;

        const input_val = parseJsonZeroTerminated(self.ctx, alloc, input_json, "<video_input>") orelse return error.InvalidInputJson;
        defer c.JS_FreeValue(self.ctx, input_val);

        var args = [_]c.JSValue{input_val};
        const ret_val = c.JS_Call(self.ctx, fn_hook, self.export_obj, 1, &args);
        defer c.JS_FreeValue(self.ctx, ret_val);

        if (isException(ret_val)) {
            logJsException(self.ctx, "generateVideo hook execution failed");
            return error.JsGenerateVideoFailed;
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

        return error.JsGenerateVideoFailed;
    }

    pub fn deinit(self: *JsProviderAdapter) void {
        const ctx = self.ctx;
        if (self.fn_extract_reasoning) |f| c.JS_FreeValue(ctx, f);
        if (self.fn_extract_content) |f| c.JS_FreeValue(ctx, f);
        if (self.fn_transform_request) |f| c.JS_FreeValue(ctx, f);
        if (self.fn_generate_image) |f| c.JS_FreeValue(ctx, f);
        if (self.fn_generate_video) |f| c.JS_FreeValue(ctx, f);
        c.JS_FreeValue(ctx, self.export_obj);

        c.JS_FreeContext(ctx);
        c.JS_FreeRuntime(self.rt);

        if (self.name_owned) |n| self.alloc.free(n);
        self.alloc.destroy(self);
    }
};
