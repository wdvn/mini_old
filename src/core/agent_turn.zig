//! agent_turn.zig — Backward-compatibility forwarder for `core/agent/turn.zig`.

const turn = @import("agent/turn.zig");
pub const nextActAttempt = turn.nextActAttempt;
pub const MAX_RATE_LIMIT_RETRIES = turn.MAX_RATE_LIMIT_RETRIES;
pub const RATE_LIMIT_BASE_DELAY_S = turn.RATE_LIMIT_BASE_DELAY_S;
pub const RATE_LIMIT_MAX_BACKOFF_S = turn.RATE_LIMIT_MAX_BACKOFF_S;
pub const TurnWorkerContext = turn.TurnWorkerContext;
pub const turnWorkerThreadEntry = turn.turnWorkerThreadEntry;
pub const ActErrorResolution = turn.ActErrorResolution;
pub const executeTurnWorker = turn.executeTurnWorker;
