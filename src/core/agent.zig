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
pub const journal_mod = @import("journal.zig");
pub const act_logger_mod = @import("act_logger.zig");
pub const signals = @import("signals.zig");
const chat_stream = @import("../ui/chat_stream.zig");
const term = @import("../ui/terminal.zig");
const spinner_mod = @import("../ui/spinner.zig");

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
fn getEnvVar(name: [*:0]const u8) ?[]const u8 {
    if (getenv(name)) |ptr| {
        return std.mem.span(ptr);
    }
    return null;
}

var g_active_agent: ?*AgentLoop = null;

fn agentToolListener(tool_name: []const u8, is_error: bool) void {
    if (g_active_agent) |agent| {
        agent.onToolCompleted(tool_name, is_error);
    }
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

/// Active AI backend.
pub const Backend = union(enum) {
    openai: openai_mod.Client,
    claude: claude_mod.Client,
    ollama: ollama_mod.Client,

    /// Display name of backend.
    pub fn name(self: Backend) []const u8 {
        return switch (self) {
            .openai => "openai-compat",
            .claude => "claude",
            .ollama => "ollama",
        };
    }

    /// Model name in use.
    pub fn model(self: Backend) []const u8 {
        return switch (self) {
            .openai => |c| c.model,
            .claude => |c| c.model,
            .ollama => |c| c.model,
        };
    }

    /// Sanitizes history according to backend formatting requirements (dispatches instead of
    /// scattering if-else throughout agent loop).
    fn sanitizeHistory(self: *Backend, hist: *history_mod.History) bool {
        return switch (self.*) {
            .openai => hist.ensureOpenAICompatible(),
            .claude => hist.ensureClaudeCompatible(),
            // Ollama uses OpenAI-compatible format.
            .ollama => hist.ensureOpenAICompatible(),
        };
    }

    /// Sends message to backend. Returns complete Response.
    fn send(
        self: *Backend,
        system_prompt: []const u8,
        msgs: []const proto.Message,
        tool_defs: []const proto.ToolDefinition,
        text_cb: ?*const fn ([]const u8) void,
        think_cb: ?*const fn ([]const u8) void,
    ) !proto.Response {
        return switch (self.*) {
            .openai => |*c| c.sendMessage(system_prompt, msgs, tool_defs, text_cb, think_cb),
            .claude => |*c| c.sendMessage(system_prompt, msgs, tool_defs, text_cb, think_cb),
            .ollama => |*c| c.sendMessage(system_prompt, msgs, tool_defs, text_cb, think_cb),
        };
    }

    /// Sets dynamic reasoning effort ("low" | "medium" | "high" | "none" | null).
    pub fn setReasoningEffort(self: *Backend, effort: ?[]const u8) void {
        switch (self.*) {
            .openai => |*c| c.setReasoningEffort(effort),
            else => {},
        }
    }

    /// Sets dynamic thinking budget tokens (or null).
    pub fn setThinkingBudget(self: *Backend, budget: ?u32) void {
        switch (self.*) {
            .claude => |*c| c.setThinkingBudget(budget),
            else => {},
        }
    }
};

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
            .media_output_dir = config.media_output_dir,
            .video_poll_timeout_secs = config.video_poll_timeout_secs,
            .openai_compat_url = config.openai_compat_url,
            .openai_compat_key = config.openai_compat_key,
            .image_input_max_bytes = config.image_input_max_bytes,
            .image_input_max_per_turn = config.image_input_max_per_turn,
        });

        var path_buf: [256]u8 = undefined;
        const home_dir = getEnvVar("HOME") orelse ".";
        const cas_path = try std.fmt.bufPrint(&path_buf, "{s}/.mini/cas", .{home_dir});
        const cas = try cas_mod.CAS.init(alloc, io, cas_path);

        var acts_buf: [256]u8 = undefined;
        const acts_path = std.fmt.bufPrint(&acts_buf, "{s}/.mini/acts", .{home_dir}) catch "/tmp/mini_acts";
        const act_logger = act_logger_mod.ActLogger.init(alloc, io, acts_path) catch null;

        var pg_store_ptr: ?*graph_store_mod.PGraphStore = null;
        if (config.memact_pg_enabled) {
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const cur_cwd = if (std.c.getcwd(&cwd_buf, cwd_buf.len)) |ptr| std.mem.sliceTo(ptr, 0) else ".";
            const prj_hash = std.hash.Fnv1a_64.hash(cur_cwd);

            var mem_path_buf: [512]u8 = undefined;
            const mem_base = config.memory_dir orelse (getEnvVar("MINI_HOME") orelse (std.fmt.bufPrint(&mem_path_buf, "{s}/.mini/memory", .{home_dir}) catch ".mini/memory"));

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
        };
    }

    /// Releases memory.
    pub fn deinit(self: *AgentLoop) void {
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
    }

    /// Saves the latest backend error context for subsequent journal recordError.
    /// Dupes raw response (since response is deinitialized before error bubbles up to processInput).
    fn setLastErrorContext(self: *AgentLoop, http_code: u32, raw: ?[]const u8) void {
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

    const StepResult = enum {
        continue_loop,
        exit_loop,
    };

    fn logActDebug(
        self: *AgentLoop,
        act_id: usize,
        input_msgs: []const proto.Message,
        tool_defs: []const proto.ToolDefinition,
        response: *const proto.Response,
        js_code_opt: ?[]const u8,
        exec_info: act_logger_mod.ActExecutionInfo,
    ) void {
        const logger = if (self.act_logger != null) &self.act_logger.? else return;

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

        const pid: u32 = @intCast(std.os.linux.getpid());
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

    fn executeStep(
        self: *AgentLoop,
        act_id: usize,
        tool_defs: []const proto.ToolDefinition,
        text_cb: ?*const fn ([]const u8) void,
        think_cb: ?*const fn ([]const u8) void,
    ) !StepResult {
        if (signals.isInterrupted()) return error.Interrupted;

        if (main.ui_repl.current_renderer == null and !utils.isSubagent()) {
            if (act_id > 1) {
                main.stderrPrint("\x1b[90m[agent] --- Loop {d} ---\x1b[0m\n", .{act_id});
            } else {
                main.stderrPrint("\n\x1b[90m[agent] --- Starting workflow ---\x1b[0m\n", .{});
            }
            main.stderrPrint("\x1b[36m[agent]\x1b[0m \x1b[93mThinking / Analyzing request... \x1b[0m\n", .{});
        }

        // Sanitize history according to backend formatting requirements.
        _ = self.backend.sanitizeHistory(&self.history);

        const input_msgs_count = self.history.len();
        const input_msgs = self.history.messages()[0..input_msgs_count];

        // Procedural Graph (RFC-010): Prepare ephemeral situational guidance block
        var temp_input_msgs = std.ArrayListUnmanaged(proto.Message).empty;
        defer temp_input_msgs.deinit(self.alloc);
        try temp_input_msgs.appendSlice(self.alloc, input_msgs);

        var ephemeral_guidance: ?[]u8 = null;
        defer if (ephemeral_guidance) |g| self.alloc.free(g);

        var ephemeral_blocks: ?[]proto.ContentBlock = null;
        defer if (ephemeral_blocks) |b| self.alloc.free(b);

        if (self.pg_store) |pg| {
            ephemeral_guidance = pg.serializeGuidance(
                self.alloc,
                self.last_executed_tool,
                self.recent_tools.items,
                self.last_act_failed,
                self.config.memact_pg_h,
            ) catch null;

            if (ephemeral_guidance) |guidance_text| {
                const blocks = try self.alloc.alloc(proto.ContentBlock, 1);
                blocks[0] = .{ .text = guidance_text };
                ephemeral_blocks = blocks;
                try temp_input_msgs.append(self.alloc, .{
                    .role = .user,
                    .content = blocks,
                });
            }
        }

        // Dynamic Thinking / Reasoning Effort modulation
        if (!self.config.reasoning_effort_disabled) {
            var effective_effort: ?[]const u8 = self.config.reasoning_effort;
            var effective_budget: ?u32 = self.config.thinking_budget_tokens;

            // Priority 1: Explicit JS override via mini.setThinking
            // (Model-driven selection: the model chooses its own effort level
            // per the agent's guidance in the system prompt.)
            if (js_bindings.consumePendingThinkingOverride()) |override| {
                if (override.effort) |eff| effective_effort = eff;
                if (override.budget_tokens) |bud| effective_budget = bud;
            } else if (self.dynamic_thinking) {
                if (act_id == 1) {
                    // Act 1: no model choice yet — start from config/default
                    effective_effort = self.config.reasoning_effort orelse "high";
                    effective_budget = self.config.thinking_budget_tokens orelse 4096;
                } else if (self.last_act_failed or self.js_retry_count > 0) {
                    // Priority 3a: Error recovery safety net — escalate to high
                    // regardless of sticky/model preference
                    effective_effort = "high";
                    effective_budget = 4096;
                } else {
                    // Priority 3b: Sticky effort — the model did not call
                    // mini.setThinking last Act, so keep the previous level
                    // instead of forcing "low". This lets the model sustain
                    // its chosen effort across routine follow-ups.
                    effective_effort = self.last_effort;
                    effective_budget = self.last_budget;
                }
            }

            // Remember the resolved values so they can stick when the model
            // makes no explicit choice in subsequent Acts.
            self.last_effort = effective_effort;
            self.last_budget = effective_budget;

            self.backend.setReasoningEffort(effective_effort);
            self.backend.setThinkingBudget(effective_budget);
            // Publish effort level to UI for live Thinking/Thought display
            chat_stream.active_effort = effective_effort;
        }

        // Send to AI backend (streaming)
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

        // Newline after stream finishes
        if (main.ui_repl.current_renderer == null) {
            try std.Io.File.stdout().writeStreamingAll(self.io, "\n");
        }

        // Append response to history (if has content)
        _ = try self.history.addAssistantResponse(&response);

        // Retrieve safe slice after history may have reallocated
        const valid_input_msgs = self.history.messages()[0..input_msgs_count];

        // Accumulate completion tokens
        for (response.content.items) |block| {
            switch (block) {
                .text => |t| self.last_turn_completion_tokens += self.token_estimator.estimate(t),
                .thinking => |th| self.last_turn_completion_tokens += self.token_estimator.estimate(th.thinking),
                .tool_use => |tu| self.last_turn_completion_tokens += self.token_estimator.estimate(tu.name) + self.token_estimator.estimate(tu.input_json),
                else => {},
            }
        }

        // 1. Native Tool Calling: if model calls tool via stop_reason .tool_use or has tool_use blocks
        var has_tool_use_blocks = false;
        for (response.content.items) |block| {
            if (block == .tool_use) {
                has_tool_use_blocks = true;
                break;
            }
        }

        if (response.stop_reason == .tool_use or has_tool_use_blocks) {
            self.logActDebug(act_id, valid_input_msgs, tool_defs, &response, null, .{ .exec_type = "tool_call" });
            try self.executeTools(act_id, &response);
            main.stderrPrint("\n", .{});
            return .continue_loop;
        }

        // 2. CodeAct: Check if JavaScript code block is present in response
        if (self.config.execution_mode != .tools) {
            if (findJsCodeInResponse(self.alloc, &response)) |js_code| {
                defer self.alloc.free(js_code);

                const start_codeact_ms = utils.milliTimestamp();
                if (main.ui_repl.current_renderer) |r| {
                    r.startTool("codeact", "{}");
                } else {
                    main.stderrPrint("\x1b[90m[codeact]\x1b[0m \x1b[35mExecuting CodeAct script...\x1b[0m ", .{});
                }

                signals.registerActiveEngine(self.engine);
                defer signals.registerActiveEngine(null);

                var res = self.engine.eval(js_code, "agent_codeact.js") catch |e| {
                    self.last_act_failed = true;
                    const end_err_ms = utils.milliTimestamp();
                    const dur_ms = if (end_err_ms >= start_codeact_ms) @as(u64, @intCast(end_err_ms - start_codeact_ms)) else 0;
                    self.logActDebug(act_id, valid_input_msgs, tool_defs, &response, js_code, .{
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
                    const err_msg = try std.fmt.allocPrint(self.alloc, "[CodeAct System Error]: {s}", .{@errorName(e)});
                    defer self.alloc.free(err_msg);
                    try self.history.addUser(err_msg);
                    return .continue_loop;
                };
                defer res.deinit();

                const end_codeact_ms = utils.milliTimestamp();
                const dur_ms = if (end_codeact_ms >= start_codeact_ms) @as(u64, @intCast(end_codeact_ms - start_codeact_ms)) else 0;

                self.logActDebug(act_id, valid_input_msgs, tool_defs, &response, js_code, .{
                    .exec_type = "codeact",
                    .stdout = res.stdout,
                    .return_value_json = res.return_value_json,
                    .is_error = res.is_error,
                    .duration_ms = dur_ms,
                    .error_message = res.error_message,
                });

                if (signals.isInterrupted()) return error.Interrupted;

                if (!res.is_error) {
                    if (main.ui_repl.current_renderer) |r| {
                        r.finishTool("codeact", if (res.return_value_json) |ret| ret else res.stdout, false, dur_ms, null, null);
                    } else {
                        main.stderrPrint("\x1b[32m[ok]\x1b[0m\n", .{});
                    }
                    self.js_retry_count = 0;
                    self.last_act_failed = false;

                    var out_buf = utils.BufWriter.init(self.alloc);
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

                    try self.history.addUser(out_buf.list.items);
                    return .continue_loop;
                } else {
                    if (main.ui_repl.current_renderer) |r| {
                        r.finishTool("codeact", if (res.error_message) |m| m else "JS Error", true, dur_ms, null, null);
                    } else {
                        main.stderrPrint("\x1b[31m[error]\x1b[0m\n", .{});
                    }
                    self.js_retry_count += 1;
                    self.last_act_failed = true;

                    var err_buf = utils.BufWriter.init(self.alloc);
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
                    if (self.js_retry_count >= 3) {
                        try err_buf.writeAll("Notice: 3 consecutive JavaScript execution errors occurred. You may fall back to standard tool calling or simplify your code.\n");
                    } else {
                        try err_buf.writeAll("Please analyze the error and retry by outputting corrected JavaScript code inside ```js ... ``` block.\n");
                    }

                    try self.history.addUser(err_buf.list.items);
                    return .continue_loop;
                }
            }
        }

        switch (response.stop_reason) {
            .end_turn, .stop_sequence => {
                self.logActDebug(act_id, valid_input_msgs, tool_defs, &response, null, .{ .exec_type = "none" });
                if (main.ui_repl.current_renderer == null and !utils.isSubagent()) {
                    main.stderrPrint("\n\x1b[92m[agent] ✓ Completed after {d} loops.\x1b[0m\n", .{act_id});
                }
                return .exit_loop;
            },
            .max_tokens => {
                self.logActDebug(act_id, valid_input_msgs, tool_defs, &response, null, .{ .exec_type = "max_tokens" });
                // Response truncated mid-stream. DO NOT exit — insert observation
                // requesting model to continue EXACTLY from where it stopped (without repeating
                // already output content) to finish the incomplete block (JS block / tool_use / text).
                self.max_tokens_continues += 1;
                if (self.max_tokens_continues > 5) {
                    main.stderrPrint("\n\x1b[31m[agent] ⛔ Continued max_tokens {d} consecutive times without completion. Stopping to prevent infinite loop.\x1b[0m\n", .{self.max_tokens_continues});
                    return .exit_loop;
                }
                main.stderrPrint("\n\x1b[33m[agent] ⚠️ Response truncated (max_tokens), requesting continuation ({d}/5)...\x1b[0m\n", .{self.max_tokens_continues});
                var buf = utils.BufWriter.init(self.alloc);
                defer buf.deinit();
                try buf.print(
                    "[System] The previous response was truncated due to reaching the max_tokens limit (attempt {d}). Please continue EXACTLY from where it stopped — do not repeat already written content, do not re-introduce. If a ```js ... ``` block or tool call was in progress, complete the remainder.",
                    .{self.max_tokens_continues},
                );
                try self.history.addUser(buf.list.items);
                return .continue_loop;
            },
            .tool_use => {
                self.logActDebug(act_id, valid_input_msgs, tool_defs, &response, null, .{ .exec_type = "tool_call" });
                try self.executeTools(act_id, &response);
                main.stderrPrint("\n", .{});
                return .continue_loop;
            },
            // RFC-009 Phase 5: stream aborted by idle stall watchdog. Partial
            // content (if any) is already in the response. If a complete tool
            // call was received, execute it normally; otherwise inject an
            // observation so the governor escalates effort on retry.
            .stream_aborted => {
                self.logActDebug(act_id, valid_input_msgs, tool_defs, &response, null, .{
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
                    self.last_act_failed = true;
                    try self.executeTools(act_id, &response);
                    return .continue_loop;
                }
                if (response.content.items.len == 0) {
                    self.last_act_failed = true;
                    main.stderrPrint("\n\x1b[33m[agent] ⚠️ Stream stalled (idle watchdog), retrying...\x1b[0m\n", .{});
                    return error.LLMProviderUnavailable;
                }
                // Partial text present: treat like truncation — ask model to continue.
                self.last_act_failed = true;
                main.stderrPrint("\n\x1b[33m[agent] ⚠️ Stream stalled mid-response, requesting continuation...\x1b[0m\n", .{});
                const note = "[System] The previous response was interrupted because the model stream went silent (idle watchdog). Continue EXACTLY from where it stopped — do not repeat already written content.";
                try self.history.addUser(note);
                return .continue_loop;
            },
            .unknown => {
                self.logActDebug(act_id, valid_input_msgs, tool_defs, &response, null, .{
                    .exec_type = "error",
                    .is_error = true,
                    .error_message = response.raw_debug_info,
                });
                // Classify HTTP errors. Capture context beforehand so error bubbling up to
                // processInput still records full journal (response is deinitialized en route).
                if (response.http_code >= 400) {
                    self.setLastErrorContext(response.http_code, response.raw_debug_info);
                }
                if (response.http_code == 401 or response.http_code == 403) return error.LLMAuthenticationError;
                if (response.http_code == 429) return error.LLMRateLimitExceeded;
                if (response.http_code >= 500 and response.http_code < 600) return error.LLMProviderUnavailable;

                if (response.http_code == 400) {
                    if (response.raw_debug_info) |raw| {
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
                }

                if (response.raw_debug_info) |raw| {
                    if (std.mem.indexOf(u8, raw, "rate_limit") != null) return error.LLMRateLimitExceeded;
                }

                // Detect role/first-message error: Claude rejects due to role ordering
                // (e.g. first message not user, or invalid role).
                if (response.http_code == 400) {
                    if (response.raw_debug_info) |raw| {
                        const has_first_msg = std.mem.indexOf(u8, raw, "first message") != null;
                        const has_role_and_assistant = std.mem.indexOf(u8, raw, "role") != null and
                            std.mem.indexOf(u8, raw, "assistant") != null;
                        if (has_first_msg or has_role_and_assistant) {
                            main.stderrPrint("\n\x1b[33m[agent] Claude rejected due to role ordering (HTTP 400). Fixing history...\x1b[0m\n", .{});
                            _ = self.history.ensureClaudeCompatible();
                            if (self.role_fix_attempts < 2) {
                                self.role_fix_attempts += 1;
                                // Retry executeStep with fixed history, bypass error/retry-truncate branch
                                return .continue_loop;
                            }
                            // Exceeded allowed attempts — fall through to standard error
                        }

                        const has_orphan_tool = std.mem.indexOf(u8, raw, "No tool call found for function call output") != null or
                            std.mem.indexOf(u8, raw, "tool_call_id") != null;
                        if (has_orphan_tool) {
                            main.stderrPrint("\n\x1b[33m[agent] OpenAI rejected due to orphan tool_result (HTTP 400). Fixing history...\x1b[0m\n", .{});
                            _ = self.history.ensureOpenAICompatible();
                            if (self.role_fix_attempts < 2) {
                                self.role_fix_attempts += 1;
                                return .continue_loop;
                            }
                        }
                    }
                }

                if (main.ui_repl.current_renderer) |r| {
                    r.stopWaiting();
                    if (r.is_thinking) r.endThinking();
                    r.ensureNewline();
                }
                main.stderrPrint("[agent] Warning: unknown stop_reason (HTTP {d})\n", .{response.http_code});
                printRawBackendResponse(response.raw_debug_info, response.http_code);
                // Ensure context captured (HTTP < 400 but malformed response)
                self.setLastErrorContext(response.http_code, response.raw_debug_info);
                return error.UnknownStopReason;
            },
        }
    }


    /// Processes user input through agentic loop.
    /// Handle tool completion lifecycle event (RFC-010 Procedural Graph tracking)
    pub fn onToolCompleted(self: *AgentLoop, tool_name: []const u8, is_error: bool) void {
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

    /// Process user input with optional attached image blocks (RFC-011 Media Ingestion).
    pub fn processInputWithImages(
        self: *AgentLoop,
        user_text: []const u8,
        images: []const proto.ImageBlock,
        text_cb: ?*const fn ([]const u8) void,
        think_cb: ?*const fn ([]const u8) void,
    ) !void {
        g_active_agent = self;
        hooks_mod.setToolListener(&agentToolListener);
        defer {
            g_active_agent = null;
            hooks_mod.setToolListener(null);
        }

        // Clear turn-level tool attachments
        media_gen_tool.clearTurnAttachments(self.alloc);

        // Allocate turn-scoped ArenaAllocator for memory cleanup
        var turn_arena = std.heap.ArenaAllocator.init(self.alloc);
        defer turn_arena.deinit();
        const turn_alloc = turn_arena.allocator();

        // Dispatch pre-prompt hook
        hooks_mod.dispatch(turn_alloc, self.io, .{
            .event = "pre-prompt",
            .user_prompt = user_text,
        });
        defer {
            hooks_mod.dispatch(turn_alloc, self.io, .{
                .event = "post-response",
                .user_prompt = user_text,
            });
        }

        // Append user message to history
        if (images.len > 0) {
            try self.history.addUserWithImages(user_text, images);
        } else {
            try self.history.addUser(user_text);
        }

        // Reset turn metrics
        self.last_turn_acts = 0;
        self.last_turn_completion_tokens = 0;

        // Reset role fix retry counter for new turn
        self.role_fix_attempts = 0;
        // Reset continue-max_tokens counter for new turn
        self.max_tokens_continues = 0;
        self.last_act_failed = false;
        self.js_retry_count = 0;

        // Retrieve relevant tool definitions for user message based on execution_mode
        const tool_defs = switch (self.config.execution_mode) {
            .codeact => &[_]proto.ToolDefinition{}, // Disable 100% of tools sent to API in codeact mode to force LLM to write CodeAct JS
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


        if (self.journal == null) {
            var path_buf: [256]u8 = undefined;
            const home_dir = getEnvVar("HOME") orelse ".";
            const journal_path = std.fmt.bufPrint(&path_buf, "{s}/.mini/sessions/journal_{d}.jsonl", .{ home_dir, std.os.linux.getpid() }) catch "/tmp/mini_journal.jsonl";
            self.journal = journal_mod.ActJournal.init(self.alloc, self.io, journal_path) catch null;
        }

        // ISSUE-CODEACT-001 M4: shared CAS snapshot tracker, global for mini.* bindings
        if (self.snapshot_tracker == null) {
            self.snapshot_tracker = snapshot_mod.SnapshotTracker.init(self.alloc, self.io, &self.cas, if (self.journal != null) &self.journal.? else null);
            snapshot_mod.setTracker(if (self.snapshot_tracker != null) &self.snapshot_tracker.? else null);
        }

        var act_id: usize = 1;
        var rate_limit_retries: usize = 0;
        const max_retries = 3;

        // Unbounded acts — model decides when to stop (exit_loop).
        while (true) : (act_id += 1) {
            self.last_turn_acts = act_id;
            var try_count: usize = 0;

            while (try_count <= max_retries) : (try_count += 1) {
                if (self.journal) |*j| j.recordEvent(self.io, act_id, .act_started, "Act started") catch {};

                const history_len = self.history.messages().len;

                const result = self.executeStep(act_id, tool_defs, text_cb, think_cb) catch |e| {
                    switch (e) {
                        error.Interrupted => {
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
                            return;
                        },
                        error.LLMAuthenticationError => {
                            if (main.ui_repl.current_renderer) |r| {
                                r.showBackendError(self.last_backend_http_code, self.last_backend_raw_error);
                            } else {
                                printRawBackendResponse(self.last_backend_raw_error, self.last_backend_http_code);
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
                        },
                        error.LLMRateLimitExceeded, error.LLMProviderUnavailable => {
                            if (main.ui_repl.current_renderer) |r| {
                                r.showBackendThrottled(self.last_backend_http_code, self.last_backend_raw_error);
                            } else {
                                printRawBackendResponse(self.last_backend_raw_error, self.last_backend_http_code);
                            }

                            // Journal: sufficient debug context — backend, model, error name,
                            // HTTP code (classified from response), attempt, raw server body.
                            if (self.journal) |*j| {
                                const ev_type: journal_mod.ActEventType = if (e == error.LLMRateLimitExceeded)
                                    .llm_call_throttled
                                else
                                    .llm_provider_error;
                                const desc = if (e == error.LLMRateLimitExceeded)
                                    "Rate limit (429) from backend"
                                else
                                    "Backend error (5xx / provider unavailable)";
                                j.recordError(self.io, act_id, ev_type, desc, .{
                                    .backend = self.backend.name(),
                                    .model = self.backend.model(),
                                    .error_name = @errorName(e),
                                    .http_code = self.last_backend_http_code,
                                    .attempt = rate_limit_retries + 1,
                                    .raw_snippet = self.last_backend_raw_error,
                                }) catch {};
                            }

                            rate_limit_retries += 1;
                            if (rate_limit_retries > MAX_RATE_LIMIT_RETRIES) {
                                if (main.ui_repl.current_renderer) |r| {
                                    r.clearInplaceLine();
                                }
                                main.stderrPrint("\n\x1b[31m[agent] ⛔ Retried {d} times but backend still reported rate limit / 503 error. Terminating task.\x1b[0m\n", .{MAX_RATE_LIMIT_RETRIES});
                                return e; // Retry limit exceeded
                            }

                            const raw_backoff: u64 = (@as(u64, 1) << @as(u6, @intCast(rate_limit_retries))) * 2;
                            const backoff_s: u64 = @min(raw_backoff, RATE_LIMIT_MAX_BACKOFF_S);

                            if (main.ui_repl.current_renderer) |r| {
                                try r.waitRetryCountdown(self.io, backoff_s, rate_limit_retries, MAX_RATE_LIMIT_RETRIES);
                            } else {
                                main.stderrPrint("[agent] ⚠ Rate limit / 503 (attempt {d}/{d})! Retrying in {d}s...\n", .{ rate_limit_retries, MAX_RATE_LIMIT_RETRIES, backoff_s });
                                std.Io.sleep(self.io, std.Io.Duration.fromSeconds(@intCast(backoff_s)), .awake) catch {};
                            }

                            if (self.history.last_compaction_act_id < act_id) {
                                self.history.truncate(history_len);
                            }
                            if (try_count > 0) try_count -= 1;
                            continue;
                        },
                        error.LLMContextWindowExceeded => {
                            if (main.ui_repl.current_renderer) |r| {
                                r.showBackendError(self.last_backend_http_code, self.last_backend_raw_error);
                            } else {
                                printRawBackendResponse(self.last_backend_raw_error, self.last_backend_http_code);
                            }
                            if (try_count >= max_retries) {
                                main.stderrPrint("\n\x1b[31m[agent] ⛔ Cannot compact context further after {d} attempts. Terminating process: {s}\x1b[0m\n", .{ max_retries + 1, @errorName(e) });
                                if (self.journal) |*j| j.recordError(self.io, act_id, .act_failed, "Context overflow cannot be compacted further — abort", .{
                                    .backend = self.backend.name(),
                                    .model = self.backend.model(),
                                    .error_name = @errorName(e),
                                    .http_code = self.last_backend_http_code,
                                    .attempt = try_count + 1,
                                    .raw_snippet = self.last_backend_raw_error,
                                }) catch {};
                                return e;
                            }

                            main.stderrPrint("\n\x1b[33m[agent] ⚠️ Model reported exceeding context limit (HTTP 400)! Performing emergency MemAct compaction (attempt {d}/{d})...\x1b[0m\n", .{ try_count + 1, max_retries + 1 });
                            if (self.journal) |*j| j.recordError(self.io, act_id, .llm_context_overflow, "Model reported context overflow — emergency MemAct compaction", .{
                                .backend = self.backend.name(),
                                .model = self.backend.model(),
                                .error_name = @errorName(e),
                                .http_code = self.last_backend_http_code,
                                .attempt = try_count + 1,
                                .raw_snippet = self.last_backend_raw_error,
                            }) catch {};

                            self.compactContext(act_id) catch {
                                self.history.compact();
                            };

                            if (self.history.last_compaction_act_id < act_id) {
                                self.history.truncate(history_len);
                            }
                            continue;
                        },

                        else => {
                            if (self.last_backend_raw_error != null and self.last_backend_http_code >= 400) {
                                if (main.ui_repl.current_renderer) |r| {
                                    r.showBackendError(self.last_backend_http_code, self.last_backend_raw_error);
                                } else {
                                    printRawBackendResponse(self.last_backend_raw_error, self.last_backend_http_code);
                                }
                            } else if (main.ui_repl.current_renderer) |r| {
                                r.stopWaiting();
                                if (r.is_thinking) r.endThinking();
                                r.ensureNewline();
                            }
                            if (try_count == max_retries) {
                                main.stderrPrint("\n[agent] Act {d} failed {d} consecutive times. Terminating process: {s}\n", .{ act_id, max_retries + 1, @errorName(e) });
                                if (self.journal) |*j| j.recordError(self.io, act_id, .act_failed, "Act terminal error — abort", .{
                                    .backend = self.backend.name(),
                                    .model = self.backend.model(),
                                    .error_name = @errorName(e),
                                    .http_code = self.last_backend_http_code,
                                    .attempt = try_count + 1,
                                    .raw_snippet = self.last_backend_raw_error,
                                }) catch {};
                                if (self.history.last_compaction_act_id < act_id) {
                                    self.history.truncate(history_len);
                                    if (self.journal) |*j| j.recordEvent(self.io, act_id, .rollback_completed, "Rollback state due to terminal error") catch {};
                                }
                                return e;
                            }

                            main.stderrPrint("\n[agent] Act {d} encountered an issue ({s}). Rolling back (attempt {d}/{d})...\n", .{ act_id, @errorName(e), try_count + 1, max_retries });
                            
                            if (self.journal) |*j| j.recordError(self.io, act_id, .act_failed, "Act error — rollback & retry", .{
                                .backend = self.backend.name(),
                                .model = self.backend.model(),
                                .error_name = @errorName(e),
                                .http_code = self.last_backend_http_code,
                                .attempt = try_count + 1,
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
                            continue;
                        }
                    }
                };

                // Reset counter when act succeeds: intermittent rate limits across a long turn
                // do not accumulate fatally.
                rate_limit_retries = 0;
                if (main.ui_repl.current_renderer) |r| {
                    r.resetErrorSignature();
                }

                // Flush all mini.write/patch/sh snapshots tracked during this act (M4)
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

                if (result == .exit_loop) {
                    if (self.journal) |*j| j.recordEvent(self.io, act_id, .task_completed, "Task completed") catch {};
                    return;
                }
                break; 
            } else {
                main.stderrPrint("\n\x1b[31m[agent] ⛔ Act {d} failed after {d} unrecoverable attempts. Terminating task.\x1b[0m\n", .{ act_id, max_retries + 1 });
                return error.ActRetryExhausted;
            }
        }
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

    fn sendToBackend(
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

    /// Executes all tool_use blocks in response.

    fn executeTools(self: *AgentLoop, act_id: usize, response: *const proto.Response) !void {
        _ = act_id;
        var any_tool_err = false;
        var results = ArrayList(proto.ToolResult).empty;
        defer results.deinit(self.alloc);
        
        var allocated_strings = ArrayList([]u8).empty;
        defer {
            for (allocated_strings.items) |s| self.alloc.free(s);
            allocated_strings.deinit(self.alloc);
        }

        for (response.content.items) |block| {
            if (signals.isInterrupted()) return error.Interrupted;
            switch (block) {
                .tool_use => |tu| {
                    const start_tool_ms = utils.milliTimestamp();
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

                    // Dispatch pre-tool-use hook
                    hooks_mod.dispatch(self.alloc, self.io, .{
                        .event = "pre-tool-use",
                        .tool_id = tu.id,
                        .tool_name = tu.name,
                        .input_json = tu.input_json,
                    });

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
                        is_err = true;
                        any_tool_err = true;
                        const msg = try std.fmt.allocPrint(self.alloc, "Tool error: {s}", .{@errorName(e)});
                        break :blk msg;
                    };
                    try allocated_strings.append(self.alloc, result);

                    // Truncate if oversized
                    const max_tool_result = 64 * 1024;
                    const truncated = if (result.len > max_tool_result) result[0..max_tool_result] else result;

                    // Dispatch post-tool-use hook
                    hooks_mod.dispatch(self.alloc, self.io, .{
                        .event = "post-tool-use",
                        .tool_id = tu.id,
                        .tool_name = tu.name,
                        .input_json = tu.input_json,
                        .tool_result = truncated,
                        .is_error = is_err,
                    });

                    try results.append(self.alloc, .{
                        .tool_use_id = tu.id,
                        .content = truncated,
                        .is_error = is_err,
                    });

                    const end_tool_ms = utils.milliTimestamp();
                    const dur_ms = if (end_tool_ms >= start_tool_ms) @as(u64, @intCast(end_tool_ms - start_tool_ms)) else 0;

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
    }
};

/// Extracts JavaScript code block from markdown text (```js ... ``` or ```javascript ... ```).
pub fn extractJsCodeBlock(alloc: Allocator, text: []const u8) ?[]const u8 {
    const markers = [_][]const u8{
        "```javascript\n",
        "```js\n",
        "```javascript\r\n",
        "```js\r\n",
    };
    for (markers) |m| {
        if (std.mem.indexOf(u8, text, m)) |start_idx| {
            const code_start = start_idx + m.len;
            if (std.mem.indexOf(u8, text[code_start..], "```")) |end_idx| {
                const code = text[code_start .. code_start + end_idx];
                const trimmed = std.mem.trim(u8, code, " \r\n\t");
                if (trimmed.len > 0) {
                    return alloc.dupe(u8, trimmed) catch null;
                }
            }
        }
    }
    return null;
}

fn extractXmlAttr(tag_str: []const u8, attr_name: []const u8) ?[]const u8 {
    var search_buf: [64]u8 = undefined;
    const pat = std.fmt.bufPrint(&search_buf, "{s}=\"", .{attr_name}) catch return null;
    if (std.mem.indexOf(u8, tag_str, pat)) |start_idx| {
        const val_start = start_idx + pat.len;
        if (std.mem.indexOfPos(u8, tag_str, val_start, "\"")) |val_end| {
            return tag_str[val_start..val_end];
        }
    }
    const pat_sq = std.fmt.bufPrint(&search_buf, "{s}='", .{attr_name}) catch return null;
    if (std.mem.indexOf(u8, tag_str, pat_sq)) |start_sq| {
        const val_start = start_sq + pat_sq.len;
        if (std.mem.indexOfPos(u8, tag_str, val_start, "'")) |val_end| {
            return tag_str[val_start..val_end];
        }
    }
    return null;
}

/// Converts pseudo XML tool tags (<file_read>, <glob>, <grep>, <bash>, <file_write>) into mini.* JS code.
pub fn convertXmlToolTagsToJs(alloc: Allocator, text: []const u8) ?[]const u8 {
    var js_buf = utils.BufWriter.init(alloc);
    errdefer js_buf.deinit();

    var has_tags = false;
    var pos: usize = 0;

    while (pos < text.len) {
        const tag_start = std.mem.indexOfPos(u8, text, pos, "<") orelse break;
        pos = tag_start + 1;

        const tag_names = [_][]const u8{ "file_read", "glob", "grep", "bash", "file_write", "file_edit", "http_request" };
        var matched_tag: ?[]const u8 = null;
        for (tag_names) |tn| {
            if (std.mem.startsWith(u8, text[tag_start + 1 ..], tn)) {
                matched_tag = tn;
                break;
            }
        }
        if (matched_tag == null) continue;

        const tag_name = matched_tag.?;
        const tag_end = std.mem.indexOfPos(u8, text, tag_start, ">") orelse continue;
        const tag_str = text[tag_start .. tag_end + 1];
        pos = tag_end + 1;

        has_tags = true;

        if (std.mem.eql(u8, tag_name, "file_read")) {
            const file_path = extractXmlAttr(tag_str, "file") orelse extractXmlAttr(tag_str, "path") orelse "";
            if (file_path.len > 0) {
                const escaped = json_mod.escape(alloc, file_path) catch continue;
                defer alloc.free(escaped);
                js_buf.print("console.log('=== file_read: ' + \"{s}\" + ' ===');\nconsole.log(mini.read(\"{s}\"));\n", .{ escaped, escaped }) catch {};
            }
        } else if (std.mem.eql(u8, tag_name, "glob")) {
            const pattern = extractXmlAttr(tag_str, "pattern") orelse "*";
            const path = extractXmlAttr(tag_str, "path") orelse ".";
            const esc_pat = json_mod.escape(alloc, pattern) catch continue;
            defer alloc.free(esc_pat);
            const esc_path = json_mod.escape(alloc, path) catch continue;
            defer alloc.free(esc_path);
            js_buf.print("console.log('=== glob: ' + \"{s}\" + ' ===');\nconsole.log(JSON.stringify(mini.glob(\"{s}\", \"{s}\")));\n", .{ esc_pat, esc_pat, esc_path }) catch {};
        } else if (std.mem.eql(u8, tag_name, "grep")) {
            const pattern = extractXmlAttr(tag_str, "pattern") orelse "";
            const path = extractXmlAttr(tag_str, "path") orelse ".";
            const esc_pat = json_mod.escape(alloc, pattern) catch continue;
            defer alloc.free(esc_pat);
            const esc_path = json_mod.escape(alloc, path) catch continue;
            defer alloc.free(esc_path);
            js_buf.print("console.log('=== grep: ' + \"{s}\" + ' ===');\nconsole.log(JSON.stringify(mini.grep(\"{s}\", \"{s}\")));\n", .{ esc_pat, esc_pat, esc_path }) catch {};
        } else if (std.mem.eql(u8, tag_name, "bash")) {
            const cmd = extractXmlAttr(tag_str, "command") orelse extractXmlAttr(tag_str, "cmd") orelse "";
            if (cmd.len > 0) {
                const esc_cmd = json_mod.escape(alloc, cmd) catch continue;
                defer alloc.free(esc_cmd);
                js_buf.print("console.log('=== bash: ' + \"{s}\" + ' ===');\nconst r = mini.sh(\"{s}\");\nconsole.log(r.stdout);\nif (r.stderr) console.log('stderr: ' + r.stderr);\n", .{ esc_cmd, esc_cmd }) catch {};
            }
        } else if (std.mem.eql(u8, tag_name, "file_write")) {
            const path = extractXmlAttr(tag_str, "path") orelse extractXmlAttr(tag_str, "file") orelse "";
            const content = extractXmlAttr(tag_str, "content") orelse "";
            if (path.len > 0) {
                const esc_path = json_mod.escape(alloc, path) catch continue;
                defer alloc.free(esc_path);
                const esc_content = json_mod.escape(alloc, content) catch continue;
                defer alloc.free(esc_content);
                js_buf.print("mini.write(\"{s}\", \"{s}\");\nconsole.log('file written: {s}');\n", .{ esc_path, esc_content, esc_path }) catch {};
            }
        }
    }

    if (!has_tags or js_buf.list.items.len == 0) {
        js_buf.deinit();
        return null;
    }

    return js_buf.toOwnedSlice() catch null;
}

/// Searches for JavaScript code block in Assistant response
pub fn findJsCodeInResponse(alloc: Allocator, response: *const proto.Response) ?[]const u8 {
    for (response.content.items) |block| {
        switch (block) {
            .text => |t| {
                if (extractJsCodeBlock(alloc, t)) |code| return code;
            },
            else => {},
        }
    }
    for (response.content.items) |block| {
        switch (block) {
            .text => |t| {
                if (convertXmlToolTagsToJs(alloc, t)) |code| return code;
            },
            else => {},
        }
    }
    return null;
}


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

