//! plan.zig — Structured Planning System
//!
//! Refactored into modular sub-package under `core/plan/`:
//!   - `plan/types.zig`       — StepStatus, PlanPhase, StepVerification, PlanStep, Plan, PlanDrift
//!   - `plan/parser.zig`      — Dual-format JSON/Markdown plan extraction
//!   - `plan/executor.zig`    — Step execution, verification, and lifecycle tracking
//!   - `plan/dispatch.zig`    — Subagent and parallel execution dispatch
//!   - `plan/monitor.zig`     — Drift detection and soft-enforcement
//!   - `plan/store.zig`       — Persistent plan storage & CAS integration
//!   - `plan/integration.zig` — Agent loop integration, PlanState, display rendering
//!
//! This file maintains 100% backward compatibility for all existing imports.

const root = @import("plan/root.zig");

pub const types = root.types;
pub const parser = root.parser;
pub const executor = root.executor;
pub const dispatch = root.dispatch;
pub const monitor = root.monitor;
pub const store = root.store;
pub const integration = root.integration;

// Types & methods
pub const StepStatus = root.StepStatus;
pub const parseStepStatus = root.parseStepStatus;
pub const PlanPhase = root.PlanPhase;
pub const parsePlanPhase = root.parsePlanPhase;
pub const VerificationStatus = root.VerificationStatus;
pub const parseVerificationStatus = root.parseVerificationStatus;
pub const VerificationKind = root.VerificationKind;
pub const StepVerification = root.StepVerification;
pub const PlanStep = root.PlanStep;
pub const Plan = root.Plan;
pub const PlanDrift = root.PlanDrift;
pub const validateDAG = root.validateDAG;
pub const checkCycles = root.checkCycles;

test {
    _ = root;
}
