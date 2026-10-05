//! core/plan/root.zig — Modular plan package root for mini-agent.
//!
//! Submodules:
//!   - `types`: Plan data model, DAG dependencies, StepStatus, PlanPhase, StepVerification, PlanStep, Plan, PlanDrift.
//!   - `parser`: Dual-format JSON / Markdown checklist plan extraction.
//!   - `executor`: Step execution, dependency resolution, verification, and progress metrics.
//!   - `dispatch`: Parallel execution and subagent dispatch for plan execution.
//!   - `monitor`: Drift detection and soft-enforcement.
//!   - `store`: CAS-based plan persistence and restoration.
//!   - `integration`: Agent loop integration, PlanState, display rendering, and lifecycle orchestration.

pub const types = @import("types.zig");
pub const parser = @import("parser.zig");
pub const executor = @import("executor.zig");
pub const dispatch = @import("dispatch.zig");
pub const monitor = @import("monitor.zig");
pub const store = @import("store.zig");
pub const integration = @import("integration.zig");

// Re-export core types for ergonomic API (compatible with plan_mod)
pub const StepStatus = types.StepStatus;
pub const parseStepStatus = types.parseStepStatus;
pub const PlanPhase = types.PlanPhase;
pub const parsePlanPhase = types.parsePlanPhase;
pub const VerificationStatus = types.VerificationStatus;
pub const parseVerificationStatus = types.parseVerificationStatus;
pub const VerificationKind = types.VerificationKind;
pub const StepVerification = types.StepVerification;
pub const PlanStep = types.PlanStep;
pub const Plan = types.Plan;
pub const PlanDrift = types.PlanDrift;
pub const validateDAG = types.validateDAG;
pub const checkCycles = types.checkCycles;

test {
    _ = types;
    _ = parser;
    _ = executor;
    _ = dispatch;
    _ = monitor;
    _ = store;
    _ = integration;
}
