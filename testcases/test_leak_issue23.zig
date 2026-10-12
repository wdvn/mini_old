const std = @import("std");
const mini = @import("mini");
const config_mod = @import("mini/src/core/config.zig");
const agent_mod = @import("mini/src/core/agent/loop.zig");

test "issue #23: AgentLoop init/deinit leaves no DebugAllocator leak (empty stack trace case)" {
    var gpa = std.heap.DebugAllocator(.{ .stack_trace_frames = 16 }){};
    const alloc = gpa.allocator();
    defer _ = gpa.deinit();
    const io = std.Io.File.stdout();
    var environ = try std.process.getEnvMap(alloc);
    defer environ.deinit();
    var cfg = try config_mod.Config.init(alloc, io, environ, null);
    defer cfg.deinit(alloc);
    var agent = try agent_mod.AgentLoop.init(alloc, io, &cfg);
    defer agent.deinit();
    try std.testing.expectEqual(std.heap.DebugAllocator(.{ .stack_trace_frames = 16 }).LeakState.no_leak, gpa.deinit());
}
