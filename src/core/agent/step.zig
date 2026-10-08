//! Step execution logic for AgentLoop.
//!
//! Decomposes single-step execution (executeStep) into focused, testable lifecycle phases:
//! - GuidanceProgressContext: injects Procedural Graph & Plan progress
//! - modulateReasoningEffort: dynamic thinking / reasoning effort selection
//! - scanResponseContent: analyzes tokens, meaningful text, tool blocks, and plan detection
//! - executeCodeActBlock: handles QuickJS evaluation, action loop trips, and output formatting
//! - dispatchStopReason: dispatches end_turn, max_tokens, tool_use, stream_aborted, unknown

const std = @import("std");
const proto = @import("../protocol.zig");
const utils = @import("../utils.zig");
const signals = @import("../signals.zig");
const main = @import("../../main.zig");
const js_bindings = @import("../../runtime/js_bindings.zig");
const chat_stream = @import("../../ui/chat_stream.zig");
const media_gen_tool = @import("../../tools/media_gen.zig");
const quickjs_engine = @import("../../runtime/quickjs_engine.zig");
const ExecutionResult = quickjs_engine.ExecutionResult;
const agent_parsing = @import("parsing.zig");
const loop_mod = @import("loop.zig");
const AgentLoop = loop_mod.AgentLoop;
const prompts_mod = @import("../prompts.zig");
const history_mod = @import("../history.zig");
const agent_loop_monitor = @import("loop_monitor.zig");

pub const StepResult = proto.ActTransition;

/// Manages ephemeral allocations and content blocks for Procedural Graph and Plan progress guidance.
pub const GuidanceProgressContext = struct {
    ephemeral_guidance: ?[]u8 = null,
    ephemeral_blocks: ?[]proto.ContentBlock = null,
    progress_text: ?[]u8 = null,
    progress_blocks: ?[]proto.ContentBlock = null,

    pub fn init() GuidanceProgressContext {
        return .{};
    }

    pub fn deinit(self: *GuidanceProgressContext, alloc: std.mem.Allocator) void {
        if (self.ephemeral_guidance) |g| alloc.free(g);
        if (self.ephemeral_blocks) |b| alloc.free(b);
        if (self.progress_text) |t| alloc.free(t);
        if (self.progress_blocks) |b| alloc.free(b);
        self.* = .{};
    }

    /// Injects Procedural Graph guidance and Plan progress tracking blocks into the temporary input message list.
    pub fn inject(
        self: *GuidanceProgressContext,
        loop: *AgentLoop,
        act_id: usize,
        temp_input_msgs: *std.ArrayListUnmanaged(proto.Message),
    ) !void {
        // Procedural Graph: Prepare ephemeral situational guidance block
        if (loop.config.prompt_enforcement_enabled) {
            if (loop.pg_store) |pg| {
                if (loop.config.memact_pg_advisory) {
                    const traj_slice: []const []const u8 = if (loop.turn_tool_trajectory.items.len > 0)
                        loop.turn_tool_trajectory.items
                    else
                        loop.recent_tools.items;

                    self.ephemeral_guidance = pg.serializeGuidance(
                        loop.alloc,
                        loop.last_executed_tool,
                        traj_slice,
                        loop.last_act_failed,
                        loop.config.memact_pg_h,
                        loop.current_user_request,
                    ) catch null;

                    if (self.ephemeral_guidance) |guidance_text| {
                        const blocks = try loop.alloc.alloc(proto.ContentBlock, 1);
                        blocks[0] = .{ .text = guidance_text };
                        self.ephemeral_blocks = blocks;
                        try temp_input_msgs.append(loop.alloc, .{
                            .role = .user,
                            .content = blocks,
                        });
                    }
                }
            }
        }

        // Progress Tracking: inject summary of previous act's work
        if (loop.plan.buildProgressBlock(loop.alloc, act_id, loop.config)) |progress_text_owned| {
            self.progress_text = progress_text_owned;
            const blocks = try loop.alloc.alloc(proto.ContentBlock, 1);
            blocks[0] = .{ .text = self.progress_text.? };
            self.progress_blocks = blocks;
            try temp_input_msgs.append(loop.alloc, .{
                .role = .user,
                .content = blocks,
            });
        }
    }
};

/// PSEUDOCODE: Cap thinking budget at 85% of max_tokens so at least 15%
/// headroom remains for the final answer / tool-call payload (same
/// estimation principle as Claude's thinking budget).
/// 1. budget null → null (thinking disabled, keep as-is)
/// 2. budget > 85% of max_tokens → clamp down to the cap
/// 3. budget <= cap → keep unchanged
fn capThinkingBudget(max_tokens: u32, budget: ?u32) ?u32 {
    const b = budget orelse return null;
    const cap = max_tokens * 85 / 100;
    if (b > cap) return cap;
    return b;
}

test "thinking budget capped at 85% of max_tokens" {
    try std.testing.expectEqual(@as(?u32, null), capThinkingBudget(24000, null));
    try std.testing.expectEqual(@as(?u32, 4096), capThinkingBudget(24000, 4096));
    try std.testing.expectEqual(@as(?u32, 20400), capThinkingBudget(24000, 40000));
    try std.testing.expectEqual(@as(?u32, 850), capThinkingBudget(1000, 900));
    try std.testing.expectEqual(@as(?u32, 20400), capThinkingBudget(24000, 20400));
}

/// Input snapshot for reasoning effort selection (pure, testable without AgentLoop).
pub const EffortSelection = struct {
    config_effort: ?[]const u8 = null,
    config_budget: ?u32 = null,
    last_effort: ?[]const u8 = null,
    last_budget: ?u32 = null,
    last_act_failed: bool = false,
    js_retry_count: usize = 0,
    act_id: usize = 1,
    /// True when a structured plan is approved/executing its items.
    plan_executing_items: bool = false,
};

/// PSEUDOCODE: Pure effort selection with fixed priority:
/// 1. Error recovery safety net — escalate to high (failed act or JS retry)
/// 2. Plan execution — downgrade to medium so mechanical step
///    execution stays fast; an explicit config effort of "low" is respected
/// 3. Act 1: no model choice yet — start from config/default
/// 4. Sticky effort — sustain previous level across routine follow-ups
pub fn selectReasoningEffort(s: EffortSelection) struct {
    effort: ?[]const u8,
    budget: ?u32,
} {
    if (s.last_act_failed or s.js_retry_count > 0)
        return .{ .effort = "high", .budget = 4096 };
    if (s.plan_executing_items) {
        if (std.mem.eql(u8, s.config_effort orelse "", "low"))
            return .{ .effort = "low", .budget = s.config_budget orelse 1024 };
        return .{ .effort = "medium", .budget = 4096 };
    }
    if (s.act_id == 1)
        return .{ .effort = s.config_effort orelse "high", .budget = s.config_budget orelse 4096 };
    return .{ .effort = s.last_effort, .budget = s.last_budget };
}

test "reasoning effort selection priorities" {
    var base = EffortSelection{};

    // Error recovery always escalates to high, even during plan execution.
    base = .{ .plan_executing_items = true, .last_act_failed = true, .act_id = 3, .last_effort = "medium" };
    try std.testing.expectEqualStrings("high", selectReasoningEffort(base).effort.?);

    base = .{ .plan_executing_items = true, .js_retry_count = 1, .act_id = 3 };
    try std.testing.expectEqualStrings("high", selectReasoningEffort(base).effort.?);

    // Plan execution downgrades sticky high to medium.
    base = .{ .plan_executing_items = true, .act_id = 2, .last_effort = "high", .last_budget = 8192 };
    var d = selectReasoningEffort(base);
    try std.testing.expectEqualStrings("medium", d.effort.?);
    try std.testing.expectEqual(@as(?u32, 4096), d.budget);

    // Explicit config effort "low" is respected during plan execution.
    base = .{ .plan_executing_items = true, .act_id = 2, .config_effort = "low" };
    d = selectReasoningEffort(base);
    try std.testing.expectEqualStrings("low", d.effort.?);
    try std.testing.expectEqual(@as(?u32, 1024), d.budget);
    base.config_budget = 512;
    try std.testing.expectEqual(@as(?u32, 512), selectReasoningEffort(base).budget);

    // No plan: act 1 starts from config/default.
    base = .{ .act_id = 1 };
    d = selectReasoningEffort(base);
    try std.testing.expectEqualStrings("high", d.effort.?);
    try std.testing.expectEqual(@as(?u32, 4096), d.budget);
    base.config_effort = "low";
    base.config_budget = 777;
    d = selectReasoningEffort(base);
    try std.testing.expectEqualStrings("low", d.effort.?);
    try std.testing.expectEqual(@as(?u32, 777), d.budget);

    // No plan: sticky effort is sustained.
    base = .{ .act_id = 4, .last_effort = "medium", .last_budget = 2048 };
    d = selectReasoningEffort(base);
    try std.testing.expectEqualStrings("medium", d.effort.?);
    try std.testing.expectEqual(@as(?u32, 2048), d.budget);
}

/// Dynamically modulates reasoning effort and thinking budget tokens based on overrides, error state, plan execution, and stickiness.
pub fn modulateReasoningEffort(loop: *AgentLoop, act_id: usize) void {
    if (loop.config.reasoning_effort_disabled) return;

    var effective_effort: ?[]const u8 = loop.config.reasoning_effort;
    var effective_budget: ?u32 = loop.config.thinking_budget_tokens;

    // Priority 1: Explicit JS override via mini.setThinking
    if (js_bindings.consumePendingThinkingOverride()) |override| {
        if (override.effort) |eff| effective_effort = eff;
        if (override.budget_tokens) |bud| effective_budget = bud;
    } else if (loop.dynamic_thinking) {
        // Downshift while executing structured plan items.
        const plan_items_executing = if (loop.plan.current_plan) |plan|
            plan.phase == .approved or plan.phase == .executing
        else
            false;

        const decision = selectReasoningEffort(EffortSelection{
            .config_effort = loop.config.reasoning_effort,
            .config_budget = loop.config.thinking_budget_tokens,
            .last_effort = loop.last_effort,
            .last_budget = loop.last_budget,
            .last_act_failed = loop.last_act_failed,
            .js_retry_count = loop.js_retry_count,
            .act_id = act_id,
            .plan_executing_items = plan_items_executing,
        });
        effective_effort = decision.effort;
        effective_budget = decision.budget;
    }

    // PSEUDOCODE: Clamp thinking budget to 85% of max_tokens so the response
    // always keeps >=15% headroom for answer / tool-call payload.
    effective_budget = capThinkingBudget(loop.config.max_tokens, effective_budget);

    loop.last_effort = effective_effort;
    loop.last_budget = effective_budget;

    loop.backend.setReasoningEffort(effective_effort);
    loop.backend.setThinkingBudget(effective_budget);
    chat_stream.active_effort = effective_effort;
}

/// Scans the backend response content, updates token counts, detects plans, and checks for tool blocks.
pub fn scanResponseContent(loop: *AgentLoop, response: *const proto.Response, was_added: bool) bool {
    var has_tool_use_blocks = false;
    for (response.content.items) |block| {
        if (block == .tool_use) {
            has_tool_use_blocks = true;
            break;
        }
    }

    var has_meaningful_text = false;
    if (was_added) {
        for (response.content.items) |block| {
            if (block == .text) {
                const trimmed = std.mem.trim(u8, block.text, " \r\n\t");
                if (trimmed.len > 0) {
                    has_meaningful_text = true;
                    break;
                }
            }
        }
    }

    for (response.content.items) |block| {
        switch (block) {
            .text => |t| {
                loop.last_turn_completion_tokens += loop.token_estimator.estimate(t);
                loop.plan.tryDetectPlanInResponse(t);
            },
            .thinking => |th| {
                loop.last_turn_completion_tokens += loop.token_estimator.estimate(th.thinking);
            },
            .tool_use => |tu| {
                loop.last_turn_completion_tokens += loop.token_estimator.estimate(tu.name) + loop.token_estimator.estimate(tu.input_json);
            },
            else => {},
        }
    }

    return has_tool_use_blocks;
}

/// Executes a CodeAct JavaScript script in QuickJS engine with loop protection and output formatting.
fn handleCodeActLoopTrip(loop: *AgentLoop, act_id: usize) !StepResult {
    if (loop.plan.loop_plan_retries < 2) {
        loop.plan.loop_plan_retries += 1;
        loop.plan.plan_execution_pending = true;
        if (loop.config.action_loop_display) {
            main.stderrPrint(
                "\n\x1b[33m[agent] ⚠️ Action loop detected: identical CodeAct script repeated without progress. Requesting model to formulate plan and execute next step.\x1b[0m\n",
                .{},
            );
        }
        if (main.ui_repl.current_renderer) |r| {
            r.ensureNewline();
            r.write(" \x1b[33m[Action Loop Detected: Requesting Plan & Execution]\x1b[0m\n");
        }
        if (loop.journal) |*j| {
            j.recordEvent(loop.io, act_id, .checkpoint_created, "CodeAct action loop - requesting plan & execution") catch {};
        }
        const trip_msg = prompts_mod.codeact_checkpoint;
        try loop.history.addUser(trip_msg);
        loop.action_loop_tripped = false;
        loop.consecutive_dup_tool_count = 0;
        loop.last_step_outcome = .actions_executed;
        return proto.ActTransition{ .next_act = {} };
    } else {
        main.stderrPrint(
            "\n\x1b[33m[agent] ⚠️ Action loop persisted after replanning attempts: identical CodeAct script repeated. Halting loop.\x1b[0m\n",
            .{},
        );
        const trip_msg = prompts_mod.codeact_system_intervention;
        try loop.history.addUser(trip_msg);
        loop.action_loop_tripped = true;
        loop.last_step_outcome = .protocol_failure;
        loop.last_turn_outcome = .stalled;
        return proto.ActTransition{ .stall = .action_loop };
    }
}

fn handleCodeActEvalError(
    loop: *AgentLoop,
    act_id: usize,
    input_msgs_count: usize,
    tool_defs: []const proto.ToolDefinition,
    response: *const proto.Response,
    js_code: []const u8,
    start_codeact_ms: u64,
    e: anyerror,
) !StepResult {
    media_gen_tool.clearTurnAttachments(loop.alloc);
    loop.last_act_failed = true;
    const end_err_ms: u64 = @as(u64, @intCast(utils.milliTimestamp()));
    const dur_ms = if (end_err_ms >= start_codeact_ms) @as(u64, @intCast(end_err_ms - start_codeact_ms)) else 0;
    loop.logActDebug(act_id, input_msgs_count, tool_defs, response, js_code, .{
        .exec_type = "codeact",
        .is_error = true,
        .duration_ms = dur_ms,
        .error_message = @errorName(e),
    });
    if (signals.isInterrupted()) return error.Interrupted;
    if (main.ui_repl.current_renderer) |r| {
        r.finishTool("codeact", @errorName(e), true, dur_ms, null, null);
    } else {
        main.stderrPrint("\x1b[31m[engine error: {s}]\x1b[0m\n", .{@errorName(e)});
    }
    const err_msg = try std.fmt.allocPrint(loop.alloc, prompts_mod.codeact_system_error_fmt, .{@errorName(e)});
    defer loop.alloc.free(err_msg);
    try loop.history.addUser(err_msg);
    loop.last_step_outcome = .actions_executed;
    return proto.ActTransition{ .next_act = {} };
}

fn handleCodeActSuccess(loop: *AgentLoop, res: ExecutionResult, dur_ms: u64) !StepResult {
    if (main.ui_repl.current_renderer) |r| {
        r.finishTool("codeact", if (res.return_value_json) |ret| ret else res.stdout, false, dur_ms, null, null);
    } else {
        main.stderrPrint("\x1b[32m[ok]\x1b[0m\n", .{});
    }
    loop.js_retry_count = 0;
    loop.plan.plan_watchdog_retries = 0;
    loop.last_act_failed = false;

    var out_buf = utils.BufWriter.init(loop.alloc);
    defer out_buf.deinit();

    try out_buf.writeAll("[CodeAct Execution Output]\n");
    if (res.stdout.len > 0) {
        try out_buf.print("stdout:\n{s}\n", .{res.stdout});
    }
    if (res.return_value_json) |ret| {
        try out_buf.print("return value:\n{s}\n", .{ret});
    }
    if (res.stdout.len == 0 and res.return_value_json == null) {
        try out_buf.writeAll("(Code executed successfully with no output)\n");
    }

    const turn_attached = media_gen_tool.getTurnAttachments();
    if (turn_attached.len > 0) {
        try loop.history.addUserWithImages(out_buf.list.items, turn_attached);
        media_gen_tool.clearTurnAttachments(loop.alloc);
    } else {
        try loop.history.addUser(out_buf.list.items);
    }
    loop.last_step_outcome = .actions_executed;
    return proto.ActTransition{ .next_act = {} };
}

fn handleCodeActScriptError(loop: *AgentLoop, res: ExecutionResult, dur_ms: u64) !StepResult {
    media_gen_tool.clearTurnAttachments(loop.alloc);
    if (main.ui_repl.current_renderer) |r| {
        r.finishTool("codeact", if (res.error_message) |m| m else "JS Error", true, dur_ms, null, null);
    } else {
        main.stderrPrint("\x1b[31m[error]\x1b[0m\n", .{});
    }
    loop.js_retry_count += 1;
    loop.last_act_failed = true;

    var err_buf = utils.BufWriter.init(loop.alloc);
    defer err_buf.deinit();

    try err_buf.writeAll(prompts_mod.codeact_js_error_header);
    if (res.error_message) |m| {
        try err_buf.print("Error: {s}\n", .{m});
    }
    if (res.stack_trace) |st| {
        try err_buf.print("Stack trace:\n{s}\n", .{st});
    }
    if (res.stdout.len > 0) {
        try err_buf.print("stdout before error:\n{s}\n", .{res.stdout});
    }
    if (loop.js_retry_count >= 3) {
        try err_buf.writeAll(prompts_mod.codeact_js_consecutive_errors_notice);
    } else {
        try err_buf.writeAll(prompts_mod.codeact_js_retry_prompt);
    }

    try loop.history.addUser(err_buf.list.items);
    loop.last_step_outcome = .actions_executed;
    return proto.ActTransition{ .next_act = {} };
}

// PSEUDOCODE:
// 1. notifyCodeActExecution: Clear plan if mutating file operations exist, announce tool start.
// 2. executeCodeActBlock: Check loop trip, announce, eval JS, log debug, handle error or success.
fn notifyCodeActExecution(loop: *AgentLoop, js_code: []const u8) void {
    if (loop.plan.plan_active and !AgentLoop.isPlanOnlyRequest(loop.current_user_request)) {
        if (std.mem.indexOf(u8, js_code, "file_edit") != null or
            std.mem.indexOf(u8, js_code, "file_write") != null or
            std.mem.indexOf(u8, js_code, "write") != null)
        {
            loop.plan.clearPlan();
        }
    }
    if (main.ui_repl.current_renderer) |r| {
        r.startTool("codeact", "{}");
    } else {
        main.stderrPrint("\x1b[90m[codeact]\x1b[0m \x1b[35mExecuting CodeAct script...\x1b[0m ", .{});
    }
}

/// Executes a CodeAct JavaScript script in QuickJS engine with loop protection and output formatting.
pub fn executeCodeActBlock(
    loop: *AgentLoop,
    act_id: usize,
    input_msgs_count: usize,
    tool_defs: []const proto.ToolDefinition,
    response: *const proto.Response,
    js_code: []const u8,
) !StepResult {
    const js_loop_check = if (loop.config.prompt_enforcement_enabled)
        loop.checkActionLoop("codeact", js_code) catch .allow
    else
        @as(@TypeOf(loop.checkActionLoop("codeact", js_code) catch .allow), .allow);
    if (js_loop_check == .trip) {
        return handleCodeActLoopTrip(loop, act_id);
    }

    // PSEUDOCODE: On .warn (identical script repeated this turn), serve cached
    // output instead of re-running the script a second time.
    if (js_loop_check == .warn) {
        const cache_hash = agent_loop_monitor.fuzzyArgsHash(js_code);
        if (loop.lookupToolCache("codeact", cache_hash)) |cached| {
            if (main.ui_repl.current_renderer) |r| {
                r.startTool("codeact", "{}");
                r.finishTool("codeact", cached, false, 0, null, null);
            } else {
                main.stderrPrint("\x1b[33m[duplicate codeact: serving cached result]\x1b[0m\n", .{});
            }
            const note = try std.fmt.allocPrint(
                loop.alloc,
                prompts_mod.codeact_cached_result_fmt,
                .{cached},
            );
            defer loop.alloc.free(note);
            try loop.history.addUser(note);
            loop.last_step_outcome = .actions_executed;
            return proto.ActTransition{ .next_act = {} };
        }
    }

    notifyCodeActExecution(loop, js_code);
    const start_codeact_ms: u64 = @as(u64, @intCast(utils.milliTimestamp()));

    signals.registerActiveEngine(loop.engine);
    defer signals.registerActiveEngine(null);
    loop.coordinator.updateStatus(act_id, .executing_codeact, "Running QuickJS script");

    var res = loop.engine.eval(js_code, "agent_codeact.js") catch |e| {
        return handleCodeActEvalError(loop, act_id, input_msgs_count, tool_defs, response, js_code, start_codeact_ms, e);
    };
    defer res.deinit();
    loop.engine.deinitSeenCalls(loop.engine.alloc);

    const end_codeact_ms: u64 = @as(u64, @intCast(utils.milliTimestamp()));
    const dur_ms = if (end_codeact_ms >= start_codeact_ms) @as(u64, @intCast(end_codeact_ms - start_codeact_ms)) else 0;

    loop.logActDebug(act_id, input_msgs_count, tool_defs, response, js_code, .{
        .exec_type = "codeact",
        .stdout = res.stdout,
        .return_value_json = res.return_value_json,
        .is_error = res.is_error,
        .duration_ms = dur_ms,
        .error_message = res.error_message,
    });

    if (signals.isInterrupted()) return error.Interrupted;

    if (!res.is_error) {
        // Cache output so an identical script replayed this turn can be served
        // from cache instead of re-executed (see .warn handling above).
        loop.storeToolCache("codeact", agent_loop_monitor.fuzzyArgsHash(js_code), if (res.return_value_json) |ret| ret else res.stdout) catch {};
        return handleCodeActSuccess(loop, res, dur_ms);
    } else {
        return handleCodeActScriptError(loop, res, dur_ms);
    }
}

fn responseRecoveryBackoffSeconds(recovery_class: proto.RecoveryClass, attempt: usize) u64 {
    // PSEUDOCODE:
    // 1. Retry empty missing-terminal streams with exponential backoff.
    // 2. Cap the delay at four seconds across the bounded retry budget.
    // 3. Keep the other response recovery paths immediate.
    if (recovery_class != .missing_terminal) return 0;
    return switch (attempt) {
        0 => 0,
        1 => 1,
        2 => 2,
        else => 4,
    };
}

fn nextResponseRecoveryTransition(
    validity: proto.ResponseValidity,
    gen_stop: proto.GenerationStop,
    budget: *proto.ResponseRecoveryBudget,
) !?proto.ActTransition {
    // PSEUDOCODE:
    // 1. Resolve the independent failure-class recovery budget.
    // 2. Preserve Act identity for retries that still have capacity.
    // 3. Fail repeated empty missing-terminal streams as provider unavailability.
    // 4. Return a typed stall when another recovery class is exhausted.
    const class = proto.responseRecoveryClass(validity, gen_stop) orelse return null;
    if (budget.consume(class) == .retry) {
        return proto.ActTransition{ .retry_same_act = {} };
    }
    if (class == .missing_terminal and validity == .empty and gen_stop == .missing_terminal_event) {
        return proto.ActTransition{ .fail = .provider_unavailable };
    }
    return proto.ActTransition{ .stall = .recovery_budget_exhausted };
}

test "Act 52 provider failure recovers then stalls on thinking loop" {
    var budget = proto.ResponseRecoveryBudget{};

    // Act 52, attempt 1: HTTP 500 is a provider failure.
    const provider_failure = proto.ActTransition{ .fail = .provider_error };
    try std.testing.expectEqual(proto.FailureReason.provider_error, provider_failure.fail);

    // Act 52, attempt 2: successful HTTP 200 thinking-only response retries with nudge.
    const recovery_1 = (try nextResponseRecoveryTransition(.thinking_only, .natural_end, &budget)).?;
    try std.testing.expect(recovery_1 == .retry_same_act);

    // Act 52, attempt 3: 2nd consecutive thinking-only response exhausts budget and stalls.
    const stalled = (try nextResponseRecoveryTransition(.thinking_only, .natural_end, &budget)).?;
    try std.testing.expectEqual(proto.StallReason.recovery_budget_exhausted, stalled.stall);
}

test "recovery exhaustion records transient retry while stalling" {
    var loop: AgentLoop = undefined;
    markRecoveryExhausted(&loop);
    try std.testing.expectEqual(proto.StepOutcome.transient_retry, loop.last_step_outcome);
    try std.testing.expectEqual(proto.TurnOutcome.stalled, loop.last_turn_outcome);
}

test "missing-terminal recovery uses capped exponential retry backoff" {
    try std.testing.expectEqual(@as(u64, 0), responseRecoveryBackoffSeconds(.missing_terminal, 0));
    try std.testing.expectEqual(@as(u64, 1), responseRecoveryBackoffSeconds(.missing_terminal, 1));
    try std.testing.expectEqual(@as(u64, 2), responseRecoveryBackoffSeconds(.missing_terminal, 2));
    try std.testing.expectEqual(@as(u64, 4), responseRecoveryBackoffSeconds(.missing_terminal, 3));
    try std.testing.expectEqual(@as(u64, 4), responseRecoveryBackoffSeconds(.missing_terminal, 4));
    try std.testing.expectEqual(@as(u64, 0), responseRecoveryBackoffSeconds(.empty_response, 1));
}

test "repeated empty missing-terminal response fails as provider unavailable" {
    // PSEUDOCODE:
    // 1. Configure a three-retry missing-terminal budget for this focused boundary test.
    // 2. Verify the first three responses retry the same Act.
    // 3. Verify the next response fails as provider unavailable.
    var budget = proto.ResponseRecoveryBudget{ .missing_terminal = 3 };

    for (0..3) |_| {
        const transition = (try nextResponseRecoveryTransition(
            .empty,
            .missing_terminal_event,
            &budget,
        )).?;
        try std.testing.expect(transition == .retry_same_act);
    }

    const transition = (try nextResponseRecoveryTransition(
        .empty,
        .missing_terminal_event,
        &budget,
    )).?;
    try std.testing.expectEqual(proto.FailureReason.provider_unavailable, transition.fail);
}

test "valid action resets max-token continuation budget" {
    var loop: AgentLoop = undefined;
    loop.max_tokens_continues = 5;
    markValidActionProgress(&loop);
    try std.testing.expectEqual(@as(usize, 0), loop.max_tokens_continues);
}

test "stop-sequence continuation is bounded and eventually stalls" {
    var count: usize = 0;
    for (0..5) |_| try std.testing.expect(stopSequenceContinuation(&count) == .next_act);
    try std.testing.expectEqual(proto.StallReason.recovery_budget_exhausted, stopSequenceContinuation(&count).stall);
    try std.testing.expectEqual(@as(usize, 6), count);
}

fn stopSequenceContinuation(count: *usize) proto.ActTransition {
    // PSEUDOCODE:
    // 1. Bound controlled stop-sequence continuations.
    // 2. Stall after five resume boundaries.
    count.* += 1;
    if (count.* <= 5) return .{ .next_act = {} };
    return .{ .stall = .recovery_budget_exhausted };
}

fn markRecoveryExhausted(loop: *AgentLoop) void {
    // PSEUDOCODE:
    // 1. Preserve the business outcome as stalled.
    // 2. Report exhausted transient recovery as the immediate step outcome.
    loop.last_step_outcome = .transient_retry;
    loop.last_turn_outcome = .stalled;
}

fn markValidActionProgress(loop: *AgentLoop) void {
    // PSEUDOCODE:
    // 1. Treat a valid action as a recovery boundary.
    // 2. Reset consecutive continuation pressure for later truncation.
    loop.response_recovery_budget = .{};
    loop.max_tokens_continues = 0;
    loop.stop_sequence_continues = 0;
}

/// P0-B: Build a thinking-tail hint for a truncated (max_tokens) thinking-only response.
/// PSEUDOCODE:
/// 1. Scan response content for the LAST thinking block; a verification signature
///    means a complete block we should not fragment, so skip entirely.
/// 2. Take up to max_chars bytes from the END of the thinking text.
/// 3. Walk back to a valid UTF-8 start boundary (byte class 0xxxxxxx or 11xxxxxx).
/// 4. If the tail trims to empty, return null.
/// 5. Compose a resume advisory embedding the tail.
/// 6. Allocate the result via the provided allocator; caller frees.
fn buildThinkingTailHint(alloc: std.mem.Allocator, response: *const proto.Response, max_chars: usize) ?[]const u8 {
    var last_thinking: ?proto.ThinkingBlock = null;
    for (response.content.items) |block| {
        if (block == .thinking) last_thinking = block.thinking;
    }
    if (last_thinking == null) return null;
    const th = last_thinking.?;
    // A non-empty signature means a complete/verified thinking block; do not fragment it.
    if (th.signature.len > 0) return null;

    const text = th.thinking;
    const start = if (text.len <= max_chars) 0 else @min(text.len - max_chars, text.len);
    // Walk back to a UTF-8 start boundary (lead byte 0xxxxxxx or 11xxxxxx).
    var i = start;
    while (i < text.len) {
        const b = text[i];
        if ((b & 0b11000000) != 0b10000000) break; // lead byte or ASCII: valid start
        i += 1;
    }
    const tail = text[i..];
    if (std.mem.trim(u8, tail, " \r\n\t").len == 0) return null;

    const tail_trimmed = std.mem.trim(u8, tail, " \r\n\t");
    if (tail_trimmed.len == 0) return null;

    // Single contiguous allocation; caller owns and frees it.
    return std.fmt.allocPrint(
        alloc,
        prompts_mod.thinking_tail_hint_fmt,
        .{tail_trimmed},
    ) catch return null;
}

fn handleResponseRecovery(
    loop: *AgentLoop,
    act_id: usize,
    input_msgs_count: usize,
    tool_defs: []const proto.ToolDefinition,
    response: *const proto.Response,
    validity: proto.ResponseValidity,
    gen_stop: proto.GenerationStop,
    history_checkpoint: usize,
) !StepResult {
    const recovery_class: proto.RecoveryClass = proto.responseRecoveryClass(validity, gen_stop) orelse {
        loop.history.truncate(history_checkpoint);
        loop.last_step_outcome = .protocol_failure;
        loop.last_turn_outcome = .failed;
        return proto.ActTransition{ .fail = .protocol_error };
    };
    loop.last_recovery_class = recovery_class;

    loop.logActDebug(act_id, input_msgs_count, tool_defs, response, null, .{
        .exec_type = "response_recovery",
        .is_error = true,
        .error_message = @tagName(validity),
    });

    // PSEUDOCODE:
    // 1. Roll back any previous retry attempt's advisory back to act_history_checkpoint.
    // 2. Consume budget: if retrying same act, append exactly one advisory.
    // 3. If failing or stalling, ensure history remains cleanly truncated at act checkpoint.
    loop.history.truncate(history_checkpoint);

    const transition = (try nextResponseRecoveryTransition(validity, gen_stop, &loop.response_recovery_budget)).?;
    if (transition == .retry_same_act) {
        loop.turn_recovery_attempts += 1;
        loop.last_agent_decision = .retry_transient;
        loop.last_step_outcome = .transient_retry;

        const advisory = switch (recovery_class) {
            .thinking_only, .thinking_loop => prompts_mod.recovery_advisory_thinking_only,
            .empty_response => prompts_mod.recovery_advisory_empty_response,
            .missing_terminal => prompts_mod.recovery_advisory_missing_terminal,
            .stream_aborted => prompts_mod.recovery_advisory_stream_aborted,
            .malformed_tool_call => prompts_mod.recovery_advisory_malformed_tool_call,
            .truncated_tool_call => prompts_mod.recovery_advisory_truncated_tool_call,
        };
        try loop.history.addUser(advisory);

        // P0-B: when a thinking-only response was truncated at max_tokens, append a
        // short UTF-8-safe tail of the reasoning so the model resumes instead of
        // re-deriving completed analysis. Only when there is no verification
        // signature (a signature implies a complete thinking block we should not
        // fragment) and when the tail is non-empty after trimming.
        if (recovery_class == .thinking_only and gen_stop == .max_tokens) {
            const thinking_tail = buildThinkingTailHint(loop.alloc, response, 512);
            if (thinking_tail) |hint| {
                defer loop.alloc.free(hint);
                try loop.history.addUser(hint);
            }
        }

        const backoff_s = responseRecoveryBackoffSeconds(recovery_class, loop.turn_recovery_attempts);
        if (backoff_s > 0) {
            try loop.waitWithInplaceCountdown(backoff_s, loop.turn_recovery_attempts, 1);
        }
        return transition;
    }

    if (transition == .fail) {
        loop.history.truncate(history_checkpoint);
        loop.last_step_outcome = .provider_failure;
        loop.last_turn_outcome = .failed;
        return transition;
    }

    loop.history.truncate(history_checkpoint);
    loop.last_agent_decision = .fail_stalled;
    if (recovery_class == .thinking_only) {
        loop.last_recovery_class = .thinking_loop;
        if (main.ui_repl.current_renderer) |r| {
            r.renderInplaceLine("\x1b[33m[agent] ⚠️ Thinking loop detected: model reasoned without taking action on consecutive attempts. Stalling.\x1b[0m\n");
        } else if (!utils.isSubagent()) {
            main.stderrPrint("\x1b[33m[agent] ⚠️ Thinking loop detected: model reasoned without taking action on consecutive attempts. Stalling.\x1b[0m\n", .{});
        }
    }
    markRecoveryExhausted(loop);
    return transition;
}

fn finalAnswerWatchdogTransition(watchdog_action: anytype) proto.ActTransition {
    // PSEUDOCODE:
    // 1. Only a valid final-text candidate reaches the watchdog.
    // 2. Continue-loop remains pending; exhaustion stalls; no-action completes.
    return switch (watchdog_action) {
        .continue_loop => .{ .next_act = {} },
        .exit_loop => .{ .stall = .plan_stalled },
        .no_action => .{ .complete = {} },
        else => unreachable,
    };
}

test "watchdog maps exhaustion to stall and no-action to completion" {
    try std.testing.expect(finalAnswerWatchdogTransition(.continue_loop) == .next_act);
    try std.testing.expectEqual(
        proto.StallReason.plan_stalled,
        finalAnswerWatchdogTransition(.exit_loop).stall,
    );
    try std.testing.expect(finalAnswerWatchdogTransition(.no_action) == .complete);
}

fn handleEndTurnStop(
    loop: *AgentLoop,
    act_id: usize,
    input_msgs_count: usize,
    tool_defs: []const proto.ToolDefinition,
    response: *const proto.Response,
) !StepResult {
    loop.logActDebug(act_id, input_msgs_count, tool_defs, response, null, .{ .exec_type = "none" });
    const watchdog_action = if (loop.config.prompt_enforcement_enabled)
        loop.plan.handleEndTurnWatchdog(loop.current_user_request, loop.hasRecentVerifiedMutation())
    else
        @as(@TypeOf(loop.plan.handleEndTurnWatchdog(loop.current_user_request, loop.hasRecentVerifiedMutation())), .no_action);
    switch (watchdog_action) {
        .continue_loop => {
            loop.last_agent_decision = .request_continuation;
            loop.last_step_outcome = .continuation_requested;
            if (main.ui_repl.current_renderer) |r| {
                r.ensureNewline();
                r.write(" \x1b[33m[Plan Watchdog: Plan declared without execution. Enforcing Step 1 execution]\x1b[0m\n");
            }
            if (loop.plan.getWatchdogDirective(loop.alloc)) |directive| {
                defer loop.alloc.free(directive);
                try loop.history.addUser(directive);
            }
            return finalAnswerWatchdogTransition(.continue_loop);
        },
        .exit_loop => {
            loop.last_agent_decision = .fail_stalled;
            loop.last_step_outcome = .protocol_failure;
            loop.last_turn_outcome = .stalled;
            return finalAnswerWatchdogTransition(.exit_loop);
        },
        .no_action => {
            loop.last_agent_decision = .deliver_final_answer;
            loop.last_step_outcome = .final_answer;
            loop.last_turn_outcome = .completed;
            if (main.ui_repl.current_renderer == null and !utils.isSubagent()) {
                main.stderrPrint("\n\x1b[92m[agent] ✓ Completed after {d} loops.\x1b[0m\n", .{act_id});
            }
            return finalAnswerWatchdogTransition(.no_action);
        },
    }
}

fn handleMaxTokensStop(
    loop: *AgentLoop,
    act_id: usize,
    input_msgs_count: usize,
    tool_defs: []const proto.ToolDefinition,
    response: *const proto.Response,
) !StepResult {
    loop.logActDebug(act_id, input_msgs_count, tool_defs, response, null, .{ .exec_type = "max_tokens" });
    loop.max_tokens_continues += 1;
    if (loop.max_tokens_continues > 5) {
        main.stderrPrint("\n\x1b[31m[agent] ⛔ Continued max_tokens {d} consecutive times without completion. Stopping to prevent infinite loop.\x1b[0m\n", .{loop.max_tokens_continues});
        loop.last_step_outcome = .protocol_failure;
        loop.last_turn_outcome = .stalled;
        return proto.ActTransition{ .stall = .recovery_budget_exhausted };
    }
    main.stderrPrint("\n\x1b[33m[agent] ⚠️ Response truncated (max_tokens), requesting continuation ({d}/5)...\x1b[0m\n", .{loop.max_tokens_continues});
    var buf = utils.BufWriter.init(loop.alloc);
    defer buf.deinit();
    try buf.print(
        prompts_mod.max_tokens_continuation_fmt,
        .{loop.max_tokens_continues},
    );
    try loop.history.addUser(buf.list.items);
    loop.last_step_outcome = .continuation_requested;
    return proto.ActTransition{ .next_act = {} };
}

fn handleToolUseStop(
    loop: *AgentLoop,
    act_id: usize,
    input_msgs_count: usize,
    tool_defs: []const proto.ToolDefinition,
    response: *const proto.Response,
    has_tool_use_blocks: bool,
) !StepResult {
    if (has_tool_use_blocks) {
        const exec_summary = try loop.executeTools(act_id, response);
        loop.logActDebug(act_id, input_msgs_count, tool_defs, response, null, .{
            .exec_type = "tool_call",
            .is_error = exec_summary.any_tool_err,
            .duration_ms = exec_summary.total_dur_ms,
        });
        main.stderrPrint("\n", .{});
        if (loop.action_loop_tripped) {
            loop.last_turn_outcome = .stalled;
            return .exit_stalled;
        }
        return .continue_loop;
    }
    loop.logActDebug(act_id, input_msgs_count, tool_defs, response, null, .{ .exec_type = "none" });
    loop.last_turn_outcome = .stalled;
    return .exit_stalled;
}

fn handleStreamAbortedStop(
    loop: *AgentLoop,
    act_id: usize,
    input_msgs_count: usize,
    tool_defs: []const proto.ToolDefinition,
    response: *const proto.Response,
) !StepResult {
    loop.logActDebug(act_id, input_msgs_count, tool_defs, response, null, .{
        .exec_type = "stream_idle_timeout",
        .is_error = true,
        .error_message = "stream aborted by idle watchdog",
    });
    var has_tool_use = false;
    for (response.content.items) |block| {
        if (block == .tool_use) {
            has_tool_use = true;
            break;
        }
    }
    if (has_tool_use) {
        loop.last_act_failed = true;
        const exec_summary = try loop.executeTools(act_id, response);
        loop.logActDebug(act_id, input_msgs_count, tool_defs, response, null, .{
            .exec_type = "tool_call",
            .is_error = exec_summary.any_tool_err,
            .duration_ms = exec_summary.total_dur_ms,
        });
        if (loop.action_loop_tripped) {
            return .exit_loop;
        }
        return .continue_loop;
    }
    if (response.content.items.len == 0) {
        loop.last_act_failed = true;
        main.stderrPrint("\n\x1b[33m[agent] ⚠️ Stream stalled (idle watchdog), retrying...\x1b[0m\n", .{});
        return error.LLMProviderUnavailable;
    }
    loop.last_act_failed = true;
    main.stderrPrint("\n\x1b[33m[agent] ⚠️ Stream stalled mid-response, requesting continuation...\x1b[0m\n", .{});
    try loop.closeOrphanedToolUses(response);
    const note = prompts_mod.idle_stream_continuation;
    try loop.history.addUser(note);
    return .continue_loop;
}

fn checkContextExceededHttp400(raw: []const u8) !void {
    const is_param_max_tokens = std.mem.indexOf(u8, raw, "\"param\":\"max_tokens\"") != null or
        std.mem.indexOf(u8, raw, "\"param\": \"max_tokens\"") != null or
        std.mem.indexOf(u8, raw, "`max_tokens` must be less than") != null;

    if (!is_param_max_tokens) {
        if (std.mem.indexOf(u8, raw, "context_length_exceeded") != null or
            std.mem.indexOf(u8, raw, "maximum context length") != null or
            std.mem.indexOf(u8, raw, "context length") != null or
            std.mem.indexOf(u8, raw, "prompt is too long") != null or
            (std.mem.indexOf(u8, raw, "context_window") != null and std.mem.indexOf(u8, raw, "exceeded") != null))
        {
            return error.LLMContextWindowExceeded;
        }
    }
}

fn checkRoleCompatibilityHttp400(loop: *AgentLoop, raw: []const u8) ?StepResult {
    const has_first_msg = std.mem.indexOf(u8, raw, "first message") != null;
    const has_role_and_assistant = std.mem.indexOf(u8, raw, "role") != null and
        std.mem.indexOf(u8, raw, "assistant") != null;
    if (has_first_msg or has_role_and_assistant) {
        main.stderrPrint("\n\x1b[33m[agent] Claude rejected due to role ordering (HTTP 400). Fixing history...\x1b[0m\n", .{});
        _ = loop.history.ensureClaudeCompatible();
        if (loop.role_fix_attempts < 2) {
            loop.role_fix_attempts += 1;
            return proto.ActTransition{ .next_act = {} };
        }
    }

    const has_orphan_tool = std.mem.indexOf(u8, raw, "No tool call found for function call output") != null or
        std.mem.indexOf(u8, raw, "tool_call_id") != null;
    if (has_orphan_tool) {
        main.stderrPrint("\n\x1b[33m[agent] OpenAI rejected due to orphan tool_result (HTTP 400). Fixing history...\x1b[0m\n", .{});
        _ = loop.history.ensureOpenAICompatible();
        if (loop.role_fix_attempts < 2) {
            loop.role_fix_attempts += 1;
            return proto.ActTransition{ .next_act = {} };
        }
    }
    return null;
}

fn handleUnknownStopReason(
    loop: *AgentLoop,
    act_id: usize,
    input_msgs_count: usize,
    tool_defs: []const proto.ToolDefinition,
    response: *const proto.Response,
) !StepResult {
    loop.logActDebug(act_id, input_msgs_count, tool_defs, response, null, .{
        .exec_type = "error",
        .is_error = true,
        .error_message = response.raw_debug_info,
    });
    if (response.http_code >= 400) {
        loop.setLastErrorContext(response.http_code, response.raw_debug_info);
    }
    if (response.http_code == 401 or response.http_code == 403) return error.LLMAuthenticationError;
    if (response.http_code == 429) return error.LLMRateLimitExceeded;
    if (response.http_code >= 500 and response.http_code < 600) return error.LLMProviderUnavailable;

    if (response.http_code == 400) {
        if (response.raw_debug_info) |raw| {
            try checkContextExceededHttp400(raw);
            if (checkRoleCompatibilityHttp400(loop, raw)) |step_res| {
                return step_res;
            }
        }
    }

    if (response.raw_debug_info) |raw| {
        if (std.mem.indexOf(u8, raw, "rate_limit") != null) return error.LLMRateLimitExceeded;
    }

    if (main.ui_repl.current_renderer) |r| {
        r.stopWaiting();
        if (r.is_thinking) r.endThinking();
        r.ensureNewline();
    }
    main.stderrPrint("[agent] Warning: unknown stop_reason (HTTP {d})\n", .{response.http_code});
    AgentLoop.printRawBackendResponse(response.raw_debug_info, response.http_code);
    loop.setLastErrorContext(response.http_code, response.raw_debug_info);
    return error.UnknownStopReason;
}

/// Dispatches stop reasons (.end_turn, .max_tokens, .tool_use, .stream_aborted, .unknown)
pub fn dispatchStopReason(
    loop: *AgentLoop,
    act_id: usize,
    input_msgs_count: usize,
    tool_defs: []const proto.ToolDefinition,
    response: *const proto.Response,
    has_tool_use_blocks: bool,
) !StepResult {
    switch (response.stop_reason) {
        .end_turn => {
            if (loop.last_response_validity == .thinking_only or
                loop.last_response_validity == .whitespace_only or
                loop.last_response_validity == .empty)
            {
                return handleResponseRecovery(loop, act_id, input_msgs_count, tool_defs, response, loop.last_response_validity, loop.last_generation_stop, loop.act_history_checkpoint);
            }
            return handleEndTurnStop(loop, act_id, input_msgs_count, tool_defs, response);
        },
        .missing_terminal_event => return handleResponseRecovery(loop, act_id, input_msgs_count, tool_defs, response, loop.last_response_validity, loop.last_generation_stop, loop.act_history_checkpoint),
        .stop_sequence => return handleResponseRecovery(loop, act_id, input_msgs_count, tool_defs, response, .partial_text, loop.last_generation_stop, loop.act_history_checkpoint),
        .max_tokens => return handleMaxTokensStop(loop, act_id, input_msgs_count, tool_defs, response),
        .tool_use => return handleToolUseStop(loop, act_id, input_msgs_count, tool_defs, response, has_tool_use_blocks),
        .stream_aborted => return handleStreamAbortedStop(loop, act_id, input_msgs_count, tool_defs, response),
        .content_filter, .provider_error, .unknown => return handleUnknownStopReason(loop, act_id, input_msgs_count, tool_defs, response),
    }
}

fn renderStepHeader(self: *AgentLoop, act_id: usize) !void {
    if (signals.isInterrupted() or self.coordinator.isTimedOut()) return error.Interrupted;

    self.coordinator.updateStatus(act_id, .calling_llm, "Calling LLM backend");

    if (main.ui_repl.current_renderer == null and !utils.isSubagent()) {
        if (act_id > 1) {
            main.stderrPrint("\x1b[90m[agent] --- Loop {d} ---\x1b[0m\n", .{act_id});
        } else {
            main.stderrPrint("\n\x1b[90m[agent] --- Starting workflow ---\x1b[0m\n", .{});
        }
        main.stderrPrint("\x1b[36m[agent]\x1b[0m \x1b[93mThinking / Analyzing request... \x1b[0m\n", .{});
    }
}

fn prepareStepInputMessages(
    self: *AgentLoop,
    act_id: usize,
    temp_msgs: *std.ArrayListUnmanaged(proto.Message),
    input_msgs_count: *usize,
) !GuidanceProgressContext {
    _ = self.backend.sanitizeHistory(&self.history);
    input_msgs_count.* = self.history.len();
    const input_msgs = self.history.messages()[0..input_msgs_count.*];
    try temp_msgs.appendSlice(self.alloc, input_msgs);

    var guidance_ctx = GuidanceProgressContext.init();
    try guidance_ctx.inject(self, act_id, temp_msgs);
    modulateReasoningEffort(self, act_id);
    return guidance_ctx;
}

fn extractAssistantText(alloc: std.mem.Allocator, response: *const proto.Response) ?[]u8 {
    var total_len: usize = 0;
    for (response.content.items) |block| {
        if (block == .text) {
            total_len += block.text.len;
        }
    }
    if (total_len == 0) return null;

    const buf = alloc.alloc(u8, total_len) catch return null;
    var offset: usize = 0;
    for (response.content.items) |block| {
        if (block == .text) {
            @memcpy(buf[offset .. offset + block.text.len], block.text);
            offset += block.text.len;
        }
    }
    return buf;
}

fn executeNativeToolCalling(
    self: *AgentLoop,
    act_id: usize,
    input_msgs_count: usize,
    tool_defs: []const proto.ToolDefinition,
    response: *const proto.Response,
) !StepResult {
    const exec_summary = try self.executeTools(act_id, response);
    self.logActDebug(act_id, input_msgs_count, tool_defs, response, null, .{
        .exec_type = "tool_call",
        .is_error = exec_summary.any_tool_err,
        .duration_ms = exec_summary.total_dur_ms,
    });
    main.stderrPrint("\n", .{});
    if (self.action_loop_tripped) {
        self.last_step_outcome = .protocol_failure;
        self.last_turn_outcome = .stalled;
        return proto.ActTransition{ .stall = .action_loop };
    }
    self.last_step_outcome = .actions_executed;
    return proto.ActTransition{ .next_act = {} };
}

pub fn executeStep(
    self: *AgentLoop,
    act_id: usize,
    tool_defs: []const proto.ToolDefinition,
    text_cb: ?*const fn ([]const u8) void,
    think_cb: ?*const fn ([]const u8) void,
) !StepResult {
    try renderStepHeader(self, act_id);

    self.last_act_usage = null;
    self.last_act_context_tokens = null;

    const history_checkpoint = self.act_history_checkpoint;

    var input_msgs_count: usize = 0;
    var temp_input_msgs = std.ArrayListUnmanaged(proto.Message).empty;
    defer temp_input_msgs.deinit(self.alloc);

    var guidance_ctx = try prepareStepInputMessages(self, act_id, &temp_input_msgs, &input_msgs_count);
    defer guidance_ctx.deinit(self.alloc);

    // Step-scoped subagent dispatch + two-stage review gate.
    // When the active step requests subagent/parallel executor mode and the
    // feature is enabled, dispatch it (and optionally review it) ahead of the
    // LLM step, then surface the outcome to the model as a user message.
    var p4_note: ?[]const u8 = null;
    var p4_blocks: ?[]proto.ContentBlock = null;
    if (self.maybeDispatchPlanStep(act_id) catch null) |note| {
        const blocks = try self.alloc.alloc(proto.ContentBlock, 1);
        blocks[0] = .{ .text = note };
        try temp_input_msgs.append(self.alloc, .{ .role = .user, .content = blocks });
        p4_note = note;
        p4_blocks = blocks;
    }
    // Freed at act end (after sendToBackend below has consumed the message).
    defer if (p4_note) |n| self.alloc.free(n);
    defer if (p4_blocks) |b| self.alloc.free(b);

    var response = try self.sendToBackend(
        act_id,
        self.config.system_prompt,
        temp_input_msgs.items,
        tool_defs,
        text_cb,
        think_cb,
    );
    main.resetThinkState();
    if (signals.isInterrupted() or self.coordinator.isTimedOut()) {
        response.deinit();
        self.last_step_outcome = .cancelled;
        self.last_turn_outcome = .cancelled;
        return proto.ActTransition{ .cancel = {} };
    }
    defer response.deinit();

    if (main.ui_repl.current_renderer == null) {
        try std.Io.File.stdout().writeStreamingAll(self.io, "\n");
    }

    const gen_stop = response.getGenerationStop();
    self.last_generation_stop = gen_stop;
    self.last_act_usage = if (response.usage.prompt_tokens > 0 or response.usage.completion_tokens > 0 or response.usage.reasoning_tokens > 0) .{
        .input_tokens = response.usage.prompt_tokens,
        .output_tokens = response.usage.completion_tokens,
        .reasoning_tokens = response.usage.reasoning_tokens,
    } else null;
    self.last_act_context_tokens = @as(usize, self.token_estimator.estimateMessages(temp_input_msgs.items));
    if (self.journal) |*j| j.recordEvent(self.io, act_id, .llm_generation_ended, "LLM generation ended") catch {};

    if (response.http_code >= 400) {
        self.setLastErrorContext(response.http_code, response.raw_debug_info);
        if (response.http_code == 401 or response.http_code == 403) return error.LLMAuthenticationError;
        if (response.http_code == 429) return error.LLMRateLimitExceeded;
        if (response.http_code >= 500 and response.http_code < 600) return error.LLMProviderUnavailable;
        if (response.http_code == 400) {
            if (response.raw_debug_info) |raw| {
                try checkContextExceededHttp400(raw);
                if (checkRoleCompatibilityHttp400(self, raw)) |res| return res;
            }
        }
    }

    const js_code_opt = if (self.config.execution_mode != .tools)
        agent_parsing.findJsCodeInResponse(self.alloc, &response)
    else
        null;
    defer if (js_code_opt) |c| self.alloc.free(c);
    const has_codeact = js_code_opt != null;

    const validity = proto.classifyResponse(&response, has_codeact);
    self.last_response_validity = validity;
    if (validity != .final_text and validity != .native_tool_calls and validity != .codeact) {
        if (self.journal) |*j| j.recordEvent(self.io, act_id, .llm_response_invalid, "Invalid LLM response payload") catch {};
    }

    const decision = proto.decideAgentAction(gen_stop, validity, false);
    self.last_agent_decision = decision;
    if (self.journal) |*j| j.recordEvent(self.io, act_id, .agent_decision, @tagName(decision)) catch {};

    switch (decision) {
        .cancel => {
            self.history.truncate(history_checkpoint);
            self.last_step_outcome = .cancelled;
            self.last_turn_outcome = .cancelled;
            return proto.ActTransition{ .cancel = {} };
        },
        .fail_protocol => {
            self.history.truncate(history_checkpoint);
            self.last_step_outcome = .protocol_failure;
            self.last_turn_outcome = .failed;
            return proto.ActTransition{ .fail = .protocol_error };
        },
        .fail_stalled => {
            self.history.truncate(history_checkpoint);
            self.last_step_outcome = .protocol_failure;
            self.last_turn_outcome = .stalled;
            return proto.ActTransition{ .stall = .recovery_budget_exhausted };
        },
        .retry_transient => {
            return handleResponseRecovery(self, act_id, input_msgs_count, tool_defs, &response, validity, gen_stop, history_checkpoint);
        },
        .execute_native_tools => {
            const was_added = try self.history.addAssistantResponse(&response);
            _ = scanResponseContent(self, &response, was_added);
            self.last_recovery_class = null;
            self.last_step_outcome = .actions_executed;
            markValidActionProgress(self);
            return executeNativeToolCalling(self, act_id, input_msgs_count, tool_defs, &response);
        },
        .execute_codeact => {
            const was_added = try self.history.addAssistantResponse(&response);
            _ = scanResponseContent(self, &response, was_added);
            self.last_recovery_class = null;
            self.last_step_outcome = .actions_executed;
            markValidActionProgress(self);
            return executeCodeActBlock(self, act_id, input_msgs_count, tool_defs, &response, js_code_opt.?);
        },
        .request_continuation => {
            // PSEUDOCODE:
            // 1. Roll back incomplete transport output that cannot be safely resumed.
            // 2. Commit explicit provider continuations such as max-token truncation.
            if (proto.responseRecoveryClass(validity, gen_stop)) |_| {
                return handleResponseRecovery(self, act_id, input_msgs_count, tool_defs, &response, validity, gen_stop, history_checkpoint);
            }

            const was_added = try self.history.addAssistantResponse(&response);
            _ = scanResponseContent(self, &response, was_added);
            // PSEUDOCODE:
            // 1. Interrupted partial responses are committed for safe continuation.
            // 2. Close every orphaned tool call without executing it.
            if (validity == .partial_text and switch (gen_stop) {
                .max_tokens, .stop_sequence, .missing_terminal_event, .stream_aborted => true,
                else => false,
            }) try self.closeOrphanedToolUses(&response);
            self.response_recovery_budget = .{};
            self.last_recovery_class = null;
            self.last_step_outcome = .continuation_requested;
            if (gen_stop == .max_tokens) {
                return handleMaxTokensStop(self, act_id, input_msgs_count, tool_defs, &response);
            }
            if (gen_stop == .stop_sequence) {
                // PSEUDOCODE:
                // 1. Keep partial text in history for a safe resume boundary.
                // 2. Bound controlled continuations and stall on repeated boundaries.
                try self.history.addUser(prompts_mod.stop_sequence_continuation);
                const transition = stopSequenceContinuation(&self.stop_sequence_continues);
                if (transition == .stall) {
                    self.last_step_outcome = .continuation_requested;
                    self.last_turn_outcome = .stalled;
                }
                return transition;
            }
            try self.history.addUser(prompts_mod.explicit_stop_continuation);
            return proto.ActTransition{ .next_act = {} };
        },
        .deliver_final_answer => {
            const was_added = try self.history.addAssistantResponse(&response);
            _ = scanResponseContent(self, &response, was_added);
            self.response_recovery_budget = .{};
            self.last_recovery_class = null;
            if (extractAssistantText(self.alloc, &response)) |text| {
                if (self.last_agent_message) |old| self.alloc.free(old);
                self.last_agent_message = text;
            }
            return handleEndTurnStop(self, act_id, input_msgs_count, tool_defs, &response);
        },
    }
}

// P0-B tests: thinking-tail hint builder.

fn makeThinkingResponse(alloc: std.mem.Allocator, thinking: []const u8, signature: []const u8) proto.Response {
    var response = proto.Response.init(alloc);
    // PSEUDOCODE:
    // 1. Dupe non-empty buffers into response-owned memory so that the
    //    caller's `response.deinit()` is the sole owner and frees them.
    // 2. Pass non-allocated (empty) slices through untouched, since
    //    deinit() only frees non-empty buffers.
    const th = if (thinking.len > 0) alloc.dupe(u8, thinking) catch unreachable else thinking;
    const sig = if (signature.len > 0) alloc.dupe(u8, signature) catch unreachable else signature;
    response.content.append(alloc, .{
        .thinking = .{
            .thinking = th,
            .signature = sig,
        },
    }) catch unreachable;
    return response;
}

test "P0-B: signed thinking block yields no tail hint" {
    const alloc = std.testing.allocator;
    var response = makeThinkingResponse(alloc, "abc", "sig");
    defer response.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), buildThinkingTailHint(alloc, &response, 512));
}

test "P0-B: short thinking yields full text in the hint" {
    const alloc = std.testing.allocator;
    var response = makeThinkingResponse(alloc, "analysis step 3", "");
    defer response.deinit();
    const hint_opt = buildThinkingTailHint(alloc, &response, 512);
    try std.testing.expect(hint_opt != null);
    const hint = hint_opt.?;
    defer alloc.free(hint);
    try std.testing.expect(std.mem.indexOf(u8, hint, "analysis step 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "truncated at the max_tokens limit") != null);
}

test "P0-B: long thinking keeps only the tail, not the head" {
    const alloc = std.testing.allocator;
    // 613-char ASCII text with a unique head marker; a 512-char tail must not include it.
    const pad: []const u8 = "b" ** 600;
    const text = std.mem.concat(alloc, u8, &.{ "HEAD_MARKER_ ", pad, ".done" }) catch unreachable;
    defer alloc.free(text);
    var response = makeThinkingResponse(alloc, text, "");
    defer response.deinit();
    const hint_opt = buildThinkingTailHint(alloc, &response, 512);
    try std.testing.expect(hint_opt != null);
    const hint = hint_opt.?;
    defer alloc.free(hint);
    // The head marker (at offset 0) is well outside the 512-char tail.
    try std.testing.expect(std.mem.indexOf(u8, hint, "HEAD_MARKER_") == null);
    // The tail ends at the very end of the original text.
    try std.testing.expect(std.mem.indexOf(u8, hint, ".done") != null);
    // The embedded tail (between the second blank line and the resume instruction) must be valid UTF-8.
    const tail_start: usize = std.mem.indexOf(u8, hint, "\n\nb") orelse {
        try std.testing.expect(false);
        unreachable;
    };
    const resume_idx = std.mem.indexOf(u8, hint, "Resume from that point") orelse unreachable;
    try std.testing.expect(std.unicode.utf8ValidateSlice(hint[tail_start..resume_idx]));
}

test "P0-B: tail cut respects UTF-8 boundaries" {
    const alloc = std.testing.allocator;
    // 1000 3-byte UTF-8 chars (一 = 0xE4 0xB8 0x80) on the stack; a 512-byte tail cut lands mid-sequence.
    var buf: [3000]u8 = undefined;
    for (buf[0..], 0..) |*b, idx| b.* = switch (idx % 3) {
        0 => 0xE4,
        1 => 0xB8,
        else => 0x80,
    };
    const text: []const u8 = buf[0..];
    var response = makeThinkingResponse(alloc, text, "");
    defer response.deinit();
    const hint_opt = buildThinkingTailHint(alloc, &response, 512);
    try std.testing.expect(hint_opt != null);
    const hint = hint_opt.?;
    defer alloc.free(hint);
    // The embedded tail must start at a valid UTF-8 boundary.
    const tail_start: usize = std.mem.indexOf(u8, hint, "\xe4\xb8\x80") orelse {
        try std.testing.expect(false);
        unreachable;
    };
    // Every byte from tail_start to the "Resume" marker must be valid UTF-8.
    const resume_idx = std.mem.indexOf(u8, hint, "Resume from that point") orelse unreachable;
    const tail_chunk = hint[tail_start..resume_idx];
    try std.testing.expect(std.unicode.utf8ValidateSlice(tail_chunk));
    // start = 3000 - 512 = 2488 lands on a continuation byte (2488 % 3 == 1); the walk
    // back reaches the next lead byte at 2490, so the tail holds 170 complete 3-byte chars.
    try std.testing.expectEqual(@as(usize, 170), std.mem.count(u8, tail_chunk, "\xe4\xb8\x80"));
}

test "P0-B: whitespace-only thinking yields no tail hint" {
    const alloc = std.testing.allocator;
    var response = makeThinkingResponse(alloc, "   \n\t  ", "");
    defer response.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), buildThinkingTailHint(alloc, &response, 512));
}

test "history rollback cleans retry advisories across multiple attempts" {
    // PSEUDOCODE:
    // 1. Establish baseline history with 1 user prompt.
    // 2. Attempt 1: transition is retry_same_act, adds 1 recovery advisory (len = baseline + 1).
    // 3. Attempt 2: truncates to baseline checkpoint, transition is retry_same_act, adds advisory (len = baseline + 1).
    // 4. Attempt 3: budget exhausted -> transition is fail, history stays cleanly truncated at baseline.
    const alloc = std.testing.allocator;
    var history = history_mod.History.init(alloc);
    defer history.deinit();

    try history.addUser("initial user prompt");
    const baseline_len = history.len();
    try std.testing.expectEqual(@as(usize, 1), baseline_len);

    var budget = proto.ResponseRecoveryBudget{ .missing_terminal = 2 };

    // Attempt 1: retry_same_act -> add advisory
    const t1 = (try nextResponseRecoveryTransition(.empty, .missing_terminal_event, &budget)).?;
    try std.testing.expect(t1 == .retry_same_act);
    try history.addUser(prompts_mod.recovery_advisory_missing_terminal);
    try std.testing.expectEqual(baseline_len + 1, history.len());

    // Attempt 2: rollback previous advisory, retry_same_act -> add advisory
    history.truncate(baseline_len);
    try std.testing.expectEqual(baseline_len, history.len());
    const t2 = (try nextResponseRecoveryTransition(.empty, .missing_terminal_event, &budget)).?;
    try std.testing.expect(t2 == .retry_same_act);
    try history.addUser(prompts_mod.recovery_advisory_missing_terminal);
    try std.testing.expectEqual(baseline_len + 1, history.len());

    // Attempt 3: rollback advisory, budget exhausted -> fail, history remains baseline
    history.truncate(baseline_len);
    const t3 = (try nextResponseRecoveryTransition(.empty, .missing_terminal_event, &budget)).?;
    try std.testing.expectEqual(proto.FailureReason.provider_unavailable, t3.fail);
    try std.testing.expectEqual(baseline_len, history.len());
}
