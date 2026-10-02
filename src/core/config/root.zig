//! config/root.zig — Modular configuration package root for mini-agent.
//!
//! Submodules:
//!   - `types`: Core config types, Config struct, JsonConfig, JsonProviderConfig.
//!   - `workspace`: Workspace discovery, marker detection, AGENTS.md rules, system prompt.
//!   - `dotenv`: .env and config.json loading, provider profiles, env mutation.
//!   - `resolvers`: Category resolvers, diagnostics, and Config.load assembly.

const std = @import("std");

pub const types = @import("types.zig");
pub const workspace = @import("workspace.zig");
pub const dotenv = @import("dotenv.zig");
pub const resolvers = @import("resolvers.zig");

// Types re-exports
pub const ExecutionMode = types.ExecutionMode;
pub const OpenAiProtocol = types.OpenAiProtocol;
pub const Config = types.Config;
pub const JsonConfig = types.JsonConfig;
pub const JsonProviderConfig = types.JsonProviderConfig;
pub const skills_mod = types.skills_mod;

// Workspace & prompt re-exports
pub const resolveWorkspaceRoot = workspace.resolveWorkspaceRoot;
pub const resolveWorkspaceRootAndName = workspace.resolveWorkspaceRootAndName;
pub const WorkspaceMarker = workspace.WorkspaceMarker;
pub const WORKSPACE_MARKERS = workspace.WORKSPACE_MARKERS;
pub const detectProjectTypes = workspace.detectProjectTypes;
pub const detectGitBranch = workspace.detectGitBranch;
pub const isIgnoredWorkspaceEntry = workspace.isIgnoredWorkspaceEntry;
pub const collectWorkspaceEntries = workspace.collectWorkspaceEntries;
pub const formatWorkspaceContext = workspace.formatWorkspaceContext;
pub const buildWorkspaceContext = workspace.buildWorkspaceContext;
pub const SpResult = workspace.SpResult;
pub const loadBaseSystemPrompt = workspace.loadBaseSystemPrompt;
pub const injectWorkspaceContext = workspace.injectWorkspaceContext;
pub const appendAgentRuleFile = workspace.appendAgentRuleFile;
pub const collectAgentRules = workspace.collectAgentRules;
pub const readAgentFile = workspace.readAgentFile;
pub const appendSkillsBlock = workspace.appendSkillsBlock;
pub const loadSystemPrompt = workspace.loadSystemPrompt;

// DotEnv & provider profile re-exports
pub const loadDotEnvFiles = dotenv.loadDotEnvFiles;
pub const loadJsonConfigFiles = dotenv.loadJsonConfigFiles;
pub const loadDotEnv = dotenv.loadDotEnv;
pub const setEnvInt = dotenv.setEnvInt;
pub const setEnvFloat = dotenv.setEnvFloat;
pub const setEnvBool = dotenv.setEnvBool;
pub const setEnvDefault = dotenv.setEnvDefault;
pub const tryLoadFile = dotenv.tryLoadFile;
pub const tryLoadJsonConfig = dotenv.tryLoadJsonConfig;
pub const tryLoadProviderJson = dotenv.tryLoadProviderJson;
pub const detectActiveProviderKey = dotenv.detectActiveProviderKey;
pub const resolveProvidersDir = dotenv.resolveProvidersDir;
pub const applyProviderProfileFiles = dotenv.applyProviderProfileFiles;
pub const loadActiveProviderConfig = dotenv.loadActiveProviderConfig;

// Resolvers re-exports
pub const BackendSettings = resolvers.BackendSettings;
pub const resolveBackendSettings = resolvers.resolveBackendSettings;
pub const MemActSettings = resolvers.MemActSettings;
pub const resolveMemActSettings = resolvers.resolveMemActSettings;
pub const LoopAndExecutionSettings = resolvers.LoopAndExecutionSettings;
pub const resolveLoopAndExecutionSettings = resolvers.resolveLoopAndExecutionSettings;
pub const ReasoningAndMediaSettings = resolvers.ReasoningAndMediaSettings;
pub const resolveReasoningAndMediaSettings = resolvers.resolveReasoningAndMediaSettings;
pub const PlanningAndWatchdogSettings = resolvers.PlanningAndWatchdogSettings;
pub const resolvePlanningAndWatchdogSettings = resolvers.resolvePlanningAndWatchdogSettings;
pub const printConfigDiagnostics = resolvers.printConfigDiagnostics;

test "JsonConfig parsing" {
    const alloc = std.testing.allocator;
    const json_str =
        \\{
        \\  "execution_mode": "codeact",
        \\  "openai_protocol": "responses",
        \\  "openai_compat_model": "gpt-4o",
        \\  "max_tokens": 4096,
        \\  "memact_enabled": true,
        \\  "memact_pg_enabled": true
        \\}
    ;

    var parsed = try std.json.parseFromSlice(JsonConfig, alloc, json_str, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("codeact", parsed.value.execution_mode.?);
    try std.testing.expectEqualStrings("responses", parsed.value.openai_protocol.?);
    try std.testing.expectEqualStrings("gpt-4o", parsed.value.openai_compat_model.?);
    try std.testing.expectEqual(4096, parsed.value.max_tokens.?);
    try std.testing.expectEqual(true, parsed.value.memact_enabled.?);
    try std.testing.expectEqual(true, parsed.value.memact_pg_enabled.?);
}

test "JsonConfig parsing RFC-019 planning fields" {
    const alloc = std.testing.allocator;
    const json_str =
        \\{
        \\  "enable_structured_planning": true,
        \\  "plan_drift_detection": true,
        \\  "plan_max_steps": 15,
        \\  "plans_dir": "/tmp/custom_plans",
        \\  "prompt_enforcement_enabled": false
        \\}
    ;

    var parsed = try std.json.parseFromSlice(JsonConfig, alloc, json_str, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expectEqual(true, parsed.value.enable_structured_planning.?);
    try std.testing.expectEqual(true, parsed.value.plan_drift_detection.?);
    try std.testing.expectEqual(@as(usize, 15), parsed.value.plan_max_steps.?);
    try std.testing.expectEqualStrings("/tmp/custom_plans", parsed.value.plans_dir.?);
    try std.testing.expectEqual(false, parsed.value.prompt_enforcement_enabled.?);
}

test "Config prompt enforcement is disabled by default" {
    const alloc = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(alloc);
    defer env_map.deinit();

    const settings = Config.resolvePlanningAndWatchdogSettings(&env_map);
    try std.testing.expectEqual(false, settings.prompt_enforcement_enabled);

    try env_map.put("MINI_PROMPT_ENFORCEMENT_ENABLED", "1");
    const enabled = Config.resolvePlanningAndWatchdogSettings(&env_map);
    try std.testing.expectEqual(true, enabled.prompt_enforcement_enabled);
}

test "Config default memact_pg_enabled is true" {
    const alloc = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(alloc);
    defer env_map.deinit();

    const def_val: bool = blk: {
        const s = env_map.get("MINI_MEMACT_PG_ENABLED") orelse env_map.get("MINI_PG_ENABLED") orelse "1";
        break :blk std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "true");
    };
    try std.testing.expect(def_val);

    try env_map.put("MINI_MEMACT_PG_ENABLED", "0");
    const disabled_val: bool = blk: {
        const s = env_map.get("MINI_MEMACT_PG_ENABLED") orelse env_map.get("MINI_PG_ENABLED") orelse "1";
        break :blk std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "true");
    };
    try std.testing.expect(!disabled_val);
}

test {
    _ = types;
    _ = workspace;
    _ = dotenv;
    _ = resolvers;
}
