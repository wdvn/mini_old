//! test_plan_rfc024_bench.zig — Benchmark sweep evaluating RFC-024 plan-framework features.
//!
//! A *sweep* over plan sizes (50 -> 1000 steps) and over each RFC-024 phase:
//!   - P1 verification: verifyStep with the default runner (real file stat, no spawn)
//!   - P2 approval:     plan phase JSON round-trip scaling
//!   - P3 reinject:     skillNameFromSkillPath + generateProgressSummary scaling
//!   - P4 dispatch:     findParallelBatch / renderStepTask / dispatchStep (fake runner, no process)
//!   - P5 telemetry:    JSON plan parse scaling + journal event-tally cost
//!
//! All operations are pure in-process (no LLM, no subagent spawn), so this runs
//! fast and is safe in the standard test suite. Each block prints one line:
//!   <label>  <iters> iters | <total_ns> ns total | <ns_per_op> ns/op
//!
//! Run via `zig build test -Dskip-e2e=true` (bundled into the testcase binary).

const std = @import("std");
const mini = @import("mini");
const plan_mod = mini.plan_mod;
const Plan = plan_mod.Plan;
const PlanStep = plan_mod.PlanStep;
const plan_executor = mini.plan_executor_mod;
const plan_dispatch = mini.plan_dispatch_mod;
const agent_mod = mini.agent_mod;

// ---------------------------------------------------------------------------
// Timing + reporting
// ---------------------------------------------------------------------------

/// Monotonic nanosecond clock (repo pattern: std.c.clock_gettime MONOTONIC,
/// matching js_provider.zig / utils.zig which read `.sec` / `.nsec`).
fn nowNs() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return std.math.maxInt(i64);
    return @as(i64, @intCast(ts.sec)) * std.time.ns_per_s + @as(i64, @intCast(ts.nsec));
}

fn report(label: []const u8, iters: usize, t0: i64, t1: i64) void {
    const total_ns: i64 = @max(0, t1 - t0);
    const per_op: i64 = if (iters > 0) @divTrunc(total_ns, @as(i64, @intCast(iters))) else 0;
    std.debug.print("  {s:<52} {d:>6} iters | {d:>14} ns total | {d:>9} ns/op\n", .{
        label,
        iters,
        total_ns,
        per_op,
    });
}

// ---------------------------------------------------------------------------
// Plan builder
// ---------------------------------------------------------------------------

/// Build a plan with `n` steps. `parallel_mode` marks every step with
/// executor_mode "parallel"; `verify` attaches a shell verification to each step.
fn buildPlan(alloc: std.mem.Allocator, n: usize, parallel_mode: bool, verify: bool) !Plan {
    const desc = try std.fmt.allocPrint(alloc, "task with {d} steps", .{n});
    defer alloc.free(desc);

    var plan = try Plan.init(alloc, desc, 0xABCD);
    errdefer plan.deinit(alloc);

    var deps_arr: [1]u64 = .{0};
    for (0..n) |i| {
        const id = @as(u64, @intCast(i + 1));
        if (i > 0) deps_arr[0] = @as(u64, @intCast(i));
        const deps: []const u64 = if (i > 0) deps_arr[0..1] else &[_]u64{};

        var step = try PlanStep.initWithId(alloc, id, "step", deps, "bash");
        defer step.deinit(alloc);
        if (parallel_mode) step.executor_mode = try alloc.dupe(u8, "parallel");
        if (verify) {
            const vv = try alloc.dupe(u8, "zig build");
            step.verification = plan_mod.StepVerification{ .kind = .shell, .value = vv };
        }
        try plan.addStep(alloc, step);
    }
    return plan;
}

// ---------------------------------------------------------------------------
// P1 — verification
// ---------------------------------------------------------------------------

test "bench P1 verifyStep (default runner, file_exists — real stat)" {
    const alloc = std.heap.page_allocator;
    const io = std.testing.io;

    var plan = try buildPlan(alloc, 1, false, false);
    const bz = try alloc.dupe(u8, "build.zig"); // owned by the plan allocator
    plan.steps.items[0].verification = plan_mod.StepVerification{
        .kind = .file_exists,
        .value = bz, // real repo file — the default runner stats it
    };
    var ctx = plan_executor.ExecutionContext{};
    ctx.current_step_idx = 0;

    const iters: usize = 2000;
    const t0 = nowNs();
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        _ = plan_executor.verifyStep(io, alloc, &plan, &ctx, &plan_executor.defaultVerificationRunner);
    }
    const t1 = nowNs();
    report("P1 verifyStep file_exists (real stat)", iters, t0, t1);

    plan.deinit(alloc);
}

// ---------------------------------------------------------------------------
// P2 — approval / phase round-trip (plan-size sweep)
// ---------------------------------------------------------------------------

test "bench P2 phase JSON round-trip across plan sizes" {
    const alloc = std.heap.page_allocator;

    for ([_]usize{ 50, 200, 500, 1000 }) |n| {
        var plan = try buildPlan(alloc, n, false, false);
        const json = try plan.toJson(alloc);
        const label = try std.fmt.allocPrint(alloc, "P2 {d}-step plan toJson+fromJson", .{n});

        const iters: usize = 300;
        const t0 = nowNs();
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            var restored = try Plan.fromJson(alloc, json);
            _ = plan_mod.parsePlanPhase("executing");
            restored.deinit(alloc);
        }
        const t1 = nowNs();
        report(label, iters, t0, t1);

        alloc.free(label);
        alloc.free(json);
        plan.deinit(alloc);
    }
}

// ---------------------------------------------------------------------------
// P3 — reinject building blocks
// ---------------------------------------------------------------------------

test "bench P3 skillNameFromSkillPath" {
    const path = "/home/u/.mini/skills/brainstorming/SKILL.md";

    const iters: usize = 50_000;
    const t0 = nowNs();
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        _ = agent_mod.skillNameFromSkillPath(path);
    }
    const t1 = nowNs();
    report("P3 skillNameFromSkillPath (hot path)", iters, t0, t1);
}

test "bench P3 generateProgressSummary across plan sizes" {
    const alloc = std.heap.page_allocator;

    for ([_]usize{ 10, 100, 500 }) |n| {
        var plan = try buildPlan(alloc, n, false, false);
        var ctx = plan_executor.ExecutionContext{};
        const label = try std.fmt.allocPrint(alloc, "P3 generateProgressSummary ({d} steps)", .{n});

        const iters: usize = 200;
        const t0 = nowNs();
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            const s = plan_executor.generateProgressSummary(&plan, &ctx, alloc) catch "";
            if (s.len > 0) alloc.free(s);
        }
        const t1 = nowNs();
        report(label, iters, t0, t1);

        alloc.free(label);
        plan.deinit(alloc);
    }
}

// ---------------------------------------------------------------------------
// P4 — dispatch (fake runners, no process spawn)
// ---------------------------------------------------------------------------

test "bench P4 findParallelBatch across plan sizes" {
    const alloc = std.heap.page_allocator;

    for ([_]usize{ 50, 200, 500, 1000 }) |n| {
        var plan = try buildPlan(alloc, n, true, true); // all parallel, chain deps
        const label = try std.fmt.allocPrint(alloc, "P4 findParallelBatch ({d} parallel steps)", .{n});

        const iters: usize = 300;
        const t0 = nowNs();
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            if (plan_dispatch.findParallelBatch(&plan, alloc) catch null) |ids| {
                alloc.free(ids);
            }
        }
        const t1 = nowNs();
        report(label, iters, t0, t1);

        alloc.free(label);
        plan.deinit(alloc);
    }
}

test "bench P4 dispatchStep + review (fake runner, no process)" {
    const alloc = std.heap.page_allocator;
    const io_in = std.testing.io;

    var plan = try buildPlan(alloc, 1, false, true);
    const step0 = &plan.steps.items[0];

    // Fake runner: returns "OK" for the implementation task and a clean
    // verdict for the review task — exercises render + run + verdict parse
    // without any real subagent process.
    const fake = struct {
        fn run(r_io: std.Io, a: std.mem.Allocator, task: []const u8) anyerror![]u8 {
            _ = r_io;
            if (std.mem.indexOf(u8, task, "Review the following") != null) {
                return a.dupe(u8, "SEVERITIES: critical=0 important=0 minor=0");
            }
            return a.dupe(u8, "OK");
        }
    };

    const iters: usize = 2000;
    const t0 = nowNs();
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const out = try plan_dispatch.dispatchStep(io_in, alloc, &plan, step0, &fake.run, true);
        alloc.free(out.subagent_output);
    }
    const t1 = nowNs();
    report("P4 dispatchStep + review (fake runner)", iters, t0, t1);

    plan.deinit(alloc);
}

// ---------------------------------------------------------------------------
// P5 — telemetry / parse scaling sweep
// ---------------------------------------------------------------------------

test "bench P5 plan JSON parse scaling sweep" {
    const alloc = std.heap.page_allocator;

    for ([_]usize{ 50, 200, 500, 1000 }) |n| {
        var plan = try buildPlan(alloc, n, false, true);
        const json = try plan.toJson(alloc);
        const label = try std.fmt.allocPrint(alloc, "P5 plan JSON parse ({d} steps)", .{n});

        const iters: usize = 300;
        const t0 = nowNs();
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            var p2 = try Plan.fromJson(alloc, json);
            p2.deinit(alloc);
        }
        const t1 = nowNs();
        report(label, iters, t0, t1);

        alloc.free(label);
        alloc.free(json);
        plan.deinit(alloc);
    }
}

test "bench P5 journal plan-methodology event tally" {
    // Simulated journal content with a mix of RFC-024 events, using the exact
    // same substring-matching strategy as session_diagnostics.scanJournalLines.
    const journal =
        \\{"act_id":1,"event_type":"plan_phase_changed","timestamp":1,"description":"approved"}
        \\{"act_id":1,"event_type":"plan_step_verified","timestamp":2,"description":"passed"}
        \\{"act_id":1,"event_type":"skill_loaded","timestamp":3,"description":"brainstorming"}
        \\{"act_id":2,"event_type":"post_compact_reinject","timestamp":4,"description":"reinject"}
        \\{"act_id":2,"event_type":"plan_review_outcome","timestamp":5,"description":"critical=0"}
    ;

    const iters: usize = 5000;
    const t0 = nowNs();
    var i: usize = 0;
    var total: usize = 0;
    while (i < iters) : (i += 1) {
        if (std.mem.indexOf(u8, journal, "\"event_type\":\"plan_phase_changed\"") != null) total += 1;
        if (std.mem.indexOf(u8, journal, "\"event_type\":\"plan_step_verified\"") != null) total += 1;
        if (std.mem.indexOf(u8, journal, "\"event_type\":\"skill_loaded\"") != null) total += 1;
        if (std.mem.indexOf(u8, journal, "\"event_type\":\"post_compact_reinject\"") != null) total += 1;
        if (std.mem.indexOf(u8, journal, "\"event_type\":\"plan_review_outcome\"") != null) total += 1;
    }
    const t1 = nowNs();
    if (total != iters * 5) @panic("tally mismatch — scan strategy changed?");
    report("P5 journal event tally (5 RFC-024 events/line)", iters, t0, t1);
}
