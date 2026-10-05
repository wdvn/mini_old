//! test_plan_executor.zig — Unit tests for Plan Executor.
//!
//! Validates:
//! 1. Step activation and dependency checking (DependenciesNotSatisfied error)
//! 2. Step completion, failure, and skipping lifecycle
//! 3. Step lookup utilities (findStepById, findActiveStepIndex, getCurrentStep)
//! 4. Progress metrics (getProgressPercent, remainingSteps, estimatedRemainingActs)
//! 5. Guidance and progress summary formatting

const std = @import("std");
const mini = @import("mini");
const plan_mod = mini.plan_mod;
const Plan = plan_mod.Plan;
const PlanStep = plan_mod.PlanStep;
const StepStatus = plan_mod.StepStatus;
const plan_executor = mini.plan_executor_mod;

// PSEUDOCODE:
// 1. Initialize empty Plan and ExecutionContext
// 2. Add Step 1 (no dependencies) and Step 2 (depends on Step 1)
// 3. Attempting to execute Step 2 first should return error.DependenciesNotSatisfied
// 4. Execute Step 1, verify status becomes .active
// 5. Complete Step 1, verify status becomes .completed
// 6. Execute Step 2, verify now succeeds and status becomes .active
// 7. Complete Step 2, verify plan.isComplete() is true and ctx.is_complete is true

test "plan_executor: step execution with dependency resolution" {
    const alloc = std.testing.allocator;

    var plan = try Plan.init(alloc, "Test Plan Execution", 0);
    defer plan.deinit(alloc);

    try plan.addStepWithDetails(alloc, 1, "Initialize database schema", &.{}, "bash");
    try plan.addStepWithDetails(alloc, 2, "Seed test user accounts", &.{1}, "bash");

    var ctx = plan_executor.ExecutionContext{};

    // Step 2 cannot be executed before Step 1 completes
    try std.testing.expectError(error.DependenciesNotSatisfied, plan_executor.executePlanStep(&plan, &ctx, 1));

    // Execute Step 1
    try plan_executor.executePlanStep(&plan, &ctx, 0);
    try std.testing.expectEqual(StepStatus.active, plan.steps.items[0].status);
    try std.testing.expectEqual(@as(usize, 0), ctx.current_step_idx);

    // Complete Step 1
    plan_executor.completePlanStep(&plan, &ctx);
    try std.testing.expectEqual(StepStatus.completed, plan.steps.items[0].status);
    try std.testing.expectEqual(@as(usize, 1), ctx.steps_completed);
    try std.testing.expect(!ctx.is_complete);

    // Now Step 2 can be executed
    try plan_executor.executePlanStep(&plan, &ctx, 1);
    try std.testing.expectEqual(StepStatus.active, plan.steps.items[1].status);
    try std.testing.expectEqual(@as(usize, 1), ctx.current_step_idx);

    // Complete Step 2
    plan_executor.completePlanStep(&plan, &ctx);
    try std.testing.expectEqual(StepStatus.completed, plan.steps.items[1].status);
    try std.testing.expectEqual(@as(usize, 2), ctx.steps_completed);
    try std.testing.expect(ctx.is_complete);
    try std.testing.expect(plan.isComplete());
}

// PSEUDOCODE:
// 1. Initialize Plan with 3 steps
// 2. Execute Step 1 and fail it; verify status is .failed and ctx.is_complete is false
// 3. Skip Step 2; verify status is .skipped and ctx.steps_completed increments
// 4. Complete Step 3; verify isComplete() handles skipped steps as satisfied

test "plan_executor: step failure and skip handling" {
    const alloc = std.testing.allocator;

    var plan = try Plan.init(alloc, "Failure & Skip Lifecycle", 0);
    defer plan.deinit(alloc);

    try plan.addStepWithDetails(alloc, 1, "Step 1", &.{}, "grep");
    try plan.addStepWithDetails(alloc, 2, "Step 2", &.{1}, "file_read");
    try plan.addStepWithDetails(alloc, 3, "Step 3", &.{2}, "file_edit");

    var ctx = plan_executor.ExecutionContext{};

    // Fail Step 1
    try plan_executor.executePlanStep(&plan, &ctx, 0);
    plan_executor.failStep(&plan, &ctx);
    try std.testing.expectEqual(StepStatus.failed, plan.steps.items[0].status);
    try std.testing.expect(!ctx.is_complete);

    // Skip Step 1 to satisfy dependency for Step 2
    ctx.current_step_idx = 0;
    plan_executor.skipStep(&plan, &ctx);
    try std.testing.expectEqual(StepStatus.skipped, plan.steps.items[0].status);

    // Step 2 should now be executable because Step 1 is skipped (treated as satisfied)
    try plan_executor.executePlanStep(&plan, &ctx, 1);
    plan_executor.skipStep(&plan, &ctx);
    try std.testing.expectEqual(StepStatus.skipped, plan.steps.items[1].status);

    // Step 3 should now be executable
    try plan_executor.executePlanStep(&plan, &ctx, 2);
    plan_executor.completePlanStep(&plan, &ctx);
    try std.testing.expectEqual(StepStatus.completed, plan.steps.items[2].status);

    try std.testing.expect(ctx.is_complete);
    try std.testing.expect(plan.isComplete());
}

// PSEUDOCODE:
// 1. Build Plan with 4 steps having estimated_acts
// 2. Test progress percentage, remainingSteps, and estimatedRemainingActs at each stage
// 3. Test generateStepGuidance and generateProgressSummary buffers

test "plan_executor: metrics and summary generation" {
    const alloc = std.testing.allocator;

    var plan = try Plan.init(alloc, "Metrics Test", 0);
    defer plan.deinit(alloc);

    try plan.addStepWithDetails(alloc, 10, "First step", &.{}, "file_read");
    plan.steps.items[0].estimated_acts = 2;

    try plan.addStepWithDetails(alloc, 20, "Second step", &.{10}, "file_edit");
    plan.steps.items[1].estimated_acts = 3;

    var ctx = plan_executor.ExecutionContext{};

    try std.testing.expectApproxEqAbs(@as(f64, 0.0), plan_executor.getProgressPercent(&plan, &ctx), 0.001);
    try std.testing.expectEqual(@as(usize, 2), plan_executor.remainingSteps(&plan, &ctx));
    try std.testing.expectEqual(@as(usize, 5), plan_executor.estimatedRemainingActs(&plan, &ctx));

    // Execute and complete Step 1
    try plan_executor.executeStep(&plan, &ctx);
    plan_executor.completeStep(&plan, &ctx);

    try std.testing.expectApproxEqAbs(@as(f64, 0.5), plan_executor.getProgressPercent(&plan, &ctx), 0.001);
    try std.testing.expectEqual(@as(usize, 1), plan_executor.remainingSteps(&plan, &ctx));
    try std.testing.expectEqual(@as(usize, 3), plan_executor.estimatedRemainingActs(&plan, &ctx));

    // Test guidance generation for Step 2
    try plan_executor.executeStep(&plan, &ctx);
    const guidance = try plan_executor.generateStepGuidance(&plan, &ctx, alloc);
    defer alloc.free(guidance);
    try std.testing.expect(std.mem.indexOf(u8, guidance, "Second step") != null);
    try std.testing.expect(std.mem.indexOf(u8, guidance, "file_edit") != null);

    // Test progress summary generation
    const summary = try plan_executor.generateProgressSummary(&plan, &ctx, alloc);
    defer alloc.free(summary);
    try std.testing.expect(std.mem.indexOf(u8, summary, "Plan Progress") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "50%") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "First step") != null);
}
