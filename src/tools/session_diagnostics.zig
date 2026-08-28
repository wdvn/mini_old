//! tools/session_diagnostics.zig — Công cụ chẩn đoán tiến trình & telemetry phiên làm việc.
//!
//! Cung cấp khả năng tự truy xuất thông tin hệ thống cho LLM:
//!   - operation="list": Liệt kê các session/subagent, PID, trạng thái sống/chết, mode (REPL vs Subagent), state.
//!   - operation="detail": Xem chi tiết journal, số act đã chạy, trạng thái hiện tại, lịch sử lỗi.
//!   - operation="kill": Dừng an toàn hoặc cưỡng bức tiến trình bị treo.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../core/json.zig");
const utils = @import("../core/utils.zig");

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern fn kill(pid: std.c.pid_t, sig: c_int) c_int;

fn getSessionsDir(alloc: Allocator) ![]u8 {
    if (getenv("MINI_HOME")) |mh| {
        const span = std.mem.span(mh);
        if (span.len > 0) return std.fmt.allocPrint(alloc, "{s}/sessions", .{span});
    }
    if (getenv("HOME")) |h| {
        const span = std.mem.span(h);
        return std.fmt.allocPrint(alloc, "{s}/.mini/sessions", .{span});
    }
    return alloc.dupe(u8, "./.mini/sessions");
}

pub const SessionMode = enum {
    repl,
    single_shot,
    subagent,
    unknown,
};

pub const SessionState = enum {
    idle_waiting_input,
    executing_act,
    between_acts,
    completed,
    crashed,
    finished,
    unknown,
};

pub const SessionSummary = struct {
    pid: i32,
    is_alive: bool,
    mode: SessionMode,
    state: SessionState,
    description: []const u8,
    last_act_id: usize = 0,
    last_event: []const u8 = "",
    last_timestamp: i64 = 0,
    error_count: usize = 0,
    total_events: usize = 0,
};

fn checkIsAlive(pid: i32) bool {
    if (pid <= 0) return false;
    return kill(pid, 0) == 0;
}

fn detectSessionMode(alloc: Allocator, io: std.Io, pid: i32) SessionMode {
    var proc_buf: [64]u8 = undefined;
    const cmdline_path = std.fmt.bufPrint(&proc_buf, "/proc/{d}/cmdline", .{pid}) catch return .unknown;

    const file = std.Io.Dir.cwd().openFile(io, cmdline_path, .{}) catch return .unknown;
    defer file.close(io);

    var buf: [512]u8 = undefined;
    const n = file.readStreaming(io, &.{&buf}) catch return .unknown;
    const cmdline = buf[0..n];

    _ = alloc;
    if (std.mem.indexOf(u8, cmdline, "-e") != null or std.mem.indexOf(u8, cmdline, "--exec") != null) {
        return .single_shot;
    }
    if (std.mem.indexOf(u8, cmdline, "mini") != null) {
        return .repl;
    }
    return .unknown;
}

pub fn analyzeJournal(alloc: Allocator, io: std.Io, file_path: []const u8, pid: i32) !SessionSummary {
    const is_alive = checkIsAlive(pid);
    const mode = if (is_alive) detectSessionMode(alloc, io, pid) else .unknown;

    const file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    const file_size: usize = @intCast(stat.size);

    var summary = SessionSummary{
        .pid = pid,
        .is_alive = is_alive,
        .mode = mode,
        .state = .unknown,
        .description = "",
        .last_act_id = 0,
        .last_event = "unknown",
        .last_timestamp = 0,
        .error_count = 0,
        .total_events = 0,
    };

    if (file_size == 0) {
        summary.state = if (is_alive) .executing_act else .finished;
        summary.description = if (is_alive) "Tiến trình đang khởi động..." else "File log trống.";
        return summary;
    }

    // Đọc toàn bộ nội dung journal (tối đa 512KB)
    const read_size = @min(file_size, 512 * 1024);
    const buf = try alloc.alloc(u8, read_size);
    defer alloc.free(buf);

    const n = try utils.readAll(io, file, buf);
    const content = buf[0..n];

    var line_it = std.mem.splitScalar(u8, content, '\n');
    var last_non_empty_line: ?[]const u8 = null;

    while (line_it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        summary.total_events += 1;
        last_non_empty_line = trimmed;

        if (std.mem.indexOf(u8, trimmed, "\"error_detail\":null") == null and std.mem.indexOf(u8, trimmed, "\"error_detail\":") != null) {
            summary.error_count += 1;
        }
    }

    if (last_non_empty_line) |last_line| {
        if (json.findString(last_line, "event_type")) |ev| {
            summary.last_event = try alloc.dupe(u8, ev);
        }
        if (json.findInt(last_line, "act_id", usize)) |act_id| {
            summary.last_act_id = act_id;
        }
        if (json.findInt(last_line, "timestamp", i64)) |ts| {
            summary.last_timestamp = ts;
        }
    }

    // Xác định trạng thái nghiệp vụ chuẩn xác
    if (is_alive) {
        if (std.mem.eql(u8, summary.last_event, "task_completed")) {
            if (summary.mode == .repl) {
                summary.state = .idle_waiting_input;
                summary.description = "Phiên REPL tương tác đang rảnh, nằm chờ người dùng nhập câu hỏi mới tại dấu nhắc You >";
            } else {
                summary.state = .completed;
                summary.description = "Nhiệm vụ đã hoàn tất thành công.";
            }
        } else if (std.mem.eql(u8, summary.last_event, "act_started")) {
            summary.state = .executing_act;
            summary.description = "Đang thực thi Act (chờ LLM stream phản hồi hoặc đang chạy Tool)";
        } else if (std.mem.eql(u8, summary.last_event, "act_completed")) {
            summary.state = .between_acts;
            summary.description = "Đã hoàn thành Act gần nhất, đang chuẩn bị cho Act tiếp theo";
        } else if (std.mem.eql(u8, summary.last_event, "act_failed")) {
            summary.state = .crashed;
            summary.description = "Act gặp sự cố lỗi";
        } else {
            summary.state = .executing_act;
            summary.description = "Đang hoạt động bình thường";
        }
    } else {
        if (std.mem.eql(u8, summary.last_event, "task_completed")) {
            summary.state = .completed;
            summary.description = "Tiến trình đã hoàn thành và thoát bình thường.";
        } else {
            summary.state = .finished;
            summary.description = "Tiến trình đã kết thúc/dừng.";
        }
    }

    return summary;
}

/// Liệt kê tất cả các sessions gần nhất
pub fn listSessions(alloc: Allocator, io: std.Io) ![]u8 {
    const sessions_dir = try getSessionsDir(alloc);
    defer alloc.free(sessions_dir);

    var dir = std.Io.Dir.cwd().openDir(io, sessions_dir, .{ .iterate = true }) catch |e| {
        return std.fmt.allocPrint(alloc, "Không thể mở thư mục sessions: {s} ({s})", .{ sessions_dir, @errorName(e) });
    };
    defer dir.close(io);

    var w = utils.BufWriter.init(alloc);
    defer w.deinit();

    try w.print("## Danh sách Sessions & Subprocesses (~/.mini/sessions)\n\n", .{});
    try w.print("| PID | Sống | Mode | State | Last Act | Last Event | Chi tiết |\n", .{});
    try w.print("|---|---|---|---|---|---|---|\n", .{});

    var count: usize = 0;
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "journal_") or !std.mem.endsWith(u8, entry.name, ".jsonl")) continue;

        // Parse PID
        const pid_str = entry.name[8 .. entry.name.len - 6];
        const pid = std.fmt.parseInt(i32, pid_str, 10) catch continue;

        var path_buf: [512]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ sessions_dir, entry.name }) catch continue;

        const summary = analyzeJournal(alloc, io, full_path, pid) catch continue;
        count += 1;

        const alive_str = if (summary.is_alive) "🟢 **ALIVE**" else "⚪ DEAD";
        const mode_str = switch (summary.mode) {
            .repl => "REPL (interactive)",
            .single_shot => "Single-shot (-e)",
            .subagent => "Sub-agent",
            .unknown => "Unknown",
        };
        const state_str = switch (summary.state) {
            .idle_waiting_input => "💤 `idle_waiting_input`",
            .executing_act => "⚡ `executing_act`",
            .between_acts => "⏳ `between_acts`",
            .completed => "✓ `completed`",
            .crashed => "❌ `crashed`",
            .finished => "⏹ `finished`",
            .unknown => "`unknown`",
        };

        try w.print("| `{d}` | {s} | {s} | {s} | Act {d} | `{s}` | {s} |\n", .{
            summary.pid,
            alive_str,
            mode_str,
            state_str,
            summary.last_act_id,
            summary.last_event,
            summary.description,
        });
    }

    if (count == 0) {
        try w.writeAll("\n*(Không tìm thấy session journal nào trong thư mục)*\n");
    }

    return alloc.dupe(u8, w.list.items);
}

/// Xem chi tiết một session theo PID
pub fn detailSession(alloc: Allocator, io: std.Io, pid: i32) ![]u8 {
    const sessions_dir = try getSessionsDir(alloc);
    defer alloc.free(sessions_dir);

    var path_buf: [512]u8 = undefined;
    const full_path = std.fmt.bufPrint(&path_buf, "{s}/journal_{d}.jsonl", .{ sessions_dir, pid }) catch return error.BufferTooSmall;

    const summary = analyzeJournal(alloc, io, full_path, pid) catch |e| {
        return std.fmt.allocPrint(alloc, "Không tìm thấy session cho PID {d} (lỗi: {s}) tại {s}", .{ pid, @errorName(e), full_path });
    };

    var w = utils.BufWriter.init(alloc);
    defer w.deinit();

    try w.print("## Báo cáo Chẩn đoán Session PID `{d}`\n\n", .{pid});
    try w.print("- **Trạng thái tiến trình**: {s}\n", .{if (summary.is_alive) "🟢 Đang chạy (ALIVE)" else "⚪ Đã thoát (EXITED)"});
    try w.print("- **Chế độ thực thi**: `{s}`\n", .{@tagName(summary.mode)});
    try w.print("- **Trạng thái nghiệp vụ**: `{s}`\n", .{@tagName(summary.state)});
    try w.print("- **Đánh giá bản chất**: **{s}**\n", .{summary.description});
    try w.print("- **Act mới nhất**: `{d}` (Event: `{s}`)\n", .{ summary.last_act_id, summary.last_event });
    try w.print("- **Tổng số lỗi ghi nhận**: `{d}`\n", .{summary.error_count});
    try w.print("- **Đường dẫn Journal**: `{s}`\n\n", .{full_path});

    // Trích xuất 10 events gần nhất
    try w.print("### Các sự kiện gần nhất (Journal Tail):\n```json\n", .{});
    const file = std.Io.Dir.cwd().openFile(io, full_path, .{}) catch null;
    if (file) |f| {
        defer f.close(io);
        const stat = f.stat(io) catch null;
        if (stat) |st| {
            const size: usize = @intCast(st.size);
            const read_sz = @min(size, 512 * 1024);
            const buf = alloc.alloc(u8, read_sz) catch null;
            if (buf) |b| {
                defer alloc.free(b);
                const n = utils.readAll(io, f, b) catch 0;
                var it = std.mem.splitScalar(u8, b[0..n], '\n');
                var lines = std.ArrayListUnmanaged([]const u8).empty;
                defer lines.deinit(alloc);
                while (it.next()) |l| {
                    const trimmed = std.mem.trim(u8, l, " \r\t");
                    if (trimmed.len > 0) lines.append(alloc, trimmed) catch {};
                }
                const start_idx = if (lines.items.len > 10) lines.items.len - 10 else 0;
                for (lines.items[start_idx..]) |line| {
                    try w.print("{s}\n", .{line});
                }
            }
        }
    }
    try w.print("```\n", .{});

    return alloc.dupe(u8, w.list.items);
}

/// Dừng một session / tiến trình theo PID
pub fn killSession(alloc: Allocator, pid: i32, signal: ?[]const u8) ![]u8 {
    if (pid <= 0) {
        return std.fmt.allocPrint(alloc, "PID không hợp lệ: {d}", .{pid});
    }

    if (!checkIsAlive(pid)) {
        return std.fmt.allocPrint(alloc, "Tiến trình PID {d} đã kết thúc từ trước (không còn hoạt động).", .{pid});
    }

    const sig_num: c_int = if (signal) |s| blk: {
        if (std.mem.eql(u8, s, "SIGKILL") or std.mem.eql(u8, s, "9")) break :blk 9;
        if (std.mem.eql(u8, s, "SIGINT") or std.mem.eql(u8, s, "2")) break :blk 2;
        break :blk 15; // SIGTERM
    } else 15;

    const rc = kill(pid, sig_num);
    if (rc == 0) {
        return std.fmt.allocPrint(alloc, "Đã gửi tín hiệu dừng (signal {d}) tới PID {d} thành công.", .{ sig_num, pid });
    } else {
        return std.fmt.allocPrint(alloc, "Không thể dừng PID {d} (mã lỗi errno: {d}).", .{ pid, rc });
    }
}

pub fn executeTool(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    const op = (try json.findStringOwned(alloc, input_json, "operation")) orelse "list";
    defer alloc.free(op);

    if (std.mem.eql(u8, op, "list")) {
        return listSessions(alloc, io);
    } else if (std.mem.eql(u8, op, "detail")) {
        const pid = json.findInt(input_json, "pid", i32) orelse
            return std.fmt.allocPrint(alloc, "Lỗi: operation='detail' yêu cầu tham số 'pid' kiểu số nguyên.", .{});
        return detailSession(alloc, io, pid);
    } else if (std.mem.eql(u8, op, "kill") or std.mem.eql(u8, op, "stop")) {
        const pid = json.findInt(input_json, "pid", i32) orelse
            return std.fmt.allocPrint(alloc, "Lỗi: operation='kill' yêu cầu tham số 'pid' kiểu số nguyên.", .{});
        const sig = json.findString(input_json, "signal");
        return killSession(alloc, pid, sig);
    }

    return std.fmt.allocPrint(alloc, "Lỗi: operation không hợp lệ '{s}'. Các giá trị hợp lệ: list, detail, kill.", .{op});
}
