//! execution.zig — Tool execution pipeline and result tracking for AgentLoop.
//!
//! Handles single and multi-tool execution, output truncation, same-response
//! deduplication, dedupe caching, and structured plan tracking integration.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const proto = @import("../protocol.zig");
const json_mod = @import("../json.zig");
const utils = @import("../utils.zig");
const signals = @import("../signals.zig");
const tools_mod = @import("../../tooling/registry.zig");
const media_gen_tool = @import("../../tools/media_gen.zig");
const prompts_mod = @import("../prompts.zig");
const plan_executor = @import("../plan/executor.zig");
const plan_monitor = @import("../plan/monitor.zig");
const main = @import("../../main.zig");
const loop_mod = @import("loop.zig");
const AgentLoop = loop_mod.AgentLoop;
const loop_monitor = @import("loop_monitor.zig");

/// Execution summary returned by executeTools for act debug logging.
pub const ToolExecSummary = struct {
    any_tool_err: bool,
    total_dur_ms: u64,
    tool_count: usize,
};

/// Synthesizes `tool_result` blocks (is_error=true) for tool_use blocks present
/// in a truncated/aborted response. Those tool calls were recorded in history
/// via addAssistantResponse but will never be executed — without a matching
/// result the model tends to replay the entire call from scratch. Marking them
/// as "interrupted" closes the protocol loop and steers the model to continue
/// from where it stopped instead.
pub fn closeOrphanedToolUses(self: *AgentLoop, response: *const proto.Response) !void {
    var results = ArrayList(proto.ToolResult).empty;
    defer results.deinit(self.alloc);
    var allocated = ArrayList([]u8).empty;
    defer {
        for (allocated.items) |s| self.alloc.free(s);
        allocated.deinit(self.alloc);
    }
    for (response.content.items) |block| {
        switch (block) {
            .tool_use => |tu| {
                const msg = try std.fmt.allocPrint(
                    self.alloc,
                    "[interrupted: this tool call was truncated before execution — do NOT re-issue it; continue from where the response stopped]",
                    .{},
                );
                try allocated.append(self.alloc, msg);
                try results.append(self.alloc, .{
                    .tool_use_id = tu.id,
                    .content = msg,
                    .is_error = true,
                });
            },
            else => {},
        }
    }
    if (results.items.len > 0) {
        try self.history.addToolResults(results.items);
    }
}

pub fn formatLoopCheckpointMessage(
    self: *AgentLoop,
    tu: proto.ToolUse,
    trip_reason_str: []const u8,
) ![]u8 {
    return switch (self.last_loop_reason) {
        .orbit_cycle, .macro_cycle_2, .macro_cycle_3 => blk: {
            var mbw = utils.BufWriter.init(self.alloc);
            errdefer mbw.deinit();
            try mbw.writeAll(prompts_mod.loop_checkpoint_header);
            try mbw.print(prompts_mod.loop_checkpoint_orbit_waypoint_fmt, .{trip_reason_str});
            try mbw.writeAll("🗺️ Trajectory Scouted: ");
            for (self.turn_tool_trajectory.items, 0..) |tn, i| {
                if (i > 0) try mbw.writeAll(" → ");
                const desc = desc_blk: {
                    if (self.pg_store) |pg| {
                        if (pg.matchNode(tn)) |nid| break :desc_blk pg.graph.nodes.items[nid].desc;
                    }
                    break :desc_blk "";
                };
                try mbw.print("`{s}`", .{tn});
                if (desc.len > 0) try mbw.print(" [{s}]", .{desc});
            }
            try mbw.writeAll("\n⚠️ Exploration has circled in place without forward progress (ΔZ = 0).\n");
            try mbw.writeAll("Consider a different approach for the next step if appropriate.\n");
            break :blk try mbw.toOwnedSlice();
        },
        .readonly_budget => try std.fmt.allocPrint(
            self.alloc,
            prompts_mod.loop_checkpoint_readonly_budget_fmt,
            .{self.consecutive_readonly_count},
        ),
        else => try std.fmt.allocPrint(
            self.alloc,
            prompts_mod.loop_checkpoint_dup_tool_fmt,
            .{ tu.name, tu.name },
        ),
    };
}

/// Formats action loop trip advisory message and sets checkpoint/halt state.
pub fn handleActionLoopTripMessage(
    self: *AgentLoop,
    act_id: usize,
    tu: proto.ToolUse,
    trip_reason_str: []const u8,
) ![]u8 {
    // PSEUDOCODE:
    // 1. If retries < 2: increment retries, set checkpoint, format trajectory recap
    // 2. Else: print halt message, mark tripped, format halt message
    if (self.plan.loop_plan_retries < 2) {
        self.plan.loop_plan_retries += 1;
        self.plan.plan_execution_pending = true;
        main.stderrPrint(
            "\n\x1b[33m[agent] ⚠️ Action loop detected: {s}. Requesting model to formulate plan and execute next step.\x1b[0m\n",
            .{trip_reason_str},
        );
        if (main.ui_repl.current_renderer) |r| {
            r.ensureNewline();
            r.write(" \x1b[33m[Action Loop Checkpoint: Requesting Plan & Execution]\x1b[0m\n");
        }
        if (self.journal) |*j| {
            j.recordEvent(self.io, act_id, .checkpoint_created, "Action loop detected - requesting plan & execution") catch {};
        }
        self.action_loop_tripped = false;
        self.consecutive_dup_tool_count = 0;
        self.clearTurnToolRecords();
        return formatLoopCheckpointMessage(self, tu, trip_reason_str);
    } else {
        main.stderrPrint(
            "\n\x1b[33m[agent] ⚠️ Action loop persisted after replanning attempts: {s}. Halting turn.\x1b[0m\n",
            .{trip_reason_str},
        );
        if (main.ui_repl.current_renderer) |r| {
            r.ensureNewline();
            r.write(" \x1b[33m[Action loop persisted: halting turn]\x1b[0m\n");
        }
        self.action_loop_tripped = true;
        return try std.fmt.allocPrint(
            self.alloc,
            prompts_mod.loop_halt_fmt,
            .{trip_reason_str},
        );
    }
}

/// Constructs warning advisory suffix if loop monitor flagged a repetition warning.
pub fn getLoopWarningSuffix(self: *AgentLoop, tool_name: []const u8) ?[]u8 {
    // PSEUDOCODE: Format warning text depending on last_loop_reason
    return switch (self.last_loop_reason) {
        .orbit_cycle, .macro_cycle_2, .macro_cycle_3 => std.fmt.allocPrint(
            self.alloc,
            prompts_mod.loop_warning_orbit,
            .{},
        ) catch null,
        .readonly_budget => std.fmt.allocPrint(
            self.alloc,
            prompts_mod.loop_warning_readonly_fmt,
            .{self.consecutive_readonly_count},
        ) catch null,
        else => std.fmt.allocPrint(
            self.alloc,
            prompts_mod.loop_warning_dup_tool_fmt,
            .{tool_name},
        ) catch null,
    };
}

/// Renders tool execution start to interactive REPL or fallback stderr.
pub fn renderToolInvocationStart(self: *AgentLoop, act_id: usize, tu: proto.ToolUse) void {
    // PSEUDOCODE: Update coordinator status and display starting indicator
    self.coordinator.updateStatus(act_id, .executing_tool, tu.name);
    if (main.ui_repl.current_renderer) |r| {
        r.startTool(tu.name, tu.input_json);
        return;
    }
    if (std.mem.eql(u8, tu.name, "bash")) {
        if (json_mod.findString(tu.input_json, "command")) |cmd| {
            var cmd_buf: [100]u8 = undefined;
            const display_cmd = if (cmd.len > 97) std.fmt.bufPrint(&cmd_buf, "{s}...", .{cmd[0..97]}) catch cmd else cmd;
            main.stderrPrint("\x1b[90m[bash]\x1b[0m \x1b[35m{s}\x1b[0m ", .{display_cmd});
        } else {
            main.stderrPrint("\x1b[90m[tool: {s}]\x1b[0m ", .{tu.name});
        }
    } else if (std.mem.eql(u8, tu.name, "file_read") or std.mem.eql(u8, tu.name, "file_write") or std.mem.eql(u8, tu.name, "file_edit")) {
        if (json_mod.findString(tu.input_json, "path")) |path| {
            main.stderrPrint("\x1b[90m[{s}]\x1b[0m \x1b[34m{s}\x1b[0m ", .{ tu.name, path });
        } else {
            main.stderrPrint("\x1b[90m[tool: {s}]\x1b[0m ", .{tu.name});
        }
    } else if (std.mem.eql(u8, tu.name, "codeact")) {
        main.stderrPrint("\x1b[90m[codeact]\x1b[0m \x1b[35mExecuting CodeAct script...\x1b[0m ", .{});
    } else {
        main.stderrPrint("\x1b[90m[tool: {s}]\x1b[0m ", .{tu.name});
    }
}

/// Renders tool execution completion to interactive REPL or fallback stderr.
pub fn renderToolInvocationFinish(self: *AgentLoop, tu: proto.ToolUse, result: []const u8, is_err: bool, dur_ms: u64) void {
    // PSEUDOCODE: If renderer present, extract patch info and finish; else print [ok]/[error]
    _ = self;
    if (main.ui_repl.current_renderer) |r| {
        var patch_path: ?[]const u8 = null;
        var patch_diff: ?[]const u8 = null;
        if (std.mem.eql(u8, tu.name, "file_edit") or std.mem.eql(u8, tu.name, "file_write")) {
            patch_path = json_mod.findString(tu.input_json, "path");
            patch_diff = json_mod.findString(tu.input_json, "patch") orelse json_mod.findString(tu.input_json, "content");
        }
        r.finishTool(tu.name, result, is_err, dur_ms, patch_path, patch_diff);
    } else {
        if (is_err) {
            main.stderrPrint("\x1b[31m[error]\x1b[0m\n", .{});
        } else {
            main.stderrPrint("\x1b[32m[ok]\x1b[0m\n", .{});
        }
    }
}

/// Updates structured plan progress, step completion, and drift monitoring.
pub fn trackPlanToolExecution(self: *AgentLoop, act_id: usize, tu: proto.ToolUse) !?[]u8 {
    // PSEUDOCODE:
    // 1. Guard: structured planning off or no plan -> null
    // 2. Bump act counters so actual_acts accounting is maintained
    // 3. Approval gate — a proposed plan is not actionable; emit advisory
    // 4. Check drift (existing)
    // 5. On tool_hint match: run verification gate when enabled, then complete/advance
    // 6. Persist at phase transitions (step complete, plan complete), not only at the end
    if (!self.plan.enable_structured_planning or self.plan.current_plan == null) return null;
    var plan = &self.plan.current_plan.?;
    var drift_advisory: ?[]u8 = null;

    plan_executor.bumpActCounters(&self.plan.plan_ctx);

    // Approval gate (advisory). A plan that is still `proposed`
    // is not actionable — steps do not advance and the model gets a standing
    // advisory instead of silent execution.
    if (self.config.plan_approval_gate and plan.phase == .proposed) {
        const note = try std.fmt.allocPrint(self.alloc,
            \\[plan] The parsed plan is `proposed` — it is not actionable yet. Run `/plan approve` to start executing, or proceed with explicit user confirmation.
        , .{});
        return note;
    }
    if (plan.phase == .rejected) return null;
    if (plan.phase == .approved) {
        plan.phase = .executing;
        if (self.journal) |*j| {
            j.recordEvent(self.io, act_id, .plan_phase_changed, "approved -> executing") catch {};
        }
    }

    if (self.config.prompt_enforcement_enabled and self.config.plan_drift_detection) {
        if (plan_monitor.checkPlanDrift(plan, &self.plan.plan_ctx, tu.name)) |d| {
            self.plan.plan_drift_score += d.drift_score;
            if (self.plan.plan_drift_score > 0.8) {
                const c = try plan_monitor.generateReplanSuggestion(plan, self.plan.plan_ctx.steps_completed, self.plan.plan_drift_score, self.alloc);
                defer self.alloc.free(c);
                drift_advisory = try std.fmt.allocPrint(self.alloc, prompts_mod.plan_drift_advisory_prefix, .{c});
            }
        }
    }

    if (self.plan.plan_ctx.current_step_idx < plan.stepCount()) {
        const current_step = &plan.steps.items[self.plan.plan_ctx.current_step_idx];
        if (current_step.tool_hint) |hint| {
            if (std.mem.eql(u8, tu.name, hint)) {
                // Verification gate. When enabled and the step
                // carries a verification, the hint match is necessary-not-
                // sufficient: run the check and only complete on .passed.
                if (self.config.plan_verification_gate and current_step.verification != null) {
                    const vstatus = plan_executor.verifyStep(
                        self.io, self.alloc, plan, &self.plan.plan_ctx,
                        &plan_executor.defaultVerificationRunner,
                    );
                    const step_desc = current_step.description;
                    const vtext = try std.fmt.allocPrint(self.alloc,
                        "step \"{s}\" -> {s}", .{ step_desc, @tagName(vstatus) });
                    if (self.journal) |*j| j.recordEvent(self.io, act_id, .plan_step_verified, vtext) catch {};
                    self.alloc.free(vtext);

                    if (vstatus == .passed) {
                        plan_executor.completeStep(plan, &self.plan.plan_ctx);
                        if (!utils.isSubagent()) main.stderrPrint("[agent] Plan step verified & completed: {s}\n", .{step_desc});
                    } else {
                        const adv = try std.fmt.allocPrint(self.alloc,
                            \\[plan] Verification for "{s}" returned {s} — the step is NOT complete. Fix and re-run verification.
                        , .{ step_desc, @tagName(vstatus) });
                        drift_advisory = adv;
                    }
                } else {
                    // Legacy path (no gate or no verification): hint match completes.
                    plan_executor.completeStep(plan, &self.plan.plan_ctx);
                    if (!utils.isSubagent()) main.stderrPrint("[agent] Plan step completed: {s}\n", .{current_step.description});
                }

                // Persistence trigger — a step transition is a
                // phase transition; save the running plan so a crash revives it.
                if (self.plan.plan_store) |ps| {
                    ps.save(plan) catch |e| main.stderrPrint("[agent] Warning: Failed to persist running plan: {s}\n", .{@errorName(e)});
                }
            }
        }
    }

    if (self.plan.plan_ctx.is_complete or plan.isComplete()) {
        plan.phase = .complete;
        if (self.journal) |*j| {
            j.recordEvent(self.io, act_id, .plan_phase_changed, "executing -> complete") catch {};
        }
        if (!utils.isSubagent()) main.stderrPrint("[agent] Plan completed! Saving to store...\n", .{});
        if (self.plan.plan_store) |ps| {
            ps.save(plan) catch |e| main.stderrPrint("[agent] Warning: Failed to save plan: {s}\n", .{@errorName(e)});
        }
        self.plan.clearPlan();
    } else {
        // Advance via the dependency-aware ready-set selector instead
        // of a sequential index scan, so independent steps can go ready the
        // moment their dependencies complete (runtime DAG wiring, §3.4).
        if (plan.findReadyStepIndex()) |next_idx| {
            self.plan.plan_ctx.current_step_idx = next_idx;
            plan.steps.items[next_idx].status = .active;
        } else {
            self.plan.plan_ctx.is_complete = true;
        }
    }
    return drift_advisory;
}

pub fn checkToolDedupeCache(
    self: *AgentLoop,
    tu: proto.ToolUse,
    results: *ArrayList(proto.ToolResult),
    allocated_strings: *ArrayList([]u8),
) !bool {
    if (!loop_monitor.isReadOnlyTool(tu.name)) return false;
    const cache_hash = loop_monitor.fuzzyArgsHash(tu.input_json);
    const cached = self.lookupToolCache(tu.name, cache_hash) orelse return false;

    main.stderrPrint("\x1b[33m[duplicate: serving cached result]\x1b[0m\n", .{});
    const note = try std.fmt.allocPrint(self.alloc, "[duplicate: identical call already executed this turn — cached result below]\n{s}", .{cached});
    try allocated_strings.append(self.alloc, note);
    try results.append(self.alloc, .{ .tool_use_id = tu.id, .content = note, .is_error = false });
    return true;
}

pub fn postProcessToolResult(
    self: *AgentLoop,
    act_id: usize,
    tu: proto.ToolUse,
    result: []const u8,
    warn_suffix: ?[]const u8,
    is_err: bool,
    results: *ArrayList(proto.ToolResult),
    allocated_strings: *ArrayList([]u8),
) !void {
    const max_tool_result = 64 * 1024;
    const truncated = if (result.len > max_tool_result) result[0..max_tool_result] else result;
    const final_content = if (warn_suffix) |ws| blk: {
        const merged = try std.fmt.allocPrint(self.alloc, "{s}{s}", .{ truncated, ws });
        try allocated_strings.append(self.alloc, merged);
        break :blk merged;
    } else truncated;

    try results.append(self.alloc, .{ .tool_use_id = tu.id, .content = final_content, .is_error = is_err });
    if (!is_err and loop_monitor.isReadOnlyTool(tu.name)) {
        self.storeToolCache(tu.name, loop_monitor.fuzzyArgsHash(tu.input_json), truncated) catch {};
    }

    if (!is_err) {
        self.plan.loop_plan_retries = 0;
        self.plan.plan_execution_pending = false;
        self.plan.plan_watchdog_retries = 0;
        if (!loop_monitor.isExploratoryToolCall(tu.name, tu.input_json)) {
            if (try trackPlanToolExecution(self, act_id, tu)) |adv| {
                try allocated_strings.append(self.alloc, adv);
                try results.append(self.alloc, .{ .tool_use_id = tu.id, .content = adv, .is_error = false });
            }
        }
    }
}

/// Executes a single tool call, handles caching, snapshot tracking, output truncation, and returns duration.
pub fn executeSingleTool(
    self: *AgentLoop,
    act_id: usize,
    tu: proto.ToolUse,
    warn_suffix: ?[]const u8,
    results: *ArrayList(proto.ToolResult),
    allocated_strings: *ArrayList([]u8),
    any_tool_err: *bool,
) !u64 {
    // PSEUDOCODE:
    // 1. Check dedupe cache for read-only tools
    // 2. Snapshot file if mutating, execute tool
    // 3. Post-process result, plan tracking, render finish, return duration
    if (try checkToolDedupeCache(self, tu, results, allocated_strings)) return 0;

    const start_tool_ms = utils.milliTimestamp();
    renderToolInvocationStart(self, act_id, tu);

    if (std.mem.eql(u8, tu.name, "file_edit") or std.mem.eql(u8, tu.name, "file_write")) {
        if (json_mod.findString(tu.input_json, "path")) |path| {
            if (self.snapshot_tracker) |*t| t.beforeFileWrite(path);
        }
    }

    var is_err = false;
    // Promoting the invoked tool keeps its schema visible for the
    // following acts even when the model calls a deferred tool directly
    // (no tool_search round-trip). Grow-only, so the cache prefix is safe.
    if (tools_mod.isDeferredToolsEnabled()) tools_mod.promoteTool(tu.name);
    const result = tools_mod.executeTool(self.alloc, self.io, tu.name, tu.input_json) catch |e| blk: {
        if (e == error.Interrupted or signals.isInterrupted()) return error.Interrupted;
        is_err = true;
        any_tool_err.* = true;
        break :blk try std.fmt.allocPrint(self.alloc, "Tool error: {s}", .{@errorName(e)});
    };
    if (signals.isInterrupted()) {
        self.alloc.free(result);
        return error.Interrupted;
    }
    try allocated_strings.append(self.alloc, result);

    try postProcessToolResult(self, act_id, tu, result, warn_suffix, is_err, results, allocated_strings);

    const end_tool_ms = utils.milliTimestamp();
    const dur_ms = if (end_tool_ms >= start_tool_ms) @as(u64, @intCast(end_tool_ms - start_tool_ms)) else 0;
    renderToolInvocationFinish(self, tu, result, is_err, dur_ms);
    return dur_ms;
}

/// Flushes tool execution results and any generated media attachments to history.
pub fn recordToolResultsToHistory(self: *AgentLoop, results: []const proto.ToolResult) !void {
    // PSEUDOCODE: If results non-empty, attach media if available and record in history
    if (results.len == 0) return;
    const turn_attached = media_gen_tool.getTurnAttachments();
    if (turn_attached.len > 0) {
        try self.history.addToolResultsWithImages(results, turn_attached);
        media_gen_tool.clearTurnAttachments(self.alloc);
    } else {
        try self.history.addToolResults(results);
    }
}

/// Evaluates loop trip and dispatches single tool execution, returning duration and whether loop tripped.
pub fn dispatchSingleToolUse(
    self: *AgentLoop,
    act_id: usize,
    tu: proto.ToolUse,
    results: *ArrayList(proto.ToolResult),
    allocated_strings: *ArrayList([]u8),
    any_tool_err: *bool,
) !struct { dur_ms: u64, should_break: bool } {
    // PSEUDOCODE: Check loop -> handle trip or execute single tool with warning suffix
    const loop_check = if (self.config.prompt_enforcement_enabled)
        self.checkActionLoop(tu.name, tu.input_json) catch .allow
    else
        @as(@TypeOf(self.checkActionLoop(tu.name, tu.input_json) catch .allow), .allow);
    if (loop_check == .trip) {
        const trip_reason_str = switch (self.last_loop_reason) {
            .macro_cycle_2 => "alternating tool loop (A ↔ B) repeated",
            .macro_cycle_3 => "3-step tool cycle (A → B → C) repeated",
            .orbit_cycle => "closed orbit in 3D procedural map repeated",
            .readonly_budget => "read-only exploratory budget exceeded without code mutation",
            else => "called repeatedly with identical parameters",
        };
        const trip_msg = try handleActionLoopTripMessage(self, act_id, tu, trip_reason_str);
        try allocated_strings.append(self.alloc, trip_msg);
        try results.append(self.alloc, .{ .tool_use_id = tu.id, .content = trip_msg, .is_error = true });
        return .{ .dur_ms = 0, .should_break = true };
    }

    const warn_suffix: ?[]u8 = if (loop_check == .warn) getLoopWarningSuffix(self, tu.name) else null;
    defer if (warn_suffix) |w| self.alloc.free(w);

    if (self.plan.plan_active and !AgentLoop.isPlanOnlyRequest(self.current_user_request) and !loop_monitor.isExploratoryToolCall(tu.name, tu.input_json)) {
        self.plan.clearPlan();
    }

    const dur = try executeSingleTool(self, act_id, tu, warn_suffix, results, allocated_strings, any_tool_err);
    return .{ .dur_ms = dur, .should_break = false };
}

/// Same-response dedupe entry: tool name + whitespace-insensitive args hash.
const SeenToolCall = struct {
    name: []u8,
    args_hash: u64,
};

/// Executes all tool_use blocks in response.
/// Returns execution summary for act debug logging.
pub fn executeTools(self: *AgentLoop, act_id: usize, response: *const proto.Response) !ToolExecSummary {
    // PSEUDOCODE: Iterate blocks, dispatch tool uses, record results to history
    var any_tool_err = false;
    var results = ArrayList(proto.ToolResult).empty;
    defer results.deinit(self.alloc);

    var allocated_strings = ArrayList([]u8).empty;
    defer {
        for (allocated_strings.items) |s| self.alloc.free(s);
        allocated_strings.deinit(self.alloc);
    }
    var total_dur_ms: u64 = 0;
    var tool_count: usize = 0;

    // Same-response duplicate guard: identical tool name + args appearing
    // multiple times in ONE assistant response is almost always a model
    // emission glitch; execute the first occurrence and serve a duplicate
    // note for the rest instead of re-running the tool.
    var seen_calls = ArrayList(SeenToolCall).empty;
    defer {
        for (seen_calls.items) |sc| self.alloc.free(sc.name);
        seen_calls.deinit(self.alloc);
    }

    for (response.content.items) |block| {
        if (signals.isInterrupted()) return error.Interrupted;
        switch (block) {
            .tool_use => |tu| {
                // PSEUDOCODE: 1. Hash name+args 2. If seen in this response, serve dup note 3. Else record and execute
                const args_hash = loop_monitor.fuzzyArgsHash(tu.input_json);
                var is_dup = false;
                for (seen_calls.items) |sc| {
                    if (sc.args_hash == args_hash and std.mem.eql(u8, sc.name, tu.name)) {
                        is_dup = true;
                        break;
                    }
                }
                if (is_dup) {
                    const note = try std.fmt.allocPrint(
                        self.alloc,
                        "[duplicate: identical call already executed in this response — result above]",
                        .{},
                    );
                    try allocated_strings.append(self.alloc, note);
                    try results.append(self.alloc, .{ .tool_use_id = tu.id, .content = note, .is_error = false });
                    tool_count += 1;
                    continue;
                }
                try seen_calls.append(self.alloc, .{
                    .name = try self.alloc.dupe(u8, tu.name),
                    .args_hash = args_hash,
                });
                const outcome = try dispatchSingleToolUse(self, act_id, tu, &results, &allocated_strings, &any_tool_err);
                total_dur_ms += outcome.dur_ms;
                if (outcome.should_break) break;
                tool_count += 1;
            },
            else => {},
        }
    }

    try recordToolResultsToHistory(self, results.items);
    self.last_act_failed = any_tool_err;
    return .{
        .any_tool_err = any_tool_err,
        .total_dur_ms = total_dur_ms,
        .tool_count = tool_count,
    };
}
