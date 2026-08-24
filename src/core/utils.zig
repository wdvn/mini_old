//! utils.zig — Các hàm tiện ích dùng chung cho mini-agent.
//!
//! Bao gồm các wrapper giúp tương thích với Zig 0.15.2 trong đó
//! một số API cũ (readAll, deprecatedWriter, ArrayList.writer()) đã bị xóa.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Đọc toàn bộ nội dung file vào buffer đã cấp phát.
/// Tương đương File.readAll() đã bị xóa trong Zig 0.15.2.
pub fn readAll(io: std.Io, file: std.Io.File, buf: []u8) !usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try file.readStreaming(io, &.{buf[total..]});
        if (n == 0) break;
        total += n;
    }
    return total;
}

/// Đọc một dòng byte-by-byte từ File, bỏ '\r'. Trả về null nếu EOF.
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
// BufWriter — thay thế ArrayList(u8).writer() đã bị xóa trong Zig 0.15.2
// ---------------------------------------------------------------------------

/// Growable string buffer với API print/writeAll/writeByte.
/// Thay thế pattern `buf.writer(alloc)` đã không còn hoạt động.
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

    /// Append một byte.
    pub fn writeByte(self: *BufWriter, byte: u8) !void {
        try self.list.append(self.alloc, byte);
    }

    /// Trả về nội dung (owned slice). Caller phải free.
    pub fn toOwnedSlice(self: *BufWriter) ![]u8 {
        return self.list.toOwnedSlice(self.alloc);
    }
};

/// Drain pipe hoàn toàn vào buffer. Giữ lại tối đa buf.len bytes đầu tiên.
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

/// Lấy epoch timestamp tính theo milliseconds
pub fn milliTimestamp() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(ts.nsec, 1000000);
}

/// Format duration (ms) thành định dạng dễ đọc cho con người (ms, s, m s, h m s).
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



