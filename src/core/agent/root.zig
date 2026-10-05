//! core/agent/root.zig — Modular agent package root for mini-agent.
//!
//! Submodules:
//!   - `loop`: AgentLoop main loop, state, and lifecycle.
//!   - `backend`: Backend initialization and protocol negotiation for AgentLoop.
//!   - `folder`: Manage the `.agent/` directory in the workspace (RFC-005).
//!   - `loop_monitor`: Loop monitoring and orbit detection for AgentLoop.
//!   - `parsing`: Response/text parsing utilities (CodeAct JS, XML tool tags, timeout decisions).
//!   - `step`: Single-step execution logic (executeStep).
//!   - `turn`: Turn execution logic (executeTurnWorker).
//!   - `execution`: Tool execution pipeline, caching, and plan tracking.
//!   - `subagent`: Subagent runner and plan dispatch orchestration.

pub const loop = @import("loop.zig");
pub const backend = @import("backend.zig");
pub const folder = @import("folder.zig");
pub const loop_monitor = @import("loop_monitor.zig");
pub const parsing = @import("parsing.zig");
pub const step = @import("step.zig");
pub const turn = @import("turn.zig");
pub const execution = @import("execution.zig");
pub const subagent = @import("subagent.zig");

// Re-export core types and functions
pub const AgentLoop = loop.AgentLoop;
pub const Backend = backend.Backend;
pub const AgentFolder = folder.AgentFolder;
pub const resolveOrInitAgentFolder = folder.resolveOrInitAgentFolder;
pub const g_agent_mutex = &loop.g_agent_mutex;
pub const skillNameFromSkillPath = loop.skillNameFromSkillPath;
pub const activateTurnHooks = loop.activateTurnHooks;
pub const deactivateTurnHooks = loop.deactivateTurnHooks;

// Re-exported modules from loop
pub const journal_mod = loop.journal_mod;
pub const act_logger_mod = loop.act_logger_mod;
pub const signals = loop.signals;
pub const act_queue = loop.act_queue;
pub const watchdog_mod = loop.watchdog_mod;

// Parsing helpers
pub const extractJsCodeBlock = parsing.extractJsCodeBlock;
pub const convertXmlToolTagsToJs = parsing.convertXmlToolTagsToJs;
pub const findJsCodeInResponse = parsing.findJsCodeInResponse;
pub const parseTimeoutDecision = parsing.parseTimeoutDecision;

// Loop monitor helpers
pub const isReadOnlyTool = loop_monitor.isReadOnlyTool;
pub const isMutatingTool = loop_monitor.isMutatingTool;
pub const isExploratoryToolCall = loop_monitor.isExploratoryToolCall;
pub const MacroCycle = loop_monitor.MacroCycle;
pub const detectMacroCycle = loop_monitor.detectMacroCycle;
pub const checkActionLoop = loop_monitor.checkActionLoop;
pub const clearTurnToolRecords = loop_monitor.clearTurnToolRecords;
pub const deinitTurnToolRecords = loop_monitor.deinitTurnToolRecords;
pub const clearToolCache = loop_monitor.clearToolCache;
pub const fuzzyArgsHash = loop_monitor.fuzzyArgsHash;
pub const lookupToolCache = loop_monitor.lookupToolCache;
pub const storeToolCache = loop_monitor.storeToolCache;
pub const hasRecentVerifiedMutation = loop_monitor.hasRecentVerifiedMutation;

// Step & Turn helpers
pub const StepResult = step.StepResult;
pub const GuidanceProgressContext = step.GuidanceProgressContext;
pub const executeStep = step.executeStep;

pub const nextActAttempt = turn.nextActAttempt;
pub const MAX_RATE_LIMIT_RETRIES = turn.MAX_RATE_LIMIT_RETRIES;
pub const RATE_LIMIT_BASE_DELAY_S = turn.RATE_LIMIT_BASE_DELAY_S;
pub const RATE_LIMIT_MAX_BACKOFF_S = turn.RATE_LIMIT_MAX_BACKOFF_S;
pub const TurnWorkerContext = turn.TurnWorkerContext;
pub const turnWorkerThreadEntry = turn.turnWorkerThreadEntry;
pub const ActErrorResolution = turn.ActErrorResolution;
pub const executeTurnWorker = turn.executeTurnWorker;

// Execution helpers
pub const ToolExecSummary = execution.ToolExecSummary;
pub const closeOrphanedToolUses = execution.closeOrphanedToolUses;
pub const executeTools = execution.executeTools;

// Subagent helpers
pub const subagentRunner = subagent.subagentRunner;
pub const batchSubagentRunner = subagent.batchSubagentRunner;
pub const maybeDispatchPlanStep = subagent.maybeDispatchPlanStep;
pub const maybeBatchPlanStep = subagent.maybeBatchPlanStep;

test {
    _ = loop;
    _ = backend;
    _ = folder;
    _ = loop_monitor;
    _ = parsing;
    _ = step;
    _ = turn;
    _ = execution;
    _ = subagent;
}
