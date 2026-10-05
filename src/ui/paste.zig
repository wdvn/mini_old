//! paste.zig — Incremental parser for bracketed paste mode (xterm `?2004`).
//!
//! Issue with the old end-of-pointer byte read approach:
//!   - Pasted content containing escape sequences (e.g. ANSI color `\x1b[31m`) can
//!     share prefixes with end-marker `\x1b[201~` → bytes wrongly inserted, real marker
//!     swallowed → editor permanently trapped in paste mode (Enter/Ctrl+C swallowed).
//!   - Terminals not sending end-marker (legacy tmux, select terminals) → same hang.
//!
//! Solution: incremental state machine — feeds byte-by-byte, parser automatically
//! identifies correct end-markers via progressive matching and flushes failed prefixes
//! once sequence can no longer match. Completely I/O free → unit testable.
//!
//! Also exposes `sanitizeAppend` — normalizes pasted content for single-line
//! composer: CRLF/CR/LF → 1 space (no doubling), strips control chars except TAB,
//! preserves UTF-8 intact (including multibyte characters / emojis).

const std = @import("std");

pub const START_MARKER = "\x1b[200~";
pub const END_MARKER = "\x1b[201~";

pub const Marker = enum { start, end };

/// Observed CR state (awaiting LF) — used for CRLF sanitization.
var sanitize_pending_cr: bool = false;

/// Sanitize + append 1 raw byte into `out` (single-line composer rules).
/// - '\r\n' / '\r' / '\n' → 1 space (CRLF does not become 2 spaces).
/// - TAB preserved; other control characters dropped.
/// Returns true if byte was appended (caller uses for bounded redrawing).
pub fn sanitizeAppend(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, c: u8) bool {
    switch (c) {
        '\r' => {
            sanitize_pending_cr = true;
            return false; // awaiting LF; if no LF follows, flush space on next byte
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

/// Reset sanitize state (between paste operations).
pub fn sanitizeReset() void {
    sanitize_pending_cr = false;
}

/// Observed CR state awaiting LF for multiline mode (independent variable, untouched by single-line).
var multi_pending_cr: bool = false;

/// Sanitize + append 1 byte according to MULTILINE rules:
/// - '\r\n' / '\r' / '\n' → exactly 1 '\n' (preserves line structure).
/// - TAB preserved; other control characters dropped; UTF-8 preserved.
/// Returns true if byte was appended.
pub fn sanitizeAppendMultiline(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, c: u8) bool {
    switch (c) {
        '\r' => {
            multi_pending_cr = true;
            return false; // awaiting LF; if no LF follows, flush '\n' on next byte
        },
        '\n' => {
            multi_pending_cr = false;
            out.append(alloc, '\n') catch return false;
            return true;
        },
        else => {
            if (multi_pending_cr) {
                multi_pending_cr = false;
                out.append(alloc, '\n') catch return false;
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

/// Reset multiline sanitize state (between paste operations).
pub fn sanitizeMultilineReset() void {
    multi_pending_cr = false;
}

fn markerCanContinue(cur: []const u8, c: u8) bool {
    // Two markers only differ at byte index 4 ('0' start / '1' end): ESC [ 2 0|1 ~
    const common = "\x1b[20";
    const idx = cur.len;
    if (idx < 4) return c == common[idx];
    if (idx == 4) return c == '0' or c == '1';
    if (idx == 5) return c == '~';
    return false;
}

/// Bracketed paste parser: receives sequential bytes, identifies start/end markers
/// accurately even when pasted content contains escape sequences matching marker prefix.
pub const Parser = struct {
    /// Number of candidate-marker bytes held (0 = none held).
    matched: usize,
    /// Kind of marker held (determined after 5th byte; default value arbitrary).
    hold_kind: Marker,
    hold_buf: [END_MARKER.len]u8,

    pub fn init() Parser {
        return .{ .matched = 0, .hold_kind = .end, .hold_buf = undefined };
    }

    pub fn reset(self: *Parser) void {
        self.matched = 0;
    }

    /// Candidate bytes currently held (undecided whether marker or content).
    pub fn pending(self: *const Parser) []const u8 {
        return self.hold_buf[0..self.matched];
    }

    /// Copy pending to caller buffer (safe after `feed` returns `.fail`).
    pub fn pendingCopy(self: *const Parser, out: *[END_MARKER.len]u8) []const u8 {
        @memcpy(out[0..self.matched], self.hold_buf[0..self.matched]);
        return out[0..self.matched];
    }

    /// Feed 1 byte.
    /// - `.content`  : byte is paste content.
    /// - `.marker`   : complete marker matched (held bytes consumed).
    /// - `.none`     : byte held as candidate (see `pending`).
    /// - `.fail`     : hold sequence broken — flush `pendingCopy` to content,
    ///                 then re-feed this byte (it has not been processed).
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

/// Result of feeding 1 byte.
pub const FeedResult = union(enum) {
    /// Byte belongs to paste content (raw, unsanitized).
    content: u8,
    /// Complete marker matched.
    marker: Marker,
    /// Byte held as candidate marker (undecided).
    none: void,
    /// Hold sequence broken — caller must: copy `pendingCopy` BEFORE feed,
    /// insert as content, then re-feed current byte.
    fail: void,
};

test "marker prefix match start" {
    var p = Parser.init();
    for (START_MARKER[0 .. START_MARKER.len - 1]) |c| {
        try std.testing.expectEqual(FeedResult.none, p.feed(c));
    }
    const r = p.feed(START_MARKER[START_MARKER.len - 1]);
    try std.testing.expectEqual(FeedResult{ .marker = .start }, r);
    // After marker, continue feeding normal bytes.
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

/// Helper: feed entire string, collect content after properly handling hold/fail.
fn feedAll(alloc: std.mem.Allocator, p: *Parser, input: []const u8) !std.ArrayListUnmanaged(u8) {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var tmp: [END_MARKER.len]u8 = undefined;
    for (input) |c| {
        // Copy pending BEFORE feed (feed may reset).
        const pre = p.pendingCopy(&tmp);
        const r = p.feed(c);
        switch (r) {
            .content => |b| try out.append(alloc, b),
            .marker, .none => {},
            .fail => {
                try out.appendSlice(alloc, pre);
                // Re-feed current byte (it has not been processed).
                switch (p.feed(c)) {
                    .content => |b| try out.append(alloc, b),
                    .none => {}, // byte is ESC → hold, ok
                    else => unreachable,
                }
            },
        }
    }
    // Flush remaining held candidate (will never match a marker again).
    try out.appendSlice(alloc, p.pendingCopy(&tmp));
    return out;
}

test "escape sequence in paste does not mistake marker" {
    var p = Parser.init();
    var content = try feedAll(std.testing.allocator, &p, "\x1b[31mred\x1b[0m");
    defer content.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("\x1b[31mred\x1b[0m", content.items);
}

test "end-marker after content containing near-marker prefix" {
    var p = Parser.init();
    var tmp: [END_MARKER.len]u8 = undefined;
    // Content "abc\x1b[20" followed by real END marker.
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
    // Stream tail still holds prefix "\x1b[20" → flush as content.
    try out.appendSlice(std.testing.allocator, p.pendingCopy(&tmp));
    try std.testing.expectEqualStrings("abc\x1b[20", out.items);
}

test "sanitizeAppend: CRLF one space, LF one space, TAB preserved, control dropped" {
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
    _ = sanitizeAppend(&out, alloc, 'z'); // Standalone CR → space then 'z'
    try std.testing.expectEqualStrings("x y z", out.items);

    out.clearRetainingCapacity();
    sanitizeReset();
    _ = sanitizeAppend(&out, alloc, 'a');
    _ = sanitizeAppend(&out, alloc, '\t');
    _ = sanitizeAppend(&out, alloc, 'b');
    _ = sanitizeAppend(&out, alloc, 1); // control → dropped
    try std.testing.expectEqualStrings("a\tb", out.items);
}
