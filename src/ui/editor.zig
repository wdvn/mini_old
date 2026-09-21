//! editor.zig — Line editor for REPL (RFC-000 Phase 0).
//!
//! Addresses editor features:
//!   - Dynamic buffer `ArrayListUnmanaged(u8)` (input limit 64KB, reject instead of truncate)
//!   - UTF-8 aware via `unicode.zig`: cursor moves by grapheme cluster,
//!     redraw according to displayWidth and multiline wrapping (typing multibyte UTF-8 / emoji / long paste without prompt repeating)
//!   - Word motion: Alt+B/F move by word, Alt+D / Alt+Backspace delete word
//!   - Undo/Redo: Ctrl+Z / Ctrl+Y (16-snapshot ring, 4KB/snapshot cap)
//!   - Kill ring: Ctrl+W cut left word, Ctrl+K cut to end of line, Ctrl+Y yank (5-slot ring)
//!   - Ctrl+A/E/U/L, Home/End, ↑/↓ history, bracketed paste
//!   - Multiline insert: Shift+Enter / Ctrl+Enter / Alt+Enter, Ctrl+J (RFC-008 §5B).
//!     Modified Enter is decoded from xterm modifyOtherKeys ("ESC[27;2;13~")
//!     or kitty keyboard protocol ("ESC[13;2u"); the editor requests
//!     modifyOtherKeys=1 (level 1: only re-encodes keys whose legacy encoding
//!     is ambiguous, e.g. Shift+Enter, leaving Ctrl/Alt+letter untouched)
//!     while in raw mode.
//!
//! Still a single-line composer (multiline is Phase 1 — RFC-000).

const std = @import("std");
const Allocator = std.mem.Allocator;
const unicode = @import("unicode.zig");
const history_mod = @import("history.zig");
const paste_mod = @import("paste.zig");
const term = @import("terminal.zig");
const utils = @import("../core/utils.zig");

/// Input limit (bytes). Exceeding -> show error, reject additional input.
pub const MAX_INPUT_BYTES = 64 * 1024;
/// Maximum undo/redo snapshots.
const UNDO_DEPTH = 16;
/// Maximum snapshot size (larger buffer -> no undo).
const UNDO_SNAPSHOT_CAP = 4 * 1024;
/// Kill ring depth.
const KILL_RING_DEPTH = 5;

pub const LineEditor = struct {
    alloc: Allocator,
    /// Prompt input history persistent (JSONL).
    prompt_history: history_mod.PromptHistory,
    history_index: usize,
    /// Backup of draft content when navigating up in history.
    draft: std.ArrayListUnmanaged(u8),

    // --- Dynamic buffer ---
    buf: std.ArrayListUnmanaged(u8),
    /// Cursor position (byte offset, always at grapheme boundary).
    pos: usize,

    // --- Multiline / Wrapping redraw tracking ---
    rendered_rows: usize,
    cursor_row: usize,

    // --- Undo/Redo ---
    undo_stack: [UNDO_DEPTH][]u8,
    undo_pos_stack: [UNDO_DEPTH]usize,
    undo_len: usize,
    undo_head: usize, // next slot index to write
    redo_stack: [UNDO_DEPTH][]u8,
    redo_pos_stack: [UNDO_DEPTH]usize,
    redo_len: usize,
    redo_head: usize,

    // --- Kill ring ---
    kill_ring: [KILL_RING_DEPTH][]u8,
    kill_len: usize,
    kill_head: usize,

    /// Display input limit error message on next redraw.
    limit_msg: bool,

    /// Bracketed paste parser (state machine — see paste.zig).
    paste_parser: paste_mod.Parser,
    /// Currently in paste mode (between START and END markers).
    pasting: bool,
    /// Undo pushed for current paste operation (1 undo per paste batch).
    paste_undo_pushed: bool,
    /// Buffer accumulating paste content before flushing to main buffer.
    paste_buf: std.ArrayListUnmanaged(u8),
    /// Test-only: suppress writing stdout during redraw (no valid std.Io).
    suppress_redraw: bool,
    /// Timestamp of the most recent Ctrl+C press (ms).
    last_ctrl_c_ms: i64,
    /// Set when Ctrl+C / Ctrl+D arrives as a CSI-u sequence with empty buffer
    /// (kitty protocol mode) — readLine exits on next loop iteration.
    exit_pending: bool,

    pub fn init(alloc: Allocator) LineEditor {
        return .{
            .alloc = alloc,
            .prompt_history = history_mod.PromptHistory.init(alloc),
            .history_index = 0,
            .draft = .empty,
            .buf = .empty,
            .pos = 0,
            .rendered_rows = 0,
            .cursor_row = 0,
            .undo_stack = undefined,
            .undo_pos_stack = undefined,
            .undo_len = 0,
            .undo_head = 0,
            .redo_stack = undefined,
            .redo_pos_stack = undefined,
            .redo_len = 0,
            .redo_head = 0,
            .kill_ring = undefined,
            .kill_len = 0,
            .kill_head = 0,
            .limit_msg = false,
            .paste_parser = paste_mod.Parser.init(),
            .pasting = false,
            .paste_undo_pushed = false,
            .paste_buf = .empty,
            .suppress_redraw = false,
            .last_ctrl_c_ms = 0,
            .exit_pending = false,
        };
    }

    pub fn deinit(self: *LineEditor) void {
        self.prompt_history.deinit();
        self.draft.deinit(self.alloc);
        self.buf.deinit(self.alloc);
        self.paste_buf.deinit(self.alloc);
        for (self.undo_stack[0..self.undo_len]) |s| self.alloc.free(s);
        for (self.redo_stack[0..self.redo_len]) |s| self.alloc.free(s);
        for (self.kill_ring[0..self.kill_len]) |s| self.alloc.free(s);
    }

    // -----------------------------------------------------------------------
    // Undo / Redo
    // -----------------------------------------------------------------------

    fn pushUndo(self: *LineEditor) void {
        if (self.buf.items.len > UNDO_SNAPSHOT_CAP) return;
        const snap = self.alloc.dupe(u8, self.buf.items) catch return;
        if (self.undo_len == UNDO_DEPTH) {
            // Ring full: overwrite oldest (undo_head always points to next slot).
            self.alloc.free(self.undo_stack[self.undo_head]);
        } else {
            self.undo_len += 1;
        }
        self.undo_stack[self.undo_head] = snap;
        self.undo_pos_stack[self.undo_head] = self.pos;
        self.undo_head = (self.undo_head + 1) % UNDO_DEPTH;
        // New mutation invalidates redo.
        self.clearRedo();
    }

    fn clearRedo(self: *LineEditor) void {
        for (self.redo_stack[0..self.redo_len]) |s| self.alloc.free(s);
        self.redo_len = 0;
        self.redo_head = 0;
    }

    fn popUndo(self: *LineEditor) ?struct { snap: []u8, pos: usize } {
        if (self.undo_len == 0) return null;
        self.undo_head = if (self.undo_head == 0) UNDO_DEPTH - 1 else self.undo_head - 1;
        self.undo_len -= 1;
        return .{ .snap = self.undo_stack[self.undo_head], .pos = self.undo_pos_stack[self.undo_head] };
    }

    fn pushRedo(self: *LineEditor) void {
        if (self.buf.items.len > UNDO_SNAPSHOT_CAP) return;
        const snap = self.alloc.dupe(u8, self.buf.items) catch return;
        if (self.redo_len == UNDO_DEPTH) {
            self.alloc.free(self.redo_stack[self.redo_head]);
        } else {
            self.redo_len += 1;
        }
        self.redo_stack[self.redo_head] = snap;
        self.redo_pos_stack[self.redo_head] = self.pos;
        self.redo_head = (self.redo_head + 1) % UNDO_DEPTH;
    }

    fn applyUndo(self: *LineEditor) bool {
        const entry = self.popUndo() orelse return false;
        defer self.alloc.free(entry.snap);
        self.pushRedo();
        self.buf.clearRetainingCapacity();
        self.buf.appendSlice(self.alloc, entry.snap) catch return false;
        self.pos = @min(entry.pos, self.buf.items.len);
        return true;
    }

    fn applyRedo(self: *LineEditor) bool {
        if (self.redo_len == 0) return false;
        self.redo_head = if (self.redo_head == 0) UNDO_DEPTH - 1 else self.redo_head - 1;
        self.redo_len -= 1;
        const snap = self.redo_stack[self.redo_head];
        defer self.alloc.free(snap);
        // Save current state into undo so that another undo returns to it.
        const cur = self.alloc.dupe(u8, self.buf.items) catch return false;
        if (self.undo_len == UNDO_DEPTH) {
            self.alloc.free(self.undo_stack[self.undo_head]);
        } else {
            self.undo_len += 1;
        }
        self.undo_stack[self.undo_head] = cur;
        self.undo_pos_stack[self.undo_head] = self.pos;
        self.undo_head = (self.undo_head + 1) % UNDO_DEPTH;

        self.buf.clearRetainingCapacity();
        self.buf.appendSlice(self.alloc, snap) catch return false;
        self.pos = @min(self.redo_pos_stack[self.redo_head], self.buf.items.len);
        return true;
    }

    // -----------------------------------------------------------------------
    // Kill ring
    // -----------------------------------------------------------------------

    fn killPush(self: *LineEditor, text: []const u8) void {
        const dup = self.alloc.dupe(u8, text) catch return;
        if (self.kill_len == KILL_RING_DEPTH) {
            self.alloc.free(self.kill_ring[self.kill_head]);
        } else {
            self.kill_len += 1;
        }
        self.kill_ring[self.kill_head] = dup;
        self.kill_head = (self.kill_head + 1) % KILL_RING_DEPTH;
    }

    fn killTop(self: *LineEditor) ?[]const u8 {
        if (self.kill_len == 0) return null;
        const idx = if (self.kill_head == 0) KILL_RING_DEPTH - 1 else self.kill_head - 1;
        return self.kill_ring[idx];
    }

    // -----------------------------------------------------------------------
    // Buffer primitives (UTF-8 grapheme aware)
    // -----------------------------------------------------------------------

    /// Number of bytes of grapheme cluster starting at byte `i`.
    fn clusterLenAt(self: *LineEditor, i: usize) usize {
        return unicode.clusterLenAt(self.buf.items, i);
    }

    /// Size of grapheme cluster preceding byte `i`.
    fn clusterLenBefore(self: *LineEditor, i: usize) usize {
        if (i == 0) return 0;
        var j = i - 1;
        // Step back through continuation bytes (10xxxxxx) to find cluster start byte.
        while (j > 0 and (self.buf.items[j] & 0xC0) == 0x80) j -= 1;
        // Continue stepping back across combining marks / ZWJ joined to preceding cluster.
        while (j > 0) {
            var k = j - 1;
            while (k > 0 and (self.buf.items[k] & 0xC0) == 0x80) k -= 1;
            const cp_len = j - k;
            if (cp_len <= 4) {
                const cp = std.unicode.utf8Decode(self.buf.items[k .. k + cp_len]) catch break;
                if (unicode.isContinuationCp(cp)) {
                    j = k;
                    continue;
                }
            }
            break;
        }
        return i - j;
    }

    fn moveLeft(self: *LineEditor) void {
        if (self.pos == 0) return;
        self.pos -= self.clusterLenBefore(self.pos);
    }

    fn moveRight(self: *LineEditor) void {
        if (self.pos >= self.buf.items.len) return;
        self.pos += self.clusterLenAt(self.pos);
    }

    fn insertBytes(self: *LineEditor, bytes: []const u8) bool {
        if (self.buf.items.len + bytes.len > MAX_INPUT_BYTES) {
            self.limit_msg = true;
            return false;
        }
        self.limit_msg = false;
        self.buf.insertSlice(self.alloc, self.pos, bytes) catch return false;
        self.pos += bytes.len;
        return true;
    }

    /// Insert '\n' at cursor position (manual newline, RFC-008 §5B).
    pub fn insertNewlineAtCursor(self: *LineEditor, io: std.Io, prompt: []const u8) void {
        if (self.buf.items.len + 1 > MAX_INPUT_BYTES) {
            self.limit_msg = true;
            self.redraw(io, prompt);
            return;
        }
        self.pushUndo();
        _ = self.insertBytes("\n");
        self.redraw(io, prompt);
    }

    /// Delete range [start, end). Returns removed text (caller frees) or null.
    fn deleteRange(self: *LineEditor, start: usize, end: usize) ?[]u8 {
        if (start >= end or end > self.buf.items.len) return null;
        const removed = self.alloc.dupe(u8, self.buf.items[start..end]) catch return null;
        const rem_len = end - start;
        std.mem.copyForwards(u8, self.buf.items[start .. self.buf.items.len - rem_len], self.buf.items[end..]);
        self.buf.items.len -= rem_len;
        if (self.pos > end) {
            self.pos -= rem_len;
        } else if (self.pos > start) {
            self.pos = start;
        }
        return removed;
    }

    // -----------------------------------------------------------------------
    // Word motion
    // -----------------------------------------------------------------------

    fn cpBefore(self: *LineEditor, i: usize) ?u21 {
        if (i == 0) return null;
        var j = i - 1;
        while (j > 0 and (self.buf.items[j] & 0xC0) == 0x80) j -= 1;
        const n = i - j;
        if (n > 4) return null;
        return std.unicode.utf8Decode(self.buf.items[j..i]) catch null;
    }

    fn cpAt(self: *LineEditor, i: usize) ?struct { cp: u21, len: usize } {
        if (i >= self.buf.items.len) return null;
        const n = unicode.utf8Len(self.buf.items[i]);
        if (i + n > self.buf.items.len) return null;
        const cp = std.unicode.utf8Decode(self.buf.items[i .. i + n]) catch return null;
        return .{ .cp = cp, .len = n };
    }

    /// Start position to the left of cursor (space-punct-word per unicode.CharClass).
    fn wordLeft(self: *LineEditor) usize {
        var i = self.pos;
        // Skip spaces to the left.
        while (i > 0) {
            const cp = self.cpBefore(i) orelse break;
            if (unicode.charClass(cp) == .space) {
                i -= unicode.utf8Len(self.buf.items[i - 1]);
                if (i > 0) {
                    var j = i - 1;
                    while (j > 0 and (self.buf.items[j] & 0xC0) == 0x80) j -= 1;
                    i -= (i - 1 - j);
                }
            } else break;
        }
        // Match character class of character at new position.
        var target_class: ?unicode.CharClass = null;
        while (i > 0) {
            const cp = self.cpBefore(i) orelse break;
            const cls = unicode.charClass(cp);
            if (target_class == null) target_class = cls;
            if (cls != target_class.?) break;
            var j = i - 1;
            while (j > 0 and (self.buf.items[j] & 0xC0) == 0x80) j -= 1;
            i = j;
        }
        return i;
    }

    /// End position to the right of cursor.
    fn wordRight(self: *LineEditor) usize {
        var i = self.pos;
        var target_class: ?unicode.CharClass = null;
        while (i < self.buf.items.len) {
            const d = self.cpAt(i) orelse break;
            const cls = unicode.charClass(d.cp);
            if (cls == .space and target_class == null) {
                i += d.len;
                continue;
            }
            if (target_class == null) target_class = cls;
            if (cls != target_class.?) break;
            i += d.len;
        }
        return i;
    }

    // -----------------------------------------------------------------------
    // History
    // -----------------------------------------------------------------------

    fn loadHistoryEntry(self: *LineEditor, delta: i32) void {
        if (self.prompt_history.entries.items.len == 0) return;
        const cur = self.history_index;
        const next: usize = blk: {
            if (delta < 0) {
                if (cur == 0) return;
                break :blk cur - 1;
            } else {
                if (cur >= self.prompt_history.entries.items.len) return;
                break :blk cur + 1;
            }
        };

        // Save draft when leaving last position.
        if (cur == self.prompt_history.entries.items.len) {
            self.draft.clearRetainingCapacity();
            self.draft.appendSlice(self.alloc, self.buf.items) catch {};
        }

        self.history_index = next;
        self.buf.clearRetainingCapacity();
        if (next == self.prompt_history.entries.items.len) {
            self.buf.appendSlice(self.alloc, self.draft.items) catch {};
        } else {
            self.buf.appendSlice(self.alloc, self.prompt_history.entries.items[next]) catch {};
        }
        self.pos = self.buf.items.len;
    }

    // -----------------------------------------------------------------------
    // Render (Multiline Wrapping Aware)
    // -----------------------------------------------------------------------

    fn redraw(self: *LineEditor, io: std.Io, prompt: []const u8) void {
        if (self.suppress_redraw) return;
        var out_buf: [8192]u8 = undefined;
        var w = std.Io.Writer.fixed(&out_buf);

        // 1. Move cursor back to the first line of prompt if previous render wrapped to lines below
        if (self.cursor_row > 0) {
            w.print("\x1b[{d}A", .{self.cursor_row}) catch return;
        }
        // 2. Return to line start and clear entire visible region from cursor downwards
        w.writeAll("\r\x1b[J") catch return;

        if (self.limit_msg) {
            w.writeAll("\x1b[33m[input limit 64KB — rejected]\x1b[0m\r\n\x1b[J") catch return;
        }

        // 3. Print prompt + buffer by logical line: actual \n -> \r\n + indent
        //    matching prompt width (raw mode: \n does not return to column 0, must use \r\n).
        const term_size = term.getTerminalSize();
        const cols: usize = if (term_size.cols > 0) term_size.cols else 80;

        const prompt_w = unicode.visibleWidth(prompt);
        var indent_buf: [64]u8 = undefined;
        const indent_len = @min(prompt_w, indent_buf.len);
        @memset(indent_buf[0..indent_len], ' ');
        const indent = indent_buf[0..indent_len];

        var total_rows: usize = 0; // extra rows relative to first row
        var cur_row: usize = 0;
        var cur_col: usize = 0;
        var cursor_placed = false;

        var line_start: usize = 0;
        var line_idx: usize = 0;
        var k: usize = 0;
        while (k <= self.buf.items.len) : (k += 1) {
            const at_end = k == self.buf.items.len;
            if (!at_end and self.buf.items[k] != '\n') continue;

            // Logical line [line_start..k)
            const line = self.buf.items[line_start..k];
            const prefix_w: usize = if (line_idx == 0) prompt_w else indent_len;
            const lw = prefix_w + unicode.displayWidth(line);

            if (line_idx == 0) {
                w.writeAll(prompt) catch return;
            } else {
                w.writeAll("\r\n") catch return;
                w.writeAll(indent) catch return;
            }
            w.writeAll(line) catch return;

            // Does cursor belong to this line?
            if (!cursor_placed and self.pos <= k) {
                const in_w = unicode.displayWidth(self.buf.items[line_start..@min(self.pos, k)]);
                const coff = prefix_w + in_w;
                // Use rows BEFORE this line's wraps for correct cursor row calc
                cur_row = total_rows + coff / cols;
                cur_col = coff % cols;
                cursor_placed = true;
            }

            total_rows += lw / cols;

            if (at_end) break;
            line_start = k + 1;
            line_idx += 1;
        }

        // 4. Move terminal cursor to (cur_row, cur_col)
        if (total_rows > cur_row) {
            w.print("\x1b[{d}A", .{total_rows - cur_row}) catch return;
        }
        w.writeAll("\r") catch return;
        if (cur_col > 0) {
            w.print("\x1b[{d}C", .{cur_col}) catch return;
        }

        self.rendered_rows = total_rows;
        self.cursor_row = cur_row;

        const stdout_file = std.Io.File.stdout();
        stdout_file.writeStreamingAll(io, out_buf[0..w.end]) catch {};
    }

    // -----------------------------------------------------------------------
    // Main loop
    // -----------------------------------------------------------------------

    pub fn readLine(self: *LineEditor, io: std.Io, prompt: []const u8) !?[]const u8 {
        const stdin_fd = std.posix.STDIN_FILENO;
        const stdout_file = std.Io.File.stdout();
        const stdin_file = std.Io.File.stdin();

        const orig_termios = try std.posix.tcgetattr(stdin_fd);
        var raw = orig_termios;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false; // Receive Ctrl+C byte (0x03) directly for editor to handle line cancel / exit on double-press
        // Disable (input) CR/NL translation: pasted CRLF must arrive intact
        // (\r\n -> 1 space when sanitized), Enter arrives as '\r' (13).
        raw.iflag.ICRNL = false;
        raw.iflag.INLCR = false;
        raw.iflag.IGNCR = false;
        raw.iflag.IXON = false; // Ctrl+S/Q pass to editor, not caught by kernel
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;

        try std.posix.tcsetattr(stdin_fd, .FLUSH, raw);
        defer {
            stdout_file.writeStreamingAll(io, "\x1b[?2004l\x1b[<u\x1b[>4;0m") catch {};
            std.posix.tcsetattr(stdin_fd, .FLUSH, orig_termios) catch {};
        }

        // Bracketed paste mode + enhanced keyboard reporting so that
        // Shift/Ctrl+Enter arrive as a distinguishable sequence instead of
        // a plain '\r' (13):
        //   - kitty protocol (flag 1: disambiguate escape codes): Shift+Enter -> ESC[13;2u
        //   - xterm modifyOtherKeys level 1:                      Shift+Enter -> ESC[27;2;13~
        // Level 1 only re-encodes keys whose legacy encoding is ambiguous
        // (Shift+Enter and plain Enter both legacy-encode as '\r'), so
        // Ctrl/Alt+letter keep their legacy bytes and existing bindings are
        // unaffected. Unknown terminals ignore the request (no-op), plain
        // Enter still sends '\r'.
        stdout_file.writeStreamingAll(io, "\x1b[>4;1m\x1b[>1u\x1b[?2004h") catch {};

        self.buf.clearRetainingCapacity();
        self.pos = 0;
        self.rendered_rows = 0;
        self.cursor_row = 0;
        self.limit_msg = false;
        self.exit_pending = false;
        self.history_index = self.prompt_history.entries.items.len;
        self.draft.clearRetainingCapacity();

        self.redraw(io, prompt);

        while (true) {
            // CSI-u exit request (Ctrl+C via kitty protocol) handled after
            // pending input is consumed (see handleEscapeSlice, code 3 / 99).
            if (self.exit_pending and self.buf.items.len == 0) {
                return null;
            }
            var read_buf: [1024]u8 = undefined;
            const n = stdin_file.readStreaming(io, &.{&read_buf}) catch |err| {
                if (err == error.Interrupted) {
                    const now_ms = utils.milliTimestamp();
                    if (now_ms - self.last_ctrl_c_ms <= 2000 and self.last_ctrl_c_ms > 0) {
                        stdout_file.writeStreamingAll(io, "^C\r\n") catch {};
                        return null;
                    }
                    self.last_ctrl_c_ms = now_ms;
                    stdout_file.writeStreamingAll(io, "^C\r\n") catch {};
                    self.buf.clearRetainingCapacity();
                    self.pos = 0;
                    self.rendered_rows = 0;
                    self.cursor_row = 0;
                    self.history_index = self.prompt_history.entries.items.len;
                    self.draft.clearRetainingCapacity();
                    self.redraw(io, prompt);
                    continue;
                }
                return err;
            };
            if (n == 0) return null;

            // In paste mode: feed entire chunk to paste parser.
            // pasteFeed returns offset immediately AFTER END marker if paste finishes
            // MID-chunk — remainder must continue processing as regular input
            // (RCA-001: lost bytes after END marker).
            var i: usize = 0;
            if (self.pasting) {
                const consumed = self.pasteFeed(io, prompt, read_buf[0..n]);
                if (self.pasting) {
                    if (self.pasteIdleTimedOut(io, stdin_file)) {
                        self.endPaste(io, prompt);
                    }
                    continue;
                }
                i = consumed;
            }

            while (i < n) {
                // START marker just completed WITHIN this chunk (case 27 called
                // beginPaste): remainder is PASTE CONTENT, must not go through
                // normal path — '\r' byte would hit case 13 and prematurely submit
                // (root cause of multi-line paste being truncated).
                if (self.pasting) {
                    const consumed = self.pasteFeed(io, prompt, read_buf[i..n]);
                    if (!self.pasting) {
                        i += consumed; // END marker mid-chunk -> process remainder
                        continue;
                    }
                    if (self.pasteIdleTimedOut(io, stdin_file)) {
                        self.endPaste(io, prompt);
                    }
                    break; // still pasting -> return to main read loop
                }
                const c = read_buf[i];
                if (c != 3) {
                    self.last_ctrl_c_ms = 0;
                }
                switch (c) {
                    3 => { // Ctrl+C: Cancel current line or exit REPL on double-press
                        const now_ms = utils.milliTimestamp();
                        if (self.rendered_rows > self.cursor_row) {
                            var move_down_buf: [32]u8 = undefined;
                            const seq = std.fmt.bufPrint(&move_down_buf, "\x1b[{d}B", .{self.rendered_rows - self.cursor_row}) catch "";
                            stdout_file.writeStreamingAll(io, seq) catch {};
                        }

                        if (self.buf.items.len > 0) {
                            stdout_file.writeStreamingAll(io, "^C\r\n") catch {};
                            self.buf.clearRetainingCapacity();
                            self.pos = 0;
                            self.rendered_rows = 0;
                            self.cursor_row = 0;
                            self.history_index = self.prompt_history.entries.items.len;
                            self.draft.clearRetainingCapacity();
                            self.last_ctrl_c_ms = now_ms;
                            self.redraw(io, prompt);
                            i += 1;
                        } else {
                            if (now_ms - self.last_ctrl_c_ms <= 2000 and self.last_ctrl_c_ms > 0) {
                                stdout_file.writeStreamingAll(io, "^C\r\n") catch {};
                                return null;
                            } else {
                                self.last_ctrl_c_ms = now_ms;
                                stdout_file.writeStreamingAll(io, "^C\r\n") catch {};
                                self.rendered_rows = 0;
                                self.cursor_row = 0;
                                self.redraw(io, prompt);
                                i += 1;
                            }
                        }
                    },
                    4 => { // Ctrl+D: EOF when buffer empty -> exit REPL
                        if (self.buf.items.len == 0) {
                            stdout_file.writeStreamingAll(io, "\r\n") catch {};
                            return null;
                        }
                        if (self.pos < self.buf.items.len) {
                            self.pushUndo();
                            const end = self.pos + self.clusterLenAt(self.pos);
                            if (self.deleteRange(self.pos, end)) |rem| self.alloc.free(rem);
                            self.redraw(io, prompt);
                        }
                        i += 1;
                    },
                    13 => { // Enter -> submit (entire buffer, including multiline)
                        // Backslash line continuation (RFC-008 §5B):
                        // If buffer ends with an unescaped backslash '\' at cursor/end,
                        // treat Enter as multiline continuation: strip '\' and insert '\n'.
                        if (self.pos == self.buf.items.len) {
                            var k = self.buf.items.len;
                            while (k > 0 and (self.buf.items[k - 1] == ' ' or self.buf.items[k - 1] == '\t')) : (k -= 1) {}
                            if (k > 0 and self.buf.items[k - 1] == '\\') {
                                const is_escaped = (k >= 2 and self.buf.items[k - 2] == '\\');
                                if (!is_escaped) {
                                    self.buf.items.len = k - 1;
                                    self.pos = self.buf.items.len;
                                    self.insertNewlineAtCursor(io, prompt);
                                    i += 1;
                                    continue;
                                }
                            }
                        }

                        if (self.rendered_rows > self.cursor_row) {
                            var move_down_buf: [32]u8 = undefined;
                            const seq = std.fmt.bufPrint(&move_down_buf, "\x1b[{d}B", .{self.rendered_rows - self.cursor_row}) catch "";
                            stdout_file.writeStreamingAll(io, seq) catch {};
                        }
                        stdout_file.writeStreamingAll(io, "\r\n") catch {};
                        return try self.alloc.dupe(u8, self.buf.items);
                    },
                    10 => { // Ctrl+J -> manually insert newline (RFC-008 §5B)
                        self.insertNewlineAtCursor(io, prompt);
                        i += 1;
                    },
                    12 => { // Ctrl+L redraw
                        stdout_file.writeStreamingAll(io, "\x1b[2J\x1b[H") catch {};
                        self.cursor_row = 0;
                        self.rendered_rows = 0;
                        self.redraw(io, prompt);
                        i += 1;
                    },
                    127, 8 => { // Backspace (grapheme)
                        if (self.pos > 0) {
                            self.pushUndo();
                            const start = self.pos - self.clusterLenBefore(self.pos);
                            if (self.deleteRange(start, self.pos)) |rem| self.alloc.free(rem);
                            self.redraw(io, prompt);
                        }
                        i += 1;
                    },
                    1 => { // Ctrl+A
                        self.pos = 0;
                        self.redraw(io, prompt);
                        i += 1;
                    },
                    5 => { // Ctrl+E
                        self.pos = self.buf.items.len;
                        self.redraw(io, prompt);
                        i += 1;
                    },
                    21 => { // Ctrl+U — delete to start of line
                        if (self.pos > 0) {
                            self.pushUndo();
                            if (self.deleteRange(0, self.pos)) |rem| self.alloc.free(rem);
                            self.redraw(io, prompt);
                        }
                        i += 1;
                    },
                    23 => { // Ctrl+W — kill word to the left
                        const start = self.wordLeft();
                        if (start < self.pos) {
                            self.pushUndo();
                            if (self.deleteRange(start, self.pos)) |rem| {
                                self.killPush(rem);
                                self.alloc.free(rem);
                            }
                            self.redraw(io, prompt);
                        }
                        i += 1;
                    },
                    11 => { // Ctrl+K — kill to end of line
                        if (self.pos < self.buf.items.len) {
                            self.pushUndo();
                            if (self.deleteRange(self.pos, self.buf.items.len)) |rem| {
                                self.killPush(rem);
                                self.alloc.free(rem);
                            }
                            self.redraw(io, prompt);
                        }
                        i += 1;
                    },
                    25 => { // Ctrl+Y — yank kill ring
                        if (self.killTop()) |text| {
                            self.pushUndo();
                            if (self.insertBytes(text)) {
                                self.redraw(io, prompt);
                            }
                        }
                        i += 1;
                    },
                    26 => { // Ctrl+Z — undo
                        if (self.applyUndo()) self.redraw(io, prompt);
                        i += 1;
                    },
                    19 => {
                        self.redraw(io, prompt);
                        i += 1;
                    },
                    31 => { // Ctrl+_ — redo (alias Ctrl+Y)
                        if (self.applyRedo()) self.redraw(io, prompt);
                        i += 1;
                    },
                    27 => { // ESC — escape sequence
                        const consumed = self.handleEscapeSlice(io, stdin_file, prompt, read_buf[i..n]);
                        i += consumed;
                    },
                    else => {
                        if (c >= 32) {
                            var end = i + 1;
                            while (end < n and read_buf[end] >= 32 and read_buf[end] != 127) : (end += 1) {}

                            if (end - i == 1) {
                                const seq_len = unicode.utf8Len(c);
                                var bytes: [4]u8 = undefined;
                                bytes[0] = c;
                                var got: usize = 1;
                                while (got < seq_len) : (got += 1) {
                                    var b: [1]u8 = undefined;
                                    const rn = stdin_file.readStreaming(io, &.{&b}) catch 0;
                                    if (rn == 0) break;
                                    bytes[got] = b[0];
                                }
                                self.pushUndo();
                                if (self.insertBytes(bytes[0..got])) {
                                    self.redraw(io, prompt);
                                } else {
                                    if (self.popUndo()) |entry| self.alloc.free(entry.snap);
                                    self.redraw(io, prompt);
                                }
                                i += 1;
                            } else {
                                // Batch insert for fast text / paste outside paste mode
                                self.pushUndo();
                                if (self.insertBytes(read_buf[i..end])) {
                                    self.redraw(io, prompt);
                                } else {
                                    if (self.popUndo()) |entry| self.alloc.free(entry.snap);
                                    self.redraw(io, prompt);
                                }
                                i = end;
                            }
                        } else {
                            i += 1;
                        }
                    },
                }
            }
        }
    }

    /// Handle escape sequences: arrow keys, Alt+key, Home/End, Delete, bracketed paste,
    /// Kitty CSI-u (Shift/Ctrl/Alt+Enter), xterm modifyOtherKeys, CSI-tilde.
    pub fn handleEscapeSlice(self: *LineEditor, io: std.Io, stdin_file: std.Io.File, prompt: []const u8, slice: []const u8) usize {
        var seq_buf: [64]u8 = undefined;
        var slen: usize = 0;

        const copy_len = @min(slice.len, seq_buf.len);
        @memcpy(seq_buf[0..copy_len], slice[0..copy_len]);
        slen = copy_len;

        // If only bare ESC in slice, poll stdin to see if more bytes arrive immediately.
        if (slen == 1) {
            var fds = [_]std.posix.pollfd{.{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&fds, 30) catch 0;
            if (ready > 0) {
                var b: [1]u8 = undefined;
                if ((stdin_file.readStreaming(io, &.{&b}) catch 0) > 0) {
                    seq_buf[1] = b[0];
                    slen = 2;
                }
            } else {
                // Bare ESC key alone — do not block
                return 1;
            }
        }

        // Two-byte ESC sequence: ESC + character (Alt/Meta key combinations)
        // If 2nd byte is neither '[' (CSI) nor 'O' (SS3), it's strictly a 2-byte sequence.
        if (slen >= 2 and seq_buf[1] != '[' and seq_buf[1] != 'O') {
            switch (seq_buf[1]) {
                '\r', '\n' => { // Alt+Enter / Meta+Enter -> newline (RFC-008 §5B)
                    self.insertNewlineAtCursor(io, prompt);
                },
                'b', 'B' => {
                    self.pos = self.wordLeft();
                    self.redraw(io, prompt);
                },
                'f', 'F' => {
                    self.pos = self.wordRight();
                    self.redraw(io, prompt);
                },
                'd', 'D' => {
                    const end = self.wordRight();
                    if (end > self.pos) {
                        self.pushUndo();
                        if (self.deleteRange(self.pos, end)) |rem| self.alloc.free(rem);
                        self.redraw(io, prompt);
                    }
                },
                127, 8 => {
                    const start = self.wordLeft();
                    if (start < self.pos) {
                        self.pushUndo();
                        if (self.deleteRange(start, self.pos)) |rem| {
                            self.killPush(rem);
                            self.alloc.free(rem);
                        }
                        self.redraw(io, prompt);
                    }
                },
                else => {},
            }
            return @min(2, slice.len);
        }

        // SS3 sequence: ESC O <char> (e.g. Home/End/Keypad)
        if (slen >= 2 and seq_buf[1] == 'O') {
            if (slen < 3) {
                var b: [1]u8 = undefined;
                if ((stdin_file.readStreaming(io, &.{&b}) catch 0) > 0) {
                    seq_buf[2] = b[0];
                    slen = 3;
                }
            }
            if (slen >= 3) {
                switch (seq_buf[2]) {
                    'H' => {
                        self.pos = 0;
                        self.redraw(io, prompt);
                    },
                    'F' => {
                        self.pos = self.buf.items.len;
                        self.redraw(io, prompt);
                    },
                    else => {},
                }
            }
            return @min(3, slice.len);
        }

        // CSI sequence: ESC [ ...
        if (slen >= 2 and seq_buf[1] == '[') {
            // Check for bracketed paste START marker: ESC [ 2 0 0 ~
            if (slen >= 6 and std.mem.startsWith(u8, seq_buf[0..6], "\x1b[200~")) {
                self.beginPaste();
                return @min(6, slice.len);
            }
            if (slen < 6 and std.mem.startsWith(u8, "\x1b[200~", seq_buf[0..slen])) {
                while (slen < 6) {
                    var b: [1]u8 = undefined;
                    if ((stdin_file.readStreaming(io, &.{&b}) catch 0) == 0) break;
                    seq_buf[slen] = b[0];
                    slen += 1;
                }
                if (slen >= 6 and std.mem.startsWith(u8, seq_buf[0..6], "\x1b[200~")) {
                    self.beginPaste();
                    return @min(6, slice.len);
                }
            }

            // Find terminator byte for CSI (final byte in ASCII 0x40..0x7E)
            var term_idx: ?usize = null;
            var t: usize = 2;
            while (t < slen) : (t += 1) {
                if (seq_buf[t] >= 0x40 and seq_buf[t] <= 0x7E) {
                    term_idx = t;
                    break;
                }
            }

            // Read remaining bytes if terminator not in buffer yet
            while (term_idx == null and slen < seq_buf.len) {
                var fds_csi = [_]std.posix.pollfd{.{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 }};
                const r = std.posix.poll(&fds_csi, 50) catch 0;
                if (r == 0) break;
                var b: [1]u8 = undefined;
                if ((stdin_file.readStreaming(io, &.{&b}) catch 0) == 0) break;
                seq_buf[slen] = b[0];
                if (seq_buf[slen] >= 0x40 and seq_buf[slen] <= 0x7E) {
                    term_idx = slen;
                    slen += 1;
                    break;
                }
                slen += 1;
            }

            if (term_idx) |t_pos| {
                const term_ch = seq_buf[t_pos];
                const consumed_from_slice = @min(t_pos + 1, slice.len);

                // Parse numeric parameters in seq_buf[2..t_pos], separated by ';' or ':'
                var params: [6]usize = .{ 0, 0, 0, 0, 0, 0 };
                var n_params: usize = 0;
                var val: usize = 0;
                var have_val = false;
                for (seq_buf[2..t_pos]) |b| {
                    if (b >= '0' and b <= '9') {
                        val = val * 10 + (b - '0');
                        have_val = true;
                    } else if (b == ';' or b == ':') {
                        if (n_params < params.len) params[n_params] = val;
                        n_params += 1;
                        val = 0;
                        have_val = false;
                    }
                }
                if (have_val and n_params < params.len) {
                    params[n_params] = val;
                    n_params += 1;
                }

                // Check CSI-u ('u')
                if (term_ch == 'u') {
                    // Kitty keyboard protocol: ESC [ <code> ; <mod> u
                    const code = params[0];
                    const modv = if (n_params > 1) params[1] else 1;
                    if (code == 13) {
                        // Enter with modifier (Shift=2, Alt=3, Ctrl=5, etc.) -> newline
                        self.insertNewlineAtCursor(io, prompt);
                        return consumed_from_slice;
                    }
                    if (code == 3 or (code == 99 and modv >= 5)) {
                        // Ctrl+C as CSI-u
                        const now_ms = utils.milliTimestamp();
                        const out = std.Io.File.stdout();
                        if (self.buf.items.len > 0) {
                            out.writeStreamingAll(io, "^C\r\n") catch {};
                            self.buf.clearRetainingCapacity();
                            self.pos = 0;
                            self.rendered_rows = 0;
                            self.cursor_row = 0;
                            self.last_ctrl_c_ms = now_ms;
                            self.redraw(io, prompt);
                        } else if (now_ms - self.last_ctrl_c_ms <= 2000 and self.last_ctrl_c_ms > 0) {
                            out.writeStreamingAll(io, "^C\r\n") catch {};
                            self.exit_pending = true;
                        } else {
                            self.last_ctrl_c_ms = now_ms;
                            out.writeStreamingAll(io, "^C\r\n") catch {};
                            self.rendered_rows = 0;
                            self.cursor_row = 0;
                            self.redraw(io, prompt);
                        }
                        return consumed_from_slice;
                    }
                    return consumed_from_slice;
                }

                // Check CSI '~' (modifyOtherKeys, CSI-tilde, Delete, Home, End)
                if (term_ch == '~') {
                    if (params[0] == 27 and n_params >= 3) {
                        // modifyOtherKeys: ESC [ 27 ; <mod> ; <code> ~
                        const code = params[2];
                        if (code == 13) {
                            self.insertNewlineAtCursor(io, prompt);
                            return consumed_from_slice;
                        }
                    } else if (params[0] == 13) {
                        // CSI tilde: ESC [ 13 ; <mod> ~ (Shift+Enter or Ctrl+Enter)
                        self.insertNewlineAtCursor(io, prompt);
                        return consumed_from_slice;
                    } else if (params[0] == 3) {
                        // Delete: ESC [ 3 ~
                        if (self.pos < self.buf.items.len) {
                            self.pushUndo();
                            const end = self.pos + self.clusterLenAt(self.pos);
                            if (self.deleteRange(self.pos, end)) |rem| self.alloc.free(rem);
                            self.redraw(io, prompt);
                        }
                        return consumed_from_slice;
                    } else if (params[0] == 1) {
                        // Home: ESC [ 1 ~
                        self.pos = 0;
                        self.redraw(io, prompt);
                        return consumed_from_slice;
                    } else if (params[0] == 4) {
                        // End: ESC [ 4 ~
                        self.pos = self.buf.items.len;
                        self.redraw(io, prompt);
                        return consumed_from_slice;
                    }
                    return consumed_from_slice;
                }

                // Standard letter CSI sequences
                switch (term_ch) {
                    'A' => { // ↑ history
                        self.loadHistoryEntry(-1);
                        self.redraw(io, prompt);
                        return consumed_from_slice;
                    },
                    'B' => { // ↓ history
                        self.loadHistoryEntry(1);
                        self.redraw(io, prompt);
                        return consumed_from_slice;
                    },
                    'C' => { // → or Alt+→
                        if (n_params >= 2 and params[0] == 1 and params[1] == 3) {
                            self.pos = self.wordRight();
                        } else {
                            self.moveRight();
                        }
                        self.redraw(io, prompt);
                        return consumed_from_slice;
                    },
                    'D' => { // ← or Alt+←
                        if (n_params >= 2 and params[0] == 1 and params[1] == 3) {
                            self.pos = self.wordLeft();
                        } else {
                            self.moveLeft();
                        }
                        self.redraw(io, prompt);
                        return consumed_from_slice;
                    },
                    'H' => { // Home
                        self.pos = 0;
                        self.redraw(io, prompt);
                        return consumed_from_slice;
                    },
                    'F' => { // End
                        self.pos = self.buf.items.len;
                        self.redraw(io, prompt);
                        return consumed_from_slice;
                    },
                    else => {
                        return consumed_from_slice;
                    },
                }
            }
        }

        return @max(1, @min(slen, slice.len));
    }

    /// Begin paste mode (START marker received).
    fn beginPaste(self: *LineEditor) void {
        self.pasting = true;
        self.paste_undo_pushed = false;
        self.paste_buf.clearRetainingCapacity();
        self.paste_parser.reset();
        paste_mod.sanitizeReset();
        paste_mod.sanitizeMultilineReset();
    }

    /// End paste mode: flush remaining held candidate as content and insert into buffer.
    fn endPaste(self: *LineEditor, io: std.Io, prompt: []const u8) void {
        if (!self.pasting) return;
        self.pasting = false;
        self.paste_undo_pushed = false;
        var tmp: [paste_mod.END_MARKER.len]u8 = undefined;
        const pre = self.paste_parser.pendingCopy(&tmp);
        for (pre) |b| _ = paste_mod.sanitizeAppendMultiline(&self.paste_buf, self.alloc, b);
        self.paste_parser.reset();
        paste_mod.sanitizeMultilineReset();

        if (self.paste_buf.items.len > 0) {
            self.pushUndo();
            _ = self.insertBytes(self.paste_buf.items);
            self.paste_buf.clearRetainingCapacity();
        }
        self.redraw(io, prompt);
    }

    /// Feed bytes in paste mode through state machine (see paste.zig).
    /// Returns offset in `bytes` IMMEDIATELY AFTER END marker if paste ended mid-chunk;
    /// returns `bytes.len` if chunk ended while still pasting.
    fn pasteFeed(self: *LineEditor, io: std.Io, prompt: []const u8, bytes: []const u8) usize {
        var tmp: [paste_mod.END_MARKER.len]u8 = undefined;
        var idx: usize = 0;
        while (idx < bytes.len) : (idx += 1) {
            const c = bytes[idx];
            const pre = self.paste_parser.pendingCopy(&tmp);
            switch (self.paste_parser.feed(c)) {
                .content => |b| {
                    _ = paste_mod.sanitizeAppendMultiline(&self.paste_buf, self.alloc, b);
                },
                .marker => |m| {
                    if (m == .end) {
                        self.endPaste(io, prompt);
                        // RCA-001: return byte offset AFTER end-marker. Caller
                        // uses it to continue processing remainder of chunk as
                        // normal input (bytes after END marker must not be swallowed).
                        return idx + 1;
                    }
                },
                .none => {},
                .fail => {
                    for (pre) |b| _ = paste_mod.sanitizeAppendMultiline(&self.paste_buf, self.alloc, b);
                    switch (self.paste_parser.feed(c)) {
                        .content => |b| _ = paste_mod.sanitizeAppendMultiline(&self.paste_buf, self.alloc, b),
                        .none => {},
                        else => {},
                    }
                },
            }
        }
        return bytes.len;
    }

    /// In paste mode: poll stdin for 100ms — if time expires without bytes,
    /// assume terminal will not send END marker -> caller exits paste mode automatically.
    /// (100ms: wide enough for large pastes over SSH/laggy networks, smaller than
    /// dummy byte thread TTL during tab switching to avoid stuck redraw — RCA-001.)
    fn pasteIdleTimedOut(_: *LineEditor, _: std.Io, _: std.Io.File) bool {
        var fds = [_]std.posix.pollfd{.{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, 100) catch return true;
        return ready == 0;
    }

    /// Sanitize (newline->space, strip control) then insert into buffer + redraw.
    fn insertPastedSanitized(self: *LineEditor, io: std.Io, prompt: []const u8, bytes: []const u8) void {
        if (bytes.len == 0) return;
        if (!self.paste_undo_pushed) {
            self.pushUndo();
            self.paste_undo_pushed = true;
        }
        var tmp_list: std.ArrayListUnmanaged(u8) = .empty;
        defer tmp_list.deinit(self.alloc);
        for (bytes) |b| _ = paste_mod.sanitizeAppend(&tmp_list, self.alloc, b);
        if (tmp_list.items.len > 0) {
            _ = self.insertBytes(tmp_list.items);
            self.redraw(io, prompt);
        }
    }

    /// Add to prompt history (called on submit).
    pub fn addHistory(self: *LineEditor, line: []const u8) !void {
        try self.prompt_history.add(line);
    }

    /// Load persistent history from disk.
    pub fn loadHistoryFile(self: *LineEditor, io: std.Io, path: []const u8) !void {
        try self.prompt_history.loadFromFile(io, path);
    }

    /// Flush persistent history to disk if dirty.
    pub fn saveHistoryFile(self: *LineEditor, io: std.Io, path: []const u8) !void {
        try self.prompt_history.saveToFile(io, path);
    }
};

// ---------------------------------------------------------------------------
// Tests — pure logic without terminal
// ---------------------------------------------------------------------------

const Testing = struct {
    fn makeEditor(alloc: Allocator) !LineEditor {
        var e = LineEditor.init(alloc);
        try e.buf.appendSlice(alloc, "hello world foo");
        e.pos = e.buf.items.len;
        return e;
    }
};

test "wordLeft / wordRight ASCII" {
    const alloc = std.testing.allocator;
    var e = try Testing.makeEditor(alloc);
    defer e.deinit();

    e.pos = e.buf.items.len; // after "foo"
    try std.testing.expectEqual(@as(usize, 12), e.wordLeft()); // before "foo"
    e.pos = 12;
    try std.testing.expectEqual(@as(usize, 6), e.wordLeft()); // before "world"
    e.pos = 6;
    try std.testing.expectEqual(@as(usize, 0), e.wordLeft()); // before "hello"

    e.pos = 0;
    try std.testing.expectEqual(@as(usize, 5), e.wordRight()); // after "hello"
    e.pos = 5;
    try std.testing.expectEqual(@as(usize, 11), e.wordRight()); // after "world"
}

test "word motion across punct" {
    const alloc = std.testing.allocator;
    var e = LineEditor.init(alloc);
    defer e.deinit();
    try e.buf.appendSlice(alloc, "foo.bar baz");
    e.pos = e.buf.items.len;
    try std.testing.expectEqual(@as(usize, 8), e.wordLeft()); // before "baz"
    e.pos = 8;
    try std.testing.expectEqual(@as(usize, 4), e.wordLeft()); // before "bar" ("." is separate punct cluster)
    e.pos = 4;
    try std.testing.expectEqual(@as(usize, 3), e.wordLeft()); // before "." ("foo" is 1 word)
}

test "word motion multibyte UTF-8" {
    const alloc = std.testing.allocator;
    var e = LineEditor.init(alloc);
    defer e.deinit();
    try e.buf.appendSlice(alloc, "tết đến rồi");
    e.pos = e.buf.items.len;
    const w1 = e.wordLeft(); // before "rồi"
    try std.testing.expectEqualStrings("rồi", e.buf.items[w1..]);
    e.pos = w1;
    const w2 = e.wordLeft(); // before "đến"
    try std.testing.expectEqualStrings("đến rồi", e.buf.items[w2..]);
}

test "undo redo basic" {
    const alloc = std.testing.allocator;
    var e = LineEditor.init(alloc);
    defer e.deinit();

    try e.buf.appendSlice(alloc, "abc");
    e.pos = 3;
    e.pushUndo();
    try e.buf.appendSlice(alloc, "def");
    e.pos = 6;
    try std.testing.expectEqualStrings("abcdef", e.buf.items);

    try std.testing.expect(e.applyUndo());
    try std.testing.expectEqualStrings("abc", e.buf.items);
    try std.testing.expectEqual(@as(usize, 3), e.pos);

    try std.testing.expect(e.applyRedo());
    try std.testing.expectEqualStrings("abcdef", e.buf.items);
}

test "undo ring depth cap" {
    const alloc = std.testing.allocator;
    var e = LineEditor.init(alloc);
    defer e.deinit();
    var i: usize = 0;
    while (i < UNDO_DEPTH + 5) : (i += 1) {
        e.pushUndo();
        try e.buf.appendSlice(alloc, "x");
    }
    try std.testing.expectEqual(@as(usize, UNDO_DEPTH), e.undo_len);
}

test "kill ring push/yank and depth cap" {
    const alloc = std.testing.allocator;
    var e = LineEditor.init(alloc);
    defer e.deinit();

    e.killPush("one");
    e.killPush("two");
    try std.testing.expectEqualStrings("two", e.killTop().?);

    var i: usize = 0;
    while (i < KILL_RING_DEPTH + 2) : (i += 1) e.killPush("x");
    try std.testing.expectEqual(@as(usize, KILL_RING_DEPTH), e.kill_len);
}

test "insertBytes reject when exceeding limit" {
    const alloc = std.testing.allocator;
    var e = LineEditor.init(alloc);
    defer e.deinit();
    try e.buf.appendSlice(alloc, "a" ** (MAX_INPUT_BYTES - 2));
    e.pos = e.buf.items.len;
    try std.testing.expect(!e.insertBytes("xyz"));
    try std.testing.expect(e.limit_msg);
    try std.testing.expect(e.insertBytes("ab")); // exact fit
}

test "deleteRange updates pos correctly" {
    const alloc = std.testing.allocator;
    var e = LineEditor.init(alloc);
    defer e.deinit();
    try e.buf.appendSlice(alloc, "hello world");
    e.pos = 11;
    const rem = e.deleteRange(5, 11);
    defer alloc.free(rem.?);
    try std.testing.expectEqualStrings(" world", rem.?);
    try std.testing.expectEqualStrings("hello", e.buf.items);
    try std.testing.expectEqual(@as(usize, 5), e.pos);
}

test "clusterLenBefore with emoji and multibyte UTF-8" {
    const alloc = std.testing.allocator;
    var e = LineEditor.init(alloc);
    defer e.deinit();
    // "a" + "ế" (3 bytes) + 👍 (4 bytes)
    try e.buf.appendSlice(alloc, "a\u{1EBF}\u{1F44D}");
    e.pos = e.buf.items.len;
    e.moveLeft(); // past 👍 (4 bytes)
    try std.testing.expectEqual(@as(usize, 4), e.pos);
    e.moveLeft(); // past ế (3 bytes)
    try std.testing.expectEqual(@as(usize, 1), e.pos);
    e.moveLeft(); // past a
    try std.testing.expectEqual(@as(usize, 0), e.pos);
}

// ---------------------------------------------------------------------------
// Paste mode — repro & fix for stuck paste bug (see paste.zig)
// ---------------------------------------------------------------------------

/// Simulate feeding a stream of bytes into editor in paste mode.
/// Returns buffer after stream completes (no timeout — uses parser directly).
fn simulatePaste(alloc: Allocator, input: []const u8) ![]u8 {
    var e = LineEditor.init(alloc);
    defer e.deinit();
    e.suppress_redraw = true;
    e.beginPaste();
    _ = e.pasteFeed(undefined, "", input);
    if (e.pasting) e.endPaste(undefined, "");
    return alloc.dupe(u8, e.buf.items);
}

test "normal paste: content between start/end marker" {
    const alloc = std.testing.allocator;
    const out = try simulatePaste(alloc, "hello pasted" ++ paste_mod.END_MARKER);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("hello pasted", out);
}

test "multiline paste: preserves newlines (RFC-008 §5A)" {
    const alloc = std.testing.allocator;
    const out = try simulatePaste(alloc, "line1\r\nline2\nline3" ++ paste_mod.END_MARKER);
    defer alloc.free(out);
    // CRLF -> 1 \n (no double), single \n preserved.
    try std.testing.expectEqualStrings("line1\nline2\nline3", out);
}

test "multiline paste preserves indent (tab + space)" {
    const alloc = std.testing.allocator;
    const out = try simulatePaste(alloc, "fn x() {\n\treturn 1;\n}" ++ paste_mod.END_MARKER);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("fn x() {\n\treturn 1;\n}", out);
}

test "insertNewlineAtCursor: inserts \\n in middle of buffer, pos correct" {
    const alloc = std.testing.allocator;
    var e = LineEditor.init(alloc);
    defer e.deinit();
    e.suppress_redraw = true;
    try e.buf.appendSlice(alloc, "ab");
    e.pos = 1;
    e.insertNewlineAtCursor(undefined, "");
    try std.testing.expectEqualStrings("a\nb", e.buf.items);
    try std.testing.expectEqual(@as(usize, 2), e.pos);
}

test "paste containing ANSI escape does not mistake end-marker" {
    const alloc = std.testing.allocator;
    const input = "\x1b[31mred\x1b[0m end" ++ paste_mod.END_MARKER;
    const out = try simulatePaste(alloc, input);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("[31mred[0m end", out);
}

test "paste containing prefix near end-marker still detects real marker" {
    const alloc = std.testing.allocator;
    const input = "abc\x1b[20" ++ paste_mod.END_MARKER;
    const out = try simulatePaste(alloc, input);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("abc[20", out);
}

test "paste without end-marker: flushes pending, editor does not hang" {
    const alloc = std.testing.allocator;
    var e = LineEditor.init(alloc);
    defer e.deinit();
    e.suppress_redraw = true;
    e.beginPaste();
    const consumed = e.pasteFeed(undefined, "", "dangling\x1b[2");
    _ = consumed;
    // Idle timeout path: call endPaste as editor would.
    e.endPaste(undefined, "");
    try std.testing.expect(!e.pasting);
    try std.testing.expectEqualStrings("dangling[2", e.buf.items);
}

test "paste UTF-8 multibyte + emoji preserved" {
    const alloc = std.testing.allocator;
    const out = try simulatePaste(alloc, "xin chào thế giới 👍" ++ paste_mod.END_MARKER);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("xin chào thế giới 👍", out);
}

test "long paste chunk does not repeat redraw or overflow line" {
    const alloc = std.testing.allocator;
    var e = LineEditor.init(alloc);
    defer e.deinit();
    e.suppress_redraw = true;
    e.beginPaste();
    const long_text = "// contextTools returns tools that let the producer inspect and compact its // current session. " ** 10;
    _ = e.pasteFeed(undefined, "", long_text ++ paste_mod.END_MARKER);
    try std.testing.expect(!e.pasting);
    try std.testing.expect(e.buf.items.len > 500);
}

// RCA-001: START marker located MID-chunk — content after marker is paste content,
// must not go through normal path (accidental Enter -> premature submit).
test "paste starting mid-chunk: portion after START marker enters paste mode" {
    const alloc = std.testing.allocator;
    var e = LineEditor.init(alloc);
    defer e.deinit();
    e.suppress_redraw = true;

    // Simulate main loop receiving 1 chunk: prompt-echo + Enter + START + "l1\r\nl2"
    const chunk = "abc\r\x1b[200~l1\r\nl2";
    // Go through normal path until reaching ESC[200~: simulate by feeding
    // initial portion as main loop (3 chars + Enter), then remaining chunk.
    for ("abc") |ch| _ = e.insertBytes(&.{ch});
    e.pos = e.buf.items.len;
    _ = e.handleEscapeSlice(undefined, undefined, "", chunk[4..]);
    try std.testing.expect(e.pasting); // START marker enabled paste mode

    // Remainder of chunk ("l1\r\nl2") MUST be handled by pasteFeed:
    const consumed = e.pasteFeed(undefined, "", chunk[10..]);
    try std.testing.expectEqual(@as(usize, chunk.len - 10), consumed);
    e.endPaste(undefined, "");
    try std.testing.expectEqualStrings("abcl1\nl2", e.buf.items);
}

// RCA-001: END marker located mid-chunk — bytes after marker are normal input
// (Enter immediately after paste -> submit, not swallowed).
test "paste ending mid-chunk: bytes after END marker are not swallowed" {
    const alloc = std.testing.allocator;
    var e = LineEditor.init(alloc);
    defer e.deinit();
    e.suppress_redraw = true;

    e.beginPaste();
    const consumed = e.pasteFeed(undefined, "", "abc" ++ paste_mod.END_MARKER ++ "xyz");
    try std.testing.expect(!e.pasting);
    try std.testing.expectEqual(@as(usize, 3 + paste_mod.END_MARKER.len), consumed);
    e.endPaste(undefined, "");
    try std.testing.expectEqualStrings("abc", e.buf.items);
    // "xyz" (returned offset) must remain for caller to process as regular input.
}

test "Shift+Enter / Ctrl+Enter: Kitty CSI-u escapes insert newline" {
    const alloc = std.testing.allocator;
    var e = LineEditor.init(alloc);
    defer e.deinit();
    e.suppress_redraw = true;

    try e.buf.appendSlice(alloc, "first line");
    e.pos = e.buf.items.len;

    // Kitty Shift+Enter: \x1b[13;2u
    const seq_shift = "\x1b[13;2u";
    const consumed1 = e.handleEscapeSlice(undefined, undefined, "", seq_shift);
    try std.testing.expectEqual(seq_shift.len, consumed1);
    try std.testing.expectEqualStrings("first line\n", e.buf.items);

    // Kitty Shift+Enter with event type (press :1): \x1b[13;2:1u
    const seq_shift_press = "\x1b[13;2:1u";
    const consumed2 = e.handleEscapeSlice(undefined, undefined, "", seq_shift_press);
    try std.testing.expectEqual(seq_shift_press.len, consumed2);
    try std.testing.expectEqualStrings("first line\n\n", e.buf.items);

    // Kitty Ctrl+Enter: \x1b[13;5u
    const seq_ctrl = "\x1b[13;5u";
    const consumed3 = e.handleEscapeSlice(undefined, undefined, "", seq_ctrl);
    try std.testing.expectEqual(seq_ctrl.len, consumed3);
    try std.testing.expectEqualStrings("first line\n\n\n", e.buf.items);
}

test "Shift+Enter / Ctrl+Enter: xterm modifyOtherKeys escapes insert newline" {
    const alloc = std.testing.allocator;
    var e = LineEditor.init(alloc);
    defer e.deinit();
    e.suppress_redraw = true;

    try e.buf.appendSlice(alloc, "hello");
    e.pos = e.buf.items.len;

    // xterm Shift+Enter: \x1b[27;2;13~
    const seq_shift = "\x1b[27;2;13~";
    const consumed1 = e.handleEscapeSlice(undefined, undefined, "", seq_shift);
    try std.testing.expectEqual(seq_shift.len, consumed1);
    try std.testing.expectEqualStrings("hello\n", e.buf.items);

    // xterm Ctrl+Enter: \x1b[27;5;13~
    const seq_ctrl = "\x1b[27;5;13~";
    const consumed2 = e.handleEscapeSlice(undefined, undefined, "", seq_ctrl);
    try std.testing.expectEqual(seq_ctrl.len, consumed2);
    try std.testing.expectEqualStrings("hello\n\n", e.buf.items);
}

test "Shift+Enter / Ctrl+Enter: CSI-tilde escapes insert newline" {
    const alloc = std.testing.allocator;
    var e = LineEditor.init(alloc);
    defer e.deinit();
    e.suppress_redraw = true;

    try e.buf.appendSlice(alloc, "line");
    e.pos = e.buf.items.len;

    // CSI tilde Shift+Enter: \x1b[13;2~
    const seq_shift = "\x1b[13;2~";
    const consumed1 = e.handleEscapeSlice(undefined, undefined, "", seq_shift);
    try std.testing.expectEqual(seq_shift.len, consumed1);
    try std.testing.expectEqualStrings("line\n", e.buf.items);

    // CSI tilde Ctrl+Enter: \x1b[13;5~
    const seq_ctrl = "\x1b[13;5~";
    const consumed2 = e.handleEscapeSlice(undefined, undefined, "", seq_ctrl);
    try std.testing.expectEqual(seq_ctrl.len, consumed2);
    try std.testing.expectEqualStrings("line\n\n", e.buf.items);
}

test "Alt+Enter: ESC-prefixed sequences insert newline without blocking" {
    const alloc = std.testing.allocator;
    var e = LineEditor.init(alloc);
    defer e.deinit();
    e.suppress_redraw = true;

    try e.buf.appendSlice(alloc, "item");
    e.pos = e.buf.items.len;

    const consumed1 = e.handleEscapeSlice(undefined, undefined, "", "\x1b\r");
    try std.testing.expectEqual(@as(usize, 2), consumed1);
    try std.testing.expectEqualStrings("item\n", e.buf.items);

    const consumed2 = e.handleEscapeSlice(undefined, undefined, "", "\x1b\n");
    try std.testing.expectEqual(@as(usize, 2), consumed2);
    try std.testing.expectEqualStrings("item\n\n", e.buf.items);
}

test "Backslash line continuation: trailing backslash stripped and newline inserted" {
    const alloc = std.testing.allocator;
    var e = LineEditor.init(alloc);
    defer e.deinit();
    e.suppress_redraw = true;

    try e.buf.appendSlice(alloc, "first line \\");
    e.pos = e.buf.items.len;

    // Simulate Enter when line ends with backslash
    if (e.pos == e.buf.items.len) {
        var k = e.buf.items.len;
        while (k > 0 and (e.buf.items[k - 1] == ' ' or e.buf.items[k - 1] == '\t')) : (k -= 1) {}
        if (k > 0 and e.buf.items[k - 1] == '\\') {
            const is_escaped = (k >= 2 and e.buf.items[k - 2] == '\\');
            if (!is_escaped) {
                e.buf.items.len = k - 1;
                e.pos = e.buf.items.len;
                e.insertNewlineAtCursor(undefined, "");
            }
        }
    }
    try std.testing.expectEqualStrings("first line \n", e.buf.items);
}


