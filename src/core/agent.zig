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
const plan_dispatch = @import("plan_dispatch.zig");
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
const process_manager = @import("../runtime/process_manager.zig");
const tokens_mod = @import("memact/tokens.zig");
const graph_store_mod = @import("memact/graph_store.zig");
const store_mod = @import("memact/store.zig");
const snapshot_mod = @import("snapshot.zig");
const cas_mod = @import("cas.zig");
const prompts_mod = @import("prompts.zig");
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
        for (self.recent_tools.items) |t| {
            self.alloc.free(t);
        }
        self.recent_tools.deinit(self.alloc);
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

    const agent_step = @import("agent_step.zig");
    pub const StepResult = agent_step.StepResult;
    pub const executeStep = agent_step.executeStep;

    const agent_turn = @import("agent_turn.zig");
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

    /// Processes user input through agentic loop.
    /// Handle tool completion lifecycle event (RFC-010 Procedural Graph tracking)
    /// Appends episodic memory entry for the completed tool call (RFC-003).
    fn appendEpisodicMemory(self: *AgentLoop, tool_name: []const u8, is_error: bool) void {
        // PSEUDOCODE:
        // 1. Guard check if memory store is enabled and tool execution succeeded
        // 2. Prepare stack MemoryEntry referencing tool_name
        // 3. Append to memory store
        // 4. Free generated entry ID
        if (self.memory_store == null) return;
        if (!self.config.memact_enabled) return;
        if (is_error) return;

        var kw_slice = [_][]u8{@constCast(tool_name)};

        var entry = store_mod.MemoryEntry{
            .id = &.{},
            .ts = utils.milliTimestamp(),
            .type = "episodic",
            .content = @constCast(tool_name),
            .keywords = &kw_slice,
            .source_session = null,
            .confidence = 0.7,
            .supersedes = null,
            .access_count = 0,
            .last_access = 0,
        };
        defer if (entry.id.len > 0) self.alloc.free(entry.id);

        self.memory_store.?.append(self.io, &entry) catch return;
    }

    /// RFC-024 §3.4: when subagent dispatch is enabled and the current step
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

/// RFC-024 §3.4: real subagent runner — wraps the `invoke_subagent` tool so
/// plan steps can be dispatched to a child mini process. Module-level so it
/// can be passed as a `plan_dispatch.SubagentRunner`.
pub fn subagentRunner(io: std.Io, alloc: std.mem.Allocator, task: []const u8) anyerror![]u8 {
    const esc = try json_mod.escape(alloc, task);
    defer alloc.free(esc);
    const input = try std.fmt.allocPrint(alloc, "{{\"task\":\"{s}\"}}", .{esc});
    defer alloc.free(input);
    return tools_mod.executeTool(alloc, io, "invoke_subagent", input);
}

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
    }

    pub fn onToolCompleted(self: *AgentLoop, tool_name: []const u8, input_json: ?[]const u8, is_error: bool) void {
        if (self.pg_store) |pg| {
            if (self.last_executed_tool) |prev_tool| {
                pg.recordTransition(self.io, prev_tool, tool_name) catch {};
            }
        }
        self.recordSkillLoaded(tool_name, input_json);
        self.appendEpisodicMemory(tool_name, is_error);

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

        // Extract keywords from current prompt and user request
        var keywords = ArrayList([]const u8).empty;
        defer keywords.deinit(alloc);

        // Extract keywords from current prompt AND user request
        var prompt_it = std.mem.splitScalar(u8, current_prompt, ' ');
        while (prompt_it.next()) |word| {
            const trimmed = std.mem.trim(u8, word, " \t\r\n");
            if (trimmed.len >= 3 and trimmed.len <= 30) {
                try keywords.append(alloc, trimmed);
            }
        }
        // Add keywords from user request if available
        if (self.current_user_request) |req| {
            var it = std.mem.splitScalar(u8, req, ' ');
            while (it.next()) |word| {
                const trimmed = std.mem.trim(u8, word, " \t\r\n");
                if (trimmed.len >= 3 and trimmed.len <= 30) {
                    try keywords.append(alloc, trimmed);
                }
            }
        }

        // Score and filter entries
        const ScoredEntry = struct { entry: *store_mod.MemoryEntry, score: f32 };
        var scored = ArrayList(ScoredEntry).empty;
        defer scored.deinit(alloc);

        for (entries) |*entry| {
            var score: f32 = entry.confidence * @as(f32, @floatFromInt(entry.access_count + 1));
            var matches: usize = 0;
            for (entry.keywords) |kw| {
                for (keywords.items) |qkw| {
                    if (store_mod.matchKeyword(qkw, kw) or store_mod.matchKeyword(kw, qkw)) {
                        matches += 1;
                        score += 0.5;
                    }
                }
            }
            if (matches > 0) {
                try scored.append(alloc, .{ .entry = entry, .score = score });
            }
        }

        // Sort by score descending
        std.mem.sort(ScoredEntry, scored.items, {}, struct {
            fn lessThan(_: void, a: ScoredEntry, b: ScoredEntry) bool {
                return a.score > b.score;
            }
        }.lessThan);

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
        try prompt_buf.print(
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

        const system_prompt =
            \\You are the Watchdog Supervisor for mini-agent.
            \\An action is taking longer than the configured timeout limit.
            \\Your job is to analyze the action and output to decide if it is legitimately working (e.g. compiling, downloading, running a long test suite) or hung/frozen/waiting for input.
        ;
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
            const memact_prompt =
                "SYSTEM: You are the MemAct memory engine. Concisely summarize the preceding conversation into JSON, strictly adhering to this stencil:\n" ++
                "{\n  \"type\": \"context_summary\",\n  \"iteration_range\": [1, 99],\n  \"task_state\": \"progress description\",\n  \"decisions\": [\"decision 1\"],\n  \"open_questions\": [],\n  \"learned_errors\": [],\n  \"files_touched\": [],\n  \"next_step\": \"next step\"\n}\n" ++
                "If the input conversation already contains a \"[MemAct Context Summary]\" block, merge the previous summary into the new summary, retaining critical details while preserving the JSON stencil above.\nOutput JSON only, with no additional markdown text.";
            if (try self.requestContextSummary(act_id, memact_prompt)) |summary| {
                defer self.alloc.free(summary);
                try self.history.compactMemAct(act_id, summary);
            } else {
                main.stderrPrint("[agent] Warning: LLM did not return text summary, fallback.\n", .{});
                self.history.compact();
            }
        } else {
            main.stderrPrint("\n\x1b[33m[agent] History too long (MemAct disabled), compacting using legacy method...\x1b[0m\n", .{});
            const legacy_prompt = "SYSTEM: History is full. Please summarize the current task state (what has been done, results, next steps). Do not call tools, return summary text only.";
            if (try self.requestContextSummary(act_id, legacy_prompt)) |summary| {
                defer self.alloc.free(summary);
                try self.history.compactWithSummary(summary);
            } else {
                self.history.compact();
            }
        }

        // RFC-024 §3.3: after a successful compaction, re-inject the active plan
        // progress, read-skill names, and the task reminder so the model keeps
        // its bearings (a pure information add — cannot suppress existing flow).
        if (self.config.post_compact_reinject) {
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
                    bw.writeAll("[Post-Compact Plan Context]\n") catch return;
                    bw.writeAll(summary) catch return;
                    has_content = true;
                }
            }
        }

        // (b) read-skill names (restated because their content was dropped)
        if (self.read_skills.items.len > 0) {
            bw.writeAll("\n[Skills already read this session] ") catch return;
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

    fn formatLoopCheckpointMessage(
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
    fn handleActionLoopTripMessage(
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
            return self.formatLoopCheckpointMessage(tu, trip_reason_str);
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
    fn getLoopWarningSuffix(self: *AgentLoop, tool_name: []const u8) ?[]u8 {
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
    fn renderToolInvocationStart(self: *AgentLoop, act_id: usize, tu: proto.ToolUse) void {
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
    fn renderToolInvocationFinish(self: *AgentLoop, tu: proto.ToolUse, result: []const u8, is_err: bool, dur_ms: u64) void {
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
    fn trackPlanToolExecution(self: *AgentLoop, act_id: usize, tu: proto.ToolUse) !?[]u8 {
        // PSEUDOCODE:
        // 1. Guard: structured planning off or no plan -> null
        // 2. RFC-024: bump act counters so actual_acts accounting is maintained
        // 3. RFC-024: approval gate — a proposed plan is not actionable; emit advisory
        // 4. Check drift (existing)
        // 5. On tool_hint match: run verification gate when enabled, then complete/advance
        // 6. Persist at phase transitions (step complete, plan complete), not only at the end
        if (!self.plan.enable_structured_planning or self.plan.current_plan == null) return null;
        var plan = &self.plan.current_plan.?;
        var drift_advisory: ?[]u8 = null;

        plan_executor.bumpActCounters(&self.plan.plan_ctx);

        // RFC-024 §3.2: approval gate (advisory). A plan that is still `proposed`
        // is not actionable — steps do not advance and the model gets a standing
        // advisory instead of silent execution.
        if (self.config.plan_approval_gate and plan.phase == .proposed) {
            const note = try std.fmt.allocPrint(self.alloc,
                \\[plan] The parsed plan is `proposed` — it is not actionable yet. Run `/plan approve` to start executing, or proceed with explicit user confirmation.
            , .{});
            return note;
        }
        if (plan.phase == .rejected) return null;
        if (plan.phase == .approved) plan.phase = .executing;

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
                    // RFC-024 §3.1: verification gate. When enabled and the step
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

                    // RFC-024 §3.2: persistence trigger — a step transition is a
                    // phase transition; save the running plan so a crash revives it.
                    if (self.plan.plan_store) |ps| {
                        ps.save(plan) catch |e| main.stderrPrint("[agent] Warning: Failed to persist running plan: {s}\n", .{@errorName(e)});
                    }
                }
            }
        }

        if (self.plan.plan_ctx.is_complete or plan.isComplete()) {
            plan.phase = .complete;
            if (!utils.isSubagent()) main.stderrPrint("[agent] Plan completed! Saving to store...\n", .{});
            if (self.plan.plan_store) |ps| {
                ps.save(plan) catch |e| main.stderrPrint("[agent] Warning: Failed to save plan: {s}\n", .{@errorName(e)});
            }
            self.plan.clearPlan();
        } else {
            // RFC-024: advance via the dependency-aware ready-set selector instead
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

    fn checkToolDedupeCache(
        self: *AgentLoop,
        tu: proto.ToolUse,
        results: *ArrayList(proto.ToolResult),
        allocated_strings: *ArrayList([]u8),
    ) !bool {
        if (!isReadOnlyTool(tu.name)) return false;
        const cache_hash = fuzzyArgsHash(tu.input_json);
        const cached = self.lookupToolCache(tu.name, cache_hash) orelse return false;

        main.stderrPrint("\x1b[33m[duplicate: serving cached result]\x1b[0m\n", .{});
        const note = try std.fmt.allocPrint(self.alloc, "[duplicate: identical call already executed this turn — cached result below]\n{s}", .{cached});
        try allocated_strings.append(self.alloc, note);
        try results.append(self.alloc, .{ .tool_use_id = tu.id, .content = note, .is_error = false });
        return true;
    }

    fn postProcessToolResult(
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
        if (!is_err and isReadOnlyTool(tu.name)) {
            self.storeToolCache(tu.name, fuzzyArgsHash(tu.input_json), truncated) catch {};
        }

        if (!is_err) {
            self.plan.loop_plan_retries = 0;
            self.plan.plan_execution_pending = false;
            self.plan.plan_watchdog_retries = 0;
            if (!isExploratoryToolCall(tu.name, tu.input_json)) {
                if (try self.trackPlanToolExecution(act_id, tu)) |adv| {
                    try allocated_strings.append(self.alloc, adv);
                    try results.append(self.alloc, .{ .tool_use_id = tu.id, .content = adv, .is_error = false });
                }
            }
        }
    }

    /// Executes a single tool call, handles caching, snapshot tracking, output truncation, and returns duration.
    fn executeSingleTool(
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
        if (try self.checkToolDedupeCache(tu, results, allocated_strings)) return 0;

        const start_tool_ms = utils.milliTimestamp();
        self.renderToolInvocationStart(act_id, tu);

        if (std.mem.eql(u8, tu.name, "file_edit") or std.mem.eql(u8, tu.name, "file_write")) {
            if (json_mod.findString(tu.input_json, "path")) |path| {
                if (self.snapshot_tracker) |*t| t.beforeFileWrite(path);
            }
        }

        var is_err = false;
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

        try self.postProcessToolResult(act_id, tu, result, warn_suffix, is_err, results, allocated_strings);

        const end_tool_ms = utils.milliTimestamp();
        const dur_ms = if (end_tool_ms >= start_tool_ms) @as(u64, @intCast(end_tool_ms - start_tool_ms)) else 0;
        self.renderToolInvocationFinish(tu, result, is_err, dur_ms);
        return dur_ms;
    }

    /// Flushes tool execution results and any generated media attachments to history.
    fn recordToolResultsToHistory(self: *AgentLoop, results: []const proto.ToolResult) !void {
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
    fn dispatchSingleToolUse(
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
            const trip_msg = try self.handleActionLoopTripMessage(act_id, tu, trip_reason_str);
            try allocated_strings.append(self.alloc, trip_msg);
            try results.append(self.alloc, .{ .tool_use_id = tu.id, .content = trip_msg, .is_error = true });
            return .{ .dur_ms = 0, .should_break = true };
        }

        const warn_suffix: ?[]u8 = if (loop_check == .warn) self.getLoopWarningSuffix(tu.name) else null;
        defer if (warn_suffix) |w| self.alloc.free(w);

        if (self.plan.plan_active and !isPlanOnlyRequest(self.current_user_request) and !isExploratoryToolCall(tu.name, tu.input_json)) {
            self.plan.clearPlan();
        }

        const dur = try self.executeSingleTool(act_id, tu, warn_suffix, results, allocated_strings, any_tool_err);
        return .{ .dur_ms = dur, .should_break = false };
    }

    /// Executes all tool_use blocks in response.
    /// Returns execution summary for act debug logging.
    /// Same-response dedupe entry: tool name + whitespace-insensitive args hash.
    const SeenToolCall = struct {
        name: []u8,
        args_hash: u64,
    };

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
                    const args_hash = agent_loop_monitor.fuzzyArgsHash(tu.input_json);
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
                    const outcome = try self.dispatchSingleToolUse(act_id, tu, &results, &allocated_strings, &any_tool_err);
                    total_dur_ms += outcome.dur_ms;
                    if (outcome.should_break) break;
                    tool_count += 1;
                },
                else => {},
            }
        }

        try self.recordToolResultsToHistory(results.items);
        self.last_act_failed = any_tool_err;
        return .{
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
