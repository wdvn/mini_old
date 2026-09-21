//! test_file_edit.zig — Tests for file_edit tool (fix: memory leak on Ctrl+C).
//!
//! Covers:
//!   1. editFile succeeds — replaces old_string with new_string
//!   2. editFile returns error when old_string not found
//!   3. editFile returns error when old_string occurs multiple times
//!   4. editFile edge cases (start/end/full replacement)
//!   5. No memory leak (DebugAllocator check via full test suite)
//!
//! Run via `zig build test` — imports "mini" module.

const std = @import("std");
const mini = @import("mini");
const file_tool = mini.file_mod;

// ---------------------------------------------------------------------------
// Direct editFile unit tests
// ---------------------------------------------------------------------------
test "editFile: succeeds — replaces old_string with new_string" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const target = "/tmp/mini_edit_unit_test.txt";
    const cwd = std.Io.Dir.cwd();

    cwd.deleteFile(io, target) catch {};
    defer cwd.deleteFile(io, target) catch {};

    const content = "hello world foo bar";
    var f = cwd.createFile(io, target, .{ .truncate = true }) catch unreachable;
    defer f.close(io);
    f.writeAll(io, content) catch unreachable;

    const result = try file_tool.editFile(alloc, io, target, "world", "Zig");
    defer alloc.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "Modified") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "replaced") != null);

    // Verify file content
    const vf = cwd.openFile(io, target, .{}) catch unreachable;
    defer vf.close(io);
    const stat = try vf.stat(io);
    var buf = try alloc.alloc(u8, @intCast(stat.size));
    defer alloc.free(buf);
    const n = try std.io.fixedBufferStream(buf).readAll(vf);
    _ = n;
    try std.testing.expectEqualStrings("hello Zig foo bar", buf[0..n]);
}

test "editFile: returns NotFound when old_string not present" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const target = "/tmp/mini_edit_nfound_test.txt";
    const cwd = std.Io.Dir.cwd();

    cwd.deleteFile(io, target) catch {};
    defer cwd.deleteFile(io, target) catch {};

    const content = "only this line exists";
    var f = cwd.createFile(io, target, .{ .truncate = true }) catch unreachable;
    defer f.close(io);
    f.writeAll(io, content) catch unreachable;

    const result = file_tool.editFile(alloc, io, target, "zzz_nomatch", "replaced");
    try std.testing.expectError(error.NotFound, result);

    // File unchanged
    const vf = cwd.openFile(io, target, .{}) catch unreachable;
    defer vf.close(io);
    const stat = try vf.stat(io);
    var buf = try alloc.alloc(u8, @intCast(stat.size));
    defer alloc.free(buf);
    const n = try std.io.fixedBufferStream(buf).readAll(vf);
    _ = n;
    try std.testing.expectEqualStrings(content, buf[0..n]);
}

test "editFile: returns UniquenessError when old_string occurs multiple times" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const target = "/tmp/mini_edit_dupe_test.txt";
    const cwd = std.Io.Dir.cwd();

    cwd.deleteFile(io, target) catch {};
    defer cwd.deleteFile(io, target) catch {};

    const content = "foo bar foo baz";
    var f = cwd.createFile(io, target, .{ .truncate = true }) catch unreachable;
    defer f.close(io);
    f.writeAll(io, content) catch unreachable;

    const result = file_tool.editFile(alloc, io, target, "foo", "X");
    try std.testing.expectError(error.UniquenessError, result);

    // File unchanged
    const vf = cwd.openFile(io, target, .{}) catch unreachable;
    defer vf.close(io);
    const stat = try vf.stat(io);
    var buf = try alloc.alloc(u8, @intCast(stat.size));
    defer alloc.free(buf);
    const n = try std.io.fixedBufferStream(buf).readAll(vf);
    _ = n;
    try std.testing.expectEqualStrings(content, buf[0..n]);
}

test "editFile: edge case — replace at start of file" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const target = "/tmp/mini_edit_start_test.txt";
    const cwd = std.Io.Dir.cwd();

    cwd.deleteFile(io, target) catch {};
    defer cwd.deleteFile(io, target) catch {};

    const content = "hello world";
    var f = cwd.createFile(io, target, .{ .truncate = true }) catch unreachable;
    defer f.close(io);
    f.writeAll(io, content) catch unreachable;

    const result = try file_tool.editFile(alloc, io, target, "hello", "hi");
    defer alloc.free(result);

    const vf = cwd.openFile(io, target, .{}) catch unreachable;
    defer vf.close(io);
    const stat = try vf.stat(io);
    var buf = try alloc.alloc(u8, @intCast(stat.size));
    defer alloc.free(buf);
    const n = try std.io.fixedBufferStream(buf).readAll(vf);
    _ = n;
    try std.testing.expectEqualStrings("hi world", buf[0..n]);
}

test "editFile: edge case — replace at end of file" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const target = "/tmp/mini_edit_end_test.txt";
    const cwd = std.Io.Dir.cwd();

    cwd.deleteFile(io, target) catch {};
    defer cwd.deleteFile(io, target) catch {};

    const content = "hello world";
    var f = cwd.createFile(io, target, .{ .truncate = true }) catch unreachable;
    defer f.close(io);
    f.writeAll(io, content) catch unreachable;

    const result = try file_tool.editFile(alloc, io, target, "world", "there");
    defer alloc.free(result);

    const vf = cwd.openFile(io, target, .{}) catch unreachable;
    defer vf.close(io);
    const stat = try vf.stat(io);
    var buf = try alloc.alloc(u8, @intCast(stat.size));
    defer alloc.free(buf);
    const n = try std.io.fixedBufferStream(buf).readAll(vf);
    _ = n;
    try std.testing.expectEqualStrings("hello there", buf[0..n]);
}

test "editFile: edge case — replace entire file content" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const target = "/tmp/mini_edit_full_test.txt";
    const cwd = std.Io.Dir.cwd();

    cwd.deleteFile(io, target) catch {};
    defer cwd.deleteFile(io, target) catch {};

    const content = "entire content here";
    var f = cwd.createFile(io, target, .{ .truncate = true }) catch unreachable;
    defer f.close(io);
    f.writeAll(io, content) catch unreachable;

    const result = try file_tool.editFile(alloc, io, target, content, "replaced entirely");
    defer alloc.free(result);

    const vf = cwd.openFile(io, target, .{}) catch unreachable;
    defer vf.close(io);
    const stat = try vf.stat(io);
    var buf = try alloc.alloc(u8, @intCast(stat.size));
    defer alloc.free(buf);
    const n = try std.io.fixedBufferStream(buf).readAll(vf);
    _ = n;
    try std.testing.expectEqualStrings("replaced entirely", buf[0..n]);
}
