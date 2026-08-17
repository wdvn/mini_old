//! tools/glob.zig — Tool tìm file theo wildcard pattern.
//!
//! Hỗ trợ các wildcard cơ bản:
//!   `*`   — khớp bất kỳ chuỗi nào (không kể path separator)
//!   `**`  — khớp bất kỳ chuỗi kể cả path separator (recursive)
//!   `?`   — khớp đúng 1 ký tự bất kỳ
//!
//! ## Input schema
//! ```json
//! { "pattern": "**/*.zig", "path": "./src" }
//! ```
//! `path` là thư mục gốc để tìm kiếm (mặc định: ".").
//!
//! ## Output
//! Danh sách đường dẫn, mỗi file một dòng, tối đa 500 kết quả.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const utils = @import("../utils.zig");

const MAX_RESULTS = 500;

/// Tool entry point.
/// Input: {"pattern":"**/*.zig", "path":"./src"}
pub fn executeTool(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    const pattern = json.findString(input_json, "pattern") orelse
        return std.fmt.allocPrint(alloc, "Lỗi: thiếu trường 'pattern'", .{});
    const base_path = json.findString(input_json, "path") orelse ".";

    return searchGlob(alloc, io, pattern, base_path);
}

/// Tìm file theo glob pattern trong thư mục base_path.
pub fn searchGlob(alloc: Allocator, io: std.Io, pattern: []const u8, base_path: []const u8) ![]u8 {
    var result = utils.BufWriter.init(alloc);
    errdefer result.deinit();

    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, base_path, .{ .iterate = true }) catch |e| {
        return std.fmt.allocPrint(alloc, "Lỗi mở thư mục '{s}': {s}", .{ base_path, @errorName(e) });
    };
    defer dir.close(io);

    var count: usize = 0;
    var walker = try dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (count >= MAX_RESULTS) {
            try result.print("... (giới hạn {d} kết quả)\n", .{MAX_RESULTS});
            break;
        }

        // Match pattern
        const path = entry.path;
        if (globMatch(pattern, path)) {
            try result.writeAll(path);
            try result.writeByte('\n');
            count += 1;
        }
    }

    if (count == 0) {
        return std.fmt.allocPrint(alloc, "Không tìm thấy file khớp với pattern '{s}' trong '{s}'.", .{ pattern, base_path });
    }

    // Thêm summary
    try result.print("\n{d} file(s) found.", .{count});
    return result.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Glob matching
// ---------------------------------------------------------------------------

/// Khớp path với pattern glob.
/// Hỗ trợ `*` (không qua /), `**` (qua /), `?` (1 ký tự).
fn globMatch(pattern: []const u8, path: []const u8) bool {
    return matchInner(pattern, path);
}

fn matchInner(pat: []const u8, str: []const u8) bool {
    var pi: usize = 0;
    var si: usize = 0;

    while (pi < pat.len) {
        if (pat[pi] == '*') {
            // Double star: khớp bất kỳ (kể cả /)
            if (pi + 1 < pat.len and pat[pi + 1] == '*') {
                pi += 2;
                if (pi < pat.len and pat[pi] == '/') pi += 1;
                // Thử khớp từ mỗi vị trí trong str
                var i: usize = si;
                while (i <= str.len) : (i += 1) {
                    if (matchInner(pat[pi..], str[i..])) return true;
                }
                return false;
            } else {
                // Single star: không qua /
                pi += 1;
                var i: usize = si;
                while (i <= str.len) : (i += 1) {
                    if (i > si and str[i - 1] == '/') break;
                    if (matchInner(pat[pi..], str[i..])) return true;
                }
                return false;
            }
        } else if (pat[pi] == '?') {
            if (si >= str.len or str[si] == '/') return false;
            pi += 1;
            si += 1;
        } else {
            if (si >= str.len or pat[pi] != str[si]) return false;
            pi += 1;
            si += 1;
        }
    }
    return si == str.len;
}
