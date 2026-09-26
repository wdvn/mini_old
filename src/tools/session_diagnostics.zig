//! tools/session_diagnostics.zig — Process diagnostics & session telemetry tool.
//!
//! Provides system inspection capabilities for LLMs:
//!   - operation="list": List sessions/subagents, PID, alive status, mode (REPL vs Subagent), state.
//!   - operation="detail": Inspect journal details, executed acts, current state, error history.
//!   - operation="kill": Safely or forcefully terminate a hanging process.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../core/json.zig");
const utils = @import("../core/utils.zig");

extern fn kill(pid: std.c.pid_t, sig: c_int) c_int;

fn getSessionsDir(alloc: Allocator) ![]u8 {
    if (utils.getEnvSlice("MINI_HOME")) |mh| {
        if (mh.len > 0) return std.fmt.allocPrint(alloc, "{s}/sessions", .{mh});
    }
    if (utils.getEnvSlice("HOME")) |h| {
        return std.fmt.allocPrint(alloc, "{s}/.mini/sessions", .{h});
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
    throttled,
    context_overflow,
    cancelled,
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
    last_event_buf: [64]u8 = [_]u8{0} ** 64,
    last_event_len: usize = 0,
    last_timestamp: i64 = 0,
    error_count: usize = 0,
    total_events: usize = 0,
    last_error_code: u32 = 0,
    last_error_name_buf: [48]u8 = [_]u8{0} ** 48,
    last_error_name_len: usize = 0,
    last_error_msg_buf: [256]u8 = [_]u8{0} ** 256,
    last_error_msg_len: usize = 0,

    // RFC-024 §3.5: plan-methodology event counts (scanned from journal lines).
    plan_phase_changed: usize = 0,
    plan_step_verified: usize = 0,
    plan_review_outcome: usize = 0,
    skill_loaded: usize = 0,
    post_compact_reinject: usize = 0,

    pub fn lastEvent(self: *const SessionSummary) []const u8 {
        if (self.last_event_len == 0) return "unknown";
        return self.last_event_buf[0..self.last_event_len];
    }

    pub fn setLastEvent(self: *SessionSummary, ev: []const u8) void {
        const copy_len = @min(ev.len, self.last_event_buf.len);
        @memcpy(self.last_event_buf[0..copy_len], ev[0..copy_len]);
        self.last_event_len = copy_len;
    }

    pub fn lastErrorName(self: *const SessionSummary) []const u8 {
        if (self.last_error_name_len == 0) return "";
        return self.last_error_name_buf[0..self.last_error_name_len];
    }

    pub fn lastErrorMessage(self: *const SessionSummary) []const u8 {
        if (self.last_error_msg_len == 0) return "";
        return self.last_error_msg_buf[0..self.last_error_msg_len];
    }
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

fn extractRecentErrorDetails(summary: *SessionSummary, err_line: []const u8) void {
    // PSEUDOCODE: Parse http_code, error_name, and error message into summary buffers.
    if (json.findInt(err_line, "http_code", u32)) |code| {
        summary.last_error_code = code;
    }
    if (json.findString(err_line, "error_name")) |name| {
        const copy_len = @min(name.len, summary.last_error_name_buf.len);
        @memcpy(summary.last_error_name_buf[0..copy_len], name[0..copy_len]);
        summary.last_error_name_len = copy_len;
    }
    if (json.findString(err_line, "server_error") orelse json.findString(err_line, "message")) |msg| {
        const copy_len = @min(msg.len, summary.last_error_msg_buf.len);
        @memcpy(summary.last_error_msg_buf[0..copy_len], msg[0..copy_len]);
        summary.last_error_msg_len = copy_len;
    }
}

fn evaluateAliveState(summary: *SessionSummary, last_ev: []const u8) void {
    // PSEUDOCODE: Determine operational state for running process based on last event.
    if (std.mem.eql(u8, last_ev, "task_completed")) {
        if (summary.mode == .repl) {
            summary.state = .idle_waiting_input;
            summary.description = "REPL session idle, waiting for command at You >";
        } else {
            summary.state = .completed;
            summary.description = "Task completed successfully.";
        }
    } else if (std.mem.eql(u8, last_ev, "task_interrupted")) {
        summary.state = .cancelled;
        summary.description = "Task interrupted by user (Ctrl+C).";
    } else if (std.mem.eql(u8, last_ev, "llm_call_throttled")) {
        summary.state = .throttled;
        summary.description = "Backend rate limited (429/503), waiting for retry";
    } else if (std.mem.eql(u8, last_ev, "llm_context_overflow")) {
        summary.state = .context_overflow;
        summary.description = "Context limit exceeded, compressing context via MemAct";
    } else if (std.mem.eql(u8, last_ev, "act_started")) {
        summary.state = .executing_act;
        summary.description = "Executing Act (waiting for LLM stream or tool execution)";
    } else if (std.mem.eql(u8, last_ev, "act_completed")) {
        summary.state = .between_acts;
        summary.description = "Latest Act completed, preparing for next Act";
    } else if (std.mem.eql(u8, last_ev, "act_failed")) {
        summary.state = .crashed;
        summary.description = "Act encountered an error";
    } else {
        summary.state = .executing_act;
        summary.description = "Operating normally";
    }
}

fn evaluateExitedState(summary: *SessionSummary, last_ev: []const u8) void {
    // PSEUDOCODE: Determine final state for terminated process based on last event.
    if (std.mem.eql(u8, last_ev, "task_completed")) {
        summary.state = .completed;
        summary.description = "Process completed and exited normally.";
    } else if (std.mem.eql(u8, last_ev, "task_interrupted")) {
        summary.state = .cancelled;
        summary.description = "Process stopped due to user interruption (Ctrl+C).";
    } else if (std.mem.eql(u8, last_ev, "act_failed") or std.mem.eql(u8, last_ev, "llm_call_throttled")) {
        summary.state = .crashed;
        summary.description = "Process stopped due to backend error / retry limit reached.";
    } else {
        summary.state = .finished;
        summary.description = "Process finished / stopped.";
    }
}

fn scanJournalLines(summary: *SessionSummary, content: []const u8) struct { last_line: ?[]const u8, err_line: ?[]const u8 } {
    // PSEUDOCODE: Scan lines to count events, errors, and extract last lines.
    // Also count RFC-024 plan-methodology events by matching "event_type":"<name>".
    var line_it = std.mem.splitScalar(u8, content, '\n');
    var last_non_empty: ?[]const u8 = null;
    var last_err: ?[]const u8 = null;

    while (line_it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        summary.total_events += 1;
        last_non_empty = trimmed;

        if (std.mem.indexOf(u8, trimmed, "\"error_detail\":null") == null and std.mem.indexOf(u8, trimmed, "\"error_detail\":") != null) {
            summary.error_count += 1;
            last_err = trimmed;
        }

        // RFC-024 §3.5: tally plan-methodology events for the diagnostics section.
        if (std.mem.indexOf(u8, trimmed, "\"event_type\":\"plan_phase_changed\"") != null) summary.plan_phase_changed += 1;
        if (std.mem.indexOf(u8, trimmed, "\"event_type\":\"plan_step_verified\"") != null) summary.plan_step_verified += 1;
        if (std.mem.indexOf(u8, trimmed, "\"event_type\":\"plan_review_outcome\"") != null) summary.plan_review_outcome += 1;
        if (std.mem.indexOf(u8, trimmed, "\"event_type\":\"skill_loaded\"") != null) summary.skill_loaded += 1;
        if (std.mem.indexOf(u8, trimmed, "\"event_type\":\"post_compact_reinject\"") != null) summary.post_compact_reinject += 1;
    }
    return .{ .last_line = last_non_empty, .err_line = last_err };
}

fn applyScannedJournal(summary: *SessionSummary, scanned: anytype, is_alive: bool) void {
    if (scanned.last_line) |last_line| {
        if (json.findString(last_line, "event_type")) |ev| summary.setLastEvent(ev);
        if (json.findInt(last_line, "act_id", usize)) |act_id| summary.last_act_id = act_id;
        if (json.findInt(last_line, "timestamp", i64)) |ts| summary.last_timestamp = ts;
    }
    if (scanned.err_line) |err_line| {
        extractRecentErrorDetails(summary, err_line);
    }
    if (is_alive) {
        evaluateAliveState(summary, summary.lastEvent());
    } else {
        evaluateExitedState(summary, summary.lastEvent());
    }
}

pub fn analyzeJournal(alloc: Allocator, io: std.Io, file_path: []const u8, pid: i32) !SessionSummary {
    // PSEUDOCODE:
    // 1. Detect process liveness and execution mode.
    // 2. Open journal file and handle empty file.
    // 3. Scan lines for event counts, timestamps, and error details.
    // 4. Evaluate operational state and description.
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
        .last_timestamp = 0,
        .error_count = 0,
        .total_events = 0,
    };

    if (file_size == 0) {
        summary.state = if (is_alive) .executing_act else .finished;
        summary.description = if (is_alive) "Process is starting up..." else "Empty log file.";
        return summary;
    }

    const read_size = @min(file_size, 512 * 1024);
    const buf = try alloc.alloc(u8, read_size);
    defer alloc.free(buf);

    const n = try utils.readAll(io, file, buf);
    const scanned = scanJournalLines(&summary, buf[0..n]);
    applyScannedJournal(&summary, scanned, is_alive);
    return summary;
}

fn formatSessionTableRow(alloc: Allocator, w: *utils.BufWriter, summary: SessionSummary) !void {
    // PSEUDOCODE: Format session properties into a markdown table row.
    const alive_str = if (summary.is_alive) "🟢 **ALIVE**" else "⚪ DEAD";
    const mode_str = switch (summary.mode) {
        .repl => "REPL (interactive)",
        .single_shot => "Single-shot (-e)",
        .subagent => "Sub-agent",
        .unknown => "Unknown",
    };
    const state_str = switch (summary.state) {
        .idle_waiting_input => "💤 `idle`",
        .executing_act => "⚡ `running`",
        .between_acts => "⏳ `between`",
        .throttled => "⚠️ `throttled`",
        .context_overflow => "🔄 `overflow`",
        .cancelled => "⏹ `cancelled`",
        .completed => "✓ `completed`",
        .crashed => "❌ `crashed`",
        .finished => "⚪ `finished`",
        .unknown => "`unknown`",
    };

    const err_str = if (summary.error_count > 0)
        try std.fmt.allocPrint(alloc, "🔴 {d}", .{summary.error_count})
    else
        try alloc.dupe(u8, "0");
    defer alloc.free(err_str);

    try w.print("| `{d}` | {s} | {s} | {s} | Act {d} | {s} | {s} |\n", .{
        summary.pid,
        alive_str,
        mode_str,
        state_str,
        summary.last_act_id,
        err_str,
        summary.description,
    });
}

/// List all recent sessions
pub fn listSessions(alloc: Allocator, io: std.Io) ![]u8 {
    // PSEUDOCODE:
    // 1. Open ~/.mini/sessions directory.
    // 2. Iterate journal files and parse PID.
    // 3. For each session, analyze journal and render table row via formatSessionTableRow.
    const sessions_dir = try getSessionsDir(alloc);
    defer alloc.free(sessions_dir);

    var dir = std.Io.Dir.cwd().openDir(io, sessions_dir, .{ .iterate = true }) catch |e| {
        return std.fmt.allocPrint(alloc, "Could not open sessions directory: {s} ({s})", .{ sessions_dir, @errorName(e) });
    };
    defer dir.close(io);

    var w = utils.BufWriter.init(alloc);
    defer w.deinit();

    try w.print("## Sessions & Subprocesses List (~/.mini/sessions)\n\n", .{});
    try w.print("| PID | Alive | Mode | State | Last Act | Errors | Details |\n|---|---|---|---|---|---|---|\n", .{});

    var count: usize = 0;
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "journal_") or !std.mem.endsWith(u8, entry.name, ".jsonl")) continue;

        const pid_str = entry.name[8 .. entry.name.len - 6];
        const pid = std.fmt.parseInt(i32, pid_str, 10) catch continue;

        var path_buf: [512]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ sessions_dir, entry.name }) catch continue;

        const summary = analyzeJournal(alloc, io, full_path, pid) catch continue;
        count += 1;
        try formatSessionTableRow(alloc, &w, summary);
    }

    if (count == 0) {
        try w.writeAll("\n*(No session journals found in directory)*\n");
    }

    return alloc.dupe(u8, w.list.items);
}

fn formatEventLine(w: *utils.BufWriter, line: []const u8) !void {
    // PSEUDOCODE: Format single journal event line with status icon and error metadata.
    const act_id = json.findInt(line, "act_id", usize) orelse 0;
    const ev = json.findString(line, "event_type") orelse "event";
    const desc = json.findString(line, "description") orelse "";
    const has_err = std.mem.indexOf(u8, line, "\"error_detail\":null") == null and
        std.mem.indexOf(u8, line, "\"error_detail\":") != null;

    const icon = if (std.mem.eql(u8, ev, "act_completed") or std.mem.eql(u8, ev, "task_completed"))
        "✓"
    else if (std.mem.eql(u8, ev, "task_interrupted"))
        "⏹"
    else if (has_err or std.mem.eql(u8, ev, "act_failed"))
        "⚠️"
    else
        "⚡";

    if (has_err) {
        const http_code = json.findInt(line, "http_code", u32) orelse 0;
        const err_msg = json.findString(line, "server_error") orelse json.findString(line, "message");
        if (http_code > 0 and err_msg != null) {
            try w.print("- {s} `[Act {d}]` **`{s}`**: {s} *(HTTP {d}: {s})*\n", .{ icon, act_id, ev, desc, http_code, err_msg.? });
            return;
        }
    }
    try w.print("- {s} `[Act {d}]` **`{s}`**: {s}\n", .{ icon, act_id, ev, desc });
}

fn printRecentEventsTail(alloc: Allocator, io: std.Io, w: *utils.BufWriter, full_path: []const u8) !void {
    // PSEUDOCODE: Read file tail and print up to 10 recent events via formatEventLine.
    try w.print("### Recent Events (Journal Tail):\n\n", .{});
    const file = std.Io.Dir.cwd().openFile(io, full_path, .{}) catch return;
    defer file.close(io);

    const stat = file.stat(io) catch return;
    const size: usize = @intCast(stat.size);
    const read_sz = @min(size, 512 * 1024);
    const buf = alloc.alloc(u8, read_sz) catch return;
    defer alloc.free(buf);

    const n = utils.readAll(io, file, buf) catch 0;
    var it = std.mem.splitScalar(u8, buf[0..n], '\n');
    var lines = std.ArrayListUnmanaged([]const u8).empty;
    defer lines.deinit(alloc);

    while (it.next()) |l| {
        const trimmed = std.mem.trim(u8, l, " \r\t");
        if (trimmed.len > 0) lines.append(alloc, trimmed) catch {};
    }

    const start_idx = if (lines.items.len > 10) lines.items.len - 10 else 0;
    for (lines.items[start_idx..]) |line| {
        try formatEventLine(w, line);
    }
}

/// Inspect detailed session state by PID
pub fn detailSession(alloc: Allocator, io: std.Io, pid: i32) ![]u8 {
    // PSEUDOCODE:
    // 1. Locate journal file path and analyze session.
    // 2. Format session status summary block.
    // 3. Print recent events tail via printRecentEventsTail.
    const sessions_dir = try getSessionsDir(alloc);
    defer alloc.free(sessions_dir);

    var path_buf: [512]u8 = undefined;
    const full_path = std.fmt.bufPrint(&path_buf, "{s}/journal_{d}.jsonl", .{ sessions_dir, pid }) catch return error.BufferTooSmall;

    const summary = analyzeJournal(alloc, io, full_path, pid) catch |e| {
        return std.fmt.allocPrint(alloc, "Session not found for PID {d} (error: {s}) at {s}", .{ pid, @errorName(e), full_path });
    };

    var w = utils.BufWriter.init(alloc);
    defer w.deinit();

    try w.print("## Session Diagnostic Report PID `{d}`\n\n", .{pid});
    try w.print("- **Process status**: {s}\n", .{if (summary.is_alive) "🟢 Running (ALIVE)" else "⚪ Exited (EXITED)"});
    try w.print("- **Execution mode**: `{s}`\n", .{@tagName(summary.mode)});
    try w.print("- **Operational state**: `{s}`\n", .{@tagName(summary.state)});
    try w.print("- **Assessment**: **{s}**\n", .{summary.description});
    try w.print("- **Latest Act**: `{d}` (Event: `{s}`)\n", .{ summary.last_act_id, summary.lastEvent() });
    try w.print("- **Total events**: `{d}` (Recorded errors: `{d}`)\n", .{ summary.total_events, summary.error_count });

    if (summary.last_error_code > 0 or summary.lastErrorName().len > 0 or summary.lastErrorMessage().len > 0) {
        try w.print("- **Most recent error**: `HTTP {d}` [{s}]: {s}\n", .{
            summary.last_error_code,
            if (summary.lastErrorName().len > 0) summary.lastErrorName() else "Error",
            if (summary.lastErrorMessage().len > 0) summary.lastErrorMessage() else "No error details",
        });
    }
    try w.print("- **Journal path**: `{s}`\n\n", .{full_path});

    // RFC-024 §3.5: plan-methodology telemetry section (the plan-path half of
    // RFC-020's telemetry requirement). Only shown when the session has any
    // plan/skill/reinject activity, so legacy sessions stay unchanged.
    const has_plan_activity = summary.plan_phase_changed > 0 or
        summary.plan_step_verified > 0 or
        summary.plan_review_outcome > 0 or
        summary.skill_loaded > 0 or
        summary.post_compact_reinject > 0;
    if (has_plan_activity) {
        try w.writeAll("## Plan Methodology (RFC-024)\n");
        try w.print("- **Plan phase changes**: {d}\n", .{summary.plan_phase_changed});
        try w.print("- **Step verifications**: {d}\n", .{summary.plan_step_verified});
        try w.print("- **Review outcomes**: {d}\n", .{summary.plan_review_outcome});
        try w.print("- **Skills read**: {d}\n", .{summary.skill_loaded});
        try w.print("- **Post-compact reinjections**: {d}\n\n", .{summary.post_compact_reinject});
    }

    try printRecentEventsTail(alloc, io, &w, full_path);
    return alloc.dupe(u8, w.list.items);
}

/// Terminate a session / process by PID
pub fn killSession(alloc: Allocator, pid: i32, signal: ?[]const u8) ![]u8 {
    if (pid <= 0) {
        return std.fmt.allocPrint(alloc, "Invalid PID: {d}", .{pid});
    }

    if (!checkIsAlive(pid)) {
        return std.fmt.allocPrint(alloc, "Process PID {d} already terminated (no longer active).", .{pid});
    }

    const sig_num: c_int = if (signal) |s| blk: {
        if (std.mem.eql(u8, s, "SIGKILL") or std.mem.eql(u8, s, "9")) break :blk 9;
        if (std.mem.eql(u8, s, "SIGINT") or std.mem.eql(u8, s, "2")) break :blk 2;
        break :blk 15; // SIGTERM default
    } else 15;

    const rc = kill(pid, sig_num);
    if (rc == 0) {
        return std.fmt.allocPrint(alloc, "Successfully sent termination signal (signal {d}) to PID {d}.", .{ sig_num, pid });
    } else {
        return std.fmt.allocPrint(alloc, "Failed to stop PID {d} (errno: {d}).", .{ pid, rc });
    }
}

pub fn executeTool(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    const op = (try json.findStringOwned(alloc, input_json, "operation")) orelse "list";
    defer alloc.free(op);

    if (std.mem.eql(u8, op, "list")) {
        return listSessions(alloc, io);
    } else if (std.mem.eql(u8, op, "detail")) {
        const pid = json.findInt(input_json, "pid", i32) orelse
            return std.fmt.allocPrint(alloc, "Error: operation='detail' requires integer 'pid' parameter.", .{});
        return detailSession(alloc, io, pid);
    } else if (std.mem.eql(u8, op, "kill") or std.mem.eql(u8, op, "stop")) {
        const pid = json.findInt(input_json, "pid", i32) orelse
            return std.fmt.allocPrint(alloc, "Error: operation='kill' requires integer 'pid' parameter.", .{});
        const sig = json.findString(input_json, "signal");
        return killSession(alloc, pid, sig);
    }

    return std.fmt.allocPrint(alloc, "Error: invalid operation '{s}'. Valid values: list, detail, kill.", .{op});
}
