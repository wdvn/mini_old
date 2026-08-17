//! tools/search.zig — Tool tìm kiếm web qua DuckDuckGo.
//!
//! Không cần API key. Dùng DuckDuckGo Lite HTML interface để lấy
//! kết quả tìm kiếm và parse thủ công.
//!
//! ## Input schema
//! ```json
//! { "query": "Zig programming language tutorial", "num_results": 5 }
//! ```
//!
//! ## Output
//! ```
//! 1. Zig Programming Language
//!    https://ziglang.org
//!    Fast, general purpose, statically typed...
//!
//! 2. ...
//! ```
//!
//! ## Giới hạn
//!   - Tối đa 10 kết quả
//!   - Chỉ trả về title, URL, snippet (không có full content)
//!   - Rate limit: không gửi quá nhanh

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const http = @import("http.zig");
const utils = @import("../utils.zig");

const DDG_LITE_URL = "https://lite.duckduckgo.com/lite/";
const MAX_RESULTS = 10;

/// Tool entry point.
/// Input: {"query":"...", "num_results":5}
pub fn executeTool(alloc: Allocator, input_json: []const u8) ![]u8 {
    const query = json.findString(input_json, "query") orelse
        return std.fmt.allocPrint(alloc, "Lỗi: thiếu trường 'query'", .{});

    const n_str = json.findString(input_json, "num_results") orelse "5";
    const num_results = @min(
        std.fmt.parseInt(usize, n_str, 10) catch 5,
        MAX_RESULTS,
    );

    return searchDDG(alloc, query, num_results);
}

/// Tìm kiếm trên DuckDuckGo Lite và trả về kết quả đã parse.
fn searchDDG(alloc: Allocator, query: []const u8, num_results: usize) ![]u8 {
    // URL encode query (đơn giản: thay space bằng +)
    const encoded = try urlEncode(alloc, query);
    defer alloc.free(encoded);

    const url = try std.fmt.allocPrint(alloc, "{s}?q={s}&kl=vn-vi", .{ DDG_LITE_URL, encoded });
    defer alloc.free(url);

    // Gửi request với User-Agent trình duyệt
    const headers_json = "{\"User-Agent\":\"Mozilla/5.0\",\"Accept\":\"text/html\"}";
    const raw_html = try http.httpRequest(alloc, url, "GET", null, headers_json);
    defer alloc.free(raw_html);

    return parseHtml(alloc, raw_html, num_results);
}

/// Parse HTML từ DDG Lite để trích xuất kết quả.
/// DDG Lite dùng HTML đơn giản, không cần parser phức tạp.
fn parseHtml(alloc: Allocator, html: []const u8, max: usize) ![]u8 {
    var result = utils.BufWriter.init(alloc);
    errdefer result.deinit();
    const w = &result;

    var count: usize = 0;

    // Tìm các result links: <a class="result-link" href="...">title</a>
    // DDG Lite có cấu trúc: <a href="...">title</a> trong table rows
    var i: usize = 0;
    while (i < html.len and count < max) {
        // Tìm href="http
        const href_tag = std.mem.indexOf(u8, html[i..], "href=\"http") orelse break;
        i += href_tag + 6; // skip href="

        // Tìm URL end
        const url_end = std.mem.indexOfScalar(u8, html[i..], '"') orelse break;
        const url = html[i .. i + url_end];
        i += url_end + 1;

        // Bỏ qua các URL nội bộ của DDG
        if (std.mem.indexOf(u8, url, "duckduckgo.com") != null) continue;
        if (std.mem.indexOf(u8, url, "duck.co") != null) continue;

        // Tìm title trong <a>...</a>
        const gt = std.mem.indexOfScalar(u8, html[i..], '>') orelse break;
        i += gt + 1;
        const lt = std.mem.indexOfScalar(u8, html[i..], '<') orelse break;
        const title = std.mem.trim(u8, html[i .. i + lt], " \t\n\r");
        i += lt;

        if (title.len == 0) continue;

        // Tìm snippet trong phần tiếp theo (class="result-snippet")
        var snippet: []const u8 = "";
        const snip_start = std.mem.indexOf(u8, html[i..], "result-snippet");
        if (snip_start) |ss| {
            const snip_i = i + ss;
            const snip_gt = std.mem.indexOfScalar(u8, html[snip_i..], '>') orelse 0;
            const snip_text_start = snip_i + snip_gt + 1;
            if (snip_text_start < html.len) {
                const snip_end = std.mem.indexOfScalar(u8, html[snip_text_start..], '<') orelse 0;
                snippet = std.mem.trim(u8, html[snip_text_start .. snip_text_start + snip_end], " \t\n\r");
            }
        }

        count += 1;
        try w.print("{d}. {s}\n   {s}\n", .{ count, title, url });
        if (snippet.len > 0) {
            try w.print("   {s}\n", .{snippet[0..@min(snippet.len, 200)]});
        }
        try w.writeByte('\n');
    }

    if (count == 0) {
        return std.fmt.allocPrint(alloc, "Không tìm thấy kết quả. Thử query khác.", .{});
    }

    return result.toOwnedSlice();
}

/// URL encode đơn giản: space → +, ký tự đặc biệt → %XX.
fn urlEncode(alloc: Allocator, s: []const u8) ![]u8 {
    var buf = utils.BufWriter.init(alloc);
    errdefer buf.deinit();
    for (s) |c| {
        if (c == ' ') {
            try buf.writeByte('+');
        } else if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try buf.writeByte(c);
        } else {
            try buf.print("%{X:0>2}", .{c});
        }
    }
    return buf.toOwnedSlice();
}
