//! agent.zig — AgentLoop: main loop of mini-agent.
//!
//! AgentLoop processes user input across multiple iterations until
//! the AI returns `end_turn` (no further tool calls requested).
//!
//! ## Iteration Flow
//! ```
//! user_text -> history.addUser()
//!           -> sendToBackend(system, history, tools)  <- streaming
//!           -> response.stop_reason == .tool_use?
//!               YES -> executeTools() -> history.addToolResults() -> continue
//!               NO  -> finish, return
//! ```
//!
//! ## Backends
//! Agent selects a single backend at startup, in the following order:
//!   1. OpenAI-compatible (if OPENAI_COMPAT_URL is set)
//!   2. Claude (if ANTHROPIC_API_KEY is set)
//!   3. Ollama (local)
//!
//! ## Fallback
//! There is no cross-provider fallback at this layer: protocol/vendor
//! fallback is handled inside the provider abstraction (RFC-012), and the
//! act retry loop in `processInput` re-runs the same backend on transient
//! transport errors. A blind extra Ollama attempt was removed because it
//! usually pointed at a non-running local server and masked the real error.
//!
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const proto = @import("protocol.zig");
const config_mod = @import("config.zig");
const history_mod = @import("history.zig");
const tools_mod = @import("../tooling/registry.zig");
const media_gen_tool = @import("../tools/media_gen.zig");
const json_mod = @import("json.zig");
const openai_mod = @import("../backends/openai.zig");
const claude_mod = @import("../backends/claude.zig");
const ollama_mod = @import("../backends/ollama.zig");
const hooks_mod = @import("hooks.zig");
const main = @import("../main.zig");
const utils = @import("utils.zig");
const quickjs = @import("../runtime/quickjs_engine.zig");
const js_bindings = @import("../runtime/js_bindings.zig");
const tokens_mod = @import("memact/tokens.zig");
const graph_store_mod = @import("memact/graph_store.zig");
const snapshot_mod = @import("snapshot.zig");
const cas_mod = @import("cas.zig");
const plan_mod = @import("plan.zig");
const plan_parser = @import("plan_parser.zig");
const plan_executor = @import("plan_executor.zig");
const plan_monitor = @import("plan_monitor.zig");
const plan_store_mod = @import("plan_store.zig");
const plan_integration = @import("plan_integration.zig");
pub const journal_mod = @import("journal.zig");
pub const act_logger_mod = @import("act_logger.zig");
pub const signals = @import("signals.zig");
pub const act_queue = @import("act_queue.zig");
pub const watchdog_mod = @import("watchdog.zig");
const chat_stream = @import("../ui/chat_stream.zig");
const term = @import("../ui/terminal.zig");
const spinner_mod = @import("../ui/spinner.zig");

/// Mutex protecting g_active_agent.
pub var g_agent_mutex = std.atomic.Mutex.unlocked;

var g_active_agent: ?*AgentLoop = null;

fn agentToolListener(tool_name: []const u8, input_json: ?[]const u8, is_error: bool) void {
    while (!g_agent_mutex.tryLock()) {}
    const agent = g_active_agent;
    g_agent_mutex.unlock();
    if (agent) |a| {
        a.onToolCompleted(tool_name, input_json, is_error);
    }
}

fn agentOutputListener(chunk: []const u8) void {
    while (!g_agent_mutex.tryLock()) {}
    const agent = g_active_agent;
    g_agent_mutex.unlock();
    if (agent) |a| {
        a.coordinator.appendActLog(chunk);
    }
}

pub fn activateTurnHooks(agent: *AgentLoop) void {
    while (!g_agent_mutex.tryLock()) {}
    g_active_agent = agent;
    g_agent_mutex.unlock();
    hooks_mod.setToolListener(&agentToolListener);
    hooks_mod.setOutputListener(&agentOutputListener);
}

pub fn deactivateTurnHooks() void {
    while (!g_agent_mutex.tryLock()) {}
    g_active_agent = null;
    g_agent_mutex.unlock();
    hooks_mod.setToolListener(null);
    hooks_mod.setOutputListener(null);
}

fn watchdogInterruptHandler() void {
    while (!g_agent_mutex.tryLock()) {}
    const agent = g_active_agent;
    g_agent_mutex.unlock();
    if (agent) |a| {
        a.engine.requestInterrupt();
    }
    tools_mod.interruptActiveBash();
}

fn watchdogForceKillHandler() void {
    while (!g_agent_mutex.tryLock()) {}
    const agent = g_active_agent;
    g_agent_mutex.unlock();
    if (agent) |a| {
        a.engine.requestInterrupt();
    }
    tools_mod.forceKillActiveBash();
}

fn watchdogDecisionHandler(ctx: watchdog_mod.DecisionContext) watchdog_mod.TimeoutDecision {
    while (!g_agent_mutex.tryLock()) {}
    const agent = g_active_agent;
    g_agent_mutex.unlock();
    if (agent) |a| {
        return a.consultLlmOnTimeout(ctx);
    }
    return .{ .should_kill = false, .extend_seconds = 60 };
}

/// Maximum retries on rate limit.
const MAX_RATE_LIMIT_RETRIES = 12;
/// Initial delay on rate limit (seconds).
const RATE_LIMIT_BASE_DELAY_S: u64 = 5;
/// Maximum backoff cap on rate limit (seconds).
const RATE_LIMIT_MAX_BACKOFF_S: u64 = 120;

// ---------------------------------------------------------------------------
// Backend union
// ---------------------------------------------------------------------------

const agent_backend = @import("agent_backend.zig");
pub const Backend = agent_backend.Backend;

// ---------------------------------------------------------------------------
// AgentLoop
// ---------------------------------------------------------------------------

/// Main agent loop.
pub const AgentLoop = struct {
    alloc: Allocator,
    io: std.Io,
    /// Backend currently in use.
    backend: Backend,
    /// Conversation history.
    history: history_mod.History,
    /// Loaded configuration.
    config: *const config_mod.Config,
    /// CodeAct embedded engine.
    engine: *quickjs.Engine,
    /// Consecutive JavaScript error self-correction counter.
    js_retry_count: usize = 0,
    /// Count of role/first-message fix attempts (Claude 400) in current turn.
    role_fix_attempts: usize = 0,
    /// Consecutive response continuations due to max_tokens in current turn.
    max_tokens_continues: usize = 0,
    /// Token estimator (MemAct).
    token_estimator: tokens_mod.TokenEstimator,
    /// Content-Addressed Storage (RFC-002).
    cas: cas_mod.CAS,
    /// Act Journal (RFC-002). Null if processInput has not run.
    journal: ?journal_mod.ActJournal = null,
    /// Act Logger (Session Replay & Diagnostics).
    act_logger: ?act_logger_mod.ActLogger = null,
    /// Snapshot tracker (RFC-002/ISSUE-CODEACT-001 M4) — tracks mini.write/patch/sh.
    snapshot_tracker: ?snapshot_mod.SnapshotTracker = null,
    /// HTTP code of latest backend error (for journal ErrorDetail).
    last_backend_http_code: u32 = 0,
    /// Raw body of latest backend error (duped, owned by agent — for journal).
    last_backend_raw_error: ?[]u8 = null,
    /// Number of acts executed in the last turn.
    last_turn_acts: usize = 0,
    /// Completion tokens received in the last turn.
    last_turn_completion_tokens: usize = 0,
    /// Whether the previous act encountered an error (tool failure or JS error).
    last_act_failed: bool = false,
    /// Sticky reasoning effort/budget resolved in the previous Act
    /// (model-driven selection via mini.setThinking, with sticky fallback).
    last_effort: ?[]const u8 = null,
    last_budget: ?u32 = null,
    /// Dynamic thinking governor runtime state (enabled by default).
    dynamic_thinking: bool = true,
    /// Procedural Graph Store (RFC-010).
    pg_store: ?*graph_store_mod.PGraphStore = null,
    /// Last executed tool name (RFC-010 active node anchor).
    last_executed_tool: ?[]u8 = null,
    /// Recent tool execution sequence (w acts window).
    recent_tools: std.ArrayListUnmanaged([]u8) = .empty,
    /// Action Loop Guard: tool signatures executed in current turn.
    turn_tool_records: std.ArrayListUnmanaged(ToolCallRecord) = .empty,
    /// Hard dedupe cache: recent read-only tool results served on exact repeat
    /// instead of re-execution (mechanical replay-loop barrier).
    tool_cache: std.ArrayListUnmanaged(ToolCacheEntry) = .empty,
    /// 3D Procedural Map trajectory tracking for orbit detection and Checkpoint & Recap.
    turn_tool_trajectory: std.ArrayListUnmanaged([]u8) = .empty,
    /// Consecutive identical tool call counter.
    consecutive_dup_tool_count: usize = 0,
    /// Consecutive read-only exploratory tool call counter.
    consecutive_readonly_count: usize = 0,
    /// Last detected loop reason.
    last_loop_reason: LoopReason = .none,
    /// Flag set when action loop circuit breaker trips to break out of agent loop.
    action_loop_tripped: bool = false,
    /// Track whether the most recent LLM response had no meaningful content (empty/whitespace only).
    /// Used to prevent premature exit_loop when model returns nothing but also didn't fail.
    response_content_empty: bool = false,

    current_user_request: ?[]const u8 = null,

    /// Consolidated plan state (RFC-019 + legacy watchdog). See plan_integration.zig.
    plan: plan_integration.PlanState,

    /// 3-Thread Coordinator & State Monitor (RFC-015)
    coordinator: *act_queue.ActCoordinator,
    /// Thread 2 Watchdog Monitor
    watchdog: ?*watchdog_mod.Watchdog = null,



    pub const ToolCallRecord = struct {
        name: []u8,
        args_hash: u64,
    };

    /// Cached result of a previously executed read-only tool call (per turn).
    pub const ToolCacheEntry = struct {
        name: []u8,
        args_hash: u64,
        result: []u8,
    };

    pub const LoopReason = enum {
        none,
        identical_repeat,
        window_repeat,
        macro_cycle_2,
        macro_cycle_3,
        readonly_budget,
        orbit_cycle,
    };

    pub const LoopCheckResult = enum {
        allow,
        warn,
        trip,
    };

    pub const Error = error{
        LLMAuthenticationError,
        LLMRateLimitExceeded,
        LLMProviderUnavailable,
        LLMMalformedJsonOutput,
        LLMContextWindowExceeded,
        ActRetryExhausted,
        UnknownStopReason,
        UserCancelled,
    };

    /// Initializes AgentLoop from config.
    /// Selects backend based on config priority order.
    pub fn init(alloc: Allocator, io: std.Io, config: *const config_mod.Config) !AgentLoop {
        // Initialize CodeAct engine (Engine.init automatically registers bindings via resetContext)
        const engine = try quickjs.Engine.init(alloc, io);
        errdefer engine.deinit();

        // Select backend in priority order
        var backend: Backend = blk: {
            if (config.openai_compat_url) |url| {
                if (!utils.isSubagent()) main.stderrPrint("[agent] Backend: OpenAI-compat @ {s} ({s})\n", .{ url, config.openai_compat_model });
                const proto_mode: openai_mod.ProtocolMode = switch (config.openai_protocol) {
                    .auto => .auto,
                    .chat_completions => .chat_completions,
                    .responses => .responses,
                };
                var client = openai_mod.Client.initWithProvider(
                    alloc,
                    url,
                    config.openai_compat_key orelse "",
                    config.openai_compat_api_header,
                    config.openai_compat_model,
                    config.max_tokens,
                    proto_mode,
                    config.openai_provider,
                );
                client.provider_js = config.openai_provider_js;
                break :blk .{ .openai = client };
            }
            if (config.anthropic_key) |key| {
                if (!utils.isSubagent()) main.stderrPrint("[agent] Backend: Claude ({s})\n", .{config.claude_model});
                break :blk .{ .claude = claude_mod.Client.init(
                    alloc,
                    key,
                    config.claude_model,
                    config.max_tokens,
                ) };
            }
            // Fallback: Ollama
            if (!utils.isSubagent()) main.stderrPrint("[agent] Backend: Ollama @ {s} ({s})\n", .{ config.ollama_url, config.ollama_model });
            break :blk .{ .ollama = ollama_mod.Client.init(
                alloc,
                config.ollama_url,
                config.ollama_model,
                config.max_tokens,
            ) };
        };

        if (!config.reasoning_effort_disabled) {
            backend.setReasoningEffort(config.reasoning_effort);
            backend.setThinkingBudget(config.thinking_budget_tokens);
        }

        // Configure tool policy & media capability gates
        tools_mod.setPolicy(config.tool_allowlist, config.tool_blocklist);
        tools_mod.setMediaConfig(config.image_gen_enabled, config.video_gen_enabled, config.image_input_enabled);
        media_gen_tool.setConfig(.{
            .image_gen_enabled = config.image_gen_enabled,
            .image_gen_provider = config.image_gen_provider,
            .image_gen_model = config.image_gen_model,
            .image_gen_size = config.image_gen_size,
            .video_gen_enabled = config.video_gen_enabled,
            .video_gen_model = config.video_gen_model,
            .video_gen_provider = config.video_gen_provider,
            .media_output_dir = config.media_output_dir,
            .video_poll_timeout_secs = config.video_poll_timeout_secs,
            .openai_compat_url = config.openai_compat_url,
            .openai_compat_key = config.openai_compat_key,
            .image_input_max_bytes = config.image_input_max_bytes,
            .image_input_max_per_turn = config.image_input_max_per_turn,
        });

        var path_buf: [256]u8 = undefined;
        const home_dir = utils.getEnvSlice("HOME") orelse ".";
        const cas_path = try std.fmt.bufPrint(&path_buf, "{s}/.mini/cas", .{home_dir});
        var cas = try cas_mod.CAS.init(alloc, io, cas_path);

        var acts_buf: [256]u8 = undefined;
        const acts_path = std.fmt.bufPrint(&acts_buf, "{s}/.mini/acts", .{home_dir}) catch "/tmp/mini_acts";
        const act_logger = act_logger_mod.ActLogger.init(alloc, io, acts_path) catch null;

        var pg_store_ptr: ?*graph_store_mod.PGraphStore = null;
        if (config.memact_pg_enabled) {
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const cur_cwd = if (std.c.getcwd(&cwd_buf, cwd_buf.len)) |ptr| std.mem.sliceTo(ptr, 0) else ".";
            const prj_hash = std.hash.Fnv1a_64.hash(cur_cwd);

            var mem_path_buf: [512]u8 = undefined;
            const mem_base = config.memory_dir orelse (utils.getEnvSlice("MINI_HOME") orelse (std.fmt.bufPrint(&mem_path_buf, "{s}/.mini/memory", .{home_dir}) catch ".mini/memory"));

            const prj_mem_dir = std.fmt.allocPrint(alloc, "{s}/{x}", .{ mem_base, prj_hash }) catch null;
            if (prj_mem_dir) |pmd| {
                defer alloc.free(pmd);
                const store = alloc.create(graph_store_mod.PGraphStore) catch null;
                if (store) |st| {
                    if (graph_store_mod.PGraphStore.init(alloc, io, pmd)) |val| {
                        st.* = val;
                        st.auto_populate = config.memact_pg_auto_populate;
                        st.loadIndex(io) catch |e| {
                            main.stderrPrint("[agent] Warning: Failed to load PGraph index: {s}\n", .{@errorName(e)});
                        };
                        pg_store_ptr = st;
                    } else |e| {
                        main.stderrPrint("[agent] Warning: Failed to init PGraphStore: {s}\n", .{@errorName(e)});
                        alloc.destroy(st);
                    }
                }
            }
        }

        const cas_ptr: *cas_mod.CAS = &cas;

        const coordinator = act_queue.ActCoordinator.init(alloc);
        const watchdog = watchdog_mod.Watchdog.init(alloc, io, coordinator, .{
            .tracking_interval_s = config.watchdog_tracking_interval_s,
            .act_timeout_secs = config.act_timeout_secs,
            .recap_interval_acts = config.watchdog_recap_interval,
            .poll_interval_ms = config.watchdog_interval_ms,
            .verbose_stderr = config.action_loop_display,
        });
        watchdog.interrupt_fn = &watchdogInterruptHandler;
        watchdog.force_kill_fn = &watchdogForceKillHandler;
        watchdog.decision_fn = &watchdogDecisionHandler;
        watchdog.start() catch |e| {
            if (!utils.isSubagent()) main.stderrPrint("[agent] Warning: Failed to start Watchdog thread: {s}\n", .{@errorName(e)});
        };

        return .{
            .alloc = alloc,
            .io = io,
            .backend = backend,
            .history = history_mod.History.init(alloc),
            .config = config,
            .engine = engine,
            .js_retry_count = 0,
            .last_act_failed = false,
            .token_estimator = tokens_mod.TokenEstimator.init(alloc),
            .cas = cas,
            .journal = null,
            .act_logger = act_logger,
            .dynamic_thinking = config.dynamic_thinking_enabled,
            .pg_store = pg_store_ptr,
            .last_executed_tool = null,
            .recent_tools = .empty,
            .coordinator = coordinator,
            .watchdog = watchdog,
            .response_content_empty = false,
            .plan = plan_integration.PlanState.init(alloc, io, config, cas_ptr),
        };
    }

    /// Releases memory.
    pub fn deinit(self: *AgentLoop) void {
        if (self.watchdog) |wd| {
            wd.deinit();
            self.watchdog = null;
        }
        self.coordinator.deinit();
        if (self.snapshot_tracker) |*t| {
            snapshot_mod.setTracker(null);
            t.deinit();
        }
        self.history.deinit();
        self.engine.deinit();
        self.token_estimator.deinit();
        self.cas.deinit();
        if (self.journal) |*j| j.deinit();
        if (self.act_logger) |*al| al.deinit();
        if (self.last_backend_raw_error) |raw| self.alloc.free(raw);
        if (self.pg_store) |st| {
            st.deinit();
            self.alloc.destroy(st);
            self.pg_store = null;
        }
        if (self.last_executed_tool) |t| {
            self.alloc.free(t);
            self.last_executed_tool = null;
        }
        for (self.recent_tools.items) |t| {
            self.alloc.free(t);
        }
        self.recent_tools.deinit(self.alloc);
        self.deinitTurnToolRecords();
        self.plan.deinit();
    }

    const agent_loop_monitor = @import("agent_loop_monitor.zig");
    pub const isReadOnlyTool = agent_loop_monitor.isReadOnlyTool;
    pub const isMutatingTool = agent_loop_monitor.isMutatingTool;
    pub const isExploratoryToolCall = agent_loop_monitor.isExploratoryToolCall;
    pub const MacroCycle = agent_loop_monitor.MacroCycle;
    pub const detectMacroCycle = agent_loop_monitor.detectMacroCycle;
    pub const checkActionLoop = agent_loop_monitor.checkActionLoop;
    pub const clearTurnToolRecords = agent_loop_monitor.clearTurnToolRecords;
    pub const deinitTurnToolRecords = agent_loop_monitor.deinitTurnToolRecords;
    pub const clearToolCache = agent_loop_monitor.clearToolCache;
    pub const fuzzyArgsHash = agent_loop_monitor.fuzzyArgsHash;
    const lookupToolCache = agent_loop_monitor.lookupToolCache;
    const storeToolCache = agent_loop_monitor.storeToolCache;
    pub const hasRecentVerifiedMutation = agent_loop_monitor.hasRecentVerifiedMutation;

    pub fn detectPlanInText(text: []const u8) ?[]const u8 {
        return plan_integration.PlanState.detectPlanInText(text);
    }

    pub fn isPlanOnlyRequest(user_text_opt: ?[]const u8) bool {
        return plan_integration.PlanState.isPlanOnlyRequest(user_text_opt);
    }

    /// Saves the latest backend error context for subsequent journal recordError.
    /// Dupes raw response (since response is deinitialized before error bubbles up to processInput).
    pub fn setLastErrorContext(self: *AgentLoop, http_code: u32, raw: ?[]const u8) void {
        self.last_backend_http_code = http_code;
        if (self.last_backend_raw_error) |old| self.alloc.free(old);
        self.last_backend_raw_error = null;
        if (raw) |r| {
            self.last_backend_raw_error = self.alloc.dupe(u8, r) catch null;
        }
    }

    /// Resets the captured HTTP error context. Called at the start of every
    /// backend attempt so that a *transport* failure (which never sets a status
    /// code) is not mis-attributed to a previous request's 429/400 body.
    fn clearLastErrorContext(self: *AgentLoop) void {
        self.last_backend_http_code = 0;
        if (self.last_backend_raw_error) |old| {
            self.alloc.free(old);
            self.last_backend_raw_error = null;
        }
    }

    /// Prints full raw error response content from AI backend (if any) via TurnRenderer.
    pub fn printRawBackendResponse(raw_opt: ?[]const u8, http_code: u32) void {
        if (main.ui_repl.current_renderer) |r| {
            r.showBackendError(http_code, raw_opt);
        } else {
            var dummy = chat_stream.TurnRenderer.init(std.heap.page_allocator, main.getIo());
            dummy.showBackendError(http_code, raw_opt);
        }
    }

    /// In-place countdown timer for retries on the same line (with Braille spinner) via TurnRenderer.
    /// Supports immediate interruption upon receiving Ctrl+C.
    pub fn waitWithInplaceCountdown(self: *AgentLoop, backoff_s: u64, attempt: usize, max_attempts: usize) !void {
        if (main.ui_repl.current_renderer) |r| {
            try r.waitRetryCountdown(self.io, backoff_s, attempt, max_attempts);
        } else {
            var dummy = chat_stream.TurnRenderer.init(std.heap.page_allocator, self.io);
            try dummy.waitRetryCountdown(self.io, backoff_s, attempt, max_attempts);
        }
    }

    const agent_step = @import("agent_step.zig");
    pub const StepResult = agent_step.StepResult;
    pub const executeStep = agent_step.executeStep;

    const agent_turn = @import("agent_turn.zig");
    pub const executeTurnWorker = agent_turn.executeTurnWorker;

    pub fn logActDebug(
        self: *AgentLoop,
        act_id: usize,
        input_msgs_count: usize,
        tool_defs: []const proto.ToolDefinition,
        response: *const proto.Response,
        js_code_opt: ?[]const u8,
        exec_info: act_logger_mod.ActExecutionInfo,
    ) void {
        const logger = if (self.act_logger != null) &self.act_logger.? else return;

        const msgs = self.history.messages();
        const safe_count = @min(input_msgs_count, msgs.len);
        const input_msgs = msgs[0..safe_count];

        var text_acc: ?[]const u8 = null;
        var think_acc: ?[]const u8 = null;
        var tool_calls_list = std.ArrayListUnmanaged(proto.ToolUse).empty;
        defer tool_calls_list.deinit(self.alloc);

        for (response.content.items) |block| {
            switch (block) {
                .text => |t| text_acc = t,
                .thinking => |th| think_acc = th.thinking,
                .tool_use => |tu| tool_calls_list.append(self.alloc, tu) catch {},
                else => {},
            }
        }

        var snapshots_list = std.ArrayListUnmanaged(act_logger_mod.ActSnapshotInfo).empty;
        defer snapshots_list.deinit(self.alloc);
        if (self.snapshot_tracker) |t| {
            for (t.tracked.items) |tf| {
                snapshots_list.append(self.alloc, .{
                    .path = tf.path,
                    .previous_content_hash = tf.previous_content_hash,
                }) catch {};
            }
        }

        const pid: u32 = @intCast(std.c.getpid());
        logger.logAct(self.io, .{
            .session_pid = pid,
            .act_id = act_id,
            .timestamp = utils.milliTimestamp(),
            .backend_name = self.backend.name(),
            .backend_model = self.backend.model(),
            .system_prompt = self.config.system_prompt,
            .messages_count = input_msgs.len,
            .input_messages = input_msgs,
            .tool_definitions = tool_defs,
            .llm_response = .{
                .http_code = response.http_code,
                .stop_reason = @tagName(response.stop_reason),
                .text = text_acc,
                .thinking = think_acc,
                .js_code = js_code_opt,
                .tool_calls = if (tool_calls_list.items.len > 0) tool_calls_list.items else null,
                .usage = response.usage,
                .raw_debug_info = response.raw_debug_info,
            },
            .execution = exec_info,
            .snapshots = snapshots_list.items,
        }) catch {};
    }

    /// Processes user input through agentic loop.
    /// Handle tool completion lifecycle event (RFC-010 Procedural Graph tracking)
    pub fn onToolCompleted(self: *AgentLoop, tool_name: []const u8, input_json: ?[]const u8, is_error: bool) void {
        if (self.pg_store) |pg| {
            if (self.last_executed_tool) |prev_tool| {
                pg.recordTransition(self.io, prev_tool, tool_name) catch {};
            }
        }

        if (self.last_executed_tool) |old_t| {
            self.alloc.free(old_t);
            self.last_executed_tool = null;
        }
        self.last_executed_tool = self.alloc.dupe(u8, tool_name) catch null;

        if (self.recent_tools.items.len >= self.config.memact_pg_w) {
            const oldest = self.recent_tools.orderedRemove(0);
            self.alloc.free(oldest);
        }
        if (self.alloc.dupe(u8, tool_name)) |dup_t| {
            self.recent_tools.append(self.alloc, dup_t) catch {
                self.alloc.free(dup_t);
            };
        } else |_| {}

        self.last_act_failed = is_error;
        const args_hash: u64 = if (input_json) |ij|
            std.hash.Wyhash.hash(0, std.mem.trim(u8, ij, " \t\r\n"))
        else
            0;

        self.coordinator.recordToolExecution(
            tool_name,
            args_hash,
            isReadOnlyTool(tool_name),
        );
    }

    /// `text_cb`: invoked with each text chunk as AI streams.
    pub fn processInput(
        self: *AgentLoop,
        user_text: []const u8,
        text_cb: ?*const fn ([]const u8) void,
        think_cb: ?*const fn ([]const u8) void,
    ) !void {
        return self.processInputWithImages(user_text, &.{}, text_cb, think_cb);
    }

    const TurnWorkerContext = struct {
        agent: *AgentLoop,
        user_text: []const u8,
        images: []const proto.ImageBlock,
        text_cb: ?*const fn ([]const u8) void,
        think_cb: ?*const fn ([]const u8) void,
        result: anyerror!void = {},
    };

    fn turnWorkerThreadEntry(ctx: *TurnWorkerContext) void {
        ctx.result = ctx.agent.executeTurnWorker(
            ctx.user_text,
            ctx.images,
            ctx.text_cb,
            ctx.think_cb,
        );
    }

    /// Process user input with optional attached image blocks (RFC-011 Media Ingestion, RFC-015 3-Thread Architecture).
    pub fn processInputWithImages(
        self: *AgentLoop,
        user_text: []const u8,
        images: []const proto.ImageBlock,
        text_cb: ?*const fn ([]const u8) void,
        think_cb: ?*const fn ([]const u8) void,
    ) !void {
        self.coordinator.resetTurn();
        defer self.coordinator.notifyTurnComplete();

        // If inside subagent thread or child execution: execute directly
        if (utils.isSubagent()) {
            return self.executeTurnWorker(user_text, images, text_cb, think_cb);
        }

        var ctx = TurnWorkerContext{
            .agent = self,
            .user_text = user_text,
            .images = images,
            .text_cb = text_cb,
            .think_cb = think_cb,
        };

        const worker_thread = try std.Thread.spawn(.{}, turnWorkerThreadEntry, .{&ctx});
        worker_thread.join();

        return ctx.result;
    }

    /// Clears conversation history (starts new conversation).
    pub fn clearHistory(self: *AgentLoop) void {
        self.history.clear();
    }

    /// Switches backend at runtime.
    /// name: "openai", "claude", "ollama"
    pub fn switchBackend(self: *AgentLoop, backend_name: []const u8, model_override: ?[]const u8) void {
        const cfg = self.config;

        if (std.mem.eql(u8, backend_name, "openai") or std.mem.eql(u8, backend_name, "openai-compat")) {
            const url = cfg.openai_compat_url orelse {
                main.stderrPrint("[agent] OPENAI_COMPAT_URL is not configured\n", .{});
                return;
            };
            const proto_mode: openai_mod.ProtocolMode = switch (cfg.openai_protocol) {
                .auto => .auto,
                .chat_completions => .chat_completions,
                .responses => .responses,
            };
            self.backend = .{ .openai = openai_mod.Client.initWithProvider(
                self.alloc,
                url,
                cfg.openai_compat_key orelse "",
                cfg.openai_compat_api_header,
                model_override orelse cfg.openai_compat_model,
                cfg.max_tokens,
                proto_mode,
                cfg.openai_provider,
            ) };
            self.backend.openai.provider_js = cfg.openai_provider_js;
        } else if (std.mem.eql(u8, backend_name, "claude")) {
            const key = cfg.anthropic_key orelse {
                main.stderrPrint("[agent] ANTHROPIC_API_KEY is not configured\n", .{});
                return;
            };
            self.backend = .{ .claude = claude_mod.Client.init(
                self.alloc,
                key,
                model_override orelse cfg.claude_model,
                cfg.max_tokens,
            ) };
        } else if (std.mem.eql(u8, backend_name, "ollama")) {
            self.backend = .{ .ollama = ollama_mod.Client.init(
                self.alloc,
                cfg.ollama_url,
                model_override orelse cfg.ollama_model,
                cfg.max_tokens,
            ) };
        } else {
            main.stderrPrint("[agent] Invalid backend: {s}. Choices: openai, claude, ollama\n", .{backend_name});
            return;
        }

        main.stderrPrint("[agent] Switched to {s} ({s})\n", .{ self.backend.name(), self.backend.model() });
    }

    /// Set OpenAI protocol mode at runtime (auto | chat | responses).
    /// Only applies when the active backend is OpenAI-compatible.
    pub fn setProtocol(self: *AgentLoop, mode_str: []const u8) void {
        const mode: openai_mod.ProtocolMode = openai_mod.ProtocolMode.fromString(mode_str);
        switch (self.backend) {
            .openai => |*c| {
                c.protocol_mode = mode;
                c.cached_protocol = null; // clear cached negotiation so new mode takes effect immediately
                main.stderrPrint("[agent] Protocol set to: {s}\n", .{@tagName(mode)});
            },
            else => {
                main.stderrPrint("[agent] /config protocol only applies to openai-compat backend\n", .{});
            },
        }
    }

    /// Toggle dynamic thinking governor at runtime.
    pub fn setDynamicThinking(self: *AgentLoop, enabled: bool) void {
        self.dynamic_thinking = enabled;
        main.stderrPrint("[agent] Dynamic thinking: {s}\n", .{if (enabled) "enabled" else "disabled"});
    }

    /// Set reasoning effort at runtime ("low" | "medium" | "high" | "none" | "auto").
    pub fn setReasoningEffort(self: *AgentLoop, effort: []const u8) void {
        if (std.mem.eql(u8, effort, "auto")) {
            self.dynamic_thinking = true;
            self.last_effort = null;
            self.backend.setReasoningEffort(null);
            main.stderrPrint("[agent] Reasoning effort set to: auto (dynamic thinking enabled)\n", .{});
        } else if (std.mem.eql(u8, effort, "low")) {
            self.last_effort = "low";
            self.backend.setReasoningEffort("low");
            main.stderrPrint("[agent] Reasoning effort set to: low\n", .{});
        } else if (std.mem.eql(u8, effort, "medium") or std.mem.eql(u8, effort, "med")) {
            self.last_effort = "medium";
            self.backend.setReasoningEffort("medium");
            main.stderrPrint("[agent] Reasoning effort set to: medium\n", .{});
        } else if (std.mem.eql(u8, effort, "high")) {
            self.last_effort = "high";
            self.backend.setReasoningEffort("high");
            main.stderrPrint("[agent] Reasoning effort set to: high\n", .{});
        } else if (std.mem.eql(u8, effort, "none") or std.mem.eql(u8, effort, "off")) {
            self.last_effort = "none";
            self.backend.setReasoningEffort("none");
            main.stderrPrint("[agent] Reasoning effort set to: none\n", .{});
        } else {
            main.stderrPrint("[agent] Invalid reasoning effort: {s}. Choices: auto, low, medium, high, none\n", .{effort});
        }
    }

    // -----------------------------------------------------------------------
    // Internal
    // -----------------------------------------------------------------------

    pub fn sendToBackend(
        self: *AgentLoop,
        act_id: usize,
        system_prompt: []const u8,
        msgs: []const proto.Message,
        tool_defs: []const proto.ToolDefinition,
        text_cb: ?*const fn ([]const u8) void,
        think_cb: ?*const fn ([]const u8) void,
    ) !proto.Response {
        if (signals.isInterrupted()) return error.Interrupted;

        if (main.ui_repl.current_renderer) |r| {
            r.startWaiting();
        }

        // Clear stale HTTP error context (e.g. a previous act's 429/400). Without
        // this a transport failure below would be mis-attributed to that old
        // status/body in the journal (see sendToBackend error handling).
        self.clearLastErrorContext();

        // Primary backend.
        //
        // Cross-provider fallback (e.g. OpenAI-compat -> Responses API, or
        // vendor routing) is already handled *inside* the backend / provider
        // abstraction layer (RFC-012), so there is no second Ollama attempt
        // here. Blindly falling back to a local Ollama that is usually not
        // running only added an extra failing round-trip and masked the real
        // primary error in the journal.
        const primary = self.backend.send(system_prompt, msgs, tool_defs, text_cb, think_cb);
        if (primary) |resp| return resp else |e| {
            if (e == error.Interrupted or signals.isInterrupted()) {
                return error.Interrupted;
            }
            if (main.ui_repl.current_renderer) |r| {
                r.stopWaiting();
                if (r.is_thinking) r.endThinking();
                r.ensureNewline();
            }
            // Journal the transport/parse error using the PRIMARY backend's error
            // name (previously this was recorded as the Ollama fallback's
            // ConnectionRefused, which masked the true cause).
            if (self.journal) |*j| {
                const desc = std.fmt.allocPrint(
                    self.alloc,
                    "{s} backend error ({s})",
                    .{ self.backend.name(), @errorName(e) },
                ) catch "Backend error";
                defer self.alloc.free(desc);
                j.recordError(self.io, act_id, .llm_provider_error, desc, .{
                    .backend = self.backend.name(),
                    .model = self.backend.model(),
                    .error_name = @errorName(e),
                    .http_code = self.last_backend_http_code,
                    .attempt = 1,
                    .raw_snippet = self.last_backend_raw_error,
                }) catch {};
            }
            return e;
        }
    }

    /// 1-call LLM consultation invoked by Thread 2 Watchdog on timeout.
    /// Evaluates whether the long-running action is making valid progress (WAIT) or stuck/hung (KILL).
    pub fn consultLlmOnTimeout(self: *AgentLoop, ctx: watchdog_mod.DecisionContext) watchdog_mod.TimeoutDecision {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const alloc = arena.allocator();

        const system_prompt =
            \\You are the Watchdog Supervisor for mini-agent.
            \\An action is taking longer than the configured timeout limit.
            \\Your job is to analyze the action and output to decide if it is legitimately working (e.g. compiling, downloading, running a long test suite) or hung/frozen/waiting for input.
        ;

        var prompt_buf = utils.BufWriter.init(alloc);
        prompt_buf.print(
            \\Act {d} has been running action '{s}' for {d}s (timeout limit is {d}s).
            \\
            \\Recent execution output tail ({d} bytes):
            \\```
            \\{s}
            \\```
            \\
            \\Determine whether this action is making legitimate forward progress that needs more time, OR is stuck, deadlocked, idling, or waiting on user input.
            \\
            \\Respond on the first line strictly with:
            \\DECISION: WAIT <seconds> (e.g., DECISION: WAIT 60)
            \\or
            \\DECISION: KILL
            \\
            \\On the second line, provide a short 1-sentence reason:
            \\REASON: <explanation>
        , .{
            ctx.act_id,
            ctx.action_desc,
            ctx.elapsed_s,
            ctx.timeout_s,
            ctx.log_tail.len,
            ctx.log_tail,
        }) catch {
            return .{ .should_kill = false, .extend_seconds = 60 };
        };

        const blocks = [_]proto.ContentBlock{
            .{ .text = prompt_buf.list.items },
        };
        const msgs = [_]proto.Message{
            .{
                .role = .user,
                .content = &blocks,
            },
        };

        var resp = self.backend.send(
            system_prompt,
            &msgs,
            &[_]proto.ToolDefinition{},
            null,
            null,
        ) catch |e| {
            var fallback = watchdog_mod.TimeoutDecision{
                .should_kill = false,
                .extend_seconds = 30,
            };
            const err_msg = std.fmt.bufPrint(&fallback.reason_buf, "LLM decision call failed: {s}, safety wait 30s", .{@errorName(e)}) catch "LLM decision failed";
            fallback.reason_len = err_msg.len;
            return fallback;
        };
        defer resp.deinit();

        var full_text = utils.BufWriter.init(alloc);
        for (resp.content.items) |block| {
            switch (block) {
                .text => |t| full_text.writeAll(t) catch {},
                else => {},
            }
        }

        return parseTimeoutDecision(full_text.list.items);
    }

    /// Performs context compaction (MemAct compaction) when model returns context limit error.
    pub fn compactContext(self: *AgentLoop, act_id: usize) !void {
        if (self.history.messages().len <= 2) {
            self.history.compact();
            return;
        }

        main.stderrPrint("\x1b[33m[agent] Summarizing context (MemAct compaction)...\x1b[0m\n", .{});

        if (self.config.memact_enabled) {
            var msg_blocks = try self.alloc.alloc(proto.ContentBlock, 1);
            msg_blocks[0] = .{ .text = try self.alloc.dupe(u8, 
                "SYSTEM: You are the MemAct memory engine. Concisely summarize the preceding conversation into JSON, strictly adhering to this stencil:\n" ++
                "{\n" ++
                "  \"type\": \"context_summary\",\n" ++
                "  \"iteration_range\": [1, 99],\n" ++
                "  \"task_state\": \"progress description\",\n" ++
                "  \"decisions\": [\"decision 1\"],\n" ++
                "  \"open_questions\": [],\n" ++
                "  \"learned_errors\": [],\n" ++
                "  \"files_touched\": [],\n" ++
                "  \"next_step\": \"next step\"\n" ++
                "}\n" ++
                "If the input conversation already contains a \"[MemAct Context Summary]\" block, merge the previous summary into the new summary, retaining critical details while preserving the JSON stencil above.\n" ++
                "Output JSON only, with no additional markdown text."
            ) };
            const sys_msg = proto.Message{ .role = .user, .content = msg_blocks };
            defer {
                self.alloc.free(sys_msg.content[0].text);
                self.alloc.free(sys_msg.content);
            }
            
            var temp_msgs = std.ArrayListUnmanaged(proto.Message).empty;
            defer temp_msgs.deinit(self.alloc);
            try temp_msgs.appendSlice(self.alloc, self.history.messages());
            try temp_msgs.append(self.alloc, sys_msg);

            var summary_resp = try self.sendToBackend(act_id, self.config.system_prompt, temp_msgs.items, &[_]proto.ToolDefinition{}, null, null);
            defer summary_resp.deinit();

            var compacted = false;
            for (summary_resp.content.items) |block| {
                if (block == .text) {
                    try self.history.compactMemAct(act_id, block.text);
                    compacted = true;
                    break;
                }
            }
            if (!compacted) {
                main.stderrPrint("[agent] Warning: LLM did not return text summary, fallback.\n", .{});
                self.history.compact();
            }
        } else {
            main.stderrPrint("\n\x1b[33m[agent] History too long (MemAct disabled), compacting using legacy method...\x1b[0m\n", .{});
            
            var msg_blocks = try self.alloc.alloc(proto.ContentBlock, 1);
            msg_blocks[0] = .{ .text = try self.alloc.dupe(u8, "SYSTEM: History is full. Please summarize the current task state (what has been done, results, next steps). Do not call tools, return summary text only.") };
            const sys_msg = proto.Message{ .role = .user, .content = msg_blocks };
            defer {
                self.alloc.free(sys_msg.content[0].text);
                self.alloc.free(sys_msg.content);
            }
            
            var temp_msgs = std.ArrayListUnmanaged(proto.Message).empty;
            defer temp_msgs.deinit(self.alloc);
            try temp_msgs.appendSlice(self.alloc, self.history.messages());
            try temp_msgs.append(self.alloc, sys_msg);
            
            var summary_resp = try self.sendToBackend(act_id, self.config.system_prompt, temp_msgs.items, &[_]proto.ToolDefinition{}, null, null);
            defer summary_resp.deinit();
            
            var compacted = false;
            for (summary_resp.content.items) |block| {
                if (block == .text) {
                    try self.history.compactWithSummary(block.text);
                    compacted = true;
                    break;
                }
            }
            if (!compacted) {
                self.history.compact();
            }
        }
    }

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

    /// Executes all tool_use blocks in response.
    /// Returns execution summary for act debug logging.

    pub fn executeTools(self: *AgentLoop, act_id: usize, response: *const proto.Response) !ToolExecSummary {
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

        for (response.content.items) |block| {
            if (signals.isInterrupted()) return error.Interrupted;
            switch (block) {
                .tool_use => |tu| {
                    const loop_check = self.checkActionLoop(tu.name, tu.input_json) catch .allow;
                    if (loop_check == .trip) {
                        const trip_reason_str = switch (self.last_loop_reason) {
                            .macro_cycle_2 => "alternating tool loop (A ↔ B) repeated",
                            .macro_cycle_3 => "3-step tool cycle (A → B → C) repeated",
                            .orbit_cycle => "closed orbit in 3D procedural map repeated",
                            .readonly_budget => "read-only exploratory budget exceeded without code mutation",
                            else => "called repeatedly with identical parameters",
                        };

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
                            const trip_msg = switch (self.last_loop_reason) {
                                .orbit_cycle, .macro_cycle_2, .macro_cycle_3 => blk: {
                                    var mbw = utils.BufWriter.init(self.alloc);
                                    errdefer mbw.deinit();
                                    mbw.writeAll("[Action Loop Checkpoint & Trajectory Recap]\n") catch {};
                                    mbw.print("📍 Waypoint: Action loop detected ({s}).\n", .{trip_reason_str}) catch {};
                                    mbw.writeAll("🗺️ Trajectory Scouted: ") catch {};
                                    for (self.turn_tool_trajectory.items, 0..) |tn, i| {
                                        if (i > 0) mbw.writeAll(" → ") catch {};
                                        mbw.print("`{s}`", .{tn}) catch {};
                                    }
                                    mbw.writeAll("\n⚠️ Exploration has circled in place without forward progress (ΔZ = 0).\n") catch {};
                                    mbw.writeAll("Consider a different approach for the next step if appropriate.\n") catch {};
                                    break :blk try mbw.toOwnedSlice();
                                },
                                .readonly_budget => try std.fmt.allocPrint(
                                    self.alloc,
                                    "[Action Loop Checkpoint & Trajectory Recap]\n📍 Waypoint: Read-only exploratory budget exceeded ({d} consecutive search/read actions without mutation).\n\n[Exploration Advisory (Optional Suggestions)]\nCurrent Action: read-only exploration\nObservation: Sufficient context gathered.\n⚠️ Advisory Note: These are heuristic suggestions from past workflows. You are NOT required to follow them. If you have gathered sufficient context, proceed directly to modifying code or concluding.",
                                    .{self.consecutive_readonly_count},
                                ),
                                else => try std.fmt.allocPrint(
                                    self.alloc,
                                    "[Action Loop Checkpoint & Trajectory Recap]\n📍 Waypoint: Repeated invocation of '{s}' with identical parameters.\n\n[Tool Call Advisory (Optional Suggestions)]\nCurrent Action: `{s}`\nObservation: Already invoked with identical arguments. Data is in context.\n⚠️ Advisory Note: These are heuristic suggestions from past workflows. You are NOT required to follow them. If you have gathered sufficient context, proceed directly to modifying code or concluding.",
                                    .{ tu.name, tu.name },
                                ),
                            };
                            try allocated_strings.append(self.alloc, trip_msg);
                            try results.append(self.alloc, .{
                                .tool_use_id = tu.id,
                                .content = trip_msg,
                                .is_error = true,
                            });
                            self.action_loop_tripped = false;
                            self.consecutive_dup_tool_count = 0;
                            break;
                        } else {
                            main.stderrPrint(
                                "\n\x1b[33m[agent] ⚠️ Action loop persisted after replanning attempts: {s}. Halting turn.\x1b[0m\n",
                                .{trip_reason_str},
                            );
                            if (main.ui_repl.current_renderer) |r| {
                                r.ensureNewline();
                                r.write(" \x1b[33m[Action loop persisted: halting turn]\x1b[0m\n");
                            }
                            const trip_msg = try std.fmt.allocPrint(
                                self.alloc,
                                "[Action Loop Halt]: Action loop persisted after multiple replanning requests ({s}). Execution paused. Please explain your status and request user guidance.",
                                .{trip_reason_str},
                            );
                            try allocated_strings.append(self.alloc, trip_msg);
                            try results.append(self.alloc, .{
                                .tool_use_id = tu.id,
                                .content = trip_msg,
                                .is_error = true,
                            });
                            self.action_loop_tripped = true;
                            break;
                        }
                    }

                    var warn_suffix: ?[]u8 = null;
                    defer if (warn_suffix) |w| self.alloc.free(w);
                    if (loop_check == .warn) {
                        warn_suffix = switch (self.last_loop_reason) {
                            .orbit_cycle, .macro_cycle_2, .macro_cycle_3 => std.fmt.allocPrint(
                                self.alloc,
                                "\n\n[3D Procedural Map Advisory: Orbit Checkpoint & Recap]\n⚠️ Trajectory Orbit Detected: You are circling around already-scouted nodes in procedural space. If you have gathered sufficient context, consider whether further exploration is needed or if you may proceed to conclude.",
                                .{},
                            ) catch null,
                            .readonly_budget => std.fmt.allocPrint(
                                self.alloc,
                                "\n\n[System Advisory]: You have performed {d} consecutive read-only exploratory actions. If you have gathered sufficient information, proceed to take action or synthesize your response.",
                                .{self.consecutive_readonly_count},
                            ) catch null,
                            else => std.fmt.allocPrint(
                                self.alloc,
                                "\n\n[System Advisory]: Action loop detected. You have called '{s}' with identical arguments multiple times. You already have this data in your context. If you feel you have enough information, you may synthesize your findings and respond to the user.",
                                .{tu.name},
                            ) catch null,
                        };
                    }

                    // Plan completion: non-exploratory tool call means the model is executing its plan.
                    if (self.plan.plan_active and !isPlanOnlyRequest(self.current_user_request) and
                        !isExploratoryToolCall(tu.name, tu.input_json))
                    {
                        self.plan.clearPlan();
                    }

                    // Hard dedupe barrier: serve cached result for repeated read-only
                    // calls instead of re-executing (prevents mechanical replay loops;
                    // model sees identical data without redundant execution).
                    if (isReadOnlyTool(tu.name)) {
                        const cache_hash = fuzzyArgsHash(tu.input_json);
                        if (self.lookupToolCache(tu.name, cache_hash)) |cached| {
                            main.stderrPrint(
                                "\x1b[33m[duplicate: serving cached result]\x1b[0m\n",
                                .{},
                            );
                            const note = try std.fmt.allocPrint(
                                self.alloc,
                                "[duplicate: identical call already executed this turn — cached result below]\n{s}",
                                .{cached},
                            );
                            try allocated_strings.append(self.alloc, note);
                            try results.append(self.alloc, .{
                                .tool_use_id = tu.id,
                                .content = note,
                                .is_error = false,
                            });
                            tool_count += 1;
                            continue;
                        }
                    }

                    const start_tool_ms = utils.milliTimestamp();
                    self.coordinator.updateStatus(act_id, .executing_tool, tu.name);
                    if (main.ui_repl.current_renderer) |r| {
                        r.startTool(tu.name, tu.input_json);
                    } else {
                        // Display tool name and primary parameters (fallback log)
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
                                main.stderrPrint("\x1b[90m[{s}]\x1b[0m \x1b[34m{s}\x1b[0m ", .{tu.name, path});
                            } else {
                                main.stderrPrint("\x1b[90m[tool: {s}]\x1b[0m ", .{tu.name});
                            }
                        } else if (std.mem.eql(u8, tu.name, "codeact")) {
                            main.stderrPrint("\x1b[90m[codeact]\x1b[0m \x1b[35mExecuting CodeAct script...\x1b[0m ", .{});
                        } else {
                            main.stderrPrint("\x1b[90m[tool: {s}]\x1b[0m ", .{tu.name});
                        }
                    }

                    // Snapshot file if editing tool
                    if (std.mem.eql(u8, tu.name, "file_edit") or std.mem.eql(u8, tu.name, "file_write")) {
                        if (json_mod.findString(tu.input_json, "path")) |path| {
                            if (self.snapshot_tracker) |*t| {
                                t.beforeFileWrite(path);
                            }
                        }
                    }

                    var is_err = false;
                    const result = tools_mod.executeTool(self.alloc, self.io, tu.name, tu.input_json) catch |e| blk: {
                        if (e == error.Interrupted or signals.isInterrupted()) {
                            return error.Interrupted;
                        }
                        is_err = true;
                        any_tool_err = true;
                        const msg = try std.fmt.allocPrint(self.alloc, "Tool error: {s}", .{@errorName(e)});
                        break :blk msg;
                    };
                    if (signals.isInterrupted()) {
                        self.alloc.free(result);
                        return error.Interrupted;
                    }
                    try allocated_strings.append(self.alloc, result);

                    // Truncate if oversized
                    const max_tool_result = 64 * 1024;
                    const truncated = if (result.len > max_tool_result) result[0..max_tool_result] else result;

                    var merged_suffix = utils.BufWriter.init(self.alloc);
                    defer merged_suffix.deinit();
                    if (warn_suffix) |ws| try merged_suffix.writeAll(ws);

                    const final_content = if (merged_suffix.list.items.len > 0) blk: {
                        const merged = try std.fmt.allocPrint(self.alloc, "{s}{s}", .{ truncated, merged_suffix.list.items });
                        try allocated_strings.append(self.alloc, merged);
                        break :blk merged;
                    } else truncated;

                    try results.append(self.alloc, .{
                        .tool_use_id = tu.id,
                        .content = final_content,
                        .is_error = is_err,
                    });
                    // Cache successful read-only results for the dedupe barrier.
                    if (!is_err and isReadOnlyTool(tu.name)) {
                        self.storeToolCache(tu.name, fuzzyArgsHash(tu.input_json), truncated) catch {};
                    }
                    if (!is_err) {
                        self.plan.loop_plan_retries = 0;
                        self.plan.plan_execution_pending = false;
                        self.plan.plan_watchdog_retries = 0;
                        if (!isExploratoryToolCall(tu.name, tu.input_json)) {
                            // RFC-019: Plan execution tracking
                            if (self.plan.enable_structured_planning and self.plan.current_plan != null) {
                                var plan = &self.plan.current_plan.?;
                                // Check drift
                                if (self.config.plan_drift_detection) {
                                    const drift = plan_monitor.checkPlanDrift(
                                        plan,
                                        &self.plan.plan_ctx,
                                        tu.name,
                                    );
                                    if (drift) |d| {
                                        self.plan.plan_drift_score += d.drift_score;
                                        // Inject drift correction if score too high
                                        if (self.plan.plan_drift_score > 0.8) {
                                            const correction = plan_monitor.generateReplanSuggestion(
                                                plan,
                                                self.plan.plan_ctx.steps_completed,
                                                self.plan.plan_drift_score,
                                                self.alloc,
                                            ) catch null;
                                            if (correction) |c| {
                                                defer self.alloc.free(c);
                                                const adv = std.fmt.allocPrint(self.alloc, "[System Advisory]: {s}", .{c}) catch null;
                                                if (adv) |a| {
                                                    try allocated_strings.append(self.alloc, a);
                                                    try results.append(self.alloc, .{
                                                        .tool_use_id = tu.id,
                                                        .content = a,
                                                        .is_error = false,
                                                    });
                                                }
                                            }
                                        }
                                    }
                                }

                                // Complete current step if tool matches hint
                                if (self.plan.plan_ctx.current_step_idx < plan.stepCount()) {
                                    const current_step = &plan.steps.items[self.plan.plan_ctx.current_step_idx];
                                    if (current_step.tool_hint) |hint| {
                                        if (std.mem.eql(u8, tu.name, hint)) {
                                            plan_executor.completeStep(plan, &self.plan.plan_ctx);
                                            if (!utils.isSubagent()) {
                                                main.stderrPrint("[agent] Plan step completed: {s}\n", .{current_step.description});
                                            }
                                        }
                                    }
                                }

                                // Check if plan is complete
                                if (self.plan.plan_ctx.is_complete or plan.isComplete()) {
                                    if (!utils.isSubagent()) {
                                        main.stderrPrint("[agent] Plan completed! Saving to store...\n", .{});
                                    }
                                    if (self.plan.plan_store) |ps| {
                                        ps.save(plan) catch |e| {
                                            main.stderrPrint("[agent] Warning: Failed to save plan: {s}\n", .{@errorName(e)});
                                        };
                                    }
                                    self.plan.clearPlan();
                                } else {
                                    // Move to next step
                                    if (self.plan.plan_ctx.current_step_idx + 1 < plan.stepCount()) {
                                        self.plan.plan_ctx.current_step_idx += 1;
                                        plan.steps.items[self.plan.plan_ctx.current_step_idx].status = .active;
                                    }
                                }
                            } else {
                                self.plan.clearPlan();
                            }
                        }
                    }

                    const end_tool_ms = utils.milliTimestamp();
                    const dur_ms = if (end_tool_ms >= start_tool_ms) @as(u64, @intCast(end_tool_ms - start_tool_ms)) else 0;
                    total_dur_ms += dur_ms;
                    tool_count += 1;

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
                },
                else => {},
            }
        }

        if (results.items.len > 0) {
            const turn_attached = media_gen_tool.getTurnAttachments();
            if (turn_attached.len > 0) {
                try self.history.addToolResultsWithImages(results.items, turn_attached);
                media_gen_tool.clearTurnAttachments(self.alloc);
            } else {
                try self.history.addToolResults(results.items);
            }
        }
        self.last_act_failed = any_tool_err;
        return ToolExecSummary{
            .any_tool_err = any_tool_err,
            .total_dur_ms = total_dur_ms,
            .tool_count = tool_count,
        };
    }
};


// Parsing helpers moved to agent_parsing.zig; re-exported so existing
// call sites and unit tests keep working unchanged.
const agent_parsing = @import("agent_parsing.zig");
pub const extractJsCodeBlock = agent_parsing.extractJsCodeBlock;
pub const convertXmlToolTagsToJs = agent_parsing.convertXmlToolTagsToJs;
pub const findJsCodeInResponse = agent_parsing.findJsCodeInResponse;
pub const parseTimeoutDecision = agent_parsing.parseTimeoutDecision;

test "agent - extractJsCodeBlock" {
    const alloc = std.testing.allocator;
    const md =
        \\Here is the execution code:
        \\```js
        \\const a = 10;
        \\const b = 20;
        \\console.log(a + b);
        \\```
        \\See the results above.
    ;

    const extracted = extractJsCodeBlock(alloc, md);
    try std.testing.expect(extracted != null);
    defer alloc.free(extracted.?);

    try std.testing.expectEqualStrings("const a = 10;\nconst b = 20;\nconsole.log(a + b);", extracted.?);
}

test "agent - convertXmlToolTagsToJs" {
    const alloc = std.testing.allocator;
    const text =
        \\<file_read file="/home/mypc/project/rfc_003_summary.md" />
        \\<glob path="/home/mypc/project" pattern="**/*rfc_003*" />
    ;

    const js = convertXmlToolTagsToJs(alloc, text);
    try std.testing.expect(js != null);
    defer alloc.free(js.?);

    try std.testing.expect(std.mem.indexOf(u8, js.?, "mini.read") != null);
    try std.testing.expect(std.mem.indexOf(u8, js.?, "mini.glob") != null);
}

test "agent - checkActionLoop consecutive identical tool calls" {
    const alloc = std.testing.allocator;
    var cfg: config_mod.Config = undefined;
    cfg.action_loop_consecutive_cap = 3;
    cfg.action_loop_window_cap = 4;
    cfg.action_loop_readonly_warn_cap = 5;
    cfg.action_loop_readonly_trip_cap = 10;
    cfg.action_loop_macro_cycle_cap = 2;
    cfg.action_loop_orbit_cap = 2;

    var agent: AgentLoop = undefined;
    agent.alloc = alloc;
    agent.config = &cfg;
    agent.turn_tool_records = .empty;
    agent.tool_cache = .empty;
    agent.turn_tool_trajectory = .empty;
    agent.consecutive_dup_tool_count = 0;
    agent.consecutive_readonly_count = 0;
    agent.last_loop_reason = .none;
    agent.action_loop_tripped = false;
    defer agent.deinitTurnToolRecords();

    // Call 1: first time -> allow
    const res1 = try agent.checkActionLoop("bash", "{\"command\":\"ls -la\"}");
    try std.testing.expectEqual(AgentLoop.LoopCheckResult.allow, res1);
    try std.testing.expectEqual(@as(usize, 1), agent.consecutive_dup_tool_count);
    try std.testing.expect(!agent.action_loop_tripped);

    // Call 2: second consecutive identical call -> warn
    const res2 = try agent.checkActionLoop("bash", "{\"command\":\"ls -la\"}");
    try std.testing.expectEqual(AgentLoop.LoopCheckResult.warn, res2);
    try std.testing.expectEqual(@as(usize, 2), agent.consecutive_dup_tool_count);
    try std.testing.expect(!agent.action_loop_tripped);

    // Call 3: third consecutive identical call -> trip circuit breaker!
    const res3 = try agent.checkActionLoop("bash", "{\"command\":\"ls -la\"}");
    try std.testing.expectEqual(AgentLoop.LoopCheckResult.trip, res3);
    try std.testing.expectEqual(@as(usize, 3), agent.consecutive_dup_tool_count);
    try std.testing.expect(agent.action_loop_tripped);
}

test "agent - checkActionLoop different commands reset consecutive count" {
    const alloc = std.testing.allocator;
    var cfg: config_mod.Config = undefined;
    cfg.action_loop_consecutive_cap = 3;
    cfg.action_loop_window_cap = 4;
    cfg.action_loop_readonly_warn_cap = 5;
    cfg.action_loop_readonly_trip_cap = 10;
    cfg.action_loop_macro_cycle_cap = 2;
    cfg.action_loop_orbit_cap = 2;

    var agent: AgentLoop = undefined;
    agent.alloc = alloc;
    agent.config = &cfg;
    agent.turn_tool_records = .empty;
    agent.tool_cache = .empty;
    agent.turn_tool_trajectory = .empty;
    agent.consecutive_dup_tool_count = 0;
    agent.consecutive_readonly_count = 0;
    agent.last_loop_reason = .none;
    agent.action_loop_tripped = false;
    defer agent.deinitTurnToolRecords();

    // Call 1
    _ = try agent.checkActionLoop("file_read", "{\"path\":\"a.txt\"}");
    try std.testing.expectEqual(@as(usize, 1), agent.consecutive_dup_tool_count);

    // Call 2: different command
    const res = try agent.checkActionLoop("file_read", "{\"path\":\"b.txt\"}");
    try std.testing.expectEqual(AgentLoop.LoopCheckResult.allow, res);
    try std.testing.expectEqual(@as(usize, 1), agent.consecutive_dup_tool_count);
    try std.testing.expect(!agent.action_loop_tripped);
}

test "agent - checkActionLoop windowed repetition detection" {
    const alloc = std.testing.allocator;
    var cfg: config_mod.Config = undefined;
    cfg.action_loop_consecutive_cap = 3;
    cfg.action_loop_window_cap = 4;
    cfg.action_loop_readonly_warn_cap = 5;
    cfg.action_loop_readonly_trip_cap = 10;
    cfg.action_loop_macro_cycle_cap = 2;
    cfg.action_loop_orbit_cap = 2;

    var agent: AgentLoop = undefined;
    agent.alloc = alloc;
    agent.config = &cfg;
    agent.turn_tool_records = .empty;
    agent.tool_cache = .empty;
    agent.turn_tool_trajectory = .empty;
    agent.consecutive_dup_tool_count = 0;
    agent.consecutive_readonly_count = 0;
    agent.last_loop_reason = .none;
    agent.action_loop_tripped = false;
    defer agent.deinitTurnToolRecords();

    // Alternating calls with same tool name ("bash"): A, B, A, B, A, B, A
    _ = try agent.checkActionLoop("bash", "{\"command\":\"cat SKILL.md\"}");
    _ = try agent.checkActionLoop("bash", "{\"command\":\"ls\"}");
    _ = try agent.checkActionLoop("bash", "{\"command\":\"cat SKILL.md\"}");
    _ = try agent.checkActionLoop("bash", "{\"command\":\"ls\"}");

    // A3 -> 3rd occurrence in sliding window -> warn!
    const res_a3 = try agent.checkActionLoop("bash", "{\"command\":\"cat SKILL.md\"}");
    try std.testing.expectEqual(AgentLoop.LoopCheckResult.warn, res_a3);

    // B3 -> 3rd occurrence in sliding window -> warn!
    const res_b3 = try agent.checkActionLoop("bash", "{\"command\":\"ls\"}");
    try std.testing.expectEqual(AgentLoop.LoopCheckResult.warn, res_b3);

    // A4 -> 4th occurrence in sliding window -> trip!
    const res_a4 = try agent.checkActionLoop("bash", "{\"command\":\"cat SKILL.md\"}");
    try std.testing.expectEqual(AgentLoop.LoopCheckResult.trip, res_a4);
    try std.testing.expect(agent.action_loop_tripped);
}

test "agent - checkActionLoop 2-cycle alternating tool names detection" {
    const alloc = std.testing.allocator;
    var cfg: config_mod.Config = undefined;
    cfg.action_loop_consecutive_cap = 5;
    cfg.action_loop_window_cap = 8;
    cfg.action_loop_readonly_warn_cap = 10;
    cfg.action_loop_readonly_trip_cap = 20;
    cfg.action_loop_macro_cycle_cap = 2;
    cfg.action_loop_orbit_cap = 4;

    var agent: AgentLoop = undefined;
    agent.alloc = alloc;
    agent.config = &cfg;
    agent.turn_tool_records = .empty;
    agent.tool_cache = .empty;
    agent.turn_tool_trajectory = .empty;
    agent.consecutive_dup_tool_count = 0;
    agent.consecutive_readonly_count = 0;
    agent.last_loop_reason = .none;
    agent.action_loop_tripped = false;
    defer agent.deinitTurnToolRecords();

    // Sequence: grep(q1) -> bash(c1) -> grep(q2) -> bash(c2)
    // Note: parameters are DIFFERENT so argument hashes never repeat!
    _ = try agent.checkActionLoop("grep", "{\"query\":\"fn foo\"}");
    _ = try agent.checkActionLoop("bash", "{\"command\":\"zig build test\"}");
    _ = try agent.checkActionLoop("grep", "{\"query\":\"fn bar\"}");

    // 4th step: 2 full cycles of [grep, bash] -> warn!
    const res4 = try agent.checkActionLoop("bash", "{\"command\":\"zig build run\"}");
    try std.testing.expectEqual(AgentLoop.LoopCheckResult.warn, res4);
    try std.testing.expectEqual(AgentLoop.LoopReason.macro_cycle_2, agent.last_loop_reason);
    try std.testing.expect(!agent.action_loop_tripped);

    // Cycle 3: grep(q3) -> bash(c3)
    _ = try agent.checkActionLoop("grep", "{\"query\":\"fn baz\"}");
    const res6 = try agent.checkActionLoop("bash", "{\"command\":\"zig build test\"}");
    // 3 full cycles of alternating tools -> trip!
    try std.testing.expectEqual(AgentLoop.LoopCheckResult.trip, res6);
    try std.testing.expectEqual(AgentLoop.LoopReason.macro_cycle_2, agent.last_loop_reason);
    try std.testing.expect(agent.action_loop_tripped);
}

test "agent - checkActionLoop 3-cycle macro sequence detection" {
    const alloc = std.testing.allocator;
    var cfg: config_mod.Config = undefined;
    cfg.action_loop_consecutive_cap = 5;
    cfg.action_loop_window_cap = 8;
    cfg.action_loop_readonly_warn_cap = 10;
    cfg.action_loop_readonly_trip_cap = 20;
    cfg.action_loop_macro_cycle_cap = 2;
    cfg.action_loop_orbit_cap = 4;

    var agent: AgentLoop = undefined;
    agent.alloc = alloc;
    agent.config = &cfg;
    agent.turn_tool_records = .empty;
    agent.tool_cache = .empty;
    agent.turn_tool_trajectory = .empty;
    agent.consecutive_dup_tool_count = 0;
    agent.consecutive_readonly_count = 0;
    agent.last_loop_reason = .none;
    agent.action_loop_tripped = false;
    defer agent.deinitTurnToolRecords();

    // Real-world scenario from session 63448:
    // Cycle 1: bash -> grep -> file_read
    _ = try agent.checkActionLoop("bash", "{\"command\":\"zig build test\"}");
    _ = try agent.checkActionLoop("grep", "{\"query\":\"TurnRenderer\"}");
    _ = try agent.checkActionLoop("file_read", "{\"path\":\"src/ui/chat_stream.zig\"}");

    // Cycle 2: bash -> grep -> file_read (distinct query & path arguments)
    _ = try agent.checkActionLoop("bash", "{\"command\":\"zig build test-unit\"}");
    _ = try agent.checkActionLoop("grep", "{\"query\":\"deduplication\"}");

    // 6th step: completes 2 full cycles of [bash, grep, file_read] -> warn!
    const res6 = try agent.checkActionLoop("file_read", "{\"path\":\"testcases/test_backend.zig\"}");
    try std.testing.expectEqual(AgentLoop.LoopCheckResult.warn, res6);
    try std.testing.expectEqual(AgentLoop.LoopReason.macro_cycle_3, agent.last_loop_reason);
    try std.testing.expect(!agent.action_loop_tripped);

    // Cycle 3: bash -> grep -> file_read
    _ = try agent.checkActionLoop("bash", "{\"command\":\"./test_run\"}");
    _ = try agent.checkActionLoop("grep", "{\"query\":\"assert\"}");
    const res9 = try agent.checkActionLoop("file_read", "{\"path\":\"src/main.zig\"}");
    // 3 full cycles -> trip circuit breaker!
    try std.testing.expectEqual(AgentLoop.LoopCheckResult.trip, res9);
    try std.testing.expectEqual(AgentLoop.LoopReason.macro_cycle_3, agent.last_loop_reason);
    try std.testing.expect(agent.action_loop_tripped);
}

test "agent - checkActionLoop read-only exploratory budget and mutation reset" {
    const alloc = std.testing.allocator;
    var cfg: config_mod.Config = undefined;
    cfg.action_loop_consecutive_cap = 5;
    cfg.action_loop_window_cap = 8;
    cfg.action_loop_readonly_warn_cap = 3;
    cfg.action_loop_readonly_trip_cap = 5;
    cfg.action_loop_macro_cycle_cap = 4;
    cfg.action_loop_orbit_cap = 4;

    var agent: AgentLoop = undefined;
    agent.alloc = alloc;
    agent.config = &cfg;
    agent.turn_tool_records = .empty;
    agent.tool_cache = .empty;
    agent.turn_tool_trajectory = .empty;
    agent.consecutive_dup_tool_count = 0;
    agent.consecutive_readonly_count = 0;
    agent.last_loop_reason = .none;
    agent.action_loop_tripped = false;
    defer agent.deinitTurnToolRecords();

    // Read 1: allow
    _ = try agent.checkActionLoop("file_read", "{\"path\":\"a.txt\"}");
    try std.testing.expectEqual(@as(usize, 1), agent.consecutive_readonly_count);

    // Read 2: allow
    _ = try agent.checkActionLoop("grep", "{\"query\":\"foo\"}");
    try std.testing.expectEqual(@as(usize, 2), agent.consecutive_readonly_count);

    // Read 3: hits readonly_warn_cap (3) -> warn!
    const res3 = try agent.checkActionLoop("glob", "{\"pattern\":\"*.zig\"}");
    try std.testing.expectEqual(AgentLoop.LoopCheckResult.warn, res3);
    try std.testing.expectEqual(AgentLoop.LoopReason.readonly_budget, agent.last_loop_reason);
    try std.testing.expectEqual(@as(usize, 3), agent.consecutive_readonly_count);
    try std.testing.expect(!agent.action_loop_tripped);

    // Mutating action: file_edit -> resets consecutive_readonly_count to 0!
    const res_edit = try agent.checkActionLoop("file_edit", "{\"path\":\"a.txt\"}");
    try std.testing.expectEqual(AgentLoop.LoopCheckResult.allow, res_edit);
    try std.testing.expectEqual(@as(usize, 0), agent.consecutive_readonly_count);

    // Read-only counter increments again
    _ = try agent.checkActionLoop("file_read", "{\"path\":\"b.txt\"}");
    _ = try agent.checkActionLoop("grep", "{\"query\":\"bar\"}");
    _ = try agent.checkActionLoop("glob", "{\"pattern\":\"*.zig\"}");
    _ = try agent.checkActionLoop("list_dir", "{\"path\":\"src\"}");
    // 5th read-only tool in a row -> hits readonly_warn_cap (3) -> warns, but does NOT trip circuit breaker
    const res_warn = try agent.checkActionLoop("session_diagnostics", "{}");
    try std.testing.expectEqual(AgentLoop.LoopCheckResult.warn, res_warn);
    try std.testing.expectEqual(AgentLoop.LoopReason.readonly_budget, agent.last_loop_reason);
    try std.testing.expect(!agent.action_loop_tripped);

    // Non-readonly action (e.g. bash test command) resets consecutive_readonly_count to 0!
    const res_bash = try agent.checkActionLoop("bash", "{\"command\":\"zig build test\"}");
    try std.testing.expectEqual(AgentLoop.LoopCheckResult.allow, res_bash);
    try std.testing.expectEqual(@as(usize, 0), agent.consecutive_readonly_count);
}

test "agent - checkActionLoop 3D procedural map orbit detection and checkpoint trip" {
    const alloc = std.testing.allocator;
    var cfg: config_mod.Config = undefined;
    cfg.action_loop_consecutive_cap = 10;
    cfg.action_loop_window_cap = 10;
    cfg.action_loop_readonly_warn_cap = 10;
    cfg.action_loop_readonly_trip_cap = 20;
    cfg.action_loop_macro_cycle_cap = 5;
    cfg.action_loop_orbit_cap = 2;

    var agent: AgentLoop = undefined;
    agent.alloc = alloc;
    agent.config = &cfg;
    agent.turn_tool_records = .empty;
    agent.tool_cache = .empty;
    agent.turn_tool_trajectory = .empty;
    agent.consecutive_dup_tool_count = 0;
    agent.consecutive_readonly_count = 0;
    agent.last_loop_reason = .none;
    agent.action_loop_tripped = false;
    defer agent.deinitTurnToolRecords();

    // Orbit 1: bash -> grep -> file_read
    _ = try agent.checkActionLoop("bash", "{\"command\":\"zig build test\"}");
    _ = try agent.checkActionLoop("grep", "{\"query\":\"foo\"}");
    _ = try agent.checkActionLoop("file_read", "{\"path\":\"a.zig\"}");

    // Orbit 1 closes: bash (matches bash 3 steps ago) -> orbit detected (rev 1) -> warn!
    const res_orbit1 = try agent.checkActionLoop("bash", "{\"command\":\"zig build test-unit\"}");
    try std.testing.expectEqual(AgentLoop.LoopCheckResult.warn, res_orbit1);
    try std.testing.expectEqual(AgentLoop.LoopReason.orbit_cycle, agent.last_loop_reason);
    try std.testing.expect(!agent.action_loop_tripped);

    // Orbit 2 continues: grep -> file_read
    _ = try agent.checkActionLoop("grep", "{\"query\":\"bar\"}");
    _ = try agent.checkActionLoop("file_read", "{\"path\":\"b.zig\"}");

    // Orbit 2 closes: bash -> revolutions = 2 reaches action_loop_orbit_cap (2) -> trip!
    const res_orbit2 = try agent.checkActionLoop("bash", "{\"command\":\"zig build test\"}");
    try std.testing.expectEqual(AgentLoop.LoopCheckResult.trip, res_orbit2);
    try std.testing.expectEqual(AgentLoop.LoopReason.orbit_cycle, agent.last_loop_reason);
    try std.testing.expect(agent.action_loop_tripped);
}

test "agent - action loop recovery via plan and execute" {
    const alloc = std.testing.allocator;
    var cfg: config_mod.Config = undefined;
    cfg.action_loop_consecutive_cap = 2;
    cfg.action_loop_window_cap = 10;
    cfg.action_loop_readonly_warn_cap = 10;
    cfg.action_loop_readonly_trip_cap = 20;
    cfg.action_loop_macro_cycle_cap = 5;
    cfg.action_loop_orbit_cap = 5;

    var agent: AgentLoop = undefined;
    agent.alloc = alloc;
    agent.config = &cfg;
    agent.turn_tool_records = .empty;
    agent.tool_cache = .empty;
    agent.turn_tool_trajectory = .empty;
    agent.consecutive_dup_tool_count = 0;
    agent.consecutive_readonly_count = 0;
    agent.last_loop_reason = .none;
    agent.action_loop_tripped = false;
    agent.plan = .{ .alloc = alloc };
    defer agent.deinitTurnToolRecords();

    // Call 1: first time
    _ = try agent.checkActionLoop("bash", "{\"command\":\"ls\"}");
    try std.testing.expectEqual(@as(usize, 0), agent.plan.loop_plan_retries);

    // Call 2: reaches cap -> trip
    const res = try agent.checkActionLoop("bash", "{\"command\":\"ls\"}");
    try std.testing.expectEqual(AgentLoop.LoopCheckResult.trip, res);
    try std.testing.expect(agent.action_loop_tripped);

    // Simulate recovery logic in executeTools:
    // First trip: request plan & execution instead of halting
    if (agent.plan.loop_plan_retries < 2) {
        agent.plan.loop_plan_retries += 1;
        agent.plan.plan_execution_pending = true;
        agent.action_loop_tripped = false; // Turn continues!
        agent.consecutive_dup_tool_count = 0;
    }
    try std.testing.expectEqual(@as(usize, 1), agent.plan.loop_plan_retries);
    try std.testing.expect(agent.plan.plan_execution_pending);
    try std.testing.expect(!agent.action_loop_tripped);

    // Model executes mutation tool (file_edit) -> recovery succeeds!
    agent.plan.loop_plan_retries = 0;
    agent.plan.plan_execution_pending = false;
    try std.testing.expectEqual(@as(usize, 0), agent.plan.loop_plan_retries);
    try std.testing.expect(!agent.plan.plan_execution_pending);
}

test "agent - plan watchdog enforcement and procrastination intercept" {
    const alloc = std.testing.allocator;
    var cfg: config_mod.Config = undefined;
    cfg.action_loop_consecutive_cap = 5;
    cfg.action_loop_window_cap = 8;
    cfg.action_loop_readonly_warn_cap = 5;
    cfg.action_loop_readonly_trip_cap = 10;
    cfg.action_loop_macro_cycle_cap = 4;
    cfg.action_loop_orbit_cap = 4;

    var agent: AgentLoop = undefined;
    agent.alloc = alloc;
    agent.config = &cfg;
    agent.turn_tool_records = .empty;
    agent.tool_cache = .empty;
    agent.turn_tool_trajectory = .empty;
    agent.consecutive_dup_tool_count = 0;
    agent.consecutive_readonly_count = 0;
    agent.last_loop_reason = .none;
    agent.action_loop_tripped = false;
    agent.plan = .{ .alloc = alloc, .enable_structured_planning = false };
    agent.current_user_request = null;
    defer agent.deinitTurnToolRecords();

    // 1. Detect plan in Vietnamese text
    const vn_plan = plan_integration.PlanState.detectPlanInText("Đúng rồi, tôi sẽ implement fix cho bug này bằng cách thêm guard.");
    try std.testing.expect(vn_plan != null);
    agent.plan.setPlan(vn_plan.?);
    try std.testing.expect(agent.plan.plan_active);
    try std.testing.expectEqual(@as(usize, 0), agent.plan.plan_procrastination_count);

    // 2. Exploratory tool call detection
    try std.testing.expect(AgentLoop.isExploratoryToolCall("file_read", "{\"path\":\"src/core/agent.zig\"}"));
    try std.testing.expect(AgentLoop.isExploratoryToolCall("grep", "{\"query\":\"plan\"}"));
    try std.testing.expect(AgentLoop.isExploratoryToolCall("bash", "{\"command\":\"cat src/core/agent.zig\"}"));
    try std.testing.expect(AgentLoop.isExploratoryToolCall("bash", "{\"command\":\"sed -n '1,10p' file\"}"));
    try std.testing.expect(!AgentLoop.isExploratoryToolCall("bash", "{\"command\":\"sed -i 's/a/b/g' file\"}"));
    try std.testing.expect(!AgentLoop.isExploratoryToolCall("bash", "{\"command\":\"zig build test\"}"));
    try std.testing.expect(!AgentLoop.isExploratoryToolCall("file_edit", "{\"path\":\"a.zig\"}"));

    // 3. Procrastination counter increments on exploratory calls
    agent.plan.plan_procrastination_count += 1;
    try std.testing.expectEqual(@as(usize, 1), agent.plan.plan_procrastination_count);
    try std.testing.expect(agent.plan.plan_procrastination_count < agent.plan.plan_procrastination_cap);

    // 4. At cap, procrastination trips watchdog intercept
    agent.plan.plan_procrastination_count += 1;
    try std.testing.expectEqual(@as(usize, 2), agent.plan.plan_procrastination_count);
    try std.testing.expect(agent.plan.plan_procrastination_count >= agent.plan.plan_procrastination_cap);

    // 5. Executing mutating tool clears plan
    agent.plan.clearPlan();
    try std.testing.expect(!agent.plan.plan_active);
    try std.testing.expectEqual(@as(usize, 0), agent.plan.plan_procrastination_count);

    // 6. Test isPlanOnlyRequest
    try std.testing.expect(plan_integration.PlanState.isPlanOnlyRequest("Lập kế hoạch, không sửa file"));
    try std.testing.expect(plan_integration.PlanState.isPlanOnlyRequest("please provide plan only"));
    try std.testing.expect(!plan_integration.PlanState.isPlanOnlyRequest("hãy sửa bug này và chạy test"));
}

test "agent - parseTimeoutDecision" {
    // 1. Explicit WAIT with seconds and reason
    const text1 =
        \\DECISION: WAIT 120
        \\REASON: Long compilation of Zig packages in progress.
    ;
    const d1 = parseTimeoutDecision(text1);
    try std.testing.expect(!d1.should_kill);
    try std.testing.expectEqual(@as(u32, 120), d1.extend_seconds);
    try std.testing.expectEqualStrings("Long compilation of Zig packages in progress.", d1.reason());

    // 2. Simple WAIT without explicit seconds (defaults to 60)
    const text2 =
        \\WAIT
        \\REASON: npm install downloading tarballs.
    ;
    const d2 = parseTimeoutDecision(text2);
    try std.testing.expect(!d2.should_kill);
    try std.testing.expectEqual(@as(u32, 60), d2.extend_seconds);
    try std.testing.expectEqualStrings("npm install downloading tarballs.", d2.reason());

    // 3. Explicit KILL
    const text3 =
        \\DECISION: KILL
        \\REASON: Process is hung waiting on stdin.
    ;
    const d3 = parseTimeoutDecision(text3);
    try std.testing.expect(d3.should_kill);
    try std.testing.expectEqualStrings("Process is hung waiting on stdin.", d3.reason());

    // 4. Markdown formatted decision
    const text4 =
        \\**DECISION**: `KILL`
        \\**REASON**: Deadlock detected in worker process.
    ;
    const d4 = parseTimeoutDecision(text4);
    try std.testing.expect(d4.should_kill);
    try std.testing.expect(std.mem.indexOf(u8, d4.reason(), "Deadlock detected") != null);
}



