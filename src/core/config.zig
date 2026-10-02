//! config.zig — Configuration facade for mini-agent.
//!
//! Refactored into modular sub-package under `core/config/`:
//!   - `config/types.zig`      — ExecutionMode, OpenAiProtocol, Config, JsonConfig, JsonProviderConfig
//!   - `config/workspace.zig`  — Workspace discovery, marker detection, AGENTS.md rules, system prompt
//!   - `config/dotenv.zig`     — .env and config.json loading, provider profiles, env mutation
//!   - `config/resolvers.zig`  — Category resolvers, diagnostics, and Config.load assembly
//!
//! This file maintains 100% backward compatibility for all existing imports.

const root = @import("config/root.zig");

// Submodules
pub const types = root.types;
pub const workspace = root.workspace;
pub const dotenv = root.dotenv;
pub const resolvers = root.resolvers;

// Types re-exports
pub const ExecutionMode = root.ExecutionMode;
pub const OpenAiProtocol = root.OpenAiProtocol;
pub const Config = root.Config;
pub const JsonConfig = root.JsonConfig;
pub const JsonProviderConfig = root.JsonProviderConfig;
pub const skills_mod = root.skills_mod;

// Workspace & prompt re-exports
pub const resolveWorkspaceRoot = root.resolveWorkspaceRoot;
pub const resolveWorkspaceRootAndName = root.resolveWorkspaceRootAndName;
pub const WorkspaceMarker = root.WorkspaceMarker;
pub const WORKSPACE_MARKERS = root.WORKSPACE_MARKERS;
pub const detectProjectTypes = root.detectProjectTypes;
pub const detectGitBranch = root.detectGitBranch;
pub const isIgnoredWorkspaceEntry = root.isIgnoredWorkspaceEntry;
pub const collectWorkspaceEntries = root.collectWorkspaceEntries;
pub const formatWorkspaceContext = root.formatWorkspaceContext;
pub const buildWorkspaceContext = root.buildWorkspaceContext;
pub const SpResult = root.SpResult;
pub const loadBaseSystemPrompt = root.loadBaseSystemPrompt;
pub const injectWorkspaceContext = root.injectWorkspaceContext;
pub const appendAgentRuleFile = root.appendAgentRuleFile;
pub const collectAgentRules = root.collectAgentRules;
pub const readAgentFile = root.readAgentFile;
pub const appendSkillsBlock = root.appendSkillsBlock;
pub const loadSystemPrompt = root.loadSystemPrompt;

// DotEnv & provider profile re-exports
pub const loadDotEnvFiles = root.loadDotEnvFiles;
pub const loadJsonConfigFiles = root.loadJsonConfigFiles;
pub const loadDotEnv = root.loadDotEnv;
pub const setEnvInt = root.setEnvInt;
pub const setEnvFloat = root.setEnvFloat;
pub const setEnvBool = root.setEnvBool;
pub const setEnvDefault = root.setEnvDefault;
pub const tryLoadFile = root.tryLoadFile;
pub const tryLoadJsonConfig = root.tryLoadJsonConfig;
pub const tryLoadProviderJson = root.tryLoadProviderJson;
pub const detectActiveProviderKey = root.detectActiveProviderKey;
pub const resolveProvidersDir = root.resolveProvidersDir;
pub const applyProviderProfileFiles = root.applyProviderProfileFiles;
pub const loadActiveProviderConfig = root.loadActiveProviderConfig;

// Resolvers re-exports
pub const BackendSettings = root.BackendSettings;
pub const resolveBackendSettings = root.resolveBackendSettings;
pub const MemActSettings = root.MemActSettings;
pub const resolveMemActSettings = root.resolveMemActSettings;
pub const LoopAndExecutionSettings = root.LoopAndExecutionSettings;
pub const resolveLoopAndExecutionSettings = root.resolveLoopAndExecutionSettings;
pub const ReasoningAndMediaSettings = root.ReasoningAndMediaSettings;
pub const resolveReasoningAndMediaSettings = root.resolveReasoningAndMediaSettings;
pub const PlanningAndWatchdogSettings = root.PlanningAndWatchdogSettings;
pub const resolvePlanningAndWatchdogSettings = root.resolvePlanningAndWatchdogSettings;
pub const printConfigDiagnostics = root.printConfigDiagnostics;

test {
    _ = root;
}
