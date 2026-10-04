//! Turn execution logic for AgentLoop.
//!
//! Decomposes turn execution (executeTurnWorker) into distinct lifecycle phases:
//! - prepareTurnState: initial metrics reset, user message injection, plan restore, tool definition filtering
//! - handleActError: classified error handling (interrupted/timeout, auth, rate limit/503 backoff, context window compaction)
//! - flushActProgress: delta file snapshot flushing and RFC-019 plan progress tracking
//! - executeTurnWorker: resilient act loop coordinating steps and recovery

const std = @import("std");
const proto = @import("../protocol.zig");
const utils = @import("../utils.zig");
const signals = @import("../signals.zig");
const main = @import("../../main.zig");
const tools_mod = @import("../../tooling/registry.zig");
const snapshot_mod = @import("../snapshot.zig");
const journal_mod = @import("../journal.zig");
const prompts_mod = @import("../prompts.zig");
const media_gen_tool = @import("../../tools/media_gen.zig");
const hooks_mod = @import("../hooks.zig");
const loop_mod = @import("loop.zig");
const AgentLoop = loop_mod.AgentLoop;

pub fn nextActAttempt(current: usize) usize {
    // PSEUDOCODE:
    // 1. Start each Act at attempt one.
    // 2. Increment for every provider/recovery attempt while preserving Act identity.
    return if (current == 0) 1 else current + 1;
}

/// Maximum retries on rate limit.
pub const MAX_RATE_LIMIT_RETRIES = 12;
/// Initial delay on rate limit (seconds).
pub const RATE_LIMIT_BASE_DELAY_S: u64 = 5;
/// Maximum backoff on rate limit (seconds).
pub const RATE_LIMIT_MAX_BACKOFF_S: u64 = 120;

/// Context passed to the worker thread.
pub const TurnWorkerContext = struct {
    agent: *AgentLoop,
    user_text: []const u8,
    images: []const proto.ImageBlock,
    text_cb: ?*const fn ([]const u8) void,
    think_cb: ?*const fn ([]const u8) void,
    result: anyerror!proto.TurnResult = error.Unexpected,
};

/// Entry point function for std.Thread.spawn running the turn worker.
pub fn turnWorkerThreadEntry(ctx: *TurnWorkerContext) void {
    ctx.result = ctx.agent.executeTurnWorker(
        ctx.user_text,
        ctx.images,
        ctx.text_cb,
        ctx.think_cb,
    );
}

/// Action to take after an act error occurs.
pub const ActErrorResolution = enum {
    retry_act,
    next_act,
    fail_turn,
    fail_rate_limited,
    fail_provider_unavailable,
    stop_turn,
};

fn resetTurnMetrics(self: *AgentLoop, user_text: []const u8) void {
    self.last_turn_acts = 0;
    self.last_turn_completion_tokens = 0;
    self.last_generation_stop = .missing_terminal_event;
    self.last_response_validity = .empty;
    self.last_agent_decision = .request_continuation;
    self.last_step_outcome = .final_answer;
    self.response_recovery_budget = .{};
    self.turn_recovery_attempts = 0;
    if (self.last_agent_message) |old| {
        self.alloc.free(old);
        self.last_agent_message = null;
    }
    self.last_turn_outcome = .completed;
    self.current_act_attempt = 0;
    self.last_recovery_class = null;
    self.last_failure_reason = null;
    self.role_fix_attempts = 0;
    self.max_tokens_continues = 0;
    self.stop_sequence_continues = 0;
    self.last_act_failed = false;
    self.js_retry_count = 0;
    self.clearTurnToolRecords();
    self.consecutive_dup_tool_count = 0;
    self.consecutive_readonly_count = 0;
    self.action_loop_tripped = false;
    self.plan.resetTurn();
    self.current_user_request = user_text;
    self.plan.tryRestoreFromStore(user_text);
}

test "RFC-023: same-Act attempt identity increments monotonically" {
    try std.testing.expectEqual(@as(usize, 1), nextActAttempt(0));
    try std.testing.expectEqual(@as(usize, 2), nextActAttempt(1));
    try std.testing.expectEqual(@as(usize, 3), nextActAttempt(2));
}

fn resolveTurnToolDefinitions(
    self: *AgentLoop,
    turn_alloc: std.mem.Allocator,
    user_text: []const u8,
) []const proto.ToolDefinition {
    const raw_tool_defs = switch (self.config.execution_mode) {
        .codeact => &[_]proto.ToolDefinition{},
        .tools => blk: {
            const all_defs = tools_mod.getRelevantDefinitions(turn_alloc, user_text);
            var list = std.ArrayListUnmanaged(proto.ToolDefinition).empty;
            for (all_defs) |td| {
                if (!std.mem.eql(u8, td.name, "codeact")) {
                    list.append(turn_alloc, td) catch {};
                }
            }
            break :blk list.items;
        },
        .auto => tools_mod.getRelevantDefinitions(turn_alloc, user_text),
    };

    if (self.plan.getToolHint()) |hint| {
        return tools_mod.filterDefinitionsForPlan(turn_alloc, raw_tool_defs, hint);
    }
    return raw_tool_defs;
}

fn ensureJournalAndSnapshotTracker(self: *AgentLoop) void {
    if (self.journal == null) {
        var path_buf: [256]u8 = undefined;
        const home_dir = utils.getEnvSlice("HOME") orelse ".";
        const journal_path = std.fmt.bufPrint(&path_buf, "{s}/.mini/sessions/journal_{d}.jsonl", .{ home_dir, std.c.getpid() }) catch "/tmp/mini_journal.jsonl";
        self.journal = journal_mod.ActJournal.init(self.alloc, self.io, journal_path) catch null;
    }

    if (self.snapshot_tracker == null) {
        self.snapshot_tracker = snapshot_mod.SnapshotTracker.init(self.alloc, self.io, &self.cas, if (self.journal != null) &self.journal.? else null);
        snapshot_mod.setTracker(if (self.snapshot_tracker != null) &self.snapshot_tracker.? else null);
    }
}

/// Initializes turn metrics, appends the user query, restores plans, and retrieves filtered tool definitions.
pub fn prepareTurnState(
    self: *AgentLoop,
    turn_alloc: std.mem.Allocator,
    user_text: []const u8,
    images: []const proto.ImageBlock,
) ![]const proto.ToolDefinition {
    if (images.len > 0) {
        try self.history.addUserWithImages(user_text, images);
    } else {
        try self.history.addUser(user_text);
    }

    resetTurnMetrics(self, user_text);
    const tool_defs = resolveTurnToolDefinitions(self, turn_alloc, user_text);
    ensureJournalAndSnapshotTracker(self);
    return tool_defs;
}

/// Flushes all mini.write/patch/sh snapshots and writes completion record to journal.
fn flushSnapshotsAndJournal(self: *AgentLoop, act_id: usize) void {
    // PSEUDOCODE:
    // 1. Flush snapshot tracker if there are tracked files
    // 2. Record act completion in journal if no file delta was recorded
    var recorded_delta = false;
    if (self.snapshot_tracker) |*t| {
        if (t.tracked.items.len > 0) {
            t.flush(act_id, .{
                .stop_reason = self.last_stop_reason,
                .generation_stop = @tagName(self.last_generation_stop),
                .response_validity = @tagName(self.last_response_validity),
                .agent_decision = @tagName(self.last_agent_decision),
                .recovery_class = if (self.last_recovery_class) |class| @tagName(class) else null,
                .attempt = self.current_act_attempt,
            });
            recorded_delta = true;
        }
        t.reset();
    }
    if (!recorded_delta) {
        if (self.journal) |*j| {
            j.recordActComplete(self.io, act_id, .{
                .act_id = act_id,
                .file_snapshots = &.{},
                .stop_reason = self.last_stop_reason,
                .generation_stop = @tagName(self.last_generation_stop),
                .response_validity = @tagName(self.last_response_validity),
                .agent_decision = @tagName(self.last_agent_decision),
                .recovery_class = if (self.last_recovery_class) |class| @tagName(class) else null,
                .attempt = self.current_act_attempt,
            }) catch {};
        }
    }
}

/// Builds progress summary string from modified files and recent unique tool invocations.
fn buildActProgressSummary(self: *AgentLoop, alloc: std.mem.Allocator) ![]u8 {
    // PSEUDOCODE:
    // 1. Append modified files
    // 2. Deduplicate and append up to 5 most recent tool names
    // 3. Return owned slice
    var pb = std.ArrayListUnmanaged(u8).empty;
    errdefer pb.deinit(alloc);

    if (self.snapshot_tracker) |*t| {
        for (t.tracked.items) |tf| {
            if (tf.previous_content_hash) |_| {
                const line = try std.fmt.allocPrint(alloc, "Modified: {s}\n", .{tf.path});
                defer alloc.free(line);
                pb.appendSlice(alloc, line) catch {};
            }
        }
        t.reset();
    }

    if (self.turn_tool_records.items.len > 0) {
        var seen_tools: [5][]const u8 = undefined;
        var seen_count: usize = 0;
        const limit = @min(self.turn_tool_records.items.len, 5);
        for (self.turn_tool_records.items[self.turn_tool_records.items.len - limit ..]) |rec| {
            var is_dup = false;
            for (seen_tools[0..seen_count]) |st| {
                if (std.mem.eql(u8, st, rec.name)) {
                    is_dup = true;
                    break;
                }
            }
            if (is_dup) continue;
            if (seen_count < seen_tools.len) {
                seen_tools[seen_count] = rec.name;
                seen_count += 1;
            }
            const line = try std.fmt.allocPrint(alloc, "Tool: {s}\n", .{rec.name});
            defer alloc.free(line);
            pb.appendSlice(alloc, line) catch {};
        }
    }

    return pb.toOwnedSlice(alloc);
}

/// Flushes tracked file snapshots, records act completion in journal, and summarizes progress into plan state.
pub fn flushActProgress(self: *AgentLoop, act_id: usize) !void {
    // PSEUDOCODE:
    // 1. Flush snapshots and journal
    // 2. Build progress summary and forward to plan state
    flushSnapshotsAndJournal(self, act_id);
    const summary = try buildActProgressSummary(self, self.alloc);
    defer self.alloc.free(summary);
    self.plan.updateProgress(summary);
}

fn handleInterruptedActError(self: *AgentLoop, act_id: usize) !ActErrorResolution {
    if (self.coordinator.isTimedOut()) {
        const timeout_ctx = self.coordinator.popPendingTimeoutContext();
        defer if (timeout_ctx) |ctx| self.alloc.free(ctx);
        const reason = if (timeout_ctx) |ctx| ctx else "Action timed out and was killed by Watchdog";

        if (main.ui_repl.current_renderer) |r| {
            r.stopWaiting();
            if (r.is_thinking) r.endThinking();
            r.clearInplaceLine();
            r.ensureNewline();
            r.write(" \x1b[31m[Watchdog Timeout: Action terminated by LLM decision]\x1b[0m\n");
        } else {
            main.stderrPrint("\n\x1b[31m[Watchdog Timeout: Action terminated by LLM decision: {s}]\x1b[0m\n", .{reason});
        }
        signals.setInterrupted(false);
        self.coordinator.setTimedOut(false);
        self.last_act_failed = true;

        const err_msg = try std.fmt.allocPrint(self.alloc, prompts_mod.watchdog_timeout_fmt, .{reason});
        defer self.alloc.free(err_msg);
        try self.history.addUser(err_msg);
        self.coordinator.finishAct(act_id, false);
        return .next_act;
    }

    if (main.ui_repl.current_renderer) |r| {
        r.stopWaiting();
        if (r.is_thinking) r.endThinking();
        r.clearInplaceLine();
        r.ensureNewline();
        r.write(" \x1b[33m[Stopped by user (Ctrl+C)]\x1b[0m\n");
    } else {
        main.stderrPrint("\n\x1b[33m[Stopped by user (Ctrl+C)]\x1b[0m\n", .{});
    }
    return .stop_turn;
}

fn handleAuthActError(self: *AgentLoop, act_id: usize, e: anyerror) ActErrorResolution {
    if (main.ui_repl.current_renderer) |r| {
        r.showBackendError(self.last_backend_http_code, self.last_backend_raw_error);
    } else {
        AgentLoop.printRawBackendResponse(self.last_backend_raw_error, self.last_backend_http_code);
    }
    main.stderrPrint("\n\x1b[31m[agent] ⛔ Backend authentication/permission error (HTTP {d})! Please check API key or account.\x1b[0m\n", .{self.last_backend_http_code});
    if (self.journal) |*j| j.recordError(self.io, act_id, .act_failed, "Backend authentication/permission error — abort", .{
        .backend = self.backend.name(),
        .model = self.backend.model(),
        .error_name = @errorName(e),
        .http_code = self.last_backend_http_code,
        .attempt = self.current_act_attempt,
        .raw_snippet = self.last_backend_raw_error,
    }) catch {};
    self.last_generation_stop = .provider_error;
    self.last_step_outcome = .provider_failure;
    self.last_turn_outcome = .failed;
    return .fail_turn;
}

fn recordThrottledJournal(self: *AgentLoop, act_id: usize, e: anyerror) void {
    if (self.journal) |*j| {
        const is_rate_limit = (e == error.LLMRateLimitExceeded);
        const ev_type: journal_mod.ActEventType = if (is_rate_limit) .llm_call_throttled else .llm_provider_error;
        const desc = if (is_rate_limit) "Rate limit (429) from backend" else "Backend error (5xx / provider unavailable)";
        j.recordError(self.io, act_id, ev_type, desc, .{
            .backend = self.backend.name(),
            .model = self.backend.model(),
            .error_name = @errorName(e),
            .http_code = self.last_backend_http_code,
            .attempt = self.current_act_attempt,
            .raw_snippet = self.last_backend_raw_error,
        }) catch {};
    }
}

fn exhaustedActErrorResolution(e: anyerror) ActErrorResolution {
    // PSEUDOCODE:
    // 1. Preserve the exhausted backend category for ACP mapping.
    // 2. Do not collapse rate limiting into generic provider failure.
    return if (e == error.LLMRateLimitExceeded) .fail_rate_limited else .fail_provider_unavailable;
}

fn handleThrottledActError(
    self: *AgentLoop,
    act_id: usize,
    e: anyerror,
    try_count: *usize,
    rate_limit_retries: *usize,
    history_len: usize,
) !ActErrorResolution {
    if (main.ui_repl.current_renderer) |r| {
        r.showBackendThrottled(self.last_backend_http_code, self.last_backend_raw_error);
    } else {
        AgentLoop.printRawBackendResponse(self.last_backend_raw_error, self.last_backend_http_code);
    }
    recordThrottledJournal(self, act_id, e);

    rate_limit_retries.* += 1;
    if (rate_limit_retries.* > MAX_RATE_LIMIT_RETRIES) {
        if (main.ui_repl.current_renderer) |r| r.clearInplaceLine();
        main.stderrPrint("\n\x1b[31m[agent] ⛔ Retried {d} times but backend still reported rate limit / 503 error. Terminating task.\x1b[0m\n", .{MAX_RATE_LIMIT_RETRIES});
        self.last_generation_stop = .provider_error;
        self.last_step_outcome = .provider_failure;
        self.last_turn_outcome = .failed;
        return exhaustedActErrorResolution(e);
    }

    const raw_backoff: u64 = (@as(u64, 1) << @as(u6, @intCast(rate_limit_retries.*))) * 2;
    const backoff_s: u64 = @min(raw_backoff, RATE_LIMIT_MAX_BACKOFF_S);

    if (main.ui_repl.current_renderer) |r| {
        try r.waitRetryCountdown(self.io, backoff_s, rate_limit_retries.*, MAX_RATE_LIMIT_RETRIES);
    } else {
        main.stderrPrint("[agent] ⚠ Rate limit / 503 (attempt {d}/{d})! Retrying in {d}s...\n", .{ rate_limit_retries.*, MAX_RATE_LIMIT_RETRIES, backoff_s });
        std.Io.sleep(self.io, std.Io.Duration.fromSeconds(@intCast(backoff_s)), .awake) catch {};
    }

    if (self.history.last_compaction_act_id < act_id) {
        self.history.truncate(history_len);
    }
    if (try_count.* > 0) try_count.* -= 1;
    return .retry_act;
}

fn handleContextExceededActError(
    self: *AgentLoop,
    act_id: usize,
    e: anyerror,
    try_count: *usize,
    max_retries: usize,
    history_len: usize,
) !ActErrorResolution {
    if (main.ui_repl.current_renderer) |r| {
        r.showBackendError(self.last_backend_http_code, self.last_backend_raw_error);
    } else {
        AgentLoop.printRawBackendResponse(self.last_backend_raw_error, self.last_backend_http_code);
    }
    if (try_count.* >= max_retries) {
        main.stderrPrint("\n\x1b[31m[agent] ⛔ Cannot compact context further after {d} attempts. Terminating process: {s}\x1b[0m\n", .{ max_retries + 1, @errorName(e) });
        if (self.journal) |*j| j.recordError(self.io, act_id, .act_failed, "Context overflow cannot be compacted further — abort", .{
            .backend = self.backend.name(),
            .model = self.backend.model(),
            .error_name = @errorName(e),
            .http_code = self.last_backend_http_code,
            .attempt = try_count.* + 1,
            .raw_snippet = self.last_backend_raw_error,
        }) catch {};
        self.last_generation_stop = .provider_error;
        self.last_step_outcome = .provider_failure;
        self.last_turn_outcome = .failed;
        return .fail_turn;
    }

    main.stderrPrint("\n\x1b[33m[agent] ⚠️ Model reported exceeding context limit (HTTP 400)! Performing emergency MemAct compaction (attempt {d}/{d})...\x1b[0m\n", .{ try_count.* + 1, max_retries + 1 });
    if (self.journal) |*j| j.recordError(self.io, act_id, .llm_context_overflow, "Model reported context overflow — emergency MemAct compaction", .{
        .backend = self.backend.name(),
        .model = self.backend.model(),
        .error_name = @errorName(e),
        .http_code = self.last_backend_http_code,
        .attempt = try_count.* + 1,
        .raw_snippet = self.last_backend_raw_error,
    }) catch {};

    self.compactContext(act_id) catch {
        self.history.compact();
    };

    if (self.history.last_compaction_act_id < act_id) {
        self.history.truncate(history_len);
    }
    return .retry_act;
}

fn renderActErrorUI(self: *AgentLoop) void {
    if (self.last_backend_raw_error != null and self.last_backend_http_code >= 400) {
        if (main.ui_repl.current_renderer) |r| {
            r.showBackendError(self.last_backend_http_code, self.last_backend_raw_error);
        } else {
            AgentLoop.printRawBackendResponse(self.last_backend_raw_error, self.last_backend_http_code);
        }
    } else if (main.ui_repl.current_renderer) |r| {
        r.stopWaiting();
        if (r.is_thinking) r.endThinking();
        r.ensureNewline();
    }
}

fn handleTerminalActError(self: *AgentLoop, act_id: usize, e: anyerror, max_retries: usize, history_len: usize) ActErrorResolution {
    main.stderrPrint("\n[agent] Act {d} failed {d} consecutive times. Terminating process: {s}\n", .{ act_id, max_retries + 1, @errorName(e) });
    if (self.journal) |*j| j.recordError(self.io, act_id, .act_failed, "Act terminal error — abort", .{
        .backend = self.backend.name(),
        .model = self.backend.model(),
        .error_name = @errorName(e),
        .http_code = self.last_backend_http_code,
        .attempt = max_retries + 1,
        .raw_snippet = self.last_backend_raw_error,
    }) catch {};
    if (self.history.last_compaction_act_id < act_id) {
        self.history.truncate(history_len);
        if (self.journal) |*j| j.recordEvent(self.io, act_id, .rollback_completed, "Rollback state due to terminal error") catch {};
    }
    self.last_generation_stop = .provider_error;
    self.last_step_outcome = .provider_failure;
    self.last_turn_outcome = .failed;
    return .fail_turn;
}

fn handleGenericActError(
    self: *AgentLoop,
    act_id: usize,
    e: anyerror,
    try_count: *usize,
    max_retries: usize,
    history_len: usize,
) !ActErrorResolution {
    renderActErrorUI(self);

    if (try_count.* == max_retries) {
        return handleTerminalActError(self, act_id, e, max_retries, history_len);
    }

    main.stderrPrint("\n[agent] Act {d} encountered an issue ({s}). Rolling back (attempt {d}/{d})...\n", .{ act_id, @errorName(e), try_count.* + 1, max_retries });

    if (self.journal) |*j| j.recordError(self.io, act_id, .act_failed, "Act error — rollback & retry", .{
        .backend = self.backend.name(),
        .model = self.backend.model(),
        .error_name = @errorName(e),
        .http_code = self.last_backend_http_code,
        .attempt = try_count.* + 1,
        .raw_snippet = self.last_backend_raw_error,
    }) catch {};

    if (self.history.last_compaction_act_id < act_id) {
        self.history.truncate(history_len);
        try self.history.addSystemErrorObservation(@errorName(e));
        if (self.journal) |*j| j.recordEvent(self.io, act_id, .rollback_completed, "Rollback state due to error") catch {};
    } else {
        main.stderrPrint("[agent] Cannot rollback because memory compaction checkpoint has passed.\n", .{});
        self.last_generation_stop = .provider_error;
        self.last_step_outcome = .provider_failure;
        self.last_turn_outcome = .failed;
        return .fail_turn;
    }
    return .retry_act;
}

/// Dispatches classified error handling during act loop execution.
pub fn handleActError(
    self: *AgentLoop,
    act_id: usize,
    e: anyerror,
    try_count: *usize,
    max_retries: usize,
    rate_limit_retries: *usize,
    history_len: usize,
) !ActErrorResolution {
    switch (e) {
        error.Interrupted => return handleInterruptedActError(self, act_id),
        error.LLMAuthenticationError => return handleAuthActError(self, act_id, e),
        error.LLMRateLimitExceeded, error.LLMProviderUnavailable => return handleThrottledActError(self, act_id, e, try_count, rate_limit_retries, history_len),
        error.LLMContextWindowExceeded => return handleContextExceededActError(self, act_id, e, try_count, max_retries, history_len),
        else => return handleGenericActError(self, act_id, e, try_count, max_retries, history_len),
    }
}

pub fn actErrorTransition(resolution: ActErrorResolution) proto.ActTransition {
    // PSEUDOCODE:
    // 1. Preserve retry/next/cancel control flow.
    // 2. Represent terminal workflow errors as typed failed turns.
    return switch (resolution) {
        .retry_act => .{ .retry_same_act = {} },
        .next_act => .{ .next_act = {} },
        .fail_turn => .{ .fail = .provider_error },
        .fail_rate_limited => .{ .fail = .rate_limit_exhausted },
        .fail_provider_unavailable => .{ .fail = .provider_unavailable },
        .stop_turn => .{ .cancel = {} },
    };
}

test "RFC-023: terminal Act errors become failed turns" {
    try std.testing.expect(actErrorTransition(.fail_turn) == .fail);
    try std.testing.expectEqual(proto.FailureReason.provider_error, actErrorTransition(.fail_turn).fail);
    try std.testing.expect(actErrorTransition(.stop_turn) == .cancel);
}

test "RFC-023: exhausted backend error keeps rate-limit versus provider cause" {
    try std.testing.expectEqual(
        ActErrorResolution.fail_rate_limited,
        exhaustedActErrorResolution(error.LLMRateLimitExceeded),
    );
    try std.testing.expectEqual(
        ActErrorResolution.fail_provider_unavailable,
        exhaustedActErrorResolution(error.LLMProviderUnavailable),
    );
}

test "RFC-023: terminal Act errors preserve ACP exhaustion reason" {
    try std.testing.expectEqual(
        proto.FailureReason.rate_limit_exhausted,
        actErrorTransition(.fail_rate_limited).fail,
    );
    try std.testing.expectEqual(
        proto.FailureReason.provider_unavailable,
        actErrorTransition(.fail_provider_unavailable).fail,
    );
}

fn executeSingleActAttempt(
    self: *AgentLoop,
    act_id: usize,
    tool_defs: []const proto.ToolDefinition,
    text_cb: ?*const fn ([]const u8) void,
    think_cb: ?*const fn ([]const u8) void,
    try_count: *usize,
    max_retries: usize,
    rate_limit_retries: *usize,
) !proto.ActTransition {
    self.current_act_attempt = nextActAttempt(self.current_act_attempt);
    if (self.journal) |*j| j.recordEvent(self.io, act_id, .act_started, "Act started") catch {};

    const transition = self.executeStep(act_id, tool_defs, text_cb, think_cb) catch |e| {
        const resolution = try handleActError(
            self,
            act_id,
            e,
            try_count,
            max_retries,
            rate_limit_retries,
            self.act_history_checkpoint,
        );
        return actErrorTransition(resolution);
    };

    rate_limit_retries.* = 0;
    if (main.ui_repl.current_renderer) |r| {
        r.resetErrorSignature();
    }

    if (transition == .retry_same_act) {
        // PSEUDOCODE:
        // 1. Recovery is still a completed provider attempt.
        // 2. Persist its state before retrying the same Act.
        try flushActProgress(self, act_id);
        return transition;
    }

    try flushActProgress(self, act_id);
    return transition;
}

fn runActRetryLoop(
    self: *AgentLoop,
    act_id: usize,
    tool_defs: []const proto.ToolDefinition,
    text_cb: ?*const fn ([]const u8) void,
    think_cb: ?*const fn ([]const u8) void,
    rate_limit_retries: *usize,
    max_retries: usize,
) !proto.ActTransition {
    // PSEUDOCODE:
    // 1. Drain pending recap advisory at the start of the Act before establishing checkpoint.
    // 2. Record act_history_checkpoint as the pristine baseline before any retry attempts.
    self.current_act_attempt = 0;
    if (self.coordinator.popPendingRecapAdvisory()) |advisory| {
        defer self.alloc.free(advisory);
        try self.history.addUser(advisory);
    }
    self.act_history_checkpoint = self.history.len();

    var try_count: usize = 0;
    while (try_count <= max_retries) : (try_count += 1) {
        const transition = try executeSingleActAttempt(
            self,
            act_id,
            tool_defs,
            text_cb,
            think_cb,
            &try_count,
            max_retries,
            rate_limit_retries,
        );
        switch (transition) {
            .retry_same_act => continue,
            .next_act, .complete => return transition,
            .stall, .fail, .cancel => {
                self.history.truncate(self.act_history_checkpoint);
                return transition;
            },
        }
    } else {
        main.stderrPrint("\n\x1b[31m[agent] ⛔ Act {d} failed after {d} unrecoverable attempts. Terminating task.\x1b[0m\n", .{ act_id, max_retries + 1 });
        self.history.truncate(self.act_history_checkpoint);
        self.coordinator.finishAct(act_id, false);
        return proto.ActTransition{ .fail = .provider_error };
    }
}

fn terminalTaskEvent(outcome: proto.TurnOutcome) journal_mod.ActEventType {
    // PSEUDOCODE:
    // 1. Map every terminal business outcome to exactly one journal event.
    // 2. Reserve task_completed for meaningful final-answer completion.
    return switch (outcome) {
        .completed => .task_completed,
        .stalled, .blocked => .task_stalled,
        .failed => .task_failed,
        .cancelled => .task_interrupted,
    };
}

test "RFC-023: terminal outcomes map to one truthful task event" {
    try std.testing.expectEqual(journal_mod.ActEventType.task_completed, terminalTaskEvent(.completed));
    try std.testing.expectEqual(journal_mod.ActEventType.task_stalled, terminalTaskEvent(.stalled));
    try std.testing.expectEqual(journal_mod.ActEventType.task_stalled, terminalTaskEvent(.blocked));
    try std.testing.expectEqual(journal_mod.ActEventType.task_failed, terminalTaskEvent(.failed));
    try std.testing.expectEqual(journal_mod.ActEventType.task_interrupted, terminalTaskEvent(.cancelled));
}

/// Concrete act execution running on Thread 3 (Act Executor).
pub fn executeTurnWorker(
    self: *AgentLoop,
    user_text: []const u8,
    images: []const proto.ImageBlock,
    text_cb: ?*const fn ([]const u8) void,
    think_cb: ?*const fn ([]const u8) void,
) !proto.TurnResult {
    loop_mod.activateTurnHooks(self);
    defer loop_mod.deactivateTurnHooks();

    media_gen_tool.clearTurnAttachments(self.alloc);

    var turn_arena = std.heap.ArenaAllocator.init(self.alloc);
    defer turn_arena.deinit();
    const turn_alloc = turn_arena.allocator();

    hooks_mod.dispatch(turn_alloc, self.io, .{ .event = "pre-prompt", .user_prompt = user_text });
    defer hooks_mod.dispatch(turn_alloc, self.io, .{ .event = "post-response", .user_prompt = user_text });

    const tool_defs = try prepareTurnState(self, turn_alloc, user_text, images);

    var act_id: usize = 1;
    var rate_limit_retries: usize = 0;
    const max_retries = 3;

    var final_transition: proto.ActTransition = undefined;

    while (true) : (act_id += 1) {
        self.last_turn_acts = act_id;
        main.beginAct(act_id);
        const transition = try runActRetryLoop(self, act_id, tool_defs, text_cb, think_cb, &rate_limit_retries, max_retries);
        switch (transition) {
            .next_act => continue,
            .retry_same_act => continue,
            .complete, .stall, .fail, .cancel => {
                final_transition = transition;
                break;
            },
        }
    }

    const outcome: proto.TurnOutcome = switch (final_transition) {
        .complete => .completed,
        .stall => .stalled,
        .fail => .failed,
        .cancel => .cancelled,
        else => .failed,
    };
    self.last_turn_outcome = outcome;
    // PSEUDOCODE:
    // 1. Preserve the business outcome independently from its failure cause.
    // 2. Publish the typed cause only for terminal failed transitions.
    self.last_failure_reason = switch (final_transition) {
        .fail => |reason| reason,
        else => null,
    };

    // Outer lifecycle is the single authority writing terminal task events:
    if (self.journal) |*j| {
        const event = terminalTaskEvent(outcome);
        const description: []const u8 = switch (outcome) {
            .completed => "Task completed",
            .stalled => "Task stalled",
            .failed => "Task failed",
            .blocked => "Task blocked",
            .cancelled => "Task interrupted",
        };
        j.recordEvent(self.io, act_id, event, description) catch {};
    }

    self.coordinator.finishAct(act_id, outcome == .completed);
    self.coordinator.notifyTurnComplete();

    // RFC-025 Phase 3: background LLM extraction of durable memories
    // (sync end-of-turn dispatch; no-op when memact_extract == "off").
    // Extraction must never alter the turn outcome.
    self.maybeExtractMemories() catch {};

    const duped_last_message = if (self.last_agent_message) |msg|
        self.alloc.dupe(u8, msg) catch null
    else
        null;

    return proto.TurnResult{
        .outcome = outcome,
        .generation_stop = self.last_generation_stop,
        .response_validity = self.last_response_validity,
        .step_outcome = self.last_step_outcome,
        .failure_reason = self.last_failure_reason,
        .last_agent_message = duped_last_message,
        .act_count = self.last_turn_acts,
        .recovery_attempts = self.turn_recovery_attempts,
    };
}
