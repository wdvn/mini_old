//! tools/bash.zig — Tool thực thi lệnh shell.
//!
//! Chạy lệnh shell qua `/bin/sh -c` và trả về stdout + stderr.
//! Có safety check để chặn các lệnh nguy hiểm.
//!
//! ## Concurrent I/O
//! Dùng thread riêng để đọc stderr song song với stdout, tránh deadlock
//! khi child process ghi nhiều data vào cả hai pipe cùng lúc.
//! Pipe được drain hoàn toàn (data thừa bị bỏ) để child không bị block.
//!
//! ## Safety blocklist
//! Các pattern sau bị chặn vô điều kiện:
//!   - `rm -rf /` hoặc `rm -rf ~`
//!   - `dd if=`, `mkfs`, `wipefs`
//!   - `shutdown`, `reboot`, `halt`, `init 0`, `init 6`
//!   - `git push --force`, `git push -f`
//!
//! ## Tool input schema
//! ```json
//! { "command": "ls -la /tmp" }
//! ```
//!
//! ## Giới hạn
//!   - Output bị truncate ở 128KB
//!   - Working directory: CWD của process

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../core/json.zig");
const utils = @import("../core/utils.zig");

/// Danh sách pattern lệnh bị chặn.
const BLOCKED_PATTERNS = [_][]const u8{
    "rm -rf /",
    "rm -rf ~",
    "dd if=",
    "mkfs",
    "wipefs",
    "shutdown",
    "reboot",
    "halt",
    "init 0",
    "init 6",
    "git push --force",
    "git push -f",
    "git reset --hard",
    "git clean -f",
};

/// Giới hạn output (byte). Heap-allocated, không dùng stack.
const MAX_OUTPUT = 128 * 1024;

/// Thực thi tool bash.
/// Input: JSON string với trường "command".
/// Output: stdout/stderr của lệnh, hoặc thông báo lỗi.
pub fn executeTool(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    const command = json.findString(input_json, "command") orelse
        return std.fmt.allocPrint(alloc, "Lỗi: thiếu trường 'command'", .{});

    // Safety check
    for (&BLOCKED_PATTERNS) |pattern| {
        if (std.mem.indexOf(u8, command, pattern) != null) {
            return std.fmt.allocPrint(alloc,
                "BLOCKED: Lệnh bị chặn bởi safety policy.\nLệnh: {s}\nPattern: {s}",
                .{ command, pattern },
            );
        }
    }

    const stdin_str = json.findString(input_json, "stdin");

    return executeCommand(alloc, io, command, stdin_str);
}

// ---------------------------------------------------------------------------
// Concurrent pipe I/O
// ---------------------------------------------------------------------------

/// Drain pipe hoàn toàn vào buffer. Giữ lại tối đa buf.len bytes đầu tiên.
/// Phần data thừa vẫn được đọc hết để child process không bị block trên pipe.
fn drainPipe(io: std.Io, pipe: std.Io.File, buf: []u8) usize {
    var stored: usize = 0;
    while (true) {
        if (stored < buf.len) {
            // Còn chỗ trong buffer — đọc vào
            const n = pipe.readStreaming(io, &.{buf[stored..]}) catch break;
            if (n == 0) break;
            stored += n;
        } else {
            // Buffer đầy — drain phần còn lại để tránh deadlock
            var sink: [4096]u8 = undefined;
            const n = pipe.readStreaming(io, &.{&sink}) catch break;
            if (n == 0) break;
        }
    }
    return stored;
}

/// Wrapper cho thread stderr — cùng signature để dùng với Thread.spawn.
fn drainStderrThread(io: std.Io, pipe: std.Io.File, buf: []u8, len_out: *usize) void {
    len_out.* = drainPipe(io, pipe, buf);
}

// ---------------------------------------------------------------------------
// Command execution
// ---------------------------------------------------------------------------

/// Chạy lệnh shell và thu thập output.
/// Dùng thread riêng đọc stderr song song với stdout để tránh deadlock pipe.
/// Buffer được heap-allocate (128KB mỗi stream).
fn executeCommand(alloc: Allocator, io: std.Io, command: []const u8, stdin_str: ?[]const u8) ![]u8 {
    const argv = [_][]const u8{ "/bin/sh", "-c", command };
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = if (stdin_str != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    if (stdin_str) |s| {
        if (child.stdin) |in_pipe| {
            try in_pipe.writeStreamingAll(io, s);
            in_pipe.close(io);
            child.stdin = null;
        }
    }


    // Heap-allocate buffers
    const stdout_buf = try alloc.alloc(u8, MAX_OUTPUT);
    defer alloc.free(stdout_buf);
    const stderr_buf = try alloc.alloc(u8, MAX_OUTPUT);
    defer alloc.free(stderr_buf);

    var stdolen: usize = 0;
    var stdelen: usize = 0;

    // Spawn thread đọc stderr song song
    const stderr_thread = if (child.stderr) |err_pipe|
        std.Thread.spawn(.{}, drainStderrThread, .{ io, err_pipe, stderr_buf, &stdelen }) catch null
    else
        null;

    // Main thread đọc stdout
    if (child.stdout) |out_pipe| {
        stdolen = drainPipe(io, out_pipe, stdout_buf);
    }

    // Chờ stderr thread hoàn tất
    if (stderr_thread) |t| {
        t.join();
    } else if (child.stderr) |err_pipe| {
        // Fallback sequential nếu spawn thread thất bại
        stdelen = drainPipe(io, err_pipe, stderr_buf);
    }

    // Chờ child process kết thúc (sau khi đã drain hết pipe)
    const term = child.wait(io) catch |e| {
        return std.fmt.allocPrint(alloc, "Lỗi wait: {s}", .{@errorName(e)});
    };

    const exit_code: u8 = switch (term) {
        .exited => |code| code,
        .signal => |sig| {
            return std.fmt.allocPrint(alloc, "Killed by signal {d}", .{@intFromEnum(sig)});
        },
        else => 1,
    };

    // Build kết quả
    var result = utils.BufWriter.init(alloc);
    errdefer result.deinit();
    const w = &result;

    if (stdolen > 0) {
        try w.writeAll(stdout_buf[0..stdolen]);
    }
    if (stdelen > 0) {
        if (stdolen > 0) try w.writeByte('\n');
        try w.writeAll(stderr_buf[0..stdelen]);
    }
    if (exit_code != 0 and result.list.items.len == 0) {
        try w.print("Exit code: {d}", .{exit_code});
    }
    if (result.list.items.len == 0) {
        try w.writeAll("(no output)");
    }

    return result.toOwnedSlice();
}
