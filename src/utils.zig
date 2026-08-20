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


