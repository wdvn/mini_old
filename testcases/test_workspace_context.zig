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

test "system prompt: remains decoupled from codeact instructions across all modes" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    for ([_]config_mod.ExecutionMode{ .codeact, .tools, .auto }) |mode| {
        var env_map = std.process.Environ.Map.init(alloc);
        defer env_map.deinit();

        try env_map.put("OPENAI_COMPAT_URL", "http://127.0.0.1:1/v1");
        try env_map.put("MINI_EXECUTION_MODE", @tagName(mode));

        var cfg = try config_mod.Config.load(alloc, &env_map, io);
        defer cfg.deinit(alloc);

        const prompt = cfg.system_prompt;
        try std.testing.expect(std.mem.indexOf(u8, prompt, "## CodeAct Execution Instructions") == null);
        try std.testing.expect(std.mem.indexOf(u8, prompt, "TOOL EXECUTION IS CODEACT-ONLY") == null);
        try std.testing.expect(std.mem.indexOf(u8, prompt, "`tool_call` is not executable CodeAct syntax") == null);
    }
}

test "codeact tool definition encapsulates mini.* API and execution constraints" {
    const tools_mod = mini.tools_mod;

    var codeact_def_opt: ?mini.proto.ToolDefinition = null;
    for (&tools_mod.definitions) |td| {
        if (std.mem.eql(u8, td.name, "codeact")) {
            codeact_def_opt = td;
            break;
        }
    }

    try std.testing.expect(codeact_def_opt != null);
    const def = codeact_def_opt.?;

    // Description must contain synchronous constraint and console.log observation requirement
    try std.testing.expect(std.mem.indexOf(u8, def.description, "synchronous") != null);
    try std.testing.expect(std.mem.indexOf(u8, def.description, "console.log") != null);

    // Description must contain core mini.* API references
    try std.testing.expect(std.mem.indexOf(u8, def.description, "mini.read") != null);
    try std.testing.expect(std.mem.indexOf(u8, def.description, "mini.write") != null);
    try std.testing.expect(std.mem.indexOf(u8, def.description, "mini.patch") != null);
    try std.testing.expect(std.mem.indexOf(u8, def.description, "mini.sh") != null);
    try std.testing.expect(std.mem.indexOf(u8, def.description, "mini.glob") != null);
    try std.testing.expect(std.mem.indexOf(u8, def.description, "mini.grep") != null);

    // Input schema must require code argument
    try std.testing.expect(std.mem.indexOf(u8, def.input_schema_json, "\"code\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, def.input_schema_json, "\"required\":[\"code\"]") != null);
}
