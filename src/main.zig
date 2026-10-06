//! main.zig — Composition Root of mini-agent.
//!
//! Initializes DI, parses CLI arguments, loads configuration, and coordinates execution modes:
//! - `--acp`: ACP Server Mode (Agent Client Protocol via JSON-RPC 2.0)
//! - `--install-cron`: Linux cronjob installation mode
//! - `-e` / `--single`: Single-shot prompt mode
//! - Default: Interactive REPL terminal mode via `ui/repl.zig`

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const config_mod = @import("core/config.zig");
pub const agent_mod = @import("core/agent.zig");
pub const protocol_mod = @import("core/protocol.zig");
pub const history_mod = @import("core/history.zig");
pub const json_mod = @import("core/json.zig");
pub const backends = struct {
    pub const openai_mod = @import("backends/openai.zig");
    pub const claude_mod = @import("backends/claude.zig");
    pub const ollama_mod = @import("backends/ollama.zig");
    pub const provider_mod = @import("backends/provider.zig");
    pub const js_provider = @import("backends/js_provider.zig");
    pub const thinking_filter_mod = @import("backends/thinking_filter.zig");
};
pub const tools_mod = @import("tooling/registry.zig");
pub const session_diagnostics = @import("tools/session_diagnostics.zig");
pub const act_logger_mod = @import("core/act_logger.zig");
pub const act_queue_mod = @import("core/act_queue.zig");
pub const watchdog_mod = @import("core/watchdog.zig");
pub const mcp_mod = @import("tooling/mcp.zig");
pub const utils = @import("core/utils.zig");
pub const cron_mod = @import("core/cron.zig");
pub const hooks_mod = @import("core/hooks.zig");
pub const artifacts_mod = @import("core/artifacts.zig");
pub const signals_mod = @import("core/signals.zig");
pub const acp_mod = @import("acp/server.zig");
pub const ui_repl = @import("ui/repl.zig");
pub const ui_terminal = @import("ui/terminal.zig");
pub const ui_spinner = @import("ui/spinner.zig");
pub const ui_diff = @import("ui/diff_renderer.zig");
pub const ui_markdown = @import("ui/markdown.zig");
pub const ui_chat_stream = @import("ui/chat_stream.zig");
pub const ui_unicode = @import("ui/unicode.zig");
pub const ui_history = @import("ui/history.zig");
pub const http_request = @import("lib/http_request.zig");
pub const editor_mod = @import("ui/editor.zig");
pub const resetThinkState = ui_repl.resetThinkState;
pub const beginAct = ui_repl.beginAct;
pub const quickjs_engine = @import("runtime/quickjs_engine.zig");
pub const js_bindings = @import("runtime/js_bindings.zig");
pub const process_manager = @import("runtime/process_manager.zig");
pub const graph_mod = @import("lib/graph.zig");
pub const graph_store_mod = @import("core/memact/graph_store.zig");
pub const tokens_mod = @import("core/memact/tokens.zig");
pub const media_lib = @import("lib/media.zig");
pub const media_protocol = @import("core/media_protocol.zig");
pub const media_gen_tool = @import("tools/media_gen.zig");
pub const file_mod = @import("tools/file.zig");
pub const plan_mod = @import("core/plan.zig");
pub const plan_parser_mod = @import("core/plan/parser.zig");
pub const plan_executor_mod = @import("core/plan/executor.zig");
pub const plan_dispatch_mod = @import("core/plan/dispatch.zig");
pub const plan_monitor_mod = @import("core/plan/monitor.zig");
pub const plan_store_mod = @import("core/plan/store.zig");
pub const plan_integration_mod = @import("core/plan/integration.zig");
pub const cas_mod = @import("core/cas.zig");
pub const task_types_mod = @import("core/task/types.zig");
pub const task_store_mod = @import("core/task/store.zig");
pub const task_history_log_mod = @import("core/task/history_log.zig");
pub const task_retention_mod = @import("core/task/retention.zig");
pub const task_root_mod = @import("core/task/root.zig");
pub const task_resume_mod = @import("core/task/resume.zig");

pub const VERSION = "1.0.0";

/// Terminate after managed children and background jobs have been cleaned up.
fn exitAfterProcessCleanup(status: u8) noreturn {
    process_manager.deinitGlobal();
    std.process.exit(status);
}

/// Build info injected at build time (build.zig → options module `build_info`).
/// Changes on each `zig build`, identifying the binary build version.
pub const build_info = @import("build_info");
pub const BUILD_TIME = build_info.build_time;
pub const BUILD_OPTIMIZE = build_info.optimize_mode;
pub const BUILD_TARGET = build_info.target_triple;
pub const ZIG_VERSION = build_info.zig_version;

pub var g_io: std.Io = undefined;
pub var g_environ_map: ?*std.process.Environ.Map = null;

/// Get process environ map (startup snapshot + added variables e.g. from .env).
/// Used to spawn children with the accurate current environment.
pub fn getEnvironMap() ?*std.process.Environ.Map {
    return g_environ_map;
}

/// Get Io instance: automatically uses std.testing.io when running tests (comptime), or g_io at runtime.
pub fn getIo() std.Io {
    if (comptime builtin.is_test) {
        return std.testing.io;
    }
    return g_io;
}

/// In formatted string ra stdout.
pub fn stdoutPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stdout().writer(getIo(), &buf);
    w.interface.print(fmt, args) catch return;
    w.flush() catch {};
}

/// In formatted string ra stderr.
pub fn stderrPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writer(getIo(), &buf);
    w.interface.print(fmt, args) catch return;
    w.flush() catch {};
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

const agent_folder_mod = @import("core/agent/folder.zig");

fn handleHelpOrVersion(args: *const Args) bool {
    if (args.show_help) {
        printHelp();
        return true;
    }
    if (args.show_version) {
        stdoutPrint("mini-agent {s}\nbuild:   {s}\ntarget:  {s} ({s})\nzig:     {s}\n", .{
            VERSION, BUILD_TIME, BUILD_TARGET, BUILD_OPTIMIZE, ZIG_VERSION,
        });
        return true;
    }
    return false;
}

fn setupAgentFolder(alloc: Allocator, io: std.Io, env_map: *std.process.Environ.Map) ?agent_folder_mod.AgentFolder {
    var folder_opt: ?agent_folder_mod.AgentFolder = null;
    if (agent_folder_mod.resolveOrInitAgentFolder(alloc, io, env_map)) |folder| {
        folder_opt = folder;
        env_map.put("MINI_AGENT_FOLDER", folder.path) catch {};
        if (std.fs.path.dirname(folder.path)) |ws_root| {
            env_map.put("MINI_WORKSPACE_ROOT", ws_root) catch {};
        }
    } else |err| {
        stderrPrint("[main] Error finding .agent: {any}\n", .{err});
    }

    if (env_map.get("MINI_WORKSPACE_ROOT") == null) {
        if (env_map.get("PWD")) |pwd| {
            env_map.put("MINI_WORKSPACE_ROOT", pwd) catch {};
        }
    }
    return folder_opt;
}

fn overrideSystemPromptFromFile(alloc: Allocator, io: std.Io, cfg: *config_mod.Config, sfile: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, sfile, .{}) catch |e| {
        stderrPrint("Cannot open system file '{s}': {s}\n", .{ sfile, @errorName(e) });
        exitAfterProcessCleanup(1);
    };
    defer file.close(io);
    const stat = try file.stat(io);
    const buf = try alloc.alloc(u8, @intCast(stat.size));
    const n = try utils.readAll(io, file, buf);
    if (cfg.system_prompt_buf) |old| alloc.free(old);
    cfg.system_prompt_buf = buf;
    cfg.system_prompt = buf[0..n];
}

fn setupConfig(alloc: Allocator, io: std.Io, env_map: *std.process.Environ.Map, args: *const Args) config_mod.Config {
    config_mod.loadDotEnv(alloc, env_map, io);
    if (args.mode) |m| env_map.put("MINI_EXECUTION_MODE", m) catch {};
    var cfg = config_mod.Config.load(alloc, env_map, io) catch |e| {
        stderrPrint("Error loading config: {s}\n", .{@errorName(e)});
        exitAfterProcessCleanup(1);
    };
    if (args.system_file) |sfile| {
        overrideSystemPromptFromFile(alloc, io, &cfg, sfile) catch |e| {
            stderrPrint("Error applying system file: {s}\n", .{@errorName(e)});
            exitAfterProcessCleanup(1);
        };
    }
    cfg.appendCodeActInstructions(alloc);
    if (args.hook_command) |hcmd| cfg.hook_command = hcmd;
    hooks_mod.setHookCommand(cfg.hook_command);
    if (hooks_mod.getHookCommand()) |hcmd| {
        stderrPrint("[main] Hooks: enabled ({s})\n", .{hcmd});
    }
    return cfg;
}

fn setupMcp(io: std.Io, env_map: *std.process.Environ.Map, args: *const Args, cfg: *const config_mod.Config, mcp: *mcp_mod.McpClientManager) void {
    if (args.no_mcp) return;
    mcp.loadFromConfig(env_map, io, args.mcp_config orelse cfg.mcp_config_path);
    tools_mod.setMcpManager(mcp);
    if (mcp.toolCount() > 0) {
        stderrPrint("[main] MCP: {d} tools from {d} server(s)\n", .{ mcp.toolCount(), mcp.servers.items.len });
    }
}

fn handleCronInstallation(alloc: Allocator, io: std.Io, args: *const Args, exe_arg: []const u8) !bool {
    const cron_expr = args.cron orelse return false;
    if (args.prompt == null) {
        stderrPrint("Error: --install-cron requires -e <prompt>\n", .{});
        exitAfterProcessCleanup(1);
    }
    const exe_path = try getAbsoluteExePath(alloc, io, exe_arg);
    defer alloc.free(exe_path);
    cron_mod.installCronjob(alloc, io, cron_expr, exe_path, args.prompt.?) catch |e| {
        if (e == error.AlreadyExists) {
            stdoutPrint("This cronjob already exists on the system!\n", .{});
        } else {
            stderrPrint("Error installing cronjob: {s}\n", .{@errorName(e)});
            exitAfterProcessCleanup(1);
        }
        return true;
    };
    stdoutPrint("Cronjob installed successfully: {s}\n", .{cron_expr});
    return true;
}

fn setupSession(
    alloc: Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    agent: *agent_mod.AgentLoop,
    args: *const Args,
    cfg: *const config_mod.Config,
) !?[]const u8 {
    const session_id_arg = args.session orelse cfg.session_id;
    const session_file_arg = args.session_file orelse cfg.session_file;
    artifacts_mod.setSessionId(session_id_arg);
    const session_path = try resolveSessionPath(alloc, io, env_map, session_id_arg, session_file_arg);

    if (session_path) |spath| {
        stderrPrint("[main] Session: {s}\n", .{spath});
        const cwd = std.Io.Dir.cwd();
        if (cwd.openFile(io, spath, .{})) |f| {
            f.close(io);
            agent.history.restoreFromFile(io, spath) catch |e| {
                stderrPrint("[main] Warning: Error loading session file '{s}': {s}, creating new session.\n", .{ spath, @errorName(e) });
            };
        } else |_| {}
    }
    return session_path;
}

/// Resolves and returns the durable tasks base directory for this project.
fn resolveTaskResumeDir(alloc: Allocator) ?[]u8 {
    return task_resume_mod.resolveTasksBaseDir(alloc) catch null;
}

/// RFC-030 §4.5: restores the full context of a resumable durable task into
/// `agent.history` and injects the interruption note. Returns false when
/// nothing can be resumed (process exits cleanly).
fn setupTaskResume(
    alloc: Allocator,
    io: std.Io,
    agent: *agent_mod.AgentLoop,
    args: *const Args,
) !bool {
    const tasks_base = resolveTaskResumeDir(alloc) orelse return false;
    defer alloc.free(tasks_base);

    var store = task_store_mod.TaskStore.init(alloc, io, tasks_base) catch return false;
    defer store.deinit();

    // Pick the target record: explicit --resume <task_id> or latest resumable.
    var rec: ?task_types_mod.TaskRecord = null;
    if (args.resume_task) |tid| {
        rec = store.readLatest(alloc, io, tid) catch null;
        if (rec == null) {
            stderrPrint("[resume] Task '{s}' not found in {s}/tasks.jsonl\n", .{ tid, tasks_base });
            return false;
        }
        switch (rec.?.status) {
            .running, .completed => {
                stderrPrint("[resume] Task '{s}' is {s} — nothing to resume.\n", .{ tid, @tagName(rec.?.status) });
                rec.?.deinit(alloc);
                return false;
            },
            else => {},
        }
    } else {
        rec = store.readLatestResumable(alloc, io) catch null;
        if (rec == null) {
            stderrPrint("[resume] No resumable task found for this project.\n", .{});
            return false;
        }
    }
    defer rec.?.deinit(alloc);

    // Restore the full history (snapshot + deltas). Ownership of the restored
    // History transfers to the agent (deep-copied below, then freed here).
    const restored = task_resume_mod.restoreTaskHistory(alloc, io, tasks_base, rec.?.task_id) catch |e| {
        stderrPrint("[resume] Failed to restore task '{s}': {s}\n", .{ rec.?.task_id, @errorName(e) });
        return false;
    };
    defer task_history_log_mod.HistoryLog.freeRestored(alloc, restored);

    // Swap agent history to a deep copy of the restored full context (the
    // restored struct is freed by the defer above).
    agent.history.deinit();
    agent.history = history_mod.History{
        .alloc = agent.alloc,
        .msgs = .empty,
        .max_messages = restored.max_messages,
        .last_compaction_act_id = restored.last_compaction_act_id,
    };
    for (restored.messages()) |msg| {
        const content_copy = try history_mod.History.cloneContent(agent.alloc, msg.content);
        try agent.history.msgs.append(agent.alloc, .{
            .role = msg.role,
            .content = content_copy,
            .tier = msg.tier,
        });
    }

    // Baseline for retry-rollback machinery: end of restored prefix.
    agent.act_history_checkpoint = agent.history.len();

    // Interruption note as ephemeral user message (the model sees it first).
    const note = task_resume_mod.buildInterruptionNote(alloc, &rec.?) catch |e| {
        stderrPrint("[resume] Note build failed: {s}\n", .{@errorName(e)});
        return true; // history restored; continue without note
    };
    defer alloc.free(note);
    agent.history.addUser(note) catch {};

    stderrPrint("[resume] Resumed task {s} ({s}) — {d} messages restored.\n", .{ rec.?.task_id, @tagName(rec.?.status), agent.history.len() });
    return true;
}

fn readPromptFile(alloc: Allocator, io: std.Io, prompt_file: []const u8) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, prompt_file, .{}) catch |e| {
        stderrPrint("Cannot open prompt file '{s}': {s}\n", .{ prompt_file, @errorName(e) });
        exitAfterProcessCleanup(1);
    };
    defer file.close(io);
    const stat = try file.stat(io);
    const file_buf = try alloc.alloc(u8, @intCast(stat.size));
    errdefer alloc.free(file_buf);
    const n = try utils.readAll(io, file, file_buf);
    const trimmed = std.mem.trim(u8, file_buf[0..n], " \t\r\n");
    const result = try alloc.dupe(u8, trimmed);
    alloc.free(file_buf);
    return result;
}

fn executeSinglePrompt(alloc: Allocator, io: std.Io, agent: *agent_mod.AgentLoop, prompt: []const u8) !void {
    const expanded = try artifacts_mod.expandArtifactReferences(alloc, io, prompt);
    defer alloc.free(expanded);

    const media_res = if (agent.config.image_input_enabled)
        media_lib.parsePromptImages(alloc, io, expanded, .{
            .max_per_turn = agent.config.image_input_max_per_turn,
            .max_bytes = agent.config.image_input_max_bytes,
        }) catch |err| {
            stderrPrint("Failed to process image attachment: {s}\n", .{@errorName(err)});
            exitAfterProcessCleanup(1);
        }
    else
        media_lib.PromptParseResult{ .clean_text = try alloc.dupe(u8, expanded), .images = try alloc.alloc(protocol_mod.ImageBlock, 0) };
    defer media_res.deinit(alloc);

    var renderer = ui_repl.chat_stream.TurnRenderer.init(alloc, io);
    renderer.parser.thinking_tags = backends.provider_mod.getProfile(agent.config.openai_provider).thinking_tags;
    defer renderer.deinit();
    ui_repl.current_renderer = &renderer;
    defer ui_repl.current_renderer = null;

    renderer.startTurn(media_res.clean_text);
    const start_ms = utils.milliTimestamp();

    var turn_result = try agent.processInputWithImages(media_res.clean_text, media_res.images, ui_repl.printText, ui_repl.printThinkText);
    defer turn_result.deinit(alloc);
    if (signals_mod.isInterrupted() or turn_result.outcome == .cancelled) exitAfterProcessCleanup(130);
    if (turn_result.outcome != .completed) exitAfterProcessCleanup(1);

    const end_ms = utils.milliTimestamp();
    const duration = if (end_ms >= start_ms) @as(u64, @intCast(end_ms - start_ms)) else 0;
    renderer.finishTurn(.{
        .prompt_tokens = agent.token_estimator.estimate(media_res.clean_text),
        .completion_tokens = agent.last_turn_completion_tokens,
        .context_tokens = agent.token_estimator.estimateMessages(agent.history.messages()),
        .max_context_tokens = agent.config.context_window,
        .duration_ms = duration,
        .acts_count = if (agent.last_turn_acts > 0) agent.last_turn_acts else 1,
    });
}

fn dispatchExecution(
    alloc: std.mem.Allocator,
    io: std.Io,
    agent: *agent_mod.AgentLoop,
    cfg: *const config_mod.Config,
    args: *const Args,
) !void {
    if (args.acp) return acp_mod.runServer(alloc, io, agent, cfg);
    if (args.prompt) |prompt| return executeSinglePrompt(alloc, io, agent, prompt);
    if (args.single) |prompt_file| {
        const prompt = try readPromptFile(alloc, io, prompt_file);
        defer alloc.free(prompt);
        return executeSinglePrompt(alloc, io, agent, prompt);
    }
    try ui_repl.runRepl(alloc, io, agent, VERSION);
}

pub fn main(init: std.process.Init) !void {
    // PSEUDOCODE:
    // 1. Convert the native argument vector once.
    // 2. Run hidden managed-process guardians before application initialization.
    // 3. Initialize normal signal handling and application resources otherwise.
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    g_io = init.io;
    g_environ_map = init.environ_map;

    const args_raw = try init.minimal.args.toSlice(alloc);
    defer alloc.free(args_raw);
    if (process_manager.isGuardianInvocation(args_raw)) {
        const exit_code = try process_manager.runGuardian(init.io, args_raw, init.environ_map);
        std.process.exit(exit_code);
    }
    signals_mod.initSignalHandlers();
    defer process_manager.deinitGlobal();
    const args = try parseArgs(args_raw[1..]);
    if (handleHelpOrVersion(&args)) return;

    var agent_folder_opt = setupAgentFolder(alloc, init.io, init.environ_map);
    defer if (agent_folder_opt) |*f| f.deinit();

    var cfg = setupConfig(alloc, init.io, init.environ_map, &args);
    defer cfg.deinit(alloc);

    var mcp = mcp_mod.McpClientManager.init(alloc);
    defer mcp.deinit();
    setupMcp(init.io, init.environ_map, &args, &cfg, &mcp);

    var agent = agent_mod.AgentLoop.init(alloc, init.io, &cfg) catch |e| {
        stderrPrint("Error initializing agent: {s}\n", .{@errorName(e)});
        exitAfterProcessCleanup(1);
    };
    defer agent.deinit();
    if (args.backend) |b| agent.switchBackend(b, null);

    if (try handleCronInstallation(alloc, init.io, &args, args_raw[0])) return;

    // Queue-based terminal rendering (TTY only): a single background writer
    // thread drains every producer's writes (renderer, spinner, watchdog
    // notices) so in-place sections cannot interleave. Non-TTY / ACP pipe
    // mode keeps the direct synchronous stdout path. The defer guarantees the
    // queue is drained on every exit path.
    if (ui_terminal.isStdoutTty()) {
        ui_terminal.startWriter();
        defer ui_terminal.stopWriter();
    }

    const session_path = try setupSession(alloc, init.io, init.environ_map, &agent, &args, &cfg);
    defer if (session_path) |p| alloc.free(p);
    defer if (session_path) |spath| agent.history.backupToFile(init.io, spath) catch |e| {
        stderrPrint("[main] Warning: Unable to save session file: {s}\n", .{@errorName(e)});
    };

    // RFC-030: durable task resume (--resume <task_id> / --continue).
    if (args.resume_task != null or args.continue_task) {
        if (!try setupTaskResume(alloc, init.io, &agent, &args)) return; // nothing to resume → exit
    }

    try dispatchExecution(alloc, init.io, &agent, &cfg, &args);
}

// ---------------------------------------------------------------------------
// Args parsing
// ---------------------------------------------------------------------------

const Args = struct {
    prompt: ?[]const u8 = null,
    single: ?[]const u8 = null,
    system_file: ?[]const u8 = null,
    backend: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    cron: ?[]const u8 = null,
    hook_command: ?[]const u8 = null,
    session: ?[]const u8 = null,
    session_file: ?[]const u8 = null,
    resume_task: ?[]const u8 = null,
    continue_task: bool = false,
    acp: bool = false,
    no_mcp: bool = false,
    mcp_config: ?[]const u8 = null,
    show_help: bool = false,
    show_version: bool = false,
};

fn parseArgs(args: []const []const u8) !Args {
    var result = Args{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--exec")) {
            i += 1;
            if (i < args.len) result.prompt = args[i];
        } else if (std.mem.eql(u8, arg, "--single")) {
            i += 1;
            if (i < args.len) result.single = args[i];
        } else if (std.mem.eql(u8, arg, "--system")) {
            i += 1;
            if (i < args.len) result.system_file = args[i];
        } else if (std.mem.eql(u8, arg, "--mode") or std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i < args.len) result.mode = args[i];
        } else if (std.mem.eql(u8, arg, "--install-cron")) {
            i += 1;
            if (i < args.len) result.cron = args[i];
        } else if (std.mem.eql(u8, arg, "--model")) {
            i += 1;
            if (i < args.len) result.backend = args[i];
        } else if (std.mem.eql(u8, arg, "--hook-command") or std.mem.eql(u8, arg, "--prehook")) {
            i += 1;
            if (i < args.len) result.hook_command = args[i];
        } else if (std.mem.eql(u8, arg, "--session")) {
            i += 1;
            if (i < args.len) result.session = args[i];
        } else if (std.mem.eql(u8, arg, "--session-file")) {
            i += 1;
            if (i < args.len) result.session_file = args[i];
        } else if (std.mem.eql(u8, arg, "--resume")) {
            i += 1;
            if (i < args.len) result.resume_task = args[i];
        } else if (std.mem.eql(u8, arg, "--continue")) {
            result.continue_task = true;
        } else if (std.mem.eql(u8, arg, "--acp") or std.mem.eql(u8, arg, "acp")) {
            result.acp = true;
        } else if (std.mem.eql(u8, arg, "--no-mcp")) {
            result.no_mcp = true;
        } else if (std.mem.eql(u8, arg, "--mcp-config")) {
            i += 1;
            if (i < args.len) result.mcp_config = args[i];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            result.show_help = true;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            result.show_version = true;
        } else if (arg.len > 0 and arg[0] != '-' and result.prompt == null) {
            result.prompt = arg;
        }
    }
    return result;
}

fn resolveSessionPath(alloc: Allocator, io: std.Io, env_map: *const std.process.Environ.Map, session_id: ?[]const u8, session_file: ?[]const u8) !?[]u8 {
    if (session_file) |sf| {
        if (sf.len > 0) return @as(?[]u8, try alloc.dupe(u8, sf));
    }
    if (session_id) |sid| {
        if (sid.len == 0) return null;
        if (std.mem.indexOfScalar(u8, sid, '/') != null or std.mem.endsWith(u8, sid, ".json")) {
            return @as(?[]u8, try alloc.dupe(u8, sid));
        }
        const dir_path = if (env_map.get("MINI_HOME")) |mh| blk: {
            if (mh.len > 0) break :blk try std.fmt.allocPrint(alloc, "{s}/sessions", .{mh});
            const home = env_map.get("HOME") orelse ".";
            break :blk try std.fmt.allocPrint(alloc, "{s}/.mini/sessions", .{home});
        } else blk: {
            const home = env_map.get("HOME") orelse ".";
            break :blk try std.fmt.allocPrint(alloc, "{s}/.mini/sessions", .{home});
        };
        defer alloc.free(dir_path);

        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(io, dir_path) catch {};

        return @as(?[]u8, try std.fmt.allocPrint(alloc, "{s}/{s}.json", .{ dir_path, sid }));
    }
    return null;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn getAbsoluteExePath(alloc: Allocator, io: std.Io, arg0: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, arg0, "/")) {
        return alloc.dupe(u8, arg0);
    }
    const argv = [_][]const u8{ "realpath", arg0 };
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdout = .pipe,
        .stderr = .ignore,
        .stdin = .ignore,
    });

    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(alloc);

    if (child.stdout) |out| {
        var chunk: [1024]u8 = undefined;
        while (true) {
            const n = out.readStreaming(io, &.{&chunk}) catch break;
            if (n == 0) break;
            try buf.appendSlice(alloc, chunk[0..n]);
        }
    }

    _ = child.wait(io) catch {};
    return alloc.dupe(u8, std.mem.trim(u8, buf.items, " \t\r\n"));
}

// ---------------------------------------------------------------------------
// Help text
// ---------------------------------------------------------------------------

fn printHelp() void {
    std.Io.File.stdout().writeStreamingAll(g_io,
        \\mini-agent — Terminal AI agent
        \\
        \\USAGE:
        \\  mini-agent [options]
        \\
        \\OPTIONS:
        \\  -e, --exec <prompt>    Run single-shot and exit
        \\  --system <file>        Use file as system prompt
        \\  -m, --mode <mode>      Execution mode: codeact (CodeAct JS engine), tools (JSON), auto
        \\  --session <id>         Auto load/save session at ~/.mini/sessions/<id>.json
        \\  --resume <task_id>     Resume an interrupted durable task (full context)
        \\  --continue             Resume the most recent resumable task
        \\  --session-file <path>  Specify direct JSON session file path
        \\  --acp                  Run in ACP server mode (Agent Client Protocol over stdin/stdout)
        \\  --install-cron <expr>  Create automated Linux cronjob (requires -e)
        \\  --model <backend>      Select backend: openai, claude, ollama
        \\  --hook-command <cmd>   Prehook / monitoring hook command executed before/after actions
        \\  --no-mcp               Do not connect to MCP servers
        \\  --mcp-config <path>    Path to mcp.json file (overrides MINI_MCP_CONFIG)
        \\  --version, -v          Print version
        \\  --help, -h             Print this help guide
        \\
        \\EXAMPLES:
        \\  mini-agent -e "Summarize README.md"
        \\  mini-agent --session test-sess -e "My name is Alice."
        \\  mini-agent --session test-sess -e "What is my name?"
        \\  mini-agent --system prompt.md
        \\  mini-agent --model claude
        \\  mini-agent --hook-command 'echo "[HOOK] $MINI_HOOK_EVENT tool=$MINI_TOOL_NAME"'
        \\  MINI_TOOL_BLOCKLIST=bash mini-agent
        \\
        \\CONFIGURATION (.env or environment variables):
        \\  MINI_HOME              Root directory for config & sessions (default: ~/.mini)
        \\  OPENAI_COMPAT_URL      OpenAI-compatible URL
        \\  OPENAI_COMPAT_MODEL    Model name
        \\  OPENAI_COMPAT_API_HEADER Header name (default: Authorization)
        \\  ANTHROPIC_API_KEY      Claude API key
        \\  OLLAMA_HOST            Ollama URL (default: localhost:11434)
        \\  MINI_SYSTEM_FILE       System prompt file
        \\  MINI_SESSION           Session ID (stored at <MINI_HOME>/sessions/<id>.json)
        \\  MINI_SESSION_FILE      Path to session JSON file
        \\  MINI_HOOK_COMMAND      Global monitoring hook command (pre-tool-use, pre-prompt, MCP...)
        \\  MINI_TOOL_ALLOWLIST    Allow only these tools (comma-separated)
        \\  MINI_TOOL_BLOCKLIST    Block these tools (comma-separated)
        \\  MINI_MCP_CONFIG        Path to mcp.json (default: <MINI_HOME>/mcp.json)
        \\  MINI_ACTION_LOOP_DISPLAY  Show action-loop messages ("0" to suppress)
        \\  MINI_ACT_TIMEOUT_SECS  Per-act LLM timeout in seconds (default: 120)
        \\  MINI_WATCHDOG_INTERVAL_MS Watchdog poll interval in ms (default: 200)
        \\  MINI_ENABLE_STRUCTURED_PLANNING  LLM-driven planning ("0" to disable)
        \\  MINI_PLAN_MAX_STEPS    Max plan steps per task (default: 20)
        \\  MINI_IMAGE_GEN_ENABLED Enable generate_image tool ("1" to enable)
        \\  MINI_IMAGE_GEN_MODEL   Image generation model
        \\  MINI_VIDEO_GEN_ENABLED Enable generate_video tool ("1" to enable)
        \\  MINI_VIDEO_GEN_MODEL   Video generation model
        \\  MINI_VIDEO_GEN_PROVIDER  Video gen provider: openai|openai_compat|agnes
        \\  MINI_MEDIA_OUTPUT_DIR  Media output directory
        \\
    ) catch {};
}

test {
    _ = @import("core/artifacts.zig");
    _ = @import("core/agent.zig");
    _ = @import("core/agent/step.zig");
    _ = @import("core/agent/turn.zig");
    _ = @import("core/agent/execution.zig");
    _ = @import("core/agent/subagent.zig");
    _ = @import("core/agent/loop_monitor.zig");
    _ = @import("core/agent/parsing.zig");
    _ = @import("core/agent/backend.zig");
    _ = @import("core/agent/folder.zig");
    _ = @import("core/history.zig");
    _ = @import("core/history/types.zig");
    _ = @import("core/history/append.zig");
    _ = @import("core/history/compact.zig");
    _ = @import("core/history/compat.zig");
    _ = @import("core/history/backup.zig");
    _ = @import("backends/openai.zig");
    _ = @import("core/journal.zig");
    _ = @import("core/protocol.zig");
    _ = @import("core/json.zig");
    _ = @import("core/config.zig");
    _ = @import("core/config/types.zig");
    _ = @import("core/config/workspace.zig");
    _ = @import("core/config/dotenv.zig");
    _ = @import("core/config/resolvers.zig");
    _ = @import("core/memact/tokens.zig");
    _ = @import("core/memact/store.zig");
    _ = @import("core/memact/graph_store.zig");
    _ = @import("core/memact/bm25.zig");
    _ = @import("tooling/registry.zig");
    _ = @import("lib/http_request.zig");
    _ = @import("lib/graph.zig");
    _ = @import("tools/bash.zig");
    _ = @import("acp/server.zig");
    _ = @import("ui/unicode.zig");
    _ = @import("ui/history.zig");
    _ = @import("ui/editor.zig");
    _ = @import("ui/paste.zig");
    _ = @import("ui/terminal.zig");
    _ = @import("ui/spinner.zig");
    _ = @import("ui/diff_renderer.zig");
    _ = @import("ui/markdown.zig");
    _ = @import("core/act_queue.zig");
    _ = @import("core/watchdog.zig");
    _ = quickjs_engine;
    _ = js_bindings;
    _ = process_manager;
    _ = plan_mod;
    _ = plan_parser_mod;
    _ = plan_executor_mod;
    _ = plan_dispatch_mod;
    _ = plan_monitor_mod;
    _ = plan_store_mod;
    _ = plan_integration_mod;
    _ = cas_mod;
    _ = task_types_mod;
    _ = task_store_mod;
    _ = task_history_log_mod;
    _ = task_retention_mod;
    _ = task_root_mod;
}
