//! chat_stream.zig — Turn Renderer & Chat Stream Orchestrator cho mini-agent (RFC-007).
//!
//! Điều phối hiển thị toàn bộ vòng đời của 1 luồng chat (Single Turn):
//! - User Prompt Card
//! - Collapsible / Dimmed Thinking Block
//! - Tool Action Cards & Diff Views
//! - Markdown & Code Highlighting khi stream
//! - Telemetry Status Footer

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
    turn_start_ms: i64 = 0,
    has_printed_response_header: bool = false,
    in_think_tag: bool = false,
    think_tag_buf: [16]u8 = undefined,
    think_tag_len: usize = 0,

    pub fn init(alloc: Allocator, io: std.Io) TurnRenderer {
        return .{
            .alloc = alloc,
            .io = io,
            .spinner = spinner_mod.Spinner.start(),
            .highlighter = markdown_mod.StreamHighlighter.init(),
            .is_thinking = false,
            .think_start_ms = 0,
            .turn_start_ms = 0,
            .has_printed_response_header = false,
            .in_think_tag = false,
            .think_tag_len = 0,
        };
    }

    /// Bắt đầu một Turn mới từ input của User.
    pub fn startTurn(self: *TurnRenderer, prompt: []const u8) void {
        self.turn_start_ms = utils.milliTimestamp();
        self.is_thinking = false;
        self.has_printed_response_header = false;
        self.in_think_tag = false;
        self.think_tag_len = 0;
        self.highlighter = markdown_mod.StreamHighlighter.init();

        // In khung User Prompt
        var top_buf: [128]u8 = undefined;
        const top_line = std.fmt.bufPrint(&top_buf, "\n\x1b[90m{s}─ \x1b[1;34m{s} You\x1b[0m\x1b[90m ─────────────────────────────────────────────────────────────\x1b[0m\n", .{
            term.BOX_TOP_LEFT, term.GLYPH_PROMPT,
        }) catch "\n╭─ ❯ You ─────────────────────────────────────────────────────────────\n";
        term.writeStdout(top_line);

        var it = std.mem.splitScalar(u8, prompt, '\n');
        while (it.next()) |line| {
            var line_buf: [2048]u8 = undefined;
            const formatted = std.fmt.bufPrint(&line_buf, "\x1b[90m{s}\x1b[0m  {s}\n", .{ term.BOX_VERT, line }) catch continue;
            term.writeStdout(formatted);
        }

        var bot_buf: [128]u8 = undefined;
        const bot_line = std.fmt.bufPrint(&bot_buf, "\x1b[90m{s}────────────────────────────────────────────────────────────────────\x1b[0m\n", .{
            term.BOX_BOT_LEFT,
        }) catch "╰────────────────────────────────────────────────────────────────────\n";
        term.writeStdout(bot_line);
    }

    /// Bắt đầu khối Reasoning / Thinking.
    pub fn startThinking(self: *TurnRenderer) void {
        if (self.is_thinking) return;
        self.is_thinking = true;
        self.think_start_ms = utils.milliTimestamp();

        var buf: [128]u8 = undefined;
        const header = std.fmt.bufPrint(&buf, "\n \x1b[90m{s} \x1b[1;90mThinking...\x1b[0m\n", .{
            term.GLYPH_THINK,
        }) catch "\n 💭 Thinking...\n";
        term.writeStdout(header);
    }

    /// Stream một đoạn text trong khối Thinking.
    pub fn streamThinking(self: *TurnRenderer, text: []const u8) void {
        if (!self.is_thinking) {
            self.startThinking();
        }
        term.writeStdout("\x1b[90m");
        term.writeStdout(text);
        term.writeStdout("\x1b[0m");
    }

    /// Kết thúc khối Thinking.
    pub fn endThinking(self: *TurnRenderer) void {
        if (!self.is_thinking) return;
        self.is_thinking = false;
        const now = utils.milliTimestamp();
        const diff = if (now >= self.think_start_ms) now - self.think_start_ms else 0;
        const sec = @as(f64, @floatFromInt(diff)) / 1000.0;

        var buf: [128]u8 = undefined;
        const footer = std.fmt.bufPrint(&buf, "\n \x1b[90m└─ Thought for {d:.1}s\x1b[0m\n", .{sec}) catch "\n └─ Thought\n";
        term.writeStdout(footer);
    }

    /// Stream câu trả lời của AI ra stdout với Markdown & Code highlighting.
    pub fn streamResponse(self: *TurnRenderer, text: []const u8) void {
        if (self.is_thinking) {
            self.endThinking();
        }

        if (!self.has_printed_response_header) {
            self.has_printed_response_header = true;
            var buf: [128]u8 = undefined;
            const header = std.fmt.bufPrint(&buf, "\n \x1b[1;32m{s} mini-agent\x1b[0m\n\n", .{term.GLYPH_BOT}) catch "\n 🤖 mini-agent\n\n";
            term.writeStdout(header);
        }

        self.highlighter.processChunk(self.io, text);
    }

    /// Bắt đầu thực thi một Tool Action.
    pub fn startTool(self: *TurnRenderer, name: []const u8, input_json: []const u8) void {
        if (self.is_thinking) {
            self.endThinking();
        }
        self.highlighter.flush(self.io);

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

        term.writeStdout(line);
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

        var status_buf: [256]u8 = undefined;
        if (is_error) {
            const status_line = std.fmt.bufPrint(&status_buf, "    \x1b[31m{s} Lỗi sau {d}ms:\x1b[0m {s}\n\n", .{
                term.GLYPH_CROSS, duration_ms, if (result.len > 120) result[0..120] else result,
            }) catch return;
            term.writeStdout(status_line);
        } else {
            _ = name;
            const status_line = std.fmt.bufPrint(&status_buf, "    \x1b[32m{s} Hoàn thành ({d}ms)\x1b[0m\n\n", .{
                term.GLYPH_CHECK, duration_ms,
            }) catch return;
            term.writeStdout(status_line);
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
        if (self.is_thinking) {
            self.endThinking();
        }
        self.highlighter.flush(self.io);

        term.writeStdout("\n");

        const total_tokens = stats.prompt_tokens + stats.completion_tokens;
        const elapsed_sec = if (stats.duration_ms > 0)
            @as(f64, @floatFromInt(stats.duration_ms)) / 1000.0
        else blk: {
            const now = utils.milliTimestamp();
            const diff = if (now >= self.turn_start_ms) now - self.turn_start_ms else 0;
            break :blk @as(f64, @floatFromInt(diff)) / 1000.0;
        };

        const ctx_pct = if (stats.max_context_tokens > 0)
            (@as(f64, @floatFromInt(stats.context_tokens)) / @as(f64, @floatFromInt(stats.max_context_tokens))) * 100.0
        else
            0.0;

        var footer_buf: [512]u8 = undefined;
        const footer = std.fmt.bufPrint(&footer_buf,
            " \x1b[90m────────────────────────────────────────────────────────────────────\x1b[0m\n" ++
            " \x1b[90m{s} {d} tokens ({d} prompt / {d} completion) {s} {d:.1}s {s} Context: {d}/{d} ({d:.0}%) {s} {d} act(s)\x1b[0m\n\n",
            .{
                term.GLYPH_STATS,
                total_tokens,
                stats.prompt_tokens,
                stats.completion_tokens,
                term.GLYPH_BULLET,
                elapsed_sec,
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
