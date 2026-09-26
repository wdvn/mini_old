//! plan_dispatch.zig — Step-scoped subagent orchestration (RFC-024 §3.4)
//!
//! Deterministic core for dispatching plan steps to subagents and running the
//! two-stage review gate. This module is dependency-free (no subagent/spawn
//! import) so it is unit-testable in isolation; the actual process spawn is
//! injected via a `SubagentRunner` function pointer, wired in `agent.zig`.
//!
//! ## Responsibilities
//! - `renderStepTask`: build a self-contained task string for one step.
//! - `findIndependentStepSet`: collect pending steps that can be auto-batched
//!   (no dependency edge between any two).
//! - `ReviewVerdict` + `parseReviewVerdict`: machine-readable two-stage verdict.

const std = @import("std");
const Allocator = std.mem.Allocator;
const plan_mod = @import("plan.zig");
const Plan = plan_mod.Plan;
const PlanStep = plan_mod.PlanStep;
const utils = @import("utils.zig");

// ---------------------------------------------------------------------------
// Subagent runner injection
// ---------------------------------------------------------------------------

/// Pluggable subagent runner. `task` is a self-contained prompt; returns the
/// subagent's final output string (caller owns via the same `alloc`).
/// `agent.zig` provides the real runner (wraps `subagent.executeTool`); tests
/// inject a fake.
pub const SubagentRunner = *const fn (
    io: std.Io,
    alloc: Allocator,
    task: []const u8,
) anyerror![]u8;

// ---------------------------------------------------------------------------
// Task rendering
// ---------------------------------------------------------------------------

/// Render a self-contained task string for a single plan step (RFC-024 §3.4):
/// step description, dependencies' descriptions, verification requirement,
/// and executor mode hint. The subagent receives no other context, so the
/// task must be self-sufficient.
pub fn renderStepTask(alloc: Allocator, plan: *const Plan, step: *const PlanStep) ![]u8 {
    var bw = utils.BufWriter.init(alloc);
    errdefer bw.deinit();

    try bw.print("[Plan Step {d}: {s}]\n", .{ step.id, step.description });

    if (step.dependencies.len > 0) {
        try bw.writeAll("Depends on (already completed) steps:\n");
        for (step.dependencies) |dep_id| {
            for (plan.steps.items) |dep| {
                if (dep.id == dep_id) {
                    try bw.print("  - {s}\n", .{dep.description});
                }
            }
        }
    }

    if (step.verification) |v| {
        try bw.print("Verification (must pass to complete): kind={s} value=\"{s}\"\n", .{
            @tagName(v.kind),
            v.value,
        });
    }

    if (step.tool_hint) |hint| {
        try bw.print("Preferred tool hint: {s}\n", .{hint});
    }

    try bw.writeAll("Complete the step above, run the verification, and report your outcome.\n");

    return try bw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Parallel batching
// ---------------------------------------------------------------------------

/// Pluggable batch subagent runner. Given a list of self-contained task
/// strings, returns the aggregate output (owned by `alloc`). Wired to
/// `batch_invoke_subagents` in `agent.zig`; tests inject a fake.
pub const BatchSubagentRunner = *const fn (
    io: std.Io,
    alloc: Allocator,
    tasks: []const []const u8,
) anyerror![]u8;

/// PSEUDOCODE:
/// 1. Render a self-contained task for each parallel step.
/// 2. Invoke the injected batch runner with all tasks in one dispatch.
/// 3. If a review gate is requested, run a single reviewer over the
///    aggregate output and parse the verdict (Critical blocks the whole batch).
/// 4. Return the dispatch outcome.

/// Dispatch a set of independent plan steps to parallel subagents in ONE
/// `batch_invoke_subagents` call. `step_ids` are the step IDs to batch.
pub fn dispatchParallelBatch(
    io: std.Io,
    alloc: Allocator,
    plan: *const Plan,
    step_ids: []const u64,
    runner: BatchSubagentRunner,
    review: bool,
) !DispatchOutcome {
    // PSEUDOCODE:
    // 1. For each step id, find the step and render its task string.
    // 2. Collect all task strings, call the batch runner once.
    // 3. If review is on, build a single review prompt with the aggregate output.
    var tasks = std.ArrayListUnmanaged([]u8).empty;
    defer {
        for (tasks.items) |t| alloc.free(t);
        tasks.deinit(alloc);
    }

    for (step_ids) |sid| {
        var found = false;
        for (plan.steps.items) |step| {
            if (step.id == sid) {
                const task = try renderStepTask(alloc, plan, &step);
                try tasks.append(alloc, task);
                found = true;
                break;
            }
        }
        if (!found) continue; // orphan step id: skip, don't abort the batch
    }

    if (tasks.items.len == 0) {
        return DispatchOutcome{
            .subagent_output = try alloc.dupe(u8, "[plan] no batchable steps found"),
            .verdict = .{ .critical = 0, .important = 0, .minor = 0 },
            .blocked = false,
        };
    }

    const output = try runner(io, alloc, tasks.items);
    errdefer alloc.free(output);

    var verdict = ReviewVerdict{ .critical = 0, .important = 0, .minor = 0 };
    var blocked = false;

    if (review) {
        // A single reviewer over the aggregate output of the whole batch.
        var review_bw = utils.BufWriter.init(alloc);
        defer review_bw.deinit();
        try review_bw.writeAll(
            "Review the following batch of parallel plan-step outputs. " ++
                "Each step was executed independently; check spec-compliance and code quality.\n\n",
        );
        for (step_ids, 0..) |sid, i| {
            for (plan.steps.items) |step| {
                if (step.id != sid) continue;
                try review_bw.print("## Step {d}: {s}\n", .{ sid, step.description });
                break;
            }
            _ = i;
        }
        try review_bw.writeAll("\nAggregate subagent output:\n");
        try review_bw.writeAll(output);
        try review_bw.writeAll(
            "\n\nEnd with a verdict block:\n" ++
                "SEVERITIES: critical=0 important=0 minor=0",
        );
        const review_task = try review_bw.toOwnedSlice();
        defer alloc.free(review_task);

        const review_result = runner2SingleStep(io, alloc, review_task, runner) catch "";
        verdict = parseReviewVerdict(review_result);
        blocked = verdict.blocks();
        if (review_result.len > 0) alloc.free(review_result);
    }

    return DispatchOutcome{
        .subagent_output = output,
        .verdict = verdict,
        .blocked = blocked,
    };
}

/// Batch review reuses the single-step runner interface to avoid a second
/// injected dependency; the review task is wrapped as a one-item task list.
fn runner2SingleStep(
    io: std.Io,
    alloc: Allocator,
    review_task: []const u8,
    runner: BatchSubagentRunner,
) ![]u8 {
    const one = [1][]const u8{ review_task };
    return runner(io, alloc, &one);
}
/// RFC-024 §3.4: collect the IDs of the pending, mutually-independent steps
/// that are eligible for `executor_mode: "parallel"`. A step is eligible when
/// it is pending, all of its dependencies are satisfied, and its executor_mode
/// is a parallel mode. Two eligible steps are mutually independent when
/// neither depends on the other; any pair sharing a dependency edge is dropped
/// (the dependent step cannot run in the same parallel batch).
///
/// PSEUDOCODE:
/// 1. Collect candidate indices: pending + parallel mode + all deps satisfied.
/// 2. For each candidate, if any other candidate depends on it (or vice versa),
///    drop it from the batch.
/// 3. Return the surviving step IDs as an owned u64 slice (free with `alloc.free`).
pub fn findParallelBatch(plan: *const Plan, alloc: Allocator) ![]u64 {
    var candidates = std.ArrayListUnmanaged(usize).empty;
    defer candidates.deinit(alloc);

    for (plan.steps.items, 0..) |step, i| {
        if (step.status != .pending) continue;
        if (!isParallelMode(step.executor_mode)) continue;
        if (!plan.allDependenciesSatisfied(&step)) continue;
        try candidates.append(alloc, i);
    }

    // Mark candidate indices that share a dependency edge with another candidate.
    var drop = std.AutoHashMap(usize, void).init(alloc);
    defer drop.deinit();
    for (candidates.items) |i| {
        const si = &plan.steps.items[i];
        for (candidates.items) |j| {
            if (i == j) continue;
            const sj = &plan.steps.items[j];
            if ((std.mem.indexOfScalar(u64, si.dependencies, sj.id) != null) or
                (std.mem.indexOfScalar(u64, sj.dependencies, si.id) != null))
            {
                try drop.put(i, {});
                break;
            }
        }
    }

    var ids = std.ArrayListUnmanaged(u64).empty;
    errdefer ids.deinit(alloc);
    for (candidates.items) |i| {
        if (drop.contains(i)) continue;
        try ids.append(alloc, plan.steps.items[i].id);
    }
    return try ids.toOwnedSlice(alloc);
}

/// Whether a step's executor_mode string requests parallel subagent dispatch.
pub fn isParallelMode(mode: ?[]const u8) bool {
    if (mode) |m| {
        return std.mem.startsWith(u8, m, "parallel");
    }
    return false;
}

// ---------------------------------------------------------------------------
// Review verdict (two-stage, RFC-024 §3.4)
// ---------------------------------------------------------------------------

/// Machine-readable outcome of the two-stage review gate.
pub const ReviewVerdict = struct {
    /// Count of Critical findings (blocks the step).
    critical: usize,
    /// Count of Important findings (advisory).
    important: usize,
    /// Count of Minor findings (informational).
    minor: usize,
    /// True when any Critical finding exists -> the step is failed.
    pub fn blocks(self: ReviewVerdict) bool {
        return self.critical > 0;
    }
};

/// Parse a reviewer subagent's output into a ReviewVerdict. The reviewer is
/// instructed to end with a verdict block:
///
///   REVISIONS REQUIRED: no   (or yes)
///   SEVERITIES: critical=0 important=1 minor=2
///
/// Unparseable output degrades to an all-zero verdict (no block), so a silent
/// reviewer cannot falsely fail a step.
pub fn parseReviewVerdict(text: []const u8) ReviewVerdict {
    var v = ReviewVerdict{ .critical = 0, .important = 0, .minor = 0 };
    if (std.mem.indexOf(u8, text, "critical=")) |ci| {
        v.critical = parseSeverityCount(text, ci) orelse 0;
    }
    if (std.mem.indexOf(u8, text, "important=")) |ii| {
        v.important = parseSeverityCount(text, ii) orelse 0;
    }
    if (std.mem.indexOf(u8, text, "minor=")) |mi| {
        v.minor = parseSeverityCount(text, mi) orelse 0;
    }
    return v;
}

/// Parse the integer after a "name=" marker within a bounded window.
fn parseSeverityCount(text: []const u8, marker_idx: usize) ?usize {
    // Find the following '=' (marker_idx points at the word start).
    const word_end = std.mem.indexOfScalar(u8, text[marker_idx..], '=') orelse return null;
    const num_start = marker_idx + word_end + 1;
    if (num_start >= text.len) return null;
    var num_end = num_start;
    while (num_end < text.len and (text[num_end] >= '0' and text[num_end] <= '9')) : (num_end += 1) {}
    if (num_end == num_start) return null;
    return std.fmt.parseInt(usize, text[num_start..num_end], 10) catch null;
}

// ---------------------------------------------------------------------------
// Dispatch entry point (injected runner)
// ---------------------------------------------------------------------------

/// PSEUDOCODE:
/// 1. Render the step's task string.
/// 2. Invoke the injected subagent runner with it.
/// 3. If a review gate is requested, run the reviewer and parse the verdict.
/// 4. Return the dispatch outcome (subagent output + verdict + blocked flag).
pub const DispatchOutcome = struct {
    subagent_output: []u8,
    verdict: ReviewVerdict,
    /// True when the review gate blocked the step (Critical finding).
    blocked: bool,
};

/// Dispatch a single step to a subagent and optionally run the review gate.
/// `review` when true embeds the `requesting-code-review` prompt in the
/// reviewer task; the verdict is parsed from its output.
pub fn dispatchStep(
    io: std.Io,
    alloc: Allocator,
    plan: *const Plan,
    step: *const PlanStep,
    runner: SubagentRunner,
    review: bool,
) !DispatchOutcome {
    const task = try renderStepTask(alloc, plan, step);
    defer alloc.free(task);

    const output = try runner(io, alloc, task);
    errdefer alloc.free(output);

    var verdict = ReviewVerdict{ .critical = 0, .important = 0, .minor = 0 };
    var blocked = false;

    if (review) {
        const verif_desc = try verificationDescription(alloc, step);
        defer alloc.free(verif_desc);
        const review_task = try std.fmt.allocPrint(alloc,
            \\Review the following plan-step output against the step specification.
            \\Step: "{s}"
            \\Verification requirement: {s}
            \\
            \\Reviewer output:
            \\{s}
            \\
            \\End with a verdict block:
            \\SEVERITIES: critical={d} important={d} minor={d}
        , .{
            step.description,
            verif_desc,
            output,
            0,
            0,
            0,
        });
        defer alloc.free(review_task);

        const review_result = runner(io, alloc, review_task) catch "";
        verdict = parseReviewVerdict(review_result);
        blocked = verdict.blocks();
        if (review_result.len > 0) alloc.free(review_result);
    }

    return DispatchOutcome{
        .subagent_output = output,
        .verdict = verdict,
        .blocked = blocked,
    };
}

/// Short owned description of a step's verification for the reviewer prompt.
fn verificationDescription(alloc: Allocator, step: *const PlanStep) ![]u8 {
    return if (step.verification) |v|
        try std.fmt.allocPrint(alloc, "present (kind={s})", .{@tagName(v.kind)})
    else
        try alloc.dupe(u8, "none");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "renderStepTask includes description, deps, verification" {
    const alloc = std.testing.allocator;
    var plan = try Plan.init(alloc, "Task", 0x1);
    defer plan.deinit(alloc);

    var s1 = try PlanStep.initWithId(alloc, 1, "Read config", &.{}, null);
    defer s1.deinit(alloc);
    try plan.addStep(alloc, s1);

    const ver_value = try alloc.dupe(u8, "zig build test");
    var s2 = try PlanStep.initWithId(alloc, 2, "Run tests", &[_]u64{1}, null);
    defer s2.deinit(alloc);
    s2.verification = plan_mod.StepVerification{ .kind = .shell, .value = ver_value };
    s2.executor_mode = try alloc.dupe(u8, "parallel");
    try plan.addStep(alloc, s2);

    const task = try renderStepTask(alloc, &plan, &s2);
    defer alloc.free(task);

    try std.testing.expect(std.mem.indexOf(u8, task, "Run tests") != null);
    try std.testing.expect(std.mem.indexOf(u8, task, "Read config") != null);
    try std.testing.expect(std.mem.indexOf(u8, task, "zig build test") != null);
}

/// Test helper: does batch (step-id strings) contain id?
fn batchContains(batch: []const u64, id: u64) bool {
    for (batch) |b| {
        if (b == id) return true;
    }
    return false;
}

test "findParallelBatch collects independent parallel steps only" {
    const alloc = std.testing.allocator;
    var plan = try Plan.init(alloc, "Task", 0x1);
    defer plan.deinit(alloc);

    // s1, s2: no deps, parallel -> both batchable, independent -> both in batch.
    var s1 = try PlanStep.initWithId(alloc, 1, "a", &.{}, "bash");
    defer s1.deinit(alloc);
    s1.executor_mode = try alloc.dupe(u8, "parallel");
    try plan.addStep(alloc, s1);

    var s2 = try PlanStep.initWithId(alloc, 2, "b", &.{}, "bash");
    defer s2.deinit(alloc);
    s2.executor_mode = try alloc.dupe(u8, "parallel");
    try plan.addStep(alloc, s2);

    // s3: parallel but depends on s1 -> excluded (mutually dependent with s1).
    var s3 = try PlanStep.initWithId(alloc, 3, "c", &[_]u64{1}, "bash");
    defer s3.deinit(alloc);
    s3.executor_mode = try alloc.dupe(u8, "parallel:2");
    try plan.addStep(alloc, s3);

    // s4: inline mode -> not eligible.
    var s4 = try PlanStep.initWithId(alloc, 4, "d", &.{}, "bash");
    defer s4.deinit(alloc);
    s4.executor_mode = try alloc.dupe(u8, "inline");
    try plan.addStep(alloc, s4);

    const batch = try findParallelBatch(&plan, alloc);
    defer alloc.free(batch);

    // Only s1 and s2 should be batchable.
    try std.testing.expectEqual(@as(usize, 2), batch.len);
    try std.testing.expect(batchContains(batch, 1));
    try std.testing.expect(batchContains(batch, 2));
    try std.testing.expect(!batchContains(batch, 3));
    try std.testing.expect(!batchContains(batch, 4));
}

test "parseReviewVerdict extracts severity counts" {
    const text =
        \\Review of step output.
        \\SEVERITIES: critical=1 important=2 minor=3
    ;
    const v = parseReviewVerdict(text);
    try std.testing.expectEqual(@as(usize, 1), v.critical);
    try std.testing.expectEqual(@as(usize, 2), v.important);
    try std.testing.expectEqual(@as(usize, 3), v.minor);
    try std.testing.expect(v.blocks());
}

test "parseReviewVerdict degrades to non-blocking on garbage" {
    const v = parseReviewVerdict("no verdict here at all");
    try std.testing.expectEqual(@as(usize, 0), v.critical);
    try std.testing.expect(!v.blocks());
}

test "dispatchStep runs runner and review gate" {
    const alloc = std.testing.allocator;
    var plan = try Plan.init(alloc, "Task", 0x1);
    defer plan.deinit(alloc);
    var s1 = try PlanStep.initWithId(alloc, 1, "Do thing", &.{}, "bash");
    defer s1.deinit(alloc);
    try plan.addStep(alloc, s1);

    // Fake runner: returns "OK" for implementation and a clean verdict for review.
    const fake = struct {
        fn run(io: std.Io, a: Allocator, task: []const u8) anyerror![]u8 {
            _ = io;
            if (std.mem.indexOf(u8, task, "Review the following")) |_| {
                return try a.dupe(u8, "SEVERITIES: critical=0 important=0 minor=1");
            }
            return try a.dupe(u8, "OK");
        }
    };

    const out = try dispatchStep(std.testing.io, alloc, &plan, &s1, &fake.run, true);
    defer alloc.free(out.subagent_output);
    try std.testing.expectEqualStrings("OK", out.subagent_output);
    try std.testing.expect(!out.blocked);
    try std.testing.expectEqual(@as(usize, 1), out.verdict.minor);
}

test "dispatchParallelBatch runs all tasks in one batch + aggregated review" {
    const alloc = std.testing.allocator;
    var plan = try Plan.init(alloc, "Task", 0x1);
    defer plan.deinit(alloc);

    var s1 = try PlanStep.initWithId(alloc, 1, "Step one", &.{}, "bash");
    defer s1.deinit(alloc);
    s1.executor_mode = try alloc.dupe(u8, "parallel");
    try plan.addStep(alloc, s1);

    var s2 = try PlanStep.initWithId(alloc, 2, "Step two", &.{}, "bash");
    defer s2.deinit(alloc);
    s2.executor_mode = try alloc.dupe(u8, "parallel:2");
    try plan.addStep(alloc, s2);

    // Fake batch runner: echoes how many tasks it received; the review call
    // (single task) returns a clean verdict.
    const fake_batch = struct {
        fn run(
            io: std.Io,
            a: Allocator,
            tasks: []const []const u8,
        ) anyerror![]u8 {
            _ = io;
            if (tasks.len == 1 and std.mem.indexOf(u8, tasks[0], "Review the following batch") != null) {
                return try a.dupe(u8, "SEVERITIES: critical=0 important=1 minor=0");
            }
            return std.fmt.allocPrint(a, "executed {d} parallel tasks", .{tasks.len});
        }
    };

    const batch_ids = [_]u64{ 1, 2 };
    const out = try dispatchParallelBatch(std.testing.io, alloc, &plan, &batch_ids, &fake_batch.run, true);
    defer alloc.free(out.subagent_output);
    try std.testing.expect(std.mem.indexOf(u8, out.subagent_output, "executed 2 parallel tasks") != null);
    try std.testing.expect(!out.blocked);
    try std.testing.expectEqual(@as(usize, 1), out.verdict.important);
}
