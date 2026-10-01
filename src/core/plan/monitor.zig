//! core/plan/monitor.zig — Plan execution monitoring and drift detection (RFC-019)
//!
//! Detects when actual execution deviates from planned trajectory
//! and generates corrective guidance.
//!
//! ## Key Functions
//! - `checkPlanDrift` — checks if executed tool matches step expectation
//! - `calculateDriftScore` — computes normalized score (0.0 to 1.0)
//! - `generateDriftCorrection` — formats corrective guidance for LLM

const std = @import("std");
const Allocator = std.mem.Allocator;
const plan_mod = @import("types.zig");
const Plan = plan_mod.Plan;
const PlanStep = plan_mod.PlanStep;
const PlanDrift = plan_mod.PlanDrift;
const StepStatus = plan_mod.StepStatus;
const plan_executor = @import("executor.zig");
const utils = @import("../utils.zig");
const prompts_mod = @import("../prompts.zig");

// ---------------------------------------------------------------------------
// Drift Detection
// ---------------------------------------------------------------------------

// PSEUDOCODE:
// 1. Verify plan is non-empty and current_step_idx is in range
// 2. Fetch current step; if no tool_hint specified, return null (no drift possible)
// 3. Compare executed tool with step.tool_hint
// 4. If mismatched, calculate drift score (0.3 for same category, 0.8 for different)
// 5. Return PlanDrift struct

/// Check if executing a tool constitutes drift from the plan.
/// Returns null if no drift detected.
pub fn checkPlanDrift(
    plan: *const Plan,
    ctx: *const plan_executor.ExecutionContext,
    executed_tool: []const u8,
) ?PlanDrift {
    if (plan.steps.items.len == 0) return null;
    if (ctx.current_step_idx >= plan.steps.items.len) return null;

    const current_step = &plan.steps.items[ctx.current_step_idx];

    // No tool hint specified — cannot detect drift
    if (current_step.tool_hint == null) return null;

    if (!std.mem.eql(u8, executed_tool, current_step.tool_hint.?)) {
        const drift_score = calculateDriftScore(executed_tool, current_step.tool_hint.?);
        return PlanDrift{
            .step_id = current_step.id,
            .expected_tool = current_step.tool_hint,
            .actual_tool = executed_tool,
            .drift_score = drift_score,
        };
    }

    return null;
}

/// Check if skipping steps constitutes drift.
pub fn checkStepSkipping(
    plan: *const Plan,
    current_step_idx: usize,
    executed_tool: []const u8,
) ?PlanDrift {
    if (current_step_idx >= plan.steps.items.len) return null;

    for (plan.steps.items[current_step_idx..]) |*step| {
        if (step.status == .skipped) continue;
        if (step.status == .pending) {
            if (step.tool_hint != null and !std.mem.eql(u8, executed_tool, step.tool_hint.?)) {
                return PlanDrift{
                    .step_id = step.id,
                    .expected_tool = step.tool_hint,
                    .actual_tool = executed_tool,
                    .drift_score = 0.5,
                };
            }
        }
        break;
    }

    return null;
}

// PSEUDOCODE:
// 1. If actual equals expected, drift is 0.0
// 2. Classify both tools into categories (mutate, execute, explore, network)
// 3. If in same category, score = 0.3 (minor divergence)
// 4. If in different categories, score = 0.8 (major divergence)

/// Calculate drift score (0.0 to 1.0).
pub fn calculateDriftScore(actual: []const u8, expected: []const u8) f64 {
    if (std.mem.eql(u8, actual, expected)) return 0.0;

    const actual_cat = getToolCategory(actual);
    const expected_cat = getToolCategory(expected);

    if (actual_cat != null and expected_cat != null) {
        if (std.mem.eql(u8, actual_cat.?, expected_cat.?)) {
            return 0.3; // Low drift — same tool category
        }
    }

    return 0.8; // High drift — different category
}

/// Get tool category for drift scoring.
pub fn getToolCategory(tool: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, tool, "file_write") or
        std.mem.startsWith(u8, tool, "file_edit") or
        std.mem.startsWith(u8, tool, "edit") or
        std.mem.startsWith(u8, tool, "write"))
    {
        return "mutate";
    }
    if (std.mem.eql(u8, tool, "bash") or std.mem.startsWith(u8, tool, "sh")) {
        return "execute";
    }
    if (std.mem.startsWith(u8, tool, "file_read") or
        std.mem.startsWith(u8, tool, "grep") or
        std.mem.startsWith(u8, tool, "glob") or
        std.mem.startsWith(u8, tool, "read"))
    {
        return "explore";
    }
    if (std.mem.startsWith(u8, tool, "http") or std.mem.startsWith(u8, tool, "fetch")) {
        return "network";
    }
    return null;
}

// ---------------------------------------------------------------------------
// Drift Correction
// ---------------------------------------------------------------------------

// PSEUDOCODE:
// 1. Initialize BufWriter
// 2. Look up step by drift.step_id
// 3. Write drift header, step description, expected tool, actual tool
// 4. If drift > 0.7, add explicit warning and guidance to realign or update plan
// 5. Return owned slice

/// Generate drift correction message using canonical BufWriter.
pub fn generateDriftCorrection(
    plan: *const Plan,
    drift: PlanDrift,
    alloc: Allocator,
) ![]u8 {
    var bw = utils.BufWriter.init(alloc);
    errdefer bw.deinit();

    const current_step = plan_executor.findStepById(plan, drift.step_id);

    try bw.writeAll(prompts_mod.plan_drift_header);
    if (current_step) |cs| {
        try bw.print("Step: {s}\n", .{cs.description});
    }

    try bw.print("Expected tool: {s}\n", .{drift.expected_tool orelse "any"});
    try bw.print("Actual tool: {s}\n", .{drift.actual_tool});

    if (drift.drift_score > 0.7) {
        try bw.writeAll(prompts_mod.plan_drift_significant);
        if (drift.expected_tool) |et| {
            try bw.print(prompts_mod.plan_drift_significant_tool_fmt, .{et});
        }
    } else if (drift.drift_score > 0.3) {
        try bw.writeAll(prompts_mod.plan_drift_minor);
    } else {
        try bw.writeAll(prompts_mod.plan_drift_trivial);
    }

    return try bw.toOwnedSlice();
}

/// Alias for generateDriftCorrection.
pub const injectDriftCorrection = generateDriftCorrection;

/// Generate step enforcement message (when model returns text without tool call).
pub fn generateStepEnforcement(
    plan: *const Plan,
    current_step_idx: usize,
    steps_completed: usize,
    alloc: Allocator,
) ![]u8 {
    if (current_step_idx >= plan.steps.items.len) return try alloc.dupe(u8, "");
    const current = &plan.steps.items[current_step_idx];

    var bw = utils.BufWriter.init(alloc);
    errdefer bw.deinit();

    try bw.writeAll(prompts_mod.plan_step_enforcement_head);
    try bw.print("Step {d}/{d}: {s}\n", .{ steps_completed + 1, plan.stepCount(), current.description });
    try bw.writeAll("Status: active (waiting for execution)\n");

    if (current.tool_hint) |hint| {
        try bw.print(prompts_mod.plan_step_required_tool_fmt, .{hint});
    }

    try bw.writeAll(prompts_mod.plan_step_enforcement_directive);
    return try bw.toOwnedSlice();
}

/// Generate re-plan suggestion when drift is excessive.
pub fn generateReplanSuggestion(
    plan: *const Plan,
    steps_completed: usize,
    drift_score: f64,
    alloc: Allocator,
) ![]u8 {
    var bw = utils.BufWriter.init(alloc);
    errdefer bw.deinit();

    try bw.print(prompts_mod.plan_replan_suggestion_fmt, .{ steps_completed, plan.stepCount(), drift_score });

    return try bw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "checkPlanDrift - no drift" {
    const alloc = std.testing.allocator;

    var plan = try Plan.init(alloc, "Test", 0x1234);
    defer plan.deinit(alloc);

    var step = try PlanStep.init(alloc, "Run tests", &.{}, "bash");
    defer step.deinit(alloc);
    try plan.addStep(alloc, step);

    var ctx = plan_executor.ExecutionContext{
        .current_step_idx = 0,
        .steps_completed = 0,
    };

    const drift = checkPlanDrift(&plan, &ctx, "bash");
    try std.testing.expect(drift == null);
}

test "checkPlanDrift - tool mismatch" {
    const alloc = std.testing.allocator;

    var plan = try Plan.init(alloc, "Test", 0x5678);
    defer plan.deinit(alloc);

    var step = try PlanStep.init(alloc, "Edit file", &.{}, "file_edit");
    defer step.deinit(alloc);
    try plan.addStep(alloc, step);

    var ctx = plan_executor.ExecutionContext{
        .current_step_idx = 0,
        .steps_completed = 0,
    };

    const drift = checkPlanDrift(&plan, &ctx, "bash");
    try std.testing.expect(drift != null);
    try std.testing.expectEqual(0.8, drift.?.drift_score);
}

test "generateDriftCorrection" {
    const alloc = std.testing.allocator;

    var plan = try Plan.init(alloc, "Test", 0x9ABC);
    defer plan.deinit(alloc);

    var step = try PlanStep.init(alloc, "Read config", &.{}, "file_read");
    defer step.deinit(alloc);
    try plan.addStep(alloc, step);

    const drift = PlanDrift{
        .step_id = step.id,
        .expected_tool = "file_read",
        .actual_tool = "bash",
        .drift_score = 0.8,
    };

    const msg = try generateDriftCorrection(&plan, drift, alloc);
    defer alloc.free(msg);

    try std.testing.expect(std.mem.indexOf(u8, msg, "Expected tool: file_read") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "Actual tool: bash") != null);
}
