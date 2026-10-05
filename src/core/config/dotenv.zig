//! config/dotenv.zig — Environment file (.env, config.json) and provider profile loader.

const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("../utils.zig");
const main = @import("../../main.zig");
const provider_mod = @import("../../backends/provider.zig");
const types_mod = @import("types.zig");
const JsonConfig = types_mod.JsonConfig;
const JsonProviderConfig = types_mod.JsonProviderConfig;

/// Loads environment variables from .env files in priority order:
///   1. $MINI_ENV_FILE — explicit path
///   2. ./.env         — current directory
///   3. .agent/.env    — agent directory
///   4. ~/.mini/.env   — user-level
pub fn loadDotEnvFiles(env_map: *std.process.Environ.Map, io: std.Io, home: ?[]const u8) void {
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

pub fn loadJsonConfigFiles(alloc: Allocator, env_map: *std.process.Environ.Map, io: std.Io, home: ?[]const u8) void {
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

pub fn setEnvInt(comptime T: type, env_map: *std.process.Environ.Map, key: []const u8, val: T) usize {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{val}) catch return 0;
    return setEnvDefault(env_map, key, s);
}

pub fn setEnvFloat(env_map: *std.process.Environ.Map, key: []const u8, val: f64) usize {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d:.4}", .{val}) catch return 0;
    return setEnvDefault(env_map, key, s);
}

pub fn setEnvBool(env_map: *std.process.Environ.Map, key: []const u8, val: bool) usize {
    return setEnvDefault(env_map, key, if (val) "1" else "0");
}

pub fn setEnvDefault(env_map: *std.process.Environ.Map, key: []const u8, val: []const u8) usize {
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

pub fn applyGeneralAndModelJsonConfig(cfg: *const JsonConfig, env_map: *std.process.Environ.Map) usize {
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
    if (cfg.deferred_tool_loading) |val| count += setEnvBool(env_map, "MINI_DEFERRED_TOOLS", val);
    return count;
}

pub fn applyThinkingAndMemActJsonConfig(cfg: *const JsonConfig, env_map: *std.process.Environ.Map) usize {
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
    if (cfg.memact_expansion) |val| count += setEnvBool(env_map, "MINI_MEMACT_EXPANSION", val);
    if (cfg.memory_dir) |val| count += setEnvDefault(env_map, "MINI_MEMORY_DIR", val);
    if (cfg.memact_pg_enabled) |val| count += setEnvBool(env_map, "MINI_MEMACT_PG_ENABLED", val);
    if (cfg.memact_pg_advisory) |val| count += setEnvBool(env_map, "MINI_MEMACT_PG_ADVISORY", val);
    if (cfg.memact_pg_h) |val| count += setEnvInt(u32, env_map, "MINI_MEMACT_PG_H", val);
    if (cfg.memact_pg_w) |val| count += setEnvInt(u32, env_map, "MINI_MEMACT_PG_W", val);
    if (cfg.memact_pg_auto_populate) |val| count += setEnvBool(env_map, "MINI_MEMACT_PG_AUTO_POPULATE", val);
    return count;
}

pub fn applyActionLoopAndMediaJsonConfig(cfg: *const JsonConfig, env_map: *std.process.Environ.Map) usize {
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

pub fn applyPlanningAndWatchdogJsonConfig(cfg: *const JsonConfig, env_map: *std.process.Environ.Map) usize {
    var count: usize = 0;
    if (cfg.enable_structured_planning) |val| count += setEnvBool(env_map, "MINI_ENABLE_STRUCTURED_PLANNING", val);
    if (cfg.plan_drift_detection) |val| count += setEnvBool(env_map, "MINI_PLAN_DRIFT_DETECTION", val);
    if (cfg.plan_max_steps) |val| count += setEnvInt(usize, env_map, "MINI_PLAN_MAX_STEPS", val);
    if (cfg.plans_dir) |val| count += setEnvDefault(env_map, "MINI_PLANS_DIR", val);
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

pub fn tryLoadJsonConfig(alloc: Allocator, env_map: *std.process.Environ.Map, io: std.Io, path: []const u8) void {
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

pub fn tryLoadProviderJson(alloc: Allocator, env_map: *std.process.Environ.Map, io: std.Io, path: []const u8) bool {
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

pub fn detectActiveProviderKey(env_map: *const std.process.Environ.Map) []const u8 {
    if (env_map.get("OPENAI_COMPAT_PROVIDER") orelse env_map.get("MINI_PROVIDER")) |p| {
        if (p.len > 0) return p;
    }
    if (env_map.get("OPENAI_COMPAT_URL")) |url| {
        const detected = provider_mod.detectFromUrl(url);
        if (!std.mem.eql(u8, detected, "generic")) return detected;
    }
    return "";
}

pub fn resolveProvidersDir(env_map: *const std.process.Environ.Map, dir_buf: *[512]u8) []const u8 {
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

pub fn applyProviderProfileFiles(
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
