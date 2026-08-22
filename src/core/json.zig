//! json.zig — Tiện ích parse và build JSON không dùng thư viện ngoài.
//!
//! Vì mini-agent không có dependency JSON lib, module này cung cấp các hàm
//! scan đơn giản cho JSON responses từ AI backends và tool inputs.
//!
//! ## Giới hạn
//!   - Chỉ xử lý JSON flat/single-level đủ dùng cho API responses
//!   - Không validate JSON đầy đủ
//!   - Không hỗ trợ unicode escape (\uXXXX) trong chuỗi
//!
//! ## Hàm chính
//!   - `findString`  — tìm giá trị string theo key
//!   - `findObject`  — tìm giá trị object {} theo key
//!   - `findArray`   — tìm giá trị array [] theo key
//!   - `escape`      — escape một chuỗi để nhúng vào JSON string
//!   - `unescape`    — unescape JSON string sang plain text

const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Parsing helpers
// ---------------------------------------------------------------------------

/// Tìm giá trị string của key trong JSON object.
/// Trả về slice trỏ vào `json` (không owned, không cần free).
/// Không xử lý string lồng nhau hoặc key trùng lặp.
///
/// Ví dụ:
/// ```
/// findString(`{"name":"bash","id":"1"}`, "name") == "bash"
/// findString(`{"x":42}`, "x") == null  // 42 không phải string
/// ```
pub fn findString(json: []const u8, key: []const u8) ?[]const u8 {
    var pattern_buf: [256]u8 = undefined;
    if (key.len + 4 > pattern_buf.len) return null;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\":", .{key}) catch return null;

    const start_idx = std.mem.indexOf(u8, json, pattern) orelse return null;
    var val_start = start_idx + pattern.len;

    // Bỏ qua khoảng trắng sau dấu hai chấm
    while (val_start < json.len and (json[val_start] == ' ' or json[val_start] == '\t' or json[val_start] == '\n')) : (val_start += 1) {}
    
    // Phải mở bằng dấu ngoặc kép
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

/// findString + unescape kết quả. Trả về bộ nhớ owned (caller phải free).
/// Fast path: chuỗi không chứa backslash thì chỉ dupe.
/// Dùng cho mọi tool input chứa nội dung do người dùng/LLM kiểm soát
/// (command shell, pattern, nội dung file...) — nếu dùng findString thô,
/// các escape sequence JSON (\" \\n \\t) sẽ leak thành ký tự literal,
/// làm méo lệnh shell (ví dụ sinh file rác khi redirect 2>&1 bị parse sai).
pub fn findStringOwned(alloc: Allocator, json: []const u8, key: []const u8) !?[]u8 {
    const raw = findString(json, key) orelse return null;
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) {
        return try alloc.dupe(u8, raw);
    }
    return try unescape(alloc, raw);
}

/// Tìm giá trị object {} của key trong JSON.
/// Trả về slice bao gồm cả dấu `{` và `}`.
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
                    if (json[i] == '\\') { i += 1; continue; }
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

/// Tìm giá trị array [] của key trong JSON.
/// Trả về slice bao gồm cả dấu `[` và `]`.
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
                    if (json[i] == '\\') { i += 1; continue; }
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

/// Kiểm tra xem JSON có chứa key với giá trị boolean `true` không.
pub fn findBool(json: []const u8, key: []const u8) bool {
    var pattern_buf: [256]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\":true", .{key}) catch return false;
    return std.mem.indexOf(u8, json, pattern) != null;
}

test "findStringOwned unescape đúng chuỗi JSON" {
    const alloc = std.testing.allocator;
    // Lệnh shell chứa quote — must survive JSON round-trip nguyên vẹn
    const input = "{\"command\":\"grep -A 20 \\\"fail\\\\|error\\\" 2>&1\"}";
    const got = (try findStringOwned(alloc, input, "command")).?;
    defer alloc.free(got);
    try std.testing.expectEqualStrings("grep -A 20 \"fail\\|error\" 2>&1", got);

    // Fast path: không có backslash → chỉ dupe
    const input2 = "{\"command\":\"ls -la\"}";
    const got2 = (try findStringOwned(alloc, input2, "command")).?;
    defer alloc.free(got2);
    try std.testing.expectEqualStrings("ls -la", got2);

    // Newline escape
    const input3 = "{\"body\":\"line1\\nline2\"}";
    const got3 = (try findStringOwned(alloc, input3, "body")).?;
    defer alloc.free(got3);
    try std.testing.expectEqualStrings("line1\nline2", got3);

    // Key không tồn tại
    const got4 = try findStringOwned(alloc, input2, "missing");
    try std.testing.expect(got4 == null);
}

// ---------------------------------------------------------------------------
// Building helpers
// ---------------------------------------------------------------------------

/// Escape một chuỗi Zig để nhúng an toàn vào JSON string.
/// Caller phải free kết quả.
///
/// Các ký tự được escape: `"` `\` `\n` `\r` `\t`
pub fn escape(alloc: Allocator, s: []const u8) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(alloc);
    for (s) |c| {
        switch (c) {
            '"'  => try buf.appendSlice(alloc, "\\\""),
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
    return buf.toOwnedSlice(alloc);
}

/// Unescape một JSON string (phần bên trong dấu ngoặc kép).
/// Caller phải free kết quả.
pub fn unescape(alloc: Allocator, s: []const u8) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            switch (s[i]) {
                '"'  => try buf.append(alloc, '"'),
                '\\' => try buf.append(alloc, '\\'),
                'n'  => try buf.append(alloc, '\n'),
                'r'  => try buf.append(alloc, '\r'),
                't'  => try buf.append(alloc, '\t'),
                'u'  => {
                    if (i + 4 < s.len) {
                        const hex1 = s[i + 1 .. i + 5];
                        if (std.fmt.parseInt(u21, hex1, 16)) |cp1| {
                            i += 4;
                            var codepoint: u21 = cp1;
                            // Check for UTF-16 surrogate pair (\uD800-\uDBFF followed by \uDC00-\uDFFF)
                            if (cp1 >= 0xD800 and cp1 <= 0xDBFF and i + 6 < s.len and s[i + 1] == '\\' and s[i + 2] == 'u') {
                                const hex2 = s[i + 3 .. i + 7];
                                if (std.fmt.parseInt(u21, hex2, 16)) |cp2| {
                                    if (cp2 >= 0xDC00 and cp2 <= 0xDFFF) {
                                        codepoint = 0x10000 + (((cp1 - 0xD800) << 10) | (cp2 - 0xDC00));
                                        i += 6;
                                    }
                                } else |_| {}
                            }
                            var utf8_buf: [4]u8 = undefined;
                            const len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch 0;
                            if (len > 0) {
                                try buf.appendSlice(alloc, utf8_buf[0..len]);
                            } else {
                                try buf.append(alloc, '\\');
                                try buf.append(alloc, 'u');
                            }
                        } else |_| {
                            try buf.append(alloc, '\\');
                            try buf.append(alloc, 'u');
                        }
                    } else {
                        try buf.append(alloc, '\\');
                        try buf.append(alloc, 'u');
                    }
                },
                else => { try buf.append(alloc, '\\'); try buf.append(alloc, s[i]); },
            }
        } else {
            try buf.append(alloc, s[i]);
        }
    }
    return buf.toOwnedSlice(alloc);
}
