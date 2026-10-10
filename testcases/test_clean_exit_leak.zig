//! test_clean_exit_leak.zig — Regression test for Issue #23:
//! Clean exit with DebugAllocator leak checking and stack trace capture.

const std = @import("std");
const mini = @import("mini");

test "clean exit: LineEditor, AgentLoop, and Config init and deinit without memory leaks" {
    // PSEUDOCODE:
    // 1. Initialize DebugAllocator with stack_trace_frames = 16 to capture allocation stack traces
    // 2. Initialize Config with valid dummy backend URL and load settings
    // 3. Initialize AgentLoop and LineEditor with the allocator
    // 4. Deinitialize all components in reverse order
    // 5. Verify DebugAllocator deinit reports std.heap.Check.ok (no memory leaks)
    var gpa = std.heap.DebugAllocator(.{ .stack_trace_frames = 16 }){};
    defer {
        const check = gpa.deinit();
        std.testing.expectEqual(std.heap.Check.ok, check) catch @panic("DebugAllocator detected memory leak");
    }
    const alloc = gpa.allocator();
    const io = std.testing.io;

    var env_map = std.process.Environ.Map.init(alloc);
    defer env_map.deinit();
    try env_map.put("OPENAI_COMPAT_URL", "http://127.0.0.1:1/v1");

    var cfg = try mini.config_mod.Config.load(alloc, &env_map, io);
    defer cfg.deinit(alloc);

    var agent = try mini.agent_mod.AgentLoop.init(alloc, io, &cfg);
    defer agent.deinit();

    var editor = mini.editor_mod.LineEditor.init(alloc);
    defer editor.deinit();
}

test "clean exit: LineEditor multiline input and history deinit without memory leaks" {
    // PSEUDOCODE:
    // 1. Initialize DebugAllocator with stack_trace_frames = 16
    // 2. Initialize LineEditor
    // 3. Add prompt history and buffer content
    // 4. Deinitialize and verify gpa.deinit reports no leaks
    var gpa = std.heap.DebugAllocator(.{ .stack_trace_frames = 16 }){};
    defer {
        const check = gpa.deinit();
        std.testing.expectEqual(std.heap.Check.ok, check) catch @panic("DebugAllocator detected memory leak");
    }
    const alloc = gpa.allocator();

    var editor = mini.editor_mod.LineEditor.init(alloc);
    defer editor.deinit();
    editor.suppress_redraw = true;

    try editor.addHistory("first command");
    try editor.addHistory("second command");

    try editor.buf.appendSlice(alloc, "sample buffer content");
    editor.pos = editor.buf.items.len;
}
