//! test_ui_chat_stream.zig — Unit tests cho RFC-007 REPL Chat Stream & UI Primitives.
//!
//! Kiểm tra các module:
//! - ui/terminal.zig
//! - ui/spinner.zig
//! - ui/diff_renderer.zig
//! - ui/markdown.zig
//! - ui/chat_stream.zig

const std = @import("std");
const mini = @import("mini");
const term = mini.ui_terminal;
const spinner_mod = mini.ui_spinner;
const diff_mod = mini.ui_diff;
const markdown_mod = mini.ui_markdown;
const chat_stream = mini.ui_chat_stream;

test "UI Terminal: Constants and Box characters" {
    try std.testing.expectEqualStrings("\x1b[0m", term.RESET);
    try std.testing.expectEqualStrings("\x1b[1m", term.BOLD);
    try std.testing.expectEqualStrings("\x1b[32m", term.FG_GREEN);
    try std.testing.expectEqualStrings("╭", term.BOX_TOP_LEFT);
    try std.testing.expectEqualStrings("╯", term.BOX_BOT_RIGHT);
    try std.testing.expectEqualStrings("⚡", term.GLYPH_ACTION);
    try std.testing.expectEqualStrings("✓", term.GLYPH_CHECK);
}

test "UI Spinner: Frame transitions and stopwatch" {
    var spinner = spinner_mod.Spinner.start();
    try std.testing.expect(spinner.is_active);

    const f1 = spinner.nextFrame();
    const f2 = spinner.nextFrame();
    try std.testing.expect(!std.mem.eql(u8, f1, f2));

    const elapsed = spinner.elapsedSeconds();
    try std.testing.expect(elapsed >= 0.0);

    spinner.clear(std.testing.io);
    try std.testing.expect(!spinner.is_active);
}

test "UI Diff Renderer: Split lines and render verification" {
    const sample_patch =
        \\--- a/src/core/utils.zig
        \\+++ b/src/core/utils.zig
        \\@@ -10,4 +10,4 @@
        \\-const old_val = 100;
        \\+const new_val = 200;
        \\ const unchanged = true;
    ;

    // Test that renderDiff runs safely without error
    diff_mod.renderDiff(std.testing.io, "src/core/utils.zig", sample_patch, .{
        .max_display_lines = 10,
        .show_box = true,
    });
}

test "UI Markdown Highlighter: Inline formatting and code fences" {
    var hl = markdown_mod.StreamHighlighter.init();
    try std.testing.expectEqual(markdown_mod.State.normal, hl.state);

    // Stream normal text + bold
    hl.processChunk(std.testing.io, "Xin chào **bạn**!\n");
    try std.testing.expectEqual(markdown_mod.State.normal, hl.state);

    // Stream inline code
    hl.processChunk(std.testing.io, "Dùng lệnh `zig build test` để kiểm tra.\n");
    try std.testing.expectEqual(markdown_mod.State.normal, hl.state);

    // Stream code block
    hl.processChunk(std.testing.io, "```zig\nconst x: u32 = 42;\nreturn x;\n```\n");
    try std.testing.expectEqual(markdown_mod.State.normal, hl.state);
    try std.testing.expect(!hl.in_code_block);

    hl.flush(std.testing.io);
}

test "UI Chat Stream: TurnRenderer complete lifecycle" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var renderer = chat_stream.TurnRenderer.init(alloc, io);
    try std.testing.expect(!renderer.is_thinking);

    // 1. Start turn
    renderer.startTurn("Hãy sửa lỗi trong file main.zig");
    try std.testing.expect(renderer.turn_start_ms > 0);

    // 2. Stream thinking
    renderer.streamThinking("Đang kiểm tra cú pháp AST...");
    try std.testing.expect(renderer.is_thinking);
    renderer.endThinking();
    try std.testing.expect(!renderer.is_thinking);

    // 3. Process text chunk containing <think> tags
    renderer.processTextChunk("<think>Tìm thấy lỗi tại dòng 42</think>Tôi đã tìm ra giải pháp:");
    try std.testing.expect(!renderer.is_thinking);

    // 4. Tool action
    renderer.startTool("file_edit", "{\"path\":\"src/main.zig\",\"patch\":\"-old\\n+new\"}");
    renderer.finishTool("file_edit", "Updated cleanly", false, 45, "src/main.zig", "-old\n+new");

    // 5. Finish turn
    renderer.finishTurn(.{
        .prompt_tokens = 50,
        .completion_tokens = 120,
        .reasoning_tokens = 30,
        .context_tokens = 1500,
        .max_context_tokens = 128000,
        .duration_ms = 1200,
        .acts_count = 1,
        .files_modified = 1,
    });
}

test "UI Chat Stream: TurnRenderer CodeAct stream in-place" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var renderer = chat_stream.TurnRenderer.init(alloc, io);
    renderer.startTurn("Kiểm tra CodeAct in-place streaming");

    // 1. Process chunk containing inline code and attached ```js ... ```
    renderer.processTextChunk("Tôi sẽ xóa branch `luynt`.```js\nconst files = mini.glob(\"*.zig\");\nconst result = mini.read(files[0]);\nconsole.log(result);\n```Đã xóa xong.\n");
    try std.testing.expect(!renderer.is_codeact);
    try std.testing.expect(!renderer.in_codeact);

    // 2. Process chained code blocks without newlines: ```js...``````js...```
    renderer.processTextChunk("```js\nconst a = 1;\n``````js\nconst b = 2;\n```");
    try std.testing.expect(!renderer.is_codeact);
    try std.testing.expect(!renderer.in_codeact);

    // 3. Test explicit startCodeAct, streamCodeAct, endCodeAct
    renderer.startCodeAct();
    try std.testing.expect(renderer.is_codeact);
    renderer.streamCodeAct("const x = 10;\nconst y = 20;\n");
    renderer.endCodeAct();
    try std.testing.expect(!renderer.is_codeact);

    renderer.finishTurn(.{
        .prompt_tokens = 20,
        .completion_tokens = 40,
    });
}
