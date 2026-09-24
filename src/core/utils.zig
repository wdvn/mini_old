//! utils.zig — Shared utility functions for mini-agent.
//!
//! Includes wrappers for Zig 0.16 compatibility where
//! some older APIs (readAll, deprecatedWriter, ArrayList.writer()) were removed.

const std = @import("std");
const Allocator = std.mem.Allocator;

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// Check whether the current process is a subagent (spawned from parent) or in quiet mode.
pub fn isSubagent() bool {
    if (getenv("MINI_SUBAGENT_DEPTH")) |ptr| {
        const span = std.mem.sliceTo(ptr, 0);
        if (span.len > 0 and !std.mem.eql(u8, span, "0")) {
            return true;
        }
    }
    if (getenv("MINI_QUIET")) |ptr| {
        const span = std.mem.sliceTo(ptr, 0);
        if (std.mem.eql(u8, span, "1") or std.mem.eql(u8, span, "true")) {
            return true;
        }
    }
    return false;
}

/// Read an environment variable as an optional slice (process lifetime).
pub fn getEnvSlice(name: [*:0]const u8) ?[]const u8 {
    if (getenv(name)) |ptr| {
        const span = std.mem.sliceTo(ptr, 0);
        if (span.len > 0) return span;
    }
    return null;
}

/// Read entire file content into allocated buffer.
/// Equivalent to File.readAll() removed in newer Zig versions.
pub fn readAll(io: std.Io, file: std.Io.File, buf: []u8) !usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try file.readStreaming(io, &.{buf[total..]});
        if (n == 0) break;
        total += n;
    }
    return total;
}

/// Read a line byte-by-byte from File, stripping '\r'. Returns null on EOF.
pub fn readLine(io: std.Io, file: std.Io.File, buf: []u8) ?[]u8 {
    var i: usize = 0;
    while (i < buf.len) {
        var byte: [1]u8 = undefined;
        const n = file.readStreaming(io, &.{&byte}) catch return null;
        if (n == 0) {
            if (i == 0) return null;
            return buf[0..i];
        }
        if (byte[0] == '\n') return buf[0..i];
        if (byte[0] != '\r') {
            buf[i] = byte[0];
            i += 1;
        }
    }
    return buf[0..i];
}

// ---------------------------------------------------------------------------
// BufWriter — replacement for ArrayList(u8).writer() removed in newer Zig
// ---------------------------------------------------------------------------

/// Growable string buffer with print/writeAll/writeByte API.
/// Replaces the `buf.writer(alloc)` pattern.
pub const BufWriter = struct {
    list: std.ArrayList(u8),
    alloc: Allocator,

    pub fn init(alloc: Allocator) BufWriter {
        return .{
            .list = .empty,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *BufWriter) void {
        self.list.deinit(self.alloc);
    }

    /// Append formatted string.
    pub fn print(self: *BufWriter, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.alloc, fmt, args);
        defer self.alloc.free(s);
        try self.list.appendSlice(self.alloc, s);
    }

    /// Append raw bytes.
    pub fn writeAll(self: *BufWriter, bytes: []const u8) !void {
        try self.list.appendSlice(self.alloc, bytes);
    }

    /// Append a single byte.
    pub fn writeByte(self: *BufWriter, byte: u8) !void {
        try self.list.append(self.alloc, byte);
    }

    /// Return contents (owned slice). Caller must free.
    pub fn toOwnedSlice(self: *BufWriter) ![]u8 {
        return self.list.toOwnedSlice(self.alloc);
    }
};

/// Drain pipe completely into buffer. Keep up to the first buf.len bytes.
pub fn drainPipe(io: std.Io, pipe: std.Io.File, buf: []u8) usize {
    var stored: usize = 0;
    while (true) {
        if (stored < buf.len) {
            const n = pipe.readStreaming(io, &.{buf[stored..]}) catch break;
            if (n == 0) break;
            stored += n;
        } else {
            var sink: [4096]u8 = undefined;
            const n = pipe.readStreaming(io, &.{&sink}) catch break;
            if (n == 0) break;
        }
    }
    return stored;
}

/// Get epoch timestamp in milliseconds.
pub fn milliTimestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(ts.nsec, 1000000);
}

/// Format duration (ms) into human-readable format (ms, s, m s, h m s).
pub fn formatDuration(buf: []u8, duration_ms: u64) []const u8 {
    if (duration_ms < 1000) {
        return std.fmt.bufPrint(buf, "{d}ms", .{duration_ms}) catch "0ms";
    }
    if (duration_ms < 60_000) {
        const sec = @as(f64, @floatFromInt(duration_ms)) / 1000.0;
        return std.fmt.bufPrint(buf, "{d:.1}s", .{sec}) catch "0s";
    }
    const total_sec = duration_ms / 1000;
    if (total_sec < 3600) {
        const m = total_sec / 60;
        const s = total_sec % 60;
        if (s == 0) {
            return std.fmt.bufPrint(buf, "{d}m", .{m}) catch "0m";
        }
        return std.fmt.bufPrint(buf, "{d}m {d}s", .{ m, s }) catch "0m";
    }
    const h = total_sec / 3600;
    const rem_sec = total_sec % 3600;
    const m = rem_sec / 60;
    const s = rem_sec % 60;
    if (m == 0 and s == 0) {
        return std.fmt.bufPrint(buf, "{d}h", .{h}) catch "0h";
    }
    if (s == 0) {
        return std.fmt.bufPrint(buf, "{d}h {d}m", .{ h, m }) catch "0h";
    }
    return std.fmt.bufPrint(buf, "{d}h {d}m {d}s", .{ h, m, s }) catch "0h";
}

/// Check whether a word appears in text with word boundary checks (case-insensitive ASCII).
/// Ensures that matching "plan" will not match "explanation" or "plant".
pub fn hasWordIgnoreCase(text: []const u8, word: []const u8) bool {
    if (text.len < word.len) return false;
    var i: usize = 0;
    while (i + word.len <= text.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(text[i .. i + word.len], word)) {
            const prev_ok = (i == 0) or !std.ascii.isAlphanumeric(text[i - 1]);
            const next_ok = (i + word.len == text.len) or !std.ascii.isAlphanumeric(text[i + word.len]);
            if (prev_ok and next_ok) return true;
        }
    }
    return false;
}

test "formatDuration formats ms, s, m, h" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("12ms", formatDuration(&buf, 12));
    try std.testing.expectEqualStrings("999ms", formatDuration(&buf, 999));
    try std.testing.expectEqualStrings("1.0s", formatDuration(&buf, 1000));
    try std.testing.expectEqualStrings("25.9s", formatDuration(&buf, 25934));
    try std.testing.expectEqualStrings("1m", formatDuration(&buf, 60000));
    try std.testing.expectEqualStrings("2m 15s", formatDuration(&buf, 135000));
    try std.testing.expectEqualStrings("1h", formatDuration(&buf, 3600000));
    try std.testing.expectEqualStrings("1h 5m 12s", formatDuration(&buf, 3912000));
}

test "hasWordIgnoreCase word boundary detection" {
    try std.testing.expect(hasWordIgnoreCase("## Implementation Plan", "plan"));
    try std.testing.expect(hasWordIgnoreCase("Plan:", "plan"));
    try std.testing.expect(hasWordIgnoreCase("action PLAN for next steps", "plan"));
    try std.testing.expect(!hasWordIgnoreCase("Here is an explanation of the bug", "plan"));
    try std.testing.expect(!hasWordIgnoreCase("water the plant", "plan"));
}
