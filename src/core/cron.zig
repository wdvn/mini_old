//! cron.zig — Cron job installation and management for mini-agent.
//!
//! Provides utilities to install scheduled cron entries executing mini in
//! non-interactive single-shot mode (-e) via system crontab.

const std = @import("std");
const Allocator = std.mem.Allocator;
pub fn installCronjob(alloc: Allocator, io: std.Io, cron_expr: []const u8, exe_path: []const u8, prompt: []const u8) !void {
    var escaped_prompt = std.ArrayListUnmanaged(u8).empty;
    defer escaped_prompt.deinit(alloc);
    
    for (prompt) |c| {
        if (c == '\'') {
            try escaped_prompt.appendSlice(alloc, "'\\''");
        } else {
            try escaped_prompt.append(alloc, c);
        }
    }

    const cron_cmd = try std.fmt.allocPrint(alloc, "{s} -e '{s}'", .{ exe_path, escaped_prompt.items });
    defer alloc.free(cron_cmd);

    const cron_line = try std.fmt.allocPrint(alloc, "{s} {s}\n", .{ cron_expr, cron_cmd });
    defer alloc.free(cron_line);

    // crontab -l
    const argv_l = [_][]const u8{"crontab", "-l"};
    var child_l = std.process.spawn(io, .{
        .argv = &argv_l,
        .stdout = .pipe,
        .stderr = .ignore,
        .stdin = .ignore,
    }) catch |e| return e;
    
    var current_cron = std.ArrayListUnmanaged(u8).empty;
    defer current_cron.deinit(alloc);
    
    if (child_l.stdout) |out| {
        var buf: [1024]u8 = undefined;
        while (true) {
            const n = out.readStreaming(io, &.{&buf}) catch break;
            if (n == 0) break;
            try current_cron.appendSlice(alloc, buf[0..n]);
        }
    }
    
    _ = child_l.wait(io) catch {};

    if (std.mem.indexOf(u8, current_cron.items, cron_cmd) != null) {
        return error.AlreadyExists;
    }

    try current_cron.appendSlice(alloc, cron_line);

    // crontab -
    const argv_s = [_][]const u8{"crontab", "-"};
    var child_s = try std.process.spawn(io, .{
        .argv = &argv_s,
        .stdout = .ignore,
        .stderr = .inherit,
        .stdin = .pipe,
    });
    
    if (child_s.stdin) |in| {
        // Write data and close pipe
        try in.writeStreamingAll(io, current_cron.items);
        in.close(io);
        child_s.stdin = null;
    }
    
    const term = try child_s.wait(io);
    switch (term) {
        .exited => |code| {
            if (code != 0) return error.CrontabFailed;
        },
        else => return error.CrontabFailed,
    }
}
