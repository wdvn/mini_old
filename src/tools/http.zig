//! tools/http.zig — Tool gửi HTTP request tới bất kỳ URL.
//!
//! Thin wrapper quanh `lib/http_request.zig` (HTTP client tập trung):
//! parse input JSON của tool protocol rồi gọi `http_lib.fetch` và
//! format kết quả bằng `http_lib.formatResponseText`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../core/json.zig");
const http_lib = @import("../lib/http_request.zig");
const main = @import("../main.zig");

// ---------------------------------------------------------------------------
// Tool entry point
// ---------------------------------------------------------------------------

/// Thực thi tool http_request.
/// Input: {"url":"...", "method":"GET", "body":"...", "headers":{...}}
pub fn executeTool(alloc: Allocator, input_json: []const u8) ![]u8 {
    const url = (try json.findStringOwned(alloc, input_json, "url")) orelse
        return std.fmt.allocPrint(alloc, "Lỗi: thiếu trường 'url'", .{});
    defer alloc.free(url);
    const method = json.findString(input_json, "method") orelse "GET";
    const body = try json.findStringOwned(alloc, input_json, "body");
    defer if (body) |b| alloc.free(b);
    const headers_json = json.findObject(input_json, "headers");

    return httpRequest(alloc, url, method, body, headers_json);
}

/// Gửi HTTP request, trả về text cho tool protocol:
/// dòng status, các header, blank line, body (đã truncate ở 30KB).
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
