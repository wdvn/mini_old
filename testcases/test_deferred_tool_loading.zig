//! test_deferred_tool_loading.zig — Integration tests for Deferred Tool Loading.
//!
//! Validates:
//! 1. Deferred mode ships a small, MCP-independent essential tool list
//! 2. `tool_search` returns usable full schemas and promotes matched tools
//! 3. Promoted tools become visible for later acts (grow-only, deterministic order)
//! 4. `MINI_DEFERRED_TOOLS=0` restores the legacy eager tool list
//! 5. Policy still filters the resolved deferred list

const std = @import("std");
const mini = @import("mini");
const tools_mod = mini.tools_mod;

/// Names of the tools that must always be sent in deferred mode.
const expected_essential = [_][]const u8{
    "bash", "file_write", "file_edit", "http_request", "skills", "tool_search",
};

fn resetState() void {
    tools_mod.setPolicy(null, null);
    tools_mod.setMcpManager(null);
    tools_mod.setDeferredToolsEnabled(true);
    tools_mod.resetPromotedTools();
    pinSubagentDepth();
}

/// `isPermitted` hides invoke_subagent when the subagent depth limit is
/// reached, and other testcases mutate MINI_SUBAGENT_DEPTH in the shared env map.
/// Pin the depth so these tests do not depend on unrelated global state.
fn pinSubagentDepth() void {
    const em = mini.getEnvironMap() orelse return;
    em.put("MINI_SUBAGENT_DEPTH", "0") catch {};
    em.put("MINI_MAX_SUBAGENT_DEPTH", "3") catch {};
}

test "deferred mode sends only the essential tool list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    resetState();

    const defs = tools_mod.resolveDeferredTools(alloc);
    try std.testing.expectEqual(expected_essential.len, defs.len);

    for (expected_essential) |name| {
        var found = false;
        for (defs) |td| {
            if (std.mem.eql(u8, td.name, name)) found = true;
        }
        try std.testing.expect(found);
    }

    // Deferred tools must NOT be sent before promotion.
    try std.testing.expect(!tools_mod.isToolPromoted("invoke_subagent"));
    for (defs) |td| {
        try std.testing.expect(!tools_mod.isDeferredTool(td.name));
    }
}

test "tool_search returns full schemas and promotes matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    resetState();

    const out = try tools_mod.executeTool(alloc, mini.g_io, "tool_search",
        \\{"query":"subagent","limit":5}
    );
    defer alloc.free(out);

    // Full schema is materialized (not just a name).
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"invoke_subagent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"input_schema\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"task\"") != null);

    // Matching tools are promoted.
    try std.testing.expect(tools_mod.isToolPromoted("invoke_subagent"));

    // Every promoted tool becomes visible in the next resolved list, appended
    // after the essential prefix (grow-only, tail-append).
    const defs = tools_mod.resolveDeferredTools(alloc);
    try std.testing.expect(defs.len > expected_essential.len);
    for (defs[expected_essential.len..]) |td| {
        try std.testing.expect(tools_mod.isDeferredTool(td.name));
    }
    // invoke_subagent must be among the newly appended tools.
    var found_subagent = false;
    for (defs) |td| {
        if (std.mem.eql(u8, td.name, "invoke_subagent")) found_subagent = true;
    }
    try std.testing.expect(found_subagent);
}

test "promotion list is grow-only and deterministic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    resetState();

    tools_mod.promoteTool("artifact_write");
    tools_mod.promoteTool("invoke_subagent");
    // Duplicate + alias promotion must not reorder or duplicate entries.
    tools_mod.promoteTool("artifact_write");
    tools_mod.promoteTool("write_file");

    const first = tools_mod.resolveDeferredTools(alloc);
    try std.testing.expectEqual(expected_essential.len + 2, first.len);
    try std.testing.expectEqualStrings("artifact_write", first[expected_essential.len].name);
    try std.testing.expectEqualStrings("invoke_subagent", first[expected_essential.len + 1].name);

    // Re-resolving (next act) yields the identical prefix and order.
    const second = tools_mod.resolveDeferredTools(alloc);
    try std.testing.expectEqual(first.len, second.len);
    for (first, second) |a, b| {
        try std.testing.expectEqualStrings(a.name, b.name);
    }
}

test "MINI_DEFERRED_TOOLS=0 keeps the legacy eager tool list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    resetState();
    tools_mod.setDeferredToolsEnabled(false);
    defer tools_mod.setDeferredToolsEnabled(true);

    try std.testing.expect(!tools_mod.isDeferredToolsEnabled());

    // Legacy path still resolves the full core list, not the essential subset.
    const defs = tools_mod.getRelevantDefinitions(alloc, "hello");
    try std.testing.expect(defs.len > expected_essential.len);

    var has_subagent = false;
    for (defs) |td| {
        if (std.mem.eql(u8, td.name, "invoke_subagent")) has_subagent = true;
    }
    try std.testing.expect(has_subagent);
}

test "tool policy still filters the deferred list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    resetState();
    defer resetState();

    tools_mod.setPolicy("bash,file_write,skills,tool_search", null);

    const defs = tools_mod.resolveDeferredTools(alloc);
    for (defs) |td| {
        try std.testing.expect(std.mem.eql(u8, td.name, "bash") or
            std.mem.eql(u8, td.name, "file_write") or
            std.mem.eql(u8, td.name, "skills") or
            std.mem.eql(u8, td.name, "tool_search"));
    }
}
