//! agent_loop_monitor.zig — Backward-compatibility forwarder for `core/agent/loop_monitor.zig`.

const lm = @import("agent/loop_monitor.zig");
pub const isReadOnlyTool = lm.isReadOnlyTool;
pub const isMutatingTool = lm.isMutatingTool;
pub const isExploratoryToolCall = lm.isExploratoryToolCall;
pub const MacroCycle = lm.MacroCycle;
pub const detectMacroCycle = lm.detectMacroCycle;
pub const checkActionLoop = lm.checkActionLoop;
pub const clearTurnToolRecords = lm.clearTurnToolRecords;
pub const deinitTurnToolRecords = lm.deinitTurnToolRecords;
pub const clearToolCache = lm.clearToolCache;
pub const fuzzyArgsHash = lm.fuzzyArgsHash;
pub const lookupToolCache = lm.lookupToolCache;
pub const storeToolCache = lm.storeToolCache;
pub const hasRecentVerifiedMutation = lm.hasRecentVerifiedMutation;
