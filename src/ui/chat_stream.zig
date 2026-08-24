//! chat_stream.zig — Turn Renderer & Chat Stream Orchestrator cho mini-agent (RFC-007).
//!
//! Điều phối hiển thị toàn bộ vòng đời của 1 luồng chat (Single Turn):
//! - User Prompt Card
//! - Collapsible / Dimmed Thinking Block
//! - Tool Action Cards & Diff Views
//! - Markdown & Code Highlighting khi stream
//! - Telemetry Status Footer

const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const term = @import("terminal.zig");
const spinner_mod = @import("spinner.zig");
const diff_mod = @import("diff_renderer.zig");
const markdown_mod = @import("markdown.zig");
const json_mod = @import("../core/json.zig");
const utils = @import("../core/utils.zig");

pub const TurnStats = struct {
    prompt_tokens: usize = 0,
    completion_tokens: usize = 0,
    reasoning_tokens: usize = 0,
    context_tokens: usize = 0,
    max_context_tokens: usize = 128 * 1024,
    duration_ms: u64 = 0,
    acts_count: usize = 1,
    files_modified: usize = 0,
};

pub const TurnRenderer = struct {
    alloc: Allocator,
    io: std.Io,
    spinner: spinner_mod.Spinner,
    highlighter: markdown_mod.StreamHighlighter,
    is_thinking: bool = false,
    think_start_ms: i64 = 0,
    think_snippet_buf: [80]u8 = undefined,
    think_snippet_len: usize = 0,
    think_last_update_ms: i64 = 0,
    turn_start_ms: i64 = 0,
    has_printed_response_header: bool = false,
    in_think_tag: bool = false,
    think_tag_buf: [16]u8 = undefined,
    think_tag_len: usize = 0,
    consecutive_newlines: usize = 1,
    waiting_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    waiting_thread: ?std.Thread = null,

    pub fn init(alloc: Allocator, io: std.Io) TurnRenderer {
        return .{
            .alloc = alloc,
            .io = io,
            .spinner = spinner_mod.Spinner.start(),
            .highlighter = markdown_mod.StreamHighlighter.init(),
            .is_thinking = false,
            .think_start_ms = 0,
            .think_snippet_len = 0,
            .think_last_update_ms = 0,
            .turn_start_ms = 0,
            .has_printed_response_header = false,
            .in_think_tag = false,
            .think_tag_len = 0,
            .consecutive_newlines = 1,
            .waiting_active = std.atomic.Value(bool).init(false),
            .waiting_thread = null,
        };
    }

    pub fn deinit(self: *TurnRenderer) void {
        self.stopWaiting();
    }

    /// Ghi chuỗi ra terminal và cập nhật trạng thái dòng / newlines liên tiếp.
    pub fn write(self: *TurnRenderer, bytes: []const u8) void {
        if (bytes.len == 0) return;
        term.writeStdout(bytes);
        for (bytes) |c| {
            if (c == '\n') {
                self.consecutive_newlines += 1;
            } else if (c != '\r') {
                self.consecutive_newlines = 0;
            }
        }
    }

    /// Đảm bảo con trỏ đang ở đầu một dòng mới (ít nhất 1 ký tự \n).
    pub fn ensureNewline(self: *TurnRenderer) void {
        if (self.consecutive_newlines == 0) {
            self.write("\n");
        }
    }

    /// Đảm bảo có đúng 1 dòng trống phân cách đoạn (ít nhất 2 ký tự \n).
    pub fn ensureBlankLine(self: *TurnRenderer) void {
        if (self.consecutive_newlines == 0) {
            self.write("\n\n");
        } else if (self.consecutive_newlines == 1) {
            self.write("\n");
        }
    }

    /// Bắt đầu một Turn mới từ input của User.
    pub fn startTurn(self: *TurnRenderer, prompt: []const u8) void {
        _ = prompt;
        self.turn_start_ms = utils.milliTimestamp();
        self.is_thinking = false;
        self.think_snippet_len = 0;
        self.think_last_update_ms = 0;
        self.has_printed_response_header = false;
        self.in_think_tag = false;
        self.think_tag_len = 0;
        self.consecutive_newlines = 1;
        self.highlighter = markdown_mod.StreamHighlighter.init();

        // Bật ngay live spinner trong khi chờ backend phản hồi TTFT
        self.startWaiting();
    }

    /// Bắt đầu spinner chờ phản hồi đầu tiên từ AI backend (TTFT).
    pub fn startWaiting(self: *TurnRenderer) void {
        if (self.waiting_active.load(.acquire)) return;
        if (comptime builtin.is_test) return;
        if (!term.isStdoutTty()) return;

        self.waiting_active.store(true, .release);
        self.waiting_thread = std.Thread.spawn(.{}, waitingLoop, .{self}) catch null;
    }

    fn waitingLoop(self: *TurnRenderer) void {
        var s = spinner_mod.Spinner.start();
        while (self.waiting_active.load(.acquire)) {
            const frame = s.nextFrame();
            var dur_buf: [32]u8 = undefined;
            const dur_str = utils.formatDuration(&dur_buf, s.elapsedMs());
            var buf: [128]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "\r\x1b[2K \x1b[36m{s}\x1b[0m \x1b[90mThinking ({s})...\x1b[0m", .{
                frame, dur_str,
            }) catch break;
            term.writeStdout(line);
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(80), .awake) catch {};
        }
    }

    /// Dừng spinner chờ phản hồi và dọn dẹp dòng hiển thị.
    pub fn stopWaiting(self: *TurnRenderer) void {
        if (!self.waiting_active.load(.acquire)) return;
        self.waiting_active.store(false, .release);
        if (self.waiting_thread) |th| {
            th.join();
            self.waiting_thread = null;
        }
        if (term.isStdoutTty()) {
            term.writeStdout("\r\x1b[2K");
        }
    }

    /// Bắt đầu khối Reasoning / Thinking.
    pub fn startThinking(self: *TurnRenderer) void {
        if (self.is_thinking) return;
        self.is_thinking = true;
        self.think_start_ms = utils.milliTimestamp();
        self.think_snippet_len = 0;
        self.think_last_update_ms = 0;

        self.ensureNewline();
        self.write(" \x1b[90m💭 Thinking...\x1b[0m");
    }

    /// Stream một đoạn text trong khối Thinking (thu gọn trên 1 dòng duy nhất, cập nhật thời gian và snippet).
    pub fn streamThinking(self: *TurnRenderer, text: []const u8) void {
        self.stopWaiting();
        if (!self.is_thinking) {
            self.startThinking();
        }

        // Tích luỹ snippet gần nhất (loại bỏ newlines, chỉ giữ các ký tự hiển thị được)
        for (text) |c| {
            if (c == '\n' or c == '\r' or c == '\t') {
                if (self.think_snippet_len > 0 and self.think_snippet_buf[self.think_snippet_len - 1] != ' ') {
                    if (self.think_snippet_len < self.think_snippet_buf.len) {
                        self.think_snippet_buf[self.think_snippet_len] = ' ';
                        self.think_snippet_len += 1;
                    }
                }
            } else if (c >= 32) {
                if (self.think_snippet_len < self.think_snippet_buf.len) {
                    self.think_snippet_buf[self.think_snippet_len] = c;
                    self.think_snippet_len += 1;
                } else {
                    const shift = 20;
                    std.mem.copyForwards(u8, self.think_snippet_buf[0 .. self.think_snippet_buf.len - shift], self.think_snippet_buf[shift..]);
                    self.think_snippet_len = self.think_snippet_buf.len - shift;
                    self.think_snippet_buf[self.think_snippet_len] = c;
                    self.think_snippet_len += 1;
                }
            }
        }

        const now = utils.milliTimestamp();
        // Rate-limit redraw mỗi 40ms để terminal chạy mượt mà
        if (now - self.think_last_update_ms >= 40) {
            self.think_last_update_ms = now;
            const diff = if (now >= self.think_start_ms) now - self.think_start_ms else 0;
            var dur_buf: [32]u8 = undefined;
            const dur_str = utils.formatDuration(&dur_buf, @intCast(diff));
            const frame = self.spinner.nextFrame();

            const snippet = std.mem.trim(u8, self.think_snippet_buf[0..self.think_snippet_len], " ");
            var out_buf: [256]u8 = undefined;
            const line = if (snippet.len > 0)
                std.fmt.bufPrint(&out_buf, "\r\x1b[2K \x1b[36m{s}\x1b[0m \x1b[90mThinking ({s})...\x1b[0m \x1b[2;90m{s}\x1b[0m", .{
                    frame, dur_str, snippet,
                }) catch ""
            else
                std.fmt.bufPrint(&out_buf, "\r\x1b[2K \x1b[36m{s}\x1b[0m \x1b[90mThinking ({s})...\x1b[0m", .{
                    frame, dur_str,
                }) catch "";

            if (line.len > 0) term.writeStdout(line);
        }
    }

    /// Kết thúc khối Thinking: thu gọn lại thành 1 dòng tóm tắt duy nhất.
    pub fn endThinking(self: *TurnRenderer) void {
        if (!self.is_thinking) return;
        self.is_thinking = false;
        const now = utils.milliTimestamp();
        const diff = if (now >= self.think_start_ms) now - self.think_start_ms else 0;
        var dur_buf: [32]u8 = undefined;
        const dur_str = utils.formatDuration(&dur_buf, @intCast(diff));

        var buf: [128]u8 = undefined;
        const footer = std.fmt.bufPrint(&buf, "\r\x1b[2K \x1b[90m💭 Thought for {s}\x1b[0m\n", .{dur_str}) catch "\r\x1b[2K \x1b[90m💭 Thought\x1b[0m\n";
        self.write(footer);
    }

    /// Stream câu trả lời của AI ra stdout với Markdown & Code highlighting.
    pub fn streamResponse(self: *TurnRenderer, text: []const u8) void {
        self.stopWaiting();
        if (self.is_thinking) {
            self.endThinking();
        }

        const trimmed = std.mem.trim(u8, text, " \r\n\t");
        if (trimmed.len == 0 and !self.has_printed_response_header) return;

        if (!self.has_printed_response_header) {
            self.has_printed_response_header = true;
            self.ensureBlankLine();
            var buf: [128]u8 = undefined;
            const header = std.fmt.bufPrint(&buf, " \x1b[1;32m{s} mini-agent\x1b[0m\n", .{term.GLYPH_BOT}) catch " 💩 mini-agent\n";
            self.write(header);
        }

        self.highlighter.processChunk(self.io, text);
        for (text) |c| {
            if (c == '\n') {
                self.consecutive_newlines += 1;
            } else if (c != '\r') {
                self.consecutive_newlines = 0;
            }
        }
    }

    /// Bắt đầu thực thi một Tool Action.
    pub fn startTool(self: *TurnRenderer, name: []const u8, input_json: []const u8) void {
        self.stopWaiting();
        if (self.is_thinking) {
            self.endThinking();
        }
        self.highlighter.flush(self.io);

        // Nếu văn bản trước đó chưa kết thúc bằng newline, tách 1 dòng trống
        if (self.consecutive_newlines == 0) {
            self.ensureBlankLine();
        } else {
            self.ensureNewline();
        }

        var detail_buf: [256]u8 = undefined;
        var detail: []const u8 = "";

        if (std.mem.eql(u8, name, "bash")) {
            if (json_mod.findString(input_json, "command")) |cmd| {
                const trimmed = if (cmd.len > 80) cmd[0..80] else cmd;
                detail = std.fmt.bufPrint(&detail_buf, "\x1b[35m{s}\x1b[0m", .{trimmed}) catch "";
            }
        } else if (std.mem.eql(u8, name, "file_read") or std.mem.eql(u8, name, "file_write") or std.mem.eql(u8, name, "file_edit")) {
            if (json_mod.findString(input_json, "path")) |path| {
                detail = std.fmt.bufPrint(&detail_buf, "\x1b[34m{s}\x1b[0m", .{path}) catch "";
            }
        } else if (std.mem.eql(u8, name, "web_search")) {
            if (json_mod.findString(input_json, "query")) |q| {
                detail = std.fmt.bufPrint(&detail_buf, "\x1b[32m\"{s}\"\x1b[0m", .{q}) catch "";
            }
        } else if (std.mem.eql(u8, name, "codeact")) {
            detail = "\x1b[35mQuickJS-ng script\x1b[0m";
        }

        var header_buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&header_buf, " \x1b[1;33m{s}\x1b[0m \x1b[1;37m{s}\x1b[0m {s}\n", .{
            term.GLYPH_ACTION, name, detail,
        }) catch return;

        self.write(line);
    }

    /// Hoàn thành một Tool Action.
    pub fn finishTool(self: *TurnRenderer, name: []const u8, result: []const u8, is_error: bool, duration_ms: u64, patch_path: ?[]const u8, patch_diff: ?[]const u8) void {
        if (patch_path) |path| {
            if (patch_diff) |diff| {
                if (diff.len > 0) {
                    diff_mod.renderDiff(self.io, path, diff, .{});
                }
            }
        }

        var dur_buf: [32]u8 = undefined;
        const dur_str = utils.formatDuration(&dur_buf, duration_ms);

        var status_buf: [256]u8 = undefined;
        if (is_error) {
            const status_line = std.fmt.bufPrint(&status_buf, "    \x1b[31m{s} Lỗi sau {s}:\x1b[0m {s}\n", .{
                term.GLYPH_CROSS, dur_str, if (result.len > 120) result[0..120] else result,
            }) catch return;
            self.write(status_line);
        } else {
            _ = name;
            const status_line = std.fmt.bufPrint(&status_buf, "    \x1b[32m{s} Hoàn thành ({s})\x1b[0m\n", .{
                term.GLYPH_CHECK, dur_str,
            }) catch return;
            self.write(status_line);
        }
    }

    /// Xử lý callback text chung (tự động phân biệt <think>...</think> và response text).
    pub fn processTextChunk(self: *TurnRenderer, text: []const u8) void {
        var start: usize = 0;
        var i: usize = 0;
        while (i < text.len) {
            const c = text[i];
            if (self.in_think_tag) {
                const expected = "</think>";
                if (c == '<' or self.think_tag_len > 0) {
                    if (i > start) {
                        self.streamThinking(text[start..i]);
                    }
                    self.think_tag_buf[self.think_tag_len] = c;
                    self.think_tag_len += 1;
                    i += 1;
                    start = i;

                    if (self.think_tag_buf[self.think_tag_len - 1] == expected[self.think_tag_len - 1]) {
                        if (self.think_tag_len == expected.len) {
                            self.in_think_tag = false;
                            self.think_tag_len = 0;
                            self.endThinking();
                        }
                    } else {
                        self.streamThinking(self.think_tag_buf[0..self.think_tag_len]);
                        self.think_tag_len = 0;
                    }
                } else {
                    i += 1;
                }
            } else {
                const expected = "<think>";
                if (c == '<' or self.think_tag_len > 0) {
                    if (i > start) {
                        self.streamResponse(text[start..i]);
                    }
                    self.think_tag_buf[self.think_tag_len] = c;
                    self.think_tag_len += 1;
                    i += 1;
                    start = i;

                    if (self.think_tag_buf[self.think_tag_len - 1] == expected[self.think_tag_len - 1]) {
                        if (self.think_tag_len == expected.len) {
                            self.in_think_tag = true;
                            self.think_tag_len = 0;
                            self.startThinking();
                        }
                    } else {
                        self.streamResponse(self.think_tag_buf[0..self.think_tag_len]);
                        self.think_tag_len = 0;
                    }
                } else {
                    i += 1;
                }
            }
        }
        if (start < text.len) {
            if (self.in_think_tag) {
                self.streamThinking(text[start..]);
            } else {
                self.streamResponse(text[start..]);
            }
        }
    }

    /// Hoàn thành toàn bộ Turn và in Telemetry Status Footer.
    pub fn finishTurn(self: *TurnRenderer, stats: TurnStats) void {
        self.stopWaiting();
        if (self.is_thinking) {
            self.endThinking();
        }
        self.highlighter.flush(self.io);

        term.writeStdout("\n");

        const total_tokens = stats.prompt_tokens + stats.completion_tokens;
        const total_ms = if (stats.duration_ms > 0)
            stats.duration_ms
        else blk: {
            const now = utils.milliTimestamp();
            const diff = if (now >= self.turn_start_ms) now - self.turn_start_ms else 0;
            break :blk @as(u64, @intCast(diff));
        };
        var dur_buf: [32]u8 = undefined;
        const dur_str = utils.formatDuration(&dur_buf, total_ms);

        const ctx_pct = if (stats.max_context_tokens > 0)
            (@as(f64, @floatFromInt(stats.context_tokens)) / @as(f64, @floatFromInt(stats.max_context_tokens))) * 100.0
        else
            0.0;

        var footer_buf: [512]u8 = undefined;
        const footer = std.fmt.bufPrint(&footer_buf,
            " \x1b[90m────────────────────────────────────────────────────────────────────\x1b[0m\n" ++
            " \x1b[90m{s} {d} tokens ({d} prompt / {d} completion) {s} {s} {s} Context: {d}/{d} ({d:.0}%) {s} {d} act(s)\x1b[0m\n\n",
            .{
                term.GLYPH_STATS,
                total_tokens,
                stats.prompt_tokens,
                stats.completion_tokens,
                term.GLYPH_BULLET,
                dur_str,
                term.GLYPH_BULLET,
                stats.context_tokens,
                stats.max_context_tokens,
                ctx_pct,
                term.GLYPH_BULLET,
                stats.acts_count,
            },
        ) catch return;

        term.writeStdout(footer);
    }
};

test "TurnRenderer lifecycle" {
    const renderer = TurnRenderer.init(std.testing.allocator, std.testing.io);
    try std.testing.expect(!renderer.is_thinking);
}
