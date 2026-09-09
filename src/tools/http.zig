//! tools/http.zig — HTTP request tool.
//!
//! Thin wrapper around `lib/http_request.zig` (centralized HTTP client):
//! parses tool protocol JSON input, calls `http_lib.fetch`, and
//! formats output with `http_lib.formatResponseText`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../core/json.zig");
const http_lib = @import("../lib/http_request.zig");
const main = @import("../main.zig");

// ---------------------------------------------------------------------------
// Tool entry point
// ---------------------------------------------------------------------------

/// Execute http_request tool.
/// Input: {"url":"...", "method":"GET", "body":"...", "headers":{...}}
pub fn executeTool(alloc: Allocator, input_json: []const u8) ![]u8 {
    const url = (try json.findStringOwned(alloc, input_json, "url")) orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'url' parameter", .{});
    defer alloc.free(url);
    const method = json.findString(input_json, "method") orelse "GET";
    const body = try json.findStringOwned(alloc, input_json, "body");
    defer if (body) |b| alloc.free(b);
    const headers_json = json.findObject(input_json, "headers");

    return httpRequest(alloc, url, method, body, headers_json);
}

/// Send HTTP request and format response for tool protocol:
/// status line, headers, blank line, body (truncated at 30KB).
pub fn httpRequest(
    alloc: Allocator,
    url: []const u8,
    method: []const u8,
    body: ?[]const u8,
    headers_json: ?[]const u8,
) ![]u8 {
    var res = try http_lib.fetch(alloc, main.getIo(), .{
        .url = url,
        .method = method,
        .body = body,
        .headers_json = headers_json,
    });
    defer res.deinit(alloc);

    return http_lib.formatResponseText(alloc, &res);
}
