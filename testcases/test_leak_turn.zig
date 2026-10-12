//! test_leak_turn.zig — Memory leak verification on exit (Issue #23).
//!
//! Asserts that AgentLoop, Config, and LineEditor clean up all allocated memory
//! through DebugAllocator(.{ .stack_trace_frames = 16 }) yielding LeakState.no_leak.

const std = @import("std");
const mini = @import("mini");
const config_mod = mini.config_mod;
const agent_mod = mini.agent_mod;
const ui_editor = mini.editor_mod;

test "issue #23: AgentLoop and Config init/deinit leave no DebugAllocator leak" {
    // PSEUDOCODE:
    // 1. Wrap allocations in DebugAllocator with 16 stack trace frames.
    // 2. Initialize and deinitialize environ, config, and agent in an inner block.
    // 3. Assert gpa.deinit() returns .no_leak.
    var gpa = std.heap.DebugAllocator(.{ .stack_trace_frames = 16 }){};
    const alloc = gpa.allocator();

    {
        const io = std.testing.io;
        var env_map = std.process.Environ.Map.init(alloc);
        defer env_map.deinit();
        try env_map.put("OPENAI_COMPAT_URL", "http://127.0.0.1:1/v1");

        var cfg = try config_mod.Config.load(alloc, &env_map, io);
        defer cfg.deinit(alloc);

        var agent = try agent_mod.AgentLoop.init(alloc, io, &cfg);
        defer agent.deinit();
    }

    try std.testing.expectEqual(std.heap.Check.ok, gpa.deinit());
}

test "issue #23: LineEditor init/deinit leaves no DebugAllocator leak with edits and kills" {
    // PSEUDOCODE:
    // 1. Create LineEditor with DebugAllocator.
    // 2. Perform insertions, undos, and kill_ring pushes past circular buffer wrap-around.
    // 3. Deinit LineEditor and assert gpa.deinit() returns .no_leak.
    var gpa = std.heap.DebugAllocator(.{ .stack_trace_frames = 16 }){};
    const alloc = gpa.allocator();

    {
        var editor = ui_editor.LineEditor.init(alloc);
        defer editor.deinit();

        for (0..20) |i| {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "kill item {d}", .{i}) catch unreachable;
            editor.killPush(s);
        }

        try editor.buf.appendSlice(alloc, "test edit buffer");
        editor.pushUndo();
        try editor.buf.appendSlice(alloc, " extra");
        editor.pushUndo();
        _ = editor.applyUndo();
    }

    try std.testing.expectEqual(std.heap.Check.ok, gpa.deinit());
}
