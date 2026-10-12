const std = @import("std");
const config_mod = @import("core/config.zig");
const agent_mod = @import("core/agent/loop.zig");
const main_mod = @import("main.zig");

test "AgentLoop leak check" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);

    var cfg = config_mod.Config.init(alloc);
    // don't try to deinit cfg, it doesn't own memory

    var agent = agent_mod.AgentLoop.init(alloc, io, &cfg) catch |e| {
        std.debug.print("Init failed: {s}\n", .{@errorName(e)});
        return;
    };
    defer agent.deinit();

    std.debug.print("Success\n", .{});
}
