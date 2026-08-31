//! tools/subagent.zig — Gọi sub-agent con.
//!
//! Spawn `mini -e <task>` với stdout/stderr pipe, đọc song song cả 2 stream
//! (tránh deadlock khi child ghi nhiều vào 1 pipe) và STREAM từng dòng
//! output ra stderr của parent kèm prefix `[subagent]` để user thấy được
//! tiến trình inner đang chạy thay vì tưởng agent bị treo.
//! Output đầy đủ vẫn được buffer và trả về làm tool result cho LLM.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../core/json.zig");
const main = @import("../main.zig");

/// Độ sâu sub-agent mặc định tối đa cho phép để phòng tránh đệ quy vô hạn.
pub const DEFAULT_MAX_SUBAGENT_DEPTH: usize = 2;

/// Giới hạn output buffer (byte) giữ lại để trả về tool result.
const MAX_OUTPUT = 128 * 1024;

/// Lấy độ sâu hiện tại của subagent từ biến môi trường.
pub fn getCurrentDepth() usize {
    if (main.getEnvironMap()) |em| {
        if (em.get("MINI_SUBAGENT_DEPTH")) |v| {
            return std.fmt.parseInt(usize, v, 10) catch 0;
        }
    }
    return 0;
}

/// Lấy độ sâu tối đa cho phép từ cấu hình hoặc mặc định.
pub fn getMaxDepth() usize {
    if (main.getEnvironMap()) |em| {
        if (em.get("MINI_MAX_SUBAGENT_DEPTH")) |v| {
            return std.fmt.parseInt(usize, v, 10) catch DEFAULT_MAX_SUBAGENT_DEPTH;
        }
    }
    return DEFAULT_MAX_SUBAGENT_DEPTH;
}

pub fn executeTool(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    const current_depth = getCurrentDepth();
    const max_depth = getMaxDepth();

    if (current_depth >= max_depth) {
        return std.fmt.allocPrint(alloc, "Lỗi: Đã đạt giới hạn độ sâu subagent tối đa (depth={d}/{d}). Không thể tạo thêm subagent để phòng tránh đệ quy vô hạn.", .{ current_depth, max_depth });
    }

    const task = (try json.findStringOwned(alloc, input_json, "task")) orelse
        (try json.findStringOwned(alloc, input_json, "prompt")) orelse
        (try json.findStringOwned(alloc, input_json, "instruction")) orelse
        (try json.findStringOwned(alloc, input_json, "description")) orelse {
        return std.fmt.allocPrint(alloc, "Lỗi: thiếu tham số 'task'", .{});
    };
    defer alloc.free(task);

    // Thiết lập độ sâu cho tiến trình con kế thừa (qua environ_map truyền vào spawn,
    // vì spawn dùng snapshot environ từ lúc start chứ không đọc setenv libc).
    var depth_buf: [16]u8 = undefined;
    const next_depth_str = std.fmt.bufPrintZ(&depth_buf, "{d}", .{current_depth + 1}) catch "1";
    const env_map = main.getEnvironMap();
    const prev_depth = if (env_map) |em| em.get("MINI_SUBAGENT_DEPTH") else null;
    if (env_map) |em| {
        em.put("MINI_SUBAGENT_DEPTH", next_depth_str) catch {};
    }
    defer {
        if (env_map) |em| {
            // Restore giá trị cũ; nếu không có, đặt "0" (tương đương không phải subagent).
            const restore = prev_depth orelse "0";
            em.put("MINI_SUBAGENT_DEPTH", restore) catch {};
        }
    }

    const exe_path = "/proc/self/exe";
    const argv = [_][]const u8{ exe_path, "-e", task };

    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdout = .pipe,
        .stderr = .pipe,
        .stdin = .ignore,
        .environ_map = env_map,
    });

    // Buffer output đầy đủ để trả về agent (giới hạn MAX_OUTPUT, phần dư drain bỏ).
    var stdout_buf = std.ArrayListUnmanaged(u8).empty;
    defer stdout_buf.deinit(alloc);
    var stderr_buf = std.ArrayListUnmanaged(u8).empty;
    defer stderr_buf.deinit(alloc);

    // Thread đọc stderr song song với stdout để tránh deadlock pipe.
    const stderr_thread = if (child.stderr) |err_pipe|
        std.Thread.spawn(.{}, drainAndStreamStderr, .{ io, err_pipe, &stderr_buf, alloc }) catch null
    else
        null;

    // Main thread đọc + stream stdout.
    if (child.stdout) |out_pipe| {
        _ = drainAndStream(io, out_pipe, &stdout_buf, alloc, "subagent");
    }

    // Chờ thread stderr hoàn tất.
    if (stderr_thread) |t| {
        t.join();
    } else if (child.stderr) |err_pipe| {
        _ = drainAndStream(io, err_pipe, &stderr_buf, alloc, "subagent:err");
    }

    const term = try child.wait(io);

    switch (term) {
        .exited => |code| {
            if (code != 0) {
                const err_detail = if (stderr_buf.items.len > 0) stderr_buf.items else stdout_buf.items;
                return std.fmt.allocPrint(alloc, "Sub-agent kết thúc với mã lỗi: {d}. Chi tiết: {s}", .{ code, err_detail });
            }
        },
        else => {
            const err_detail = if (stderr_buf.items.len > 0) stderr_buf.items else stdout_buf.items;
            return std.fmt.allocPrint(alloc, "Sub-agent bị crash hoặc bị kill. Chi tiết: {s}", .{err_detail});
        },
    }

    if (stdout_buf.items.len == 0) {
        return std.fmt.allocPrint(alloc, "Sub-agent chạy thành công nhưng không trả về nội dung.", .{});
    }

    return alloc.dupe(u8, stdout_buf.items);
}

// ---------------------------------------------------------------------------
// Concurrent pipe I/O + real-time streaming
// ---------------------------------------------------------------------------

/// Đọc pipe song song, append vào buffer (giới hạn MAX_OUTPUT, phần thừa drain bỏ)
/// và stream từng dòng hoàn chỉnh ra stderr parent với prefix `tag`.
fn drainAndStream(io: std.Io, pipe: std.Io.File, buf: *std.ArrayListUnmanaged(u8), alloc: Allocator, tag: []const u8) void {
    var line_buf: [4096]u8 = undefined;
    var line_len: usize = 0;
    var stored: usize = 0;

    while (true) {
        var chunk: [4096]u8 = undefined;
        const n = pipe.readStreaming(io, &.{&chunk}) catch break;
        if (n == 0) break;

        // Giữ buffer đầy đủ tối đa MAX_OUTPUT; phần còn lại vẫn đọc để không block child.
        if (stored < MAX_OUTPUT) {
            const room = MAX_OUTPUT - stored;
            const take = @min(room, n);
            buf.appendSlice(alloc, chunk[0..take]) catch break;
            stored += take;
        }

        // Stream real-time: gom chunk thành dòng, in dòng hoàn chỉnh có prefix.
        for (chunk[0..n]) |c| {
            if (c == '\n') {
                emitLine(tag, line_buf[0..line_len]);
                line_len = 0;
            } else if (line_len < line_buf.len) {
                line_buf[line_len] = c;
                line_len += 1;
            }
        }
    }

    // Flush dòng cuối nếu chưa có newline.
    if (line_len > 0) {
        emitLine(tag, line_buf[0..line_len]);
    }
}

/// Wrapper cho thread đọc stderr — cùng signature để dùng với Thread.spawn.
fn drainAndStreamStderr(io: std.Io, pipe: std.Io.File, buf: *std.ArrayListUnmanaged(u8), alloc: Allocator) void {
    drainAndStream(io, pipe, buf, alloc, "subagent:err");
}

/// In 1 dòng output của subagent ra stderr parent với prefix dim.
fn emitLine(tag: []const u8, line: []const u8) void {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return;

    var truncated_buf: [512]u8 = undefined;
    const display = if (trimmed.len > 500) blk: {
        const n = std.fmt.bufPrint(&truncated_buf, "{s}...", .{trimmed[0..500]}) catch trimmed;
        break :blk n;
    } else trimmed;

    if (std.mem.eql(u8, tag, "subagent:err")) {
        main.stderrPrint("\x1b[2;90m[subagent:err]\x1b[0m {s}\n", .{display});
    } else {
        main.stderrPrint("\x1b[2;90m[subagent]\x1b[0m {s}\n", .{display});
    }
}

// ---------------------------------------------------------------------------
// Unit Tests
// ---------------------------------------------------------------------------

test "subagent: depth check logic" {
    const testing = std.testing;

    const env_map = main.getEnvironMap();
    if (env_map == null) return error.SkipZigTest;

    const em = env_map.?;
    const prev_depth = em.get("MINI_SUBAGENT_DEPTH");
    const prev_max = em.get("MINI_MAX_SUBAGENT_DEPTH");

    em.put("MINI_SUBAGENT_DEPTH", "2") catch {};
    em.put("MINI_MAX_SUBAGENT_DEPTH", "2") catch {};
    defer {
        if (prev_depth) |v| em.put("MINI_SUBAGENT_DEPTH", v) catch {} else em.put("MINI_SUBAGENT_DEPTH", "0") catch {};
        if (prev_max) |v| em.put("MINI_MAX_SUBAGENT_DEPTH", v) catch {} else em.put("MINI_MAX_SUBAGENT_DEPTH", "0") catch {};
    }

    try testing.expectEqual(@as(usize, 2), getCurrentDepth());
    try testing.expectEqual(@as(usize, 2), getMaxDepth());

    const res = try executeTool(testing.allocator, main.getIo(), "{\"task\":\"test infinite loop\"}");
    defer testing.allocator.free(res);

    try testing.expect(std.mem.indexOf(u8, res, "Đã đạt giới hạn độ sâu subagent tối đa") != null);
}
