//! terminal.zig — ANSI Escape Codes, Colors, Box Drawing & Terminal Primitives for mini-agent (RFC-007).
//!
//! Provides constants and utilities for terminal control, syntax coloring,
//! box drawing, and cursor management according to ANSI standards.

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
pub const GLYPH_BOT = "💩";
pub const GLYPH_BULLET = "•";

// ---------------------------------------------------------------------------
// Output helpers
// ---------------------------------------------------------------------------

/// Safely write raw bytes to stdout (skipped during testing to prevent blocking mock Io).
pub fn writeStdout(bytes: []const u8) void {
    if (comptime builtin.is_test) return;
    std.Io.File.stdout().writeStreamingAll(main.getIo(), bytes) catch {};
}

// ---------------------------------------------------------------------------
// Cursor & Screen Control
// ---------------------------------------------------------------------------

/// Clear current line and move cursor to beginning of line.
pub fn clearLine(io: std.Io) void {
    _ = io;
    writeStdout("\r\x1b[2K");
}

/// Hide terminal cursor.
pub fn hideCursor(io: std.Io) void {
    _ = io;
    writeStdout("\x1b[?25l");
}

/// Show terminal cursor.
pub fn showCursor(io: std.Io) void {
    _ = io;
    writeStdout("\x1b[?25h");
}

/// Move cursor up by `n` lines.
pub fn cursorUp(io: std.Io, n: usize) void {
    _ = io;
    if (n == 0) return;
    var buf: [32]u8 = undefined;
    const seq = std.fmt.bufPrint(&buf, "\x1b[{d}A", .{n}) catch return;
    writeStdout(seq);
}

/// Move cursor down by `n` lines.
pub fn cursorDown(io: std.Io, n: usize) void {
    _ = io;
    if (n == 0) return;
    var buf: [32]u8 = undefined;
    const seq = std.fmt.bufPrint(&buf, "\x1b[{d}B", .{n}) catch return;
    writeStdout(seq);
}

extern fn isatty(fd: c_int) c_int;
extern fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

const CWinSize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

/// Check whether stdout is a TTY.
pub fn isStdoutTty() bool {
    if (comptime builtin.is_test) return false;
    if (builtin.os.tag == .windows) return true;
    return isatty(1) != 0;
}

pub const WinSize = struct {
    rows: u16,
    cols: u16,
};

/// Get current terminal window size (rows, cols). Fallback to 24x80 if unavailable.
pub fn getTerminalSize() WinSize {
    if (comptime builtin.is_test) return .{ .rows = 24, .cols = 80 };
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        const TIOCGWINSZ: c_ulong = if (builtin.os.tag == .linux) 0x5413 else 0x40087468;
        var ws: CWinSize = undefined;
        if (ioctl(1, TIOCGWINSZ, &ws) == 0 and ws.ws_col > 0) {
            return .{ .rows = ws.ws_row, .cols = ws.ws_col };
        }
    }
    return .{ .rows = 24, .cols = 80 };
}

test "terminal constants" {
    try std.testing.expect(RESET.len > 0);
    try std.testing.expect(FG_GREEN.len > 0);
    try std.testing.expectEqualStrings("╭", BOX_TOP_LEFT);
    try std.testing.expectEqualStrings("⚡", GLYPH_ACTION);
}
