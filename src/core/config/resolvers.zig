//! config/resolvers.zig — Environment setting resolvers and config assembly.

const std = @import("std");
const Allocator = std.mem.Allocator;
const main = @import("../../main.zig");
const utils = @import("../utils.zig");
const provider_mod = @import("../../backends/provider.zig");
const types_mod = @import("types.zig");
const Config = types_mod.Config;
const ExecutionMode = types_mod.ExecutionMode;
const OpenAiProtocol = types_mod.OpenAiProtocol;
const workspace = @import("workspace.zig");
const SpResult = workspace.SpResult;

pub const BackendSettings = struct {
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

pub fn resolveBackendSettings(env_map: *const std.process.Environ.Map) !BackendSettings {
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

pub const MemActSettings = struct {
    enabled: bool,
    context_window: u32,
    ctx_safety_margin: f32,
    ctx_compact_threshold: f32,
    top_k: u32,
    memory_budget: u32,
    extract: []const u8,
    expansion: bool,
    memory_dir: ?[]const u8,
    pg_enabled: bool,
    pg_advisory: bool,
    pg_h: u32,
    pg_w: u32,
    pg_auto_populate: bool,
};

pub fn resolveMemActSettings(env_map: *const std.process.Environ.Map, openai_url: ?[]const u8, anthropic_key: ?[]const u8) MemActSettings {
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
        .expansion = blk: {
            const s = env_map.get("MINI_MEMACT_EXPANSION") orelse "1";
            break :blk !std.mem.eql(u8, s, "0") and !std.mem.eql(u8, s, "false");
        },
        .memory_dir = env_map.get("MINI_MEMORY_DIR"),
        .pg_enabled = pg_en,
        .pg_advisory = pg_adv,
        .pg_h = if (env_map.get("MINI_MEMACT_PG_H")) |s| std.fmt.parseInt(u32, s, 10) catch 2 else 2,
        .pg_w = if (env_map.get("MINI_MEMACT_PG_W")) |s| std.fmt.parseInt(u32, s, 10) catch 3 else 3,
        .pg_auto_populate = pg_auto,
    };
}

pub const LoopAndExecutionSettings = struct {
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

pub fn resolveLoopAndExecutionSettings(env_map: *const std.process.Environ.Map) LoopAndExecutionSettings {
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

pub const ReasoningAndMediaSettings = struct {
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

pub fn resolveReasoningAndMediaSettings(env_map: *const std.process.Environ.Map, provider_key: []const u8) ReasoningAndMediaSettings {
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
    const default_media_prov = if (is_agnes) "agnes" else "openai";
    const media_prov_env = env_map.get("MINI_MEDIA_PROVIDER");
    const fallback_prov = if (media_prov_env) |mp| (if (mp.len > 0) mp else default_media_prov) else default_media_prov;
    const img_prov = if (env_map.get("MINI_IMAGE_GEN_PROVIDER")) |p| (if (p.len > 0) p else fallback_prov) else fallback_prov;
    const vid_prov = if (env_map.get("MINI_VIDEO_GEN_PROVIDER")) |p| (if (p.len > 0) p else fallback_prov) else fallback_prov;

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
        .video_poll_timeout_secs = if (env_map.get("MINI_VIDEO_POLL_TIMEOUT_SECS")) |s| std.fmt.parseInt(u32, s, 10) catch 300 else 300,
    };
}

pub const PlanningAndWatchdogSettings = struct {
    enable_structured_planning: bool,
    plan_drift_detection: bool,
    plan_max_steps: usize,
    plans_dir: ?[]const u8,
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

pub fn resolvePlanningAndWatchdogSettings(env_map: *const std.process.Environ.Map) PlanningAndWatchdogSettings {
    const act_to: u32 = blk: {
        const s = env_map.get("MINI_ACT_TIMEOUT_SECS") orelse env_map.get("MINI_ACT_TIMEOUT") orelse break :blk 120;
        break :blk std.fmt.parseInt(u32, s, 10) catch 120;
    };
    return .{
        .enable_structured_planning = if (env_map.get("MINI_ENABLE_STRUCTURED_PLANNING")) |v| std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true") else true,
        .plan_drift_detection = if (env_map.get("MINI_PLAN_DRIFT_DETECTION")) |v| std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true") else true,
        .plan_max_steps = if (env_map.get("MINI_PLAN_MAX_STEPS")) |s| std.fmt.parseInt(usize, s, 10) catch 20 else 20,
        .plans_dir = env_map.get("MINI_PLANS_DIR"),
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

pub fn printConfigDiagnostics(env_map: *const std.process.Environ.Map, b: *const BackendSettings, m: *const MemActSettings, r: *const ReasoningAndMediaSettings) void {
    if (utils.isSubagent()) return;
    main.stderrPrint("[config] Env bindings: OPENAI_COMPAT_URL={s}, OPENAI_COMPAT_MODEL={s}, PROVIDER={s}, MINI_HOME={s}\n", .{
        b.openai_url orelse "(null)", b.openai_model, b.openai_provider_key, env_map.get("MINI_HOME") orelse "(null)",
    });
    main.stderrPrint("[config] Build: {s} | {s} | {s} | zig {s}\n", .{
        main.BUILD_TIME, main.BUILD_OPTIMIZE, main.BUILD_TARGET, main.ZIG_VERSION,
    });
    if (m.enabled) {
        const window_src = if (env_map.get("MINI_CONTEXT_WINDOW") != null) "env" else "auto/backend";
        main.stderrPrint("[config] MemAct: window={d} ({s}), top_k={d}, budget={d}, extract={s}, expansion={}\n", .{
            m.context_window, window_src, m.top_k, m.memory_budget, m.extract, m.expansion,
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

pub fn applyBackendAndMemActToConfig(
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
    // Safety valve — MINI_DEFERRED_TOOLS=0 restores legacy eager tool lists.
    cfg.deferred_tool_loading = blk: {
        const v = env_map.get("MINI_DEFERRED_TOOLS") orelse break :blk true;
        break :blk !((std.mem.eql(u8, v, "0")) or std.mem.eql(u8, v, "false"));
    };
    cfg.memact_enabled = m.enabled;
    cfg.context_window = m.context_window;
    cfg.ctx_safety_margin = m.ctx_safety_margin;
    cfg.ctx_compact_threshold = m.ctx_compact_threshold;
    cfg.memact_top_k = m.top_k;
    cfg.memact_memory_budget = m.memory_budget;
    cfg.memact_extract = m.extract;
    cfg.memact_expansion = m.expansion;
    cfg.memory_dir = m.memory_dir;
    cfg.memact_pg_enabled = m.pg_enabled;
    cfg.memact_pg_advisory = m.pg_advisory;
    cfg.memact_pg_h = m.pg_h;
    cfg.memact_pg_w = m.pg_w;
    cfg.memact_pg_auto_populate = m.pg_auto_populate;
}

pub fn applyLoopAndSessionToConfig(
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

pub fn applyReasoningMediaPlanningToConfig(
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
    cfg.plan_drift_detection = p.plan_drift_detection;
    cfg.plan_max_steps = p.plan_max_steps;
    cfg.plans_dir = p.plans_dir;
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
    const sp_result = workspace.loadSystemPrompt(alloc, env_map, io);

    printConfigDiagnostics(env_map, &b, &m, &r);

    var cfg: Config = undefined;
    applyBackendAndMemActToConfig(&cfg, env_map, &b, &m, sp_result);
    applyLoopAndSessionToConfig(&cfg, env_map, &l);
    applyReasoningMediaPlanningToConfig(&cfg, &r, &p);
    cfg.appendCodeActInstructions(alloc);
    return cfg;
}
