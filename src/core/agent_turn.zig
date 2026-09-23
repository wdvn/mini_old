//! Turn execution logic for AgentLoop.
//!
//! Decomposes turn execution (executeTurnWorker) into distinct lifecycle phases:
//! - prepareTurnState: initial metrics reset, user message injection, plan restore, tool definition filtering
//! - handleActError: classified error handling (interrupted/timeout, auth, rate limit/503 backoff, context window compaction)
//! - flushActProgress: delta file snapshot flushing and RFC-019 plan progress tracking
//! - executeTurnWorker: resilient act loop coordinating steps and recovery

const std = @import("std");
const proto = @import("protocol.zig");
const utils = @import("utils.zig");
const signals = @import("signals.zig");
const main = @import("../main.zig");
const tools_mod = @import("../tooling/registry.zig");
const snapshot_mod = @import("snapshot.zig");
const journal_mod = @import("journal.zig");
const prompts_mod = @import("prompts.zig");
const media_gen_tool = @import("../tools/media_gen.zig");
const hooks_mod = @import("hooks.zig");
const agent_mod = @import("agent.zig");
const AgentLoop = agent_mod.AgentLoop;

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
    result: anyerror!void = {},
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
    stop_turn,
};

fn resetTurnMetrics(self: *AgentLoop, user_text: []const u8) void {
    self.last_turn_acts = 0;
    self.last_turn_completion_tokens = 0;
    self.role_fix_attempts = 0;
    self.max_tokens_continues = 0;
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
            t.flush(act_id);
            recorded_delta = true;
        }
        t.reset();
    }
    if (!recorded_delta) {
        if (self.journal) |*j| {
            j.recordActComplete(self.io, act_id, .{
                .act_id = act_id,
                .file_snapshots = &.{},
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
    if (self.journal) |*j| {
        j.recordEvent(self.io, act_id, .task_interrupted, "Task cancelled by user (Ctrl+C)") catch {};
    }
    return .stop_turn;
}

fn handleAuthActError(self: *AgentLoop, act_id: usize, e: anyerror) anyerror {
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
        .attempt = 1,
        .raw_snippet = self.last_backend_raw_error,
    }) catch {};
    return e;
}

fn recordThrottledJournal(self: *AgentLoop, act_id: usize, e: anyerror, retries: usize) void {
    if (self.journal) |*j| {
        const is_rate_limit = (e == error.LLMRateLimitExceeded);
        const ev_type: journal_mod.ActEventType = if (is_rate_limit) .llm_call_throttled else .llm_provider_error;
        const desc = if (is_rate_limit) "Rate limit (429) from backend" else "Backend error (5xx / provider unavailable)";
        j.recordError(self.io, act_id, ev_type, desc, .{
            .backend = self.backend.name(),
            .model = self.backend.model(),
            .error_name = @errorName(e),
            .http_code = self.last_backend_http_code,
            .attempt = retries + 1,
            .raw_snippet = self.last_backend_raw_error,
        }) catch {};
    }
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
    recordThrottledJournal(self, act_id, e, rate_limit_retries.*);

    rate_limit_retries.* += 1;
    if (rate_limit_retries.* > MAX_RATE_LIMIT_RETRIES) {
        if (main.ui_repl.current_renderer) |r| r.clearInplaceLine();
        main.stderrPrint("\n\x1b[31m[agent] ⛔ Retried {d} times but backend still reported rate limit / 503 error. Terminating task.\x1b[0m\n", .{MAX_RATE_LIMIT_RETRIES});
        return e;
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
        return e;
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

fn handleTerminalActError(self: *AgentLoop, act_id: usize, e: anyerror, max_retries: usize, history_len: usize) anyerror {
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
    return e;
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
        return e;
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

const ActAttemptResult = enum {
    retry_act,
    next_act,
    exit_loop,
    stop_turn,
};

fn executeSingleActAttempt(
    self: *AgentLoop,
    act_id: usize,
    tool_defs: []const proto.ToolDefinition,
    text_cb: ?*const fn ([]const u8) void,
    think_cb: ?*const fn ([]const u8) void,
    try_count: *usize,
    max_retries: usize,
    rate_limit_retries: *usize,
) !ActAttemptResult {
    if (self.journal) |*j| j.recordEvent(self.io, act_id, .act_started, "Act started") catch {};

    const history_len = self.history.messages().len;

    const result = self.executeStep(act_id, tool_defs, text_cb, think_cb) catch |e| {
        const resolution = try handleActError(
            self,
            act_id,
            e,
            try_count,
            max_retries,
            rate_limit_retries,
            history_len,
        );
        switch (resolution) {
            .retry_act => return .retry_act,
            .next_act => return .next_act,
            .stop_turn => return .stop_turn,
        }
    };

    rate_limit_retries.* = 0;
    if (main.ui_repl.current_renderer) |r| {
        r.resetErrorSignature();
    }

    try flushActProgress(self, act_id);

    if (result == .exit_loop) {
        if (self.journal) |*j| j.recordEvent(self.io, act_id, .task_completed, "Task completed") catch {};
        self.coordinator.finishAct(act_id, !self.last_act_failed);
        self.coordinator.notifyTurnComplete();
        return .exit_loop;
    }
    self.coordinator.finishAct(act_id, !self.last_act_failed);
    return .next_act;
}

fn runActRetryLoop(
    self: *AgentLoop,
    act_id: usize,
    tool_defs: []const proto.ToolDefinition,
    text_cb: ?*const fn ([]const u8) void,
    think_cb: ?*const fn ([]const u8) void,
    rate_limit_retries: *usize,
    max_retries: usize,
) !bool {
    var try_count: usize = 0;
    while (try_count <= max_retries) : (try_count += 1) {
        const attempt = try executeSingleActAttempt(
            self,
            act_id,
            tool_defs,
            text_cb,
            think_cb,
            &try_count,
            max_retries,
            rate_limit_retries,
        );
        switch (attempt) {
            .retry_act => continue,
            .next_act => return false,
            .exit_loop, .stop_turn => return true,
        }
    } else {
        main.stderrPrint("\n\x1b[31m[agent] ⛔ Act {d} failed after {d} unrecoverable attempts. Terminating task.\x1b[0m\n", .{ act_id, max_retries + 1 });
        self.coordinator.finishAct(act_id, false);
        return error.ActRetryExhausted;
    }
}

/// Concrete act execution running on Thread 3 (Act Executor).
pub fn executeTurnWorker(
    self: *AgentLoop,
    user_text: []const u8,
    images: []const proto.ImageBlock,
    text_cb: ?*const fn ([]const u8) void,
    think_cb: ?*const fn ([]const u8) void,
) !void {
    agent_mod.activateTurnHooks(self);
    defer agent_mod.deactivateTurnHooks();

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

    while (true) : (act_id += 1) {
        self.last_turn_acts = act_id;
        main.beginAct(act_id);
        const should_stop = try runActRetryLoop(self, act_id, tool_defs, text_cb, think_cb, &rate_limit_retries, max_retries);
        if (should_stop) return;
    }
}
