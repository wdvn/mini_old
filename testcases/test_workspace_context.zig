//! test_workspace_context.zig — Tests for Workspace Context & Project AGENTS.md auto-detection.
//!
//! Validates:
//!   1. buildWorkspaceContext constructs dynamic <workspace_context> with working directory,
//!      project name, detected project type (e.g. Zig), git branch, and top-level entries.
//!   2. loadSystemPrompt loads project root AGENTS.md (not just .agent/AGENTS.md).
//!   3. Injected workspace context appears in system prompt before rules.

const std = @import("std");
const mini = @import("mini");
const config_mod = mini.config_mod;

test "workspace_context: buildWorkspaceContext detects current project metadata" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var env_map = std.process.Environ.Map.init(alloc);
    defer env_map.deinit();

    // Use current working directory
    const cwd_path = std.c.getenv("PWD") orelse ".";
    try env_map.put("MINI_WORKSPACE_ROOT", std.mem.span(cwd_path));
    try env_map.put("PWD", std.mem.span(cwd_path));

    const ctx = config_mod.buildWorkspaceContext(alloc, &env_map, io);
    try std.testing.expect(ctx != null);
    defer alloc.free(ctx.?);

    // Verify key sections of <workspace_context>
    try std.testing.expect(std.mem.indexOf(u8, ctx.?, "<workspace_context>") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx.?, "</workspace_context>") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx.?, "- Working Directory:") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx.?, "- Project Name:") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx.?, "- Project Type:") != null);
    // In this repo, Zig marker (build.zig) should be detected
    try std.testing.expect(std.mem.indexOf(u8, ctx.?, "Zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx.?, "- Workspace Entries:") != null);
}

test "workspace_context: loadSystemPrompt injects context and loads root AGENTS.md" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var env_map = std.process.Environ.Map.init(alloc);
    defer env_map.deinit();

    const cwd_path = std.c.getenv("PWD") orelse ".";
    try env_map.put("MINI_WORKSPACE_ROOT", std.mem.span(cwd_path));
    try env_map.put("PWD", std.mem.span(cwd_path));
    if (std.c.getenv("HOME")) |home| {
        try env_map.put("HOME", std.mem.span(home));
    }

    const sp = config_mod.loadSystemPrompt(alloc, &env_map, io);
    defer if (sp.buf) |b| alloc.free(b);
    defer config_mod.skills_mod.deinitSkills();

    // 1. Should have workspace context
    try std.testing.expect(std.mem.indexOf(u8, sp.text, "<workspace_context>") != null);

    // 2. Should have loaded root AGENTS.md
    try std.testing.expect(std.mem.indexOf(u8, sp.text, "<RULE[AGENTS.md]>") != null);
    try std.testing.expect(std.mem.indexOf(u8, sp.text, "mini-agent") != null);
}

test "system prompt: codeact instructions are enabled only for codeact mode" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    for ([_]struct { mode: config_mod.ExecutionMode, expected: bool }{
        .{ .mode = .codeact, .expected = true },
        .{ .mode = .tools, .expected = false },
        .{ .mode = .auto, .expected = false },
    }) |case| {
        var env_map = std.process.Environ.Map.init(alloc);
        defer env_map.deinit();

        try env_map.put("OPENAI_COMPAT_URL", "http://127.0.0.1:1/v1");
        try env_map.put("MINI_EXECUTION_MODE", @tagName(case.mode));

        var cfg = try config_mod.Config.load(alloc, &env_map, io);
        defer cfg.deinit(alloc);

        const has_instructions = std.mem.indexOf(u8, cfg.system_prompt, "## CodeAct Execution Instructions") != null;
        try std.testing.expectEqual(case.expected, has_instructions);
    }
}
