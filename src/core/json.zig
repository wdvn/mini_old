//! json.zig — Lightweight JSON parsing and serialization utilities without external dependencies.
//!
//! Because mini-agent has no external JSON library dependencies, this module provides
//! simple scanning functions for JSON responses from AI backends and tool inputs.
//!
//! ## Limitations
//!   - Only handles flat/single-level JSON sufficient for API responses
//!   - Does not perform full JSON validation
//!   - Does not support unicode escapes (\uXXXX) in strings
//!
//! ## Key functions
//!   - `findString`  — find string value by key
//!   - `findObject`  — find object {} value by key
//!   - `findArray`   — find array [] value by key
//!   - `escape`      — escape a string to embed into JSON string
//!   - `unescape`    — unescape JSON string to plain text

const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Parsing helpers
// ---------------------------------------------------------------------------

/// Find string value of key in JSON object.
/// Returns slice pointing into `json` (not owned, no need to free).
/// Does not handle nested strings or duplicate keys.
///
/// Example:
/// ```
/// findString(`{"name":"bash","id":"1"}`, "name") == "bash"
/// findString(`{"x":42}`, "x") == null  // 42 is not a string
/// ```
pub fn findString(json: []const u8, key: []const u8) ?[]const u8 {
    var pattern_buf: [256]u8 = undefined;
    if (key.len + 4 > pattern_buf.len) return null;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\":", .{key}) catch return null;

    const start_idx = std.mem.indexOf(u8, json, pattern) orelse return null;
    var val_start = start_idx + pattern.len;

    // Skip whitespace after colon
    while (val_start < json.len and (json[val_start] == ' ' or json[val_start] == '\t' or json[val_start] == '\n')) : (val_start += 1) {}

    // Must start with double quote
    if (val_start >= json.len or json[val_start] != '"') return null;
    val_start += 1;

    // Scan for closing quote, handling backslash escapes
    var i = val_start;
    while (i < json.len) : (i += 1) {
        if (json[i] == '\\') {
            i += 1; // skip escaped char
            continue;
        }
        if (json[i] == '"') return json[val_start..i];
    }
    return null;
}

/// findString + unescape result. Returns owned memory (caller must free).
/// Fast path: string containing no backslashes is simply duplicated.
/// Used for all tool inputs containing user/LLM-controlled content
/// (shell commands, patterns, file contents...) — if raw findString is used,
/// JSON escape sequences (\" \\n \\t) would leak as literal characters,
/// distorting shell commands (e.g., creating stray files when redirect 2>&1 is misparsed).
pub fn findStringOwned(alloc: Allocator, json: []const u8, key: []const u8) !?[]u8 {
    const raw = findString(json, key) orelse return null;
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) {
        return try alloc.dupe(u8, raw);
    }
    return try unescape(alloc, raw);
}

/// Find object {} value of key in JSON.
/// Returns slice including `{` and `}` braces.
pub fn findObject(json: []const u8, key: []const u8) ?[]const u8 {
    var pattern_buf: [256]u8 = undefined;
    if (key.len + 4 > pattern_buf.len) return null;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\":", .{key}) catch return null;

    const kpos = std.mem.indexOf(u8, json, pattern) orelse return null;
    var i = kpos + pattern.len;

    // Skip whitespace
    while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n')) : (i += 1) {}
    if (i >= json.len or json[i] != '{') return null;

    const obj_start = i;
    var depth: i32 = 0;
    while (i < json.len) : (i += 1) {
        switch (json[i]) {
            '"' => {
                i += 1;
                while (i < json.len) : (i += 1) {
                    if (json[i] == '\\') {
                        i += 1;
                        continue;
                    }
                    if (json[i] == '"') break;
                }
            },
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return json[obj_start .. i + 1];
            },
            else => {},
        }
    }
    return null;
}

/// Find array [] value of key in JSON.
/// Returns slice including `[` and `]` brackets.
pub fn findArray(json: []const u8, key: []const u8) ?[]const u8 {
    var pattern_buf: [256]u8 = undefined;
    if (key.len + 4 > pattern_buf.len) return null;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\":", .{key}) catch return null;

    const kpos = std.mem.indexOf(u8, json, pattern) orelse return null;
    var i = kpos + pattern.len;

    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) : (i += 1) {}
    if (i >= json.len or json[i] != '[') return null;

    const arr_start = i;
    var depth: i32 = 0;
    while (i < json.len) : (i += 1) {
        switch (json[i]) {
            '"' => {
                i += 1;
                while (i < json.len) : (i += 1) {
                    if (json[i] == '\\') {
                        i += 1;
                        continue;
                    }
                    if (json[i] == '"') break;
                }
            },
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) return json[arr_start .. i + 1];
            },
            else => {},
        }
    }
    return null;
}

/// Check whether JSON contains key with boolean value `true`.
pub fn findBool(json: []const u8, key: []const u8) bool {
    var pattern_buf: [256]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\":true", .{key}) catch return false;
    return std.mem.indexOf(u8, json, pattern) != null;
}

/// Find integer value of key in JSON object.
pub fn findInt(json: []const u8, key: []const u8, comptime T: type) ?T {
    var pattern_buf: [256]u8 = undefined;
    if (key.len + 4 > pattern_buf.len) return null;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\":", .{key}) catch return null;

    const start_idx = std.mem.indexOf(u8, json, pattern) orelse return null;
    var val_start = start_idx + pattern.len;

    while (val_start < json.len and (json[val_start] == ' ' or json[val_start] == '\t' or json[val_start] == '\n' or json[val_start] == '\r')) : (val_start += 1) {}
    if (val_start >= json.len) return null;

    var val_end = val_start;
    if (val_end < json.len and (json[val_end] == '-' or json[val_end] == '+')) {
        val_end += 1;
    }
    while (val_end < json.len and std.ascii.isDigit(json[val_end])) : (val_end += 1) {}
    if (val_end == val_start) return null;

    return std.fmt.parseInt(T, json[val_start..val_end], 10) catch null;
}

test "findInt correctly parses integers from JSON" {
    const json_str = "{\"id\":123,\"prompt_tokens\":4500,\"negative\":-42,\"not_number\":\"hello\"}";
    try std.testing.expectEqual(@as(?u32, 123), findInt(json_str, "id", u32));
    try std.testing.expectEqual(@as(?u64, 4500), findInt(json_str, "prompt_tokens", u64));
    try std.testing.expectEqual(@as(?i32, -42), findInt(json_str, "negative", i32));
    try std.testing.expectEqual(@as(?u32, null), findInt(json_str, "not_number", u32));
    try std.testing.expectEqual(@as(?u32, null), findInt(json_str, "missing", u32));
}

test "findStringOwned correctly unescapes JSON string" {
    const alloc = std.testing.allocator;
    // Shell command containing quotes — must survive JSON round-trip intact
    const input = "{\"command\":\"grep -A 20 \\\"fail\\\\|error\\\" 2>&1\"}";
    const got = (try findStringOwned(alloc, input, "command")).?;
    defer alloc.free(got);
    try std.testing.expectEqualStrings("grep -A 20 \"fail\\|error\" 2>&1", got);

    // Fast path: no backslash -> only dupe
    const input2 = "{\"command\":\"ls -la\"}";
    const got2 = (try findStringOwned(alloc, input2, "command")).?;
    defer alloc.free(got2);
    try std.testing.expectEqualStrings("ls -la", got2);

    // Newline escape
    const input3 = "{\"body\":\"line1\\nline2\"}";
    const got3 = (try findStringOwned(alloc, input3, "body")).?;
    defer alloc.free(got3);
    try std.testing.expectEqualStrings("line1\nline2", got3);

    // Key does not exist
    const got4 = try findStringOwned(alloc, input2, "missing");
    try std.testing.expect(got4 == null);
}

test "Claude partial_json accumulated → unescape → findStringOwned works" {
    const alloc = std.testing.allocator;

    // Claude SSE sends partial_json chunks. findString returns raw slice (escaped).
    // Simulated: findString(data, "partial_json") returns each escaped chunk:
    //   chunk1: {\"comm       (from "partial_json":"{\"comm")
    //   chunk2: and\":\"ls\"}  (from "partial_json":"and\":\"ls\"}")
    // Accumulated: {\"command\":\"ls\"}
    const accumulated_escaped = "{\\\"command\\\":\\\"ls\\\"}";

    // After unescape (at content_block_stop) -> standard input_json
    const input_json = try unescape(alloc, accumulated_escaped);
    defer alloc.free(input_json);
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", input_json);

    // Verify: findStringOwned on unescaped input_json -> extracts cleanly
    const cmd = (try findStringOwned(alloc, input_json, "command")).?;
    defer alloc.free(cmd);
    try std.testing.expectEqualStrings("ls", cmd);
}

// ---------------------------------------------------------------------------
// Building helpers
// ---------------------------------------------------------------------------

/// Re-serialize raw JSON text into valid wire-format.
///
/// When `input_json` has been unescaped (by `std.json.parseFromSlice` or
/// `findStringOwned`), inner string values may contain raw control
/// chars (newline 0x0A, tab 0x09...) that break JSON wire format.
///
/// This function walks the JSON, tracks in/out string state, and:
///   - Outside strings: keeps intact (structural chars `{` `}` `[` `]` `:` `,` `"`)
///   - Inside strings: re-escapes control chars (`\n` → `\\n`, `\t` → `\\t`...)
///     while preserving existing escape sequences (such as `\\`, `\"`)
///
/// Caller must free result.
pub fn reserializeJson(alloc: Allocator, raw: []const u8) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(alloc);

    var in_string = false;
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (in_string) {
            if (c == '\\' and i + 1 < raw.len) {
                // Existing escape sequence — preserve (\\, \", \n, \t, \uXXXX...)
                try buf.append(alloc, c);
                i += 1;
                try buf.append(alloc, raw[i]);
                i += 1;
                continue;
            }
            if (c == '"') {
                // Closing string quote
                try buf.append(alloc, c);
                in_string = false;
                i += 1;
                continue;
            }
            // Character inside string — re-escape control chars
            switch (c) {
                '\n' => try buf.appendSlice(alloc, "\\n"),
                '\r' => try buf.appendSlice(alloc, "\\r"),
                '\t' => try buf.appendSlice(alloc, "\\t"),
                0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                    var tmp: [8]u8 = undefined;
                    const s = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch continue;
                    try buf.appendSlice(alloc, s);
                },
                else => try buf.append(alloc, c),
            }
            i += 1;
        } else {
            // Outside string — preserve all structural characters
            if (c == '"') {
                in_string = true;
            }
            try buf.append(alloc, c);
            i += 1;
        }
    }
    return buf.toOwnedSlice(alloc);
}

test "reserializeJson: basic" {
    const alloc = std.testing.allocator;

    // JSON object without control chars — preserve unchanged
    const simple = "{\"command\":\"ls\"}";
    const r1 = try reserializeJson(alloc, simple);
    defer alloc.free(r1);
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", r1);
}

test "reserializeJson: raw newline in string value" {
    const alloc = std.testing.allocator;

    // Raw newline (0x0A) inside string → re-escape to \\n
    const input = "{\"prompt\":\"Line 1\nLine 2\"}";
    const r = try reserializeJson(alloc, input);
    defer alloc.free(r);
    try std.testing.expectEqualStrings("{\"prompt\":\"Line 1\\nLine 2\"}", r);
}

test "reserializeJson: preserve existing escape sequences" {
    const alloc = std.testing.allocator;

    // \\n already escaped (2 chars: \ + n) → preserve unchanged
    const input = "{\"prompt\":\"hello\\nworld\"}";
    const r = try reserializeJson(alloc, input);
    defer alloc.free(r);
    try std.testing.expectEqualStrings("{\"prompt\":\"hello\\nworld\"}", r);
}

test "reserializeJson: raw tab + nested object" {
    const alloc = std.testing.allocator;

    const input = "{\"a\":\"x\ty\",\"b\":{\"c\":\"ok\"}}";
    const r = try reserializeJson(alloc, input);
    defer alloc.free(r);
    try std.testing.expectEqualStrings("{\"a\":\"x\\ty\",\"b\":{\"c\":\"ok\"}}", r);
}

/// Escape a string to embed into a JSON string.
///
/// Sanitize UTF-8: invalid bytes (truncated sequences, dangling continuation
/// bytes...) are replaced with U+FFFD (REPLACEMENT CHARACTER) so the body sent
/// to backend is always valid JSON/UTF-8. Without sanitization, the server may
/// reject the request with misleading errors (e.g. "missing model" HTTP 400).
/// Caller must free result.
fn sanitizeMultibyte(alloc: Allocator, buf: *std.ArrayListUnmanaged(u8), s: []const u8, i: *usize, pending: *usize) !void {
    if (pending.* > 0) {
        try appendEscaped(alloc, buf, s[i.* - pending.* .. i.*]);
        pending.* = 0;
    }
    const b = s[i.*];
    const seq_len = std.unicode.utf8ByteSequenceLength(b) catch {
        try buf.appendSlice(alloc, "\u{FFFD}");
        i.* += 1;
        return;
    };
    if (i.* + seq_len > s.len) {
        try buf.appendSlice(alloc, "\u{FFFD}");
        i.* = s.len;
        return;
    }
    if (std.unicode.utf8Decode(s[i.* .. i.* + seq_len])) |_| {
        try buf.appendSlice(alloc, s[i.* .. i.* + seq_len]);
        i.* += seq_len;
    } else |_| {
        try buf.appendSlice(alloc, "\u{FFFD}");
        var j = i.* + 1;
        while (j < s.len and (s[j] & 0xC0) == 0x80) : (j += 1) {}
        i.* = j;
    }
}

pub fn escape(alloc: Allocator, s: []const u8) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(alloc);

    // Fast path: valid UTF-8 string only needs normal escaping.
    if (std.unicode.utf8ValidateSlice(s)) {
        try appendEscaped(alloc, &buf, s);
        return buf.toOwnedSlice(alloc);
    }

    // Sanitize path: decode each codepoint, invalid bytes → U+FFFD.
    var i: usize = 0;
    var pending: usize = 0;
    while (i < s.len) {
        if (s[i] < 0x80) {
            i += 1;
            pending += 1;
        } else {
            try sanitizeMultibyte(alloc, &buf, s, &i, &pending);
        }
    }
    if (pending > 0) {
        try appendEscaped(alloc, &buf, s[s.len - pending ..]);
    }
    return buf.toOwnedSlice(alloc);
}

/// Escape string guaranteed to be valid UTF-8 (no extra sanitization).
fn appendEscaped(alloc: Allocator, buf: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                var tmp: [8]u8 = undefined;
                const s2 = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch continue;
                try buf.appendSlice(alloc, s2);
            },
            else => try buf.append(alloc, c),
        }
    }
}

/// Unescape a JSON string (content inside double quotes).
/// Caller must free result.
fn appendUnicodeEscape(alloc: Allocator, buf: *std.ArrayListUnmanaged(u8), s: []const u8, i: *usize) !void {
    if (i.* + 4 >= s.len) {
        try buf.appendSlice(alloc, "\\u");
        return;
    }
    const hex1 = s[i.* + 1 .. i.* + 5];
    const cp1 = std.fmt.parseInt(u21, hex1, 16) catch {
        try buf.appendSlice(alloc, "\\u");
        return;
    };
    i.* += 4;
    var codepoint: u21 = cp1;
    if (cp1 >= 0xD800 and cp1 <= 0xDBFF and i.* + 6 < s.len and s[i.* + 1] == '\\' and s[i.* + 2] == 'u') {
        const hex2 = s[i.* + 3 .. i.* + 7];
        if (std.fmt.parseInt(u21, hex2, 16)) |cp2| {
            if (cp2 >= 0xDC00 and cp2 <= 0xDFFF) {
                codepoint = 0x10000 + (((cp1 - 0xD800) << 10) | (cp2 - 0xDC00));
                i.* += 6;
            }
        } else |_| {}
    }
    var utf8_buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch 0;
    if (len > 0) {
        try buf.appendSlice(alloc, utf8_buf[0..len]);
    } else {
        try buf.appendSlice(alloc, "\\u");
    }
}

pub fn unescape(alloc: Allocator, s: []const u8) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            switch (s[i]) {
                '"' => try buf.append(alloc, '"'),
                '\\' => try buf.append(alloc, '\\'),
                'n' => try buf.append(alloc, '\n'),
                'r' => try buf.append(alloc, '\r'),
                't' => try buf.append(alloc, '\t'),
                'u' => try appendUnicodeEscape(alloc, &buf, s, &i),
                else => {
                    try buf.append(alloc, '\\');
                    try buf.append(alloc, s[i]);
                },
            }
        } else {
            try buf.append(alloc, s[i]);
        }
    }
    return buf.toOwnedSlice(alloc);
}

test "escape preserves valid ASCII/UTF-8 string" {
    const alloc = std.testing.allocator;
    const got = try escape(alloc, "grep -A 20 \"fail\\|error\"\nline2\ttab");
    defer alloc.free(got);
    try std.testing.expectEqualStrings("grep -A 20 \\\"fail\\\\|error\\\"\\nline2\\ttab", got);

    // Multibyte valid UTF-8 — must preserve each byte
    const got2 = try escape(alloc, "đường dẫn /tmp — ok");
    defer alloc.free(got2);
    try std.testing.expectEqualStrings("đường dẫn /tmp — ok", got2);
}

test "escape replaces invalid UTF-8 bytes with U+FFFD" {
    const alloc = std.testing.allocator;

    // 3-byte sequence truncated at string end (e.g. truncated tool output)
    const trunc = "ok\xe2\x80";
    const got = try escape(alloc, trunc);
    defer alloc.free(got);
    try std.testing.expectEqualStrings("ok\u{FFFD}", got);

    // Dangling continuation byte in the middle of valid string
    const dangling = "a\xc3\xa9\xffb";
    const got2 = try escape(alloc, dangling);
    defer alloc.free(got2);
    // \xc3\xa9 = 'é' valid and preserved; \xff corrupted → U+FFFD
    try std.testing.expectEqualStrings("aé\u{FFFD}b", got2);

    // Escape still works after sanitize: quote preceding invalid byte
    const mixed = "\"quo\"\x80tail";
    const got3 = try escape(alloc, mixed);
    defer alloc.free(got3);
    try std.testing.expectEqualStrings("\\\"quo\\\"\u{FFFD}tail", got3);
}

/// Pretty-print indentation (2 spaces) for JSON string.
/// Supports object {}, array [], and strings with escaped special characters.
/// Returns newly allocated string via `alloc` (owned by caller).
/// If string is not JSON (does not start with { or [), returns unmodified dupe.
fn appendIndent(alloc: Allocator, out: *std.ArrayListUnmanaged(u8), level: usize) !void {
    try out.append(alloc, '\n');
    try out.appendNTimes(alloc, ' ', level * 2);
}

fn handlePrettyOpenBracket(
    alloc: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    trimmed: []const u8,
    i: *usize,
    c: u8,
    indent_level: *usize,
) !void {
    try out.append(alloc, c);
    var next_idx = i.* + 1;
    while (next_idx < trimmed.len and (trimmed[next_idx] == ' ' or trimmed[next_idx] == '\t' or trimmed[next_idx] == '\r' or trimmed[next_idx] == '\n')) : (next_idx += 1) {}
    const closing_char: u8 = if (c == '{') '}' else ']';
    if (next_idx < trimmed.len and trimmed[next_idx] == closing_char) {
        try out.append(alloc, closing_char);
        i.* = next_idx;
    } else {
        indent_level.* += 1;
        try appendIndent(alloc, out, indent_level.*);
    }
}

fn handlePrettyStringChar(alloc: Allocator, out: *std.ArrayListUnmanaged(u8), c: u8, in_str: *bool, is_escape: *bool) !void {
    try out.append(alloc, c);
    if (is_escape.*) {
        is_escape.* = false;
    } else if (c == '\\') {
        is_escape.* = true;
    } else if (c == '"') {
        in_str.* = false;
    }
}

fn handlePrettyCloseBracket(alloc: Allocator, out: *std.ArrayListUnmanaged(u8), c: u8, indent_level: *usize) !void {
    if (indent_level.* > 0) indent_level.* -= 1;
    try appendIndent(alloc, out, indent_level.*);
    try out.append(alloc, c);
}

pub fn prettyPrint(alloc: Allocator, raw_json: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw_json, " \t\r\n");
    if (trimmed.len == 0 or (trimmed[0] != '{' and trimmed[0] != '[')) {
        return try alloc.dupe(u8, raw_json);
    }

    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(alloc);

    var indent_level: usize = 0;
    var in_str = false;
    var is_escape = false;
    var i: usize = 0;

    while (i < trimmed.len) : (i += 1) {
        const c = trimmed[i];

        if (in_str) {
            try handlePrettyStringChar(alloc, &out, c, &in_str, &is_escape);
            continue;
        }

        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') continue;

        switch (c) {
            '"' => {
                in_str = true;
                is_escape = false;
                try out.append(alloc, c);
            },
            '{', '[' => try handlePrettyOpenBracket(alloc, &out, trimmed, &i, c, &indent_level),
            '}', ']' => try handlePrettyCloseBracket(alloc, &out, c, &indent_level),
            ',' => {
                try out.append(alloc, c);
                try appendIndent(alloc, &out, indent_level);
            },
            ':' => try out.appendSlice(alloc, ": "),
            else => try out.append(alloc, c),
        }
    }

    return out.toOwnedSlice(alloc);
}

test "prettyPrint formats JSON object and array correctly" {
    const alloc = std.testing.allocator;
    const raw = "{\"error\":{\"code\":429,\"message\":\"Rate limit: try again, please\"},\"tags\":[\"a\",\"b\"],\"empty\":{}}";
    const formatted = try prettyPrint(alloc, raw);
    defer alloc.free(formatted);

    const expected =
        \\{
        \\  "error": {
        \\    "code": 429,
        \\    "message": "Rate limit: try again, please"
        \\  },
        \\  "tags": [
        \\    "a",
        \\    "b"
        \\  ],
        \\  "empty": {}
        \\}
    ;
    try std.testing.expectEqualStrings(expected, formatted);
}
