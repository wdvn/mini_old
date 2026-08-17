//! tools/grep.zig — Tool tìm kiếm nội dung trong file.
//!
//! Tìm kiếm pattern trong một file hoặc thư mục (recursive).
//! Trả về kết quả dạng `path:line_num:nội_dòng`.
//!
//! ## Input schema
//! ```json
//! { "pattern": "fn main", "path": "./src", "case_insensitive": "false" }
//! ```
//!
//! ## Output format
//! ```
//! src/main.zig:42:pub fn main() !void {
//! src/agent.zig:10:fn main_loop() void {
//! ```
//!
//! ## Giới hạn
//!   - Tối đa 200 kết quả
//!   - Skip file > 1MB
//!   - Binary files bị bỏ qua tự động

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const utils = @import("../utils.zig");

const MAX_MATCHES = 200;
const MAX_FILE_SIZE = 1024 * 1024;

/// Tool entry point.
/// Input: {"pattern":"...", "path":".", "case_insensitive":"false"}
pub fn executeTool(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    const pattern = json.findString(input_json, "pattern") orelse
        return std.fmt.allocPrint(alloc, "Lỗi: thiếu trường 'pattern'", .{});
    const search_path = json.findString(input_json, "path") orelse ".";
    const ci_str = json.findString(input_json, "case_insensitive") orelse "false";
    const case_insensitive = std.mem.eql(u8, ci_str, "true");

    return searchContent(alloc, io, pattern, search_path, case_insensitive);
}

/// Tìm kiếm pattern trong path (file hoặc thư mục).
pub fn searchContent(alloc: Allocator, io: std.Io, pattern: []const u8, search_path: []const u8, case_insensitive: bool) ![]u8 {
    var result = utils.BufWriter.init(alloc);
    errdefer result.deinit();
    var count: usize = 0;

    const cwd = std.Io.Dir.cwd();

    // Thử mở như file trước
    const stat = cwd.statFile(io, search_path, .{}) catch |e| {
        return std.fmt.allocPrint(alloc, "Lỗi truy cập '{s}': {s}", .{ search_path, @errorName(e) });
    };

    if (stat.kind == .file) {
        try searchFile(alloc, io, &result, &count, pattern, search_path, case_insensitive);
    } else if (stat.kind == .directory) {
        var dir = cwd.openDir(io, search_path, .{}) catch |e| {
            return std.fmt.allocPrint(alloc, "Lỗi mở thư mục '{s}': {s}", .{ search_path, @errorName(e) });
        };
        defer dir.close(io);

        var walker = try dir.walk(alloc);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (count >= MAX_MATCHES) break;

            if (isBinaryName(entry.path)) continue;

            const full_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ search_path, entry.path });
            defer alloc.free(full_path);
            try searchFile(alloc, io, &result, &count, pattern, full_path, case_insensitive);
        }
    }

    if (count == 0) {
        return std.fmt.allocPrint(alloc, "Không tìm thấy '{s}' trong '{s}'.", .{ pattern, search_path });
    }

    try result.print("\n{d} match(es) found.", .{count});
    return result.toOwnedSlice();
}

fn searchFile(
    alloc: Allocator,
    io: std.Io,
    result: *utils.BufWriter,
    count: *usize,
    pattern: []const u8,
    path: []const u8,
    case_insensitive: bool,
) !void {
    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, path, .{}) catch return;
    defer file.close(io);

    const stat = file.stat(io) catch return;
    if (stat.size > MAX_FILE_SIZE or stat.size == 0) return;

    const buf = alloc.alloc(u8, @intCast(stat.size)) catch return;
    defer alloc.free(buf);
    const n = utils.readAll(io, file, buf) catch return;
    const content = buf[0..n];

    // Skip binary: nếu có null bytes trong 512 byte đầu
    const check_len = @min(content.len, 512);
    for (content[0..check_len]) |c| {
        if (c == 0) return;
    }

    var line_num: usize = 1;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| : (line_num += 1) {
        if (count.* >= MAX_MATCHES) return;
        const matched = if (case_insensitive)
            containsCI(line, pattern)
        else
            std.mem.indexOf(u8, line, pattern) != null;

        if (matched) {
            try result.print("{s}:{d}:{s}\n", .{ path, line_num, line });
            count.* += 1;
        }
    }
}

/// Case-insensitive substring search.
fn containsCI(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (0..needle.len) |j| {
            const h = std.ascii.toLower(haystack[i + j]);
            const n = std.ascii.toLower(needle[j]);
            if (h != n) { match = false; break; }
        }
        if (match) return true;
    }
    return false;
}

/// Kiểm tra extension có khả năng là binary không.
fn isBinaryName(name: []const u8) bool {
    const binary_exts = [_][]const u8{
        ".o", ".a", ".so", ".dylib", ".dll", ".exe",
        ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".ico",
        ".zip", ".tar", ".gz", ".bz2", ".xz",
        ".pdf", ".bin", ".wasm",
    };
    for (binary_exts) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return true;
    }
    return false;
}
