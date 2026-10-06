//! core/task/retention.zig — Retention / GC for durable tasks (RFC-030 §4.6).
//!
//! Terminal tasks (completed/failed/stalled/interrupted beyond `retention_days`)
//! have their per-task directories removed; the TaskRecord line is kept for
//! analytics (same discipline as journal pruning).

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const utils = @import("../utils.zig");
const TaskRecord = types.TaskRecord;
const TaskStore = @import("store.zig").TaskStore;

const seconds_per_day: i64 = 24 * 3600 * 1000; // in ms

/// Removes task directories older than `retention_days` for terminal tasks.
pub fn applyRetention(alloc: Allocator, io: std.Io, base_dir: []const u8, retention_days: i64) !void {
    // PSEUDOCODE:
    // 1. Open base dir for iteration
    // 2. For each subdirectory, read its TaskRecord from tasks.jsonl
    // 3. If terminal status and updated_at older than cutoff → deleteTree(dir)
    const cwd = std.Io.Dir.cwd();
    var store = try TaskStore.init(alloc, io, base_dir);
    defer store.deinit();

    const cutoff = utils.milliTimestamp() - retention_days * seconds_per_day;
    var dir = cwd.openDir(io, base_dir, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        var rec = ((store.readLatest(alloc, io, entry.name) catch null) orelse continue);
        defer rec.deinit(alloc);
        switch (rec.status) {
            .running => continue, // never GC an active task
            else => {},
        }
        if (rec.updated_at < cutoff) {
            const sub = try std.fs.path.join(alloc, &.{ base_dir, entry.name });
            defer alloc.free(sub);
            cwd.deleteTree(io, sub) catch {};
        }
    }
}
