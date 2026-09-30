//! terminal.zig — ANSI Escape Codes, Colors, Box Drawing & Terminal Primitives for mini-agent (RFC-007).
//!
//! Provides constants and utilities for terminal control, syntax coloring,
//! box drawing, and cursor management according to ANSI standards.

const std = @import("std");
const builtin = @import("builtin");
const main = @import("../main.zig");

// ---------------------------------------------------------------------------
// ANSI Styles & Colors
// ---------------------------------------------------------------------------

pub const RESET = "\x1b[0m";
pub const BOLD = "\x1b[1m";
pub const DIM = "\x1b[2m";
pub const ITALIC = "\x1b[3m";
pub const UNDERLINE = "\x1b[4m";
pub const INVERSE = "\x1b[7m";

// Standard Colors
pub const FG_BLACK = "\x1b[30m";
pub const FG_RED = "\x1b[31m";
pub const FG_GREEN = "\x1b[32m";
pub const FG_YELLOW = "\x1b[33m";
pub const FG_BLUE = "\x1b[34m";
pub const FG_MAGENTA = "\x1b[35m";
pub const FG_CYAN = "\x1b[36m";
pub const FG_WHITE = "\x1b[37m";

// Bright Colors
pub const FG_BRIGHT_BLACK = "\x1b[90m"; // Gray
pub const FG_BRIGHT_RED = "\x1b[91m";
pub const FG_BRIGHT_GREEN = "\x1b[92m";
pub const FG_BRIGHT_YELLOW = "\x1b[93m";
pub const FG_BRIGHT_BLUE = "\x1b[94m";
pub const FG_BRIGHT_MAGENTA = "\x1b[95m";
pub const FG_BRIGHT_CYAN = "\x1b[96m";
pub const FG_BRIGHT_WHITE = "\x1b[97m";

// Background Colors
pub const BG_BLACK = "\x1b[40m";
pub const BG_RED = "\x1b[41m";
pub const BG_GREEN = "\x1b[42m";
pub const BG_YELLOW = "\x1b[43m";
pub const BG_BLUE = "\x1b[44m";
pub const BG_MAGENTA = "\x1b[45m";
pub const BG_CYAN = "\x1b[46m";
pub const BG_WHITE = "\x1b[47m";
pub const BG_GRAY = "\x1b[48;5;236m";

// ---------------------------------------------------------------------------
// UTF-8 Box Drawing & Symbols
// ---------------------------------------------------------------------------

pub const BOX_TOP_LEFT = "╭";
pub const BOX_TOP_RIGHT = "╮";
pub const BOX_BOT_LEFT = "╰";
pub const BOX_BOT_RIGHT = "╯";
pub const BOX_HORIZ = "─";
pub const BOX_VERT = "│";
pub const BOX_T_RIGHT = "├";
pub const BOX_T_LEFT = "┤";

pub const GLYPH_PROMPT = "❯";
pub const GLYPH_ACTION = "⚡";
pub const GLYPH_CHECK = "✓";
pub const GLYPH_CROSS = "✗";
pub const GLYPH_THINK = "💭";
pub const GLYPH_STATS = "📊";
pub const GLYPH_BOT = "💩";
pub const GLYPH_BULLET = "•";

// ---------------------------------------------------------------------------
// Output helpers
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Terminal writer queue
//
// // PSEUDOCODE:
// // 1. A single background writer thread drains a FIFO of byte items (global
// //    `g_queue`, guarded by `g_queue_mu`) and writes them to stdout in order.
// // 2. Producers (renderer, spinner, editor, watchdog notices) call
// //    writeStdout / writeAllStdout, which only copy bytes onto the queue.
// //    FIFO ordering makes multi-write "in-place" sections atomic: no other
// //    producer can slip writes between the section's items.
// // 3. startWriter() spawns the thread; stopWriter() drains the remainder and
// //    joins. When the queue is not active (non-TTY, tests, ACP pipe mode),
// //    writes fall back to the previous direct synchronous stdout write.
// ---------------------------------------------------------------------------

const page_alloc = std.heap.page_allocator;

/// FIFO byte-item queue drained by the background writer thread.
/// Exposed for deterministic tests (enqueue/drain ordering) without spawning
/// real threads in test executables.
pub const WriterQueue = struct {
    items: std.ArrayListUnmanaged([]u8) = .empty,
    mu: std.atomic.Mutex = .unlocked,
    active: std.atomic.Value(bool) = .init(false),

    /// Enqueue a byte item (copied; caller's slice may be reused).
    /// Returns false on allocation failure.
    pub fn enqueue(self: *WriterQueue, bytes: []const u8) bool {
        const copy = page_alloc.dupe(u8, bytes) catch return false;
        errdefer page_alloc.free(copy);
        while (!self.mu.tryLock()) {
            std.atomic.spinLoopHint();
        }
        defer self.mu.unlock();
        self.items.append(page_alloc, copy) catch {
            page_alloc.free(copy);
            return false;
        };
        return true;
    }

    /// Number of items currently queued.
    pub fn depth(self: *WriterQueue) usize {
        while (!self.mu.tryLock()) {
            std.atomic.spinLoopHint();
        }
        defer self.mu.unlock();
        return self.items.items.len;
    }

    /// Writer-thread poll step: drain all queued items, write each to stdout
    /// (FIFO order) via the self-contained single-threaded Io context, and
    /// free each item's buffer. Returns how many items were flushed.
    pub fn pollFlush(self: *WriterQueue) usize {
        var take: std.ArrayListUnmanaged([]u8) = .empty;
        {
            while (!self.mu.tryLock()) {
                std.atomic.spinLoopHint();
            }
            defer self.mu.unlock();
            take = self.items;
            self.items = .empty;
        }
        const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);
        const f = std.Io.File.stdout();
        const count = take.items.len;
        for (take.items) |item| {
            f.writeStreamingAll(io, item) catch {};
            page_alloc.free(item);
        }
        take.deinit(page_alloc);
        return count;
    }

    /// Free all queued items without writing (used on shutdown when no more
    /// output is desired, e.g. the thread failed to start). Returns how many
    /// were discarded.
    pub fn drainAll(self: *WriterQueue) usize {
        var take: std.ArrayListUnmanaged([]u8) = .empty;
        {
            while (!self.mu.tryLock()) {
                std.atomic.spinLoopHint();
            }
            defer self.mu.unlock();
            take = self.items;
            self.items = .empty;
        }
        const count = take.items.len;
        for (take.items) |item| page_alloc.free(item);
        take.deinit(page_alloc);
        return count;
    }

    /// Return the current FIFO item list without freeing, for inspection.
    /// The returned list owns its internal buffer; the caller must iterate
    /// `take.items`, free each item with page_alloc, then call
    /// `take.deinit(page_alloc)`.
    pub fn peekItems(self: *WriterQueue) std.ArrayListUnmanaged([]u8) {
        var take: std.ArrayListUnmanaged([]u8) = .empty;
        while (!self.mu.tryLock()) {
            std.atomic.spinLoopHint();
        }
        defer self.mu.unlock();
        take = self.items;
        self.items = .empty;
        return take;
    }
};

var g_queue: WriterQueue = .{};
var g_writer_thread: ?std.Thread = null;

fn writerThreadEntry() void {
    // PSEUDOCODE:
    // 1. Drain the queue (mutex-swapped list) and write items to stdout in FIFO
    //    order using the self-contained single-threaded Io context.
    // 2. If the queue was deactivated and fully drained → exit; else poll 1ms.
    const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);
    while (true) {
        _ = g_queue.pollFlush();
        if (!g_queue.active.load(.acquire)) return;
        _ = std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
}

/// Activate the background writer thread. No-op when called twice or in tests.
pub fn startWriter() void {
    if (comptime builtin.is_test) return;
    if (g_queue.active.load(.acquire)) return;
    g_queue.active.store(true, .release);
    g_writer_thread = std.Thread.spawn(.{}, writerThreadEntry, .{}) catch {
        g_queue.active.store(false, .release);
        return;
    };
}

/// Drain remaining queued writes and stop the writer thread.
pub fn stopWriter() void {
    if (comptime builtin.is_test) return;
    if (!g_queue.active.load(.acquire)) return;
    g_queue.active.store(false, .release);
    if (g_writer_thread) |t| {
        t.join();
        g_writer_thread = null;
    }
    // The writer drains the remainder itself before exiting; if spawn failed,
    // flush the remainder synchronously here.
    _ = g_queue.pollFlush();
}

/// Safely write raw bytes to stdout (skipped during testing to prevent blocking mock Io).
/// When the writer queue is active, bytes are enqueued as a single FIFO item and
/// flushed by the background writer thread — in-place "sections" built by one
/// producer therefore cannot be interleaved by other producers.
pub fn writeStdout(bytes: []const u8) void {
    if (comptime builtin.is_test) return;
    if (g_queue.active.load(.acquire) and g_queue.enqueue(bytes)) return;
    const f = std.Io.File.stdout();
    f.writeStreamingAll(main.getIo(), bytes) catch {};
}

/// Number of items currently waiting in the writer queue (test/diagnostics hook).
pub fn queueDepth() usize {
    return g_queue.depth();
}

// ---------------------------------------------------------------------------
// Cursor & Screen Control
// ---------------------------------------------------------------------------

/// Clear current line and move cursor to beginning of line.
pub fn clearLine(io: std.Io) void {
    _ = io;
    writeStdout("\r\x1b[2K");
}

/// Hide terminal cursor.
pub fn hideCursor(io: std.Io) void {
    _ = io;
    writeStdout("\x1b[?25l");
}

/// Show terminal cursor.
pub fn showCursor(io: std.Io) void {
    _ = io;
    writeStdout("\x1b[?25h");
}

/// Move cursor up by `n` lines.
pub fn cursorUp(io: std.Io, n: usize) void {
    _ = io;
    if (n == 0) return;
    var buf: [32]u8 = undefined;
    const seq = std.fmt.bufPrint(&buf, "\x1b[{d}A", .{n}) catch return;
    writeStdout(seq);
}

/// Move cursor down by `n` lines.
pub fn cursorDown(io: std.Io, n: usize) void {
    _ = io;
    if (n == 0) return;
    var buf: [32]u8 = undefined;
    const seq = std.fmt.bufPrint(&buf, "\x1b[{d}B", .{n}) catch return;
    writeStdout(seq);
}

extern fn isatty(fd: c_int) c_int;
extern fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

const CWinSize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

/// Check whether stdout is a TTY.
pub fn isStdoutTty() bool {
    if (comptime builtin.is_test) return false;
    if (builtin.os.tag == .windows) return true;
    return isatty(1) != 0;
}

pub const WinSize = struct {
    rows: u16,
    cols: u16,
};

/// Get current terminal window size (rows, cols). Fallback to 24x80 if unavailable.
pub fn getTerminalSize() WinSize {
    if (comptime builtin.is_test) return .{ .rows = 24, .cols = 80 };
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        const TIOCGWINSZ: c_ulong = if (builtin.os.tag == .linux) 0x5413 else 0x40087468;
        var ws: CWinSize = undefined;
        if (ioctl(1, TIOCGWINSZ, &ws) == 0 and ws.ws_col > 0) {
            return .{ .rows = ws.ws_row, .cols = ws.ws_col };
        }
    }
    return .{ .rows = 24, .cols = 80 };
}

test "terminal constants" {
    try std.testing.expect(RESET.len > 0);
    try std.testing.expect(FG_GREEN.len > 0);
    try std.testing.expectEqualStrings("╭", BOX_TOP_LEFT);
    try std.testing.expectEqualStrings("⚡", GLYPH_ACTION);
}

test "terminal WriterQueue: FIFO enqueue/drain semantics" {
    // PSEUDOCODE:
    // 1. Enqueue 3 items; caller reuses its scratch buffer after each enqueue
    //    (items must be COPIES, not views).
    // 2. peekItems → items come back in FIFO order; queue depth back to 0.
    // 3. peekItems on an empty queue → zero items.
    var q: WriterQueue = .{};
    var scratch: [16]u8 = undefined;
    try std.testing.expect(q.enqueue("a"));
    @memcpy(scratch[0..1], "b");
    try std.testing.expect(q.enqueue(scratch[0..1]));
    @memcpy(scratch[0..1], "c");
    try std.testing.expect(q.enqueue(scratch[0..1]));
    try std.testing.expectEqual(@as(usize, 3), q.depth());

    var take = q.peekItems();
    try std.testing.expectEqual(@as(usize, 3), take.items.len);
    try std.testing.expectEqualStrings("a", take.items[0]);
    try std.testing.expectEqualStrings("b", take.items[1]);
    try std.testing.expectEqualStrings("c", take.items[2]);
    try std.testing.expectEqual(@as(usize, 0), q.depth());
    for (take.items) |item| page_alloc.free(item);
    take.deinit(page_alloc);

    var empty = q.peekItems();
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);
    for (empty.items) |item| page_alloc.free(item);
    empty.deinit(page_alloc);
}

/// Thread entry for the multi-producer WriterQueue test (file-level so Zig
/// parses it cleanly; mirrors the repo's test-thread convention).
fn writerQueueTestProducer(q_ptr: *WriterQueue, id: usize) void {
    for (0..writerQueueTestItemsPerProducer) |i| {
        var buf: [16]u8 = undefined;
        const item = std.fmt.bufPrint(&buf, "{d}-{d}", .{ id, i }) catch unreachable;
        if (!q_ptr.enqueue(item)) unreachable;
    }
}

const writerQueueTestProducers = 4;
const writerQueueTestItemsPerProducer = 50;

test "terminal WriterQueue: multi-producer ordering under concurrency" {
    var q: WriterQueue = .{};

    var threads: [writerQueueTestProducers]std.Thread = undefined;
    for (0..writerQueueTestProducers) |i| {
        threads[i] = try std.Thread.spawn(.{}, writerQueueTestProducer, .{ &q, i });
    }
    for (threads) |t| t.join();

    // Drain once: total item count must be exact (no lost enqueues).
    var take = q.peekItems();
    const total = take.items.len;
    for (take.items) |item| page_alloc.free(item);
    take.deinit(page_alloc);
    try std.testing.expectEqual(
        @as(usize, writerQueueTestProducers * writerQueueTestItemsPerProducer),
        total,
    );
}
