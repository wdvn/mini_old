//! core/protocol/root.zig — Modular protocol package root for mini-agent.
//!
//! Submodules:
//!   - `types`: Role, Message, ContentBlock, ToolUse, ToolResultBlock, Usage, Tier.
//!   - `response`: GenerationStop, StopReason, Response, ResponseValidity, ModelResponse.
//!   - `decision`: StepOutcome, TurnOutcome, AgentDecision, classifyResponse, decideAgentAction.
//!   - `tools`: ToolDefinition, ToolResult.

pub const types = @import("types.zig");
pub const response = @import("response.zig");
pub const decision = @import("decision.zig");
pub const tools = @import("tools.zig");
pub const media = @import("../media_protocol.zig");

// Types
pub const Role = types.Role;
pub const ToolUse = types.ToolUse;
pub const ToolResultBlock = types.ToolResultBlock;
pub const ImageBlock = types.ImageBlock;
pub const ThinkingBlock = types.ThinkingBlock;
pub const ContentBlock = types.ContentBlock;
pub const Tier = types.Tier;
pub const Message = types.Message;
pub const Usage = types.Usage;

// Response
pub const GenerationStop = response.GenerationStop;
pub const StopReason = response.StopReason;
pub const MAX_RESPONSE_SNIPPET_LEN = response.MAX_RESPONSE_SNIPPET_LEN;
pub const boundedResponseSnippet = response.boundedResponseSnippet;
pub const toGenerationStop = response.toGenerationStop;
pub const ResponseValidity = response.ResponseValidity;
pub const ResponseDiagnostics = response.ResponseDiagnostics;
pub const ModelResponse = response.ModelResponse;
pub const Response = response.Response;

// Decision
pub const StepOutcome = decision.StepOutcome;
pub const TurnOutcome = decision.TurnOutcome;
pub const TurnResult = decision.TurnResult;
pub const AgentDecision = decision.AgentDecision;
pub const RecoveryClass = decision.RecoveryClass;
pub const RecoveryDecision = decision.RecoveryDecision;
pub const StallReason = decision.StallReason;
pub const FailureReason = decision.FailureReason;
pub const ActTransition = decision.ActTransition;
pub const ResponseRecoveryBudget = decision.ResponseRecoveryBudget;
pub const isExecutableToolUse = decision.isExecutableToolUse;
pub const isValidJsonObject = decision.isValidJsonObject;
pub const responseRecoveryClass = decision.responseRecoveryClass;
pub const classifyResponse = decision.classifyResponse;
pub const decideAgentAction = decision.decideAgentAction;
pub const decideAgentActionFromStopReason = decision.decideAgentActionFromStopReason;

// Tools
pub const ToolDefinition = tools.ToolDefinition;
pub const ToolResult = tools.ToolResult;

test {
    _ = types;
    _ = response;
    _ = decision;
    _ = tools;
    _ = media;
}

