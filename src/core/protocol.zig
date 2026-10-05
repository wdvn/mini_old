//! protocol.zig — Shared data types for mini-agent.
//!
//! Refactored into modular sub-packages under `core/protocol/`:
//!   - `protocol/types.zig`    — Message, ContentBlock, ToolUse, Usage, Tier
//!   - `protocol/response.zig` — Response, GenerationStop, StopReason, ModelResponse
//!   - `protocol/decision.zig` — AgentDecision, TurnOutcome, classifyResponse, decideAgentAction
//!   - `protocol/tools.zig`    — ToolDefinition, ToolResult
//!
//! This file maintains 100% backward compatibility for all existing imports.

const root = @import("protocol/root.zig");

pub const types = root.types;
pub const response = root.response;
pub const decision = root.decision;
pub const tools = root.tools;
pub const media = root.media;

// Types
pub const Role = root.Role;
pub const ToolUse = root.ToolUse;
pub const ToolResultBlock = root.ToolResultBlock;
pub const ImageBlock = root.ImageBlock;
pub const ThinkingBlock = root.ThinkingBlock;
pub const ContentBlock = root.ContentBlock;
pub const Tier = root.Tier;
pub const Message = root.Message;
pub const Usage = root.Usage;

// Response
pub const GenerationStop = root.GenerationStop;
pub const StopReason = root.StopReason;
pub const MAX_RESPONSE_SNIPPET_LEN = root.MAX_RESPONSE_SNIPPET_LEN;
pub const boundedResponseSnippet = root.boundedResponseSnippet;
pub const toGenerationStop = root.toGenerationStop;
pub const ResponseValidity = root.ResponseValidity;
pub const ResponseDiagnostics = root.ResponseDiagnostics;
pub const ModelResponse = root.ModelResponse;
pub const Response = root.Response;

// Decision
pub const StepOutcome = root.StepOutcome;
pub const TurnOutcome = root.TurnOutcome;
pub const TurnResult = root.TurnResult;
pub const AgentDecision = root.AgentDecision;
pub const RecoveryClass = root.RecoveryClass;
pub const RecoveryDecision = root.RecoveryDecision;
pub const StallReason = root.StallReason;
pub const FailureReason = root.FailureReason;
pub const ActTransition = root.ActTransition;
pub const ResponseRecoveryBudget = root.ResponseRecoveryBudget;
pub const isExecutableToolUse = root.isExecutableToolUse;
pub const isValidJsonObject = root.isValidJsonObject;
pub const responseRecoveryClass = root.responseRecoveryClass;
pub const classifyResponse = root.classifyResponse;
pub const decideAgentAction = root.decideAgentAction;
pub const decideAgentActionFromStopReason = root.decideAgentActionFromStopReason;

// Tools
pub const ToolDefinition = root.ToolDefinition;
pub const ToolResult = root.ToolResult;

test {
    _ = root;
}
