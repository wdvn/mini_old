//! signals.zig — Hệ thống bắt tín hiệu OS (SIGINT/Ctrl+C) và điều phối Interrupt cho mini-agent.
//!
//! Đảm bảo khi người dùng nhấn Ctrl+C:
//! - Đánh dấu cờ atomic `interrupted`
//! - Ngắt luồng HTTP streaming (SSE)
//! - Ngắt thực thi QuickJS Engine
//! - Giữ nguyên tiến trình REPL và quay lại prompt thay vì crash/exit đột ngột.

const std = @import("std");
const builtin = @import("builtin");
const quickjs_engine = @import("../runtime/quickjs_engine.zig");

pub var interrupted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
pub var active_engine: ?*quickjs_engine.Engine = null;

/// Kiểm tra xem tác vụ hiện tại có bị yêu cầu ngắt bởi Ctrl+C không.
pub fn isInterrupted() bool {
    return interrupted.load(.acquire);
}

/// Thiết lập trạng thái cờ ngắt.
pub fn setInterrupted(val: bool) void {
    interrupted.store(val, .release);
}

/// Kiểm tra và xóa cờ ngắt về false (atomic swap).
pub fn checkAndResetInterrupted() bool {
    return interrupted.swap(false, .acq_rel);
}

/// Đăng ký QuickJS Engine đang chạy để ngắt khi nhận SIGINT.
pub fn registerActiveEngine(engine: ?*quickjs_engine.Engine) void {
    active_engine = engine;
}

fn handleSigInt(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    interrupted.store(true, .release);
    if (active_engine) |eng| {
        eng.requestInterrupt();
    }
}

/// Khởi tạo và đăng ký signal handlers cho hệ điều hành.
pub fn initSignalHandlers() void {
    if (comptime builtin.os.tag != .windows) {
        const act = std.posix.Sigaction{
            .handler = .{ .handler = handleSigInt },
            .mask = std.mem.zeroes(std.posix.sigset_t),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &act, null);
    }
}

test "signals: atomic set and check" {
    setInterrupted(false);
    try std.testing.expect(!isInterrupted());

    setInterrupted(true);
    try std.testing.expect(isInterrupted());

    try std.testing.expect(checkAndResetInterrupted());
    try std.testing.expect(!isInterrupted());
}
