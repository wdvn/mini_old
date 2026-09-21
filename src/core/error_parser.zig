//! error_parser.zig — Shared provider error parsing for tools and backends.
//!
//! Normalizes error responses across providers (AgnesAI, OpenAI, Anthropic)
//! into a common structured format so callers (tools, backends, UI) can
//! surface meaningful messages to users and debug tools.
//!
//! Supports three error envelope formats:
//!   - AgnesAI:  {"error":{"code":"<code>","message":"<msg>","type":"AgnesAI_error"}}
//!   - OpenAI:   {"error":{"code":"<code>","message":"<msg>","type":"<type>"}}
//!   - Anthropic:{"type":"error","error":{"type":"<type>","message":"<msg>"}}
//!
//! Also supports legacy/top-level fallbacks:
//!   - Top-level "message" or "error.message"
//!   - Raw body snippet (truncated) when no parseable structure found.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("json.zig");

/// Parsed error details extracted from an HTTP error response.
pub const ErrorInfo = struct {
    /// HTTP status code.
    http_code: u16,
    /// Provider-specific error code (e.g. "video_queue_full", "model_not_found").
    code: ?[]const u8 = null,
    /// Human-readable error message.
    message: []const u8,
    /// Raw error body snippet (truncated), for debugging.
    raw_snippet: ?[]const u8 = null,
};

/// Parse provider-specific error response into structured ErrorInfo.
///
/// Caller must free `result.message` and `result.raw_snippet` (if non-null).
/// Returns error.OutOfMemory on allocation failure.
pub fn parseError(alloc: Allocator, status: u16, body: []const u8) !ErrorInfo {
    var result = ErrorInfo{
        .http_code = status,
        .message = "",
        .raw_snippet = null,
        .code = null,
    };
    errdefer {
        if (result.message.len > 0) alloc.free(result.message);
        if (result.raw_snippet) |r| alloc.free(r);
    }

    if (body.len == 0) {
        result.message = try alloc.dupe(u8, "No response body");
        return result;
    }

    // Try to extract structured error fields
    const err_obj = json.findObject(body, "error");
    if (err_obj) |eo| {
        // AgnesAI / OpenAI style: {error: {code, message, type}}
        const code = json.findString(eo, "code");
        const msg = json.findString(eo, "message");

        if (code) |c| {
            result.code = try alloc.dupe(u8, c);
        }
        if (msg) |m| {
            // Format: "[HTTP_CODE CODE] message"
            var formatted = std.ArrayList(u8).empty;
            errdefer formatted.deinit(alloc);
            try formatted.appendSlice(alloc, m);
            result.message = try formatted.toOwnedSlice(alloc);
            return result;
        }
    }

    // Fallback: top-level "message" field
    const top_msg = json.findString(body, "message");
    if (top_msg) |m| {
        result.message = try alloc.dupe(u8, m);
        return result;
    }

    // No structured error — return raw snippet
    const snippet = if (body.len > 512) body[0..512] else body;
    result.raw_snippet = try alloc.dupe(u8, snippet);
    result.message = try std.fmt.allocPrint(alloc, "HTTP {d}", .{status});
    return result;
}

/// Extract a short error code string from body for logging/journaling.
/// Returns null if no structured code found.
/// Does not allocate — returns slice into body (caller manages lifetime).
pub fn extractErrorCode(body: []const u8) ?[]const u8 {
    const err_obj = json.findObject(body, "error") orelse return null;
    return json.findString(err_obj, "code");
}

/// Extract error message from body for journaling/debugging.
/// Returns slice pointing into body (not owned, no need to free).
pub fn extractErrorMessage(body: []const u8) ?[]const u8 {
    const err_obj = json.findObject(body, "error") orelse return json.findString(body, "message");
    return json.findString(err_obj, "message");
}

test "parseError: AgnesAI format with code and message" {
    const alloc = std.testing.allocator;
    const body = "{\"error\":{\"code\":\"video_queue_full\",\"message\":\"video queue is full, please retry later (request id: abc123)\",\"type\":\"AgnesAI_error\"}}";
    const result = try parseError(alloc, 503, body);
    defer {
        alloc.free(result.message);
        if (result.code) |c| alloc.free(c);
        if (result.raw_snippet) |r| alloc.free(r);
    }
    try std.testing.expectEqual(@as(u16, 503), result.http_code);
    try std.testing.expectEqualStrings("video_queue_full", result.code.?);
    try std.testing.expectEqualStrings("video queue is full, please retry later (request id: abc123)", result.message);
}

test "parseError: OpenAI format with code and message" {
    const alloc = std.testing.allocator;
    const body = "{\"error\":{\"code\":\"invalid_api_key\",\"message\":\"Incorrect API key provided\",\"type\":\"invalid_request_error\"}}";
    const result = try parseError(alloc, 401, body);
    defer {
        alloc.free(result.message);
        if (result.code) |c| alloc.free(c);
        if (result.raw_snippet) |r| alloc.free(r);
    }
    try std.testing.expectEqual(@as(u16, 401), result.http_code);
    try std.testing.expectEqualStrings("invalid_api_key", result.code.?);
    try std.testing.expectEqualStrings("Incorrect API key provided", result.message);
}

test "parseError: Anthropic top-level message" {
    const alloc = std.testing.allocator;
    const body = "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"Method Not Allowed\"},\"request_id\":\"req_abc\"}";
    const result = try parseError(alloc, 405, body);
    defer {
        alloc.free(result.message);
        if (result.raw_snippet) |r| alloc.free(r);
    }
    try std.testing.expectEqual(@as(u16, 405), result.http_code);
    try std.testing.expectEqualStrings("Method Not Allowed", result.message);
}

test "parseError: top-level message fallback" {
    const alloc = std.testing.allocator;
    const body = "{\"message\":\"rate_limit_exceeded\"}";
    const result = try parseError(alloc, 429, body);
    defer {
        alloc.free(result.message);
        if (result.raw_snippet) |r| alloc.free(r);
    }
    try std.testing.expectEqual(@as(u16, 429), result.http_code);
    try std.testing.expectEqualStrings("rate_limit_exceeded", result.message);
}

test "parseError: empty body" {
    const alloc = std.testing.allocator;
    const result = try parseError(alloc, 500, "");
    defer {
        alloc.free(result.message);
        if (result.raw_snippet) |r| alloc.free(r);
    }
    try std.testing.expectEqual(@as(u16, 500), result.http_code);
    try std.testing.expectEqualStrings("No response body", result.message);
}

test "parseError: raw HTML fallback" {
    const alloc = std.testing.allocator;
    const body = "<html><body>503 Service Temporarily Unavailable</body></html>";
    const result = try parseError(alloc, 503, body);
    defer {
        alloc.free(result.message);
        if (result.raw_snippet) |r| alloc.free(r);
    }
    try std.testing.expectEqual(@as(u16, 503), result.http_code);
    try std.testing.expect(result.raw_snippet != null);
    try std.testing.expect(std.mem.startsWith(u8, result.message, "HTTP 503"));
}

test "extractErrorCode: finds code in nested error" {
    const body = "{\"error\":{\"code\":\"model_not_found\",\"message\":\"No available channel\"}}";
    const code = extractErrorCode(body);
    try std.testing.expectEqualStrings("model_not_found", code.?);
}

test "extractErrorCode: null when no code" {
    const body = "{\"error\":{\"message\":\"something went wrong\"}}";
    try std.testing.expect(extractErrorCode(body) == null);
}

test "extractErrorCode: null when no error object" {
    const body = "{\"message\":\"plain error\"}";
    try std.testing.expect(extractErrorCode(body) == null);
}

test "extractErrorMessage: finds message in nested error" {
    const body = "{\"error\":{\"code\":\"rate_limit\",\"message\":\"Too many requests\"}}";
    const msg = extractErrorMessage(body);
    try std.testing.expectEqualStrings("Too many requests", msg.?);
}

test "extractErrorMessage: fallback to top-level message" {
    const body = "{\"message\":\"simple error\"}";
    const msg = extractErrorMessage(body);
    try std.testing.expectEqualStrings("simple error", msg.?);
}
