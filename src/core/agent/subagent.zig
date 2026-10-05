//! subagent.zig — Subagent runner and plan dispatch orchestration for AgentLoop.
//!
//! Provides child-process subagent invocation via `invoke_subagent` and parallel
//! batch dispatch via `batch_invoke_subagents` according to

const std = @import("std");
const proto = @import("../protocol.zig");
const json_mod = @import("../json.zig");
const utils = @import("../utils.zig");
const tools_mod = @import("../../tooling/registry.zig");
const plan_mod = @import("../plan.zig");
const plan_executor = @import("../plan/executor.zig");
const plan_dispatch = @import("../plan/dispatch.zig");
const main = @import("../../main.zig");
const loop_mod = @import("loop.zig");
const AgentLoop = loop_mod.AgentLoop;

/// Real subagent runner — wraps the `invoke_subagent` tool so
/// plan steps can be dispatched to a child mini process. Module-level so it
/// can be passed as a `plan_dispatch.SubagentRunner`.
pub fn subagentRunner(io: std.Io, alloc: std.mem.Allocator, task: []const u8) anyerror![]u8 {
    const esc = try json_mod.escape(alloc, task);
    defer alloc.free(esc);
    const input = try std.fmt.allocPrint(alloc, "{{\"task\":\"{s}\"}}", .{esc});
    defer alloc.free(input);
    return tools_mod.executeTool(alloc, io, "invoke_subagent", input);
}

/// Batch subagent runner — wraps `batch_invoke_subagents` so
/// multiple independent plan steps are executed in one parallel dispatch.
/// Builds `{"tasks":[t1,t2,...]}` JSON, escaped.
pub fn batchSubagentRunner(
    io: std.Io,
    alloc: std.mem.Allocator,
    tasks: []const []const u8,
) anyerror![]u8 {
    // PSEUDOCODE:
    // 1. Build a JSON array of escaped task strings.
    // 2. Wrap in {"tasks":[...]} and call batch_invoke_subagents.
    var buf = utils.BufWriter.init(alloc);
    errdefer buf.deinit();
    try buf.writeAll("{\"tasks\":[");
    for (tasks, 0..) |task, i| {
        if (i > 0) try buf.writeByte(',');
        const esc = try json_mod.escape(alloc, task);
        defer alloc.free(esc);
        try buf.writeAll(esc);
    }
    try buf.writeAll("]}");
    const input = try buf.toOwnedSlice();
    defer alloc.free(input);
    return tools_mod.executeTool(alloc, io, "batch_invoke_subagents", input);
}

/// Dispatch a set of independent parallel plan steps in one
/// `batch_invoke_subagents` call. On success (or unblocked review) every
/// batched step is completed via `completeStepByIndex` and `ctx` advances
/// to the next ready step; a blocked review yields a re-run advisory
/// instead. Returns the note to surface to the model.
pub fn maybeBatchPlanStep(
    self: *AgentLoop,
    act_id: usize,
    plan: *plan_mod.Plan,
    ctx: *plan_executor.ExecutionContext,
    ids: []const u64,
    mode: []const u8,
) ![]u8 {
    const out = try plan_dispatch.dispatchParallelBatch(
        self.io,
        self.alloc,
        plan,
        ids,
        &batchSubagentRunner,
        self.config.plan_review_gate,
    );
    defer self.alloc.free(out.subagent_output);

    // Journal the review verdict when a review ran.
    if (self.config.plan_review_gate) {
        if (self.journal) |*j| {
            const desc = try std.fmt.allocPrint(self.alloc,
                "batch review ({d} steps): critical={d} important={d} minor={d} blocked={}",
                .{ ids.len, out.verdict.critical, out.verdict.important, out.verdict.minor, out.blocked });
            j.recordEvent(self.io, act_id, .plan_review_outcome, desc) catch {};
            self.alloc.free(desc);
        }
    }

    if (out.blocked) {
        const adv = try std.fmt.allocPrint(self.alloc,
            \\[plan] Parallel batch ({d} steps, mode={s}) was blocked by the review gate
            \\(critical={d} important={d} minor={d}). The steps are NOT complete — fix and re-run.
        , .{ ids.len, mode, out.verdict.critical, out.verdict.important, out.verdict.minor });
        return adv;
    }

    // Unblocked: complete every batched step (idempotent) and advance ctx.
    for (ids) |sid| {
        if (plan_executor.findStepIndexById(plan, sid)) |idx| {
            _ = plan_executor.completeStepByIndex(plan, ctx, idx);
        }
    }
    // Advance ctx to the next dependency-ready step (or mark complete).
    if (plan.findReadyStepIndex()) |next_idx| {
        ctx.current_step_idx = next_idx;
        plan.steps.items[next_idx].status = .active;
    } else {
        ctx.is_complete = true;
    }

    // Persist the running plan.
    if (self.plan.plan_store) |ps| {
        ps.save(plan) catch |e| main.stderrPrint("[agent] Warning: Failed to persist running plan: {s}\n", .{@errorName(e)});
    }

    // Build a "3 steps [1,2,3]" descriptor for the note.
    var id_buf = utils.BufWriter.init(self.alloc);
    defer id_buf.deinit();
    try id_buf.print("{d} steps [", .{ids.len});
    for (ids, 0..) |sid, i| {
        if (i > 0) try id_buf.writeByte(',');
        try id_buf.print("{d}", .{sid});
    }
    try id_buf.writeByte(']');
    const ids_joined = try id_buf.toOwnedSlice();
    defer self.alloc.free(ids_joined);

    return try std.fmt.allocPrint(self.alloc,
        \\[plan] Parallel batch of {s} dispatched via batch_invoke_subagents
        \\(mode={s}); review verdict critical={d} important={d} minor={d}.
        \\Aggregate result:\n{s}
    , .{
        ids_joined,
        mode,
        out.verdict.critical,
        out.verdict.important,
        out.verdict.minor,
        out.subagent_output,
    });
}

/// When subagent dispatch is enabled and the current step
/// requests a `subagent` / `parallel` executor mode, dispatch the step to
/// a child process and optionally run the two-stage review gate. The step
/// is only completed on a passing verification (or unblocked review).
/// Returns an advisory string to append to tool results, or null.
pub fn maybeDispatchPlanStep(self: *AgentLoop, act_id: usize) !?[]u8 {
    if (!self.config.plan_subagent_dispatch) return null;
    if (self.plan.current_plan == null) return null;
    const plan = &self.plan.current_plan.?;
    const ctx = &self.plan.plan_ctx;
    if (ctx.current_step_idx >= plan.stepCount()) return null;

    const step = &plan.steps.items[ctx.current_step_idx];
    const mode = step.executor_mode orelse return null;
    if (!std.mem.startsWith(u8, mode, "subagent") and !plan_dispatch.isParallelMode(mode)) return null;

    // auto-batching: when the current step requests a
    // parallel mode and >= 2 mutually-independent parallel steps are
    // ready, dispatch them ALL in one `batch_invoke_subagents` call
    // instead of one-per-step. A single ready step falls through to
    // the single-step dispatch below.
    if (plan_dispatch.isParallelMode(mode)) {
        if (plan_dispatch.findParallelBatch(plan, self.alloc) catch null) |ids| {
            defer self.alloc.free(ids);
            if (ids.len >= 2) {
                return try maybeBatchPlanStep(self, act_id, plan, ctx, ids, mode);
            }
        }
    }

    const out = try plan_dispatch.dispatchStep(
        self.io, self.alloc, plan, step,
        &subagentRunner,
        self.config.plan_review_gate,
    );
    defer self.alloc.free(out.subagent_output);

    // Journal the review verdict when a review ran.
    if (self.config.plan_review_gate) {
        if (self.journal) |*j| {
            const desc = try std.fmt.allocPrint(self.alloc,
                "review verdict: critical={d} important={d} minor={d} blocked={}",
                .{ out.verdict.critical, out.verdict.important, out.verdict.minor, out.blocked });
            j.recordEvent(self.io, act_id, .plan_review_outcome, desc) catch {};
            self.alloc.free(desc);
        }
    }

    if (out.blocked) {
        // Critical finding -> the step is failed, feed a replan advisory.
        const adv = try std.fmt.allocPrint(self.alloc,
            \\[plan] Subagent review for step "{s}" reported a Critical finding — the step is NOT complete.
            \\Address the issue and re-run the step.
        , .{step.description});
        return adv;
    }

    // Unblocked (or review off): complete the step via the normal path.
    plan_executor.completeStep(plan, ctx);
    const note = try std.fmt.allocPrint(self.alloc,
        \\[plan] Step "{s}" dispatched to subagent (mode={s}); review verdict critical={d} important={d} minor={d}.
    , .{ step.description, mode, out.verdict.critical, out.verdict.important, out.verdict.minor });
    return note;
}
