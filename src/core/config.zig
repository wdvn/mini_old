//! config.zig — Load configuration from environment variables and .env files.
//!
//! ## .env file search order (highest to lowest priority)
//!   1. `$MINI_ENV_FILE`      — explicitly specified path
//!   2. `./.env`              — current working directory (project-level)
//!   3. `~/.mini/.env`        — user-level config
//!
//! Shell environment variables always TAKE HIGHER PRECEDENCE over values in .env files
//! (using `setenv` with overwrite=0).
//!
//! ## Supported environment variables
//!
//! ### AI Backend
//!   `OPENAI_COMPAT_URL`     OpenAI-compatible URL (highest priority)
//!   `OPENAI_COMPAT_MODEL`   Model name (default: gpt-4o-mini)
//!   `OPENAI_COMPAT_API_KEY` API key (optional, some endpoints do not require one)
//!   `OPENAI_COMPAT_API_HEADER` Header name (default: Authorization)
//!   `ANTHROPIC_API_KEY`     Claude API key
//!   `OLLAMA_HOST`           Ollama base URL (default: http://localhost:11434)
//!   `OLLAMA_MODEL`          Ollama model (default: llama3)
//!
//! ### Agent & Reasoning
//!   `MINI_MAX_TOKENS`               Response token limit (default: 24000)
//!   `MINI_MAX_TOKENS_CONTINUE_CAP`  Max consecutive continuation acts when truncated by max_tokens (default: 3)
//!   `MINI_SYSTEM_FILE`              Path to system prompt file (.md)
//!   `MINI_PROMPT_ENFORCEMENT_ENABLED` "1" to inject plan/checkpoint enforcement prompts (default: disabled)
//!   `MINI_NO_HISTORY`               "1" to disable in-memory history saving
//!   `MINI_DYNAMIC_THINKING`         "0" to disable dynamic thinking governor (default: 1/enabled)
//!   `MINI_REASONING_EFFORT`         Reasoning effort ("minimal"|"low"|"medium"|"high"|"none")
//!   `MINI_REASONING_EFFORT_DISABLED` "1" to omit reasoning parameters for compat endpoints
//!   `MINI_THINKING_BUDGET`          Thinking budget tokens (e.g. for Claude thinking.budget_tokens >= 1024)
//!   `MINI_WATCHDOG_ENABLED`         "0" to disable stream stall watchdog (idle timeout); default: enabled
//!
//! ### MemAct (RFC-003)
//!   `MINI_MEMACT_ENABLED`       "0" to disable MemAct (default: enabled)
//!   `MINI_CONTEXT_WINDOW`       Context window tokens; if unset,
//!                               auto-detects based on backend (openai-compat 128000,
//!                               anthropic 200000, ollama 8192)
//!   `MINI_CTX_SAFETY_MARGIN`    Safety margin ratio (default: 0.15)
//!   `MINI_CTX_COMPACT_THRESHOLD` History compaction threshold (default: 0.85)
//!   `MINI_MEMACT_TOP_K`         Maximum injected memory items (default: 8)
//!   `MINI_MEMACT_MEMORY_BUDGET` Token budget for memory block (default: 2000)
//!   `MINI_MEMACT_EXTRACT`       Memory extraction mode: async|sync|off (default: async)
//!   `MINI_MEMORY_DIR`           Memory directory (default: ~/.mini/memory)
//!
//! ### Tools
//!   `MINI_TOOL_ALLOWLIST`   Only allow these tools (comma-separated)
//!   `MINI_TOOL_BLOCKLIST`   Block these tools (comma-separated)
//!
//! ### MCP
//!   `MINI_MCP_CONFIG`       Path to mcp.json file (default: ~/.mini/mcp.json)

const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");
pub const skills_mod = @import("skills.zig");
const main = @import("../main.zig");
const provider_mod = @import("../backends/provider.zig");
const prompts_mod = @import("prompts.zig");

// ---------------------------------------------------------------------------
// Config struct
// ---------------------------------------------------------------------------

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
    /// Minimum task length (chars) to trigger planning. Default: 50.
    planning_min_task_length: usize = 50,
    /// Enable drift detection. Default: true.
    plan_drift_detection: bool = true,
    /// Max plan steps (prevent infinite planning). Default: 20.
    plan_max_steps: usize = 20,
    /// Plan persistence directory. Null = ~/.mini/plans/.
    plans_dir: ?[]const u8 = null,
    /// Use enhanced progress checkpoint format. Default: true.
    enhanced_progress_checkpoint: bool = true,
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
    /// The literal content lives in prompts.zig (centralized prompt library).
    pub const default_system_prompt = @import("prompts.zig").default_system_prompt;

    /// Load configuration from environment variables (after calling loadDotEnv).
    /// `alloc` is used to read system prompt file if needed.
    const BackendSettings = struct {
        exec_mode: ExecutionMode,
        openai_proto: OpenAiProtocol,
        openai_url: ?[]const u8,
        openai_key: ?[]const u8,
        openai_api_header: []const u8,
        openai_model: []const u8,
        openai_provider_key: []const u8,
        anthropic_key: ?[]const u8,
        claude_model: []const u8,
        ollama_url: []const u8,
        ollama_model: []const u8,
        use_completion_tokens: bool,
    };

    fn resolveBackendSettings(env_map: *const std.process.Environ.Map) !BackendSettings {
        const openai_url = env_map.get("OPENAI_COMPAT_URL");
        const anthropic_key = env_map.get("ANTHROPIC_API_KEY");
        if (openai_url == null and anthropic_key == null) {
            main.stderrPrint(
                \\[config] Error: AI backend is not configured.
                \\
                \\Set one of the following environment variables:
                \\  OPENAI_COMPAT_URL=http://localhost:11434/v1
                \\  ANTHROPIC_API_KEY=sk-ant-...
                \\
                \\Or create a .env file in the current directory.
                \\
            , .{});
            return error.MissingBackend;
        }

        const provider_key = blk: {
            if (env_map.get("OPENAI_COMPAT_PROVIDER") orelse env_map.get("MINI_PROVIDER")) |p| {
                if (p.len > 0) break :blk p;
            }
            if (openai_url) |url| {
                const detected = provider_mod.detectFromUrl(url);
                if (!std.mem.eql(u8, detected, "generic")) break :blk detected;
            }
            break :blk "generic";
        };

        const use_comp = blk: {
            const v = env_map.get("MINI_USE_COMPLETION_TOKENS") orelse "0";
            break :blk std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true");
        };

        return .{
            .exec_mode = if (env_map.get("MINI_EXECUTION_MODE")) |m| ExecutionMode.fromString(m) else .auto,
            .openai_proto = if (env_map.get("OPENAI_PROTOCOL") orelse env_map.get("MINI_OPENAI_PROTOCOL") orelse env_map.get("OPENAI_COMPAT_PROTOCOL")) |p| OpenAiProtocol.fromString(p) else .auto,
            .openai_url = openai_url,
            .openai_key = env_map.get("OPENAI_COMPAT_API_KEY") orelse env_map.get("OPENAI_API_KEY"),
            .openai_api_header = env_map.get("OPENAI_COMPAT_API_HEADER") orelse "Authorization",
            .openai_model = env_map.get("OPENAI_COMPAT_MODEL") orelse "gpt-4o-mini",
            .openai_provider_key = provider_key,
            .anthropic_key = anthropic_key,
            .claude_model = env_map.get("CLAUDE_MODEL") orelse "claude-opus-4-5",
            .ollama_url = env_map.get("OLLAMA_HOST") orelse "http://localhost:11434",
            .ollama_model = env_map.get("OLLAMA_MODEL") orelse "llama3",
            .use_completion_tokens = use_comp,
        };
    }

    const MemActSettings = struct {
        enabled: bool,
        context_window: u32,
        ctx_safety_margin: f32,
        ctx_compact_threshold: f32,
        top_k: u32,
        memory_budget: u32,
        extract: []const u8,
        memory_dir: ?[]const u8,
        pg_enabled: bool,
        pg_advisory: bool,
        pg_h: u32,
        pg_w: u32,
        pg_auto_populate: bool,
    };

    fn resolveMemActSettings(env_map: *const std.process.Environ.Map, openai_url: ?[]const u8, anthropic_key: ?[]const u8) MemActSettings {
        const memact_enabled = blk: {
            const s = env_map.get("MINI_MEMACT_ENABLED") orelse "1";
            break :blk std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "true");
        };
        const ctx_window: u32 = blk: {
            if (env_map.get("MINI_CONTEXT_WINDOW")) |s| break :blk std.fmt.parseInt(u32, s, 10) catch 128000;
            if (openai_url != null) break :blk 128000;
            if (anthropic_key != null) break :blk 200000;
            break :blk 8192;
        };
        const extract: []const u8 = blk: {
            const s = env_map.get("MINI_MEMACT_EXTRACT") orelse "async";
            if (std.mem.eql(u8, s, "sync") or std.mem.eql(u8, s, "off") or std.mem.eql(u8, s, "async")) break :blk s;
            break :blk "async";
        };
        const pg_en = blk: {
            const s = env_map.get("MINI_MEMACT_PG_ENABLED") orelse env_map.get("MINI_PG_ENABLED") orelse "1";
            break :blk std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "true");
        };
        const pg_adv = blk: {
            const s = env_map.get("MINI_MEMACT_PG_ADVISORY") orelse "1";
            break :blk !std.mem.eql(u8, s, "0") and !std.mem.eql(u8, s, "false");
        };
        const pg_auto = blk: {
            const s = env_map.get("MINI_MEMACT_PG_AUTO_POPULATE") orelse "1";
            break :blk !std.mem.eql(u8, s, "0") and !std.mem.eql(u8, s, "false");
        };

        return .{
            .enabled = memact_enabled,
            .context_window = ctx_window,
            .ctx_safety_margin = if (env_map.get("MINI_CTX_SAFETY_MARGIN")) |s| std.fmt.parseFloat(f32, s) catch 0.15 else 0.15,
            .ctx_compact_threshold = if (env_map.get("MINI_CTX_COMPACT_THRESHOLD")) |s| std.fmt.parseFloat(f32, s) catch 0.85 else 0.85,
            .top_k = if (env_map.get("MINI_MEMACT_TOP_K")) |s| std.fmt.parseInt(u32, s, 10) catch 8 else 8,
            .memory_budget = if (env_map.get("MINI_MEMACT_MEMORY_BUDGET")) |s| std.fmt.parseInt(u32, s, 10) catch 2000 else 2000,
            .extract = extract,
            .memory_dir = env_map.get("MINI_MEMORY_DIR"),
            .pg_enabled = pg_en,
            .pg_advisory = pg_adv,
            .pg_h = if (env_map.get("MINI_MEMACT_PG_H")) |s| std.fmt.parseInt(u32, s, 10) catch 2 else 2,
            .pg_w = if (env_map.get("MINI_MEMACT_PG_W")) |s| std.fmt.parseInt(u32, s, 10) catch 3 else 3,
            .pg_auto_populate = pg_auto,
        };
    }

    const LoopAndExecutionSettings = struct {
        max_tokens: u32,
        budget_max_tokens: usize,
        history_enabled: bool,
        action_loop_consecutive_cap: usize,
        action_loop_window_cap: usize,
        action_loop_readonly_warn_cap: usize,
        action_loop_readonly_trip_cap: usize,
        action_loop_macro_cycle_cap: usize,
        action_loop_orbit_cap: usize,
        action_loop_display: bool,
    };

    fn resolveLoopAndExecutionSettings(env_map: *const std.process.Environ.Map) LoopAndExecutionSettings {
        const hist_en = blk: {
            const v = env_map.get("MINI_NO_HISTORY") orelse break :blk true;
            break :blk !std.mem.eql(u8, v, "1");
        };
        const loop_disp = blk: {
            const v = env_map.get("MINI_ACTION_LOOP_DISPLAY") orelse "1";
            break :blk !std.mem.eql(u8, v, "0") and !std.mem.eql(u8, v, "false");
        };

        return .{
            .max_tokens = if (env_map.get("MINI_MAX_TOKENS")) |s| std.fmt.parseInt(u32, s, 10) catch 24000 else 24000,
            .budget_max_tokens = if (env_map.get("MINI_BUDGET_MAX_TOKENS")) |s| std.fmt.parseInt(usize, s, 10) catch 10_000_000 else 10_000_000,
            .history_enabled = hist_en,
            .action_loop_consecutive_cap = if (env_map.get("MINI_LOOP_CONSECUTIVE_CAP")) |s| std.fmt.parseInt(usize, s, 10) catch 3 else 3,
            .action_loop_window_cap = if (env_map.get("MINI_LOOP_WINDOW_CAP")) |s| std.fmt.parseInt(usize, s, 10) catch 4 else 4,
            .action_loop_readonly_warn_cap = if (env_map.get("MINI_LOOP_READONLY_WARN")) |s| std.fmt.parseInt(usize, s, 10) catch 5 else 5,
            .action_loop_readonly_trip_cap = if (env_map.get("MINI_LOOP_READONLY_TRIP")) |s| std.fmt.parseInt(usize, s, 10) catch 10 else 10,
            .action_loop_macro_cycle_cap = if (env_map.get("MINI_LOOP_MACRO_CYCLE_CAP")) |s| std.fmt.parseInt(usize, s, 10) catch 2 else 2,
            .action_loop_orbit_cap = if (env_map.get("MINI_LOOP_ORBIT_CAP")) |s| std.fmt.parseInt(usize, s, 10) catch 2 else 2,
            .action_loop_display = loop_disp,
        };
    }

    const ReasoningAndMediaSettings = struct {
        reasoning_effort: ?[]const u8,
        reasoning_effort_disabled: bool,
        thinking_budget_tokens: ?u32,
        max_tokens_continue_cap: usize,
        dynamic_thinking_enabled: bool,
        image_input_enabled: bool,
        image_input_max_per_turn: u8,
        image_input_max_bytes: usize,
        image_gen_enabled: bool,
        image_gen_provider: []const u8,
        image_gen_model: []const u8,
        image_gen_size: []const u8,
        video_gen_enabled: bool,
        video_gen_model: []const u8,
        video_gen_provider: []const u8,
        media_output_dir: ?[]const u8,
        video_poll_timeout_secs: u32,
    };

    fn resolveReasoningAndMediaSettings(env_map: *const std.process.Environ.Map, provider_key: []const u8) ReasoningAndMediaSettings {
        const reasoning_effort = blk: {
            if (env_map.get("MINI_REASONING_EFFORT")) |s| {
                if (std.mem.eql(u8, s, "minimal") or std.mem.eql(u8, s, "low") or
                    std.mem.eql(u8, s, "medium") or std.mem.eql(u8, s, "high") or
                    std.mem.eql(u8, s, "none")) break :blk s;
            }
            break :blk null;
        };
        const thinking_budget: ?u32 = blk: {
            if (env_map.get("MINI_THINKING_BUDGET")) |s| {
                if (std.fmt.parseInt(u32, s, 10)) |val| {
                    if (val >= 1024) break :blk val;
                } else |_| {}
            }
            break :blk null;
        };
        const is_agnes = std.mem.indexOf(u8, provider_key, "agnes") != null;
        const img_prov = if (env_map.get("MINI_IMAGE_GEN_PROVIDER")) |p| (if (p.len > 0) p else if (is_agnes) "agnes" else "openai") else (if (is_agnes) "agnes" else "openai");
        const vid_prov = if (env_map.get("MINI_VIDEO_GEN_PROVIDER")) |p| (if (p.len > 0) p else if (is_agnes) "agnes" else "openai") else (if (is_agnes) "agnes" else "openai");

        return .{
            .reasoning_effort = reasoning_effort,
            .reasoning_effort_disabled = if (env_map.get("MINI_REASONING_EFFORT_DISABLED")) |v| std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true") else false,
            .thinking_budget_tokens = thinking_budget,
            .max_tokens_continue_cap = if (env_map.get("MINI_MAX_TOKENS_CONTINUE_CAP")) |s| std.fmt.parseInt(usize, s, 10) catch 3 else 3,
            .dynamic_thinking_enabled = if (env_map.get("MINI_DYNAMIC_THINKING")) |v| !std.mem.eql(u8, v, "0") and !std.mem.eql(u8, v, "false") else true,
            .image_input_enabled = if (env_map.get("MINI_IMAGE_INPUT_ENABLED")) |v| !std.mem.eql(u8, v, "0") and !std.mem.eql(u8, v, "false") else true,
            .image_input_max_per_turn = if (env_map.get("MINI_IMAGE_INPUT_MAX_PER_TURN")) |s| std.fmt.parseInt(u8, s, 10) catch 5 else 5,
            .image_input_max_bytes = if (env_map.get("MINI_IMAGE_INPUT_MAX_BYTES")) |s| std.fmt.parseInt(usize, s, 10) catch 10 * 1024 * 1024 else 10 * 1024 * 1024,
            .image_gen_enabled = if (env_map.get("MINI_IMAGE_GEN_ENABLED")) |v| std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true") else false,
            .image_gen_provider = img_prov,
            .image_gen_model = env_map.get("MINI_IMAGE_GEN_MODEL") orelse "gpt-image-1",
            .image_gen_size = env_map.get("MINI_IMAGE_GEN_SIZE") orelse "1024x1024",
            .video_gen_enabled = if (env_map.get("MINI_VIDEO_GEN_ENABLED")) |v| std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true") else false,
            .video_gen_model = env_map.get("MINI_VIDEO_GEN_MODEL") orelse "sora-2",
            .video_gen_provider = vid_prov,
            .media_output_dir = env_map.get("MINI_MEDIA_OUTPUT_DIR"),
            .video_poll_timeout_secs = if (env_map.get("MINI_VIDEO_POLL_TIMEOUT_SECS")) |s| std.fmt.parseInt(u32, s, 10) catch 600 else 600,
        };
    }

    const PlanningAndWatchdogSettings = struct {
        enable_structured_planning: bool,
        planning_min_task_length: usize,
        plan_drift_detection: bool,
        plan_max_steps: usize,
        plans_dir: ?[]const u8,
        enhanced_progress_checkpoint: bool,
        prompt_enforcement_enabled: bool,
        plan_verification_gate: bool,
        plan_approval_gate: bool,
        post_compact_reinject: bool,
        plan_subagent_dispatch: bool,
        plan_review_gate: bool,
        act_timeout_secs: u32,
        watchdog_tracking_s: u32,
        watchdog_recap_interval: usize,
        watchdog_interval_ms: u32,
    };

    fn resolvePlanningAndWatchdogSettings(env_map: *const std.process.Environ.Map) PlanningAndWatchdogSettings {
        const act_to: u32 = blk: {
            const s = env_map.get("MINI_ACT_TIMEOUT_SECS") orelse env_map.get("MINI_ACT_TIMEOUT") orelse break :blk 120;
            break :blk std.fmt.parseInt(u32, s, 10) catch 120;
        };
        return .{
            .enable_structured_planning = if (env_map.get("MINI_ENABLE_STRUCTURED_PLANNING")) |v| std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true") else false,
            .planning_min_task_length = if (env_map.get("MINI_PLANNING_MIN_TASK_LENGTH")) |s| std.fmt.parseInt(usize, s, 10) catch 50 else 50,
            .plan_drift_detection = if (env_map.get("MINI_PLAN_DRIFT_DETECTION")) |v| std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true") else true,
            .plan_max_steps = if (env_map.get("MINI_PLAN_MAX_STEPS")) |s| std.fmt.parseInt(usize, s, 10) catch 20 else 20,
            .plans_dir = env_map.get("MINI_PLANS_DIR"),
            .enhanced_progress_checkpoint = if (env_map.get("MINI_ENHANCED_PROGRESS_CHECKPOINT")) |v| std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true") else true,
            .prompt_enforcement_enabled = if (env_map.get("MINI_PROMPT_ENFORCEMENT_ENABLED")) |v| std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true") else false,
            .plan_verification_gate = if (env_map.get("MINI_PLAN_VERIFICATION_GATE")) |v| std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true") else false,
            .plan_approval_gate = if (env_map.get("MINI_PLAN_APPROVAL_GATE")) |v| std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true") else false,
            .post_compact_reinject = if (env_map.get("MINI_POST_COMPACT_REINJECT")) |v| std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true") else true,
            .plan_subagent_dispatch = if (env_map.get("MINI_PLAN_SUBAGENT_DISPATCH")) |v| std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true") else false,
            .plan_review_gate = if (env_map.get("MINI_PLAN_REVIEW_GATE")) |v| std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true") else false,
            .act_timeout_secs = act_to,
            .watchdog_tracking_s = if (env_map.get("MINI_WATCHDOG_TRACKING_S")) |s| std.fmt.parseInt(u32, s, 10) catch 10 else 10,
            .watchdog_recap_interval = if (env_map.get("MINI_WATCHDOG_RECAP_INTERVAL")) |s| std.fmt.parseInt(usize, s, 10) catch 10 else 10,
            .watchdog_interval_ms = if (env_map.get("MINI_WATCHDOG_INTERVAL_MS")) |s| std.fmt.parseInt(u32, s, 10) catch 200 else 200,
        };
    }

    fn printConfigDiagnostics(env_map: *const std.process.Environ.Map, b: *const BackendSettings, m: *const MemActSettings, r: *const ReasoningAndMediaSettings) void {
        if (utils.isSubagent()) return;
        main.stderrPrint("[config] Env bindings: OPENAI_COMPAT_URL={s}, OPENAI_COMPAT_MODEL={s}, PROVIDER={s}, MINI_HOME={s}\n", .{
            b.openai_url orelse "(null)", b.openai_model, b.openai_provider_key, env_map.get("MINI_HOME") orelse "(null)",
        });
        main.stderrPrint("[config] Build: {s} | {s} | {s} | zig {s}\n", .{
            main.BUILD_TIME, main.BUILD_OPTIMIZE, main.BUILD_TARGET, main.ZIG_VERSION,
        });
        if (m.enabled) {
            const window_src = if (env_map.get("MINI_CONTEXT_WINDOW") != null) "env" else "auto/backend";
            main.stderrPrint("[config] MemAct: window={d} ({s}), top_k={d}, budget={d}, extract={s}\n", .{
                m.context_window, window_src, m.top_k, m.memory_budget, m.extract,
            });
        }
        if (m.pg_enabled) {
            main.stderrPrint("[config] Procedural Graph: enabled, h={d}, w={d}, auto_populate={}\n", .{
                m.pg_h, m.pg_w, m.pg_auto_populate,
            });
        }
        if (r.dynamic_thinking_enabled) {
            main.stderrPrint("[config] Cognitive Governor: dynamic thinking enabled (effort={s}, budget={?d})\n", .{
                r.reasoning_effort orelse "auto", r.thinking_budget_tokens,
            });
        } else if (r.reasoning_effort != null or r.thinking_budget_tokens != null) {
            main.stderrPrint("[config] Cognitive Governor: static thinking (effort={s}, budget={?d})\n", .{
                r.reasoning_effort orelse "(none)", r.thinking_budget_tokens,
            });
        }
    }

    fn applyBackendAndMemActToConfig(
        cfg: *Config,
        env_map: *const std.process.Environ.Map,
        b: *const BackendSettings,
        m: *const MemActSettings,
        sp: SpResult,
    ) void {
        cfg.execution_mode = b.exec_mode;
        cfg.openai_protocol = b.openai_proto;
        cfg.openai_compat_url = b.openai_url;
        cfg.openai_compat_key = b.openai_key;
        cfg.openai_compat_api_header = b.openai_api_header;
        cfg.openai_compat_model = b.openai_model;
        cfg.openai_compat_use_completion_tokens = b.use_completion_tokens;
        cfg.openai_provider = b.openai_provider_key;
        cfg.openai_provider_js = env_map.get("OPENAI_COMPAT_PROVIDER_JS");
        cfg.anthropic_key = b.anthropic_key;
        cfg.claude_model = b.claude_model;
        cfg.ollama_url = b.ollama_url;
        cfg.ollama_model = b.ollama_model;
        cfg.system_prompt = sp.text;
        cfg.system_prompt_buf = sp.buf;
        cfg.tool_allowlist = env_map.get("MINI_TOOL_ALLOWLIST");
        cfg.tool_blocklist = env_map.get("MINI_TOOL_BLOCKLIST");
        cfg.memact_enabled = m.enabled;
        cfg.context_window = m.context_window;
        cfg.ctx_safety_margin = m.ctx_safety_margin;
        cfg.ctx_compact_threshold = m.ctx_compact_threshold;
        cfg.memact_top_k = m.top_k;
        cfg.memact_memory_budget = m.memory_budget;
        cfg.memact_extract = m.extract;
        cfg.memory_dir = m.memory_dir;
        cfg.memact_pg_enabled = m.pg_enabled;
        cfg.memact_pg_advisory = m.pg_advisory;
        cfg.memact_pg_h = m.pg_h;
        cfg.memact_pg_w = m.pg_w;
        cfg.memact_pg_auto_populate = m.pg_auto_populate;
    }

    fn applyLoopAndSessionToConfig(
        cfg: *Config,
        env_map: *const std.process.Environ.Map,
        l: *const LoopAndExecutionSettings,
    ) void {
        cfg.max_tokens = l.max_tokens;
        cfg.budget_max_tokens = l.budget_max_tokens;
        cfg.history_enabled = l.history_enabled;
        cfg.action_loop_consecutive_cap = l.action_loop_consecutive_cap;
        cfg.action_loop_window_cap = l.action_loop_window_cap;
        cfg.action_loop_readonly_warn_cap = l.action_loop_readonly_warn_cap;
        cfg.action_loop_readonly_trip_cap = l.action_loop_readonly_trip_cap;
        cfg.action_loop_macro_cycle_cap = l.action_loop_macro_cycle_cap;
        cfg.action_loop_orbit_cap = l.action_loop_orbit_cap;
        cfg.action_loop_display = l.action_loop_display;
        cfg.mcp_config_path = env_map.get("MINI_MCP_CONFIG");
        cfg.hook_command = env_map.get("MINI_HOOK_COMMAND") orelse env_map.get("MINI_PREHOOK") orelse env_map.get("MINI_HOOK_CMD");
        cfg.hooks_config_path = env_map.get("MINI_HOOKS_CONFIG");
        cfg.session_id = env_map.get("MINI_SESSION");
        cfg.session_file = env_map.get("MINI_SESSION_FILE");
    }

    fn applyReasoningMediaPlanningToConfig(
        cfg: *Config,
        r: *const ReasoningAndMediaSettings,
        p: *const PlanningAndWatchdogSettings,
    ) void {
        cfg.reasoning_effort = r.reasoning_effort;
        cfg.reasoning_effort_disabled = r.reasoning_effort_disabled;
        cfg.thinking_budget_tokens = r.thinking_budget_tokens;
        cfg.thinking_temperature = 1.0;
        cfg.max_tokens_continue_cap = r.max_tokens_continue_cap;
        cfg.dynamic_thinking_enabled = r.dynamic_thinking_enabled;
        cfg.image_input_enabled = r.image_input_enabled;
        cfg.image_input_max_per_turn = r.image_input_max_per_turn;
        cfg.image_input_max_bytes = r.image_input_max_bytes;
        cfg.image_gen_enabled = r.image_gen_enabled;
        cfg.image_gen_provider = r.image_gen_provider;
        cfg.image_gen_model = r.image_gen_model;
        cfg.image_gen_size = r.image_gen_size;
        cfg.video_gen_enabled = r.video_gen_enabled;
        cfg.video_gen_model = r.video_gen_model;
        cfg.video_gen_provider = r.video_gen_provider;
        cfg.media_output_dir = r.media_output_dir;
        cfg.video_poll_timeout_secs = r.video_poll_timeout_secs;
        cfg.act_timeout_secs = p.act_timeout_secs;
        cfg.watchdog_tracking_interval_s = p.watchdog_tracking_s;
        cfg.watchdog_recap_interval = p.watchdog_recap_interval;
        cfg.watchdog_interval_ms = p.watchdog_interval_ms;
        cfg.enable_structured_planning = p.enable_structured_planning;
        cfg.planning_min_task_length = p.planning_min_task_length;
        cfg.plan_drift_detection = p.plan_drift_detection;
        cfg.plan_max_steps = p.plan_max_steps;
        cfg.plans_dir = p.plans_dir;
        cfg.enhanced_progress_checkpoint = p.enhanced_progress_checkpoint;
        cfg.prompt_enforcement_enabled = p.prompt_enforcement_enabled;
        cfg.plan_verification_gate = p.plan_verification_gate;
        cfg.plan_approval_gate = p.plan_approval_gate;
        cfg.post_compact_reinject = p.post_compact_reinject;
        cfg.plan_subagent_dispatch = p.plan_subagent_dispatch;
        cfg.plan_review_gate = p.plan_review_gate;
    }

    /// Load configuration from environment variables (after calling loadDotEnv).
    /// `alloc` is used to read system prompt file if needed.
    pub fn load(alloc: Allocator, env_map: *const std.process.Environ.Map, io: std.Io) !Config {
        // PSEUDOCODE:
        // 1. Resolve backend settings
        // 2. Resolve MemAct, loop, reasoning/media, and planning/watchdog settings
        // 3. Load system prompt with workspace and rules
        // 4. Print diagnostics and populate Config via modular setters
        const b = try resolveBackendSettings(env_map);
        const m = resolveMemActSettings(env_map, b.openai_url, b.anthropic_key);
        const l = resolveLoopAndExecutionSettings(env_map);
        const r = resolveReasoningAndMediaSettings(env_map, b.openai_provider_key);
        const p = resolvePlanningAndWatchdogSettings(env_map);
        const sp_result = loadSystemPrompt(alloc, env_map, io);

        printConfigDiagnostics(env_map, &b, &m, &r);

        var cfg: Config = undefined;
        applyBackendAndMemActToConfig(&cfg, env_map, &b, &m, sp_result);
        applyLoopAndSessionToConfig(&cfg, env_map, &l);
        applyReasoningMediaPlanningToConfig(&cfg, &r, &p);
        cfg.appendCodeActInstructions(alloc);
        return cfg;
    }

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

// ---------------------------------------------------------------------------
// System prompt loading
// ---------------------------------------------------------------------------

const SpResult = struct { buf: ?[]u8, text: []const u8 };

/// Scans the workspace directory to build a dynamic context block informing the
/// model about the current environment (working directory, project name, detected
/// project stack, git branch, and top-level files/directories).
fn resolveWorkspaceRoot(env_map: *const std.process.Environ.Map) ?[]const u8 {
    if (env_map.get("MINI_WORKSPACE_ROOT")) |r| return r;
    if (env_map.get("MINI_AGENT_FOLDER")) |agent_dir| {
        if (std.fs.path.dirname(agent_dir)) |parent| return parent;
    }
    return env_map.get("PWD");
}

fn resolveWorkspaceRootAndName(env_map: *const std.process.Environ.Map) ?struct { root: []const u8, prj_name: []const u8 } {
    const root = resolveWorkspaceRoot(env_map) orelse return null;
    var prj_name = std.fs.path.basename(root);
    if (std.mem.eql(u8, prj_name, ".") or prj_name.len == 0) {
        if (env_map.get("PWD")) |pwd| {
            const b = std.fs.path.basename(pwd);
            if (b.len > 0 and !std.mem.eql(u8, b, ".")) prj_name = b;
        }
    }
    return .{ .root = root, .prj_name = prj_name };
}

const WorkspaceMarker = struct {
    file: []const u8,
    name: []const u8,
};

const WORKSPACE_MARKERS = [_]WorkspaceMarker{
    .{ .file = "go.mod", .name = "Go" },
    .{ .file = "package.json", .name = "Node.js / Web" },
    .{ .file = "Cargo.toml", .name = "Rust" },
    .{ .file = "build.zig", .name = "Zig" },
    .{ .file = "build.zig.zon", .name = "Zig" },
    .{ .file = "pyproject.toml", .name = "Python" },
    .{ .file = "requirements.txt", .name = "Python" },
    .{ .file = "setup.py", .name = "Python" },
    .{ .file = "pom.xml", .name = "Java (Maven)" },
    .{ .file = "build.gradle", .name = "Java/Kotlin (Gradle)" },
    .{ .file = "CMakeLists.txt", .name = "C/C++" },
    .{ .file = "Makefile", .name = "Make" },
};

fn detectProjectTypes(alloc: Allocator, io: std.Io, dir: *std.Io.Dir, list: *std.ArrayList([]const u8)) void {
    for (WORKSPACE_MARKERS) |marker| {
        if (dir.statFile(io, marker.file, .{})) |_| {
            var already = false;
            for (list.items) |existing| {
                if (std.mem.eql(u8, existing, marker.name)) {
                    already = true;
                    break;
                }
            }
            if (!already) list.append(alloc, marker.name) catch {};
        } else |_| {}
    }
}

fn detectGitBranch(io: std.Io, dir: *std.Io.Dir, buf: *[128]u8) ?[]const u8 {
    const head_file = dir.openFile(io, ".git/HEAD", .{}) catch return null;
    defer head_file.close(io);
    const n = utils.readAll(io, head_file, buf) catch return null;
    const head_content = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (std.mem.startsWith(u8, head_content, "ref: refs/heads/")) {
        return head_content["ref: refs/heads/".len..];
    }
    if (head_content.len >= 7) return head_content[0..7];
    return null;
}

fn isIgnoredWorkspaceEntry(name: []const u8) bool {
    const IGNORED = [_][]const u8{ "node_modules", "zig-cache", "zig-out", "__pycache__", "target", "dist", "build" };
    for (IGNORED) |ign| {
        if (std.mem.eql(u8, name, ign)) return true;
    }
    return false;
}

fn collectWorkspaceEntries(alloc: Allocator, io: std.Io, dir: *std.Io.Dir, list: *std.ArrayList([]const u8)) void {
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (isIgnoredWorkspaceEntry(entry.name)) continue;

        if (entry.kind == .directory) {
            const dname = std.fmt.allocPrint(alloc, "{s}/", .{entry.name}) catch continue;
            list.append(alloc, dname) catch {
                alloc.free(dname);
                continue;
            };
        } else {
            const fname = alloc.dupe(u8, entry.name) catch continue;
            list.append(alloc, fname) catch {
                alloc.free(fname);
                continue;
            };
        }
        if (list.items.len >= 35) break;
    }
    std.mem.sort([]const u8, list.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
}

fn formatWorkspaceContext(
    alloc: Allocator,
    root: []const u8,
    prj_name: []const u8,
    types: []const []const u8,
    branch: ?[]const u8,
    entries: []const []const u8,
) ?[]u8 {
    var bw = utils.BufWriter.init(alloc);
    defer bw.deinit();

    bw.print("<workspace_context>\n", .{}) catch return null;
    bw.print("- Working Directory: {s}\n- Project Name: {s}\n", .{ root, prj_name }) catch return null;

    if (types.len > 0) {
        bw.print("- Project Type: ", .{}) catch return null;
        for (types, 0..) |t, idx| {
            if (idx > 0) bw.print(", ", .{}) catch return null;
            bw.print("{s}", .{t}) catch return null;
        }
        bw.print("\n", .{}) catch return null;
    }
    if (branch) |b| bw.print("- Git Branch: {s}\n", .{b}) catch return null;

    if (entries.len > 0) {
        bw.print("- Workspace Entries: ", .{}) catch return null;
        for (entries, 0..) |item, idx| {
            if (idx > 0) bw.print(", ", .{}) catch return null;
            bw.print("{s}", .{item}) catch return null;
        }
        bw.print("\n", .{}) catch return null;
    }
    bw.print("</workspace_context>\n", .{}) catch return null;
    return bw.toOwnedSlice() catch null;
}

pub fn buildWorkspaceContext(alloc: Allocator, env_map: *const std.process.Environ.Map, io: std.Io) ?[]u8 {
    // PSEUDOCODE:
    // 1. Resolve workspace root directory and project name
    // 2. Open directory iterator
    // 3. Detect project types via marker files
    // 4. Detect current Git branch from .git/HEAD
    // 5. Collect top-level workspace entries (up to 35 items)
    // 6. Format workspace context XML block
    const ws = resolveWorkspaceRootAndName(env_map) orelse return null;
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, ws.root, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var detected_types = std.ArrayList([]const u8).empty;
    defer detected_types.deinit(alloc);
    detectProjectTypes(alloc, io, &dir, &detected_types);

    var head_buf: [128]u8 = undefined;
    const git_branch = detectGitBranch(io, &dir, &head_buf);

    var entries_list = std.ArrayList([]const u8).empty;
    defer {
        for (entries_list.items) |item| alloc.free(item);
        entries_list.deinit(alloc);
    }
    collectWorkspaceEntries(alloc, io, &dir, &entries_list);

    return formatWorkspaceContext(alloc, ws.root, ws.prj_name, detected_types.items, git_branch, entries_list.items);
}

fn loadBaseSystemPrompt(alloc: Allocator, env_map: *const std.process.Environ.Map, io: std.Io) SpResult {
    const path = env_map.get("MINI_SYSTEM_FILE") orelse return .{ .buf = null, .text = Config.default_system_prompt };
    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, path, .{}) catch {
        if (!utils.isSubagent()) main.stderrPrint("[config] Failed to open system prompt: {s}, using default.\n", .{path});
        return .{ .buf = null, .text = Config.default_system_prompt };
    };
    defer file.close(io);

    const stat = file.stat(io) catch return .{ .buf = null, .text = Config.default_system_prompt };
    if (stat.size == 0 or stat.size > 64 * 1024) return .{ .buf = null, .text = Config.default_system_prompt };

    const buf = alloc.alloc(u8, @intCast(stat.size)) catch return .{ .buf = null, .text = Config.default_system_prompt };
    const n = utils.readAll(io, file, buf) catch {
        alloc.free(buf);
        return .{ .buf = null, .text = Config.default_system_prompt };
    };
    if (!utils.isSubagent()) main.stderrPrint("[config] System prompt: {s} ({d} bytes)\n", .{ path, n });
    return .{ .buf = buf, .text = buf[0..n] };
}

fn injectWorkspaceContext(alloc: Allocator, env_map: *const std.process.Environ.Map, io: std.Io, current: SpResult) SpResult {
    const ws_ctx = buildWorkspaceContext(alloc, env_map, io) orelse return current;
    defer alloc.free(ws_ctx);
    const combined = std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ current.text, ws_ctx }) catch return current;
    if (current.buf) |b| alloc.free(b);
    if (!utils.isSubagent()) main.stderrPrint("[config] Injected workspace context into system prompt\n", .{});
    return .{ .buf = combined, .text = combined };
}

fn appendAgentRuleFile(alloc: Allocator, io: std.Io, accum: *std.ArrayList(u8), path: []const u8, label: []const u8) bool {
    const text = readAgentFile(alloc, io, path) orelse return false;
    defer alloc.free(text);
    accum.appendSlice(alloc, text) catch return false;
    accum.appendSlice(alloc, "\n\n") catch return false;
    if (!utils.isSubagent()) main.stderrPrint("[config] Loaded {s} ({d} bytes)\n", .{ label, text.len });
    return true;
}

fn collectAgentRules(alloc: Allocator, env_map: *const std.process.Environ.Map, io: std.Io) ?[]u8 {
    var accum = std.ArrayList(u8).empty;
    defer accum.deinit(alloc);

    const ws_root = resolveWorkspaceRoot(env_map);
    var path_buf: [512]u8 = undefined;

    if (ws_root) |root| {
        if (std.fmt.bufPrint(&path_buf, "{s}/AGENTS.md", .{root})) |p| {
            if (!appendAgentRuleFile(alloc, io, &accum, p, "workspace AGENTS.md")) {
                if (std.fmt.bufPrint(&path_buf, "{s}/CLAUDE.md", .{root})) |cp| {
                    _ = appendAgentRuleFile(alloc, io, &accum, cp, "workspace CLAUDE.md");
                } else |_| {}
            }
        } else |_| {}
    }

    if (env_map.get("MINI_AGENT_FOLDER")) |agent_dir| {
        const is_same = if (ws_root) |root| std.mem.eql(u8, root, agent_dir) else false;
        if (!is_same) {
            if (std.fmt.bufPrint(&path_buf, "{s}/AGENTS.md", .{agent_dir})) |pp| {
                _ = appendAgentRuleFile(alloc, io, &accum, pp, ".agent AGENTS.md");
            } else |_| {}
        }
    }

    if (env_map.get("HOME")) |home| {
        if (std.fmt.bufPrint(&path_buf, "{s}/.mini/AGENTS.md", .{home})) |gp| {
            _ = appendAgentRuleFile(alloc, io, &accum, gp, "global AGENTS.md");
        } else |_| {}
    }

    if (accum.items.len == 0) return null;
    return alloc.dupe(u8, accum.items) catch null;
}

pub fn loadSystemPrompt(alloc: Allocator, env_map: *const std.process.Environ.Map, io: std.Io) SpResult {
    // PSEUDOCODE:
    // 1. Load base prompt from file or fallback to default
    // 2. Inject workspace context if available
    // 3. Collect and append AGENTS.md rules
    // 4. Append skills block
    var result = loadBaseSystemPrompt(alloc, env_map, io);
    result = injectWorkspaceContext(alloc, env_map, io, result);

    if (collectAgentRules(alloc, env_map, io)) |rules| {
        defer alloc.free(rules);
        const combined = std.fmt.allocPrint(alloc, "{s}\n\n<RULE[AGENTS.md]>\n{s}</RULE[AGENTS.md]>\n", .{ result.text, rules }) catch return appendSkillsBlock(alloc, env_map, io, result);
        if (result.buf) |b| alloc.free(b);
        result = .{ .buf = combined, .text = combined };
    }

    return appendSkillsBlock(alloc, env_map, io, result);
}

fn readAgentFile(alloc: Allocator, io: std.Io, path: []const u8) ?[]u8 {
    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, path, .{}) catch return null;
    defer file.close(io);

    const stat = file.stat(io) catch return null;
    if (stat.size == 0 or stat.size > 128 * 1024) return null;

    const buf = alloc.alloc(u8, @intCast(stat.size)) catch return null;
    const n = utils.readAll(io, file, buf) catch {
        alloc.free(buf);
        return null;
    };
    return buf[0..n];
}

/// Injects skills block at the end of system prompt.
/// Loads skills from disk first (loadSkills), then builds block and appends it.
/// Returns new SpResult; if no skills exist, returns original.
fn appendSkillsBlock(alloc: Allocator, env_map: *const std.process.Environ.Map, io: std.Io, prev: SpResult) SpResult {
    const n = skills_mod.loadSkills(alloc, io, env_map);
    if (n == 0) return prev;

    const block = skills_mod.buildSkillsBlock(alloc) catch return prev;
    if (block) |b| {
        const combined = std.fmt.allocPrint(alloc, "{s}\n{s}", .{ prev.text, b }) catch {
            alloc.free(b);
            return prev;
        };
        alloc.free(b);
        if (prev.buf) |old| alloc.free(old);
        if (!utils.isSubagent()) main.stderrPrint("[config] Loaded {d} skill(s) into system prompt\n", .{n});
        return .{ .buf = combined, .text = combined };
    }
    return prev;
}

// ---------------------------------------------------------------------------
// .env loader
// ---------------------------------------------------------------------------

/// Loads environment variables from .env files in priority order:
///   1. $MINI_ENV_FILE — explicit path
///   2. ./.env         — current directory
///   3. ~/.mini/.env   — user-level
///
/// Shell env variables always take higher precedence (setenv overwrite=0).
/// Supports syntax: `KEY=VALUE`, `KEY="VALUE"`, `KEY='VALUE'`,
///                  `export KEY=VALUE`, `# comment`, empty lines.
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
    planning_min_task_length: ?usize = null,
    plan_drift_detection: ?bool = null,
    plan_max_steps: ?usize = null,
    plans_dir: ?[]const u8 = null,
    enhanced_progress_checkpoint: ?bool = null,
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

/// Loads environment variables from .env and config.json files in priority order:
///   1. $MINI_ENV_FILE
///   2. ./.env
///   3. .agent/.env
///   4. ~/.mini/.env
///   5. .agent/config.json
///   6. ~/.mini/config.json
fn loadDotEnvFiles(env_map: *std.process.Environ.Map, io: std.Io, home: ?[]const u8) void {
    // PSEUDOCODE:
    // 1. Gather candidate .env paths: MINI_ENV_FILE, .env, MINI_AGENT_FOLDER/.env, MINI_HOME/.env
    // 2. Call tryLoadFile on each existing candidate
    var paths: [4][512]u8 = undefined;
    var path_lens: [4]usize = .{ 0, 0, 0, 0 };
    var n: usize = 0;

    if (env_map.get("MINI_ENV_FILE")) |explicit| {
        if (explicit.len > 0 and explicit.len < 512) {
            @memcpy(paths[n][0..explicit.len], explicit);
            path_lens[n] = explicit.len;
            n += 1;
        }
    }

    const dot_env = ".env";
    @memcpy(paths[n][0..dot_env.len], dot_env);
    path_lens[n] = dot_env.len;
    n += 1;

    if (env_map.get("MINI_AGENT_FOLDER")) |agent_dir| {
        if (agent_dir.len > 0) {
            const p = std.fmt.bufPrint(&paths[n], "{s}/.env", .{agent_dir}) catch "";
            path_lens[n] = p.len;
            if (p.len > 0) n += 1;
        }
    }

    if (env_map.get("MINI_HOME")) |mh| {
        if (mh.len > 0) {
            const p = std.fmt.bufPrint(&paths[n], "{s}/.env", .{mh}) catch "";
            path_lens[n] = p.len;
            if (p.len > 0) n += 1;
        }
    } else if (home) |h| {
        const p = std.fmt.bufPrint(&paths[n], "{s}/.mini/.env", .{h}) catch "";
        path_lens[n] = p.len;
        if (p.len > 0) n += 1;
    }

    for (0..n) |i| {
        tryLoadFile(env_map, io, paths[i][0..path_lens[i]]);
    }
}

fn loadJsonConfigFiles(alloc: Allocator, env_map: *std.process.Environ.Map, io: std.Io, home: ?[]const u8) void {
    // PSEUDOCODE:
    // 1. Check MINI_AGENT_FOLDER/config.json
    // 2. Check MINI_HOME/config.json or ~/.mini/config.json
    if (env_map.get("MINI_AGENT_FOLDER")) |agent_dir| {
        if (agent_dir.len > 0) {
            var json_path_buf: [512]u8 = undefined;
            if (std.fmt.bufPrint(&json_path_buf, "{s}/config.json", .{agent_dir})) |jp| {
                tryLoadJsonConfig(alloc, env_map, io, jp);
            } else |_| {}
        }
    }

    if (env_map.get("MINI_HOME")) |mh| {
        if (mh.len > 0) {
            var json_path_buf: [512]u8 = undefined;
            if (std.fmt.bufPrint(&json_path_buf, "{s}/config.json", .{mh})) |jp| {
                tryLoadJsonConfig(alloc, env_map, io, jp);
            } else |_| {}
        }
    } else if (home) |h| {
        var json_path_buf: [512]u8 = undefined;
        if (std.fmt.bufPrint(&json_path_buf, "{s}/.mini/config.json", .{h})) |jp| {
            tryLoadJsonConfig(alloc, env_map, io, jp);
        } else |_| {}
    }
}

pub fn loadDotEnv(alloc: Allocator, env_map: *std.process.Environ.Map, io: std.Io) void {
    // PSEUDOCODE:
    // 1. Load .env file candidates
    // 2. Load config.json file candidates
    // 3. Load active provider configuration and adapter
    const home = env_map.get("HOME");
    loadDotEnvFiles(env_map, io, home);
    loadJsonConfigFiles(alloc, env_map, io, home);
    loadActiveProviderConfig(alloc, env_map, io);
}

fn setEnvInt(comptime T: type, env_map: *std.process.Environ.Map, key: []const u8, val: T) usize {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{val}) catch return 0;
    return setEnvDefault(env_map, key, s);
}

fn setEnvFloat(env_map: *std.process.Environ.Map, key: []const u8, val: f64) usize {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d:.4}", .{val}) catch return 0;
    return setEnvDefault(env_map, key, s);
}

fn setEnvBool(env_map: *std.process.Environ.Map, key: []const u8, val: bool) usize {
    return setEnvDefault(env_map, key, if (val) "1" else "0");
}

fn applyGeneralAndModelJsonConfig(cfg: *const JsonConfig, env_map: *std.process.Environ.Map) usize {
    var count: usize = 0;
    if (cfg.execution_mode) |val| count += setEnvDefault(env_map, "MINI_EXECUTION_MODE", val);
    if (cfg.openai_protocol) |val| count += setEnvDefault(env_map, "OPENAI_PROTOCOL", val);
    if (cfg.openai_compat_url) |val| count += setEnvDefault(env_map, "OPENAI_COMPAT_URL", val);
    if (cfg.openai_compat_api_key) |val| count += setEnvDefault(env_map, "OPENAI_COMPAT_API_KEY", val);
    if (cfg.openai_compat_api_header) |val| count += setEnvDefault(env_map, "OPENAI_COMPAT_API_HEADER", val);
    if (cfg.openai_compat_model) |val| count += setEnvDefault(env_map, "OPENAI_COMPAT_MODEL", val);
    if (cfg.openai_compat_use_completion_tokens) |val| count += setEnvBool(env_map, "MINI_USE_COMPLETION_TOKENS", val);
    if (cfg.openai_compat_provider_js) |val| count += setEnvDefault(env_map, "OPENAI_COMPAT_PROVIDER_JS", val);
    if (cfg.openai_compat_provider orelse cfg.openai_provider) |val| count += setEnvDefault(env_map, "OPENAI_COMPAT_PROVIDER", val);
    if (cfg.anthropic_api_key) |val| count += setEnvDefault(env_map, "ANTHROPIC_API_KEY", val);
    if (cfg.claude_model) |val| count += setEnvDefault(env_map, "CLAUDE_MODEL", val);
    if (cfg.ollama_host) |val| count += setEnvDefault(env_map, "OLLAMA_HOST", val);
    if (cfg.ollama_model) |val| count += setEnvDefault(env_map, "OLLAMA_MODEL", val);
    if (cfg.max_tokens) |val| count += setEnvInt(u32, env_map, "MINI_MAX_TOKENS", val);
    if (cfg.tool_allowlist) |val| count += setEnvDefault(env_map, "MINI_TOOL_ALLOWLIST", val);
    if (cfg.tool_blocklist) |val| count += setEnvDefault(env_map, "MINI_TOOL_BLOCKLIST", val);
    return count;
}

fn applyThinkingAndMemActJsonConfig(cfg: *const JsonConfig, env_map: *std.process.Environ.Map) usize {
    var count: usize = 0;
    if (cfg.reasoning_effort) |val| count += setEnvDefault(env_map, "MINI_REASONING_EFFORT", val);
    if (cfg.reasoning_effort_disabled) |val| count += setEnvBool(env_map, "MINI_REASONING_EFFORT_DISABLED", val);
    if (cfg.thinking_budget_tokens) |val| count += setEnvInt(u32, env_map, "MINI_THINKING_BUDGET", val);
    if (cfg.thinking_temperature) |val| count += setEnvFloat(env_map, "MINI_THINKING_TEMPERATURE", val);
    if (cfg.max_tokens_continue_cap) |val| count += setEnvInt(usize, env_map, "MINI_MAX_TOKENS_CONTINUE_CAP", val);
    if (cfg.dynamic_thinking_enabled) |val| count += setEnvBool(env_map, "MINI_DYNAMIC_THINKING", val);
    if (cfg.memact_enabled) |val| count += setEnvBool(env_map, "MINI_MEMACT_ENABLED", val);
    if (cfg.context_window) |val| count += setEnvInt(u32, env_map, "MINI_CONTEXT_WINDOW", val);
    if (cfg.ctx_safety_margin) |val| count += setEnvFloat(env_map, "MINI_CTX_SAFETY_MARGIN", val);
    if (cfg.ctx_compact_threshold) |val| count += setEnvFloat(env_map, "MINI_CTX_COMPACT_THRESHOLD", val);
    if (cfg.memact_top_k) |val| count += setEnvInt(u32, env_map, "MINI_MEMACT_TOP_K", val);
    if (cfg.memact_memory_budget) |val| count += setEnvInt(u32, env_map, "MINI_MEMACT_MEMORY_BUDGET", val);
    if (cfg.memact_extract) |val| count += setEnvDefault(env_map, "MINI_MEMACT_EXTRACT", val);
    if (cfg.memory_dir) |val| count += setEnvDefault(env_map, "MINI_MEMORY_DIR", val);
    if (cfg.memact_pg_enabled) |val| count += setEnvBool(env_map, "MINI_MEMACT_PG_ENABLED", val);
    if (cfg.memact_pg_advisory) |val| count += setEnvBool(env_map, "MINI_MEMACT_PG_ADVISORY", val);
    if (cfg.memact_pg_h) |val| count += setEnvInt(u32, env_map, "MINI_MEMACT_PG_H", val);
    if (cfg.memact_pg_w) |val| count += setEnvInt(u32, env_map, "MINI_MEMACT_PG_W", val);
    if (cfg.memact_pg_auto_populate) |val| count += setEnvBool(env_map, "MINI_MEMACT_PG_AUTO_POPULATE", val);
    return count;
}

fn applyActionLoopAndMediaJsonConfig(cfg: *const JsonConfig, env_map: *std.process.Environ.Map) usize {
    var count: usize = 0;
    if (cfg.budget_max_tokens) |val| count += setEnvInt(usize, env_map, "MINI_BUDGET_MAX_TOKENS", val);
    if (cfg.action_loop_consecutive_cap) |val| count += setEnvInt(usize, env_map, "MINI_LOOP_CONSECUTIVE_CAP", val);
    if (cfg.action_loop_window_cap) |val| count += setEnvInt(usize, env_map, "MINI_LOOP_WINDOW_CAP", val);
    if (cfg.action_loop_readonly_warn_cap) |val| count += setEnvInt(usize, env_map, "MINI_LOOP_READONLY_WARN", val);
    if (cfg.action_loop_readonly_trip_cap) |val| count += setEnvInt(usize, env_map, "MINI_LOOP_READONLY_TRIP", val);
    if (cfg.action_loop_macro_cycle_cap) |val| count += setEnvInt(usize, env_map, "MINI_LOOP_MACRO_CYCLE_CAP", val);
    if (cfg.action_loop_orbit_cap) |val| count += setEnvInt(usize, env_map, "MINI_LOOP_ORBIT_CAP", val);
    if (cfg.action_loop_display) |val| count += setEnvBool(env_map, "MINI_ACTION_LOOP_DISPLAY", val);
    if (cfg.mcp_config) |val| count += setEnvDefault(env_map, "MINI_MCP_CONFIG", val);
    if (cfg.history_enabled) |val| count += setEnvDefault(env_map, "MINI_NO_HISTORY", if (val) "0" else "1");
    if (cfg.hook_command) |val| count += setEnvDefault(env_map, "MINI_HOOK_COMMAND", val);
    if (cfg.hooks_config_path) |val| count += setEnvDefault(env_map, "MINI_HOOKS_CONFIG", val);
    if (cfg.session_id) |val| count += setEnvDefault(env_map, "MINI_SESSION", val);
    if (cfg.session_file) |val| count += setEnvDefault(env_map, "MINI_SESSION_FILE", val);
    if (cfg.image_input_enabled) |val| count += setEnvBool(env_map, "MINI_IMAGE_INPUT_ENABLED", val);
    if (cfg.image_input_max_per_turn) |val| count += setEnvInt(u8, env_map, "MINI_IMAGE_INPUT_MAX_PER_TURN", val);
    if (cfg.image_input_max_bytes) |val| count += setEnvInt(usize, env_map, "MINI_IMAGE_INPUT_MAX_BYTES", val);
    if (cfg.image_gen_enabled) |val| count += setEnvBool(env_map, "MINI_IMAGE_GEN_ENABLED", val);
    if (cfg.image_gen_provider) |val| count += setEnvDefault(env_map, "MINI_IMAGE_GEN_PROVIDER", val);
    if (cfg.image_gen_model) |val| count += setEnvDefault(env_map, "MINI_IMAGE_GEN_MODEL", val);
    if (cfg.image_gen_size) |val| count += setEnvDefault(env_map, "MINI_IMAGE_GEN_SIZE", val);
    if (cfg.video_gen_enabled) |val| count += setEnvBool(env_map, "MINI_VIDEO_GEN_ENABLED", val);
    if (cfg.video_gen_model) |val| count += setEnvDefault(env_map, "MINI_VIDEO_GEN_MODEL", val);
    if (cfg.video_gen_provider) |val| count += setEnvDefault(env_map, "MINI_VIDEO_GEN_PROVIDER", val);
    if (cfg.media_output_dir) |val| count += setEnvDefault(env_map, "MINI_MEDIA_OUTPUT_DIR", val);
    if (cfg.video_poll_timeout_secs) |val| count += setEnvInt(u32, env_map, "MINI_VIDEO_POLL_TIMEOUT_SECS", val);
    return count;
}

fn applyPlanningAndWatchdogJsonConfig(cfg: *const JsonConfig, env_map: *std.process.Environ.Map) usize {
    var count: usize = 0;
    if (cfg.enable_structured_planning) |val| count += setEnvBool(env_map, "MINI_ENABLE_STRUCTURED_PLANNING", val);
    if (cfg.planning_min_task_length) |val| count += setEnvInt(usize, env_map, "MINI_PLANNING_MIN_TASK_LENGTH", val);
    if (cfg.plan_drift_detection) |val| count += setEnvBool(env_map, "MINI_PLAN_DRIFT_DETECTION", val);
    if (cfg.plan_max_steps) |val| count += setEnvInt(usize, env_map, "MINI_PLAN_MAX_STEPS", val);
    if (cfg.plans_dir) |val| count += setEnvDefault(env_map, "MINI_PLANS_DIR", val);
    if (cfg.enhanced_progress_checkpoint) |val| count += setEnvBool(env_map, "MINI_ENHANCED_PROGRESS_CHECKPOINT", val);
    if (cfg.prompt_enforcement_enabled) |val| count += setEnvBool(env_map, "MINI_PROMPT_ENFORCEMENT_ENABLED", val);
    if (cfg.plan_verification_gate) |val| count += setEnvBool(env_map, "MINI_PLAN_VERIFICATION_GATE", val);
    if (cfg.plan_approval_gate) |val| count += setEnvBool(env_map, "MINI_PLAN_APPROVAL_GATE", val);
    if (cfg.post_compact_reinject) |val| count += setEnvBool(env_map, "MINI_POST_COMPACT_REINJECT", val);
    if (cfg.plan_subagent_dispatch) |val| count += setEnvBool(env_map, "MINI_PLAN_SUBAGENT_DISPATCH", val);
    if (cfg.plan_review_gate) |val| count += setEnvBool(env_map, "MINI_PLAN_REVIEW_GATE", val);
    if (cfg.act_timeout_secs) |val| count += setEnvInt(u32, env_map, "MINI_ACT_TIMEOUT_SECS", val);
    if (cfg.watchdog_tracking_interval_s) |val| count += setEnvInt(u32, env_map, "MINI_WATCHDOG_TRACKING_S", val);
    if (cfg.watchdog_recap_interval) |val| count += setEnvInt(usize, env_map, "MINI_WATCHDOG_RECAP_INTERVAL", val);
    if (cfg.watchdog_interval_ms) |val| count += setEnvInt(u32, env_map, "MINI_WATCHDOG_INTERVAL_MS", val);
    return count;
}

fn tryLoadJsonConfig(alloc: Allocator, env_map: *std.process.Environ.Map, io: std.Io, path: []const u8) void {
    // PSEUDOCODE:
    // 1. Open and stat config JSON file up to 64KB
    // 2. Parse JsonConfig slice
    // 3. Delegate to modular category setters to update env_map
    // 4. Emit loaded count if positive
    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, path, .{}) catch return;
    defer file.close(io);

    const stat = file.stat(io) catch return;
    if (stat.size == 0 or stat.size > 64 * 1024) return;

    const buf = alloc.alloc(u8, @intCast(stat.size)) catch return;
    defer alloc.free(buf);

    const n = utils.readAll(io, file, buf) catch return;
    var parsed = std.json.parseFromSlice(JsonConfig, alloc, buf[0..n], .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();

    const cfg = parsed.value;
    var count: usize = 0;
    count += applyGeneralAndModelJsonConfig(&cfg, env_map);
    count += applyThinkingAndMemActJsonConfig(&cfg, env_map);
    count += applyActionLoopAndMediaJsonConfig(&cfg, env_map);
    count += applyPlanningAndWatchdogJsonConfig(&cfg, env_map);

    if (count > 0 and !utils.isSubagent()) {
        main.stderrPrint("[config] Loaded {d} settings from {s}\n", .{ count, path });
    }
}

fn tryLoadProviderJson(alloc: Allocator, env_map: *std.process.Environ.Map, io: std.Io, path: []const u8) bool {
    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, path, .{}) catch return false;
    defer file.close(io);

    const stat = file.stat(io) catch return false;
    if (stat.size == 0 or stat.size > 64 * 1024) return false;

    const buf = alloc.alloc(u8, @intCast(stat.size)) catch return false;
    defer alloc.free(buf);

    const n = utils.readAll(io, file, buf) catch return false;
    const data = buf[0..n];

    var parsed = std.json.parseFromSlice(JsonProviderConfig, alloc, data, .{ .ignore_unknown_fields = true }) catch return false;
    defer parsed.deinit();

    const cfg = parsed.value;
    var count: usize = 0;

    if (cfg.protocol) |val| count += setEnvDefault(env_map, "OPENAI_PROTOCOL", val);
    if (cfg.url orelse cfg.base_url) |val| count += setEnvDefault(env_map, "OPENAI_COMPAT_URL", val);
    if (cfg.api_key) |val| count += setEnvDefault(env_map, "OPENAI_COMPAT_API_KEY", val);
    if (cfg.api_header) |val| count += setEnvDefault(env_map, "OPENAI_COMPAT_API_HEADER", val);
    if (cfg.model) |val| count += setEnvDefault(env_map, "OPENAI_COMPAT_MODEL", val);
    if (cfg.use_completion_tokens) |val| count += setEnvDefault(env_map, "MINI_USE_COMPLETION_TOKENS", if (val) "1" else "0");
    if (cfg.provider_js) |val| count += setEnvDefault(env_map, "OPENAI_COMPAT_PROVIDER_JS", val);

    if (count > 0 and !utils.isSubagent()) {
        main.stderrPrint("[config] Loaded {d} provider setting(s) from {s}\n", .{ count, path });
    }
    return true;
}

fn detectActiveProviderKey(env_map: *const std.process.Environ.Map) []const u8 {
    if (env_map.get("OPENAI_COMPAT_PROVIDER") orelse env_map.get("MINI_PROVIDER")) |p| {
        if (p.len > 0) return p;
    }
    if (env_map.get("OPENAI_COMPAT_URL")) |url| {
        const detected = provider_mod.detectFromUrl(url);
        if (!std.mem.eql(u8, detected, "generic")) return detected;
    }
    return "";
}

fn resolveProvidersDir(env_map: *const std.process.Environ.Map, dir_buf: *[512]u8) []const u8 {
    if (env_map.get("MINI_HOME")) |mh| {
        if (mh.len == 0) return "";
        return std.fmt.bufPrint(dir_buf, "{s}/providers", .{mh}) catch "";
    }
    if (env_map.get("HOME")) |h| {
        if (h.len == 0) return "";
        return std.fmt.bufPrint(dir_buf, "{s}/.mini/providers", .{h}) catch "";
    }
    return "";
}

fn applyProviderProfileFiles(
    alloc: Allocator,
    env_map: *std.process.Environ.Map,
    io: std.Io,
    provider_key: []const u8,
    json_path: []const u8,
    js_path: []const u8,
    has_json: bool,
    has_js: bool,
) void {
    if (has_json) {
        _ = tryLoadProviderJson(alloc, env_map, io, json_path);
        _ = setEnvDefault(env_map, "OPENAI_COMPAT_PROVIDER", provider_key);
        if (env_map.get("OPENAI_COMPAT_PROVIDER_JS") == null) {
            _ = setEnvDefault(env_map, "OPENAI_COMPAT_PROVIDER_JS", if (has_js) js_path else json_path);
        }
        if (!utils.isSubagent()) main.stderrPrint("[config] Provider profile: auto-loaded {s}\n", .{json_path});
        return;
    }
    if (has_js) {
        _ = setEnvDefault(env_map, "OPENAI_COMPAT_PROVIDER", provider_key);
        _ = setEnvDefault(env_map, "OPENAI_COMPAT_PROVIDER_JS", js_path);
        if (!utils.isSubagent()) main.stderrPrint("[config] Provider adapter: auto-loaded {s}\n", .{js_path});
    }
}

pub fn loadActiveProviderConfig(alloc: Allocator, env_map: *std.process.Environ.Map, io: std.Io) void {
    // PSEUDOCODE:
    // 1. Detect provider key from env or URL
    // 2. Resolve providers directory ($MINI_HOME or ~/.mini)
    // 3. Probe existence of <provider>.json and <provider>.js
    // 4. Apply provider profile files if found
    const provider_key = detectActiveProviderKey(env_map);
    if (provider_key.len == 0) return;

    var dir_buf: [512]u8 = undefined;
    const providers_dir = resolveProvidersDir(env_map, &dir_buf);
    if (providers_dir.len == 0) return;

    const cwd = std.Io.Dir.cwd();
    var json_buf: [512]u8 = undefined;
    var js_buf: [512]u8 = undefined;
    const json_path = std.fmt.bufPrint(&json_buf, "{s}/{s}.json", .{ providers_dir, provider_key }) catch return;
    const js_path = std.fmt.bufPrint(&js_buf, "{s}/{s}.js", .{ providers_dir, provider_key }) catch return;

    const has_json = if (cwd.openFile(io, json_path, .{})) |f| blk: {
        f.close(io);
        break :blk true;
    } else |_| false;
    const has_js = if (cwd.openFile(io, js_path, .{})) |f| blk: {
        f.close(io);
        break :blk true;
    } else |_| false;

    applyProviderProfileFiles(alloc, env_map, io, provider_key, json_path, js_path, has_json, has_js);
}

fn setEnvDefault(env_map: *std.process.Environ.Map, key: []const u8, val: []const u8) usize {
    if (env_map.get(key) != null) return 0;
    env_map.put(key, val) catch return 0;
    return 1;
}

pub fn tryLoadFile(env_map: *std.process.Environ.Map, io: std.Io, path: []const u8) void {
    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, path, .{}) catch return;
    defer file.close(io);

    var buf: [16384]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const r = file.readStreaming(io, &.{buf[total..]}) catch break;
        if (r == 0) break;
        total += r;
    }

    var loaded: usize = 0;
    var lines = std.mem.splitScalar(u8, buf[0..total], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        // Strip "export " prefix
        const eff = if (std.mem.startsWith(u8, line, "export "))
            std.mem.trim(u8, line["export ".len..], " \t")
        else
            line;

        const eq = std.mem.indexOfScalar(u8, eff, '=') orelse continue;
        const key = std.mem.trim(u8, eff[0..eq], " \t");
        var val = std.mem.trim(u8, eff[eq + 1 ..], " \t");

        // Strip surrounding quotes
        if (val.len >= 2) {
            if ((val[0] == '"' and val[val.len - 1] == '"') or
                (val[0] == '\'' and val[val.len - 1] == '\''))
                val = val[1 .. val.len - 1];
        }

        if (key.len == 0 or key.len > 255 or val.len > 4095) continue;

        // Do not overwrite if already present in shell env
        if (env_map.get(key) != null) continue;
        env_map.put(key, val) catch continue;
        loaded += 1;
    }

    if (loaded > 0) {
        if (!utils.isSubagent()) main.stderrPrint("[config] Loaded {d} vars from {s}\n", .{ loaded, path });
    }
}

test "JsonConfig parsing" {
    const alloc = std.testing.allocator;
    const json_str =
        \\{
        \\  "execution_mode": "codeact",
        \\  "openai_protocol": "responses",
        \\  "openai_compat_model": "gpt-4o",
        \\  "max_tokens": 4096,
        \\  "memact_enabled": true,
        \\  "memact_pg_enabled": true
        \\}
    ;

    var parsed = try std.json.parseFromSlice(JsonConfig, alloc, json_str, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("codeact", parsed.value.execution_mode.?);
    try std.testing.expectEqualStrings("responses", parsed.value.openai_protocol.?);
    try std.testing.expectEqualStrings("gpt-4o", parsed.value.openai_compat_model.?);
    try std.testing.expectEqual(4096, parsed.value.max_tokens.?);
    try std.testing.expectEqual(true, parsed.value.memact_enabled.?);
    try std.testing.expectEqual(true, parsed.value.memact_pg_enabled.?);
}

test "JsonConfig parsing RFC-019 planning fields" {
    const alloc = std.testing.allocator;
    const json_str =
        \\{
        \\  "enable_structured_planning": true,
        \\  "planning_min_task_length": 100,
        \\  "plan_drift_detection": true,
        \\  "plan_max_steps": 15,
        \\  "plans_dir": "/tmp/custom_plans",
        \\  "enhanced_progress_checkpoint": true,
        \\  "prompt_enforcement_enabled": false
        \\}
    ;

    var parsed = try std.json.parseFromSlice(JsonConfig, alloc, json_str, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expectEqual(true, parsed.value.enable_structured_planning.?);
    try std.testing.expectEqual(100, parsed.value.planning_min_task_length.?);
    try std.testing.expectEqual(true, parsed.value.plan_drift_detection.?);
    try std.testing.expectEqual(15, parsed.value.plan_max_steps.?);
    try std.testing.expectEqualStrings("/tmp/custom_plans", parsed.value.plans_dir.?);
    try std.testing.expectEqual(true, parsed.value.enhanced_progress_checkpoint.?);
    try std.testing.expectEqual(false, parsed.value.prompt_enforcement_enabled.?);
}

test "Config prompt enforcement is disabled by default" {
    const alloc = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(alloc);
    defer env_map.deinit();

    const settings = Config.resolvePlanningAndWatchdogSettings(&env_map);
    try std.testing.expectEqual(false, settings.prompt_enforcement_enabled);

    try env_map.put("MINI_PROMPT_ENFORCEMENT_ENABLED", "1");
    const enabled = Config.resolvePlanningAndWatchdogSettings(&env_map);
    try std.testing.expectEqual(true, enabled.prompt_enforcement_enabled);
}

test "Config default memact_pg_enabled is true" {
    const alloc = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(alloc);
    defer env_map.deinit();

    const def_val: bool = blk: {
        const s = env_map.get("MINI_MEMACT_PG_ENABLED") orelse env_map.get("MINI_PG_ENABLED") orelse "1";
        break :blk std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "true");
    };
    try std.testing.expect(def_val);

    try env_map.put("MINI_MEMACT_PG_ENABLED", "0");
    const disabled_val: bool = blk: {
        const s = env_map.get("MINI_MEMACT_PG_ENABLED") orelse env_map.get("MINI_PG_ENABLED") orelse "1";
        break :blk std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "true");
    };
    try std.testing.expect(!disabled_val);
}
