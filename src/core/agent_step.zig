//! Step execution logic for AgentLoop.
//!
//! Decomposes single-step execution (executeStep) into focused, testable lifecycle phases:
//! - GuidanceProgressContext: injects Procedural Graph (RFC-010) & Plan progress (RFC-019)
//! - modulateReasoningEffort: dynamic thinking / reasoning effort selection
//! - scanResponseContent: analyzes tokens, meaningful text, tool blocks, and plan detection
//! - executeCodeActBlock: handles QuickJS evaluation, action loop trips, and output formatting
//! - dispatchStopReason: dispatches end_turn, max_tokens, tool_use, stream_aborted, unknown

const std = @import("std");
const proto = @import("protocol.zig");
const utils = @import("utils.zig");
const signals = @import("signals.zig");
const main = @import("../main.zig");
const js_bindings = @import("../runtime/js_bindings.zig");
const chat_stream = @import("../ui/chat_stream.zig");
const media_gen_tool = @import("../tools/media_gen.zig");
const quickjs_engine = @import("../runtime/quickjs_engine.zig");
const ExecutionResult = quickjs_engine.ExecutionResult;
const agent_parsing = @import("agent_parsing.zig");
const agent_mod = @import("agent.zig");
const AgentLoop = agent_mod.AgentLoop;
const prompts_mod = @import("prompts.zig");
const agent_loop_monitor = @import("agent_loop_monitor.zig");

pub const StepResult = enum {
    continue_loop,
    retry_act,
    exit_loop,
    exit_stalled,
};

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
        // Procedural Graph (RFC-010): Prepare ephemeral situational guidance block
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

/// Dynamically modulates reasoning effort and thinking budget tokens based on overrides, error state, and stickiness.
pub fn modulateReasoningEffort(loop: *AgentLoop, act_id: usize) void {
    if (loop.config.reasoning_effort_disabled) return;

    var effective_effort: ?[]const u8 = loop.config.reasoning_effort;
    var effective_budget: ?u32 = loop.config.thinking_budget_tokens;

    // Priority 1: Explicit JS override via mini.setThinking
    if (js_bindings.consumePendingThinkingOverride()) |override| {
        if (override.effort) |eff| effective_effort = eff;
        if (override.budget_tokens) |bud| effective_budget = bud;
    } else if (loop.dynamic_thinking) {
        if (act_id == 1) {
            // Act 1: no model choice yet — start from config/default
            effective_effort = loop.config.reasoning_effort orelse "high";
            effective_budget = loop.config.thinking_budget_tokens orelse 4096;
        } else if (loop.last_act_failed or loop.js_retry_count > 0) {
            // Priority 3a: Error recovery safety net — escalate to high
            effective_effort = "high";
            effective_budget = 4096;
        } else {
            // Priority 3b: Sticky effort — sustain previous level across routine follow-ups
            effective_effort = loop.last_effort;
            effective_budget = loop.last_budget;
        }
    }

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
    loop.response_content_empty = !has_meaningful_text and !has_tool_use_blocks;

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
        return .continue_loop;
    } else {
        main.stderrPrint(
            "\n\x1b[33m[agent] ⚠️ Action loop persisted after replanning attempts: identical CodeAct script repeated. Halting loop.\x1b[0m\n",
            .{},
        );
        const trip_msg = "[CodeAct System Intervention]: Action loop persisted after multiple replanning attempts. Halting execution. Synthesize your findings and answer the user now.";
        try loop.history.addUser(trip_msg);
        loop.action_loop_tripped = true;
        loop.last_turn_outcome = .stalled;
        return .exit_stalled;
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
    return .continue_loop;
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
    return .continue_loop;
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

    try err_buf.writeAll("[CodeAct JavaScript Error]\n");
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
        try err_buf.writeAll("Notice: 3 consecutive JavaScript execution errors occurred. You may fall back to standard tool calling or simplify your code.\n");
    } else {
        try err_buf.writeAll("Please analyze the error and retry by outputting corrected JavaScript code inside ```js ... ``` block.\n");
    }

    try loop.history.addUser(err_buf.list.items);
    return .continue_loop;
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
    const js_loop_check = loop.checkActionLoop("codeact", js_code) catch .allow;
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
                "[duplicate: identical CodeAct script already executed this turn — cached output below]\n{s}",
                .{cached},
            );
            defer loop.alloc.free(note);
            try loop.history.addUser(note);
            return .continue_loop;
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

fn responseRecoveryClass(validity: proto.ResponseValidity, stop_reason: proto.StopReason) ?proto.RecoveryClass {
    // PSEUDOCODE:
    // 1. Map no-action response shapes to the RFC-023 recovery class.
    // 2. Preserve stop-reason information when it changes the recovery class.
    return switch (validity) {
        .thinking_only => .thinking_only,
        .whitespace_only, .empty => .empty_response,
        .partial_text => if (stop_reason == .missing_terminal_event) .missing_terminal else .stream_aborted,
        else => null,
    };
}

fn handleResponseRecovery(
    loop: *AgentLoop,
    act_id: usize,
    input_msgs_count: usize,
    tool_defs: []const proto.ToolDefinition,
    response: *const proto.Response,
    validity: proto.ResponseValidity,
) !StepResult {
    const class = responseRecoveryClass(validity, response.stop_reason) orelse return .continue_loop;
    // PSEUDOCODE:
    // 1. Log the unusable response before removing it from model-visible history.
    // 2. Rollback only the current Act's assistant message.
    // 3. Retry the same Act while the failure-class budget remains.
    // 4. End the turn as stalled when the bounded recovery class is exhausted.
    loop.logActDebug(act_id, input_msgs_count, tool_defs, response, null, .{
        .exec_type = "response_recovery",
        .is_error = true,
        .error_message = @tagName(validity),
    });
    loop.history.truncate(input_msgs_count);
    loop.last_turn_outcome = .stalled;

    const decision = loop.response_recovery_budget.consume(class);
    if (decision == .stalled) {
        loop.last_agent_decision = .fail_stalled;
        return .exit_stalled;
    }

    loop.turn_recovery_attempts += 1;
    loop.last_agent_decision = .retry_transient;
    try loop.history.addUser(prompts_mod.empty_response_advisory);
    return .retry_act;
}

fn handleEndTurnStop(
    loop: *AgentLoop,
    act_id: usize,
    input_msgs_count: usize,
    tool_defs: []const proto.ToolDefinition,
    response: *const proto.Response,
) !StepResult {
    // PSEUDOCODE:
    // 1. The response has already passed action/payload validation.
    // 2. Ask the plan watchdog for policy continuation.
    // 3. Only a valid final-text candidate can complete the turn.
    loop.logActDebug(act_id, input_msgs_count, tool_defs, response, null, .{ .exec_type = "none" });
    switch (loop.plan.handleEndTurnWatchdog(loop.current_user_request, loop.hasRecentVerifiedMutation())) {
        .continue_loop => {
            loop.last_agent_decision = .request_continuation;
            if (main.ui_repl.current_renderer) |r| {
                r.ensureNewline();
                r.write(" \x1b[33m[Plan Watchdog: Plan declared without execution. Enforcing Step 1 execution]\x1b[0m\n");
            }
            if (loop.plan.getWatchdogDirective(loop.alloc)) |directive| {
                defer loop.alloc.free(directive);
                try loop.history.addUser(directive);
            }
            return .continue_loop;
        },
        .exit_loop => {
            loop.last_agent_decision = .fail_stalled;
            loop.last_turn_outcome = .stalled;
            return .exit_stalled;
        },
        .no_action => {},
    }
    loop.last_agent_decision = .deliver_final_answer;
    loop.last_turn_outcome = .completed;
    if (main.ui_repl.current_renderer == null and !utils.isSubagent()) {
        main.stderrPrint("\n\x1b[92m[agent] ✓ Completed after {d} loops.\x1b[0m\n", .{act_id});
    }
    return .exit_loop;
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
        loop.last_turn_outcome = .stalled;
        return .exit_stalled;
    }
    main.stderrPrint("\n\x1b[33m[agent] ⚠️ Response truncated (max_tokens), requesting continuation ({d}/5)...\x1b[0m\n", .{loop.max_tokens_continues});
    try loop.closeOrphanedToolUses(response);
    var buf = utils.BufWriter.init(loop.alloc);
    defer buf.deinit();
    try buf.print(
        "[System] The previous response was truncated due to reaching the max_tokens limit (attempt {d}). Please continue EXACTLY from where it stopped — do not repeat already written content, do not re-introduce. If a ```js ... ``` block or tool call was in progress, complete the remainder.",
        .{loop.max_tokens_continues},
    );
    try loop.history.addUser(buf.list.items);
    return .continue_loop;
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
    const note = "[System] The previous response was interrupted because the model stream went silent (idle watchdog). Continue EXACTLY from where it stopped — do not repeat already written content.";
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
            return .continue_loop;
        }
    }

    const has_orphan_tool = std.mem.indexOf(u8, raw, "No tool call found for function call output") != null or
        std.mem.indexOf(u8, raw, "tool_call_id") != null;
    if (has_orphan_tool) {
        main.stderrPrint("\n\x1b[33m[agent] OpenAI rejected due to orphan tool_result (HTTP 400). Fixing history...\x1b[0m\n", .{});
        _ = loop.history.ensureOpenAICompatible();
        if (loop.role_fix_attempts < 2) {
            loop.role_fix_attempts += 1;
            return .continue_loop;
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
                return handleResponseRecovery(loop, act_id, input_msgs_count, tool_defs, response, loop.last_response_validity);
            }
            return handleEndTurnStop(loop, act_id, input_msgs_count, tool_defs, response);
        },
        .missing_terminal_event => return handleResponseRecovery(loop, act_id, input_msgs_count, tool_defs, response, loop.last_response_validity),
        .stop_sequence => return handleResponseRecovery(loop, act_id, input_msgs_count, tool_defs, response, .partial_text),
        .max_tokens => return handleMaxTokensStop(loop, act_id, input_msgs_count, tool_defs, response),
        .tool_use => return handleToolUseStop(loop, act_id, input_msgs_count, tool_defs, response, has_tool_use_blocks),
        .stream_aborted => return handleStreamAbortedStop(loop, act_id, input_msgs_count, tool_defs, response),
        .content_filter, .provider_error, .unknown => return handleUnknownStopReason(loop, act_id, input_msgs_count, tool_defs, response),
    }
}

fn renderStepHeader(self: *AgentLoop, act_id: usize) !void {
    if (signals.isInterrupted() or self.coordinator.isTimedOut()) return error.Interrupted;

    if (self.coordinator.popPendingRecapAdvisory()) |advisory| {
        defer self.alloc.free(advisory);
        try self.history.addUser(advisory);
    }

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
        self.last_turn_outcome = .stalled;
        return .exit_stalled;
    }
    return .continue_loop;
}

/// Executes a single agent step:
/// 1. Status and history preparation (watchdog recap, guidance, plan progress)
/// 2. Dynamic reasoning effort modulation
/// 3. AI backend streaming communication
/// 4. Plan detection & token tracking
/// 5. Tool execution or CodeAct evaluation or stop reason dispatching
fn tryExecuteCodeAct(
    self: *AgentLoop,
    act_id: usize,
    input_msgs_count: usize,
    tool_defs: []const proto.ToolDefinition,
    response: *const proto.Response,
) !?StepResult {
    if (self.config.execution_mode == .tools) return null;
    if (agent_parsing.findJsCodeInResponse(self.alloc, response)) |js_code| {
        defer self.alloc.free(js_code);
        return try executeCodeActBlock(self, act_id, input_msgs_count, tool_defs, response, js_code);
    }
    return null;
}

/// Executes a single agent step:
/// 1. Status and history preparation (watchdog recap, guidance, plan progress)
/// 2. Dynamic reasoning effort modulation
/// 3. AI backend streaming communication
/// 4. Plan detection & token tracking
/// 5. Tool execution or CodeAct evaluation or stop reason dispatching
pub fn executeStep(
    self: *AgentLoop,
    act_id: usize,
    tool_defs: []const proto.ToolDefinition,
    text_cb: ?*const fn ([]const u8) void,
    think_cb: ?*const fn ([]const u8) void,
) !StepResult {
    try renderStepHeader(self, act_id);

    var input_msgs_count: usize = 0;
    var temp_input_msgs = std.ArrayListUnmanaged(proto.Message).empty;
    defer temp_input_msgs.deinit(self.alloc);

    var guidance_ctx = try prepareStepInputMessages(self, act_id, &temp_input_msgs, &input_msgs_count);
    defer guidance_ctx.deinit(self.alloc);

    var response = try self.sendToBackend(
        act_id,
        self.config.system_prompt,
        temp_input_msgs.items,
        tool_defs,
        text_cb,
        think_cb,
    );
    main.resetThinkState();
    if (signals.isInterrupted()) {
        response.deinit();
        return error.Interrupted;
    }
    defer response.deinit();

    if (main.ui_repl.current_renderer == null) {
        try std.Io.File.stdout().writeStreamingAll(self.io, "\n");
    }

    const validity = proto.classifyResponse(&response, false);
    self.last_generation_stop = response.stop_reason;
    self.last_response_validity = validity;
    self.last_agent_decision = proto.decideAgentAction(response.stop_reason, validity, false);
    const was_added = try self.history.addAssistantResponse(&response);
    const has_tool_use_blocks = scanResponseContent(self, &response, was_added);

    if (has_tool_use_blocks) {
        self.response_recovery_budget = .{};
        return executeNativeToolCalling(self, act_id, input_msgs_count, tool_defs, &response);
    }

    if (try tryExecuteCodeAct(self, act_id, input_msgs_count, tool_defs, &response)) |res| {
        self.response_recovery_budget = .{};
        return res;
    }

    if (validity == .final_text or validity == .partial_text or validity == .thinking_only or
        validity == .whitespace_only or validity == .empty)
    {
        if (self.last_agent_decision == .retry_transient or validity == .partial_text) {
            return handleResponseRecovery(self, act_id, input_msgs_count, tool_defs, &response, validity);
        }
    }
    return dispatchStopReason(self, act_id, input_msgs_count, tool_defs, &response, has_tool_use_blocks);
}
