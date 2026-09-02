//! editor.zig — Line editor cho REPL (RFC-000 Phase 0).
//!
//! Đáp ứng các issue editor:
//!   - Buffer động `ArrayListUnmanaged(u8)` (input limit 64KB, reject thay vì truncate)
//!   - UTF-8 aware qua `unicode.zig`: cursor move theo grapheme cluster,
//!     redraw theo displayWidth và multiline wrapping (gõ tiếng Việt / emoji / paste dài không lặp prompt)
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
const term = @import("terminal.zig");
const utils = @import("../core/utils.zig");

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

    // --- Multiline / Wrapping redraw tracking ---
    rendered_rows: usize,
    cursor_row: usize,

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
    /// Buffer tích luỹ nội dung paste trước khi flush vào buffer chính.
    paste_buf: std.ArrayListUnmanaged(u8),
    /// Test-only: bỏ qua ghi stdout trong redraw (không có std.Io hợp lệ).
    suppress_redraw: bool,
    /// Timestamp lần nhấn Ctrl+C gần nhất (ms).
    last_ctrl_c_ms: i64,

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

    /// Chèn '\n' tại vị trí cursor (xuống dòng thủ công, RFC-008 §5B).
    fn insertNewlineAtCursor(self: *LineEditor, io: std.Io, prompt: []const u8) void {
        if (self.buf.items.len + 1 > MAX_INPUT_BYTES) {
            self.limit_msg = true;
            self.redraw(io, prompt);
            return;
        }
        self.pushUndo();
        _ = self.insertBytes("\n");
        self.redraw(io, prompt);
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
    // Render (Multiline Wrapping Aware)
    // -----------------------------------------------------------------------

    fn redraw(self: *LineEditor, io: std.Io, prompt: []const u8) void {
        if (self.suppress_redraw) return;
        var out_buf: [8192]u8 = undefined;
        var w = std.Io.Writer.fixed(&out_buf);

        // 1. Lùi cursor về dòng đầu tiên của prompt nếu lần render trước bị wrap xuống các dòng dưới
        if (self.cursor_row > 0) {
            w.print("\x1b[{d}A", .{self.cursor_row}) catch return;
        }
        // 2. Về đầu dòng và xóa toàn bộ vùng hiển thị từ cursor xuống dưới màn hình
        w.writeAll("\r\x1b[J") catch return;

        if (self.limit_msg) {
            w.writeAll("\x1b[33m[input limit 64KB — từ chối]\x1b[0m\r\n\x1b[J") catch return;
        }

        // 3. In prompt + buffer theo dòng logic: \n thật → \r\n + thụt lề
        //    bằng độ rộng prompt (raw mode: \n không tự về cột 0, phải dùng \r\n).
        const term_size = term.getTerminalSize();
        const cols: usize = if (term_size.cols > 0) term_size.cols else 80;

        const prompt_w = unicode.visibleWidth(prompt);
        var indent_buf: [64]u8 = undefined;
        const indent_len = @min(prompt_w, indent_buf.len);
        @memset(indent_buf[0..indent_len], ' ');
        const indent = indent_buf[0..indent_len];

        var total_rows: usize = 0; // số hàng thêm so với hàng đầu tiên
        var cur_row: usize = 0;
        var cur_col: usize = 0;
        var cursor_placed = false;

        var line_start: usize = 0;
        var line_idx: usize = 0;
        var k: usize = 0;
        while (k <= self.buf.items.len) : (k += 1) {
            const at_end = k == self.buf.items.len;
            if (!at_end and self.buf.items[k] != '\n') continue;

            // Dòng logic [line_start..k)
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

            // Cursor thuộc dòng này?
            if (!cursor_placed and self.pos <= k) {
                const in_w = unicode.displayWidth(self.buf.items[line_start..@min(self.pos, k)]);
                const coff = prefix_w + in_w;
                cur_row = total_rows + coff / cols;
                cur_col = coff % cols;
                cursor_placed = true;
            }

            // Hàng thêm: dòng đầu chỉ tính wrap, dòng sau tính cả lần xuống dòng
            if (line_idx == 0) {
                total_rows += lw / cols;
            } else {
                total_rows += 1 + lw / cols;
            }

            if (at_end) break;
            line_start = k + 1;
            line_idx += 1;
        }

        // 4. Di chuyển con trỏ terminal về (cur_row, cur_col)
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
        raw.lflag.ISIG = false; // Nhận byte Ctrl+C (0x03) trực tiếp để editor xử lý hủy dòng / thoát 2 lần
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
        self.rendered_rows = 0;
        self.cursor_row = 0;
        self.limit_msg = false;
        self.history_index = self.prompt_history.entries.items.len;
        self.draft.clearRetainingCapacity();

        self.redraw(io, prompt);

        while (true) {
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

            // Đang trong paste mode: đưa toàn bộ chunk vào paste parser.
            // pasteFeed trả về offset ngay SAU END marker nếu paste kết thúc
            // GIỮA chunk — phần còn lại phải xử lý tiếp như input thường
            // (RCA-001: mất bytes sau END marker).
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
                // START marker vừa hoàn tất TRONG chunk này (case 27 gọi
                // beginPaste): phần còn lại là NỘI DUNG paste, tuyệt đối không
                // đi qua đường thường — byte '\r' sẽ rơi vào case 13 và submit
                // nhầm giữa chừng (root cause paste multi-line bị cắt).
                if (self.pasting) {
                    const consumed = self.pasteFeed(io, prompt, read_buf[i..n]);
                    if (!self.pasting) {
                        i += consumed; // END marker giữa chunk → xử lý nốt phần sau
                        continue;
                    }
                    if (self.pasteIdleTimedOut(io, stdin_file)) {
                        self.endPaste(io, prompt);
                    }
                    break; // vẫn pasting → về vòng read chính
                }
                const c = read_buf[i];
                if (c != 3) {
                    self.last_ctrl_c_ms = 0;
                }
                switch (c) {
                    3 => { // Ctrl+C: Hủy dòng đang nhập hoặc thoát REPL nếu nhấn 2 lần liên tiếp
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
                    4 => { // Ctrl+D: EOF khi buffer rỗng → thoát REPL
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
                    13 => { // Enter → submit (toàn bộ buffer, kể cả multiline)
                        if (self.rendered_rows > self.cursor_row) {
                            var move_down_buf: [32]u8 = undefined;
                            const seq = std.fmt.bufPrint(&move_down_buf, "\x1b[{d}B", .{self.rendered_rows - self.cursor_row}) catch "";
                            stdout_file.writeStreamingAll(io, seq) catch {};
                        }
                        stdout_file.writeStreamingAll(io, "\r\n") catch {};
                        return try self.alloc.dupe(u8, self.buf.items);
                    },
                    10 => { // Ctrl+J → chèn newline thủ công (RFC-008 §5B)
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
                    21 => { // Ctrl+U — xóa tới đầu dòng
                        if (self.pos > 0) {
                            self.pushUndo();
                            if (self.deleteRange(0, self.pos)) |rem| self.alloc.free(rem);
                            self.redraw(io, prompt);
                        }
                        i += 1;
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
                        i += 1;
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
                                // Batch insert cho text nhanh / dán ngoài paste mode
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

    /// Xử lý escape sequence: mũi tên, Alt+key, Home/End, Delete, bracketed paste.
    fn handleEscapeSlice(self: *LineEditor, io: std.Io, stdin_file: std.Io.File, prompt: []const u8, slice: []const u8) usize {
        var seq_buf: [8]u8 = undefined;
        var seq_len: usize = 0;

        const copy_len = @min(slice.len, seq_buf.len);
        @memcpy(seq_buf[0..copy_len], slice[0..copy_len]);
        seq_len = copy_len;

        if (seq_len < 3) {
            while (seq_len < 3) {
                var b: [1]u8 = undefined;
                if ((stdin_file.readStreaming(io, &.{&b}) catch 0) == 0) break;
                seq_buf[seq_len] = b[0];
                seq_len += 1;
            }
        }

        if (seq_len >= 3 and seq_buf[0] == 0x1b and seq_buf[1] == '[') {
            switch (seq_buf[2]) {
                'A' => { // ↑ history
                    self.loadHistoryEntry(-1);
                    self.redraw(io, prompt);
                    return @min(3, slice.len);
                },
                'B' => { // ↓ history
                    self.loadHistoryEntry(1);
                    self.redraw(io, prompt);
                    return @min(3, slice.len);
                },
                'C' => { // →
                    self.moveRight();
                    self.redraw(io, prompt);
                    return @min(3, slice.len);
                },
                'D' => { // ←
                    self.moveLeft();
                    self.redraw(io, prompt);
                    return @min(3, slice.len);
                },
                'H' => { // Home
                    self.pos = 0;
                    self.redraw(io, prompt);
                    return @min(3, slice.len);
                },
                'F' => { // End
                    self.pos = self.buf.items.len;
                    self.redraw(io, prompt);
                    return @min(3, slice.len);
                },
                '1' => { // ESC [ 1 ~ hoặc ESC [ 1 ; 3 C (Alt+→)
                    if (seq_len >= 4 and seq_buf[3] == '~') {
                        self.pos = 0;
                        self.redraw(io, prompt);
                        return @min(4, slice.len);
                    }
                    if (seq_len >= 6 and seq_buf[3] == ';' and seq_buf[4] == '3') {
                        if (seq_buf[5] == 'C') {
                            self.pos = self.wordRight();
                            self.redraw(io, prompt);
                        } else if (seq_buf[5] == 'D') {
                            self.pos = self.wordLeft();
                            self.redraw(io, prompt);
                        }
                        return @min(6, slice.len);
                    }
                    self.consumeTildeOrModifier(io, stdin_file, prompt);
                    return @min(3, slice.len);
                },
                '2' => { // Bracketed paste bắt đầu: ESC [ 2 0 0 ~
                    if (seq_len >= 6 and std.mem.eql(u8, seq_buf[0..6], "\x1b[200~")) {
                        self.beginPaste();
                        return @min(6, slice.len);
                    }
                    var marker: [3]u8 = undefined;
                    var got: usize = 0;
                    while (got < 3) : (got += 1) {
                        if ((stdin_file.readStreaming(io, &.{marker[got .. got + 1]}) catch 0) == 0) break;
                    }
                    if (got == 3 and std.mem.eql(u8, &marker, "00~")) {
                        self.beginPaste();
                    }
                    return @min(3, slice.len);
                },
                '3' => { // Delete
                    if (seq_len >= 4 and seq_buf[3] == '~') {
                        if (self.pos < self.buf.items.len) {
                            self.pushUndo();
                            const end = self.pos + self.clusterLenAt(self.pos);
                            if (self.deleteRange(self.pos, end)) |rem| self.alloc.free(rem);
                            self.redraw(io, prompt);
                        }
                        return @min(4, slice.len);
                    }
                    var tilde: [1]u8 = undefined;
                    _ = stdin_file.readStreaming(io, &.{&tilde}) catch 0;
                    if (tilde[0] == '~' and self.pos < self.buf.items.len) {
                        self.pushUndo();
                        const end = self.pos + self.clusterLenAt(self.pos);
                        if (self.deleteRange(self.pos, end)) |rem| self.alloc.free(rem);
                        self.redraw(io, prompt);
                    }
                    return @min(3, slice.len);
                },
                else => {},
            }
        } else if (seq_len >= 3 and seq_buf[0] == 0x1b and seq_buf[1] == 'O') {
            switch (seq_buf[2]) {
                'H' => {
                    self.pos = 0;
                    self.redraw(io, prompt);
                    return @min(3, slice.len);
                },
                'F' => {
                    self.pos = self.buf.items.len;
                    self.redraw(io, prompt);
                    return @min(3, slice.len);
                },
                else => {},
            }
        } else if (seq_len >= 2 and seq_buf[0] == 0x1b) {
            switch (seq_buf[1]) {
                'b', 'B' => {
                    self.pos = self.wordLeft();
                    self.redraw(io, prompt);
                    return @min(2, slice.len);
                },
                'f', 'F' => {
                    self.pos = self.wordRight();
                    self.redraw(io, prompt);
                    return @min(2, slice.len);
                },
                'd', 'D' => {
                    const end = self.wordRight();
                    if (end > self.pos) {
                        self.pushUndo();
                        if (self.deleteRange(self.pos, end)) |rem| self.alloc.free(rem);
                        self.redraw(io, prompt);
                    }
                    return @min(2, slice.len);
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
                    return @min(2, slice.len);
                },
                else => {},
            }
        }

        return @max(1, @min(seq_len, slice.len));
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
                switch (modkey[1]) {
                    'C' => {
                        self.pos = self.wordRight();
                        self.redraw(io, prompt);
                    },
                    'D' => {
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
        self.paste_buf.clearRetainingCapacity();
        self.paste_parser.reset();
        paste_mod.sanitizeReset();
        paste_mod.sanitizeMultilineReset();
    }

    /// Kết thúc paste mode: flush nốt candidate còn hold thành content và chèn vào buffer.
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

    /// Feed các bytes trong paste mode qua state machine (xem paste.zig).
    /// Trả về offset trong `bytes` NGAY SAU END marker nếu paste kết thúc giữa
    /// chunk; trả về `bytes.len` nếu hết chunk mà vẫn đang pasting.
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
                        // RCA-001: trả về offset byte SAU end-marker. Caller
                        // dùng để xử lý tiếp phần còn lại của chunk như input
                        // thường (bytes sau END marker không được nuốt).
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

    /// Trong paste mode: poll stdin 100ms — hết thời gian mà không có byte
    /// coi như terminal sẽ không gửi END marker → caller tự thoát paste mode.
    /// (100ms: đủ rộng cho paste lớn qua SSH/mạng lag, nhỏ hơn TTL luồng
    /// dummy byte của render khi tab qua lại nên không gây redraw dính — RCA-001.)
    fn pasteIdleTimedOut(_: *LineEditor, _: std.Io, _: std.Io.File) bool {
        var fds = [_]std.posix.pollfd{.{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, 100) catch return true;
        return ready == 0;
    }

    /// Sanitize (newline→space, bỏ control) rồi insert vào buffer + redraw.
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
    _ = e.pasteFeed(undefined, "", input);
    if (e.pasting) e.endPaste(undefined, "");
    return alloc.dupe(u8, e.buf.items);
}

test "paste thường: content nằm giữa start/end marker" {
    const alloc = std.testing.allocator;
    const out = try simulatePaste(alloc, "hello pasted" ++ paste_mod.END_MARKER);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("hello pasted", out);
}

test "paste multiline: giữ nguyên newline (RFC-008 §5A)" {
    const alloc = std.testing.allocator;
    const out = try simulatePaste(alloc, "line1\r\nline2\nline3" ++ paste_mod.END_MARKER);
    defer alloc.free(out);
    // CRLF → 1 \n (không double), \n đơn giữ nguyên.
    try std.testing.expectEqualStrings("line1\nline2\nline3", out);
}

test "paste multiline giữ indent (tab + space)" {
    const alloc = std.testing.allocator;
    const out = try simulatePaste(alloc, "fn x() {\n\treturn 1;\n}" ++ paste_mod.END_MARKER);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("fn x() {\n\treturn 1;\n}", out);
}

test "insertNewlineAtCursor: chèn \\n giữa buffer, pos đúng" {
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

test "paste chứa ANSI escape không nhầm end-marker" {
    const alloc = std.testing.allocator;
    const input = "\x1b[31mred\x1b[0m end" ++ paste_mod.END_MARKER;
    const out = try simulatePaste(alloc, input);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("[31mred[0m end", out);
}

test "paste chứa prefix gần end-marker vẫn nhận đúng marker thật" {
    const alloc = std.testing.allocator;
    const input = "abc\x1b[20" ++ paste_mod.END_MARKER;
    const out = try simulatePaste(alloc, input);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("abc[20", out);
}

test "paste không có end-marker: flush pending, editor không kẹt" {
    const alloc = std.testing.allocator;
    var e = LineEditor.init(alloc);
    defer e.deinit();
    e.suppress_redraw = true;
    e.beginPaste();
    const consumed = e.pasteFeed(undefined, "", "dangling\x1b[2");
    _ = consumed;
    // Idle timeout path: gọi endPaste như editor sẽ làm.
    e.endPaste(undefined, "");
    try std.testing.expect(!e.pasting);
    try std.testing.expectEqualStrings("dangling[2", e.buf.items);
}

test "paste UTF-8 tiếng Việt + emoji giữ nguyên" {
    const alloc = std.testing.allocator;
    const out = try simulatePaste(alloc, "xin chào thế giới 👍" ++ paste_mod.END_MARKER);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("xin chào thế giới 👍", out);
}

test "paste đoạn dài không bị lặp redraw hay tràn dòng" {
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

// RCA-001: START marker nằm GIỮA chunk — phần sau marker là nội dung paste,
// không được đi qua đường thường (Enter nhầm → submit giữa chừng).
test "paste bắt đầu giữa chunk: phần sau START marker vào paste mode" {
    const alloc = std.testing.allocator;
    var e = LineEditor.init(alloc);
    defer e.deinit();
    e.suppress_redraw = true;

    // Mô phỏng main loop nhận 1 chunk: prompt-echo + Enter + START + "l1\r\nl2"
    const chunk = "abc\r\x1b[200~l1\r\nl2";
    // Đi qua đường thường tới khi gặp ESC[200~: mô phỏng bằng cách tự feed
    // phần đầu như main loop (3 ký tự + Enter), sau đó phần còn lại chunk.
    for ("abc") |ch| _ = e.insertBytes(&.{ch});
    e.pos = e.buf.items.len;
    _ = e.handleEscapeSlice(undefined, undefined, "", chunk[4..]);
    try std.testing.expect(e.pasting); // START marker đã bật paste mode

    // Phần còn lại của chunk ("l1\r\nl2") PHẢI được pasteFeed xử lý:
    const consumed = e.pasteFeed(undefined, "", chunk[10..]);
    try std.testing.expectEqual(@as(usize, chunk.len - 10), consumed);
    e.endPaste(undefined, "");
    try std.testing.expectEqualStrings("abcl1\nl2", e.buf.items);
}

// RCA-001: END marker nằm giữa chunk — bytes sau marker là input thường
// (Enter ngay sau paste → submit, không bị nuốt).
test "paste kết thúc giữa chunk: bytes sau END marker không bị nuốt" {
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
    // "xyz" (offset trả về) phải còn lại để caller xử lý như input thường.
}
