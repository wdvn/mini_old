//! paste.zig — Incremental parser cho bracketed paste mode (xterm `?2004`).
//!
//! Vấn đề với cách đọc byte-cứi-pointer cũ (RFC-000 follow-up):
//!   - Nội dung paste chứa escape sequence (vd ANSI color `\x1b[31m`) có thể
//!     trùng prefix với end-marker `\x1b[201~` → byte bị chèn sai, marker thật
//!     bị nuốt → editor kẹt vĩnh viễn trong paste mode (Enter/Ctrl+C bị nuốt).
//!   - Terminal không gửi end-marker (tmux cũ, một số terminal) → cùng hang.
//!
//! Giải pháp: state machine incremental — feed từng byte, parser tự nhận diện
//! đúng end-marker bằng cách so khớp dần và flush phần sai khi biết chuỗi không
//! thể là marker nữa. Hoàn toàn không I/O → unit test được.
//!
//! Đồng thời expose `sanitizeAppend` — chuẩn hoá nội dung paste cho single-line
//! composer: CRLF/CR/LF → 1 space (không double), strip control chars ngoài TAB,
//! giữ nguyên UTF-8 (kể cả multibyte tiếng Việt / emoji).

const std = @import("std");

pub const START_MARKER = "\x1b[200~";
pub const END_MARKER = "\x1b[201~";

pub const Marker = enum { start, end };

/// Trạng thái CR đã thấy (đang chờ LF) — dùng cho sanitize CRLF.
var sanitize_pending_cr: bool = false;

/// Sanitize + append 1 raw byte vào `out` (single-line composer rules).
/// - '\r\n' / '\r' / '\n' → 1 space (CRLF không thành 2 space).
/// - TAB giữ nguyên; control char khác bị bỏ.
/// Trả về true nếu byte được append (caller dùng cho việc redraw hạn chế).
pub fn sanitizeAppend(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, c: u8) bool {
    switch (c) {
        '\r' => {
            sanitize_pending_cr = true;
            return false; // chờ LF; nếu không có LF sẽ flush space ở byte kế
        },
        '\n' => {
            sanitize_pending_cr = false;
            out.append(alloc, ' ') catch return false;
            return true;
        },
        else => {
            if (sanitize_pending_cr) {
                sanitize_pending_cr = false;
                out.append(alloc, ' ') catch return false;
            }
            if (c == '\t') {
                out.append(alloc, c) catch return false;
                return true;
            }
            if (c < 32 or c == 0x7f) return false;
            out.append(alloc, c) catch return false;
            return true;
        },
    }
}

/// Reset trạng thái sanitize (giữa 2 lần paste).
pub fn sanitizeReset() void {
    sanitize_pending_cr = false;
}

fn markerCanContinue(cur: []const u8, c: u8) bool {
    // Hai marker chỉ khác byte index 4 ('0' start / '1' end): ESC [ 2 0|1 ~
    const common = "\x1b[20";
    const idx = cur.len;
    if (idx < 4) return c == common[idx];
    if (idx == 4) return c == '0' or c == '1';
    if (idx == 5) return c == '~';
    return false;
}

/// Parser bracketed paste: nhận byte tuần tự, tự nhận diện start/end marker
/// ngay cả khi nội dung paste chứa escape sequence trùng prefix marker.
pub const Parser = struct {
    /// Số byte candidate-marker đang hold (0 = không hold).
    matched: usize,
    /// Kind marker đang hold (chắc chắn sau byte thứ 5; giá trị mặc định vô nghĩa).
    hold_kind: Marker,
    hold_buf: [END_MARKER.len]u8,

    pub fn init() Parser {
        return .{ .matched = 0, .hold_kind = .end, .hold_buf = undefined };
    }

    pub fn reset(self: *Parser) void {
        self.matched = 0;
    }

    /// Bytes candidate đang hold (chưa biết là marker hay content).
    pub fn pending(self: *const Parser) []const u8 {
        return self.hold_buf[0..self.matched];
    }

    /// Copy pending sang buffer caller (an toàn sau khi `feed` trả `.fail`).
    pub fn pendingCopy(self: *const Parser, out: *[END_MARKER.len]u8) []const u8 {
        @memcpy(out[0..self.matched], self.hold_buf[0..self.matched]);
        return out[0..self.matched];
    }

    /// Feed 1 byte.
    /// - `.content`  : byte là nội dung paste.
    /// - `.marker`   : marker hoàn chỉnh vừa khớp (hold đã được tiêu thụ).
    /// - `.none`     : byte được hold làm candidate (xem `pending`).
    /// - `.fail`     : hold vừa vỡ — flush `pendingCopy` thành content rồi
    ///                 feed LẠI byte này (nó chưa được xử lý).
    pub fn feed(self: *Parser, c: u8) FeedResult {
        if (self.matched == 0) {
            if (c == 0x1b) {
                self.hold_buf[0] = c;
                self.matched = 1;
                return .none;
            }
            return .{ .content = c };
        }
        if (!markerCanContinue(self.hold_buf[0..self.matched], c)) {
            self.matched = 0;
            return .fail;
        }
        self.hold_buf[self.matched] = c;
        self.matched += 1;
        if (self.matched == 5) {
            self.hold_kind = if (self.hold_buf[4] == '0') .start else .end;
        }
        if (self.matched == END_MARKER.len) {
            self.matched = 0;
            return .{ .marker = self.hold_kind };
        }
        return .none;
    }
};

/// Kết quả feed 1 byte.
pub const FeedResult = union(enum) {
    /// Byte thuộc nội dung paste (raw, chưa sanitize).
    content: u8,
    /// Marker hoàn chỉnh vừa khớp.
    marker: Marker,
    /// Byte được hold làm candidate marker (chưa quyết định).
    none: void,
    /// Chuỗi hold vừa vỡ — caller phải: copy `pendingCopy` TRƯỚC khi feed,
    /// chèn nó thành content, rồi feed lại byte hiện tại.
    fail: void,
};

test "marker prefix match start" {
    var p = Parser.init();
    for (START_MARKER[0 .. START_MARKER.len - 1]) |c| {
        try std.testing.expectEqual(FeedResult.none, p.feed(c));
    }
    const r = p.feed(START_MARKER[START_MARKER.len - 1]);
    try std.testing.expectEqual(FeedResult{ .marker = .start }, r);
    // Sau marker, feed tiếp byte thường.
    try std.testing.expectEqual(FeedResult{ .content = 'x' }, p.feed('x'));
}

test "marker prefix match end" {
    var p = Parser.init();
    for (END_MARKER[0 .. END_MARKER.len - 1]) |c| {
        try std.testing.expectEqual(FeedResult.none, p.feed(c));
    }
    const r = p.feed(END_MARKER[END_MARKER.len - 1]);
    try std.testing.expectEqual(FeedResult{ .marker = .end }, r);
}

/// Helper: feed toàn bộ chuỗi, gom content sau khi xử lý hold/fail đúng cách.
fn feedAll(alloc: std.mem.Allocator, p: *Parser, input: []const u8) !std.ArrayListUnmanaged(u8) {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var tmp: [END_MARKER.len]u8 = undefined;
    for (input) |c| {
        // Copy pending TRƯỚC khi feed (feed có thể reset).
        const pre = p.pendingCopy(&tmp);
        const r = p.feed(c);
        switch (r) {
            .content => |b| try out.append(alloc, b),
            .marker, .none => {},
            .fail => {
                try out.appendSlice(alloc, pre);
                // Feed lại byte hiện tại (nó chưa được xử lý).
                switch (p.feed(c)) {
                    .content => |b| try out.append(alloc, b),
                    .none => {}, // byte là ESC → hold lại, ok
                    else => unreachable,
                }
            },
        }
    }
    // Flush nốt candidate còn hold (không bao giờ khớp marker nữa).
    try out.appendSlice(alloc, p.pendingCopy(&tmp));
    return out;
}

test "escape sequence trong paste không nhầm marker" {
    var p = Parser.init();
    var content = try feedAll(std.testing.allocator, &p, "\x1b[31mred\x1b[0m");
    defer content.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("\x1b[31mred\x1b[0m", content.items);
}

test "end-marker sau content chứa prefix gần marker" {
    var p = Parser.init();
    var tmp: [END_MARKER.len]u8 = undefined;
    // Content "abc\x1b[20" rồi END marker thật.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    var got_end = false;
    const input = "abc\x1b[20" ++ END_MARKER;
    for (input) |c| {
        const pre = p.pendingCopy(&tmp);
        switch (p.feed(c)) {
            .content => |b| try out.append(std.testing.allocator, b),
            .marker => |m| {
                if (m == .end) got_end = true;
            },
            .fail => {
                try out.appendSlice(std.testing.allocator, pre);
                switch (p.feed(c)) {
                    .content => |b| try out.append(std.testing.allocator, b),
                    .none => {},
                    else => unreachable,
                }
            },
            .none => {},
        }
    }
    try std.testing.expect(got_end);
    // Cuối stream còn hold prefix "\x1b[20" → flush thành content.
    try out.appendSlice(std.testing.allocator, p.pendingCopy(&tmp));
    try std.testing.expectEqualStrings("abc\x1b[20", out.items);
}

test "sanitizeAppend: CRLF một space, LF một space, TAB giữ, control bỏ" {
    const alloc = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    sanitizeReset();
    _ = sanitizeAppend(&out, alloc, 'a');
    _ = sanitizeAppend(&out, alloc, '\r');
    _ = sanitizeAppend(&out, alloc, '\n');
    _ = sanitizeAppend(&out, alloc, 'b');
    try std.testing.expectEqualStrings("a b", out.items);

    out.clearRetainingCapacity();
    sanitizeReset();
    _ = sanitizeAppend(&out, alloc, 'x');
    _ = sanitizeAppend(&out, alloc, '\n');
    _ = sanitizeAppend(&out, alloc, 'y');
    _ = sanitizeAppend(&out, alloc, '\r');
    _ = sanitizeAppend(&out, alloc, 'z'); // CR đứng đơn → space rồi 'z'
    try std.testing.expectEqualStrings("x y z", out.items);

    out.clearRetainingCapacity();
    sanitizeReset();
    _ = sanitizeAppend(&out, alloc, 'a');
    _ = sanitizeAppend(&out, alloc, '\t');
    _ = sanitizeAppend(&out, alloc, 'b');
    _ = sanitizeAppend(&out, alloc, 1); // control → bỏ
    try std.testing.expectEqualStrings("a\tb", out.items);
}
