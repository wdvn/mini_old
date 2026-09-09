//! spinner.zig — Live Non-blocking Braille Spinner & Timer for mini-agent (RFC-007).
//!
//! Provides an animated spinner with smooth rotating Braille frames and execution timer.

const std = @import("std");
const term = @import("terminal.zig");
const utils = @import("../core/utils.zig");

pub const Spinner = struct {
    frames: []const []const u8 = &.{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
    frame_idx: usize = 0,
    start_ms: i64 = 0,
    is_active: bool = false,

    /// Initialize and start the spinner timer.
    pub fn start() Spinner {
        return .{
            .frame_idx = 0,
            .start_ms = utils.milliTimestamp(),
            .is_active = true,
        };
    }

    /// Get current frame and advance to next frame.
    pub fn nextFrame(self: *Spinner) []const u8 {
        const frame = self.frames[self.frame_idx];
        self.frame_idx = (self.frame_idx + 1) % self.frames.len;
        return frame;
    }

    /// Compute elapsed seconds since start.
    pub fn elapsedSeconds(self: *const Spinner) f64 {
        const now = utils.milliTimestamp();
        const diff = if (now >= self.start_ms) now - self.start_ms else 0;
        return @as(f64, @floatFromInt(diff)) / 1000.0;
    }

    /// Compute elapsed milliseconds since start.
    pub fn elapsedMs(self: *const Spinner) u64 {
        const now = utils.milliTimestamp();
        return if (now >= self.start_ms) @intCast(now - self.start_ms) else 0;
    }

    /// Render one spinner frame to the terminal (at current line).
    pub fn render(self: *Spinner, io: std.Io, msg: []const u8) void {
        _ = io;
        if (!term.isStdoutTty()) return;
        const frame = self.nextFrame();
        var dur_buf: [32]u8 = undefined;
        const dur_str = utils.formatDuration(&dur_buf, self.elapsedMs());

        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "\r\x1b[2K\x1b[36m{s}\x1b[0m \x1b[90m{s} ({s})...\x1b[0m", .{
            frame, msg, dur_str,
        }) catch return;

        term.writeStdout(line);
    }

    /// Stop spinner and clear status line.
    pub fn clear(self: *Spinner, io: std.Io) void {
        _ = io;
        if (!self.is_active) return;
        self.is_active = false;
        if (term.isStdoutTty()) {
            term.writeStdout("\r\x1b[2K");
        }
    }

    /// Stop spinner and print final status line (e.g., completed or error).
    pub fn finish(self: *Spinner, io: std.Io, glyph: []const u8, glyph_color: []const u8, msg: []const u8) void {
        self.clear(io);
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{s}{s}\x1b[0m {s}\n", .{ glyph_color, glyph, msg }) catch return;
        term.writeStdout(line);
    }
};

test "spinner elapsed time and frames" {
    var spinner = Spinner.start();
    try std.testing.expect(spinner.is_active);
    const f1 = spinner.nextFrame();
    const f2 = spinner.nextFrame();
    try std.testing.expect(!std.mem.eql(u8, f1, f2));
    try std.testing.expect(spinner.elapsedSeconds() >= 0.0);
}
