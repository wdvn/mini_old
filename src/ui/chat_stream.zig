//! chat_stream.zig — Turn Renderer & Unified Stream Event Lifecycle for mini-agent (RFC-007).
//!
//! Stream Event Lifecycle Pipeline architecture:
//!
//!   AI Backend (SSE / Chunks)
//!             │
//!             ▼
//!   StreamEventParser (Lexer / Tokenizer FSM)
//!             │
//!             ├─► .think_start / .think_chunk / .think_end
//!             ├─► .codeact_start / .codeact_chunk / .codeact_end
//!             └─► .text_start / .text_chunk / .text_end
//!             │
//!             ▼
//!   TurnRenderer (UI Presentation FSM)
//!             │
//!             ├─► .waiting ──► .thinking ──► .codeact_live ──► .codeact_ready ──► .tool_executing
//!             └─► Telemetry Status Footer

const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const term = @import("terminal.zig");
const spinner_mod = @import("spinner.zig");
const diff_mod = @import("diff_renderer.zig");
const markdown_mod = @import("markdown.zig");
const json_mod = @import("../core/json.zig");
const utils = @import("../core/utils.zig");
const signals = @import("../core/signals.zig");
const main = @import("../main.zig");

/// Calculate visual display length (number of visible columns on terminal) of a string,
/// ignoring all ANSI escape sequences (e.g. `\x1b[...m`, `\x1b[...K`, etc.).
pub fn visibleWidth(str: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < str.len) {
        if (str[i] == 0x1b and i + 1 < str.len and str[i + 1] == '[') {
            i += 2;
            while (i < str.len and str[i] != 'm' and str[i] != 'K' and str[i] != 'J' and str[i] != 'H' and str[i] != 'h' and str[i] != 'l') {
                i += 1;
            }
            if (i < str.len) i += 1;
            continue;
        }
        if (str[i] == '\r' or str[i] == '\n') {
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(str[i]) catch 1;
        width += 1;
        i += len;
    }
    return width;
}

/// Truncate ANSI-colored string so visual width <= max_cols.
/// Automatically closes ANSI escape sequence with `\x1b[0m` at the end if truncated.
/// Active reasoning effort label for the current Act, set by AgentLoop
/// before streaming (e.g. "low" | "medium" | "high" | "minimal" | "none").
/// Displayed live in the Thinking header and the Thought footer.
pub var active_effort: ?[]const u8 = null;

pub fn truncateAnsi(buf: []u8, str: []const u8, max_cols: usize) []const u8 {
    if (visibleWidth(str) <= max_cols) return str;
    if (max_cols <= 3) return "";

    const target_cols = max_cols - 3;
    var current_width: usize = 0;
    var i: usize = 0;
    var last_safe_idx: usize = 0;

    while (i < str.len) {
        if (str[i] == 0x1b and i + 1 < str.len and str[i + 1] == '[') {
            i += 2;
            while (i < str.len and str[i] != 'm' and str[i] != 'K' and str[i] != 'J' and str[i] != 'H' and str[i] != 'h' and str[i] != 'l') {
                i += 1;
            }
            if (i < str.len) i += 1;
            last_safe_idx = i;
            continue;
        }
        if (str[i] == '\r' or str[i] == '\n') {
            i += 1;
            continue;
        }
        const seq_len = std.unicode.utf8ByteSequenceLength(str[i]) catch 1;
        if (current_width + 1 > target_cols) break;
        current_width += 1;
        i += seq_len;
        last_safe_idx = i;
    }

    return std.fmt.bufPrint(buf, "{s}...\x1b[0m", .{str[0..last_safe_idx]}) catch str[0..last_safe_idx];
}

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

/// Lifecycle events emitted from LLM streaming
pub const StreamEvent = union(enum) {
    think_start,
    think_chunk: []const u8,
    think_end,

    codeact_start,
    codeact_chunk: []const u8,
    codeact_end,

    text_start,
    text_chunk: []const u8,
    text_end,
};

pub const open_think_tags = [_][]const u8{
    "<think>",
    "<思考>",
    "<推理>",
    "<反思>",
    "<推敲>",
};

pub const close_think_tags = [_][]const u8{
    "</think>",
    "</思考>",
    "</推理>",
    "</反思>",
    "</推敲>",
};

fn isPrefixOfAny(buf: []const u8, tags: []const []const u8) bool {
    for (tags) |tag| {
        if (buf.len <= tag.len and std.mem.eql(u8, buf, tag[0..buf.len])) {
            return true;
        }
    }
    return false;
}

fn isExactMatch(buf: []const u8, tags: []const []const u8) bool {
    for (tags) |tag| {
        if (std.mem.eql(u8, buf, tag)) {
            return true;
        }
    }
    return false;
}

/// Finite State Machine parsing stream chunks and emitting typed StreamEvents
pub const StreamEventParser = struct {
    pub const ParseState = enum {
        idle,
        in_think,
        in_codeact,
        in_text,
    };

    state: ParseState = .idle,
    tag_buf: [32]u8 = undefined,
    tag_len: usize = 0,
    fence_buf: [32]u8 = undefined,
    fence_len: usize = 0,
    in_fence_check: bool = false,
    closing_backticks: usize = 0,

    pub fn init() StreamEventParser {
        return .{
            .state = .idle,
            .tag_len = 0,
            .fence_len = 0,
            .in_fence_check = false,
            .closing_backticks = 0,
        };
    }

    pub fn resetAct(self: *StreamEventParser) void {
        self.state = .idle;
        self.tag_len = 0;
        self.fence_len = 0;
        self.in_fence_check = false;
        self.closing_backticks = 0;
    }

    pub fn feed(self: *StreamEventParser, chunk: []const u8, context: anytype, comptime emitFn: fn (@TypeOf(context), StreamEvent) void) void {
        var i: usize = 0;
        while (i < chunk.len) {
            const c = chunk[i];

            // 1. Parse <think>...</think> and Chinese variants (<思考>...</思考>, <推理>, <反思>, <推敲>)
            if (self.state == .in_think) {
                if (c == '<' or self.tag_len > 0) {
                    if (self.tag_len < self.tag_buf.len) {
                        self.tag_buf[self.tag_len] = c;
                        self.tag_len += 1;
                        i += 1;

                        const cur = self.tag_buf[0..self.tag_len];
                        if (isExactMatch(cur, &close_think_tags)) {
                            self.state = .idle;
                            self.tag_len = 0;
                            emitFn(context, .think_end);
                        } else if (isPrefixOfAny(cur, &close_think_tags)) {
                            // Valid prefix of a close tag, continue buffering
                        } else {
                            emitFn(context, .{ .think_chunk = cur });
                            self.tag_len = 0;
                        }
                    } else {
                        emitFn(context, .{ .think_chunk = self.tag_buf[0..self.tag_len] });
                        self.tag_len = 0;
                    }
                } else {
                    emitFn(context, .{ .think_chunk = chunk[i .. i + 1] });
                    i += 1;
                }
                continue;
            }

            // 2. Parse inside CodeAct block (```js ... ```)
            if (self.state == .in_codeact) {
                if (c == '`') {
                    self.closing_backticks += 1;
                    if (self.closing_backticks == 3) {
                        self.state = .idle;
                        self.closing_backticks = 0;
                        emitFn(context, .codeact_end);
                        i += 1;
                        continue;
                    }
                    i += 1;
                    continue;
                } else {
                    if (self.closing_backticks > 0) {
                        var k: usize = 0;
                        while (k < self.closing_backticks) : (k += 1) {
                            emitFn(context, .{ .codeact_chunk = "`" });
                        }
                        self.closing_backticks = 0;
                    }
                    emitFn(context, .{ .codeact_chunk = chunk[i .. i + 1] });
                    i += 1;
                    continue;
                }
            }

            // 3. Parse opening Code Fence ```
            if (self.in_fence_check) {
                if (self.fence_len < 3 and c != '`') {
                    self.in_fence_check = false;
                    if (self.state != .in_text) {
                        self.state = .in_text;
                        emitFn(context, .text_start);
                    }
                    emitFn(context, .{ .text_chunk = self.fence_buf[0..self.fence_len] });
                    self.fence_len = 0;
                    continue;
                }

                if (c == '\n') {
                    self.in_fence_check = false;
                    const raw_lang = if (self.fence_len > 3) self.fence_buf[3..self.fence_len] else "";
                    const lang = std.mem.trim(u8, raw_lang, " \r\t");

                    if (std.mem.eql(u8, lang, "js") or
                        std.mem.eql(u8, lang, "javascript") or
                        std.mem.eql(u8, lang, "ts") or
                        std.mem.eql(u8, lang, "typescript") or
                        std.mem.eql(u8, lang, "codeact") or
                        std.mem.eql(u8, lang, "node"))
                    {
                        if (self.state == .in_text) {
                            self.state = .idle;
                            emitFn(context, .text_end);
                        }
                        self.state = .in_codeact;
                        self.closing_backticks = 0;
                        emitFn(context, .codeact_start);
                    } else {
                        if (self.state != .in_text) {
                            self.state = .in_text;
                            emitFn(context, .text_start);
                        }
                        emitFn(context, .{ .text_chunk = self.fence_buf[0..self.fence_len] });
                        emitFn(context, .{ .text_chunk = "\n" });
                    }
                    self.fence_len = 0;
                    i += 1;
                    continue;
                } else {
                    if (self.fence_len < self.fence_buf.len) {
                        self.fence_buf[self.fence_len] = c;
                        self.fence_len += 1;
                        i += 1;
                    } else {
                        self.in_fence_check = false;
                        if (self.state != .in_text) {
                            self.state = .in_text;
                            emitFn(context, .text_start);
                        }
                        emitFn(context, .{ .text_chunk = self.fence_buf[0..self.fence_len] });
                        self.fence_len = 0;
                    }
                    continue;
                }
            }

            // 4. Check opening thinking tags (<think>, <思考>, <推理>, <反思>, <推敲>)
            if (c == '<' or self.tag_len > 0) {
                if (self.tag_len < self.tag_buf.len) {
                    self.tag_buf[self.tag_len] = c;
                    self.tag_len += 1;
                    i += 1;

                    const cur = self.tag_buf[0..self.tag_len];
                    if (isExactMatch(cur, &open_think_tags)) {
                        if (self.state == .in_text) {
                            self.state = .idle;
                            emitFn(context, .text_end);
                        }
                        self.state = .in_think;
                        self.tag_len = 0;
                        emitFn(context, .think_start);
                    } else if (isPrefixOfAny(cur, &open_think_tags)) {
                        // Valid prefix of an open tag, continue buffering
                    } else {
                        if (self.state != .in_text) {
                            self.state = .in_text;
                            emitFn(context, .text_start);
                        }
                        emitFn(context, .{ .text_chunk = cur });
                        self.tag_len = 0;
                    }
                } else {
                    if (self.state != .in_text) {
                        self.state = .in_text;
                        emitFn(context, .text_start);
                    }
                    emitFn(context, .{ .text_chunk = self.tag_buf[0..self.tag_len] });
                    self.tag_len = 0;
                }
                continue;
            }

            // 5. Check start of code fence ```
            if (c == '`') {
                self.in_fence_check = true;
                self.fence_buf[0] = '`';
                self.fence_len = 1;
                i += 1;
                continue;
            }

            // 6. Regular text chunk
            if (self.state != .in_text) {
                self.state = .in_text;
                emitFn(context, .text_start);
            }
            emitFn(context, .{ .text_chunk = chunk[i .. i + 1] });
            i += 1;
        }
    }
};

/// UI Presentation Layer coordinating rendering states of a Turn
pub const TurnRenderer = struct {
    pub const UIState = enum {
        idle,
        waiting,
        thinking,
        codeact_live,
        codeact_ready,
        text_streaming,
        tool_executing,
    };

    alloc: Allocator,
    io: std.Io,
    spinner: spinner_mod.Spinner,
    highlighter: markdown_mod.StreamHighlighter,
    parser: StreamEventParser,
    ui_state: UIState = .idle,

    // Public compatibility flags (queried by tests/repl)
    is_thinking: bool = false,
    is_codeact: bool = false,
    in_codeact: bool = false,

    turn_start_ms: i64 = 0,
    has_printed_response_header: bool = false,
    consecutive_newlines: usize = 1,

    // Thinking live state
    think_start_ms: i64 = 0,
    think_snippet_buf: [80]u8 = undefined,
    think_snippet_len: usize = 0,
    think_last_update_ms: i64 = 0,

    // CodeAct live state (in-place multi-line max 3 lines)
    codeact_start_ms: i64 = 0,
    codeact_last_update_ms: i64 = 0,
    codeact_curr_buf: [128]u8 = undefined,
    codeact_curr_len: usize = 0,
    codeact_line1_buf: [128]u8 = undefined,
    codeact_line1_len: usize = 0,
    codeact_line2_buf: [128]u8 = undefined,
    codeact_line2_len: usize = 0,
    codeact_rendered_lines: usize = 0,
    codeact_total_lines: usize = 0,

    last_error_signature: u64 = 0,

    waiting_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    waiting_thread: ?std.Thread = null,

    pub fn init(alloc: Allocator, io: std.Io) TurnRenderer {
        return .{
            .alloc = alloc,
            .io = io,
            .spinner = spinner_mod.Spinner.start(),
            .highlighter = markdown_mod.StreamHighlighter.init(),
            .parser = StreamEventParser.init(),
            .ui_state = .idle,
            .is_thinking = false,
            .is_codeact = false,
            .in_codeact = false,
            .turn_start_ms = 0,
            .has_printed_response_header = false,
            .consecutive_newlines = 1,
            .think_start_ms = 0,
            .think_snippet_len = 0,
            .think_last_update_ms = 0,
            .codeact_start_ms = 0,
            .codeact_last_update_ms = 0,
            .codeact_curr_len = 0,
            .codeact_line1_len = 0,
            .codeact_line2_len = 0,
            .codeact_rendered_lines = 0,
            .codeact_total_lines = 0,
            .last_error_signature = 0,
            .waiting_active = std.atomic.Value(bool).init(false),
            .waiting_thread = null,
        };
    }

    pub fn deinit(self: *TurnRenderer) void {
        self.stopWaiting();
        self.clearInplaceLine();
    }

    // -----------------------------------------------------------------------
    // In-place Terminal Rendering Primitives (Anti-wrap & ANSI safe)
    // -----------------------------------------------------------------------

    /// Safely overwrite current line in-place, preventing column overflow (anti line-wrap).
    pub fn renderInplaceLine(self: *TurnRenderer, text: []const u8) void {
        _ = self;
        if (comptime builtin.is_test) return;
        if (!term.isStdoutTty()) return;

        const win = term.getTerminalSize();
        const max_cols: usize = if (win.cols > 2) win.cols - 1 else 80;

        var trunc_buf: [512]u8 = undefined;
        const safe_text = truncateAnsi(&trunc_buf, text, max_cols);

        term.writeStdout("\r\x1b[2K");
        term.writeStdout(safe_text);
    }

    /// Clear current line in-place and return cursor to column 0.
    pub fn clearInplaceLine(self: *TurnRenderer) void {
        _ = self;
        if (comptime builtin.is_test) return;
        if (!term.isStdoutTty()) return;
        term.writeStdout("\r\x1b[2K");
    }

    /// Reset error signature on successful act or turn completion.
    pub fn resetErrorSignature(self: *TurnRenderer) void {
        self.last_error_signature = 0;
        self.clearInplaceLine();
    }

    /// Compute 64-bit FNV-1a error signature combining HTTP code and raw response body.
    pub fn computeErrorSignature(http_code: u32, raw_opt: ?[]const u8) u64 {
        var hash: u64 = 0xcbf29ce484222325 ^ @as(u64, http_code);
        hash *%= 0x100000001b3;
        if (raw_opt) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            for (trimmed) |b| {
                hash ^= b;
                hash *%= 0x100000001b3;
            }
        }
        return hash;
    }

    /// Display generic backend error block, independent of provider-specific error schema or format.
    pub fn showBackendError(self: *TurnRenderer, http_code: u32, raw_opt: ?[]const u8) void {
        self.stopWaiting();
        if (self.ui_state == .thinking or self.is_thinking) {
            self.endThinking();
        }
        self.clearInplaceLine();
        self.ensureNewline();

        if (http_code > 0) {
            main.stderrPrint("\n\x1b[1;31m[agent] ⛔ Backend error (HTTP {d})\x1b[0m\n", .{http_code});
        } else {
            main.stderrPrint("\n\x1b[1;31m[agent] ⛔ Backend connection error\x1b[0m\n", .{});
        }

        if (raw_opt) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len > 0) {
                // Automatically pretty-print if valid JSON; keep raw if HTML/plain text
                const pretty = json_mod.prettyPrint(std.heap.page_allocator, trimmed) catch null;
                defer if (pretty) |p| std.heap.page_allocator.free(p);
                const to_print = if (pretty) |p| p else trimmed;

                if (http_code > 0) {
                    main.stderrPrint("\x1b[90m--- RAW BACKEND RESPONSE (HTTP {d}) ---\x1b[0m\n{s}\n\x1b[90m---------------------------------------\x1b[0m\n", .{ http_code, to_print });
                } else {
                    main.stderrPrint("\x1b[90m--- RAW BACKEND RESPONSE ---\x1b[0m\n{s}\n\x1b[90m----------------------------\x1b[0m\n", .{to_print});
                }
                return;
            }
        }
        if (http_code >= 400) {
            main.stderrPrint("\x1b[90m--- RAW BACKEND RESPONSE (HTTP {d}) ---\x1b[0m\n(No content returned from server)\n\x1b[90m---------------------------------------\x1b[0m\n", .{http_code});
        }
    }

    /// Handle throttled backend error (Rate limit 429 / 503) with automatic deduplication.
    pub fn showBackendThrottled(self: *TurnRenderer, http_code: u32, raw_opt: ?[]const u8) void {
        self.stopWaiting();
        if (self.is_thinking) self.endThinking();

        const current_sig = computeErrorSignature(http_code, raw_opt);
        const is_same_error = (self.last_error_signature != 0 and current_sig == self.last_error_signature);

        if (!is_same_error) {
            self.last_error_signature = current_sig;
            self.showBackendError(http_code, raw_opt);
        } else {
            self.clearInplaceLine();
        }
    }

    /// Perform smooth in-place countdown on a single line (with Braille spinner and realtime countdown).
    /// Checks signals.isInterrupted() to exit immediately on Ctrl+C.
    pub fn waitRetryCountdown(self: *TurnRenderer, io: std.Io, backoff_s: u64, attempt: usize, max_attempts: usize) !void {
        if (!term.isStdoutTty()) {
            main.stderrPrint("[agent] ⚠ Rate limit / 503 (attempt {d}/{d})! Retrying in {d}s...\n", .{ attempt, max_attempts, backoff_s });
            std.Io.sleep(io, std.Io.Duration.fromSeconds(@intCast(backoff_s)), .awake) catch {};
            return;
        }

        var s = spinner_mod.Spinner.start();
        const total_ms: u64 = backoff_s * 1000;
        const start_ms = utils.milliTimestamp();

        while (true) {
            if (signals.isInterrupted()) {
                self.clearInplaceLine();
                return error.Interrupted;
            }
            const now = utils.milliTimestamp();
            const elapsed = if (now >= start_ms) @as(u64, @intCast(now - start_ms)) else 0;
            if (elapsed >= total_ms) break;

            const remaining_ms = total_ms - elapsed;
            const remaining_s = (remaining_ms + 999) / 1000;

            const frame = s.nextFrame();
            var buf: [256]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, " \x1b[33m{s}\x1b[0m \x1b[1;33m[agent]\x1b[0m \x1b[33m⚠ Rate limit / 503 (attempt {d}/{d})! Retrying in {d}s... \x1b[90m(Ctrl+C to cancel)\x1b[0m", .{
                frame, attempt, max_attempts, remaining_s,
            }) catch "";
            if (line.len > 0) self.renderInplaceLine(line);

            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(80), .awake) catch {};
        }

        var retry_buf: [256]u8 = undefined;
        const retry_line = std.fmt.bufPrint(&retry_buf, " \x1b[36m{s}\x1b[0m \x1b[90m[agent] Retrying backend connection (attempt {d}/{d})...\x1b[0m", .{
            s.nextFrame(), attempt + 1, max_attempts,
        }) catch "";
        if (retry_line.len > 0) self.renderInplaceLine(retry_line);
    }

    /// Write string to terminal and update newline state.
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

    /// Ensure cursor is at the beginning of a new line (at least 1 newline).
    pub fn ensureNewline(self: *TurnRenderer) void {
        if (self.consecutive_newlines == 0) {
            self.write("\n");
        }
    }

    /// Ensure exactly 1 blank line separating paragraphs (at least 2 newlines).
    pub fn ensureBlankLine(self: *TurnRenderer) void {
        if (self.consecutive_newlines == 0) {
            self.write("\n\n");
        } else if (self.consecutive_newlines == 1) {
            self.write("\n");
        }
    }

    /// Start a new Turn from user input.
    pub fn startTurn(self: *TurnRenderer, prompt: []const u8) void {
        _ = prompt;
        self.turn_start_ms = utils.milliTimestamp();
        self.ui_state = .waiting;
        self.is_thinking = false;
        self.is_codeact = false;
        self.in_codeact = false;
        self.think_snippet_len = 0;
        self.think_last_update_ms = 0;
        self.has_printed_response_header = false;
        self.codeact_start_ms = 0;
        self.codeact_last_update_ms = 0;
        self.codeact_curr_len = 0;
        self.codeact_line1_len = 0;
        self.codeact_line2_len = 0;
        self.codeact_rendered_lines = 0;
        self.codeact_total_lines = 0;
        self.consecutive_newlines = 1;
        self.highlighter = markdown_mod.StreamHighlighter.init();
        self.parser.resetAct();
        self.resetErrorSignature();

        // Start live spinner while waiting for backend TTFT
        self.startWaiting();
    }

    /// Start spinner waiting for first response from AI backend (TTFT).
    pub fn startWaiting(self: *TurnRenderer) void {
        if (self.waiting_active.load(.acquire)) return;
        if (comptime builtin.is_test) return;
        if (!term.isStdoutTty()) return;

        self.waiting_active.store(true, .release);
        self.waiting_thread = std.Thread.spawn(.{}, waitingLoop, .{self}) catch null;
    }

    extern "c" fn usleep(usec: c_uint) c_int;

    fn waitingLoop(self: *TurnRenderer) void {
        var s = spinner_mod.Spinner.start();
        while (self.waiting_active.load(.acquire)) {
            const frame = s.nextFrame();
            var dur_buf: [32]u8 = undefined;
            const dur_str = utils.formatDuration(&dur_buf, s.elapsedMs());
            var buf: [128]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, " \x1b[36m{s}\x1b[0m \x1b[90mThinking ({s})...\x1b[0m", .{
                frame, dur_str,
            }) catch break;
            self.renderInplaceLine(line);
            _ = usleep(80 * 1000);
        }
    }

    /// Stop waiting spinner and clean up line.
    pub fn stopWaiting(self: *TurnRenderer) void {
        if (!self.waiting_active.load(.acquire)) return;
        self.waiting_active.store(false, .release);
        if (self.waiting_thread) |th| {
            th.join();
            self.waiting_thread = null;
        }
        self.clearInplaceLine();
    }

    /// Handle typed stream event from Parser
    pub fn onStreamEvent(self: *TurnRenderer, event: StreamEvent) void {
        switch (event) {
            .think_start => self.startThinking(),
            .think_chunk => |chunk| self.streamThinking(chunk),
            .think_end => self.endThinking(),

            .codeact_start => self.startCodeAct(),
            .codeact_chunk => |chunk| self.streamCodeAct(chunk),
            .codeact_end => self.markCodeActReady(),

            .text_start => self.startTextResponse(),
            .text_chunk => |chunk| self.streamTextResponse(chunk),
            .text_end => self.endTextResponse(),
        }
    }

    fn dispatchParserEvent(self: *TurnRenderer, event: StreamEvent) void {
        self.onStreamEvent(event);
    }

    /// Process text chunk from LLM backend
    pub fn processTextChunk(self: *TurnRenderer, text: []const u8) void {
        self.parser.feed(text, self, dispatchParserEvent);
    }

    // -----------------------------------------------------------------------
    // Thinking State Handlers
    // -----------------------------------------------------------------------

    pub fn startThinking(self: *TurnRenderer) void {
        self.stopWaiting();
        if (self.ui_state == .thinking and self.is_thinking) return;

        self.ui_state = .thinking;
        self.is_thinking = true;
        self.think_start_ms = utils.milliTimestamp();
        self.think_snippet_len = 0;
        self.think_last_update_ms = 0;

        self.ensureNewline();
        var hdr_buf: [96]u8 = undefined;
        if (active_effort) |eff| {
            const hdr = std.fmt.bufPrint(&hdr_buf, " \x1b[90m💭 Thinking \x1b[36m[{s}]\x1b[0m", .{eff}) catch " \x1b[90m💭 Thinking...\x1b[0m";
            self.write(hdr);
        } else {
            self.write(" \x1b[90m💭 Thinking...\x1b[0m");
        }
    }

    pub fn streamThinking(self: *TurnRenderer, text: []const u8) void {
        self.stopWaiting();
        if (self.ui_state != .thinking) {
            self.startThinking();
        }

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

        if (comptime builtin.is_test) return;
        if (!term.isStdoutTty()) return;

        const now = utils.milliTimestamp();
        if (now - self.think_last_update_ms >= 40) {
            self.think_last_update_ms = now;
            const diff = if (now >= self.think_start_ms) now - self.think_start_ms else 0;
            var dur_buf: [32]u8 = undefined;
            const dur_str = utils.formatDuration(&dur_buf, @intCast(diff));
            const frame = self.spinner.nextFrame();

            const snippet = std.mem.trim(u8, self.think_snippet_buf[0..self.think_snippet_len], " ");
            var out_buf: [256]u8 = undefined;
            var eff_buf: [48]u8 = undefined;
            const eff_part = if (active_effort) |eff|
                std.fmt.bufPrint(&eff_buf, " \x1b[36m[{s}]\x1b[0m", .{eff}) catch ""
            else
                "";
            const line = if (snippet.len > 0)
                std.fmt.bufPrint(&out_buf, " \x1b[36m{s}\x1b[0m \x1b[90mThinking ({s})\x1b[0m{s} \x1b[2;90m{s}\x1b[0m", .{
                    frame, dur_str, eff_part, snippet,
                }) catch ""
            else
                std.fmt.bufPrint(&out_buf, " \x1b[36m{s}\x1b[0m \x1b[90mThinking ({s})\x1b[0m{s}...\x1b[0m", .{
                    frame, dur_str, eff_part,
                }) catch "";

            if (line.len > 0) self.renderInplaceLine(line);
        }
    }

    pub fn endThinking(self: *TurnRenderer) void {
        if (self.ui_state != .thinking and !self.is_thinking) return;
        self.is_thinking = false;
        self.ui_state = .idle;
        const now = utils.milliTimestamp();
        const diff = if (now >= self.think_start_ms) now - self.think_start_ms else 0;
        var dur_buf: [32]u8 = undefined;
        const dur_str = utils.formatDuration(&dur_buf, @intCast(diff));

        var buf: [160]u8 = undefined;
        const footer = if (active_effort) |eff|
            std.fmt.bufPrint(&buf, "\r\x1b[2K \x1b[90m💭 Thought for {s} \x1b[36m[{s}]\x1b[0m\n", .{ dur_str, eff }) catch "\r\x1b[2K \x1b[90m💭 Thought\x1b[0m\n"
        else
            std.fmt.bufPrint(&buf, "\r\x1b[2K \x1b[90m💭 Thought for {s}\x1b[0m\n", .{dur_str}) catch "\r\x1b[2K \x1b[90m💭 Thought\x1b[0m\n";
        self.write(footer);
    }

    // -----------------------------------------------------------------------
    // CodeAct State Handlers
    // -----------------------------------------------------------------------

    pub fn startCodeAct(self: *TurnRenderer) void {
        self.stopWaiting();
        if (self.ui_state == .thinking or self.is_thinking) {
            self.endThinking();
        }
        if (self.ui_state == .codeact_live and self.is_codeact) return;

        self.ui_state = .codeact_live;
        self.is_codeact = true;
        self.in_codeact = true;
        self.codeact_start_ms = utils.milliTimestamp();
        self.codeact_last_update_ms = 0;
        self.codeact_curr_len = 0;
        self.codeact_line1_len = 0;
        self.codeact_line2_len = 0;
        self.codeact_rendered_lines = 0;
        self.codeact_total_lines = 0;
        self.highlighter.flush(self.io);
    }

    pub fn streamCodeAct(self: *TurnRenderer, text: []const u8) void {
        self.stopWaiting();
        if (self.ui_state != .codeact_live) {
            self.startCodeAct();
        }

        for (text) |c| {
            if (c == '\n') {
                if (self.codeact_curr_len > 0 or self.codeact_total_lines > 0) {
                    std.mem.copyForwards(u8, &self.codeact_line1_buf, self.codeact_line2_buf[0..self.codeact_line2_len]);
                    self.codeact_line1_len = self.codeact_line2_len;

                    std.mem.copyForwards(u8, &self.codeact_line2_buf, self.codeact_curr_buf[0..self.codeact_curr_len]);
                    self.codeact_line2_len = self.codeact_curr_len;

                    self.codeact_curr_len = 0;
                    self.codeact_total_lines += 1;
                }
            } else if (c == '\r') {
                // ignore \r
            } else if (c == '\t') {
                if (self.codeact_curr_len + 2 < self.codeact_curr_buf.len) {
                    self.codeact_curr_buf[self.codeact_curr_len] = ' ';
                    self.codeact_curr_len += 1;
                    self.codeact_curr_buf[self.codeact_curr_len] = ' ';
                    self.codeact_curr_len += 1;
                }
            } else if (c >= 32) {
                if (self.codeact_curr_len < 72) {
                    self.codeact_curr_buf[self.codeact_curr_len] = c;
                    self.codeact_curr_len += 1;
                }
            }
        }

        const now = utils.milliTimestamp();
        if (now - self.codeact_last_update_ms >= 40) {
            self.codeact_last_update_ms = now;
            self.renderCodeActInPlace(now);
        }
    }

    fn renderCodeActInPlace(self: *TurnRenderer, now: i64) void {
        if (comptime builtin.is_test) return;
        if (!term.isStdoutTty()) return;

        const diff = if (now >= self.codeact_start_ms) now - self.codeact_start_ms else 0;
        var dur_buf: [32]u8 = undefined;
        const dur_str = utils.formatDuration(&dur_buf, @intCast(diff));
        const frame = self.spinner.nextFrame();

        var h_buf: [128]u8 = undefined;
        const header_line = std.fmt.bufPrint(&h_buf, " \x1b[35m{s}\x1b[0m \x1b[1;35mCodeAct\x1b[0m \x1b[90m({s})...\x1b[0m", .{
            frame, dur_str,
        }) catch " ⚡ CodeAct...";

        var line2_opt: ?[]const u8 = null;
        var line3_opt: ?[]const u8 = null;
        var num_lines: usize = 1;

        if (self.codeact_curr_len > 0) {
            if (self.codeact_line2_len > 0) {
                line2_opt = self.codeact_line2_buf[0..self.codeact_line2_len];
                line3_opt = self.codeact_curr_buf[0..self.codeact_curr_len];
                num_lines = 3;
            } else {
                line2_opt = self.codeact_curr_buf[0..self.codeact_curr_len];
                num_lines = 2;
            }
        } else if (self.codeact_line2_len > 0) {
            if (self.codeact_line1_len > 0) {
                line2_opt = self.codeact_line1_buf[0..self.codeact_line1_len];
                line3_opt = self.codeact_line2_buf[0..self.codeact_line2_len];
                num_lines = 3;
            } else {
                line2_opt = self.codeact_line2_buf[0..self.codeact_line2_len];
                num_lines = 2;
            }
        }

        // Move cursor up to first previously rendered line
        if (self.codeact_rendered_lines > 1) {
            for (0..self.codeact_rendered_lines - 1) |_| {
                term.writeStdout("\x1b[1A");
            }
        }

        // Render Line 1 (Header)
        term.writeStdout("\r\x1b[2K");
        term.writeStdout(header_line);

        // Anti-wrap: each in-place line MUST occupy exactly 1 terminal row,
        // otherwise cursor-up (\x1b[1A) math in subsequent re-renders and in
        // endCodeAct() lands on the wrong row and garbles the block.
        const win = term.getTerminalSize();
        // prefix "  │ " ≈ 6 cols + margins; keep 4 cols spare
        const max_content_cols: usize = if (win.cols > 14) win.cols - 10 else 60;

        // Render Line 2
        if (line2_opt) |l2| {
            var l2_trunc: [160]u8 = undefined;
            const l2_safe = truncateAnsi(&l2_trunc, l2, max_content_cols);
            var l2_buf: [256]u8 = undefined;
            const l2_str = std.fmt.bufPrint(&l2_buf, "\n\r\x1b[2K  \x1b[90m│\x1b[0m \x1b[2;37m{s}\x1b[0m", .{l2_safe}) catch "";
            term.writeStdout(l2_str);
        }

        // Render Line 3
        if (line3_opt) |l3| {
            var l3_trunc: [160]u8 = undefined;
            const l3_safe = truncateAnsi(&l3_trunc, l3, max_content_cols);
            var l3_buf: [256]u8 = undefined;
            const l3_str = std.fmt.bufPrint(&l3_buf, "\n\r\x1b[2K  \x1b[90m│\x1b[0m \x1b[37m{s}\x1b[0m", .{l3_safe}) catch "";
            term.writeStdout(l3_str);
        }

        // Clear excess lines if this render has fewer lines than before
        if (self.codeact_rendered_lines > num_lines) {
            const excess = self.codeact_rendered_lines - num_lines;
            for (0..excess) |_| {
                term.writeStdout("\n\r\x1b[2K");
            }
            for (0..excess) |_| {
                term.writeStdout("\x1b[1A");
            }
        }

        self.codeact_rendered_lines = num_lines;
    }

    pub fn markCodeActReady(self: *TurnRenderer) void {
        self.is_codeact = false;
        self.in_codeact = false;
        self.ui_state = .codeact_ready;
    }

    pub fn endCodeAct(self: *TurnRenderer) void {
        if (!self.is_codeact and self.ui_state != .codeact_live and self.ui_state != .codeact_ready) return;
        self.is_codeact = false;
        self.in_codeact = false;

        if (term.isStdoutTty() and self.codeact_rendered_lines > 0) {
            if (self.codeact_rendered_lines > 1) {
                for (0..self.codeact_rendered_lines - 1) |_| {
                    term.writeStdout("\x1b[1A");
                }
            }
            for (0..self.codeact_rendered_lines) |idx| {
                term.writeStdout("\r\x1b[2K");
                if (idx + 1 < self.codeact_rendered_lines) {
                    term.writeStdout("\n");
                }
            }
            if (self.codeact_rendered_lines > 1) {
                for (0..self.codeact_rendered_lines - 1) |_| {
                    term.writeStdout("\x1b[1A");
                }
            }
            term.writeStdout("\r\x1b[2K");
        }

        self.ui_state = .idle;
        self.codeact_curr_len = 0;
        self.codeact_rendered_lines = 0;
        self.codeact_total_lines = 0;
    }

    // -----------------------------------------------------------------------
    // Text Response Handlers
    // -----------------------------------------------------------------------

    pub fn startTextResponse(self: *TurnRenderer) void {
        self.stopWaiting();
        if (self.ui_state == .thinking or self.is_thinking) {
            self.endThinking();
        }
        if (self.ui_state == .codeact_live or self.ui_state == .codeact_ready or self.is_codeact) {
            self.endCodeAct();
        }
        self.ui_state = .text_streaming;

        if (!self.has_printed_response_header) {
            self.has_printed_response_header = true;
            self.ensureBlankLine();
            var buf: [128]u8 = undefined;
            const header = std.fmt.bufPrint(&buf, " \x1b[1;32m{s} mini-agent\x1b[0m\n", .{term.GLYPH_BOT}) catch " 💩 mini-agent\n";
            self.write(header);
        }
    }

    pub fn streamTextResponse(self: *TurnRenderer, text: []const u8) void {
        if (self.ui_state != .text_streaming) {
            self.startTextResponse();
        }

        const trimmed = std.mem.trim(u8, text, " \r\n\t");
        if (trimmed.len == 0 and !self.has_printed_response_header) return;

        self.highlighter.processChunk(self.io, text);
        for (text) |c| {
            if (c == '\n') {
                self.consecutive_newlines += 1;
            } else if (c != '\r') {
                self.consecutive_newlines = 0;
            }
        }
    }

    pub fn endTextResponse(self: *TurnRenderer) void {
        self.highlighter.flush(self.io);
        if (self.ui_state == .text_streaming) {
            self.ui_state = .idle;
        }
    }

    /// Stream AI response to stdout (backwards-compatible function).
    pub fn streamResponse(self: *TurnRenderer, text: []const u8) void {
        self.streamTextResponse(text);
    }

    // -----------------------------------------------------------------------
    // Tool Execution Lifecycle Handlers
    // -----------------------------------------------------------------------

    /// Start executing a Tool Action.
    pub fn startTool(self: *TurnRenderer, name: []const u8, input_json: []const u8) void {
        self.stopWaiting();
        if (self.ui_state == .thinking or self.is_thinking) {
            self.endThinking();
        }
        if (self.ui_state == .codeact_ready or self.ui_state == .codeact_live or self.is_codeact) {
            self.endCodeAct();
        }
        self.highlighter.flush(self.io);

        var detail_buf: [256]u8 = undefined;
        var detail: []const u8 = "";

        if (std.mem.eql(u8, name, "bash") or std.mem.eql(u8, name, "sh") or std.mem.eql(u8, name, "exec")) {
            if (json_mod.findString(input_json, "command") orelse json_mod.findString(input_json, "cmd")) |cmd| {
                const trimmed = if (cmd.len > 80) cmd[0..80] else cmd;
                detail = std.fmt.bufPrint(&detail_buf, "\x1b[35m{s}\x1b[0m", .{trimmed}) catch "";
            }
        } else if (std.mem.eql(u8, name, "invoke_subagent") or std.mem.eql(u8, name, "batch_invoke_subagents") or std.mem.eql(u8, name, "subagent")) {
            if (json_mod.findString(input_json, "task") orelse json_mod.findString(input_json, "prompt") orelse json_mod.findString(input_json, "description")) |t| {
                const trimmed = if (t.len > 80) t[0..80] else t;
                detail = std.fmt.bufPrint(&detail_buf, "\x1b[36m\"{s}\"\x1b[0m", .{trimmed}) catch "";
            }
        } else if (std.mem.eql(u8, name, "file_read") or std.mem.eql(u8, name, "file_write") or std.mem.eql(u8, name, "file_edit") or std.mem.eql(u8, name, "read_file") or std.mem.eql(u8, name, "write_file") or std.mem.eql(u8, name, "edit_file")) {
            if (json_mod.findString(input_json, "path") orelse json_mod.findString(input_json, "TargetFile") orelse json_mod.findString(input_json, "file")) |path| {
                detail = std.fmt.bufPrint(&detail_buf, "\x1b[34m{s}\x1b[0m", .{path}) catch "";
            }
        } else if (std.mem.eql(u8, name, "grep")) {
            if (json_mod.findString(input_json, "pattern") orelse json_mod.findString(input_json, "query")) |pat| {
                detail = std.fmt.bufPrint(&detail_buf, "\x1b[33m/{s}/\x1b[0m", .{pat}) catch "";
            }
        } else if (std.mem.eql(u8, name, "glob")) {
            if (json_mod.findString(input_json, "pattern")) |pat| {
                detail = std.fmt.bufPrint(&detail_buf, "\x1b[33m{s}\x1b[0m", .{pat}) catch "";
            }
        } else if (std.mem.eql(u8, name, "http_request") or std.mem.eql(u8, name, "http") or std.mem.eql(u8, name, "fetch")) {
            if (json_mod.findString(input_json, "url")) |u| {
                const trimmed = if (u.len > 80) u[0..80] else u;
                detail = std.fmt.bufPrint(&detail_buf, "\x1b[34m{s}\x1b[0m", .{trimmed}) catch "";
            }
        } else if (std.mem.eql(u8, name, "session_diagnostics")) {
            const op = json_mod.findString(input_json, "operation") orelse "list";
            if (json_mod.findInt(input_json, "pid", i32)) |pid| {
                detail = std.fmt.bufPrint(&detail_buf, "\x1b[36m{s} pid={d}\x1b[0m", .{ op, pid }) catch "";
            } else {
                detail = std.fmt.bufPrint(&detail_buf, "\x1b[36m{s}\x1b[0m", .{op}) catch "";
            }
        } else if (std.mem.eql(u8, name, "codeact")) {
            detail = "\x1b[35mCodeAct script\x1b[0m";
        } else {
            if (json_mod.findString(input_json, "task") orelse
                json_mod.findString(input_json, "query") orelse
                json_mod.findString(input_json, "path") orelse
                json_mod.findString(input_json, "command") orelse
                json_mod.findString(input_json, "name") orelse
                json_mod.findString(input_json, "prompt")) |val|
            {
                const trimmed = if (val.len > 80) val[0..80] else val;
                detail = std.fmt.bufPrint(&detail_buf, "\x1b[90m{s}\x1b[0m", .{trimmed}) catch "";
            }
        }

        if (self.consecutive_newlines == 0) {
            self.ensureNewline();
        }
        var header_buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&header_buf, " \x1b[1;33m{s}\x1b[0m \x1b[1;37m{s}\x1b[0m {s}\n", .{
            term.GLYPH_ACTION, name, detail,
        }) catch return;
        self.write(line);

        self.ui_state = .tool_executing;
    }

    /// Finish a Tool Action and display output snippet (up to 3 lines).
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
            const status_line = std.fmt.bufPrint(&status_buf, "    \x1b[31m{s} Error after {s}:\x1b[0m {s}\n", .{
                term.GLYPH_CROSS, dur_str, if (result.len > 120) result[0..120] else result,
            }) catch return;
            self.write(status_line);
        } else {
            _ = name;
            const status_line = std.fmt.bufPrint(&status_buf, "    \x1b[32m{s} Completed ({s})\x1b[0m\n", .{
                term.GLYPH_CHECK, dur_str,
            }) catch return;
            self.write(status_line);
        }

        // Render up to 3 lines of output snippet (stream inplace detail)
        if (patch_diff == null or patch_diff.?.len == 0) {
            const trimmed_res = std.mem.trim(u8, result, " \r\n\t");
            if (trimmed_res.len > 0) {
                var line_it = std.mem.splitScalar(u8, trimmed_res, '\n');
                var line_count: usize = 0;
                while (line_it.next()) |raw_line| {
                    const clean_line = std.mem.trim(u8, raw_line, " \r\t");
                    if (clean_line.len == 0) continue;
                    if (line_count >= 3) {
                        self.write("    \x1b[2;90m...\x1b[0m\n");
                        break;
                    }
                    line_count += 1;
                    const truncated_line = if (clean_line.len > 120) clean_line[0..120] else clean_line;
                    var out_line_buf: [256]u8 = undefined;
                    const out_line = std.fmt.bufPrint(&out_line_buf, "    \x1b[2;90m│\x1b[0m \x1b[90m{s}\x1b[0m\n", .{truncated_line}) catch continue;
                    self.write(out_line);
                }
            }
        }

        self.ui_state = .idle;
        self.parser.resetAct();
    }

    // -----------------------------------------------------------------------
    // Turn Finalization
    // -----------------------------------------------------------------------

    /// Finish entire Turn and print Telemetry Status Footer.
    pub fn finishTurn(self: *TurnRenderer, stats: TurnStats) void {
        self.stopWaiting();
        if (self.ui_state == .thinking or self.is_thinking) {
            self.endThinking();
        }
        if (self.ui_state == .codeact_live or self.ui_state == .codeact_ready or self.is_codeact) {
            self.endCodeAct();
        }
        if (self.ui_state == .text_streaming) {
            self.endTextResponse();
        }
        self.parser.resetAct();
        self.ui_state = .idle;
        self.resetErrorSignature();

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
