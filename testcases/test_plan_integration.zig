//! test_plan_integration.zig — End-to-End Integration & Edge Cases for
//!
//! Validates:
//! 1. Full lifecycle: LLM plan extraction -> CAS storage -> execution -> drift monitoring -> completion
//! 2. Backward compatibility when structured planning is disabled
//! 3. Edge cases: empty plan, cyclic dependencies (DAG validation), unsatisfied dependency execution

const std = @import("std");
const mini = @import("mini");
const cas_mod = mini.cas_mod;
const CAS = cas_mod.CAS;
const plan_mod = mini.plan_mod;
const Plan = plan_mod.Plan;
const StepStatus = plan_mod.StepStatus;
const plan_parser = mini.plan_parser_mod;
const plan_executor = mini.plan_executor_mod;
const plan_monitor = mini.plan_monitor_mod;
const plan_store_mod = mini.plan_store_mod;
const PlanStore = plan_store_mod.PlanStore;

// PSEUDOCODE:
// 1. Prepare simulated LLM markdown output containing a 2-step structured plan
// 2. Call plan_parser.extractStructuredPlan to extract Plan struct
// 3. Initialize CAS and PlanStore in temp directories
// 4. Save initial Plan to PlanStore
// 5. Execute Step 1 (expecting glob):
//    - Simulate tool execution with "glob" -> verify checkPlanDrift is null
//    - Mark Step 1 completed
// 6. Execute Step 2 (expecting file_edit):
//    - Simulate tool execution with "bash" (drift!) -> checkPlanDrift returns PlanDrift
//    - Generate drift correction guidance
//    - Simulate agent realigning and executing "file_edit" -> checkPlanDrift is null
//    - Mark Step 2 completed
// 7. Verify plan.isComplete() is true
// 8. Save updated Plan to PlanStore and restore by request_hash
// 9. Verify restored plan has all steps completed

test "plan_integration: full plan execution and monitoring lifecycle" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const cas_dir = "/tmp/test_mini_plan_integ_cas";
    const plans_dir = "/tmp/test_mini_plan_integ_plans";

    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, cas_dir) catch {};
    cwd.deleteTree(io, plans_dir) catch {};
    defer {
        cwd.deleteTree(io, cas_dir) catch {};
        cwd.deleteTree(io, plans_dir) catch {};
    }

    var cas = try CAS.init(alloc, io, cas_dir);
    defer cas.deinit();

    var store = try PlanStore.init(alloc, io, &cas, plans_dir);
    defer store.deinit();

    const llm_response =
        \\I will execute the task according to the following plan:
        \\```json
        \\{
        \\  "task": "Migrate database configurations",
        \\  "steps": [
        \\    {"id": 1, "description": "Locate existing config files", "dependencies": [], "tool_hint": "glob"},
        \\    {"id": 2, "description": "Update connection string", "dependencies": [1], "tool_hint": "file_edit"}
        \\  ]
        \\}
        \\```
    ;

    var plan = (try plan_parser.extractStructuredPlan(llm_response, alloc)).?;
    defer plan.deinit(alloc);
    const req_hash: u64 = 0x9988_7766_5544_3322;
    plan.request_hash = req_hash;

    try std.testing.expectEqual(@as(usize, 2), plan.stepCount());

    // Save initial state to PlanStore
    try store.save(&plan);

    var ctx = plan_executor.ExecutionContext{};

    // --- Step 1: Locate existing config files (glob) ---
    try plan_executor.executeStep(&plan, &ctx);
    try std.testing.expectEqual(StepStatus.active, plan.steps.items[0].status);

    // Matching tool: no drift
    const drift_step1 = plan_monitor.checkPlanDrift(&plan, &ctx, "glob");
    try std.testing.expect(drift_step1 == null);

    // Complete Step 1
    plan_executor.completePlanStep(&plan, &ctx);
    try std.testing.expectEqual(StepStatus.completed, plan.steps.items[0].status);

    // --- Step 2: Update connection string (file_edit) ---
    try plan_executor.executeStep(&plan, &ctx);
    try std.testing.expectEqual(StepStatus.active, plan.steps.items[1].status);

    // Divergent tool executed: "bash" instead of "file_edit"
    const drift_step2 = plan_monitor.checkPlanDrift(&plan, &ctx, "bash");
    try std.testing.expect(drift_step2 != null);
    const correction = try plan_monitor.generateDriftCorrection(&plan, drift_step2.?, alloc);
    defer alloc.free(correction);
    try std.testing.expect(std.mem.indexOf(u8, correction, "[Plan Drift Detected]") != null);

    // Realigned tool executed: "file_edit"
    const realigned_drift = plan_monitor.checkPlanDrift(&plan, &ctx, "file_edit");
    try std.testing.expect(realigned_drift == null);

    // Complete Step 2
    plan_executor.completePlanStep(&plan, &ctx);
    try std.testing.expectEqual(StepStatus.completed, plan.steps.items[1].status);
    try std.testing.expect(plan.isComplete());

    // Update Plan in storage
    try store.save(&plan);

    // Restore and verify persistence
    var restored = (try store.restore(req_hash)).?;
    defer restored.deinit(alloc);

    try std.testing.expect(restored.isComplete());
    try std.testing.expectEqual(StepStatus.completed, restored.steps.items[0].status);
    try std.testing.expectEqual(StepStatus.completed, restored.steps.items[1].status);
}

// PSEUDOCODE:
// 1. Verify that a text with no plan syntax returns null from extractStructuredPlan
// 2. Verify an empty Plan struct behaves safely (stepCount = 0, isComplete = false)

test "plan_integration: backward compatibility and no-plan mode" {
    const alloc = std.testing.allocator;

    const normal_response = "I have checked the file contents and everything looks good.";
    const parsed = try plan_parser.extractStructuredPlan(normal_response, alloc);
    try std.testing.expect(parsed == null);

    var empty_plan = try Plan.init(alloc, "Empty task", 0);
    defer empty_plan.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), empty_plan.stepCount());
    try std.testing.expect(!empty_plan.isComplete());

    const ctx = plan_executor.ExecutionContext{};
    try std.testing.expectEqual(@as(usize, 0), plan_executor.remainingSteps(&empty_plan, &ctx));
}

// PSEUDOCODE:
// 1. Create a cycle: Step 1 depends on Step 2, and Step 2 depends on Step 1
// 2. Call plan_mod.checkCycles, verify it returns true (cycle detected)
// 3. Create a non-cyclic DAG: Step 1, Step 2 depends on 1, Step 3 depends on 2
// 4. Call plan_mod.checkCycles, verify it returns false (valid DAG)

test "plan_integration: edge case cycle detection and DAG validation" {
    const alloc = std.testing.allocator;

    var cyclic_plan = try Plan.init(alloc, "Cyclic Plan", 0);
    defer cyclic_plan.deinit(alloc);

    try cyclic_plan.addStepWithDetails(alloc, 1, "Step 1", &.{2}, "bash");
    try cyclic_plan.addStepWithDetails(alloc, 2, "Step 2", &.{1}, "bash");

    // Cycle check should flag cyclic dependencies
    try std.testing.expect(plan_mod.checkCycles(cyclic_plan.steps.items));

    var acyclic_plan = try Plan.init(alloc, "Valid DAG Plan", 0);
    defer acyclic_plan.deinit(alloc);

    try acyclic_plan.addStepWithDetails(alloc, 1, "Acyclic 1", &.{}, "file_read");
    try acyclic_plan.addStepWithDetails(alloc, 2, "Acyclic 2", &.{1}, "file_edit");
    try acyclic_plan.addStepWithDetails(alloc, 3, "Acyclic 3", &.{ 1, 2 }, "bash");

    try std.testing.expect(!plan_mod.checkCycles(acyclic_plan.steps.items));
    try std.testing.expect(plan_mod.validateDAG(acyclic_plan.steps.items));
}
