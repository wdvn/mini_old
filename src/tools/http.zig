//! tools/http.zig — Tool gửi HTTP request tới bất kỳ URL.
//!
//! Sử dụng std.http.Client của Zig thay vì libcurl. Hỗ trợ các phương thức
//! HTTP phổ biến và custom headers. Response body được truncate ở 30KB để tránh
//! overflow context window của AI.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../core/json.zig");
const utils = @import("../core/utils.zig");
const main = @import("../main.zig");

const MAX_RESPONSE_SIZE = 30 * 1024;

// ---------------------------------------------------------------------------
// Tool entry point
// ---------------------------------------------------------------------------

/// Thực thi tool http_request.
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

/// Gửi HTTP request và trả về status + headers + body.
pub fn httpRequest(
    alloc: Allocator,
    url: []const u8,
    method: []const u8,
    body: ?[]const u8,
    headers_json: ?[]const u8,
) ![]u8 {
    var client = std.http.Client{
        .allocator = alloc,
        .io = main.g_io,
    };
    defer client.deinit();

    // Method
    var method_upper_buf: [32]u8 = undefined;
    const method_upper = std.ascii.upperString(&method_upper_buf, method[0..@min(method.len, 31)]);
    const http_method = std.meta.stringToEnum(std.http.Method, method_upper) orelse return error.InvalidMethod;

    // Headers
    var extra_headers = std.ArrayList(std.http.Header).empty;
    defer extra_headers.deinit(alloc);

    if (headers_json) |hj| {
        var i: usize = 1; // skip {
        while (i < hj.len) : (i += 1) {
            if (hj[i] == '"') {
                const key_start = i + 1;
                i += 1;
                while (i < hj.len and hj[i] != '"') : (i += 1) {}
                const key = hj[key_start..i];
                // Skip ":"
                i += 1;
                while (i < hj.len and (hj[i] == ':' or hj[i] == ' ')) : (i += 1) {}
                if (i < hj.len and hj[i] == '"') {
                    const val_start = i + 1;
                    i += 1;
                    while (i < hj.len and hj[i] != '"') : (i += 1) {}
                    const val = hj[val_start..i];
                    try extra_headers.append(alloc, .{ .name = key, .value = val });
                }
            }
        }
    }

    const uri = try std.Uri.parse(url);
    var req = try client.request(http_method, uri, .{
        .extra_headers = extra_headers.items,
        .headers = .{
            .accept_encoding = .omit,
        },
        .keep_alive = false,
    });
    defer req.deinit();

    // Body
    if (body) |b| {
        if (b.len > 0) {
            req.transfer_encoding = .{ .content_length = b.len };
            var req_body = try req.sendBodyUnflushed(&.{});
            try req_body.writer.writeAll(b);
            try req_body.end();
            try req.connection.?.flush();
        } else {
            try req.sendBodiless();
        }
    } else {
        try req.sendBodiless();
    }

    var redirect_buffer: [4096]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);

    // Định dạng kết quả đầu ra (headers trước khi đọc body để tránh bị ghi đè / gỡ đệm)
    var out = utils.BufWriter.init(alloc);
    errdefer out.deinit();
    const w = &out;

    try w.print("HTTP {d} {s}\n", .{ @intFromEnum(response.head.status), response.head.reason });
    if (response.head.bytes.len > 0) {
        var lines = std.mem.splitScalar(u8, response.head.bytes, '\n');
        _ = lines.first(); // Bỏ qua dòng status
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \r\t");
            if (line.len == 0) break; // Hết phần headers
            if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                const name = std.mem.trim(u8, line[0..colon], " \t");
                const val = std.mem.trim(u8, line[colon + 1 ..], " \t");
                if (name.len > 0) {
                    try w.print("{s}: {s}\n", .{ name, val });
                }
            }
        }
    }
    try w.writeByte('\n');

    // Đọc body lên tới MAX_RESPONSE_SIZE (30KB)
    var resp_body = std.ArrayList(u8).empty;
    defer resp_body.deinit(alloc);

    var transfer_buf: [4096]u8 = undefined;
    const r = response.reader(&transfer_buf);

    var chunk_buf: [4096]u8 = undefined;
    var total_bytes: usize = 0;
    while (true) {
        const n = r.readSliceShort(&chunk_buf) catch |e| {
            if (resp_body.items.len > 0) break;
            return e;
        };
        if (n == 0) break;
        total_bytes += n;
        if (resp_body.items.len < MAX_RESPONSE_SIZE) {
            const to_copy = @min(n, MAX_RESPONSE_SIZE - resp_body.items.len);
            try resp_body.appendSlice(alloc, chunk_buf[0..to_copy]);
        }
    }

    try w.writeAll(resp_body.items);
    if (total_bytes > MAX_RESPONSE_SIZE) {
        try w.print("\n... [truncated {d} bytes]", .{total_bytes - MAX_RESPONSE_SIZE});
    }

    return out.toOwnedSlice();
}
