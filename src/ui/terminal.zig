//! terminal.zig — ANSI Escape Codes, Colors, Box Drawing & Terminal Primitives cho mini-agent (RFC-007).
//!
//! Cung cấp các hằng số và tiện ích điều khiển terminal, tô màu cú pháp,
//! vẽ khung viền (box drawing) và quản lý con trỏ theo chuẩn ANSI.

const std = @import("std");
const builtin = @import("builtin");
const main = @import("../main.zig");

// ---------------------------------------------------------------------------
// ANSI Styles & Colors
// ---------------------------------------------------------------------------

pub const RESET = "\x1b[0m";
pub const BOLD = "\x1b[1m";
pub const DIM = "\x1b[2m";
pub const ITALIC = "\x1b[3m";
pub const UNDERLINE = "\x1b[4m";
pub const INVERSE = "\x1b[7m";

// Standard Colors
pub const FG_BLACK = "\x1b[30m";
pub const FG_RED = "\x1b[31m";
pub const FG_GREEN = "\x1b[32m";
pub const FG_YELLOW = "\x1b[33m";
pub const FG_BLUE = "\x1b[34m";
pub const FG_MAGENTA = "\x1b[35m";
pub const FG_CYAN = "\x1b[36m";
pub const FG_WHITE = "\x1b[37m";

// Bright Colors
pub const FG_BRIGHT_BLACK = "\x1b[90m"; // Gray
pub const FG_BRIGHT_RED = "\x1b[91m";
pub const FG_BRIGHT_GREEN = "\x1b[92m";
pub const FG_BRIGHT_YELLOW = "\x1b[93m";
pub const FG_BRIGHT_BLUE = "\x1b[94m";
pub const FG_BRIGHT_MAGENTA = "\x1b[95m";
pub const FG_BRIGHT_CYAN = "\x1b[96m";
pub const FG_BRIGHT_WHITE = "\x1b[97m";

// Background Colors
pub const BG_BLACK = "\x1b[40m";
pub const BG_RED = "\x1b[41m";
pub const BG_GREEN = "\x1b[42m";
pub const BG_YELLOW = "\x1b[43m";
pub const BG_BLUE = "\x1b[44m";
pub const BG_MAGENTA = "\x1b[45m";
pub const BG_CYAN = "\x1b[46m";
pub const BG_WHITE = "\x1b[47m";
pub const BG_GRAY = "\x1b[48;5;236m";

// ---------------------------------------------------------------------------
// UTF-8 Box Drawing & Symbols
// ---------------------------------------------------------------------------

pub const BOX_TOP_LEFT = "╭";
pub const BOX_TOP_RIGHT = "╮";
pub const BOX_BOT_LEFT = "╰";
pub const BOX_BOT_RIGHT = "╯";
pub const BOX_HORIZ = "─";
pub const BOX_VERT = "│";
pub const BOX_T_RIGHT = "├";
pub const BOX_T_LEFT = "┤";

pub const GLYPH_PROMPT = "❯";
pub const GLYPH_ACTION = "⚡";
pub const GLYPH_CHECK = "✓";
pub const GLYPH_CROSS = "✗";
pub const GLYPH_THINK = "💭";
pub const GLYPH_STATS = "📊";
pub const GLYPH_BOT = "🤖";
pub const GLYPH_BULLET = "•";

// ---------------------------------------------------------------------------
// Output helpers
// ---------------------------------------------------------------------------

/// Ghi raw bytes ra stdout an toàn (bỏ qua khi chạy test để tránh block mock Io).
pub fn writeStdout(bytes: []const u8) void {
    if (comptime builtin.is_test) return;
    std.Io.File.stdout().writeStreamingAll(main.getIo(), bytes) catch {};
}

// ---------------------------------------------------------------------------
// Cursor & Screen Control
// ---------------------------------------------------------------------------

/// Xóa dòng hiện tại và đưa con trỏ về đầu dòng.
pub fn clearLine(io: std.Io) void {
    _ = io;
    writeStdout("\r\x1b[2K");
}

/// Ẩn con trỏ terminal.
pub fn hideCursor(io: std.Io) void {
    _ = io;
    writeStdout("\x1b[?25l");
}

/// Hiện con trỏ terminal.
pub fn showCursor(io: std.Io) void {
    _ = io;
    writeStdout("\x1b[?25h");
}

/// Di chuyển con trỏ lên `n` dòng.
pub fn cursorUp(io: std.Io, n: usize) void {
    _ = io;
    if (n == 0) return;
    var buf: [32]u8 = undefined;
    const seq = std.fmt.bufPrint(&buf, "\x1b[{d}A", .{n}) catch return;
    writeStdout(seq);
}

/// Di chuyển con trỏ xuống `n` dòng.
pub fn cursorDown(io: std.Io, n: usize) void {
    _ = io;
    if (n == 0) return;
    var buf: [32]u8 = undefined;
    const seq = std.fmt.bufPrint(&buf, "\x1b[{d}B", .{n}) catch return;
    writeStdout(seq);
}

extern fn isatty(fd: c_int) c_int;

/// Kiểm tra stdout có phải là TTY không.
pub fn isStdoutTty() bool {
    if (comptime builtin.is_test) return false;
    if (builtin.os.tag == .windows) return true;
    return isatty(1) != 0;
}

test "terminal constants" {
    try std.testing.expect(RESET.len > 0);
    try std.testing.expect(FG_GREEN.len > 0);
    try std.testing.expectEqualStrings("╭", BOX_TOP_LEFT);
    try std.testing.expectEqualStrings("⚡", GLYPH_ACTION);
}
