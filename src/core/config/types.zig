//! config/types.zig — Configuration types, structs, and schemas for mini-agent.

const std = @import("std");
const Allocator = std.mem.Allocator;
const prompts_mod = @import("../prompts.zig");
pub const skills_mod = @import("../skills.zig");
const resolvers = @import("resolvers.zig");

pub const ExecutionMode = enum {
    codeact,
    tools,
    auto,

    pub fn fromString(s: []const u8) ExecutionMode {
        if (std.mem.eql(u8, s, "codeact") or std.mem.eql(u8, s, "js")) return .codeact;
        if (std.mem.eql(u8, s, "tools") or std.mem.eql(u8, s, "json")) return .tools;
        return .auto;
    }
};

/// OpenAI-compatible protocol (ISSUE-BACKEND-001).
pub const OpenAiProtocol = enum {
    auto,
    chat_completions,
    responses,

    pub fn fromString(s: []const u8) OpenAiProtocol {
        if (std.mem.eql(u8, s, "responses") or std.mem.eql(u8, s, "response")) return .responses;
        if (std.mem.eql(u8, s, "chat") or std.mem.eql(u8, s, "chat_completions") or std.mem.eql(u8, s, "completions")) return .chat_completions;
        return .auto;
    }
};

/// Complete configuration of mini-agent, loaded from environment variables.
pub const Config = struct {
    // Mode
    execution_mode: ExecutionMode = .auto,
    // Backend
    /// OpenAI-compatible protocol (default: auto).
    openai_protocol: OpenAiProtocol = .auto,
    /// OpenAI-compatible URL (highest priority). Null = unconfigured.
    openai_compat_url: ?[]const u8,
    /// API key for OpenAI-compatible endpoint. Null = key not required.
    openai_compat_key: ?[]const u8,
    /// Header name holding API key (default: Authorization).
    openai_compat_api_header: []const u8,
    /// Model for OpenAI-compatible endpoint.
    openai_compat_model: []const u8,
    /// Flag to use max_completion_tokens instead of max_tokens.
    openai_compat_use_completion_tokens: bool,
    /// Provider profile key for OpenAI-compat backend (RFC-012).
    openai_provider: []const u8 = "generic",
    openai_provider_js: ?[]const u8 = null,
    /// Anthropic API key. Null = unconfigured.
    anthropic_key: ?[]const u8,
    /// Claude model ID.
    claude_model: []const u8,
    /// Ollama base URL.
    ollama_url: []const u8,
    /// Ollama model name.
    ollama_model: []const u8,

    // Agent
    /// Maximum tokens in a response.
    max_tokens: u32,
    /// System prompt content (loaded from file or uses default).
    system_prompt: []const u8,
    /// Allocated memory for system_prompt (null if using default).
    system_prompt_buf: ?[]u8,

    // Tools
    /// Comma-separated allowlist. Null = allow all.
    tool_allowlist: ?[]const u8,
    /// Comma-separated blocklist. Null = block none.
    tool_blocklist: ?[]const u8,

    // Reasoning & Thinking (RFC-009)
    /// Reasoning effort for OpenAI-compatible models: "minimal" | "low" | "medium" | "high" | "none" | null.
    reasoning_effort: ?[]const u8 = null,
    /// Soft off-switch, set to true to force omitting reasoning params.
    reasoning_effort_disabled: bool = false,
    /// Anthropic thinking budget (tokens). Null = extended thinking disabled.
    thinking_budget_tokens: ?u32 = null,
    /// Anthropic thinking temperature (fixed 1.0 when thinking is enabled).
    thinking_temperature: f32 = 1.0,
    /// Maximum auto-continuations on max_tokens truncation per turn.
    max_tokens_continue_cap: usize = 3,
    /// Enable dynamic thinking governor (adaptive per-turn effort & mini.setThinking).
    dynamic_thinking_enabled: bool = true,

    // MemAct Config
    memact_enabled: bool,
    context_window: u32,
    ctx_safety_margin: f32,
    ctx_compact_threshold: f32,
    /// Maximum memory items injected into prompt (RFC-003).
    memact_top_k: u32 = 8,
    /// Token budget for memory block (RFC-003).
    memact_memory_budget: u32 = 2000,
    /// Memory extraction mode: async | sync | off (RFC-003).
    memact_extract: []const u8 = "async",
    /// LLM query expansion for dual-path retrieval (RFC-025 Phase 2).
    memact_expansion: bool = true,
    /// Memory directory. Null = caller builds ~/.mini/memory.
    memory_dir: ?[]const u8 = null,

    // Procedural Graph (RFC-010)
    /// Whether Procedural Graph online guidance is enabled.
    memact_pg_enabled: bool = true,
    /// Whether to emit procedural advisory/checkpoint messages to stderr.
    /// Default: true (show). Set MINI_MEMACT_PG_QUIET=1 to hide.
    memact_pg_advisory: bool = true,
    /// Procedural Graph neighborhood hop distance for localized guidance (default: 2).
    memact_pg_h: u32 = 2,
    /// Number of recent trajectory acts considered for context (default: 3).
    memact_pg_w: u32 = 3,
    /// Automatically learn and persist frequent tool transitions (N >= 3).
    memact_pg_auto_populate: bool = true,

    // Budget Limits (RFC-002)
    budget_max_tokens: usize,

    // Execution & Action Loop Limits
    /// Maximum consecutive identical tool calls before circuit breaker trips (default: 3).
    action_loop_consecutive_cap: usize = 3,
    /// Maximum occurrences of identical tool call within sliding window before circuit breaker trips (default: 4).
    action_loop_window_cap: usize = 4,
    /// Maximum consecutive read-only exploratory actions before warning (default: 5).
    action_loop_readonly_warn_cap: usize = 5,
    /// Maximum consecutive read-only exploratory actions before tripping circuit breaker (default: 10).
    action_loop_readonly_trip_cap: usize = 10,
    /// Macro-cycle repetition threshold for alternating tools before tripping circuit breaker (default: 2).
    action_loop_macro_cycle_cap: usize = 2,
    /// 3D procedural map orbit repetition threshold before tripping action loop circuit breaker (default: 2).
    action_loop_orbit_cap: usize = 2,
    /// Whether to display action loop detection messages to stderr/REPL (default: true). Set MINI_ACTION_LOOP_DISPLAY=0 to suppress.
    action_loop_display: bool = true,

    // MCP
    /// Path to mcp.json file. Null = default ~/.mini/mcp.json.
    mcp_config_path: ?[]const u8,

    // History
    /// false = disable history saving.
    history_enabled: bool,

    // Hooks
    /// Global hook command. Null = hook disabled.
    hook_command: ?[]const u8,
    /// Path to hooks configuration file. Null = use default.
    hooks_config_path: ?[]const u8,

    // Session
    /// Session ID (auto saved/restored at ~/.mini/sessions/<id>.json).
    session_id: ?[]const u8,
    /// Direct path to session file.
    session_file: ?[]const u8,

    // RFC-011: Media I/O
    /// Enable @image:<path> parsing in prompt (Ingestion, Phase 0). Default: true.
    image_input_enabled: bool = true,
    /// Maximum image attachments per turn.
    image_input_max_per_turn: u8 = 5,
    /// Maximum file size for input image in bytes (default: 10MB).
    image_input_max_bytes: usize = 10 * 1024 * 1024,
    /// Enable generate_image tool. Default: false.
    image_gen_enabled: bool = false,
    /// Image gen provider: "openai" | "openai_compat".
    image_gen_provider: []const u8 = "openai",
    /// Image gen model: "gpt-image-1", "dall-e-3", etc.
    image_gen_model: []const u8 = "gpt-image-1",
    /// Default image size: "1024x1024" | "1536x1024" | "1024x1536" | "auto".
    image_gen_size: []const u8 = "1024x1024",
    /// Enable generate_video tool. Default: false.
    video_gen_enabled: bool = false,
    /// Video gen model: "sora-2", "sora-2-pro", etc.
    video_gen_model: []const u8 = "sora-2",
    /// Video gen provider: "openai" | "openai_compat".
    video_gen_provider: []const u8 = "openai",
    /// Media output directory. Null = "<workspace>/media".
    media_output_dir: ?[]const u8 = null,
    /// Video poll timeout in seconds.
    video_poll_timeout_secs: u32 = 300,

    // RFC-019: Structured Planning System
    /// Enable structured planning system. Default: true.
    enable_structured_planning: bool = true,
    /// Enable drift detection. Default: true.
    plan_drift_detection: bool = true,
    /// Max plan steps (prevent infinite planning). Default: 20.
    plan_max_steps: usize = 20,
    /// Plan persistence directory. Null = ~/.mini/plans/.
    plans_dir: ?[]const u8 = null,
    /// Inject plan, progress, action-loop, and trajectory enforcement prompts. Default: false.
    prompt_enforcement_enabled: bool = false,

    // RFC-024: AI Plan Framework
    /// Gate plan step completion on explicit verification. Default: false.
    plan_verification_gate: bool = false,
    /// Require user approval before executing a parsed plan (advisory gate). Default: false.
    plan_approval_gate: bool = false,
    /// Re-inject plan + skill + task context after MemAct compaction. Default: true.
    post_compact_reinject: bool = true,
    /// Dispatch plan steps to subagents (per-step or auto-parallel for independent steps). Default: false.
    plan_subagent_dispatch: bool = false,
    /// Two-stage review gate after subagent-executed steps. Default: false.
    plan_review_gate: bool = false,

    // 3-Thread Watchdog & Act Coordinator (RFC-015)
    act_timeout_secs: u32 = 120,
    watchdog_tracking_interval_s: u32 = 10,
    watchdog_recap_interval: usize = 10,
    watchdog_interval_ms: u32 = 200,

    /// Default system prompt when MINI_SYSTEM_FILE is not configured.
    pub const default_system_prompt = prompts_mod.default_system_prompt;

    // Method delegations to resolvers
    pub const load = resolvers.load;
    pub const resolveBackendSettings = resolvers.resolveBackendSettings;
    pub const resolveMemActSettings = resolvers.resolveMemActSettings;
    pub const resolveLoopAndExecutionSettings = resolvers.resolveLoopAndExecutionSettings;
    pub const resolveReasoningAndMediaSettings = resolvers.resolveReasoningAndMediaSettings;
    pub const resolvePlanningAndWatchdogSettings = resolvers.resolvePlanningAndWatchdogSettings;

    // PSEUDOCODE:
    // 1. Stop unless the active execution mode is explicitly CodeAct.
    // 2. Stop when CodeAct instructions were already appended.
    // 3. Combine the current system prompt with the dedicated instructions.
    // 4. Replace and release the previous owned prompt buffer.
    pub fn appendCodeActInstructions(self: *Config, alloc: Allocator) void {
        if (self.execution_mode != .codeact) return;
        if (std.mem.indexOf(u8, self.system_prompt, "## CodeAct Execution Instructions") != null) return;

        const combined = std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{
            self.system_prompt,
            prompts_mod.codeact_execution_instructions,
        }) catch return;
        if (self.system_prompt_buf) |buf| alloc.free(buf);
        self.system_prompt_buf = combined;
        self.system_prompt = combined;
    }

    /// Releases allocated memory (system_prompt_buf + skills arena).
    pub fn deinit(self: *Config, alloc: Allocator) void {
        if (self.system_prompt_buf) |buf| {
            alloc.free(buf);
            self.system_prompt_buf = null;
            self.system_prompt = default_system_prompt;
        }
        skills_mod.deinitSkills();
    }
};

pub const JsonConfig = struct {
    // Backend
    execution_mode: ?[]const u8 = null,
    openai_protocol: ?[]const u8 = null,
    openai_compat_url: ?[]const u8 = null,
    openai_compat_api_key: ?[]const u8 = null,
    openai_compat_api_header: ?[]const u8 = null,
    openai_compat_model: ?[]const u8 = null,
    openai_compat_use_completion_tokens: ?bool = null,
    openai_compat_provider: ?[]const u8 = null,
    openai_compat_provider_js: ?[]const u8 = null,
    openai_provider: ?[]const u8 = null,
    anthropic_api_key: ?[]const u8 = null,
    claude_model: ?[]const u8 = null,
    ollama_host: ?[]const u8 = null,
    ollama_model: ?[]const u8 = null,
    // Agent
    max_tokens: ?u32 = null,
    // Tools
    tool_allowlist: ?[]const u8 = null,
    tool_blocklist: ?[]const u8 = null,
    // Reasoning & Thinking (RFC-009)
    reasoning_effort: ?[]const u8 = null,
    reasoning_effort_disabled: ?bool = null,
    thinking_budget_tokens: ?u32 = null,
    thinking_temperature: ?f32 = null,
    max_tokens_continue_cap: ?usize = null,
    dynamic_thinking_enabled: ?bool = null,
    // MemAct Config (RFC-003)
    memact_enabled: ?bool = null,
    context_window: ?u32 = null,
    ctx_safety_margin: ?f32 = null,
    ctx_compact_threshold: ?f32 = null,
    memact_top_k: ?u32 = null,
    memact_memory_budget: ?u32 = null,
    memact_extract: ?[]const u8 = null,
    memact_expansion: ?bool = null,
    memory_dir: ?[]const u8 = null,
    // Procedural Graph (RFC-010)
    memact_pg_enabled: ?bool = null,
    memact_pg_advisory: ?bool = null,
    memact_pg_h: ?u32 = null,
    memact_pg_w: ?u32 = null,
    memact_pg_auto_populate: ?bool = null,
    // Budget Limits (RFC-002)
    budget_max_tokens: ?usize = null,
    // Execution & Action Loop Limits
    action_loop_consecutive_cap: ?usize = null,
    action_loop_window_cap: ?usize = null,
    action_loop_readonly_warn_cap: ?usize = null,
    action_loop_readonly_trip_cap: ?usize = null,
    action_loop_macro_cycle_cap: ?usize = null,
    action_loop_orbit_cap: ?usize = null,
    action_loop_display: ?bool = null,
    // MCP
    mcp_config: ?[]const u8 = null,
    // History
    history_enabled: ?bool = null,
    // Hooks
    hook_command: ?[]const u8 = null,
    hooks_config_path: ?[]const u8 = null,
    // Session
    session_id: ?[]const u8 = null,
    session_file: ?[]const u8 = null,
    // RFC-011: Media I/O
    image_input_enabled: ?bool = null,
    image_input_max_per_turn: ?u8 = null,
    image_input_max_bytes: ?usize = null,
    image_gen_enabled: ?bool = null,
    image_gen_provider: ?[]const u8 = null,
    image_gen_model: ?[]const u8 = null,
    image_gen_size: ?[]const u8 = null,
    video_gen_enabled: ?bool = null,
    video_gen_model: ?[]const u8 = null,
    video_gen_provider: ?[]const u8 = null,
    media_output_dir: ?[]const u8 = null,
    video_poll_timeout_secs: ?u32 = null,
    // RFC-019: Structured Planning System
    enable_structured_planning: ?bool = null,
    plan_drift_detection: ?bool = null,
    plan_max_steps: ?usize = null,
    plans_dir: ?[]const u8 = null,
    prompt_enforcement_enabled: ?bool = null,
    // RFC-024: AI Plan Framework
    plan_verification_gate: ?bool = null,
    plan_approval_gate: ?bool = null,
    post_compact_reinject: ?bool = null,
    plan_subagent_dispatch: ?bool = null,
    plan_review_gate: ?bool = null,
    // 3-Thread Watchdog & Act Coordinator (RFC-015)
    act_timeout_secs: ?u32 = null,
    watchdog_tracking_interval_s: ?u32 = null,
    watchdog_recap_interval: ?usize = null,
    watchdog_interval_ms: ?u32 = null,
};

pub const JsonProviderConfig = struct {
    name: ?[]const u8 = null,
    protocol: ?[]const u8 = null,
    reasoning_field: ?[]const u8 = null,
    echo_policy: ?[]const u8 = null,
    thinking_tags: ?[]const u8 = null,
    reasoning_param: ?[]const u8 = null,
    supports_stream_options: ?bool = null,
    use_completion_tokens: ?bool = null,
    provider_js: ?[]const u8 = null,
    url: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    api_header: ?[]const u8 = null,
    model: ?[]const u8 = null,
};
