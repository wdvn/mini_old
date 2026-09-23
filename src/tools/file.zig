//! tools/file.zig — File read, write, and edit tools.
//!
//! ## Tool functions
//!   - `file_read`  — reads file, supports line-based offset/limit
//!   - `file_write` — writes/creates file (creates parent directories if needed)
//!   - `file_edit`  — finds a unique string and replaces it
//!
//! ## File paths
//! All paths resolve relative to process CWD. Absolute paths are also supported.
//!
//! ## Limits
//!   - file_read: max 1MB, max 2000 lines per read
//!   - file_write: max 10MB
//!   - file_edit: old_string must appear exactly once in file

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

/// Tool file_read: reads file content with line numbers.
/// Input: {"path":"...", "offset":10, "limit":50}
pub fn readTool(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    const path = (try json.findStringOwned(alloc, input_json, "path")) orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'path' parameter", .{});
    defer alloc.free(path);

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

/// Tool file_write: writes content to file (creates or overwrites).
/// Input: {"path":"...", "content":"..."}
pub fn writeTool(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    const path = (try json.findStringOwned(alloc, input_json, "path")) orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'path' parameter", .{});
    defer alloc.free(path);
    const content = (try json.findStringOwned(alloc, input_json, "content")) orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'content' parameter", .{});
    defer alloc.free(content);

    return writeFile(alloc, io, path, content);
}

/// Tool file_edit: finds unique old_string and replaces it with new_string.
/// Input: {"path":"...", "old_string":"...", "new_string":"..."}
pub fn editTool(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    const path = (try json.findStringOwned(alloc, input_json, "path")) orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'path' parameter", .{});
    const old_str = (try json.findStringOwned(alloc, input_json, "old_string")) orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'old_string' parameter", .{});
    const new_str = (try json.findStringOwned(alloc, input_json, "new_string")) orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'new_string' parameter", .{});
    errdefer alloc.free(path);
    errdefer alloc.free(old_str);
    errdefer alloc.free(new_str);

    const result = try editFile(alloc, io, path, old_str, new_str);
    alloc.free(path);
    alloc.free(old_str);
    alloc.free(new_str);
    return result;
}

// ---------------------------------------------------------------------------
// Core functions
// ---------------------------------------------------------------------------

/// Read file with line numbers. offset=0 starts at line 1.
/// Returns string formatted as "1: content\n2: content\n..."
pub fn readFile(alloc: Allocator, io: std.Io, path: []const u8, offset: usize, limit: usize) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, path, .{}) catch |e| {
        return std.fmt.allocPrint(alloc, "Error opening file '{s}': {s}", .{ path, @errorName(e) });
    };
    defer file.close(io);

    const stat = file.stat(io) catch |e| {
        return std.fmt.allocPrint(alloc, "Error stating file '{s}': {s}", .{ path, @errorName(e) });
    };
    if (stat.size > MAX_READ_SIZE) {
        return std.fmt.allocPrint(alloc, "File too large ({d} bytes). Use offset/limit.", .{stat.size});
    }

    const raw = alloc.alloc(u8, @intCast(stat.size)) catch return error.OutOfMemory;
    defer alloc.free(raw);
    const n = utils.readAll(io, file, raw) catch |e| {
        return std.fmt.allocPrint(alloc, "Error reading '{s}': {s}", .{ path, @errorName(e) });
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

    if (count == 0) try w.writeAll("(file empty or offset exceeds line count)");
    return result.toOwnedSlice();
}

/// Write content to file. Creates parent directories if not present.
pub fn writeFile(alloc: Allocator, io: std.Io, path: []const u8, content: []const u8) ![]u8 {
    if (content.len > MAX_WRITE_SIZE) {
        return std.fmt.allocPrint(alloc, "Content too large ({d} bytes).", .{content.len});
    }

    // Create parent directories if needed
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    }

    const cwd = std.Io.Dir.cwd();
    const file = cwd.createFile(io, path, .{ .truncate = true }) catch |e| {
        return std.fmt.allocPrint(alloc, "Error creating file '{s}': {s}", .{ path, @errorName(e) });
    };
    defer file.close(io);

    file.writeStreamingAll(io, content) catch |e| {
        return std.fmt.allocPrint(alloc, "Error writing '{s}': {s}", .{ path, @errorName(e) });
    };

    return std.fmt.allocPrint(alloc, "Wrote {d} bytes to '{s}'.", .{ content.len, path });
}

fn spliceReplacement(alloc: Allocator, content: []const u8, first: usize, old_len: usize, new_str: []const u8) ![]u8 {
    // PSEUDOCODE: Allocate and splice prefix + new_str + suffix.
    const new_size = content.len - old_len + new_str.len;
    const result_buf = try alloc.alloc(u8, new_size);
    @memcpy(result_buf[0..first], content[0..first]);
    @memcpy(result_buf[first .. first + new_str.len], new_str);
    @memcpy(result_buf[first + new_str.len ..], content[first + old_len ..]);
    return result_buf;
}

fn overwriteFileContent(io: std.Io, path: []const u8, bytes: []const u8) !void {
    // PSEUDOCODE: Create/truncate file and stream all bytes.
    const cwd = std.Io.Dir.cwd();
    const file_w = try cwd.createFile(io, path, .{ .truncate = true });
    defer file_w.close(io);
    try file_w.writeStreamingAll(io, bytes);
}

/// Find unique old_string in file and replace it with new_string.
/// Returns an error if old_string occurs multiple times.
pub fn editFile(alloc: Allocator, io: std.Io, path: []const u8, old_str: []const u8, new_str: []const u8) ![]u8 {
    // PSEUDOCODE:
    // 1. Open file and read content under MAX_READ_SIZE limit.
    // 2. Locate unique match for old_str; return error if missing or duplicate.
    // 3. Splice new_str and overwrite file.
    const cwd = std.Io.Dir.cwd();
    const file_r = cwd.openFile(io, path, .{}) catch |e| {
        return std.fmt.allocPrint(alloc, "Error opening '{s}': {s}", .{ path, @errorName(e) });
    };
    defer file_r.close(io);

    const stat = file_r.stat(io) catch return std.fmt.allocPrint(alloc, "Error stating file", .{});
    if (stat.size > MAX_READ_SIZE) return std.fmt.allocPrint(alloc, "File too large.", .{});

    const buf = alloc.alloc(u8, @intCast(stat.size)) catch return error.OutOfMemory;
    defer alloc.free(buf);
    const n = utils.readAll(io, file_r, buf) catch return std.fmt.allocPrint(alloc, "Error reading file.", .{});
    const content = buf[0..n];

    const first = std.mem.indexOf(u8, content, old_str) orelse {
        return std.fmt.allocPrint(alloc, "Could not find old_string in '{s}'.\nold_string: {s}", .{ path, old_str[0..@min(old_str.len, 100)] });
    };
    if (std.mem.indexOf(u8, content[first + 1 ..], old_str) != null) {
        return std.fmt.allocPrint(alloc, "old_string is not unique in '{s}'. Please provide a more specific string.", .{path});
    }

    const result_buf = try spliceReplacement(alloc, content, first, old_str.len, new_str);
    defer alloc.free(result_buf);

    overwriteFileContent(io, path, result_buf) catch |e| {
        return std.fmt.allocPrint(alloc, "Error writing '{s}': {s}", .{ path, @errorName(e) });
    };

    return std.fmt.allocPrint(alloc, "Modified '{s}': replaced {d} characters with {d} characters.", .{
        path, old_str.len, new_str.len,
    });
}
