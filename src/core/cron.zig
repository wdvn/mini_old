//! cron.zig — Cron job installation and management for mini-agent.
//!
//! Provides utilities to install scheduled cron entries executing mini in
//! non-interactive single-shot mode (-e) via system crontab.

const std = @import("std");
const Allocator = std.mem.Allocator;
fn escapePrompt(alloc: Allocator, prompt: []const u8) ![]u8 {
    // PSEUDOCODE:
    // 1. Iterate over characters in prompt.
    // 2. Escape single quotes with '\'' for shell compatibility.
    var escaped = std.ArrayListUnmanaged(u8).empty;
    errdefer escaped.deinit(alloc);
    for (prompt) |c| {
        if (c == '\'') {
            try escaped.appendSlice(alloc, "'\\''");
        } else {
            try escaped.append(alloc, c);
        }
    }
    return escaped.toOwnedSlice(alloc);
}

fn readCurrentCrontab(alloc: Allocator, io: std.Io) !std.ArrayListUnmanaged(u8) {
    // PSEUDOCODE:
    // 1. Spawn `crontab -l`.
    // 2. Read output into ArrayList and return.
    const argv_l = [_][]const u8{ "crontab", "-l" };
    var child_l = std.process.spawn(io, .{
        .argv = &argv_l,
        .stdout = .pipe,
        .stderr = .ignore,
        .stdin = .ignore,
    }) catch |e| return e;

    var current_cron = std.ArrayListUnmanaged(u8).empty;
    errdefer current_cron.deinit(alloc);

    if (child_l.stdout) |out| {
        var buf: [1024]u8 = undefined;
        while (true) {
            const n = out.readStreaming(io, &.{&buf}) catch break;
            if (n == 0) break;
            try current_cron.appendSlice(alloc, buf[0..n]);
        }
    }
    _ = child_l.wait(io) catch {};
    return current_cron;
}

fn writeCrontab(io: std.Io, cron_content: []const u8) !void {
    // PSEUDOCODE:
    // 1. Spawn `crontab -`.
    // 2. Pipe cron_content to stdin, close, and verify exit code.
    const argv_s = [_][]const u8{ "crontab", "-" };
    var child_s = try std.process.spawn(io, .{
        .argv = &argv_s,
        .stdout = .ignore,
        .stderr = .inherit,
        .stdin = .pipe,
    });

    if (child_s.stdin) |in| {
        try in.writeStreamingAll(io, cron_content);
        in.close(io);
        child_s.stdin = null;
    }

    const term = try child_s.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.CrontabFailed,
        else => return error.CrontabFailed,
    }
}

pub fn installCronjob(alloc: Allocator, io: std.Io, cron_expr: []const u8, exe_path: []const u8, prompt: []const u8) !void {
    // PSEUDOCODE:
    // 1. Escape prompt for shell argument.
    // 2. Format cron command and line.
    // 3. Read current crontab, check duplicate, and append new line.
    // 4. Write back updated crontab.
    const escaped = try escapePrompt(alloc, prompt);
    defer alloc.free(escaped);

    const cron_cmd = try std.fmt.allocPrint(alloc, "{s} -e '{s}'", .{ exe_path, escaped });
    defer alloc.free(cron_cmd);

    const cron_line = try std.fmt.allocPrint(alloc, "{s} {s}\n", .{ cron_expr, cron_cmd });
    defer alloc.free(cron_line);

    var current_cron = try readCurrentCrontab(alloc, io);
    defer current_cron.deinit(alloc);

    if (std.mem.indexOf(u8, current_cron.items, cron_cmd) != null) {
        return error.AlreadyExists;
    }

    try current_cron.appendSlice(alloc, cron_line);
    try writeCrontab(io, current_cron.items);
}
