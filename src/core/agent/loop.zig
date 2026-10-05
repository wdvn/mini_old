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
const proto = @import("../protocol.zig");
const config_mod = @import("../config.zig");
const history_mod = @import("../history.zig");
const tools_mod = @import("../../tooling/registry.zig");
const plan_dispatch = @import("../plan/dispatch.zig");
const media_gen_tool = @import("../../tools/media_gen.zig");
const json_mod = @import("../json.zig");
const openai_mod = @import("../../backends/openai.zig");
const claude_mod = @import("../../backends/claude.zig");
const ollama_mod = @import("../../backends/ollama.zig");
const hooks_mod = @import("../hooks.zig");
const main = @import("../../main.zig");
const utils = @import("../utils.zig");
const quickjs = @import("../../runtime/quickjs_engine.zig");
const js_bindings = @import("../../runtime/js_bindings.zig");
const process_manager = @import("../../runtime/process_manager.zig");
const tokens_mod = @import("../memact/tokens.zig");
const graph_store_mod = @import("../memact/graph_store.zig");
const store_mod = @import("../memact/store.zig");
const bm25_mod = @import("../memact/bm25.zig");
const snapshot_mod = @import("../snapshot.zig");
const cas_mod = @import("../cas.zig");
const prompts_mod = @import("../prompts.zig");
const plan_parser = @import("../plan/parser.zig");
const plan_executor = @import("../plan/executor.zig");
const plan_monitor = @import("../plan/monitor.zig");
const plan_mod = @import("../plan.zig");
const plan_store_mod = @import("../plan/store.zig");
const plan_integration = @import("../plan/integration.zig");
pub const journal_mod = @import("../journal.zig");
pub const act_logger_mod = @import("../act_logger.zig");
pub const signals = @import("../signals.zig");
pub const act_queue = @import("../act_queue.zig");
pub const watchdog_mod = @import("../watchdog.zig");
const chat_stream = @import("../../ui/chat_stream.zig");
const term = @import("../../ui/terminal.zig");
const spinner_mod = @import("../../ui/spinner.zig");

/// Mutex protecting g_active_agent.
pub var g_agent_mutex = std.atomic.Mutex.unlocked;

var g_active_agent: ?*AgentLoop = null;

/// RFC-024 §3.3: extract a skill name from a `.../skills/<name>/SKILL.md`
/// path, or null if the path does not look like a skill file.
pub fn skillNameFromSkillPath(path: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, path, "SKILL.md")) return null;
    // .../skills/<name>/SKILL.md -> strip trailing "SKILL.md", parent dir = skill name
    const base = path[0 .. path.len - "SKILL.md".len];
    const trimmed = std.mem.trim(u8, base, "/");
    if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |slash| {
        return trimmed[slash + 1 ..];
    }
    return null;
}

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
    tools_mod.interruptActiveMcp();
}

fn watchdogForceKillHandler() void {
    // PSEUDOCODE:
    // 1. Interrupt the active CodeAct engine.
    // 2. Force-kill bash, MCP, and every managed background process group.
    while (!g_agent_mutex.tryLock()) {}
    const agent = g_active_agent;
    g_agent_mutex.unlock();
    if (agent) |a| {
        a.engine.requestInterrupt();
    }
    tools_mod.forceKillActiveBash();
    tools_mod.forceKillActiveMcp();
    _ = process_manager.killAllTrackedProcesses(9);
    _ = process_manager.forceKillAllJobs("SIGKILL");
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

const agent_backend = @import("backend.zig");
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
    stop_sequence_continues: usize = 0,
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
    /// Semantic/Episodic Memory Store (RFC-003).
    memory_store: ?*store_mod.MemoryStore = null,
    /// RFC-025 Phase 2: cached LLM query expansion per distinct user request.
    memact_expansion_cache: ?[]u8 = null,
    memact_expansion_cache_key: ?[]u8 = null,
    /// Last executed tool name (RFC-010 active node anchor).
    last_executed_tool: ?[]u8 = null,
    /// Recent tool execution sequence (w acts window).
    recent_tools: std.ArrayListUnmanaged([]u8) = .empty,
    /// RFC-024 §3.3: skill names read into the conversation this session
    /// (for post-compaction re-injection; name only, deduplicated).
    read_skills: std.ArrayListUnmanaged([]u8) = .empty,
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
    /// Stop reason from the most recent LLM response (for journal debugging).
    last_stop_reason: ?[]const u8 = null,
    /// Track whether the most recent LLM response had no meaningful content (empty/whitespace only).
    /// RFC-023 response state for the current turn.
    last_generation_stop: proto.GenerationStop = .missing_terminal_event,
    last_response_validity: proto.ResponseValidity = .empty,
    last_agent_decision: proto.AgentDecision = .request_continuation,
    last_step_outcome: proto.StepOutcome = .final_answer,
    response_recovery_budget: proto.ResponseRecoveryBudget = .{},
    turn_recovery_attempts: usize = 0,
    last_agent_message: ?[]const u8 = null,
    last_turn_outcome: proto.TurnOutcome = .completed,
    current_act_attempt: usize = 1,
    /// History length at the start of the active Act (before any retry attempt).
    act_history_checkpoint: usize = 0,
    last_recovery_class: ?proto.RecoveryClass = null,
    last_failure_reason: ?proto.FailureReason = null,

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

    /// Initializes backend based on configuration priority order and applies reasoning effort.
    fn initBackend(alloc: Allocator, config: *const config_mod.Config) Backend {
        // PSEUDOCODE:
        // 1. Select backend: OpenAI-compat > Claude > Ollama fallback
        // 2. Apply reasoning effort and thinking budget if enabled
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
                break :blk .{ .claude = claude_mod.Client.init(alloc, key, config.claude_model, config.max_tokens) };
            }
            if (!utils.isSubagent()) main.stderrPrint("[agent] Backend: Ollama @ {s} ({s})\n", .{ config.ollama_url, config.ollama_model });
            break :blk .{ .ollama = ollama_mod.Client.init(alloc, config.ollama_url, config.ollama_model, config.max_tokens) };
        };

        if (!config.reasoning_effort_disabled) {
            backend.setReasoningEffort(config.reasoning_effort);
            backend.setThinkingBudget(config.thinking_budget_tokens);
        }
        return backend;
    }

    /// Configures tool execution policy and media generation subsystem.
    fn initMediaAndTools(config: *const config_mod.Config) void {
        // PSEUDOCODE: Set tool policies and media generation options
        tools_mod.setPolicy(config.tool_allowlist, config.tool_blocklist);
        tools_mod.setMediaConfig(config.image_gen_enabled, config.video_gen_enabled, config.image_input_enabled);
        tools_mod.setDeferredToolsEnabled(config.deferred_tool_loading);
        media_gen_tool.setConfig(.{
            .image = .{
                .enabled = config.image_gen_enabled,
                .provider = config.image_gen_provider,
                .model = config.image_gen_model,
                .size = config.image_gen_size,
                .url = config.image_gen_url,
                .key = config.image_gen_key,
                .api_header = config.image_gen_api_header,
            },
            .video = .{
                .enabled = config.video_gen_enabled,
                .provider = config.video_gen_provider,
                .model = config.video_gen_model,
                .url = config.video_gen_url,
                .key = config.video_gen_key,
                .api_header = config.video_gen_api_header,
            },
            .media_output_dir = config.media_output_dir,
            .image_input_max_bytes = config.image_input_max_bytes,
            .image_input_max_per_turn = config.image_input_max_per_turn,
        });
    }

    /// Initializes procedural graph store if enabled for the active project.
    fn initPGraphStore(alloc: Allocator, io: std.Io, config: *const config_mod.Config, home_dir: []const u8) ?*graph_store_mod.PGraphStore {
        // PSEUDOCODE: Hash cwd, resolve memory path, allocate and initialize PGraphStore
        if (!config.memact_pg_enabled) return null;
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cur_cwd = if (std.c.getcwd(&cwd_buf, cwd_buf.len)) |ptr| std.mem.sliceTo(ptr, 0) else ".";
        const prj_hash = std.hash.Fnv1a_64.hash(cur_cwd);

        var mem_path_buf: [512]u8 = undefined;
        const mem_base = config.memory_dir orelse (utils.getEnvSlice("MINI_HOME") orelse (std.fmt.bufPrint(&mem_path_buf, "{s}/.mini/memory", .{home_dir}) catch ".mini/memory"));
        const prj_mem_dir = std.fmt.allocPrint(alloc, "{s}/{x}", .{ mem_base, prj_hash }) catch return null;
        defer alloc.free(prj_mem_dir);

        const store = alloc.create(graph_store_mod.PGraphStore) catch return null;
        if (graph_store_mod.PGraphStore.init(alloc, io, prj_mem_dir)) |val| {
            store.* = val;
            store.auto_populate = config.memact_pg_auto_populate;
            store.loadIndex(io) catch |e| {
                main.stderrPrint("[agent] Warning: Failed to load PGraph index: {s}\n", .{@errorName(e)});
            };
            return store;
        } else |e| {
            main.stderrPrint("[agent] Warning: Failed to init PGraphStore: {s}\n", .{@errorName(e)});
            alloc.destroy(store);
            return null;
        }
    }

    /// Initializes semantic/episodic memory store for the active project (RFC-003).
    fn initMemoryStore(alloc: Allocator, io: std.Io, config: *const config_mod.Config, home_dir: []const u8) ?*store_mod.MemoryStore {
        // PSEUDOCODE: Hash cwd, resolve memory path, allocate and initialize MemoryStore
        if (!config.memact_enabled) return null;
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cur_cwd = if (std.c.getcwd(&cwd_buf, cwd_buf.len)) |ptr| std.mem.sliceTo(ptr, 0) else ".";
        const prj_hash = std.hash.Fnv1a_64.hash(cur_cwd);

        var mem_path_buf: [512]u8 = undefined;
        const mem_base = config.memory_dir orelse (utils.getEnvSlice("MINI_HOME") orelse (std.fmt.bufPrint(&mem_path_buf, "{s}/.mini/memory", .{home_dir}) catch ".mini/memory"));
        const prj_mem_dir = std.fmt.allocPrint(alloc, "{s}/{x}", .{ mem_base, prj_hash }) catch return null;
        defer alloc.free(prj_mem_dir);

        const store = alloc.create(store_mod.MemoryStore) catch return null;
        if (store_mod.MemoryStore.init(alloc, io, prj_mem_dir)) |val| {
            store.* = val;
            // Load index eagerly to fail fast; entries are re-loaded on demand
            // in injectSemanticMemory — free them here to avoid leaking.
            if (store.loadIndex(io)) |entries| {
                store_mod.MemoryStore.freeEntries(alloc, entries);
            } else |e| {
                main.stderrPrint("[agent] Warning: Failed to load Memory index: {s}\n", .{@errorName(e)});
            }
            return store;
        } else |e| {
            main.stderrPrint("[agent] Warning: Failed to init MemoryStore: {s}\n", .{@errorName(e)});
            alloc.destroy(store);
            return null;
        }
    }

    /// Initializes and starts Watchdog background monitoring thread.
    fn watchdogNoticeSink(io: std.Io, msg: []const u8) void {
    // PSEUDOCODE: Route terminal notices through the terminal writer queue
    // (term.writeStdout enqueues a single FIFO item) so watchdog lines from the
    // watchdog thread can never interleave the renderer's in-place sections.
    _ = io;
    term.writeStdout(msg);
}

fn initWatchdog(alloc: Allocator, io: std.Io, coordinator: *act_queue.ActCoordinator, config: *const config_mod.Config) ?*watchdog_mod.Watchdog {
        // PSEUDOCODE: Create watchdog with signal handlers and start thread
        const watchdog = watchdog_mod.Watchdog.init(alloc, io, coordinator, .{
            .tracking_interval_s = config.watchdog_tracking_interval_s,
            .act_timeout_secs = config.act_timeout_secs,
            .recap_interval_acts = config.watchdog_recap_interval,
            .poll_interval_ms = config.watchdog_interval_ms,
            .verbose_stderr = config.action_loop_display,
            .prompt_enforcement_enabled = config.prompt_enforcement_enabled,
        });
        watchdog.interrupt_fn = &watchdogInterruptHandler;
        watchdog.force_kill_fn = &watchdogForceKillHandler;
        watchdog.decision_fn = &watchdogDecisionHandler;
        // TTY only: ACP pipe / subagent / test stdout must keep the stderr path.
        if (term.isStdoutTty()) {
            watchdog.notice_fn = &watchdogNoticeSink;
        }
        watchdog.start() catch |e| {
            if (!utils.isSubagent()) main.stderrPrint("[agent] Warning: Failed to start Watchdog thread: {s}\n", .{@errorName(e)});
        };
        return watchdog;
    }

    /// Initializes AgentLoop from config.
    /// Selects backend based on config priority order.
    pub fn init(alloc: Allocator, io: std.Io, config: *const config_mod.Config) !AgentLoop {
        // PSEUDOCODE:
        // 1. Initialize CodeAct engine and backend
        // 2. Configure tool policy, CAS, act logger, PGraph, coordinator, and watchdog
        // 3. Assemble and return AgentLoop
        const engine = try quickjs.Engine.init(alloc, io);
        errdefer engine.deinit();

        const backend = initBackend(alloc, config);
        initMediaAndTools(config);

        var path_buf: [256]u8 = undefined;
        const home_dir = utils.getEnvSlice("HOME") orelse ".";
        const cas_path = try std.fmt.bufPrint(&path_buf, "{s}/.mini/cas", .{home_dir});
        var cas = try cas_mod.CAS.init(alloc, io, cas_path);

        var acts_buf: [256]u8 = undefined;
        const acts_path = std.fmt.bufPrint(&acts_buf, "{s}/.mini/acts", .{home_dir}) catch "/tmp/mini_acts";
        const act_logger = act_logger_mod.ActLogger.init(alloc, io, acts_path) catch null;
        const pg_store_ptr = initPGraphStore(alloc, io, config, home_dir);
        const memory_store_ptr = initMemoryStore(alloc, io, config, home_dir);
        const coordinator = act_queue.ActCoordinator.init(alloc);
        const watchdog = initWatchdog(alloc, io, coordinator, config);
        const cas_ptr: *cas_mod.CAS = &cas;

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
            .memory_store = memory_store_ptr,
            .last_executed_tool = null,
            .recent_tools = .empty,
            .read_skills = .empty,
            .coordinator = coordinator,
            .watchdog = watchdog,
            .last_generation_stop = .missing_terminal_event,
            .last_response_validity = .empty,
            .last_agent_decision = .request_continuation,
            .last_step_outcome = .final_answer,
            .response_recovery_budget = .{},
            .turn_recovery_attempts = 0,
            .last_agent_message = null,
            .last_turn_outcome = .completed,
            .current_act_attempt = 1,
            .last_recovery_class = null,
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
        if (self.memory_store) |ms| {
            ms.deinit();
            self.alloc.destroy(ms);
            self.memory_store = null;
        }
        if (self.last_executed_tool) |t| {
            self.alloc.free(t);
            self.last_executed_tool = null;
        }
        if (self.memact_expansion_cache) |c| self.alloc.free(c);
        if (self.memact_expansion_cache_key) |k| self.alloc.free(k);
        for (self.recent_tools.items) |t| {
            self.alloc.free(t);
        }
        self.recent_tools.deinit(self.alloc);
        // PSEUDOCODE:
        // 1. Free each skill name slice tracked during this session
        // 2. Deinitialize the read_skills unmanaged list
        for (self.read_skills.items) |s| {
            self.alloc.free(s);
        }
        self.read_skills.deinit(self.alloc);
        self.deinitTurnToolRecords();
        if (self.last_agent_message) |msg| {
            self.alloc.free(msg);
            self.last_agent_message = null;
        }
        if (self.last_stop_reason) |sr| {
            self.alloc.free(sr);
            self.last_stop_reason = null;
        }
        self.plan.deinit();
    }

    const agent_loop_monitor = @import("loop_monitor.zig");
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
    pub const lookupToolCache = agent_loop_monitor.lookupToolCache;
    pub const storeToolCache = agent_loop_monitor.storeToolCache;
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
            self.last_backend_raw_error = self.alloc.dupe(
                u8,
                proto.boundedResponseSnippet(r),
            ) catch null;
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

    const agent_step = @import("step.zig");
    pub const StepResult = agent_step.StepResult;
    pub const executeStep = agent_step.executeStep;

    const agent_turn = @import("turn.zig");
    pub const executeTurnWorker = agent_turn.executeTurnWorker;

    const ResponseBlocksSummary = struct {
        text: ?[]const u8 = null,
        thinking: ?[]const u8 = null,
    };

    fn collectResponseBlocks(
        alloc: Allocator,
        content: []const proto.ContentBlock,
        tool_calls: *std.ArrayListUnmanaged(proto.ToolUse),
    ) ResponseBlocksSummary {
        var summary = ResponseBlocksSummary{};
        for (content) |block| {
            switch (block) {
                .text => |t| summary.text = t,
                .thinking => |th| summary.thinking = th.thinking,
                .tool_use => |tu| tool_calls.append(alloc, tu) catch {},
                else => {},
            }
        }
        return summary;
    }

    fn collectSnapshots(
        alloc: Allocator,
        tracker: ?snapshot_mod.SnapshotTracker,
        list: *std.ArrayListUnmanaged(act_logger_mod.ActSnapshotInfo),
    ) void {
        const t = tracker orelse return;
        for (t.tracked.items) |tf| {
            list.append(alloc, .{
                .path = tf.path,
                .previous_content_hash = tf.previous_content_hash,
            }) catch {};
        }
    }

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

        var tool_calls_list = std.ArrayListUnmanaged(proto.ToolUse).empty;
        defer tool_calls_list.deinit(self.alloc);
        const summary = collectResponseBlocks(self.alloc, response.content.items, &tool_calls_list);

        var snapshots_list = std.ArrayListUnmanaged(act_logger_mod.ActSnapshotInfo).empty;
        defer snapshots_list.deinit(self.alloc);
        collectSnapshots(self.alloc, self.snapshot_tracker, &snapshots_list);

        const normalized_stop = @tagName(response.getGenerationStop());
        if (self.last_stop_reason) |old| self.alloc.free(old);
        self.last_stop_reason = self.alloc.dupe(u8, normalized_stop) catch null;
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
                .stop_reason = normalized_stop,
                .generation_stop = @tagName(self.last_generation_stop),
                .response_validity = @tagName(self.last_response_validity),
                .agent_decision = @tagName(self.last_agent_decision),
                .recovery_class = if (self.last_recovery_class) |class| @tagName(class) else null,
                .attempt = self.current_act_attempt,
                .text = summary.text,
                .thinking = summary.thinking,
                .js_code = js_code_opt,
                .tool_calls = if (tool_calls_list.items.len > 0) tool_calls_list.items else null,
                .usage = response.usage,
                .raw_debug_info = response.raw_debug_info,
            },
            .execution = exec_info,
            .snapshots = snapshots_list.items,
        }) catch {};
    }

    /// RFC-024 §3.5: approve the current plan and journal the phase change
    /// (REPL `/plan approve` path).
    pub fn approvePlan(self: *AgentLoop) bool {
        const ok = self.plan.approve();
        if (ok) {
            if (self.journal) |*j| {
                j.recordEvent(self.io, 0, .plan_phase_changed, "user approved plan (proposed/approved -> executing)") catch {};
            }
        }
        return ok;
    }

    /// RFC-024 §3.5: reject the current plan and journal the phase change
    /// (REPL `/plan reject` path).
    pub fn rejectPlan(self: *AgentLoop) bool {
        const ok = self.plan.reject();
        if (ok) {
            if (self.journal) |*j| {
                j.recordEvent(self.io, 0, .plan_phase_changed, "user rejected plan (-> rejected)") catch {};
            }
        }
        return ok;
    }

    const agent_subagent = @import("subagent.zig");
    pub const maybeBatchPlanStep = agent_subagent.maybeBatchPlanStep;
    pub const maybeDispatchPlanStep = agent_subagent.maybeDispatchPlanStep;

/// RFC-024 §3.3: record that a skill's content was read this session so the
/// post-compaction reinject block can restate it. `skills` (operation=detail)
/// and `file_read` of a SKILL.md path are the two signals.
fn recordSkillLoaded(self: *AgentLoop, tool_name: []const u8, input_json: ?[]const u8) void {
        if (std.mem.eql(u8, tool_name, "skills")) {
            const op = json_mod.findString(input_json orelse "", "operation") orelse return;
            if (!std.mem.eql(u8, op, "detail")) return;
            if (json_mod.findString(input_json orelse "", "name")) |skill_name| {
                self.trackSkillName(skill_name);
            }
        } else if (std.mem.eql(u8, tool_name, "file_read") or std.mem.eql(u8, tool_name, "read_file")) {
            const path = json_mod.findString(input_json orelse "", "path") orelse return;
            if (skillNameFromSkillPath(path)) |skill_name| {
                self.trackSkillName(skill_name);
            }
        }
    }

    /// Deduplicate + append a skill name to read_skills.
    fn trackSkillName(self: *AgentLoop, name: []const u8) void {
        for (self.read_skills.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return;
        }
        if (self.alloc.dupe(u8, name)) |owned| {
            self.read_skills.append(self.alloc, owned) catch self.alloc.free(owned);
        } else |_| {}
        // RFC-024 §3.5: telemetry — a skill was read into the conversation.
        if (self.journal) |*j| {
            j.recordEvent(self.io, 0, .skill_loaded, name) catch {};
        }
    }

    pub fn onToolCompleted(self: *AgentLoop, tool_name: []const u8, input_json: ?[]const u8, is_error: bool) void {
        if (self.pg_store) |pg| {
            if (self.last_executed_tool) |prev_tool| {
                pg.recordTransition(self.io, prev_tool, tool_name) catch {};
            }
        }
        self.recordSkillLoaded(tool_name, input_json);

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
    ) !proto.TurnResult {
        return self.processInputWithImages(user_text, &.{}, text_cb, think_cb);
    }

    const TurnWorkerContext = struct {
        agent: *AgentLoop,
        user_text: []const u8,
        images: []const proto.ImageBlock,
        text_cb: ?*const fn ([]const u8) void,
        think_cb: ?*const fn ([]const u8) void,
        result: anyerror!proto.TurnResult = error.Unexpected,
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
    ) !proto.TurnResult {
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
        // PSEUDOCODE:
        // 1. Clear history messages
        // 2. Free and clear tracked skill names from previous conversation
        self.history.clear();
        for (self.read_skills.items) |s| {
            self.alloc.free(s);
        }
        self.read_skills.clearRetainingCapacity();
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

    fn handleBackendSendError(self: *AgentLoop, act_id: usize, e: anyerror) anyerror {
        if (e == error.Interrupted or signals.isInterrupted()) {
            return error.Interrupted;
        }
        if (main.ui_repl.current_renderer) |r| {
            r.stopWaiting();
            if (r.is_thinking) r.endThinking();
            r.ensureNewline();
        }
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
                .attempt = self.current_act_attempt,
                .raw_snippet = self.last_backend_raw_error,
            }) catch {};
        }
        return e;
    }

    /// RFC-025 Phase 2: LLM query expansion (Path B). Stateless keyword
    /// expansion of the retrieval query; returns null when expansion fails or
    /// yields nothing (graceful degrade — Path A stands alone). Results are
    /// cached per user request in `memact_expansion_cache`.
    fn expandMemActQuery(self: *AgentLoop, alloc: Allocator, query: []const u8) !?[]u8 {
        // PSEUDOCODE:
        // 1. Serve the cache when the query is unchanged.
        // 2. Build a stateless expansion request (user message only).
        // 3. Call backend directly (bypass sendToBackend -> avoids recursion
        //    into injectSemanticMemory).
        // 4. Parse at most 12 keyword lines; store in cache; return text.
        if (self.memact_expansion_cache) |cached| {
            if (self.memact_expansion_cache_key) |key| {
                if (std.mem.eql(u8, key, query)) return cached;
            }
        }

        const expansion_system_prompt = prompts_mod.memact_expansion_system_prompt;

        var msg_blocks = try alloc.alloc(proto.ContentBlock, 1);
        errdefer {
            alloc.free(msg_blocks[0].text);
            alloc.free(msg_blocks);
        }
        msg_blocks[0] = .{ .text = try alloc.dupe(u8, query) };
        const user_msg = proto.Message{ .role = .user, .content = msg_blocks };

        var resp = self.backend.send(expansion_system_prompt, &.{ user_msg }, &[_]proto.ToolDefinition{}, null, null) catch {
            // Graceful degrade: Path A results stand alone.
            alloc.free(msg_blocks[0].text);
            alloc.free(msg_blocks);
            return null;
        };
        defer resp.deinit();
        alloc.free(msg_blocks[0].text);
        alloc.free(msg_blocks);

        // Collect response text blocks.
        var response_text = ArrayList(u8).empty;
        defer response_text.deinit(alloc);
        for (resp.content.items) |block| {
            if (block == .text) try response_text.appendSlice(alloc, block.text);
        }

        // Keep at most 12 keyword lines (latency/cost cap, RFC-025 §4).
        var keyword_buf = ArrayList(u8).empty;
        defer keyword_buf.deinit(alloc);
        var line_count: u32 = 0;
        var it = std.mem.splitScalar(u8, response_text.items, '\n');
        while (it.next()) |line| {
            if (line_count >= 12) break;
            line_count += 1;
            const keyword = std.mem.trim(u8, line, " \t\r-");
            if (keyword.len == 0) continue;
            if (keyword_buf.items.len > 0) try keyword_buf.append(alloc, ' ');
            try keyword_buf.appendSlice(alloc, keyword);
        }

        const keywords_text = try keyword_buf.toOwnedSlice(alloc);
        if (keywords_text.len == 0) {
            alloc.free(keywords_text);
            return null;
        }

        // Update cache (replacing any stale entry).
        if (self.memact_expansion_cache) |old| alloc.free(old);
        self.memact_expansion_cache = keywords_text;
        if (self.memact_expansion_cache_key) |old_key| alloc.free(old_key);
        self.memact_expansion_cache_key = try alloc.dupe(u8, query);

        return keywords_text;
    }

    /// RFC-025 Phase 3: end-of-turn LLM extraction of durable facts/lessons
    /// into the declarative store (`semantic` / `project_state` records with
    /// meaningful self-reported confidence, optional `related_tool` mapped to
    /// a procedural-graph `node_ref`). Wired from `executeTurnWorker` when
    /// `memact_extract != "off"`. No-op on failure (extraction must never
    /// break the turn outcome).
    pub fn maybeExtractMemories(self: *AgentLoop) !void {
        // PSEUDOCODE:
        // 1. Guards: memory store present, memact enabled, extract mode not "off",
        //    completed/stalled outcome only (failed turns produce no lessons).
        // 2. Build extraction request: user request + recent tools + final message.
        // 3. Parse JSON array of {content, keywords, type, confidence, related_tool}.
        // 4. Append eligible records to the store (cap 5, content >= 20 chars).
        if (self.memory_store == null) return;
        if (!self.config.memact_enabled) return;
        if (std.mem.eql(u8, self.config.memact_extract, "off")) return;
        if (self.last_turn_outcome != .completed and self.last_turn_outcome != .stalled) return;

        var prompt = ArrayList(u8).empty;
        defer prompt.deinit(self.alloc);
        try prompt.appendSlice(self.alloc, prompts_mod.memact_extraction_user_prompt_head);
        if (self.current_user_request) |req| try prompt.appendSlice(self.alloc, req);
        try prompt.appendSlice(self.alloc, "\n\nTools executed:\n");
        for (self.recent_tools.items) |t| {
            try prompt.appendSlice(self.alloc, "- ");
            try prompt.appendSlice(self.alloc, t);
            try prompt.appendSlice(self.alloc, "\n");
        }
        if (self.last_agent_message) |msg| {
            try prompt.appendSlice(self.alloc, "\nFinal response (tail):\n");
            const tail = if (msg.len > 400) msg[msg.len - 400 ..] else msg;
            try prompt.appendSlice(self.alloc, tail);
        }
        const request_text = prompt.toOwnedSlice(self.alloc) catch return;

        const extraction_system_prompt = prompts_mod.memact_extraction_system_prompt;

        var msg_blocks = try self.alloc.alloc(proto.ContentBlock, 1);
        msg_blocks[0] = .{ .text = request_text };
        const user_msg = proto.Message{ .role = .user, .content = msg_blocks };

        // PSEUDOCODE:
        // 1. Attempt backend send; on error, free both prompt buffers and
        //    gracefully bail out (extraction must never break the turn).
        //    NOTE: `catch return` swallows the error, so an errdefer would
        //    not fire here — the failure path must free manually.
        // 2. On success, free the buffers explicitly after resp is owned
        //    by `defer resp.deinit()`.
        var resp = self.backend.send(extraction_system_prompt, &.{ user_msg }, &[_]proto.ToolDefinition{}, null, null) catch {
            self.alloc.free(msg_blocks[0].text);
            self.alloc.free(msg_blocks);
            return;
        };
        defer resp.deinit();
        self.alloc.free(msg_blocks);
        self.alloc.free(request_text);

        // Collect response text.
        var response_text = ArrayList(u8).empty;
        defer response_text.deinit(self.alloc);
        for (resp.content.items) |block| {
            if (block == .text) response_text.appendSlice(self.alloc, block.text) catch return;
        }

        // Parse the JSON array (tolerate a leading/trailing fence line).
        const json_text = std.mem.trim(u8, response_text.items, " \t\r\n`");
        const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, json_text, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        const arr = switch (parsed.value) {
            .array => |a| a.items,
            else => return,
        };

        var extracted: u32 = 0;
        for (arr) |item| {
            if (extracted >= 5) break;
            const obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const content = switch (obj.get("content") orelse .null) {
                .string => |s| s,
                else => continue,
            };
            // Injection filter (RFC-025 §3.2 rule 3): reject tool-name-only rows.
            if (content.len < 20) continue;

            // Confidence: model self-report, clamped; banned constants are
            // replaced by the extraction prompt (RFC-025 §3.2 rule 2).
            const confidence: f32 = switch (obj.get("confidence") orelse .null) {
                .float => |f| @min(1.0, @max(0.0, @as(f32, @floatCast(f)))),
                .integer => |i| @min(1.0, @max(0.0, @as(f32, @floatFromInt(i)))),
                else => 0.5,
            };

            const mem_type: []const u8 = switch (obj.get("type") orelse .null) {
                .string => |s| if (std.mem.eql(u8, s, "project_state")) "project_state" else "semantic",
                else => "semantic",
            };

            // related_tool -> procedural graph node_ref (dangling-safe).
            var node_ref: ?u32 = null;
            if (obj.get("related_tool")) |v| {
                const tool_name = switch (v) {
                    .string => |s| s,
                    else => "",
                };
                if (tool_name.len > 0) {
                    if (self.pg_store) |pg| {
                        node_ref = pg.matchNode(tool_name);
                    }
                }
            }

            // Keywords (optional).
            var kw_list = ArrayList([]const u8).empty;
            defer kw_list.deinit(self.alloc);
            if (obj.get("keywords")) |kw_val| {
                switch (kw_val) {
                    .array => |kw_arr| {
                        for (kw_arr.items) |k| {
                            if (kw_list.items.len >= 4) break;
                            switch (k) {
                                .string => |s| if (s.len > 0) kw_list.append(self.alloc, s) catch continue,
                                else => {},
                            }
                        }
                    },
                    else => {},
                }
            }
            const kw_owned: [][]u8 = blk: {
                var owned = try self.alloc.alloc([]u8, kw_list.items.len);
                for (kw_list.items, 0..) |k, i| owned[i] = try self.alloc.dupe(u8, k);
                break :blk owned;
            };

            var entry = store_mod.MemoryEntry{
                .id = &.{},
                .ts = utils.milliTimestamp(),
                .type = mem_type,
                .content = self.alloc.dupe(u8, content) catch continue,
                .keywords = kw_owned,
                .source_session = null,
                .confidence = confidence,
                .supersedes = null,
                .node_ref = node_ref,
                .access_count = 0,
                .last_access = 0,
            };
            self.memory_store.?.append(self.io, &entry) catch {
                self.alloc.free(entry.id);
                self.alloc.free(entry.content);
                for (entry.keywords) |k| self.alloc.free(k);
                self.alloc.free(entry.keywords);
                continue;
            };
            self.alloc.free(entry.id);
            self.alloc.free(entry.content);
            for (entry.keywords) |k| self.alloc.free(k);
            self.alloc.free(entry.keywords);
            extracted += 1;
        }
    }

    /// Injects top-k semantic memories into system prompt based on keyword matching (RFC-003).
    fn injectSemanticMemory(self: *AgentLoop, alloc: Allocator, current_prompt: []const u8) ![]u8 {
        // PSEUDOCODE:
        // 1. Load memory entries from store
        // 2. Filter entries matching keywords from current prompt/user request
        // 3. Sort by confidence * access_count, take top_k
        // 4. Append matching memories to system prompt
        if (self.memory_store == null) return alloc.dupe(u8, current_prompt);
        if (!self.config.memact_enabled) return alloc.dupe(u8, current_prompt);

        const entries = self.memory_store.?.loadIndex(self.io) catch return alloc.dupe(u8, current_prompt);
        defer store_mod.MemoryStore.freeEntries(alloc, entries);

        // RFC-025 Phase 1: dual-path retrieval, Path A = BM25 on the original
        // query (user request; falls back to the prompt). Guarantees exact
        // lexical recall of private entities (error codes, identifiers).
        const query: []const u8 = self.current_user_request orelse current_prompt;

        // Build doc texts (content + keywords) from eligible entries.
        var doc_entries = ArrayList(*store_mod.MemoryEntry).empty;
        defer doc_entries.deinit(alloc);
        var doc_texts = ArrayList([]u8).empty;
        defer {
            for (doc_texts.items) |t| alloc.free(t);
            doc_texts.deinit(alloc);
        }

        for (entries) |*entry| {
            // RFC-025 Phase 0: reject tool-name-only rows defensively
            // (legacy episodic entries may still exist on disk).
            if (entry.content.len < 20) continue;

            var buf = ArrayList(u8).empty;
            defer buf.deinit(alloc);
            try buf.appendSlice(alloc, entry.content);
            for (entry.keywords) |kw| {
                try buf.append(alloc, ' ');
                try buf.appendSlice(alloc, kw);
            }
            try doc_entries.append(alloc, entry);
            try doc_texts.append(alloc, try buf.toOwnedSlice(alloc));
        }

        if (doc_texts.items.len == 0) return alloc.dupe(u8, current_prompt);

        var index = try bm25_mod.Index.build(alloc, doc_texts.items);
        defer index.deinit(alloc);

        // Path A: BM25 on the original query (guarantees exact lexical recall
        // of private entities — RFC-025 §3.1).
        const ranked_a_opt = index.rank(alloc, query, doc_texts.items.len) catch null;
        defer if (ranked_a_opt) |r| alloc.free(r);
        const ranked_a: []const bm25_mod.Ranked = ranked_a_opt orelse &.{};

        // Path B: BM25 on the LLM-expanded query (semantic safety net).
        // Graceful degrade: when expansion is disabled or fails, Path A stands
        // alone (ranked_b empty -> RRF keeps Path A ranking).
        var ranked_b_opt: ?[]bm25_mod.Ranked = null;
        if (self.config.memact_expansion) {
            if (self.expandMemActQuery(alloc, query) catch null) |kw| {
                ranked_b_opt = index.rank(alloc, kw, doc_texts.items.len) catch null;
            }
        }
        defer if (ranked_b_opt) |r| alloc.free(r);
        const ranked_b: []const bm25_mod.Ranked = ranked_b_opt orelse &.{};

        const fused = try bm25_mod.rrfFuse(alloc, ranked_a, ranked_b);
        defer alloc.free(fused);

        // Scored entries in fused ranking order (descending RRF score).
        const ScoredEntry = struct { entry: *store_mod.MemoryEntry, score: f32 };
        var scored = ArrayList(ScoredEntry).empty;
        defer scored.deinit(alloc);
        for (fused) |f| {
            try scored.append(alloc, .{ .entry = doc_entries.items[f.doc_index], .score = f.score });
        }

        // Take top_k and build memory block
        const top_k = @min(self.config.memact_top_k, @as(u32, @intCast(scored.items.len)));
        if (top_k == 0) return alloc.dupe(u8, current_prompt);

        var mem_buf = utils.BufWriter.init(alloc);
        defer mem_buf.deinit();

        try mem_buf.writeAll("\n[MemAct Semantic Memory]\n");
        var budget_used: u32 = 0;
        const budget = self.config.memact_memory_budget;

        var count: u32 = 0;
        for (scored.items[0..@intCast(top_k)]) |scored_entry| {
            const entry = scored_entry.entry;
            const entry_text = entry.content;
            const tokens = self.token_estimator.estimate(entry_text);

            if (budget_used + tokens > budget) break;
            budget_used += tokens;

            try mem_buf.print("- [{s}] {s}\n", .{ entry.type, entry_text });

            // RFC-025 Phase 3: graph enrichment. A record carrying `node_ref`
            // is enriched with its 2-hop procedural context (causes/effects +
            // guidance/pitfalls). Dangling refs degrade to the plain record.
            if (entry.node_ref) |node_ref| {
                if (self.pg_store) |pg| {
                    const ctx = pg.enrichNode(alloc, node_ref, 4) catch null;
                    if (ctx) |ctx_text| {
                        const ctx_tokens = self.token_estimator.estimate(ctx_text);
                        if (budget_used + ctx_tokens <= budget) {
                            budget_used += ctx_tokens;
                            // Indent the context lines under the record.
                            var ctx_it = std.mem.splitScalar(u8, ctx_text, '\n');
                            while (ctx_it.next()) |line| {
                                if (line.len > 0) {
                                    try mem_buf.print("    {s}\n", .{line});
                                }
                            }
                        }
                        alloc.free(ctx_text);
                    }
                }
            }

            count += 1;
        }

        if (count > 0) {
            try mem_buf.writeAll("[/MemAct Semantic Memory]\n");
            const mem_str = try mem_buf.toOwnedSlice();
            defer alloc.free(mem_str);
            return try std.fmt.allocPrint(alloc, "{s}{s}", .{ current_prompt, mem_str });
        }

        return alloc.dupe(u8, current_prompt);
    }

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

        self.clearLastErrorContext();

        const enriched_prompt = self.injectSemanticMemory(self.alloc, system_prompt) catch null;
        defer if (enriched_prompt) |p| self.alloc.free(p);
        const active_prompt = enriched_prompt orelse system_prompt;

        const primary = self.backend.send(active_prompt, msgs, tool_defs, text_cb, think_cb);
        if (primary) |resp| return resp else |e| {
            return self.handleBackendSendError(act_id, e);
        }
    }

    /// 1-call LLM consultation invoked by Thread 2 Watchdog on timeout.
    /// Builds supervisor decision prompt for watchdog timeout evaluation.
    fn buildTimeoutSupervisorPrompt(alloc: Allocator, ctx: watchdog_mod.DecisionContext) ![]const u8 {
        // PSEUDOCODE:
        // 1. Format action description, elapsed time, and output log tail
        // 2. Return formatted prompt string
        var prompt_buf = utils.BufWriter.init(alloc);
        try prompt_buf.print(prompts_mod.watchdog_supervisor_decision_prompt_fmt, .{
            ctx.act_id,
            ctx.action_desc,
            ctx.elapsed_s,
            ctx.timeout_s,
            ctx.log_tail.len,
            ctx.log_tail,
        });
        return prompt_buf.list.items;
    }

    /// Evaluates whether the long-running action is making valid progress (WAIT) or stuck/hung (KILL).
    pub fn consultLlmOnTimeout(self: *AgentLoop, ctx: watchdog_mod.DecisionContext) watchdog_mod.TimeoutDecision {
        // PSEUDOCODE:
        // 1. Initialize arena for prompt construction
        // 2. Request supervisor evaluation from backend
        // 3. Fall back to safety wait if request fails
        // 4. Parse and return timeout decision
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const alloc = arena.allocator();

        const system_prompt = prompts_mod.watchdog_supervisor_system_prompt;
        const prompt_text = buildTimeoutSupervisorPrompt(alloc, ctx) catch {
            return .{ .should_kill = false, .extend_seconds = 60 };
        };

        const blocks = [_]proto.ContentBlock{.{ .text = prompt_text }};
        const msgs = [_]proto.Message{.{ .role = .user, .content = &blocks }};

        var resp = self.backend.send(system_prompt, &msgs, &[_]proto.ToolDefinition{}, null, null) catch |e| {
            var fallback = watchdog_mod.TimeoutDecision{ .should_kill = false, .extend_seconds = 30 };
            const err_msg = std.fmt.bufPrint(&fallback.reason_buf, "LLM decision call failed: {s}, safety wait 30s", .{@errorName(e)}) catch "LLM decision failed";
            fallback.reason_len = err_msg.len;
            return fallback;
        };
        defer resp.deinit();

        var full_text = utils.BufWriter.init(alloc);
        for (resp.content.items) |block| {
            if (block == .text) full_text.writeAll(block.text) catch {};
        }
        return parseTimeoutDecision(full_text.list.items);
    }

    /// Requests context summary from LLM for a given prompt, appending conversation history.
    fn requestContextSummary(self: *AgentLoop, act_id: usize, prompt: []const u8) !?[]const u8 {
        // PSEUDOCODE:
        // 1. Build temporary message sequence: history + system summary prompt
        // 2. Send request to backend and scan response for summary text block
        var msg_blocks = try self.alloc.alloc(proto.ContentBlock, 1);
        msg_blocks[0] = .{ .text = try self.alloc.dupe(u8, prompt) };
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

        for (summary_resp.content.items) |block| {
            if (block == .text) return try self.alloc.dupe(u8, block.text);
        }
        return null;
    }

    /// Performs context compaction (MemAct compaction) when model returns context limit error.
    pub fn compactContext(self: *AgentLoop, act_id: usize) !void {
        // PSEUDOCODE:
        // 1. Early-return if history length <= 2
        // 2. Dispatch MemAct JSON compaction if enabled; fall back to plain compaction if no summary
        // 3. Otherwise dispatch legacy summary compaction
        if (self.history.messages().len <= 2) {
            self.history.compact();
            return;
        }

        main.stderrPrint("\x1b[33m[agent] Summarizing context (MemAct compaction)...\x1b[0m\n", .{});

        if (self.config.memact_enabled) {
            const memact_prompt = prompts_mod.memact_compaction_prompt;
            if (try self.requestContextSummary(act_id, memact_prompt)) |summary| {
                defer self.alloc.free(summary);
                try self.history.compactMemAct(act_id, summary);
            } else {
                main.stderrPrint("[agent] Warning: LLM did not return text summary, fallback.\n", .{});
                self.history.compact();
            }
        } else {
            main.stderrPrint("\n\x1b[33m[agent] History too long (MemAct disabled), compacting using legacy method...\x1b[0m\n", .{});
            const legacy_prompt = prompts_mod.legacy_compaction_prompt;
            if (try self.requestContextSummary(act_id, legacy_prompt)) |summary| {
                defer self.alloc.free(summary);
                try self.history.compactWithSummary(summary);
            } else {
                self.history.compact();
            }
        }

        // RFC-024 §3.3: after a successful compaction, re-inject the active plan
        // progress, read-skill names, and the task reminder so the model keeps
        // its bearings. §3.6 State A: when structured planning is fully off,
        // ALL RFC-024 behavior must be a no-op — so the reinject is additionally
        // gated on enable_structured_planning (it only re-emits plan/skill
        // context that would not exist in State A anyway).
        if (self.config.post_compact_reinject and self.config.enable_structured_planning) {
            self.reinjectPostCompactContext(act_id);
        }
    }

    /// RFC-024 §3.3: build and append a `.summarized`-tier user message at the
    /// next history index containing (a) the active plan progress summary,
    /// (b) skill names read this session, and (c) the task reminder. Skips
    /// silently when there is nothing to reinject (no plan, no skills, no task).
    /// State B fallback (§3.6): plan-less variant contains only skills + task
    /// reminder.
    fn reinjectPostCompactContext(self: *AgentLoop, act_id: usize) void {
        var bw = utils.BufWriter.init(self.alloc);
        errdefer bw.deinit();

        var has_content = false;

        // (a) active plan progress summary (degrades to nothing if no plan)
        if (self.plan.current_plan != null) {
            const plan = &self.plan.current_plan.?;
            if (plan_executor.generateProgressSummary(plan, &self.plan.plan_ctx, self.alloc) catch null) |summary| {
                defer self.alloc.free(summary);
                if (summary.len > 0) {
                    bw.writeAll(prompts_mod.post_compact_plan_header) catch return;
                    bw.writeAll(summary) catch return;
                    has_content = true;
                }
            }
        }

        // (b) read-skill names (restated because their content was dropped)
        if (self.read_skills.items.len > 0) {
            bw.writeAll(prompts_mod.post_compact_skills_prefix) catch return;
            var first = true;
            for (self.read_skills.items) |name| {
                if (!first) bw.writeAll(", ") catch return;
                bw.print("`{s}`", .{name}) catch return;
                first = false;
            }
            has_content = true;
        }

        // (c) task reminder (original request, restated — cf. pg_task_reminder_fmt)
        if (self.current_user_request) |req| {
            const trunc = if (req.len > 200) req[0..200] ++ "..." else req;
            bw.print(prompts_mod.pg_task_reminder_fmt, .{trunc}) catch return;
            has_content = true;
        }

        if (!has_content) return;

        const block = bw.toOwnedSlice() catch return;
        defer self.alloc.free(block);

        self.history.addUser(block) catch return;

        if (self.journal) |*j| {
            j.recordEvent(self.io, act_id, .post_compact_reinject, "post-compact plan/skill/task re-injected") catch {};
        }
        if (!utils.isSubagent()) main.stderrPrint("[agent] Re-injected post-compact context (plan/skills/task).\n", .{});
    }

    const agent_execution = @import("execution.zig");
    pub const ToolExecSummary = agent_execution.ToolExecSummary;
    pub const closeOrphanedToolUses = agent_execution.closeOrphanedToolUses;
    pub const executeTools = agent_execution.executeTools;
};

// Parsing helpers moved to agent/parsing.zig; re-exported so existing
// call sites and unit tests keep working unchanged.
const agent_parsing = @import("parsing.zig");
pub const extractJsCodeBlock = agent_parsing.extractJsCodeBlock;
pub const convertXmlToolTagsToJs = agent_parsing.convertXmlToolTagsToJs;
pub const findJsCodeInResponse = agent_parsing.findJsCodeInResponse;
pub const parseTimeoutDecision = agent_parsing.parseTimeoutDecision;
pub const subagentRunner = @import("subagent.zig").subagentRunner;
pub const batchSubagentRunner = @import("subagent.zig").batchSubagentRunner;

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

fn waitManagedChildForTest(
    io: std.Io,
    child: *std.process.Child,
    completed: *std.atomic.Value(bool),
    wait_failed: *std.atomic.Value(bool),
) void {
    // PSEUDOCODE:
    // 1. Wait for the direct child in a helper thread.
    // 2. Publish successful completion separately from wait errors.
    if (child.wait(io)) |_| {
        completed.store(true, .release);
    } else |_| {
        wait_failed.store(true, .release);
    }
}

test "watchdog force kill terminates managed foreground process groups" {
    if (comptime @import("builtin").os.tag == .windows) return;

    defer signals.setInterrupted(false);
    const io = std.testing.io;
    const argv = [_][]const u8{ "/bin/sh", "-c", "sleep 30" };
    var child = try process_manager.spawnManaged(io, &argv, null, .ignore, .ignore, .ignore);
    const managed_pid: i32 = if (child.id) |pid| @as(i32, @intCast(pid)) else 0;
    var completed = std.atomic.Value(bool).init(false);
    var wait_failed = std.atomic.Value(bool).init(false);
    const waiter = try std.Thread.spawn(.{}, waitManagedChildForTest, .{ io, &child, &completed, &wait_failed });
    var child_reaped = false;
    defer if (!child_reaped) {
        process_manager.abortManaged(io, &child);
        child_reaped = true;
    };

    watchdogForceKillHandler();
    for (0..100) |_| {
        if (completed.load(.acquire) or wait_failed.load(.acquire)) break;
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    }
    const terminated_by_watchdog = completed.load(.acquire);
    if (!terminated_by_watchdog and managed_pid > 0) {
        _ = std.posix.kill(-managed_pid, std.posix.SIG.KILL) catch {};
    }
    waiter.join();
    child_reaped = true;
    process_manager.unregisterProcessGroup(managed_pid);
    try std.testing.expect(!wait_failed.load(.acquire));
    try std.testing.expect(terminated_by_watchdog);
}

test "watchdog force kill terminates managed background jobs" {
    if (comptime @import("builtin").os.tag == .windows) return;

    defer signals.setInterrupted(false);
    const io = std.testing.io;
    const manager = process_manager.getProcessManager(std.testing.allocator);
    const info = try manager.spawnBackground(io, "sleep 30");
    defer _ = process_manager.forceKillAllJobs("SIGKILL");
    defer process_manager.deinitGlobal();

    watchdogForceKillHandler();

    var running = true;
    for (0..100) |_| {
        const status = manager.getJobStatus(info.job_id) orelse return error.TestUnexpectedResult;
        running = status.running;
        if (!running) break;
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    }

    try std.testing.expect(!running);
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

test "agent - skillNameFromSkillPath" {
    // A SKILL.md inside a skills/<name>/ directory -> skill name is the dir.
    try std.testing.expectEqualStrings(
        "brainstorming",
        skillNameFromSkillPath("/home/u/.mini/skills/brainstorming/SKILL.md").?,
    );
    // A project-relative skills path also works.
    try std.testing.expectEqualStrings(
        "codebase-analysis",
        skillNameFromSkillPath(".agent/skills/codebase-analysis/SKILL.md").?,
    );
    // Non-skill paths return null.
    try std.testing.expect(skillNameFromSkillPath("/home/u/rfc_003_summary.md") == null);
    try std.testing.expect(skillNameFromSkillPath("/home/u/notskilled/SKILL.md.bak") == null);
}

test "agent - read_skills lifecycle and deinit cleans up without leaks" {
    // PSEUDOCODE:
    // 1. Allocate read_skills using testing allocator
    // 2. Track skill names (including duplicates)
    // 3. Verify deduplication
    // 4. Free and deinit read_skills, verifying no leaks
    const alloc = std.testing.allocator;
    var list: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (list.items) |s| alloc.free(s);
        list.deinit(alloc);
    }

    const s1 = try alloc.dupe(u8, "brainstorming");
    try list.append(alloc, s1);

    const s2 = try alloc.dupe(u8, "codebase-analysis");
    try list.append(alloc, s2);

    try std.testing.expectEqual(@as(usize, 2), list.items.len);
}

