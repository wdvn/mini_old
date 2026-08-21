//! sse.zig — HTTP client dùng std.http.Client, hỗ trợ streaming SSE và NDJSON.
//!
//! Module này cung cấp hàm `post` duy nhất để gửi HTTP POST đến bất kỳ
//! endpoint nào và nhận phản hồi theo từng chunk qua callback.
//!
//! Các AI backend (openai, claude, ollama) dùng module này làm tầng vận chuyển,
//! mỗi backend tự parse chunk theo định dạng riêng của mình.

const std = @import("std");
const Allocator = std.mem.Allocator;
const main = @import("../main.zig");

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Hàm callback nhận từng chunk dữ liệu từ HTTP response.
/// `chunk` là slice tạm thời — phải copy nếu cần giữ lại.
/// `userdata` là con trỏ tới context struct của caller.
pub const ChunkFn = *const fn (chunk: []const u8, userdata: *anyopaque) void;

/// Tùy chọn cho HTTP request.
pub const RequestOpts = struct {
    /// URL đầy đủ (phải có http:// hoặc https://).
    url: []const u8,
    /// Headers dạng "Key: Value".
    headers: []const []const u8 = &.{},
    /// Body của POST request (JSON string).
    body: []const u8 = "",
    /// Timeout tổng (giây). Mặc định: 120.
    timeout_secs: u32 = 120,
};

/// Gửi HTTP POST và nhận phản hồi qua `on_chunk` callback.
/// Trả về HTTP status code.
pub fn post(
    alloc: Allocator,
    opts: RequestOpts,
    on_chunk: ChunkFn,
    userdata: *anyopaque,
) !u32 {
    var client = std.http.Client{
        .allocator = alloc,
        .io = main.g_io,
    };
    defer client.deinit();

    // Parse URL
    const uri = try std.Uri.parse(opts.url);

    // Parse headers từ "Key: Value" sang std.http.Header
    var extra_headers = std.ArrayList(std.http.Header).empty;
    defer extra_headers.deinit(alloc);
    for (opts.headers) |hdr| {
        if (std.mem.indexOfScalar(u8, hdr, ':')) |idx| {
            const name = std.mem.trim(u8, hdr[0..idx], " \t");
            const value = std.mem.trim(u8, hdr[idx + 1 ..], " \t");
            try extra_headers.append(alloc, .{ .name = name, .value = value });
        }
    }

    var req = try client.request(.POST, uri, .{
        .extra_headers = extra_headers.items,
        .headers = .{
            .accept_encoding = .omit,
        },
        .keep_alive = false,
    });
    defer req.deinit();

    // Gửi body
    if (opts.body.len > 0) {
        req.transfer_encoding = .{ .content_length = opts.body.len };
        var req_body = try req.sendBodyUnflushed(&.{});
        try req_body.writer.writeAll(opts.body);
        try req_body.end();
        try req.connection.?.flush();
    } else {
        try req.sendBodiless();
    }

    var redirect_buffer: [4096]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);

    // Đọc streaming từ response
    var transfer_buf: [4096]u8 = undefined;
    const r = response.reader(&transfer_buf);

    var chunk_buf: [4096]u8 = undefined;
    while (true) {
        const n = try r.readSliceShort(&chunk_buf);
        if (n == 0) break;
        on_chunk(chunk_buf[0..n], userdata);
    }

    return @intFromEnum(response.head.status);
}
