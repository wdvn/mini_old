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
};
pub const tools_mod = @import("tooling/registry.zig");
pub const session_diagnostics = @import("tools/session_diagnostics.zig");
pub const act_logger_mod = @import("core/act_logger.zig");
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
pub const editor_mod = @import("ui/editor.zig");
pub const resetThinkState = ui_repl.resetThinkState;
pub const quickjs_engine = @import("runtime/quickjs_engine.zig");
pub const js_bindings = @import("runtime/js_bindings.zig");
pub const process_manager = @import("runtime/process_manager.zig");
pub const graph_mod = @import("lib/graph.zig");

pub const VERSION = "1.0.0";

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

pub fn main(init: std.process.Init) !void {
    signals_mod.initSignalHandlers();
    g_io = init.io;
    g_environ_map = init.environ_map;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Parse CLI args
    const args_raw = try init.minimal.args.toSlice(alloc);
    defer alloc.free(args_raw);
    const args = try parseArgs(args_raw[1..]);

    if (args.show_help) {
        printHelp();
        return;
    }
    if (args.show_version) {
        stdoutPrint("mini-agent {s}\nbuild:   {s}\ntarget:  {s} ({s})\nzig:     {s}\n", .{
            VERSION, BUILD_TIME, BUILD_TARGET, BUILD_OPTIMIZE, ZIG_VERSION,
        });
        return;
    }

    // Init Agent Folder
    const agent_folder_mod = @import("core/agent_folder.zig");
    var agent_folder_opt: ?agent_folder_mod.AgentFolder = null;
    if (agent_folder_mod.resolveOrInitAgentFolder(alloc, init.io, init.environ_map)) |folder| {
        agent_folder_opt = folder;
        init.environ_map.put("MINI_AGENT_FOLDER", folder.path) catch {};
    } else |err| {
        stderrPrint("[main] Error finding .agent: {any}\n", .{err});
    }
    defer if (agent_folder_opt) |*f| f.deinit();

    // Load environment variables from .env and config.json
    config_mod.loadDotEnv(alloc, init.environ_map, init.io);

    // Load Config
    var cfg = config_mod.Config.load(alloc, init.environ_map, init.io) catch |e| {
        stderrPrint("Error loading config: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    defer cfg.deinit(alloc);

    // Override system prompt from CLI
    if (args.system_file) |sfile| {
        const cwd = std.Io.Dir.cwd();
        const file = cwd.openFile(init.io, sfile, .{}) catch |e| {
            stderrPrint("Cannot open system file '{s}': {s}\n", .{ sfile, @errorName(e) });
            std.process.exit(1);
        };
        defer file.close(init.io);
        const stat = try file.stat(init.io);
        const buf = try alloc.alloc(u8, @intCast(stat.size));
        const n = try utils.readAll(init.io, file, buf);
        if (cfg.system_prompt_buf) |old| alloc.free(old);
        cfg.system_prompt_buf = buf;
        cfg.system_prompt = buf[0..n];
    }

    // Override execution mode from CLI
    if (args.mode) |m| cfg.execution_mode = config_mod.ExecutionMode.fromString(m);

    // Hooks setup
    if (args.hook_command) |hcmd| cfg.hook_command = hcmd;
    hooks_mod.setHookCommand(cfg.hook_command);
    if (hooks_mod.getHookCommand()) |hcmd| {
        stderrPrint("[main] Hooks: enabled ({s})\n", .{hcmd});
    }

    // MCP setup
    var mcp = mcp_mod.McpClientManager.init(alloc);
    defer mcp.deinit();
    if (!args.no_mcp) {
        mcp.loadFromConfig(init.environ_map, init.io, args.mcp_config orelse cfg.mcp_config_path);
        tools_mod.setMcpManager(&mcp);
        if (mcp.toolCount() > 0) {
            stderrPrint("[main] MCP: {d} tools from {d} server(s)\n", .{ mcp.toolCount(), mcp.servers.items.len });
        }
    }

    // Initialize AgentLoop
    var agent = agent_mod.AgentLoop.init(alloc, init.io, &cfg) catch |e| {
        stderrPrint("Error initializing agent: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    defer agent.deinit();

    // Override backend from CLI
    if (args.backend) |b| agent.switchBackend(b, null);

    // Install cronjob
    if (args.cron) |cron_expr| {
        if (args.prompt == null) {
            stderrPrint("Error: --install-cron requires -e <prompt>\n", .{});
            std.process.exit(1);
        }
        
        const exe_path = try getAbsoluteExePath(alloc, init.io, args_raw[0]);
        defer alloc.free(exe_path);
        
        cron_mod.installCronjob(alloc, init.io, cron_expr, exe_path, args.prompt.?) catch |e| {
            if (e == error.AlreadyExists) {
                stdoutPrint("This cronjob already exists on the system!\n", .{});
            } else {
                stderrPrint("Error installing cronjob: {s}\n", .{@errorName(e)});
                std.process.exit(1);
            }
            return;
        };
        stdoutPrint("Cronjob installed successfully: {s}\n", .{cron_expr});
        return;
    }

    // Session setup & restore
    const session_id_arg = args.session orelse cfg.session_id;
    const session_file_arg = args.session_file orelse cfg.session_file;
    artifacts_mod.setSessionId(session_id_arg);
    const session_path = try resolveSessionPath(alloc, init.io, init.environ_map, session_id_arg, session_file_arg);
    defer if (session_path) |p| alloc.free(p);

    if (session_path) |spath| {
        stderrPrint("[main] Session: {s}\n", .{spath});
        const cwd = std.Io.Dir.cwd();
        if (cwd.openFile(init.io, spath, .{})) |f| {
            f.close(init.io);
            agent.history.restoreFromFile(init.io, spath) catch |e| {
                stderrPrint("[main] Warning: Error loading session file '{s}': {s}, creating new session.\n", .{ spath, @errorName(e) });
            };
        } else |_| {}
    }

    // Automatically save session on exit
    defer {
        if (session_path) |spath| {
            agent.history.backupToFile(init.io, spath) catch |e| {
                stderrPrint("[main] Warning: Unable to save session file: {s}\n", .{@errorName(e)});
            };
        }
    }

    // 1. ACP Server Mode (Agent Client Protocol over stdin/stdout)
    if (args.acp) {
        try acp_mod.runServer(alloc, init.io, &agent, &cfg);
        return;
    }

    // 2. Single-shot prompt mode
    if (args.prompt) |prompt| {
        const expanded = try artifacts_mod.expandArtifactReferences(alloc, init.io, prompt);
        defer alloc.free(expanded);

        var renderer = ui_repl.chat_stream.TurnRenderer.init(alloc, init.io);
        defer renderer.deinit();
        ui_repl.current_renderer = &renderer;
        defer ui_repl.current_renderer = null;

        renderer.startTurn(expanded);
        const start_ms = utils.milliTimestamp();

        try agent.processInput(expanded, ui_repl.printText, ui_repl.printThinkText);

        if (signals_mod.isInterrupted()) {
            std.process.exit(130);
        }

        const end_ms = utils.milliTimestamp();
        const duration = if (end_ms >= start_ms) @as(u64, @intCast(end_ms - start_ms)) else 0;
        const ctx_tokens = agent.token_estimator.estimateMessages(agent.history.messages());

        renderer.finishTurn(.{
            .prompt_tokens = agent.token_estimator.estimate(expanded),
            .completion_tokens = 0,
            .context_tokens = ctx_tokens,
            .max_context_tokens = 128 * 1024,
            .duration_ms = duration,
            .acts_count = 1,
        });
        return;
    }

    // 3. Single-shot prompt from file
    if (args.single) |prompt_file| {
        const cwd = std.Io.Dir.cwd();
        const file = cwd.openFile(init.io, prompt_file, .{}) catch |e| {
            stderrPrint("Cannot open prompt file '{s}': {s}\n", .{ prompt_file, @errorName(e) });
            std.process.exit(1);
        };
        defer file.close(init.io);
        const stat = try file.stat(init.io);
        const file_buf = try alloc.alloc(u8, @intCast(stat.size));
        defer alloc.free(file_buf);
        const n = try utils.readAll(init.io, file, file_buf);
        const file_prompt = std.mem.trim(u8, file_buf[0..n], " \t\r\n");
        const expanded = try artifacts_mod.expandArtifactReferences(alloc, init.io, file_prompt);
        defer alloc.free(expanded);

        var renderer = ui_repl.chat_stream.TurnRenderer.init(alloc, init.io);
        ui_repl.current_renderer = &renderer;
        defer ui_repl.current_renderer = null;

        renderer.startTurn(expanded);
        const start_ms = utils.milliTimestamp();

        try agent.processInput(expanded, ui_repl.printText, ui_repl.printThinkText);

        if (signals_mod.isInterrupted()) {
            std.process.exit(130);
        }

        const end_ms = utils.milliTimestamp();
        const duration = if (end_ms >= start_ms) @as(u64, @intCast(end_ms - start_ms)) else 0;
        const ctx_tokens = agent.token_estimator.estimateMessages(agent.history.messages());

        renderer.finishTurn(.{
            .prompt_tokens = agent.token_estimator.estimate(expanded),
            .completion_tokens = 0,
            .context_tokens = ctx_tokens,
            .max_context_tokens = 128 * 1024,
            .duration_ms = duration,
            .acts_count = 1,
        });
        return;
    }

    // 4. Interactive REPL mode
    try ui_repl.runRepl(alloc, init.io, &agent, VERSION);
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
    const argv = [_][]const u8{"realpath", arg0};
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
        \\
    ) catch {};
}

test {
    _ = @import("core/artifacts.zig");
    _ = @import("core/agent.zig");
    _ = @import("core/history.zig");
    _ = @import("core/journal.zig");
    _ = @import("core/protocol.zig");
    _ = @import("core/json.zig");
    _ = @import("core/config.zig");
    _ = @import("core/memact/tokens.zig");
    _ = @import("core/memact/store.zig");
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
    _ = @import("ui/chat_stream.zig");
    _ = quickjs_engine;
    _ = js_bindings;
    _ = process_manager;
}

