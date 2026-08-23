//! editor.zig — Line editor cho REPL (RFC-000 Phase 0).
//!
//! Đáp ứng các issue editor:
//!   - Buffer động `ArrayListUnmanaged(u8)` (input limit 64KB, reject thay vì truncate)
//!   - UTF-8 aware qua `unicode.zig`: cursor move theo grapheme cluster,
//!     redraw theo displayWidth (gõ tiếng Việt / emoji không lệch cursor)
//!   - Word motion: Alt+B/F di chuyển theo từ, Alt+D / Alt+Backspace xóa từ
//!   - Undo/Redo: Ctrl+Z / Ctrl+Y (ring 16 snapshot, cap 4KB/snapshot)
//!   - Kill ring: Ctrl+W cut từ trái, Ctrl+K cut tới cuối dòng, Ctrl+Y yank (ring 5)
//!   - Ctrl+A/E/U/L, Home/End, ↑/↓ history, bracketed paste
//!
//! Vẫn là single-line composer (multiline là Phase 1 — RFC-000).

const std = @import("std");
const Allocator = std.mem.Allocator;
const unicode = @import("unicode.zig");
const history_mod = @import("history.zig");
const paste_mod = @import("paste.zig");

/// Input limit (byte). Vượt → hiện lỗi, không nhận thêm.
pub const MAX_INPUT_BYTES = 64 * 1024;
/// Số snapshot undo/redo tối đa.
const UNDO_DEPTH = 16;
/// Kích thước tối đa mỗi snapshot (buffer lớn hơn → không undo).
const UNDO_SNAPSHOT_CAP = 4 * 1024;
/// Kill ring depth.
const KILL_RING_DEPTH = 5;

pub const LineEditor = struct {
    alloc: Allocator,
    /// Prompt input history persistent (JSONL).
    prompt_history: history_mod.PromptHistory,
    history_index: usize,
    /// Backup nội dung đang soạn khi đi lên history.
    draft: std.ArrayListUnmanaged(u8),

    // --- Buffer động ---
    buf: std.ArrayListUnmanaged(u8),
    /// Vị trí cursor (byte offset, luôn đứng ở biên grapheme).
    pos: usize,

    // --- Undo/Redo ---
    undo_stack: [UNDO_DEPTH][]u8,
    undo_pos_stack: [UNDO_DEPTH]usize,
    undo_len: usize,
    undo_head: usize, // index phần tử kế tiếp được ghi
    redo_stack: [UNDO_DEPTH][]u8,
    redo_pos_stack: [UNDO_DEPTH]usize,
    redo_len: usize,
    redo_head: usize,

    // --- Kill ring ---
    kill_ring: [KILL_RING_DEPTH][]u8,
    kill_len: usize,
    kill_head: usize,

    /// Hiển thị thông báo lỗi input-limit cho redraw kế tiếp.
    limit_msg: bool,

    /// Parser bracketed paste (state machine — xem paste.zig).
    paste_parser: paste_mod.Parser,
    /// Đang trong paste mode (giữa START và END marker).
    pasting: bool,
    /// Đã push undo cho đợt paste hiện tại (1 undo cho cả đợt).
    paste_undo_pushed: bool,
    /// Test-only: bỏ qua ghi stdout trong redraw (không có std.Io hợp lệ).
    suppress_redraw: bool,

    pub fn init(alloc: Allocator) LineEditor {
        return .{
            .alloc = alloc,
            .prompt_history = history_mod.PromptHistory.init(alloc),
            .history_index = 0,
            .draft = .empty,
            .buf = .empty,
            .pos = 0,
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
            .suppress_redraw = false,
        };
    }

    pub fn deinit(self: *LineEditor) void {
        self.prompt_history.deinit();
        self.draft.deinit(self.alloc);
        self.buf.deinit(self.alloc);
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
            // Ring đầy: ghi đè cũ nhất (undo_head luôn trỏ slot kế tiếp).
            self.alloc.free(self.undo_stack[self.undo_head]);
        } else {
            self.undo_len += 1;
        }
        self.undo_stack[self.undo_head] = snap;
        self.undo_pos_stack[self.undo_head] = self.pos;
        self.undo_head = (self.undo_head + 1) % UNDO_DEPTH;
        // Mutation mới vô hiệu redo.
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
        // Lưu trạng thái hiện tại vào undo để undo lần nữa quay lại.
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

    /// Số byte của grapheme cluster bắt đầu tại byte `i`.
    fn clusterLenAt(self: *LineEditor, i: usize) usize {
        return unicode.clusterLenAt(self.buf.items, i);
    }

    /// Kích thước grapheme cluster đứng TRƯỚC byte `i`.
    fn clusterLenBefore(self: *LineEditor, i: usize) usize {
        if (i == 0) return 0;
        var j = i - 1;
        // Lùi qua các continuation byte (10xxxxxx) để tìm byte đầu cluster.
        while (j > 0 and (self.buf.items[j] & 0xC0) == 0x80) j -= 1;
        // Lùi tiếp qua combining marks / ZWJ nối với cluster trước đó.
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

    /// Xóa range [start, end). Trả về text đã xóa (caller free) hoặc null.
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

    /// Vị trí bắt đầu từ phía trái cursor (space-punct-word theo unicode.CharClass).
    fn wordLeft(self: *LineEditor) usize {
        var i = self.pos;
        // Bỏ qua space về trái.
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
        // Ăn theo class của ký tự tại vị trí mới.
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

    /// Vị trí kết thúc từ phía phải cursor.
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

        // Lưu draft khi rời vị trí cuối.
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
    // Render
    // -----------------------------------------------------------------------

    fn redraw(self: *LineEditor, io: std.Io, prompt: []const u8) void {
        if (self.suppress_redraw) return;
        var out_buf: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&out_buf);

        w.writeAll("\x1b[2K\r") catch return;
        if (self.limit_msg) {
            w.writeAll("\x1b[33m[input limit 64KB — từ chối]\x1b[0m\r\n\x1b[2K\r") catch return;
        }
        w.writeAll(prompt) catch return;
        w.writeAll(self.buf.items) catch return;

        // Di chuyển cursor về đúng vị trí theo displayWidth.
        const after_width = unicode.displayWidth(self.buf.items[self.pos..]);
        if (after_width > 0) {
            w.print("\x1b[{d}D", .{after_width}) catch return;
        }

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
        raw.lflag.ISIG = true;
        // Tắt(input) CR/NL translation: paste CRLF phải đến nguyên vẹn
        // (\r\n → 1 space khi sanitize), Enter đến như '\r' (13).
        raw.iflag.ICRNL = false;
        raw.iflag.INLCR = false;
        raw.iflag.IGNCR = false;
        raw.iflag.IXON = false; // Ctrl+S/Q đến editor, không bị kernel bắt
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;

        try std.posix.tcsetattr(stdin_fd, .FLUSH, raw);
        defer {
            stdout_file.writeStreamingAll(io, "\x1b[?2004l") catch {};
            std.posix.tcsetattr(stdin_fd, .FLUSH, orig_termios) catch {};
        }

        // Bracketed paste mode.
        stdout_file.writeStreamingAll(io, "\x1b[?2004h") catch {};

        self.buf.clearRetainingCapacity();
        self.pos = 0;
        self.limit_msg = false;
        self.history_index = self.prompt_history.entries.items.len;
        self.draft.clearRetainingCapacity();

        self.redraw(io, prompt);

        while (true) {
            var char_buf: [1]u8 = undefined;
            const n = try stdin_file.readStreaming(io, &.{&char_buf});
            if (n == 0) return null;
            const c = char_buf[0];

            // Đang trong paste mode: mọi byte đi qua paste parser cho tới khi
            // gặp END marker hoặc idle-timeout (terminal không gửi marker).
            if (self.pasting) {
                self.pasteFeed(io, stdin_file, prompt, c);
                continue;
            }

            switch (c) {
                3, 4 => return null, // Ctrl+C / Ctrl+D
                13, 10 => { // Enter → submit
                    stdout_file.writeStreamingAll(io, "\r\n") catch {};
                    return try self.alloc.dupe(u8, self.buf.items);
                },                12 => { // Ctrl+L redraw
                    stdout_file.writeStreamingAll(io, "\x1b[2J\x1b[H") catch {};
                    self.redraw(io, prompt);
                },
                127, 8 => { // Backspace (grapheme)
                    if (self.pos > 0) {
                        self.pushUndo();
                        const start = self.pos - self.clusterLenBefore(self.pos);
                        if (self.deleteRange(start, self.pos)) |rem| self.alloc.free(rem);
                        self.redraw(io, prompt);
                    }
                },
                1 => { // Ctrl+A
                    self.pos = 0;
                    self.redraw(io, prompt);
                },
                5 => { // Ctrl+E
                    self.pos = self.buf.items.len;
                    self.redraw(io, prompt);
                },
                21 => { // Ctrl+U — xóa tới đầu dòng
                    if (self.pos > 0) {
                        self.pushUndo();
                        if (self.deleteRange(0, self.pos)) |rem| self.alloc.free(rem);
                        self.redraw(io, prompt);
                    }
                },
                23 => { // Ctrl+W — kill word trái
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
                11 => { // Ctrl+K — kill tới cuối dòng
                    if (self.pos < self.buf.items.len) {
                        self.pushUndo();
                        if (self.deleteRange(self.pos, self.buf.items.len)) |rem| {
                            self.killPush(rem);
                            self.alloc.free(rem);
                        }
                        self.redraw(io, prompt);
                    }
                },
                25 => { // Ctrl+Y — yank kill ring
                    if (self.killTop()) |text| {
                        self.pushUndo();
                        if (self.insertBytes(text)) {
                            self.redraw(io, prompt);
                        }
                    }
                },
                26 => { // Ctrl+Z — undo
                    if (self.applyUndo()) self.redraw(io, prompt);
                },
                19 => { // Ctrl+S thường bị terminal bắt — không dùng. Ctrl+Y đã là redo chuẩn readline? Không: Ctrl+_ (31) là readline undo. Thêm:
                    self.redraw(io, prompt);
                },
                31 => { // Ctrl+_ — redo (alias Ctrl+Y)
                    if (self.applyRedo()) self.redraw(io, prompt);
                },
                27 => { // ESC — escape sequence
                    self.handleEscape(io, stdin_file, prompt);
                },
                else => {
                    if (char_buf[0] >= 32) {
                        // UTF-8 continuation bytes có thể đến sau — đọc nốt multibyte.
                        const seq_len = unicode.utf8Len(char_buf[0]);
                        var bytes: [4]u8 = undefined;
                        bytes[0] = char_buf[0];
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
                            // insert bị reject (limit) — hoàn tác undo snapshot vừa push.
                            if (self.popUndo()) |entry| self.alloc.free(entry.snap);
                            self.redraw(io, prompt);
                        }
                    }
                },
            }
        }
    }

    /// Xử lý escape sequence: mũi tên, Alt+key, Home/End, Delete, bracketed paste.
    fn handleEscape(self: *LineEditor, io: std.Io, stdin_file: std.Io.File, prompt: []const u8) void {
        var seq: [2]u8 = undefined;
        if ((stdin_file.readStreaming(io, &.{seq[0..1]}) catch 0) == 0) return;
        if ((stdin_file.readStreaming(io, &.{seq[1..2]}) catch 0) == 0) return;

        if (seq[0] == '[') {
            switch (seq[1]) {
                'A' => { // ↑ history
                    self.loadHistoryEntry(-1);
                    self.redraw(io, prompt);
                },
                'B' => { // ↓ history
                    self.loadHistoryEntry(1);
                    self.redraw(io, prompt);
                },
                'C' => { // →
                    self.moveRight();
                    self.redraw(io, prompt);
                },
                'D' => { // ←
                    self.moveLeft();
                    self.redraw(io, prompt);
                },
                'H' => { // Home
                    self.pos = 0;
                    self.redraw(io, prompt);
                },
                'F' => { // End
                    self.pos = self.buf.items.len;
                    self.redraw(io, prompt);
                },
                '1' => { // ESC [ 1 ~ hoặc ESC [ 1 ; 3 C (Alt+→) — đọc tới '~' hoặc chữ
                    self.consumeTildeOrModifier(io, stdin_file, prompt);
                },
                '2' => { // Bracketed paste bắt đầu: ESC [ 2 0 0 ~
                    var marker: [3]u8 = undefined;
                    var got: usize = 0;
                    while (got < 3) : (got += 1) {
                        if ((stdin_file.readStreaming(io, &.{marker[got .. got + 1]}) catch 0) == 0) break;
                    }
                    if (got == 3 and std.mem.eql(u8, &marker, "00~")) {
                        self.beginPaste();
                    }
                },
                '3' => { // Delete
                    var tilde: [1]u8 = undefined;
                    _ = stdin_file.readStreaming(io, &.{&tilde}) catch 0;
                    if (tilde[0] == '~' and self.pos < self.buf.items.len) {
                        self.pushUndo();
                        const end = self.pos + self.clusterLenAt(self.pos);
                        if (self.deleteRange(self.pos, end)) |rem| self.alloc.free(rem);
                        self.redraw(io, prompt);
                    }
                },
                else => {},
            }
        } else if (seq[0] == 'O') {
            switch (seq[1]) {
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
        } else {
            // Alt+<key>: ESC theo sau bởi key thường.
            switch (seq[1]) {
                'b', 'B' => { // Alt+B — word left
                    self.pos = self.wordLeft();
                    self.redraw(io, prompt);
                },
                'f', 'F' => { // Alt+F — word right
                    self.pos = self.wordRight();
                    self.redraw(io, prompt);
                },
                'd', 'D' => { // Alt+D — delete word phải
                    const end = self.wordRight();
                    if (end > self.pos) {
                        self.pushUndo();
                        if (self.deleteRange(self.pos, end)) |rem| self.alloc.free(rem);
                        self.redraw(io, prompt);
                    }
                },
                127, 8 => { // Alt+Backspace — delete word trái
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
    }

    /// ESC [ 1 ... — đọc nốt tới '~' (Home variant) hoặc ';<mod><key>' (modifier combo).
    fn consumeTildeOrModifier(self: *LineEditor, io: std.Io, stdin_file: std.Io.File, prompt: []const u8) void {
        var extra: [8]u8 = undefined;
        var got: usize = 0;
        while (got < extra.len) : (got += 1) {
            if ((stdin_file.readStreaming(io, &.{extra[got .. got + 1]}) catch 0) == 0) return;
            const c = extra[got];
            if (c == '~') {
                // ESC [ 1 ~ = Home
                self.pos = 0;
                self.redraw(io, prompt);
                return;
            }
            if (c == ';') {
                // ESC [ 1 ; 3 <C|D> — Alt+→ / Alt+←
                var modkey: [2]u8 = undefined;
                var k: usize = 0;
                while (k < 2) : (k += 1) {
                    if ((stdin_file.readStreaming(io, &.{modkey[k .. k + 1]}) catch 0) == 0) return;
                }
                // modkey[0] = modifier digit, modkey[1] = key
                switch (modkey[1]) {
                    'C' => { // Alt+→ word right
                        self.pos = self.wordRight();
                        self.redraw(io, prompt);
                    },
                    'D' => { // Alt+← word left
                        self.pos = self.wordLeft();
                        self.redraw(io, prompt);
                    },
                    else => {},
                }
                return;
            }
            if (!std.ascii.isDigit(c)) return;
        }
    }

    /// Bắt đầu paste mode (đã nhận START marker).
    fn beginPaste(self: *LineEditor) void {
        self.pasting = true;
        self.paste_undo_pushed = false;
        self.paste_parser.reset();
        paste_mod.sanitizeReset();
    }

    /// Kết thúc paste mode: flush nốt candidate còn hold thành content.
    fn endPaste(self: *LineEditor, io: std.Io, prompt: []const u8) void {
        self.pasting = false;
        self.paste_undo_pushed = false;
        var tmp: [paste_mod.END_MARKER.len]u8 = undefined;
        const pre = self.paste_parser.pendingCopy(&tmp);
        self.insertPastedSanitized(io, prompt, pre);
        self.paste_parser.reset();
    }

    /// Feed 1 byte trong paste mode qua state machine (xem paste.zig).
    /// END marker hoặc idle-timeout sẽ thoát paste mode.
    fn pasteFeed(self: *LineEditor, io: std.Io, stdin_file: std.Io.File, prompt: []const u8, c: u8) void {
        // Copy pending TRƯỚC khi feed (feed có thể reset state).
        var tmp: [paste_mod.END_MARKER.len]u8 = undefined;
        const pre = self.paste_parser.pendingCopy(&tmp);

        switch (self.paste_parser.feed(c)) {
            .content => |b| {
                var one = [1]u8{b};
                self.insertPastedSanitized(io, prompt, &one);
                // Content vừa xử lý xong mà stdin im → terminal đã gửi hết
                // (quên end-marker) → thoát paste mode để Enter không bị nuốt.
                // Khi paste vẫn đang đổ, poll thấy byte kế ngay → không tốn chờ.
                if (self.pasteIdleTimedOut(io, stdin_file)) {
                    self.endPaste(io, prompt);
                    self.redraw(io, prompt);
                }
            },
            .marker => |m| {
                if (m == .end) {
                    self.endPaste(io, prompt);
                    self.redraw(io, prompt);
                }
                // .start trong khi pasting: marker lồng nhau (hiếm) — bỏ qua.
            },
            .none => {
                // Byte đang hold. Nếu hold kéo dài mà không có byte kế
                // (terminal gửi marker bị tách / không gửi end-marker) →
                // idle-timeout thoát paste mode, không kẹt vĩnh viễn.
                if (self.pasteIdleTimedOut(io, stdin_file)) {
                    // Không còn byte: flush hold + kết thúc.
                    self.endPaste(io, prompt);
                    self.redraw(io, prompt);
                }
            },
            .fail => {
                // Hold vỡ: flush hold thành content rồi xử lý lại byte hiện tại.
                self.insertPastedSanitized(io, prompt, pre);
                switch (self.paste_parser.feed(c)) {
                    .content => |b| {
                        var one = [1]u8{b};
                        self.insertPastedSanitized(io, prompt, &one);
                    },
                    .none => {
                        if (self.pasteIdleTimedOut(io, stdin_file)) {
                            self.endPaste(io, prompt);
                            self.redraw(io, prompt);
                        }
                    },
                    else => unreachable,
                }
            },
        }
    }

    /// Trong paste mode: poll stdin 150ms — hết thời gian mà không có byte
    /// coi như terminal sẽ không gửi END marker → caller tự thoát paste mode.
    /// Trả về true nếu idle (không byte nào tới).
    fn pasteIdleTimedOut(_: *LineEditor, _: std.Io, _: std.Io.File) bool {
        var fds = [_]std.posix.pollfd{.{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, 150) catch return true; // lỗi poll → coi như idle
        return ready == 0;
    }

    /// Sanitize (newline→space, bỏ control) rồi insert vào buffer + redraw.
    /// Push undo 1 lần cho cả đợt paste (không phải per-byte).
    fn insertPastedSanitized(self: *LineEditor, io: std.Io, prompt: []const u8, bytes: []const u8) void {
        if (bytes.len == 0) return;
        if (!self.paste_undo_pushed) {
            self.pushUndo();
            self.paste_undo_pushed = true;
        }
        // Sanitize vào buffer tạm rồi insert một lệnh.
        var tmp_list: std.ArrayListUnmanaged(u8) = .empty;
        defer tmp_list.deinit(self.alloc);
        for (bytes) |b| _ = paste_mod.sanitizeAppend(&tmp_list, self.alloc, b);
        if (tmp_list.items.len > 0) {
            _ = self.insertBytes(tmp_list.items);
            self.redraw(io, prompt);
        }
    }

    /// Thêm vào prompt history (gọi khi submit).
    pub fn addHistory(self: *LineEditor, line: []const u8) !void {
        try self.prompt_history.add(line);
    }

    /// Load persistent history từ disk.
    pub fn loadHistoryFile(self: *LineEditor, io: std.Io, path: []const u8) !void {
        try self.prompt_history.loadFromFile(io, path);
    }

    /// Flush persistent history ra disk nếu dirty.
    pub fn saveHistoryFile(self: *LineEditor, io: std.Io, path: []const u8) !void {
        try self.prompt_history.saveToFile(io, path);
    }
};

// ---------------------------------------------------------------------------
// Tests — logic thuần không cần terminal
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

    e.pos = e.buf.items.len; // sau "foo"
    try std.testing.expectEqual(@as(usize, 12), e.wordLeft()); // trước "foo"
    e.pos = 12;
    try std.testing.expectEqual(@as(usize, 6), e.wordLeft()); // trước "world"
    e.pos = 6;
    try std.testing.expectEqual(@as(usize, 0), e.wordLeft()); // trước "hello"

    e.pos = 0;
    try std.testing.expectEqual(@as(usize, 5), e.wordRight()); // sau "hello"
    e.pos = 5;
    try std.testing.expectEqual(@as(usize, 11), e.wordRight()); // sau "world"
}

test "word motion qua punct" {
    const alloc = std.testing.allocator;
    var e = LineEditor.init(alloc);
    defer e.deinit();
    try e.buf.appendSlice(alloc, "foo.bar baz");
    e.pos = e.buf.items.len;
    try std.testing.expectEqual(@as(usize, 8), e.wordLeft()); // trước "baz"
    e.pos = 8;
    try std.testing.expectEqual(@as(usize, 4), e.wordLeft()); // trước "bar" ("." là cluster punct riêng)
    e.pos = 4;
    try std.testing.expectEqual(@as(usize, 3), e.wordLeft()); // trước "." ("foo" là 1 word)
}

test "word motion tiếng Việt" {
    const alloc = std.testing.allocator;
    var e = LineEditor.init(alloc);
    defer e.deinit();
    try e.buf.appendSlice(alloc, "tết đến rồi");
    e.pos = e.buf.items.len;
    const w1 = e.wordLeft(); // trước "rồi"
    try std.testing.expectEqualStrings("rồi", e.buf.items[w1..]);
    e.pos = w1;
    const w2 = e.wordLeft(); // trước "đến"
    try std.testing.expectEqualStrings("đến rồi", e.buf.items[w2..]);
}

test "undo redo cơ bản" {
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

test "kill ring push/yank và depth cap" {
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

test "insertBytes reject khi vượt limit" {
    const alloc = std.testing.allocator;
    var e = LineEditor.init(alloc);
    defer e.deinit();
    try e.buf.appendSlice(alloc, "a" ** (MAX_INPUT_BYTES - 2));
    e.pos = e.buf.items.len;
    try std.testing.expect(!e.insertBytes("xyz"));
    try std.testing.expect(e.limit_msg);
    try std.testing.expect(e.insertBytes("ab")); // vừa đủ
}

test "deleteRange cập nhật pos đúng" {
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

test "clusterLenBefore với emoji và tiếng Việt" {
    const alloc = std.testing.allocator;
    var e = LineEditor.init(alloc);
    defer e.deinit();
    // "a" + "ế" (3 bytes) + 👍 (4 bytes)
    try e.buf.appendSlice(alloc, "a\u{1EBF}\u{1F44D}");
    e.pos = e.buf.items.len;
    e.moveLeft(); // qua 👍 (4 bytes)
    try std.testing.expectEqual(@as(usize, 4), e.pos);
    e.moveLeft(); // qua ế (3 bytes)
    try std.testing.expectEqual(@as(usize, 1), e.pos);
    e.moveLeft(); // qua a
    try std.testing.expectEqual(@as(usize, 0), e.pos);
}

// ---------------------------------------------------------------------------
// Paste mode — tái hiện & fix bug kẹt paste (xem paste.zig)
// ---------------------------------------------------------------------------

/// Mô phỏng feed 1 stream bytes vào editor đang trong paste mode.
/// Trả về buffer sau khi stream kết thúc (không có timeout — dùng parser trực tiếp).
fn simulatePaste(alloc: Allocator, input: []const u8) ![]u8 {
    var e = LineEditor.init(alloc);
    defer e.deinit();
    e.suppress_redraw = true;
    e.beginPaste();
    var tmp: [paste_mod.END_MARKER.len]u8 = undefined;
    var done = false;
    for (input) |c| {
        if (done) break;
        const pre = e.paste_parser.pendingCopy(&tmp);
        switch (e.paste_parser.feed(c)) {
            .content => |b| {
                var one = [1]u8{b};
                e.insertPastedSanitized(undefined, "", &one);
            },
            .marker => |m| {
                if (m == .end) {
                    e.endPaste(undefined, "");
                    done = true;
                }
            },
            .fail => {
                e.insertPastedSanitized(undefined, "", pre);
                switch (e.paste_parser.feed(c)) {
                    .content => |b| {
                        var one = [1]u8{b};
                        e.insertPastedSanitized(undefined, "", &one);
                    },
                    .none => {},
                    else => unreachable,
                }
            },
            .none => {},
        }
    }
    return alloc.dupe(u8, e.buf.items);
}

test "paste thường: content nằm giữa start/end marker" {
    const alloc = std.testing.allocator;
    const out = try simulatePaste(alloc, paste_mod.START_MARKER ++ "hello pasted" ++ paste_mod.END_MARKER);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("hello pasted", out);
}

test "paste multiline: mỗi newline thành 1 space (CRLF không double)" {
    const alloc = std.testing.allocator;
    const out = try simulatePaste(alloc, paste_mod.START_MARKER ++ "line1\r\nline2\nline3" ++ paste_mod.END_MARKER);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("line1 line2 line3", out);
}

test "paste chứa ANSI escape không nhầm end-marker" {
    const alloc = std.testing.allocator;
    // Nội dung có escape sequence gần giống marker + end-marker thật phía sau.
    const input = paste_mod.START_MARKER ++ "\x1b[31mred\x1b[0m end" ++ paste_mod.END_MARKER;
    const out = try simulatePaste(alloc, input);
    defer alloc.free(out);
    // Escape sequences bị strip control chars, chữ "red end" giữ lại.
    try std.testing.expectEqualStrings("[31mred[0m end", out);
}

test "paste chứa prefix gần end-marker vẫn nhận đúng marker thật" {
    const alloc = std.testing.allocator;
    const input = paste_mod.START_MARKER ++ "abc\x1b[20" ++ paste_mod.END_MARKER;
    const out = try simulatePaste(alloc, input);
    defer alloc.free(out);
    // "\x1b[20" là prefix chưa hoàn chỉnh → giữ làm content (đúng hành vi: nó
    // không phải marker), end-marker thật được nhận diện → không kẹt.
    try std.testing.expectEqualStrings("abc[20", out);
}

test "paste không có end-marker: flush pending, editor không kẹt" {
    const alloc = std.testing.allocator;
    var e = LineEditor.init(alloc);
    defer e.deinit();
    e.suppress_redraw = true;
    e.beginPaste();
    var tmp: [paste_mod.END_MARKER.len]u8 = undefined;
    // Terminal gửi content + prefix marker rồi im luôn (không end-marker).
    for (paste_mod.START_MARKER[0..] ++ "dangling\x1b[2") |c| {
        const pre = e.paste_parser.pendingCopy(&tmp);
        switch (e.paste_parser.feed(c)) {
            .content => |b| {
                var one = [1]u8{b};
                e.insertPastedSanitized(undefined, "", &one);
            },
            .marker => |m| {
                if (m == .end) e.endPaste(undefined, "");
            },
            .fail => {
                e.insertPastedSanitized(undefined, "", pre);
                switch (e.paste_parser.feed(c)) {
                    .content => |b| {
                        var one = [1]u8{b};
                        e.insertPastedSanitized(undefined, "", &one);
                    },
                    .none => {},
                    else => unreachable,
                }
            },
            .none => {},
        }
    }
    // Idle timeout path: gọi endPaste như editor sẽ làm.
    e.endPaste(undefined, "");
    try std.testing.expect(!e.pasting);
    // "dangling" + prefix "\x1b[2" (control strip) = "dangling[2".
    try std.testing.expectEqualStrings("dangling[2", e.buf.items);
}

test "paste UTF-8 tiếng Việt + emoji giữ nguyên" {
    const alloc = std.testing.allocator;
    const out = try simulatePaste(alloc, paste_mod.START_MARKER ++ "xin chào thế giới 👍" ++ paste_mod.END_MARKER);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("xin chào thế giới 👍", out);
}
