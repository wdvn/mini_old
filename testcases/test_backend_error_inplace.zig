//! test_backend_error_inplace.zig — Integration tests cho hiển thị raw response và inplace retry khi backend gặp lỗi.
//!
//! Kiểm tra:
//!   1. In raw error response an toàn, hỗ trợ HTTP code và raw payload
//!   2. waitWithInplaceCountdown hoạt động an toàn trong môi trường non-TTY
//!   3. Đảm bảo proto.Response chứa http_code và raw_debug_info không rò rỉ bộ nhớ
//!   4. Kiểm tra visibleWidth và truncateAnsi chống tràn cột terminal (anti line-wrap)
//!   5. Kiểm tra TurnRenderer deduplication cho backend throttled errors

const std = @import("std");
const mini = @import("mini");
const proto = mini.protocol_mod;
const agent_mod = mini.agent_mod;
const chat_stream = mini.ui_chat_stream;

test "backend_error: printRawBackendResponse runs safely with various payloads" {
    // 1. Raw JSON với HTTP 429
    agent_mod.AgentLoop.printRawBackendResponse(
        \\{"error":{"message":"Rate limit exceeded (TPM)","type":"tokens"}}
    , 429);

    // 2. Raw HTML với HTTP 503
    agent_mod.AgentLoop.printRawBackendResponse(
        \\<html><body>503 Service Temporarily Unavailable</body></html>
    , 503);

    // 3. Null raw với HTTP 500
    agent_mod.AgentLoop.printRawBackendResponse(null, 500);

    // 4. Null raw với HTTP 0 (không lỗi)
    agent_mod.AgentLoop.printRawBackendResponse(null, 0);

    // 5. Chuỗi rỗng / khoảng trắng
    agent_mod.AgentLoop.printRawBackendResponse("   \n\t  ", 429);
}

test "backend_error: proto.Response preserves http_code and raw_debug_info" {
    const alloc = std.testing.allocator;

    var resp = proto.Response.init(alloc);
    defer resp.deinit();

    resp.http_code = 429;
    resp.raw_debug_info = try alloc.dupe(u8, "{\"error\":\"rate_limit_exceeded\"}");

    try std.testing.expectEqual(@as(u32, 429), resp.http_code);
    try std.testing.expect(resp.raw_debug_info != null);
    try std.testing.expectEqualStrings("{\"error\":\"rate_limit_exceeded\"}", resp.raw_debug_info.?);
}

test "backend_error: waitWithInplaceCountdown in non-tty environment terminates cleanly" {
    var agent: agent_mod.AgentLoop = undefined;
    agent.io = std.testing.io;

    // Với non-TTY (trong unit test term.isStdoutTty() == false), backoff 0s trả về ngay lập tức
    try agent.waitWithInplaceCountdown(0, 1, 7);
}

test "backend_error: visibleWidth filters ANSI escapes and counts UTF-8 codepoints accurately" {
    // 1. Chuỗi thuần ASCII
    try std.testing.expectEqual(@as(usize, 5), chat_stream.visibleWidth("hello"));

    // 2. Chuỗi có mã màu ANSI
    const ansi_str = "\x1b[33m\x1b[1mhello\x1b[0m";
    try std.testing.expectEqual(@as(usize, 5), chat_stream.visibleWidth(ansi_str));

    // 3. Chuỗi có ký tự tiếng Việt UTF-8
    const vi_str = " \x1b[36m⠋\x1b[0m \x1b[90mĐang thử lại...\x1b[0m";
    const vi_w = chat_stream.visibleWidth(vi_str);
    try std.testing.expect(vi_w > 0 and vi_w <= 20);
}

test "backend_error: truncateAnsi truncates gracefully and ensures ANSI reset" {
    var buf: [256]u8 = undefined;
    const long_colored = "\x1b[31mThis is a very long error message that exceeds terminal columns\x1b[0m";

    // Cắt ngắn xuống 20 cột
    const truncated = chat_stream.truncateAnsi(&buf, long_colored, 20);
    try std.testing.expect(chat_stream.visibleWidth(truncated) <= 20);
    try std.testing.expect(std.mem.endsWith(u8, truncated, "...\x1b[0m"));

    // Chuỗi ngắn hơn limit thì giữ nguyên
    const short_str = "\x1b[32mOK\x1b[0m";
    const kept = chat_stream.truncateAnsi(&buf, short_str, 50);
    try std.testing.expectEqualStrings(short_str, kept);
}

test "backend_error: TurnRenderer deduplication and error signature lifecycle" {
    const alloc = std.testing.allocator;
    var renderer = chat_stream.TurnRenderer.init(alloc, std.testing.io);
    defer renderer.deinit();

    const raw1 = "{\"error\":\"rate_limit_exceeded\"}";
    const sig1 = chat_stream.TurnRenderer.computeErrorSignature(429, raw1);
    try std.testing.expect(sig1 != 0);

    // Lần 1: showBackendThrottled sẽ cập nhật last_error_signature
    renderer.showBackendThrottled(429, raw1);
    try std.testing.expectEqual(sig1, renderer.last_error_signature);

    // Lần 2: gọi lại cùng lỗi -> signature giữ nguyên, không in lặp lại
    renderer.showBackendThrottled(429, raw1);
    try std.testing.expectEqual(sig1, renderer.last_error_signature);

    // Khi lỗi mới khác xuất hiện -> signature thay đổi
    const raw2 = "{\"error\":\"different_error\"}";
    const sig2 = chat_stream.TurnRenderer.computeErrorSignature(503, raw2);
    try std.testing.expect(sig1 != sig2);
    renderer.showBackendThrottled(503, raw2);
    try std.testing.expectEqual(sig2, renderer.last_error_signature);

    // Reset signature khi kết thúc
    renderer.resetErrorSignature();
    try std.testing.expectEqual(@as(u64, 0), renderer.last_error_signature);
}
