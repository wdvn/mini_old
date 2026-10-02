//! history/backup.zig — Serialization and file backup/restore for History.

const std = @import("std");
const proto = @import("../protocol.zig");
const utils = @import("../utils.zig");
const types = @import("types.zig");
const History = types.History;

/// Backs up history to a JSON file.
pub fn backupToFile(self: *const History, io: std.Io, path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(io, path, .{ .truncate = true });
    defer file.close(io);

    var out_buf = std.ArrayList(u8).empty;
    defer out_buf.deinit(self.alloc);
    var aw = std.Io.Writer.Allocating.fromArrayList(self.alloc, &out_buf);
    try std.json.Stringify.value(self.msgs.items, .{}, &aw.writer);
    out_buf = aw.toArrayList();

    try file.writeStreamingAll(io, out_buf.items);
}

/// Restores history from a JSON file.
pub fn restoreFromFile(self: *History, io: std.Io, path: []const u8) !void {
    // PSEUDOCODE:
    // 1. Read file content into buffer.
    // 2. Parse JSON into []proto.Message.
    // 3. Clear existing history and deep-clone parsed messages.
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    const buf = try self.alloc.alloc(u8, @intCast(stat.size));
    defer self.alloc.free(buf);

    const n = try utils.readAll(io, file, buf);
    const parsed = try std.json.parseFromSlice([]proto.Message, self.alloc, buf[0..n], .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    self.clear();
    for (parsed.value) |msg| {
        const content_copy = try types.History.cloneContent(self.alloc, msg.content);
        try self.msgs.append(self.alloc, .{
            .role = msg.role,
            .content = content_copy,
            .tier = msg.tier,
        });
    }
}
