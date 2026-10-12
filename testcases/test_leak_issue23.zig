const std = @import("std");
const mini = @import("mini");
const config_mod = mini.config_mod;
const agent_mod = mini.agent_mod;

test "issue #23: AgentLoop init/deinit leaves no DebugAllocator leak (empty stack trace case)" {
    var gpa = std.heap.DebugAllocator(.{ .stack_trace_frames = 16 }){};
    const alloc = gpa.allocator();
    {
        const io = std.testing.io;
        var env_map = std.process.Environ.Map.init(alloc);
        defer env_map.deinit();
        var cfg = try config_mod.Config.init(alloc, io, &env_map, null);
        defer cfg.deinit(alloc);
        var agent = try agent_mod.AgentLoop.init(alloc, io, &cfg);
        defer agent.deinit();
    }
    try std.testing.expectEqual(std.heap.DebugAllocator(.{ .stack_trace_frames = 16 }).LeakState.no_leak, gpa.deinit());
}
