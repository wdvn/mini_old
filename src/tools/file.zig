//! tools/file.zig — Tool đọc, ghi và sửa file.
//!
//! ## Các hàm tool
//!   - `file_read`  — đọc file, hỗ trợ offset/limit theo dòng
//!   - `file_write` — ghi/tạo file (tạo thư mục cha nếu cần)
//!   - `file_edit`  — tìm chuỗi duy nhất và thay thế
//!
//! ## File paths
//! Tất cả path đều được resolve từ CWD của process.
//! Absolute path cũng được hỗ trợ.
//!
//! ## Giới hạn
//!   - file_read: tối đa 1MB, tối đa 2000 dòng mỗi lần đọc
//!   - file_write: tối đa 10MB
//!   - file_edit: old_string phải là chuỗi duy nhất trong file

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../core/json.zig");
const utils = @import("../core/utils.zig");

const MAX_READ_SIZE = 1024 * 1024;   // 1MB
const MAX_WRITE_SIZE = 10 * 1024 * 1024; // 10MB
const MAX_LINES_PER_READ = 2000;

// ---------------------------------------------------------------------------
// Dispatch entry points
// ---------------------------------------------------------------------------

/// Tool file_read: đọc nội dung file với line numbers.
/// Input: {"path":"...", "offset":10, "limit":50}
pub fn readTool(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    const path = json.findString(input_json, "path") orelse
        return std.fmt.allocPrint(alloc, "Lỗi: thiếu trường 'path'", .{});

    const offset: usize = blk: {
        const s = json.findString(input_json, "offset") orelse break :blk 0;
        break :blk std.fmt.parseInt(usize, s, 10) catch 0;
    };
    const limit: usize = blk: {
        const s = json.findString(input_json, "limit") orelse break :blk MAX_LINES_PER_READ;
        break :blk std.fmt.parseInt(usize, s, 10) catch MAX_LINES_PER_READ;
    };

    return readFile(alloc, io, path, offset, @min(limit, MAX_LINES_PER_READ));
}

/// Tool file_write: ghi nội dung vào file (tạo mới hoặc ghi đè).
/// Input: {"path":"...", "content":"..."}
pub fn writeTool(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    const path = json.findString(input_json, "path") orelse
        return std.fmt.allocPrint(alloc, "Lỗi: thiếu trường 'path'", .{});
    const content = json.findString(input_json, "content") orelse
        return std.fmt.allocPrint(alloc, "Lỗi: thiếu trường 'content'", .{});

    // Unescape nội dung (API gửi dưới dạng JSON string)
    const unescaped = json.unescape(alloc, content) catch content;
    defer if (!std.mem.eql(u8, content, unescaped)) alloc.free(unescaped);

    return writeFile(alloc, io, path, unescaped);
}

/// Tool file_edit: tìm old_string (phải duy nhất) và thay bằng new_string.
/// Input: {"path":"...", "old_string":"...", "new_string":"..."}
pub fn editTool(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    const path = json.findString(input_json, "path") orelse
        return std.fmt.allocPrint(alloc, "Lỗi: thiếu trường 'path'", .{});
    const old_s = json.findString(input_json, "old_string") orelse
        return std.fmt.allocPrint(alloc, "Lỗi: thiếu trường 'old_string'", .{});
    const new_s = json.findString(input_json, "new_string") orelse
        return std.fmt.allocPrint(alloc, "Lỗi: thiếu trường 'new_string'", .{});

    const old_str = json.unescape(alloc, old_s) catch old_s;
    defer if (!std.mem.eql(u8, old_s, old_str)) alloc.free(old_str);
    const new_str = json.unescape(alloc, new_s) catch new_s;
    defer if (!std.mem.eql(u8, new_s, new_str)) alloc.free(new_str);

    return editFile(alloc, io, path, old_str, new_str);
}

// ---------------------------------------------------------------------------
// Core functions (dùng được từ code khác)
// ---------------------------------------------------------------------------

/// Đọc file với line numbers. offset=0 bắt đầu từ dòng 1.
/// Trả về string dạng "1: nội dung\n2: nội dung\n..."
pub fn readFile(alloc: Allocator, io: std.Io, path: []const u8, offset: usize, limit: usize) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, path, .{}) catch |e| {
        return std.fmt.allocPrint(alloc, "Lỗi mở file '{s}': {s}", .{ path, @errorName(e) });
    };
    defer file.close(io);

    const stat = file.stat(io) catch |e| {
        return std.fmt.allocPrint(alloc, "Lỗi stat '{s}': {s}", .{ path, @errorName(e) });
    };
    if (stat.size > MAX_READ_SIZE) {
        return std.fmt.allocPrint(alloc, "File quá lớn ({d} bytes). Dùng offset/limit.", .{stat.size});
    }

    const raw = alloc.alloc(u8, @intCast(stat.size)) catch return error.OutOfMemory;
    defer alloc.free(raw);
    const n = utils.readAll(io, file, raw) catch |e| {
        return std.fmt.allocPrint(alloc, "Lỗi đọc '{s}': {s}", .{ path, @errorName(e) });
    };

    var result = utils.BufWriter.init(alloc);
    errdefer result.deinit();
    const w = &result;

    var line_num: usize = 1;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, raw[0..n], '\n');
    while (lines.next()) |line| : (line_num += 1) {
        if (line_num <= offset) continue;
        if (count >= limit) break;
        try w.print("{d}: {s}\n", .{ line_num, line });
        count += 1;
    }

    if (count == 0) try w.writeAll("(file trống hoặc offset vượt quá số dòng)");
    return result.toOwnedSlice();
}

/// Ghi nội dung vào file. Tạo thư mục cha nếu chưa tồn tại.
pub fn writeFile(alloc: Allocator, io: std.Io, path: []const u8, content: []const u8) ![]u8 {
    if (content.len > MAX_WRITE_SIZE) {
        return std.fmt.allocPrint(alloc, "Nội dung quá lớn ({d} bytes).", .{content.len});
    }

    // Tạo thư mục cha nếu cần
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    }

    const cwd = std.Io.Dir.cwd();
    const file = cwd.createFile(io, path, .{ .truncate = true }) catch |e| {
        return std.fmt.allocPrint(alloc, "Lỗi tạo file '{s}': {s}", .{ path, @errorName(e) });
    };
    defer file.close(io);

    file.writeStreamingAll(io, content) catch |e| {
        return std.fmt.allocPrint(alloc, "Lỗi ghi '{s}': {s}", .{ path, @errorName(e) });
    };

    return std.fmt.allocPrint(alloc, "Đã ghi {d} bytes vào '{s}'.", .{ content.len, path });
}

/// Tìm old_string (duy nhất) trong file và thay bằng new_string.
/// Trả về lỗi nếu old_string xuất hiện nhiều lần.
pub fn editFile(alloc: Allocator, io: std.Io, path: []const u8, old_str: []const u8, new_str: []const u8) ![]u8 {
    // Đọc file
    const cwd = std.Io.Dir.cwd();
    const file_r = cwd.openFile(io, path, .{}) catch |e| {
        return std.fmt.allocPrint(alloc, "Lỗi mở '{s}': {s}", .{ path, @errorName(e) });
    };
    defer file_r.close(io);

    const stat = file_r.stat(io) catch return std.fmt.allocPrint(alloc, "Lỗi stat", .{});
    if (stat.size > MAX_READ_SIZE) return std.fmt.allocPrint(alloc, "File quá lớn.", .{});

    const buf = alloc.alloc(u8, @intCast(stat.size)) catch return error.OutOfMemory;
    defer alloc.free(buf);
    const n = utils.readAll(io, file_r, buf) catch return std.fmt.allocPrint(alloc, "Lỗi đọc.", .{});
    const content = buf[0..n];

    // Tìm old_string
    const first = std.mem.indexOf(u8, content, old_str) orelse {
        return std.fmt.allocPrint(alloc,
            "Không tìm thấy old_string trong '{s}'.\nold_string: {s}",
            .{ path, old_str[0..@min(old_str.len, 100)] },
        );
    };

    // Kiểm tra không có xuất hiện thứ hai
    if (std.mem.indexOf(u8, content[first + 1 ..], old_str) != null) {
        return std.fmt.allocPrint(alloc,
            "old_string không duy nhất trong '{s}'. Hãy cung cấp chuỗi cụ thể hơn.",
            .{path},
        );
    }

    // Build kết quả
    var result = std.ArrayListUnmanaged(u8).empty;
    errdefer result.deinit(alloc);
    try result.appendSlice(alloc, content[0..first]);
    try result.appendSlice(alloc, new_str);
    try result.appendSlice(alloc, content[first + old_str.len ..]);

    // Ghi lại
    const file_w = cwd.createFile(io, path, .{ .truncate = true }) catch |e| {
        return std.fmt.allocPrint(alloc, "Lỗi ghi '{s}': {s}", .{ path, @errorName(e) });
    };
    defer file_w.close(io);
    file_w.writeStreamingAll(io, result.items) catch |e| {
        return std.fmt.allocPrint(alloc, "Lỗi ghi '{s}': {s}", .{ path, @errorName(e) });
    };

    return std.fmt.allocPrint(alloc, "Đã sửa '{s}': thay {d} ký tự bằng {d} ký tự.", .{
        path, old_str.len, new_str.len,
    });
}
