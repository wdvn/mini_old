//! test_editor_multiline.zig — Integration tests for multiline terminal input & escape sequences.
//!
//! Validates:
//!   1. Kitty keyboard protocol CSI-u (Shift+Enter, Ctrl+Enter, event types) -> inserts \n
//!   2. xterm modifyOtherKeys (Shift+Enter, Ctrl+Enter) -> inserts \n
//!   3. CSI-tilde sequences (\x1b[13;2~, \x1b[13;5~) -> inserts \n
//!   4. Alt+Enter (\x1b\r, \x1b\n) -> inserts \n without blocking
//!   5. Backslash line continuation (\ + Enter)

const std = @import("std");
const mini = @import("mini");
const editor_mod = mini.editor_mod;

test "multiline: Kitty CSI-u Shift+Enter, Ctrl+Enter, and event types" {
    const alloc = std.testing.allocator;
    var e = editor_mod.LineEditor.init(alloc);
    defer e.deinit();
    e.suppress_redraw = true;

    try e.buf.appendSlice(alloc, "hello");
    e.pos = e.buf.items.len;

    // Shift+Enter (CSI 13 ; 2 u)
    const seq_shift = "\x1b[13;2u";
    const c1 = e.handleEscapeSlice(undefined, undefined, "", seq_shift);
    try std.testing.expectEqual(seq_shift.len, c1);
    try std.testing.expectEqualStrings("hello\n", e.buf.items);
    try std.testing.expectEqual(@as(usize, 6), e.pos);

    // Shift+Enter with press event type (CSI 13 ; 2 : 1 u)
    const seq_shift_ev = "\x1b[13;2:1u";
    const c2 = e.handleEscapeSlice(undefined, undefined, "", seq_shift_ev);
    try std.testing.expectEqual(seq_shift_ev.len, c2);
    try std.testing.expectEqualStrings("hello\n\n", e.buf.items);

    // Ctrl+Enter (CSI 13 ; 5 u)
    const seq_ctrl = "\x1b[13;5u";
    const c3 = e.handleEscapeSlice(undefined, undefined, "", seq_ctrl);
    try std.testing.expectEqual(seq_ctrl.len, c3);
    try std.testing.expectEqualStrings("hello\n\n\n", e.buf.items);
}

test "multiline: xterm modifyOtherKeys Shift+Enter and Ctrl+Enter" {
    const alloc = std.testing.allocator;
    var e = editor_mod.LineEditor.init(alloc);
    defer e.deinit();
    e.suppress_redraw = true;

    try e.buf.appendSlice(alloc, "prompt");
    e.pos = e.buf.items.len;

    // xterm Shift+Enter (ESC [ 27 ; 2 ; 13 ~)
    const seq_shift = "\x1b[27;2;13~";
    const c1 = e.handleEscapeSlice(undefined, undefined, "", seq_shift);
    try std.testing.expectEqual(seq_shift.len, c1);
    try std.testing.expectEqualStrings("prompt\n", e.buf.items);

    // xterm Ctrl+Enter (ESC [ 27 ; 5 ; 13 ~)
    const seq_ctrl = "\x1b[27;5;13~";
    const c2 = e.handleEscapeSlice(undefined, undefined, "", seq_ctrl);
    try std.testing.expectEqual(seq_ctrl.len, c2);
    try std.testing.expectEqualStrings("prompt\n\n", e.buf.items);
}

test "multiline: CSI-tilde Shift+Enter and Ctrl+Enter" {
    const alloc = std.testing.allocator;
    var e = editor_mod.LineEditor.init(alloc);
    defer e.deinit();
    e.suppress_redraw = true;

    try e.buf.appendSlice(alloc, "code");
    e.pos = e.buf.items.len;

    // CSI tilde Shift+Enter (ESC [ 13 ; 2 ~)
    const seq_shift = "\x1b[13;2~";
    const c1 = e.handleEscapeSlice(undefined, undefined, "", seq_shift);
    try std.testing.expectEqual(seq_shift.len, c1);
    try std.testing.expectEqualStrings("code\n", e.buf.items);

    // CSI tilde Ctrl+Enter (ESC [ 13 ; 5 ~)
    const seq_ctrl = "\x1b[13;5~";
    const c2 = e.handleEscapeSlice(undefined, undefined, "", seq_ctrl);
    try std.testing.expectEqual(seq_ctrl.len, c2);
    try std.testing.expectEqualStrings("code\n\n", e.buf.items);
}

test "multiline: Alt+Enter legacy sequences do not hang" {
    const alloc = std.testing.allocator;
    var e = editor_mod.LineEditor.init(alloc);
    defer e.deinit();
    e.suppress_redraw = true;

    try e.buf.appendSlice(alloc, "start");
    e.pos = e.buf.items.len;

    // Alt+Enter as \x1b\r
    const c1 = e.handleEscapeSlice(undefined, undefined, "", "\x1b\r");
    try std.testing.expectEqual(@as(usize, 2), c1);
    try std.testing.expectEqualStrings("start\n", e.buf.items);

    // Alt+Enter as \x1b\n
    const c2 = e.handleEscapeSlice(undefined, undefined, "", "\x1b\n");
    try std.testing.expectEqual(@as(usize, 2), c2);
    try std.testing.expectEqualStrings("start\n\n", e.buf.items);
}

test "multiline: backslash continuation strips backslash and inserts newline" {
    const alloc = std.testing.allocator;
    var e = editor_mod.LineEditor.init(alloc);
    defer e.deinit();
    e.suppress_redraw = true;

    try e.buf.appendSlice(alloc, "function foo() \\");
    e.pos = e.buf.items.len;

    // Simulate Enter key logic with backslash continuation
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

    try std.testing.expectEqualStrings("function foo() \n", e.buf.items);
    try std.testing.expectEqual(@as(usize, "function foo() \n".len), e.pos);
}
