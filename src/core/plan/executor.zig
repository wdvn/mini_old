//! core/plan/executor.zig — Execute plan steps with dependency resolution (RFC-019)
//!
//! Manages step execution lifecycle:
//! - Dependency resolution before step activation
//! - Step status tracking (pending → active → completed/failed/skipped)
//! - Progress tracking and metrics
//! - Guidance and progress summary generation using canonical BufWriter

const std = @import("std");
const Allocator = std.mem.Allocator;
const plan_mod = @import("types.zig");
const Plan = plan_mod.Plan;
const PlanStep = plan_mod.PlanStep;
const StepStatus = plan_mod.StepStatus;
const utils = @import("../utils.zig");

// ---------------------------------------------------------------------------
// Execution Context
// ---------------------------------------------------------------------------

/// Tracks execution state for a plan.
pub const ExecutionContext = struct {
    /// Current step index being executed.
    current_step_idx: usize = 0,
    /// Number of steps completed.
    steps_completed: usize = 0,
    /// Total acts consumed for current step.
    current_step_acts: usize = 0,
    /// Total acts consumed for entire plan.
    total_acts: usize = 0,
    /// Whether plan is complete.
    is_complete: bool = false,
};

// ---------------------------------------------------------------------------
// Step Execution
// ---------------------------------------------------------------------------

// PSEUDOCODE:
// 1. Verify step_idx is within bounds
// 2. Iterate through step.dependencies; verify each prerequisite is .completed or .skipped
// 3. If any dependency is unsatisfied, return error.DependenciesNotSatisfied
// 4. Mark step.status = .active, update ctx.current_step_idx and reset ctx.current_step_acts

/// Execute a specific plan step by index after verifying dependencies.
pub fn executePlanStep(plan: *Plan, ctx: *ExecutionContext, step_idx: usize) !void {
    if (step_idx >= plan.steps.items.len) {
        ctx.is_complete = true;
        return;
    }

    const step = &plan.steps.items[step_idx];

    // Verify dependencies
    for (step.dependencies) |dep_id| {
        const dep = findStepById(plan, dep_id);
        if (dep) |d| {
            if (d.status != .completed and d.status != .skipped) {
                return error.DependenciesNotSatisfied;
            }
        }
    }

    step.status = .active;
    ctx.current_step_idx = step_idx;
    ctx.current_step_acts = 0;
}

/// Execute next available pending/active plan step.
pub fn executeStep(plan: *Plan, ctx: *ExecutionContext) !void {
    const step_idx = plan.findActiveStepIndex() orelse {
        ctx.is_complete = true;
        return;
    };
    return executePlanStep(plan, ctx, step_idx);
}

// PSEUDOCODE:
// 1. Check bounds against current_step_idx
// 2. Set step.status = .completed and step.completed_at = utils.milliTimestamp()
// 3. Record actual_acts, increment ctx.steps_completed, update ctx.is_complete

/// Mark the active step as completed. Idempotent: a step that is already
/// completed/skipped (e.g. finished by a parallel batch dispatch) is a no-op,
/// so a later tool-hint act cannot double-count `steps_completed`.
pub fn completePlanStep(plan: *Plan, ctx: *ExecutionContext) void {
    if (ctx.current_step_idx >= plan.steps.items.len) return;

    const step = &plan.steps.items[ctx.current_step_idx];
    if (step.status == .completed or step.status == .skipped) return;
    step.status = .completed;
    step.completed_at = utils.milliTimestamp();
    step.actual_acts = ctx.current_step_acts;

    ctx.steps_completed += 1;
    ctx.is_complete = plan.isComplete();
}

/// Alias for completePlanStep.
pub const completeStep = completePlanStep;

/// Find the index of a step by ID, or null if not present.
pub fn findStepIndexById(plan: *const Plan, step_id: u64) ?usize {
    for (plan.steps.items, 0..) |s, i| {
        if (s.id == step_id) return i;
    }
    return null;
}

/// RFC-024 §3.4: idempotently complete the step at index `idx` (no-op when
/// already completed/skipped). Used by the parallel batch path, which
/// completes several independent steps in one act. Returns true when a
/// transition happened.
pub fn completeStepByIndex(plan: *Plan, ctx: *ExecutionContext, idx: usize) bool {
    if (idx >= plan.steps.items.len) return false;
    const step = &plan.steps.items[idx];
    if (step.status == .completed or step.status == .skipped) return false;

    step.status = .completed;
    step.completed_at = utils.milliTimestamp();
    step.actual_acts = ctx.current_step_acts;
    ctx.steps_completed += 1;
    ctx.is_complete = plan.isComplete();
    return true;
}

/// Mark a step as failed.
pub fn failStep(plan: *Plan, ctx: *ExecutionContext) void {
    if (ctx.current_step_idx >= plan.steps.items.len) return;

    const step = &plan.steps.items[ctx.current_step_idx];
    step.status = .failed;

    ctx.is_complete = false;
}

/// Skip a step (e.g., dependencies not met or alternative path taken).
pub fn skipStep(plan: *Plan, ctx: *ExecutionContext) void {
    if (ctx.current_step_idx >= plan.steps.items.len) return;

    const step = &plan.steps.items[ctx.current_step_idx];
    step.status = .skipped;

    ctx.steps_completed += 1;
    ctx.is_complete = plan.isComplete();
}

// ---------------------------------------------------------------------------
// Dependency Resolution
// ---------------------------------------------------------------------------

/// Check if a dependency step is satisfied (completed or skipped).
pub fn isDependencySatisfied(plan: *const Plan, dep_id: u64) bool {
    var i: usize = 0;
    while (i < plan.steps.items.len) {
        if (plan.steps.items[i].id == dep_id) {
            return plan.steps.items[i].status == .completed or plan.steps.items[i].status == .skipped;
        }
        i += 1;
    }
    return true;
}

/// Get all unsatisfied dependencies for a step.
pub fn getUnsatisfiedDependencies(plan: *const Plan, step_idx: usize, alloc: Allocator) ![]u64 {
    if (step_idx >= plan.steps.items.len) return &.{};
    const step = &plan.steps.items[step_idx];

    var unsatisfied = std.ArrayListUnmanaged(u64){};
    errdefer unsatisfied.deinit(alloc);

    for (step.dependencies) |dep_id| {
        if (!isDependencySatisfied(plan, dep_id)) {
            try unsatisfied.append(alloc, dep_id);
        }
    }

    return try unsatisfied.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Verification (RFC-024 §3.1)
// ---------------------------------------------------------------------------

/// Pluggable verification runner. Given a check kind + value, returns a
/// VerificationStatus. Injectable so tests can avoid real process/file IO.
pub const VerificationRunner = *const fn (
    io: std.Io,
    alloc: Allocator,
    kind: plan_mod.VerificationKind,
    value: []const u8,
) plan_mod.VerificationStatus;

const process_manager = @import("../../runtime/process_manager.zig");

/// Default runner: file_exists / file_contains use the local filesystem; shell
/// runs the command (parent-death-guarded) and reports .passed on exit 0.
pub fn defaultVerificationRunner(
    io: std.Io,
    alloc: Allocator,
    kind: plan_mod.VerificationKind,
    value: []const u8,
) plan_mod.VerificationStatus {
    switch (kind) {
        .file_exists => {
            const cwd = std.Io.Dir.cwd();
            return if (cwd.statFile(io, value, .{})) |_| .passed else |_| .failed;
        },
        .file_contains => {
            // value = "<path> <pattern>"
            const sp = std.mem.indexOfScalar(u8, value, ' ') orelse return .check_error;
            const path = value[0..sp];
            const pattern = value[sp + 1 ..];
            const cwd = std.Io.Dir.cwd();
            const file = cwd.openFile(io, path, .{}) catch return .failed;
            defer file.close(io);
            const stat = file.stat(io) catch return .failed;
            const buf = alloc.alloc(u8, @as(usize, @min(stat.size, 1 << 20))) catch return .check_error;
            defer alloc.free(buf);
            const read = utils.readAll(io, file, buf) catch return .check_error;
            return if (std.mem.indexOf(u8, buf[0..read], pattern) != null) .passed else .failed;
        },
        .shell => {
            var child = process_manager.spawnManaged(
                io,
                &.{ "sh", "-c", value },
                null,
                .ignore,
                .ignore,
                .ignore,
            ) catch return .check_error;
            const term = child.wait(io) catch return .check_error;
            return switch (term) {
                .exited => |code| if (code == 0) .passed else .failed,
                else => .check_error,
            };
        },
    }
}

// PSEUDOCODE:
// 1. Guard: no verification on current step -> .skipped (legacy)
// 2. Run the check via the provided runner
// 3. Record status on the step and return it (caller advances on .passed)

/// Run the current step's verification check and record its status. Returns
/// .skipped if the step has no verification (legacy tool_hint behavior stands).
pub fn verifyStep(
    io: std.Io,
    alloc: Allocator,
    plan: *Plan,
    ctx: *ExecutionContext,
    runner: VerificationRunner,
) plan_mod.VerificationStatus {
    const step = getCurrentStep(plan, ctx) orelse return .skipped;
    const step_mut = &plan.steps.items[ctx.current_step_idx];
    const verif = step.verification orelse {
        step_mut.verification_status = .skipped;
        return .skipped;
    };
    const status = runner(io, alloc, verif.kind, verif.value);
    step_mut.verification_status = status;
    return status;
}

/// RFC-024: count acts consumed toward the active step so `actual_acts`
/// accounting is maintained (was unwired; the counters were only ever reset).
pub fn bumpActCounters(ctx: *ExecutionContext) void {
    ctx.current_step_acts += 1;
    ctx.total_acts += 1;
}

/// RFC-024: execute the next ready step by dependency-aware ready-set, instead
/// of the sequential findActiveStepIndex scan. Falls back to .complete when no
/// ready step exists.
pub fn executeReadyStep(plan: *Plan, ctx: *ExecutionContext) !void {
    const idx = plan.findReadyStepIndex() orelse {
        ctx.is_complete = true;
        return;
    };
    return executePlanStep(plan, ctx, idx);
}

// ---------------------------------------------------------------------------
// Progress Tracking
// ---------------------------------------------------------------------------

/// Get progress percentage (0.0 to 1.0).
pub fn getProgressPercent(plan: *const Plan, ctx: *const ExecutionContext) f64 {
    if (plan.stepCount() == 0) return 0.0;
    return @as(f64, @floatFromInt(ctx.steps_completed)) / @as(f64, @floatFromInt(plan.stepCount()));
}

/// Get remaining steps count.
pub fn remainingSteps(plan: *const Plan, ctx: *const ExecutionContext) usize {
    if (ctx.is_complete) return 0;
    const count = plan.stepCount();
    if (ctx.steps_completed >= count) return 0;
    return count - ctx.steps_completed;
}

/// Get estimated remaining acts based on estimated_acts per step.
pub fn estimatedRemainingActs(plan: *const Plan, ctx: *const ExecutionContext) usize {
    if (ctx.is_complete) return 0;

    var remaining: usize = 0;
    var i: usize = ctx.steps_completed;
    while (i < plan.steps.items.len) {
        if (plan.steps.items[i].status != .completed and plan.steps.items[i].status != .skipped) {
            remaining += plan.steps.items[i].estimated_acts;
        }
        i += 1;
    }
    return remaining;
}

// ---------------------------------------------------------------------------
// Step Lookup
// ---------------------------------------------------------------------------

/// Find step by ID (const).
pub fn findStepById(plan: *const Plan, step_id: u64) ?*const PlanStep {
    var i: usize = 0;
    while (i < plan.steps.items.len) {
        if (plan.steps.items[i].id == step_id) return &plan.steps.items[i];
        i += 1;
    }
    return null;
}

/// Find mutable step by ID.
pub fn findStepByIdMut(plan: *Plan, step_id: u64) ?*PlanStep {
    var i: usize = 0;
    while (i < plan.steps.items.len) {
        if (plan.steps.items[i].id == step_id) return &plan.steps.items[i];
        i += 1;
    }
    return null;
}

/// Find active or pending step index.
pub fn findActiveStepIndex(plan: *const Plan) ?usize {
    return plan.findActiveStepIndex();
}

/// Get current step (if any).
pub fn getCurrentStep(plan: *const Plan, ctx: *const ExecutionContext) ?*const PlanStep {
    if (ctx.current_step_idx >= plan.steps.items.len) return null;
    return &plan.steps.items[ctx.current_step_idx];
}

// ---------------------------------------------------------------------------
// Guidance Generation
// ---------------------------------------------------------------------------

// PSEUDOCODE:
// 1. Initialize utils.BufWriter
// 2. Format step header: [Plan Step X/Y]: Description
// 3. Format preferred tool and dependencies if any
// 4. Return formatted string slice

/// Generate step-specific guidance message using canonical BufWriter.
pub fn generateStepGuidance(
    plan: *const Plan,
    ctx: *const ExecutionContext,
    alloc: Allocator,
) ![]u8 {
    const current = getCurrentStep(plan, ctx) orelse return "";

    var bw = utils.BufWriter.init(alloc);
    errdefer bw.deinit();

    try bw.print("[Plan Step {d}/{d}]: {s}\n", .{ ctx.steps_completed + 1, plan.stepCount(), current.description });

    if (current.tool_hint) |hint| {
        try bw.print("  Preferred tool: {s}\n", .{hint});
    }

    if (current.dependencies.len > 0) {
        try bw.writeAll("  Dependencies: ");
        for (current.dependencies, 0..) |dep_id, i| {
            if (i > 0) try bw.writeAll(", ");
            const dep = findStepById(plan, dep_id);
            if (dep) |d| {
                try bw.writeAll(d.description);
            } else {
                try bw.print("{d}", .{dep_id});
            }
        }
        try bw.writeByte('\n');
    }

    try bw.writeAll("Proceed to execution.\n");
    return try bw.toOwnedSlice();
}

/// Generate progress summary message using canonical BufWriter.
pub fn generateProgressSummary(
    plan: *const Plan,
    ctx: *const ExecutionContext,
    alloc: Allocator,
) ![]u8 {
    var bw = utils.BufWriter.init(alloc);
    errdefer bw.deinit();

    const percent = getProgressPercent(plan, ctx) * 100.0;
    try bw.print("[Plan Progress: Step {d}/{d} ({d:.0}%)]\n", .{ ctx.steps_completed, plan.stepCount(), percent });

    // Show completed steps
    for (plan.steps.items, 0..) |step, i| {
        if (step.status == .completed) {
            try bw.print("✓ Step {d}: {s}\n", .{ i + 1, step.description });
        }
    }

    // Show current step
    if (ctx.current_step_idx < plan.steps.items.len and !ctx.is_complete) {
        const current = &plan.steps.items[ctx.current_step_idx];
        try bw.print("→ Step {d}: {s} (active)\n", .{ ctx.current_step_idx + 1, current.description });

        if (current.tool_hint) |hint| {
            try bw.print("  Preferred tool: {s}\n", .{hint});
        }
    }

    // Show remaining
    const remaining = remainingSteps(plan, ctx);
    if (remaining > 0) {
        try bw.print("\nRemaining: {d} steps\n", .{remaining});
    }

    return try bw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "executeStep - basic execution" {
    const alloc = std.testing.allocator;

    var plan = try Plan.init(alloc, "Test plan", 0x1234);
    defer plan.deinit(alloc);

    var step1 = try PlanStep.initWithId(alloc, 1, "Step 1", &.{}, "file_read");
    defer step1.deinit(alloc);
    try plan.addStep(alloc, step1);

    var step2 = try PlanStep.initWithId(alloc, 2, "Step 2", &[_]u64{1}, "bash");
    defer step2.deinit(alloc);
    try plan.addStep(alloc, step2);

    var ctx = ExecutionContext{};

    // Execute first step
    try executeStep(&plan, &ctx);
    try std.testing.expectEqual(0, ctx.current_step_idx);
    try std.testing.expectEqual(StepStatus.active, plan.steps.items[0].status);

    // Complete first step
    completeStep(&plan, &ctx);
    try std.testing.expectEqual(StepStatus.completed, plan.steps.items[0].status);
    try std.testing.expectEqual(1, ctx.steps_completed);

    // Execute second step
    try executeStep(&plan, &ctx);
    try std.testing.expectEqual(1, ctx.current_step_idx);

    // Complete second step
    completeStep(&plan, &ctx);
    try std.testing.expect(ctx.is_complete);
}

test "executeStep - dependency not satisfied" {
    const alloc = std.testing.allocator;

    var plan = try Plan.init(alloc, "Test plan", 0x5678);
    defer plan.deinit(alloc);

    var step1 = try PlanStep.initWithId(alloc, 1, "Step 1", &.{}, null);
    defer step1.deinit(alloc);
    try plan.addStep(alloc, step1);

    var step2 = try PlanStep.initWithId(alloc, 2, "Step 2", &[_]u64{1}, null);
    defer step2.deinit(alloc);
    try plan.addStep(alloc, step2);

    var ctx = ExecutionContext{};

    // Try to execute step 2 directly without completing step 1
    const result = executePlanStep(&plan, &ctx, 1);
    try std.testing.expectError(error.DependenciesNotSatisfied, result);
}

test "getProgressPercent" {
    const alloc = std.testing.allocator;

    var plan = try Plan.init(alloc, "Test", 0x9ABC);
    defer plan.deinit(alloc);

    var i: usize = 0;
    while (i < 5) {
        var step = try PlanStep.initWithId(alloc, @as(u64, @intCast(i + 1)), "Step", &.{}, null);
        defer step.deinit(alloc);
        try plan.addStep(alloc, step);
        i += 1;
    }

    var ctx = ExecutionContext{};

    try std.testing.expectApproxEqAbs(0.0, getProgressPercent(&plan, &ctx), 0.01);

    completeStep(&plan, &ctx);
    try std.testing.expectApproxEqAbs(0.2, getProgressPercent(&plan, &ctx), 0.01);

    // RFC-024: completeStep is idempotent — repeating it on an already-
    // completed step is a no-op, so the runtime advances to the next step
    // before calling complete again.
    ctx.current_step_idx += 1;
    completeStep(&plan, &ctx);
    try std.testing.expectApproxEqAbs(0.4, getProgressPercent(&plan, &ctx), 0.01);

    // Repeat complete on the same step: idempotent no-op (progress unchanged).
    completeStep(&plan, &ctx);
    try std.testing.expectApproxEqAbs(0.4, getProgressPercent(&plan, &ctx), 0.01);
}
