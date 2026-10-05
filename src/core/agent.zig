//! agent.zig — AgentLoop facade for mini-agent.
//!
//! Refactored into modular sub-package under `core/agent/`:
//!   - `agent/loop.zig`         — AgentLoop main loop, state, lifecycle, and listeners
//!   - `agent/backend.zig`      — Backend initialization and protocol negotiation
//!   - `agent/folder.zig`       — Manage the `.agent/` directory in the workspace
//!   - `agent/loop_monitor.zig` — Loop monitoring, orbit detection, tool cache
//!   - `agent/parsing.zig`      — Response/text parsing utilities (CodeAct JS, XML tool tags, timeout decisions)
//!   - `agent/step.zig`         — Single-step execution logic (executeStep)
//!   - `agent/turn.zig`         — Turn execution logic (executeTurnWorker)
//!   - `agent/execution.zig`    — Tool execution pipeline, dedupe caching, and plan tracking
//!   - `agent/subagent.zig`     — Subagent runner and plan dispatch orchestration
//!
//! This file maintains 100% backward compatibility for all existing imports.

const root = @import("agent/root.zig");

// Submodules
pub const loop = root.loop;
pub const backend = root.backend;
pub const folder = root.folder;
pub const loop_monitor = root.loop_monitor;
pub const parsing = root.parsing;
pub const step = root.step;
pub const turn = root.turn;
pub const execution = root.execution;
pub const subagent = root.subagent;

// Core types & lifecycle
pub const AgentLoop = root.AgentLoop;
pub const Backend = root.Backend;
pub const AgentFolder = root.AgentFolder;
pub const resolveOrInitAgentFolder = root.resolveOrInitAgentFolder;
pub const g_agent_mutex = root.g_agent_mutex;
pub const skillNameFromSkillPath = root.skillNameFromSkillPath;
pub const activateTurnHooks = root.activateTurnHooks;
pub const deactivateTurnHooks = root.deactivateTurnHooks;

// Re-exported modules
pub const journal_mod = root.journal_mod;
pub const act_logger_mod = root.act_logger_mod;
pub const signals = root.signals;
pub const act_queue = root.act_queue;
pub const watchdog_mod = root.watchdog_mod;

// Parsing helpers
pub const extractJsCodeBlock = root.extractJsCodeBlock;
pub const convertXmlToolTagsToJs = root.convertXmlToolTagsToJs;
pub const findJsCodeInResponse = root.findJsCodeInResponse;
pub const parseTimeoutDecision = root.parseTimeoutDecision;

// Loop monitor helpers
pub const isReadOnlyTool = root.isReadOnlyTool;
pub const isMutatingTool = root.isMutatingTool;
pub const isExploratoryToolCall = root.isExploratoryToolCall;
pub const MacroCycle = root.MacroCycle;
pub const detectMacroCycle = root.detectMacroCycle;
pub const checkActionLoop = root.checkActionLoop;
pub const clearTurnToolRecords = root.clearTurnToolRecords;
pub const deinitTurnToolRecords = root.deinitTurnToolRecords;
pub const clearToolCache = root.clearToolCache;
pub const fuzzyArgsHash = root.fuzzyArgsHash;
pub const lookupToolCache = root.lookupToolCache;
pub const storeToolCache = root.storeToolCache;
pub const hasRecentVerifiedMutation = root.hasRecentVerifiedMutation;

// Step & Turn helpers
pub const StepResult = root.StepResult;
pub const GuidanceProgressContext = root.GuidanceProgressContext;
pub const executeStep = root.executeStep;

pub const nextActAttempt = root.nextActAttempt;
pub const MAX_RATE_LIMIT_RETRIES = root.MAX_RATE_LIMIT_RETRIES;
pub const RATE_LIMIT_BASE_DELAY_S = root.RATE_LIMIT_BASE_DELAY_S;
pub const RATE_LIMIT_MAX_BACKOFF_S = root.RATE_LIMIT_MAX_BACKOFF_S;
pub const TurnWorkerContext = root.TurnWorkerContext;
pub const turnWorkerThreadEntry = root.turnWorkerThreadEntry;
pub const ActErrorResolution = root.ActErrorResolution;
pub const executeTurnWorker = root.executeTurnWorker;

// Execution helpers
pub const ToolExecSummary = root.ToolExecSummary;
pub const closeOrphanedToolUses = root.closeOrphanedToolUses;
pub const executeTools = root.executeTools;

// Subagent helpers
pub const subagentRunner = root.subagentRunner;
pub const batchSubagentRunner = root.batchSubagentRunner;
pub const maybeDispatchPlanStep = root.maybeDispatchPlanStep;
pub const maybeBatchPlanStep = root.maybeBatchPlanStep;

test {
    _ = root;
}
