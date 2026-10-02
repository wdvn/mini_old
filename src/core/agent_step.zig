//! agent_step.zig — Backward-compatibility forwarder for `core/agent/step.zig`.

const step = @import("agent/step.zig");
pub const StepResult = step.StepResult;
pub const GuidanceProgressContext = step.GuidanceProgressContext;
pub const executeStep = step.executeStep;
