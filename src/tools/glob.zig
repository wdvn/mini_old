//! tools/glob.zig — File wildcard search tool.
//!
//! Supports basic wildcards:
//!   `*`   — matches any characters within a path component
//!   `**`  — matches any characters across path separators (recursive)
//!   `?`   — matches exactly 1 character
//!
//! ## Input schema
//! ```json
//! { "pattern": "**/*.zig", "path": "./src" }
//! ```
//! `path` is the search base directory (default: ".").
//!
//! ## Output
//! List of file paths, one per line, up to 500 results.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../core/json.zig");
const utils = @import("../core/utils.zig");

const MAX_RESULTS = 500;

/// Tool entry point.
/// Input: {"pattern":"**/*.zig", "path":"./src"}
pub fn executeTool(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    const pattern = (try json.findStringOwned(alloc, input_json, "pattern")) orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'pattern' parameter", .{});
    defer alloc.free(pattern);
    const base_path = (try json.findStringOwned(alloc, input_json, "path")) orelse
        try alloc.dupe(u8, ".");
    defer alloc.free(base_path);

    return searchGlob(alloc, io, pattern, base_path);
}

/// Find files matching glob pattern inside base_path.
pub fn searchGlob(alloc: Allocator, io: std.Io, pattern: []const u8, base_path: []const u8) ![]u8 {
    var result = utils.BufWriter.init(alloc);
    errdefer result.deinit();

    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, base_path, .{ .iterate = true }) catch |e| {
        return std.fmt.allocPrint(alloc, "Error opening directory '{s}': {s}", .{ base_path, @errorName(e) });
    };
    defer dir.close(io);

    var count: usize = 0;
    var walker = try dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (count >= MAX_RESULTS) {
            try result.print("... (limited to {d} results)\n", .{MAX_RESULTS});
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
        return std.fmt.allocPrint(alloc, "No files matching pattern '{s}' found in '{s}'.", .{ pattern, base_path });
    }

    // Append summary
    try result.print("\n{d} file(s) found.", .{count});
    return result.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Glob matching
// ---------------------------------------------------------------------------

/// Match path against glob pattern.
/// Supports `*` (within component), `**` (across /), `?` (single char).
fn globMatch(pattern: []const u8, path: []const u8) bool {
    return matchInner(pattern, path);
}

fn matchInner(pat: []const u8, str: []const u8) bool {
    var pi: usize = 0;
    var si: usize = 0;

    while (pi < pat.len) {
        if (pat[pi] == '*') {
            // Double star: match across /
            if (pi + 1 < pat.len and pat[pi + 1] == '*') {
                pi += 2;
                if (pi < pat.len and pat[pi] == '/') pi += 1;
                // Try matching from each position in str
                var i: usize = si;
                while (i <= str.len) : (i += 1) {
                    if (matchInner(pat[pi..], str[i..])) return true;
                }
                return false;
            } else {
                // Single star: does not cross /
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
