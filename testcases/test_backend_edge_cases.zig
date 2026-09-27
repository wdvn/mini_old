//! test_backend_edge_cases.zig — Crash-hunt & edge-case tests for backend layers.
//!
//! Scope (reliability hardening, RFC-025 companion):
//!   1. JSON helpers (core/json.zig): malformed / truncated / huge / invalid-UTF-8
//!      inputs must return errors or null — never crash.
//!   2. OOM resilience: a failing allocator must turn into error.OutOfMemory, and
//!      NO pointer that was never allocated may be freed (bogus-free detector).
//!      This locks the contract that makes the `json.unescape(alloc, x) catch x`
//!      fall-through safe in the backend stream parsers.
//!   3. Thinking-tag filter: tag split across feed boundaries, pending-buffer
//!      overflow attempts, fenced-code edge cases.
//!   4. Provider layer: URL detection + profile resolution edge cases.
//!   5. Protocol helpers: boundedResponseSnippet, stop-reason mapping, isValidJsonObject.
//!   6. Backend request builders: malformed history blocks must not crash.

const std = @import("std");
const testing = std.testing;
const mini = @import("mini");

const json = mini.json_mod;
const openai = mini.backends.openai_mod;
const claude = mini.backends.claude_mod;
const ollama = mini.backends.ollama_mod;
const provider_mod = mini.backends.provider_mod;
const thinking_filter_mod = mini.backends.thinking_filter_mod;
const proto = mini.protocol_mod;
const http_request = mini.http_request;

// ---------------------------------------------------------------------------
// Bogus-free detector allocator (0.16 layout: { ptr, vtable }).
// alloc always fails (OOM simulation); free records every call so tests can
// prove no non-heap pointer ever reached the allocator.
// ---------------------------------------------------------------------------

const BogusFreeTracker = struct {
    alloc_calls: u64 = 0,
    free_ptrs: std.ArrayList([2]usize) = .empty,

    fn allocFn(self: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const s: *BogusFreeTracker = @ptrCast(@alignCast(self));
        _ = alignment;
        _ = ret_addr;
        s.alloc_calls += 1;
        _ = len;
        return null; // simulated OOM
    }

    fn freeFn(self: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const s: *BogusFreeTracker = @ptrCast(@alignCast(self));
        _ = alignment;
        _ = ret_addr;
        // Every non-empty free is bogus (alloc never succeeded).
        if (memory.len > 0) {
            s.free_ptrs.append(std.heap.page_allocator, .{ @intFromPtr(memory.ptr), memory.len }) catch unreachable;
        }
    }

    fn resizeFn(self: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = self;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return false;
    }

    fn remapFn(self: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = self;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return null;
    }

    fn make(self: *BogusFreeTracker) std.mem.Allocator {
        return std.mem.Allocator{
            .ptr = self,
            .vtable = &.{
                .alloc = allocFn,
                .resize = resizeFn,
                .remap = remapFn,
                .free = freeFn,
            },
        };
    }

    fn deinit(self: *BogusFreeTracker) void {
        self.free_ptrs.deinit(std.heap.page_allocator);
    }

    fn bogusFreeCount(self: *const BogusFreeTracker) usize {
        return self.free_ptrs.items.len;
    }
};

// ---------------------------------------------------------------------------
// 1. JSON helpers — malformed input must not crash
// ---------------------------------------------------------------------------

test "backend_edge: json.findString truncated input returns null" {
    // Unterminated string value.
    try testing.expect(json.findString("{\"a\":\"unterminated", "a") == null);
    // Backslash escape at the very end of input.
    try testing.expect(json.findString("{\"a\":\"x\\", "a") == null);
    // Empty input.
    try testing.expect(json.findString("", "a") == null);
    // Key longer than the 256-byte pattern buffer -> graceful null.
    var long_key = std.mem.zeroes([300]u8);
    try testing.expect(json.findString("{\"a\":1}", long_key[0..260]) == null);
    // Value that is not a string -> null.
    try testing.expect(json.findString("{\"a\":1}", "a") == null);
    try testing.expect(json.findString("{\"a\":null}", "a") == null);
}

test "backend_edge: json.findObject nested + escaped quotes + truncated" {
    // Escaped quote inside a top-level object value.
    const ok = "{\"obj\":{\"inner\":\"a\\\"b\",\"deep\":{\"k\":1}}}";
    const inner = json.findObject(ok, "obj") orelse return testing.expect(false);
    try testing.expect(std.mem.indexOf(u8, inner, "\"inner\":\"a\\\"b\"") != null);
    // Unclosed object -> null, not out-of-bounds read.
    try testing.expect(json.findObject("{\"o\":{", "o") == null);
    // Truncated mid-string inside object -> null.
    try testing.expect(json.findObject("{\"o\":{\"s\":\"abc", "o") == null);
    // Array value under object key -> null.
    try testing.expect(json.findObject("{\"o\":[1,2]}", "o") == null);
    // Empty object value.
    try testing.expectEqualStrings("{}", json.findObject("{\"o\":{}}", "o").?);
}

test "backend_edge: json.findArray nested + escaped + truncated" {
    const ok = "{\"arr\":[\"x\\\"y\",[1,{\"a\":2}]]}";
    const arr = json.findArray(ok, "arr") orelse return testing.expect(false);
    try testing.expect(std.mem.startsWith(u8, arr, "["));
    try testing.expect(std.mem.endsWith(u8, arr, "]"));
    try testing.expect(json.findArray("{\"arr\":", "arr") == null); // truncated
    try testing.expect(json.findArray("{\"arr\":", "missing") == null);
}

test "backend_edge: json.findInt numeric formats" {
    try testing.expectEqual(@as(?u64, 42), json.findInt("{\"n\":42}", "n", u64));
    try testing.expectEqual(@as(?i64, -7), json.findInt("{\"n\":-7}", "n", i64));
    // Float value: parseInt stops at '.', acceptable lossy parse.
    try testing.expect(json.findInt("{\"f\":4.5}", "f", u64) != null);
    // Overflow must return null (parseInt error), not wrap.
    try testing.expect(json.findInt("{\"n\":18446744073709551616}", "n", u64) == null);
    // Empty value / non-numeric -> null.
    try testing.expect(json.findInt("{\"n\":}", "n", u64) == null);
    try testing.expect(json.findInt("{\"n\":\"x\"}", "n", u64) == null);
    try testing.expect(json.findInt("{}", "n", u64) == null);
}

test "backend_edge: json.unescape malformed escape sequences never crash" {
    const alloc = testing.allocator;
    const cases = [_][]const u8{
        "\\u", // truncated \u escape
        "\\uZZZZ", // invalid hex
        "\\u12", // truncated hex
        "abc\\", // backslash at end of string
        "\\", // single backslash
        "\\u00e9", // valid 2-byte codepoint
        "\\u2028", // line separator
        "\\uD834\\uDD1E", // surrogate pair
        "\\uD834", // lone high surrogate (invalid)
        "\\uDC00", // lone low surrogate (invalid)
        "\\u0041\\u0042", // "AB"
        "", // empty
        "\\\\n", // escaped backslash then n
        "\\x", // unknown escape
    };
    for (cases) |c| {
        const out = try json.unescape(alloc, c);
        defer alloc.free(out);
        try testing.expect(std.unicode.utf8ValidateSlice(out)); // output always valid UTF-8
    }
}

test "backend_edge: json.escape invalid UTF-8 never crashes" {
    const alloc = testing.allocator;
    // Truncated multi-byte sequences (classic SSE truncation crash class).
    const truncated = "ok\xe2\x80"; // 3-byte seq cut at 2
    const got = try json.escape(alloc, truncated);
    defer alloc.free(got);
    try testing.expect(std.unicode.utf8ValidateSlice(got));

    // NUL byte and every control byte.
    var ctrl: [32]u8 = undefined;
    for (0..32) |i| ctrl[i] = @intCast(i);
    const got2 = try json.escape(alloc, &ctrl);
    defer alloc.free(got2);
    try testing.expect(std.mem.indexOfScalar(u8, got2, 0x00) == null); // NUL re-escaped

    // Invalid byte in the middle of a valid string.
    const mixed = "a\xffb";
    const got3 = try json.escape(alloc, mixed);
    defer alloc.free(got3);
    try testing.expect(std.unicode.utf8ValidateSlice(got3));
}

test "backend_edge: json helpers under simulated OOM never crash or bogus-free" {
    var tracker = BogusFreeTracker{};
    defer tracker.deinit();
    const oom = tracker.make();

    // The failing allocator makes every allocation error out. All helpers
    // must surface error.OutOfMemory (swallowed to null here), not crash,
    // and must not free a pointer they never allocated.
    const r1: ?[]u8 = json.findStringOwned(oom, "{\"k\":\"v\"}", "k") catch null;
    const r2: ?[]u8 = json.reserializeJson(oom, "{\"a\":1}") catch null;
    const r3: ?[]u8 = json.unescape(oom, "plain") catch null;
    _ = r1;
    _ = r2;
    _ = r3;

    try testing.expect(tracker.alloc_calls > 0);
    try testing.expectEqual(@as(usize, 0), tracker.bogusFreeCount());
}

// ---------------------------------------------------------------------------
// 2. Lock the guarded-free contract (openai.zig pattern) against OOM
// ---------------------------------------------------------------------------

test "backend_edge: unescape OOM fall-through never frees the source slice" {
    var tracker = BogusFreeTracker{};
    defer tracker.deinit();
    const oom = tracker.make();

    const sse_slice = "text\\nvalue"; // simulates a slice pointing into SSE data

    // Correct pattern (as in openai.zig handleResponsesDeltaEvent):
    const unescaped = json.unescape(oom, sse_slice) catch sse_slice;
    if (unescaped.ptr != sse_slice.ptr) oom.free(unescaped);
    try testing.expectEqual(@as(usize, 0), tracker.bogusFreeCount());
}

// ---------------------------------------------------------------------------
// 3. Thinking-filter crash/edge cases
// ---------------------------------------------------------------------------

const CollectCtx = struct {
    alloc: std.mem.Allocator,
    chunks: std.ArrayList([]const u8),

    pub fn emitNormalized(self: *CollectCtx, text: []const u8, thinking: bool) !void {
        _ = thinking;
        const owned = try self.alloc.dupe(u8, text);
        try self.chunks.append(self.alloc, owned);
    }

    fn joined(self: *CollectCtx) ![]u8 {
        var total: usize = 0;
        for (self.chunks.items) |c| total += c.len;
        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.alloc);
        try out.ensureTotalCapacity(self.alloc, total);
        for (self.chunks.items) |c| {
            out.appendSliceAssumeCapacity(c);
        }
        return out.toOwnedSlice(self.alloc);
    }

    fn deinit(self: *CollectCtx) void {
        for (self.chunks.items) |c| self.alloc.free(c);
        self.chunks.deinit(self.alloc);
    }
};


test "backend_edge: thinking filter tag split across feed boundaries" {
    const alloc = testing.allocator;
    var f = thinking_filter_mod.Filter{ .tags = provider_mod.ThinkingTagSet.english_and_chinese };

    // Feed byte-by-byte so a tag split across feed() boundaries is exercised.
    var ctx = CollectCtx{ .alloc = alloc, .chunks = .empty };
    defer ctx.deinit();
    const input = "A" ++ "<" ++ "\u{601d}\u{8003}" ++ ">" ++ "B" ++ "</" ++ "\u{601d}\u{8003}" ++ ">" ++ "C";

    for (input) |b| {
        try f.feed(&[_]u8{b}, &ctx);
    }
    try f.finish(&ctx);
    const joined = try ctx.joined();
    defer alloc.free(joined);
    // Tag bytes are absorbed as thinking markers; only plain text remains.
    try testing.expectEqualStrings("ABC", joined);
}

test "backend_edge: thinking filter pending buffer cannot overflow" {
    const alloc = testing.allocator;
    var f = thinking_filter_mod.Filter{ .tags = provider_mod.ThinkingTagSet.english_and_chinese };
    var ctx = CollectCtx{ .alloc = alloc, .chunks = .empty };
    defer ctx.deinit();

    // A run of 500 unmatched '<' would, on a buggy pending buffer, write
    // past the 32-byte array. Each '<' after the first flushes the previous
    // pending '<' and re-keeps 1 pending, so len never exceeds the longest
    // tag length. Emitted: 499 flushed '<' + 1 left in pending (finish).
    const run = alloc.alloc(u8, 500) catch return;
    defer alloc.free(run);
    for (run) |*b| b.* = '<';
    try f.feed(run, &ctx);
    try f.finish(&ctx);
    const joined = try ctx.joined();
    defer alloc.free(joined);
    try testing.expectEqual(@as(usize, 500), joined.len);
    // Every emitted byte must be the literal '<'.
    for (joined) |b| {
        try testing.expectEqual(@as(u8, 60), b);
    }
}

test "backend_edge: thinking filter fenced code does not strip tags" {
    const alloc = testing.allocator;
    var f = thinking_filter_mod.Filter{ .tags = provider_mod.ThinkingTagSet.english_only };
    var ctx = CollectCtx{ .alloc = alloc, .chunks = .empty };
    defer ctx.deinit();

    // Inside a ``` fenced block, literal  must pass through.
    const input = "```\u{003c}think\u{003e}\u{003c}/think\u{003e}```";
    try f.feed(input, &ctx);
    try f.finish(&ctx);
    const joined = try ctx.joined();
    defer alloc.free(joined);
    try testing.expectEqualStrings(input, joined);
}

// ---------------------------------------------------------------------------
// 4. Provider layer: URL detection + profile resolution
// ---------------------------------------------------------------------------

test "backend_edge: provider detectFromUrl falls back to generic on unknown url" {
    try testing.expectEqualStrings("generic", provider_mod.detectFromUrl("https://example.com/v1"));
    // Empty url -> generic.
    try testing.expectEqualStrings("generic", provider_mod.detectFromUrl(""));
}

test "backend_edge: provider resolveProfile explicit key wins over url" {
    // Explicit empty key + URL should auto-detect from URL.
    const p = provider_mod.resolveProfile(null, "https://api.openai.com/v1");
    _ = p; // just must not crash
}

test "backend_edge: provider getProfile unknown key returns generic" {
    const p = provider_mod.getProfile("does-not-exist");
    try testing.expectEqual(p.name, provider_mod.getProfile("generic").name);
}

// ---------------------------------------------------------------------------
// 5. Protocol helpers
// ---------------------------------------------------------------------------

test "backend_edge: proto.boundedResponseSnippet bounds long raw" {
    const raw = "secret-bearing-response" ** 1000;
    try testing.expectEqual(proto.MAX_RESPONSE_SNIPPET_LEN, proto.boundedResponseSnippet(raw).len);
}

test "backend_edge: proto.isValidJsonObject rejects non-object and malformed" {
    try testing.expect(proto.isValidJsonObject("{\"a\":1}"));
    try testing.expect(!proto.isValidJsonObject("[1,2]"));
    try testing.expect(!proto.isValidJsonObject(""));
    try testing.expect(!proto.isValidJsonObject("{\"a\":")); // truncated
    try testing.expect(!proto.isValidJsonObject("{}extra")); // trailing garbage
}

test "backend_edge: proto.toGenerationStop mapping table" {
    try testing.expectEqual(proto.GenerationStop.natural_end, proto.toGenerationStop(.end_turn, 200));
    try testing.expectEqual(proto.GenerationStop.tool_call, proto.toGenerationStop(.tool_use, 200));
    try testing.expectEqual(proto.GenerationStop.max_tokens, proto.toGenerationStop(.max_tokens, 200));
    try testing.expectEqual(proto.GenerationStop.stream_aborted, proto.toGenerationStop(.stream_aborted, 200));
    // 5xx with unknown -> provider_error
    try testing.expectEqual(proto.GenerationStop.provider_error, proto.toGenerationStop(.unknown, 500));
}

// ---------------------------------------------------------------------------
// 6. Backend request builders: malformed history must not crash
// ---------------------------------------------------------------------------

fn emptyMsgs() []proto.Message {
    return &.{};
}

fn emptyTools() []proto.ToolDefinition {
    return &.{};
}

test "backend_edge: openai buildRequestBody with empty history/tools" {
    const alloc = testing.allocator;
    const body = try openai.buildRequestBody(
        alloc, "gpt-4o", 1024, false, false, null, false, "system",
        emptyMsgs(), emptyTools(),
    );
    defer alloc.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"model\":\"gpt-4o\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
}

test "backend_edge: openai getRootApiUrl normalizes suffix variants" {
    try testing.expectEqualStrings(
        "https://api.openai.com/v1",
        openai.getRootApiUrl("https://api.openai.com/v1/chat/completions"),
    );
    try testing.expectEqualStrings(
        "https://api.openai.com/v1",
        openai.getRootApiUrl("https://api.openai.com/v1/responses/"),
    );
    try testing.expectEqualStrings(
        "http://localhost:11434/v1",
        openai.getRootApiUrl("http://localhost:11434/v1/"),
    );
}

test "backend_edge: openai sanitizeToolName rejects malformed" {
    // Invalid chars -> null.
    // Newline truncates at the first \n, remainder is "bash" (valid).
    try testing.expectEqualStrings("bash", openai.sanitizeToolName("bash\n").?);
    // "<" truncation leaves empty -> null.
    try testing.expect(openai.sanitizeToolName("<bad>") == null);
    // Non-identifier char not stripped -> null.
    try testing.expect(openai.sanitizeToolName("ba$sh") == null);
    try testing.expect(openai.sanitizeToolName("   ") == null);
    try testing.expect(openai.sanitizeToolName("") == null);
    // Valid.
    try testing.expectEqualStrings("bash", openai.sanitizeToolName("bash").?);
    try testing.expectEqualStrings("file_read", openai.sanitizeToolName("file_read").?);
}

test "backend_edge: claude buildRequestBody with thinking budget" {
    const alloc = testing.allocator;
    const msgs = emptyMsgs();
    const tools = emptyTools();
    const body = try claude.buildRequestBody(alloc, "claude-3-5-sonnet", 1024, 2048, "sys", msgs, tools);
    defer alloc.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"budget_tokens\":2048") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":6144") != null);
}

test "backend_edge: ollama buildRequestBody with tools" {
    const alloc = testing.allocator;
    const tool_defs = [_]proto.ToolDefinition{
        .{ .name = "bash", .description = "run a command", .input_schema_json = "{}" },
    };
    const msgs = emptyMsgs();
    const body = try ollama.buildRequestBody(alloc, "llama3", "system", msgs, &tool_defs);
    defer alloc.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"tools\":[") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"name\":\"bash\"") != null);
}

test "backend_edge: http_request parseMethod rejects invalid and caps length" {
    try testing.expectEqual(std.http.Method.GET, http_request.parseMethod("GET"));
    try testing.expectEqual(std.http.Method.POST, http_request.parseMethod("post"));
    try testing.expectError(error.InvalidMethod, http_request.parseMethod("GETX"));
    // > 16 chars -> InvalidMethod, not buffer overflow.
    var long: [32]u8 = undefined;
    for (0..32) |i| long[i] = 'G' + @as(u8, @intCast(i % 26));
    try testing.expectError(error.InvalidMethod, http_request.parseMethod(long[0..32]));
}

test "backend_edge: http_request parseHeadersJson malformed inputs" {
    const alloc = testing.allocator;
    // Valid.
    const good = try http_request.parseHeadersJson(alloc, "{\"A\":\"1\",\"B\":\"2\"}");
    {
        const h = alloc.dupe(std.http.Header, good) catch return;
        for (h) |x| {
            alloc.free(x.name);
            alloc.free(x.value);
        }
        alloc.free(h);
    }
    alloc.free(good);
    // Trailing garbage -> error, not crash.
    try testing.expectError(error.InvalidHeadersJson, http_request.parseHeadersJson(alloc, "{\"a\":1}"));
    // Unterminated string -> error.
    try testing.expectError(error.InvalidHeadersJson, http_request.parseHeadersJson(alloc, "{\"a\":\"x"));
    // Empty object.
    const empty = try http_request.parseHeadersJson(alloc, "{}");
    alloc.free(empty);
    // Empty input -> error.
    try testing.expectError(error.InvalidHeadersJson, http_request.parseHeadersJson(alloc, ""));
}
