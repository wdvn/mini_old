const std = @import("std");
const config_mod = @import("../src/core/config.zig");
const agent_mod = @import("../src/core/agent/loop.zig");
const ui_repl = @import("../src/ui/repl.zig");

test "issue #23: AgentLoop init/deinit leaves no DebugAllocator leak (empty stack trace case)" {
    // PSEUDOCODE:
    // 1. Wrap everything in DebugAllocator with 16 stack frames so real leaks
    //    carry diagnostic stack traces (issue #23 complains about "(empty stack trace)").
    // 2. Init config + agent the same way main() does.
    // 3. Deinit everything and assert .no_leak.
    var gpa = std.heap.DebugAllocator(.{ .stack_trace_frames = 16 }){};
    const alloc = gpa.allocator();

    const io = std.Io.File.stdout();
    var environ = try std.process.getEnvMap(alloc);
    defer environ.deinit();

    var cfg = try config_mod.Config.init(alloc, io, environ, null);
    defer cfg.deinit(alloc);

    var agent = try agent_mod.AgentLoop.init(alloc, io, &cfg);
    defer agent.deinit();

    try std.testing.expectEqual(
        std.heap.DebugAllocator(.{ .stack_trace_frames = 16 }).LeakState.no_leak,
        gpa.deinit(),
    );
}

test "issue #23: leak detector reports stack traces (diagnostics baseline)" {
    // PSEUDOCODE:
    // 1. Confirm DebugAllocator captures stack traces for a real leak so the
    //    "(empty stack trace)" symptom in the issue is distinguishable from
    //    intentional process-exit arenas.
    // 2. Deliberately drop an allocation.
    var gpa = std.heap.DebugAllocator(.{ .stack_trace_frames = 16 }){};
    const alloc = gpa.allocator();

    const dropped = try alloc.dupe(u8, "deliberately dropped for diagnostics");
    _ = dropped; // intentionally dropped

    try std.testing.expectEqual(
        std.heap.DebugAllocator(.{ .stack_trace_frames = 16 }).LeakState.leak,
        gpa.deinit(),
    );
}

test "AgentLoop deinit leak test" {
    var gpa = std.heap.DebugAllocator(.{ .stack_trace_frames = 16 }){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) std.debug.print("Memory leaked!\n", .{});
    }
    const alloc = gpa.allocator();
    
    // Simulate init
    const io = std.Io.File.stdout();
    var environ = try std.process.getEnvMap(alloc);
    defer environ.deinit();

    var cfg = try config_mod.Config.init(alloc, io, environ, null);
    defer cfg.deinit(alloc);

    var agent = try agent_mod.AgentLoop.init(alloc, io, &cfg);
    defer agent.deinit();
}
