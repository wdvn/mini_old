//! test_plan_monitor.zig — Unit tests for Plan Monitor & Drift Detection.
//!
//! Validates:
//! 1. Drift score calculation by tool category (identical, same category, different category)
//! 2. Plan drift checking against active step tool_hint
//! 3. Step skipping detection
//! 4. Corrective guidance and step enforcement formatting
//! 5. Replan suggestion generation

const std = @import("std");
const mini = @import("mini");
const plan_mod = mini.plan_mod;
const Plan = plan_mod.Plan;
const plan_executor = mini.plan_executor_mod;
const plan_monitor = mini.plan_monitor_mod;

// PSEUDOCODE:
// 1. Test calculateDriftScore with identical tool strings -> 0.0
// 2. Test calculateDriftScore with same category tools (e.g. file_edit and file_write) -> 0.3
// 3. Test calculateDriftScore with different category tools (e.g. bash and file_read) -> 0.8
// 4. Verify tool categories for mutate, execute, explore, network

test "plan_monitor: drift score calculation by category" {
    // Identical
    try std.testing.expectEqual(@as(f64, 0.0), plan_monitor.calculateDriftScore("bash", "bash"));
    try std.testing.expectEqual(@as(f64, 0.0), plan_monitor.calculateDriftScore("file_read", "file_read"));

    // Same category: mutate
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), plan_monitor.calculateDriftScore("file_edit", "file_write"), 0.001);

    // Same category: explore
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), plan_monitor.calculateDriftScore("grep", "file_read"), 0.001);

    // Different category: execute vs explore
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), plan_monitor.calculateDriftScore("bash", "file_read"), 0.001);

    // Different category: mutate vs network
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), plan_monitor.calculateDriftScore("file_edit", "http_request"), 0.001);
}

// PSEUDOCODE:
// 1. Initialize Plan with Step 1 expecting "file_read" and Step 2 expecting "file_edit"
// 2. Execute Step 1; when executed_tool is "file_read", checkPlanDrift returns null
// 3. When executed_tool is "bash", checkPlanDrift returns PlanDrift with drift_score 0.8
// 4. Generate drift correction message and verify contents

test "plan_monitor: drift detection and correction generation" {
    const alloc = std.testing.allocator;

    var plan = try Plan.init(alloc, "Drift Test", 0);
    defer plan.deinit(alloc);

    try plan.addStepWithDetails(alloc, 1, "Inspect package.json", &.{}, "file_read");
    try plan.addStepWithDetails(alloc, 2, "Update build script", &.{1}, "file_edit");

    var ctx = plan_executor.ExecutionContext{};
    try plan_executor.executeStep(&plan, &ctx);

    // Matching tool: no drift
    const no_drift = plan_monitor.checkPlanDrift(&plan, &ctx, "file_read");
    try std.testing.expect(no_drift == null);

    // Divergent tool: bash executed instead of file_read
    const drift = plan_monitor.checkPlanDrift(&plan, &ctx, "bash");
    try std.testing.expect(drift != null);
    const d = drift.?;
    try std.testing.expectEqual(@as(u64, 1), d.step_id);
    try std.testing.expectEqualStrings("file_read", d.expected_tool.?);
    try std.testing.expectEqualStrings("bash", d.actual_tool);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), d.drift_score, 0.001);

    // Generate drift correction text
    const correction = try plan_monitor.generateDriftCorrection(&plan, d, alloc);
    defer alloc.free(correction);

    try std.testing.expect(std.mem.indexOf(u8, correction, "[Plan Drift Detected]") != null);
    try std.testing.expect(std.mem.indexOf(u8, correction, "Inspect package.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, correction, "Expected tool: file_read") != null);
    try std.testing.expect(std.mem.indexOf(u8, correction, "Actual tool: bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, correction, "Significant deviation detected") != null);
}

// PSEUDOCODE:
// 1. Initialize Plan with an active step
// 2. Call generateStepEnforcement
// 3. Verify formatted output has step info and required tool hint
// 4. Call generateReplanSuggestion and verify guidance output

test "plan_monitor: step enforcement and replan suggestion" {
    const alloc = std.testing.allocator;

    var plan = try Plan.init(alloc, "Enforcement Test", 0);
    defer plan.deinit(alloc);

    try plan.addStepWithDetails(alloc, 5, "Execute test suite", &.{}, "bash");

    const enforcement = try plan_monitor.generateStepEnforcement(&plan, 0, 0, alloc);
    defer alloc.free(enforcement);

    try std.testing.expect(std.mem.indexOf(u8, enforcement, "[Plan Enforcement]") != null);
    try std.testing.expect(std.mem.indexOf(u8, enforcement, "Execute test suite") != null);
    try std.testing.expect(std.mem.indexOf(u8, enforcement, "Required tool: bash") != null);

    const replan = try plan_monitor.generateReplanSuggestion(&plan, 0, 0.8, alloc);
    defer alloc.free(replan);

    try std.testing.expect(std.mem.indexOf(u8, replan, "[Re-plan Required]") != null);
    try std.testing.expect(std.mem.indexOf(u8, replan, "deviated from the active plan") != null);
}
