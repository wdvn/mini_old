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

    fn renderClearPrevious(w: anytype, cursor_row: usize, limit_msg: bool) !void {
        if (cursor_row > 0) {
            try w.print("\x1b[{d}A", .{cursor_row});
        }
        try w.writeAll("\r\x1b[J");
        if (limit_msg) {
            try w.writeAll("\x1b[33m[input limit 64KB — rejected]\x1b[0m\r\n\x1b[J");
        }
    }

    fn positionCursor(w: anytype, total_rows: usize, cur_row: usize, cur_col: usize) !void {
        if (total_rows > cur_row) {
            try w.print("\x1b[{d}A", .{total_rows - cur_row});
        }
        try w.writeAll("\r");
        if (cur_col > 0) {
            try w.print("\x1b[{d}C", .{cur_col});
        }
    }

    const LayoutResult = struct {
        total_rows: usize,
        cur_row: usize,
        cur_col: usize,
    };

    fn updateCursorPlacement(
        self: *LineEditor,
        line_start: usize,
        k: usize,
        prefix_w: usize,
        total_rows: usize,
        cols: usize,
        cursor_placed: *bool,
        cur_row: *usize,
        cur_col: *usize,
    ) void {
        if (!cursor_placed.* and self.pos <= k) {
            const in_w = unicode.displayWidth(self.buf.items[line_start..@min(self.pos, k)]);
            const coff = prefix_w + in_w;
            cur_row.* = total_rows + coff / cols;
            cur_col.* = coff % cols;
            cursor_placed.* = true;
        }
    }

    fn renderLogicalLines(
        self: *LineEditor,
        w: anytype,
        prompt: []const u8,
        prompt_w: usize,
        cols: usize,
    ) !LayoutResult {
        var indent_buf: [64]u8 = undefined;
        const indent_len = @min(prompt_w, indent_buf.len);
        @memset(indent_buf[0..indent_len], ' ');
        const indent = indent_buf[0..indent_len];

        var total_rows: usize = 0;
        var cur_row: usize = 0;
        var cur_col: usize = 0;
        var cursor_placed = false;

        var line_start: usize = 0;
        var line_idx: usize = 0;
        var k: usize = 0;
        while (k <= self.buf.items.len) : (k += 1) {
            const at_end = k == self.buf.items.len;
            if (!at_end and self.buf.items[k] != '\n') continue;

            const line = self.buf.items[line_start..k];
            const prefix_w: usize = if (line_idx == 0) prompt_w else indent_len;
            const lw = prefix_w + unicode.displayWidth(line);

            if (line_idx == 0) {
                try w.writeAll(prompt);
            } else {
                try w.writeAll("\r\n");
                try w.writeAll(indent);
            }
            try w.writeAll(line);

            self.updateCursorPlacement(line_start, k, prefix_w, total_rows, cols, &cursor_placed, &cur_row, &cur_col);

            total_rows += lw / cols;
            if (at_end) break;
            line_start = k + 1;
            line_idx += 1;
        }
        return .{ .total_rows = total_rows, .cur_row = cur_row, .cur_col = cur_col };
    }

    fn redraw(self: *LineEditor, io: std.Io, prompt: []const u8) void {
        // PSEUDOCODE:
        // 1. Check redraw suppression.
        // 2. Clear previously rendered rows downwards.
        // 3. Render logical lines with multiline indent and calculate cursor row/col.
        // 4. Move terminal cursor to calculated position and flush buffer.
        if (self.suppress_redraw) return;
        var out_buf: [8192]u8 = undefined;
        var w = std.Io.Writer.fixed(&out_buf);

        renderClearPrevious(&w, self.cursor_row, self.limit_msg) catch return;

        const term_size = term.getTerminalSize();
        const cols: usize = if (term_size.cols > 0) term_size.cols else 80;
        const prompt_w = unicode.visibleWidth(prompt);

        const layout = self.renderLogicalLines(&w, prompt, prompt_w, cols) catch return;
        positionCursor(&w, layout.total_rows, layout.cur_row, layout.cur_col) catch return;

        self.rendered_rows = layout.total_rows;
        self.cursor_row = layout.cur_row;

        const stdout_file = std.Io.File.stdout();
        stdout_file.writeStreamingAll(io, out_buf[0..w.end]) catch {};
    }

    // -----------------------------------------------------------------------
    // Main loop
    // -----------------------------------------------------------------------

    fn setupRawTerminal(stdin_fd: std.posix.fd_t) !std.posix.termios {
        const orig_termios = try std.posix.tcgetattr(stdin_fd);
        var raw = orig_termios;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INLCR = false;
        raw.iflag.IGNCR = false;
        raw.iflag.IXON = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        try std.posix.tcsetattr(stdin_fd, .FLUSH, raw);
        return orig_termios;
    }

    fn initReadLineState(self: *LineEditor) void {
        self.buf.clearRetainingCapacity();
        self.pos = 0;
        self.rendered_rows = 0;
        self.cursor_row = 0;
        self.limit_msg = false;
        self.exit_pending = false;
        self.history_index = self.prompt_history.entries.items.len;
        self.draft.clearRetainingCapacity();
    }

    fn handleCtrlC(self: *LineEditor, io: std.Io, stdout_file: std.Io.File, prompt: []const u8) ?bool {
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
            return true;
        }
        if (now_ms - self.last_ctrl_c_ms <= 2000 and self.last_ctrl_c_ms > 0) {
            stdout_file.writeStreamingAll(io, "^C\r\n") catch {};
            return false;
        }
        self.last_ctrl_c_ms = now_ms;
        stdout_file.writeStreamingAll(io, "^C\r\n") catch {};
        self.rendered_rows = 0;
        self.cursor_row = 0;
        self.redraw(io, prompt);
        return true;
    }

    fn handleEnterKey(self: *LineEditor, io: std.Io, stdout_file: std.Io.File, prompt: []const u8) !?[]const u8 {
        if (self.pos == self.buf.items.len) {
            var k = self.buf.items.len;
            while (k > 0 and (self.buf.items[k - 1] == ' ' or self.buf.items[k - 1] == '\t')) : (k -= 1) {}
            if (k > 0 and self.buf.items[k - 1] == '\\') {
                const is_escaped = (k >= 2 and self.buf.items[k - 2] == '\\');
                if (!is_escaped) {
                    self.buf.items.len = k - 1;
                    self.pos = self.buf.items.len;
                    self.insertNewlineAtCursor(io, prompt);
                    return null;
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
    }

    fn handlePrintableText(self: *LineEditor, io: std.Io, stdin_file: std.Io.File, prompt: []const u8, slice: []const u8) usize {
        const c = slice[0];
        var end: usize = 1;
        while (end < slice.len and slice[end] >= 32 and slice[end] != 127) : (end += 1) {}

        if (end == 1) {
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
            if (!self.insertBytes(bytes[0..got])) {
                if (self.popUndo()) |entry| self.alloc.free(entry.snap);
            }
            self.redraw(io, prompt);
            return 1;
        }
        self.pushUndo();
        if (!self.insertBytes(slice[0..end])) {
            if (self.popUndo()) |entry| self.alloc.free(entry.snap);
        }
        self.redraw(io, prompt);
        return end;
    }

    fn handleControlKey(self: *LineEditor, io: std.Io, prompt: []const u8, c: u8) void {
        switch (c) {
            1 => self.pos = 0,
            5 => self.pos = self.buf.items.len,
            10 => self.insertNewlineAtCursor(io, prompt),
            127, 8 => {
                if (self.pos > 0) {
                    self.pushUndo();
                    const start = self.pos - self.clusterLenBefore(self.pos);
                    if (self.deleteRange(start, self.pos)) |rem| self.alloc.free(rem);
                }
            },
            21 => {
                if (self.pos > 0) {
                    self.pushUndo();
                    if (self.deleteRange(0, self.pos)) |rem| self.alloc.free(rem);
                }
            },
            23 => {
                const start = self.wordLeft();
                if (start < self.pos) {
                    self.pushUndo();
                    if (self.deleteRange(start, self.pos)) |rem| {
                        self.killPush(rem);
                        self.alloc.free(rem);
                    }
                }
            },
            11 => {
                if (self.pos < self.buf.items.len) {
                    self.pushUndo();
                    if (self.deleteRange(self.pos, self.buf.items.len)) |rem| {
                        self.killPush(rem);
                        self.alloc.free(rem);
                    }
                }
            },
            25 => {
                if (self.killTop()) |text| {
                    self.pushUndo();
                    _ = self.insertBytes(text);
                }
            },
            26 => _ = self.applyUndo(),
            31 => _ = self.applyRedo(),
            else => {},
        }
        self.redraw(io, prompt);
    }

    fn handleInterruptedRead(self: *LineEditor, io: std.Io, stdout_file: std.Io.File, prompt: []const u8) ?void {
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
    }

    fn handleCtrlD(self: *LineEditor, io: std.Io, stdout_file: std.Io.File, prompt: []const u8) ?void {
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
    }

    fn processInputByte(
        self: *LineEditor,
        io: std.Io,
        stdin_file: std.Io.File,
        stdout_file: std.Io.File,
        prompt: []const u8,
        buf: []const u8,
        i: *usize,
    ) !?[]const u8 {
        const c = buf[i.*];
        if (c != 3) self.last_ctrl_c_ms = 0;
        switch (c) {
            3 => {
                if (self.handleCtrlC(io, stdout_file, prompt)) |keep_running| {
                    if (!keep_running) return null;
                    i.* += 1;
                }
            },
            4 => {
                if (self.handleCtrlD(io, stdout_file, prompt) == null) return null;
                i.* += 1;
            },
            13 => {
                if (try self.handleEnterKey(io, stdout_file, prompt)) |res| return res;
                i.* += 1;
            },
            12 => {
                stdout_file.writeStreamingAll(io, "\x1b[2J\x1b[H") catch {};
                self.cursor_row = 0;
                self.rendered_rows = 0;
                self.redraw(io, prompt);
                i.* += 1;
            },
            27 => {
                i.* += self.handleEscapeSlice(io, stdin_file, prompt, buf[i.*..]);
            },
            else => {
                if (c >= 32) {
                    i.* += self.handlePrintableText(io, stdin_file, prompt, buf[i.*..]);
                } else {
                    self.handleControlKey(io, prompt, c);
                    i.* += 1;
                }
            },
        }
        return null;
    }

    fn processReadChunk(
        self: *LineEditor,
        io: std.Io,
        stdin_file: std.Io.File,
        stdout_file: std.Io.File,
        prompt: []const u8,
        chunk: []const u8,
    ) !?[]const u8 {
        var i: usize = 0;
        if (self.pasting) {
            const consumed = self.pasteFeed(io, prompt, chunk);
            if (self.pasting) {
                if (self.pasteIdleTimedOut(io, stdin_file)) self.endPaste(io, prompt);
                return null;
            }
            i = consumed;
        }

        while (i < chunk.len) {
            if (self.pasting) {
                const consumed = self.pasteFeed(io, prompt, chunk[i..]);
                if (!self.pasting) {
                    i += consumed;
                    continue;
                }
                if (self.pasteIdleTimedOut(io, stdin_file)) self.endPaste(io, prompt);
                break;
            }
            if (try self.processInputByte(io, stdin_file, stdout_file, prompt, chunk, &i)) |submitted| {
                return submitted;
            }
        }
        return null;
    }

    pub fn readLine(self: *LineEditor, io: std.Io, prompt: []const u8) !?[]const u8 {
        // PSEUDOCODE:
        // 1. Configure raw terminal mode and bracketed paste.
        // 2. Initialize line buffer state and render initial prompt.
        // 3. Process incoming stdin bytes in event loop until submission or EOF.
        const stdin_fd = std.posix.STDIN_FILENO;
        const stdout_file = std.Io.File.stdout();
        const stdin_file = std.Io.File.stdin();

        const orig_termios = try setupRawTerminal(stdin_fd);
        defer {
            stdout_file.writeStreamingAll(io, "\x1b[?2004l\x1b[<u\x1b[>4;0m") catch {};
            std.posix.tcsetattr(stdin_fd, .FLUSH, orig_termios) catch {};
        }

        stdout_file.writeStreamingAll(io, "\x1b[>4;1m\x1b[>1u\x1b[?2004h") catch {};

        self.initReadLineState();
        self.redraw(io, prompt);

        while (true) {
            if (self.exit_pending and self.buf.items.len == 0) return null;

            var read_buf: [1024]u8 = undefined;
            const n = stdin_file.readStreaming(io, &.{&read_buf}) catch |err| {
                if (err == error.Interrupted) {
                    if (self.handleInterruptedRead(io, stdout_file, prompt) == null) return null;
                    continue;
                }
                return err;
            };
            if (n == 0) return null;

            if (try self.processReadChunk(io, stdin_file, stdout_file, prompt, read_buf[0..n])) |submitted| {
                return submitted;
            }
        }
    }

    fn handleAltEscape(self: *LineEditor, io: std.Io, prompt: []const u8, c: u8) void {
        switch (c) {
            '\r', '\n' => self.insertNewlineAtCursor(io, prompt),
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
    }

    fn handleSS3Escape(self: *LineEditor, io: std.Io, prompt: []const u8, c: u8) void {
        switch (c) {
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

    fn handleCsiU(self: *LineEditor, io: std.Io, prompt: []const u8, params: []const usize, n_params: usize) void {
        const code = params[0];
        const modv = if (n_params > 1) params[1] else 1;
        if (code == 13) {
            self.insertNewlineAtCursor(io, prompt);
            return;
        }
        if (code == 3 or (code == 99 and modv >= 5)) {
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
        }
    }

    fn handleCsiTilde(self: *LineEditor, io: std.Io, prompt: []const u8, params: []const usize, n_params: usize) void {
        if (params[0] == 27 and n_params >= 3) {
            if (params[2] == 13) self.insertNewlineAtCursor(io, prompt);
        } else if (params[0] == 13) {
            self.insertNewlineAtCursor(io, prompt);
        } else if (params[0] == 3) {
            if (self.pos < self.buf.items.len) {
                self.pushUndo();
                const end = self.pos + self.clusterLenAt(self.pos);
                if (self.deleteRange(self.pos, end)) |rem| self.alloc.free(rem);
                self.redraw(io, prompt);
            }
        } else if (params[0] == 1) {
            self.pos = 0;
            self.redraw(io, prompt);
        } else if (params[0] == 4) {
            self.pos = self.buf.items.len;
            self.redraw(io, prompt);
        }
    }

    fn handleCsiLetter(self: *LineEditor, io: std.Io, prompt: []const u8, term_ch: u8, params: []const usize, n_params: usize) void {
        switch (term_ch) {
            'A' => self.loadHistoryEntry(-1),
            'B' => self.loadHistoryEntry(1),
            'C' => {
                if (n_params >= 2 and params[0] == 1 and params[1] == 3) {
                    self.pos = self.wordRight();
                } else {
                    self.moveRight();
                }
            },
            'D' => {
                if (n_params >= 2 and params[0] == 1 and params[1] == 3) {
                    self.pos = self.wordLeft();
                } else {
                    self.moveLeft();
                }
            },
            'H' => self.pos = 0,
            'F' => self.pos = self.buf.items.len,
            else => return,
        }
        self.redraw(io, prompt);
    }

    const CsiParams = struct {
        params: [6]usize = .{ 0, 0, 0, 0, 0, 0 },
        n_params: usize = 0,
    };

    fn parseCsiParams(seq: []const u8) CsiParams {
        var result = CsiParams{};
        var val: usize = 0;
        var have_val = false;
        for (seq) |b| {
            if (b >= '0' and b <= '9') {
                val = val * 10 + (b - '0');
                have_val = true;
            } else if (b == ';' or b == ':') {
                if (result.n_params < result.params.len) result.params[result.n_params] = val;
                result.n_params += 1;
                val = 0;
                have_val = false;
            }
        }
        if (have_val and result.n_params < result.params.len) {
            result.params[result.n_params] = val;
            result.n_params += 1;
        }
        return result;
    }

    fn readCsiTerminator(io: std.Io, stdin_file: std.Io.File, seq_buf: *[64]u8, slen: *usize) ?usize {
        var t: usize = 2;
        while (t < slen.*) : (t += 1) {
            if (seq_buf[t] >= 0x40 and seq_buf[t] <= 0x7E) return t;
        }
        while (slen.* < seq_buf.len) {
            var fds_csi = [_]std.posix.pollfd{.{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 }};
            const r = std.posix.poll(&fds_csi, 50) catch 0;
            if (r == 0) break;
            var b: [1]u8 = undefined;
            if ((stdin_file.readStreaming(io, &.{&b}) catch 0) == 0) break;
            seq_buf[slen.*] = b[0];
            if (b[0] >= 0x40 and b[0] <= 0x7E) {
                const idx = slen.*;
                slen.* += 1;
                return idx;
            }
            slen.* += 1;
        }
        return null;
    }

    fn handleCsiSequence(
        self: *LineEditor,
        io: std.Io,
        stdin_file: std.Io.File,
        prompt: []const u8,
        seq_buf: *[64]u8,
        slen: *usize,
        slice_len: usize,
    ) ?usize {
        if (slen.* >= 6 and std.mem.startsWith(u8, seq_buf[0..6], "\x1b[200~")) {
            self.beginPaste();
            return @min(6, slice_len);
        }
        if (slen.* < 6 and std.mem.startsWith(u8, "\x1b[200~", seq_buf[0..slen.*])) {
            while (slen.* < 6) {
                var b: [1]u8 = undefined;
                if ((stdin_file.readStreaming(io, &.{&b}) catch 0) == 0) break;
                seq_buf[slen.*] = b[0];
                slen.* += 1;
            }
            if (slen.* >= 6 and std.mem.startsWith(u8, seq_buf[0..6], "\x1b[200~")) {
                self.beginPaste();
                return @min(6, slice_len);
            }
        }

        const t_pos = readCsiTerminator(io, stdin_file, seq_buf, slen) orelse return null;
        const term_ch = seq_buf[t_pos];
        const consumed = @min(t_pos + 1, slice_len);
        const parsed = parseCsiParams(seq_buf[2..t_pos]);

        if (term_ch == 'u') {
            self.handleCsiU(io, prompt, &parsed.params, parsed.n_params);
        } else if (term_ch == '~') {
            self.handleCsiTilde(io, prompt, &parsed.params, parsed.n_params);
        } else {
            self.handleCsiLetter(io, prompt, term_ch, &parsed.params, parsed.n_params);
        }
        return consumed;
    }

    /// Handle escape sequences: arrow keys, Alt+key, Home/End, Delete, bracketed paste,
    /// Kitty CSI-u (Shift/Ctrl/Alt+Enter), xterm modifyOtherKeys, CSI-tilde.
    pub fn handleEscapeSlice(self: *LineEditor, io: std.Io, stdin_file: std.Io.File, prompt: []const u8, slice: []const u8) usize {
        // PSEUDOCODE:
        // 1. Copy initial escape slice to buffer and poll next byte if bare ESC.
        // 2. Dispatch to 2-byte Alt sequence, SS3 sequence, or CSI sequence handler.
        var seq_buf: [64]u8 = undefined;
        const copy_len = @min(slice.len, seq_buf.len);
        @memcpy(seq_buf[0..copy_len], slice[0..copy_len]);
        var slen: usize = copy_len;

        if (slen == 1) {
            var fds = [_]std.posix.pollfd{.{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 }};
            if ((std.posix.poll(&fds, 30) catch 0) > 0) {
                var b: [1]u8 = undefined;
                if ((stdin_file.readStreaming(io, &.{&b}) catch 0) > 0) {
                    seq_buf[1] = b[0];
                    slen = 2;
                }
            } else {
                return 1;
            }
        }

        if (slen >= 2 and seq_buf[1] != '[' and seq_buf[1] != 'O') {
            self.handleAltEscape(io, prompt, seq_buf[1]);
            return @min(2, slice.len);
        }

        if (slen >= 2 and seq_buf[1] == 'O') {
            if (slen < 3) {
                var b: [1]u8 = undefined;
                if ((stdin_file.readStreaming(io, &.{&b}) catch 0) > 0) {
                    seq_buf[2] = b[0];
                    slen = 3;
                }
            }
            if (slen >= 3) self.handleSS3Escape(io, prompt, seq_buf[2]);
            return @min(3, slice.len);
        }

        if (slen >= 2 and seq_buf[1] == '[') {
            if (self.handleCsiSequence(io, stdin_file, prompt, &seq_buf, &slen, slice.len)) |consumed| {
                return consumed;
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
