//! test_plan_store.zig — Unit tests for RFC-019 Plan Store & CAS persistence.
//!
//! Validates:
//! 1. Plan serialization and CAS hashing
//! 2. PlanMetadata recording and retrieval in metadata.jsonl
//! 3. Cross-turn plan restoration by request_hash
//! 4. Non-existent plan lookup returning null
//! 5. Resource cleanup without memory leaks

const std = @import("std");
const mini = @import("mini");
const cas_mod = mini.cas_mod;
const CAS = cas_mod.CAS;
const plan_store_mod = mini.plan_store_mod;
const PlanStore = plan_store_mod.PlanStore;
const plan_mod = mini.plan_mod;
const Plan = plan_mod.Plan;
const StepStatus = plan_mod.StepStatus;

// PSEUDOCODE:
// 1. Set up temporary test directories for CAS and Plans
// 2. Initialize CAS and PlanStore
// 3. Create a Plan with multiple steps, set a request_hash
// 4. Save the plan via plan_store.save(&plan)
// 5. Restore the plan via plan_store.restore(request_hash)
// 6. Verify restored fields match original
// 7. Verify readMetadata returns entry matching request_hash
// 8. Restore with unknown hash returns null
// 9. Clean up all resources and temp directories

test "plan_store: save and restore by request_hash" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const cas_dir = "/tmp/test_mini_plan_store_cas";
    const plans_dir = "/tmp/test_mini_plan_store_plans";

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

    const request_hash: u64 = 0xcafe_babe_1234_5678;

    var original_plan = try Plan.init(alloc, "Refactor database queries", request_hash);
    defer original_plan.deinit(alloc);

    try original_plan.addStepWithDetails(alloc, 1, "Profile slow queries", &.{}, "bash");
    try original_plan.addStepWithDetails(alloc, 2, "Add compound indexes", &.{1}, "file_edit");
    original_plan.steps.items[0].status = .completed;

    // Save plan
    try store.save(&original_plan);

    // Read metadata
    const metadata_list = try store.readMetadata();
    defer store.freeMetadata(metadata_list);

    try std.testing.expectEqual(@as(usize, 1), metadata_list.len);
    try std.testing.expectEqual(request_hash, metadata_list[0].request_hash);
    try std.testing.expectEqual(@as(usize, 2), metadata_list[0].steps_count);
    try std.testing.expectEqual(@as(usize, 1), metadata_list[0].steps_completed);

    // Restore plan
    const restored_opt = try store.restore(request_hash);
    try std.testing.expect(restored_opt != null);
    var restored = restored_opt.?;
    defer restored.deinit(alloc);

    try std.testing.expectEqualStrings("Refactor database queries", restored.task_description);
    try std.testing.expectEqual(@as(usize, 2), restored.stepCount());
    try std.testing.expectEqual(StepStatus.completed, restored.steps.items[0].status);
    try std.testing.expectEqual(StepStatus.pending, restored.steps.items[1].status);
    try std.testing.expectEqualStrings("bash", restored.steps.items[0].tool_hint.?);
    try std.testing.expectEqualStrings("file_edit", restored.steps.items[1].tool_hint.?);

    // Lookup non-existent hash returns null
    const missing = try store.restore(0xdead_beef_0000_0000);
    try std.testing.expect(missing == null);
}
