//! repl.zig — Interactive Terminal REPL & UI Presentation Layer for mini-agent (RFC-007).
//!
//! Fully decouples the user interface, slash command handlers (/help, /model, /artifact, /clear),
//! and streaming markdown / thinking text from the composition root.

const std = @import("std");
const Allocator = std.mem.Allocator;
const agent_mod = @import("../core/agent.zig");
const artifacts_mod = @import("../core/artifacts.zig");
const editor_mod = @import("editor.zig");
const main = @import("../main.zig");
const utils = @import("../core/utils.zig");
const signals = @import("../core/signals.zig");
const proto = @import("../core/protocol.zig");
const media_lib = @import("../lib/media.zig");
pub const chat_stream = @import("chat_stream.zig");

pub const PROMPT_PREFIX = "\x1b[1;34mYou\x1b[0m > ";

/// Global renderer for current turn (if processing).
/// Mutex protecting current_renderer.
pub var g_renderer_mutex = std.atomic.Mutex.unlocked;
pub var current_renderer: ?*chat_stream.TurnRenderer = null;

fn resolveInputPrompt(
    alloc: Allocator,
    io: std.Io,
    agent: *agent_mod.AgentLoop,
    input: []const u8,
) !?media_lib.PromptParseResult {
    const expanded_input = try artifacts_mod.expandArtifactReferences(alloc, io, input);
    defer alloc.free(expanded_input);

    if (!agent.config.image_input_enabled) {
        return media_lib.PromptParseResult{
            .clean_text = try alloc.dupe(u8, expanded_input),
            .images = try alloc.alloc(proto.ImageBlock, 0),
        };
    }

    return media_lib.parsePromptImages(alloc, io, expanded_input, .{
        .max_per_turn = agent.config.image_input_max_per_turn,
        .max_bytes = agent.config.image_input_max_bytes,
    }) catch |err| {
        main.stdoutPrint("\x1b[31m[media error]\x1b[0m Failed to process image attachment: {s}\n", .{@errorName(err)});
        return null;
    };
}

fn turnStatusLabel(
    buf: []u8,
    outcome: proto.TurnOutcome,
    failure_reason: ?proto.FailureReason,
) ![]const u8 {
    // PSEUDOCODE:
    // 1. Render the terminal outcome using the caller's fixed-size buffer.
    // 2. Append the typed failure cause when the terminal result provides one.
    if (failure_reason) |reason| {
        return std.fmt.bufPrint(buf, "{s}: {s}", .{ @tagName(outcome), @tagName(reason) });
    }
    return std.fmt.bufPrint(buf, "{s}", .{@tagName(outcome)});
}

fn runAgentTurn(
    alloc: Allocator,
    io: std.Io,
    agent: *agent_mod.AgentLoop,
    clean_text: []const u8,
    images: []const proto.ImageBlock,
) void {
    var renderer = chat_stream.TurnRenderer.init(alloc, io);
    renderer.parser.thinking_tags = main.backends.provider_mod.getProfile(agent.config.openai_provider).thinking_tags;
    defer renderer.deinit();

    while (!g_renderer_mutex.tryLock()) {
        if (signals.isInterrupted()) return;
    }
    current_renderer = &renderer;
    g_renderer_mutex.unlock();
    var interrupted = false;
    defer {
        while (!g_renderer_mutex.tryLock()) {
            if (signals.isInterrupted()) {
                interrupted = true;
                break;
            }
        }
        if (!interrupted) {
            current_renderer = null;
            g_renderer_mutex.unlock();
        } else {
            g_renderer_mutex.unlock();
        }
    }

    renderer.startTurn(clean_text);
    const start_ms = utils.milliTimestamp();

    var turn_result = agent.processInputWithImages(clean_text, images, printText, printThinkText) catch |e| {
        if (e != error.Interrupted) {
            main.stdoutPrint("\x1b[31m[error]\x1b[0m {s}\n", .{@errorName(e)});
        }
        return;
    };
    defer turn_result.deinit(agent.alloc);
    if (turn_result.outcome != .completed) {
        var status_buf: [64]u8 = undefined;
        const status = turnStatusLabel(&status_buf, turn_result.outcome, turn_result.failure_reason) catch "failed";
        main.stdoutPrint("\x1b[33m[turn {s}]\x1b[0m\n", .{status});
    }
    if (signals.checkAndResetInterrupted()) return;

    const end_ms = utils.milliTimestamp();
    const duration = if (end_ms >= start_ms) @as(u64, @intCast(end_ms - start_ms)) else 0;
    const ctx_tokens = agent.token_estimator.estimateMessages(agent.history.messages());

    renderer.finishTurn(.{
        .prompt_tokens = agent.token_estimator.estimate(clean_text),
        .completion_tokens = agent.last_turn_completion_tokens,
        .context_tokens = ctx_tokens,
        .max_context_tokens = agent.config.context_window,
        .duration_ms = duration,
        .acts_count = if (agent.last_turn_acts > 0) agent.last_turn_acts else 1,
    });
}

/// Run interactive REPL loop.
pub fn runRepl(alloc: Allocator, io: std.Io, agent: *agent_mod.AgentLoop, version: []const u8) !void {
    signals.initSignalHandlers();
    const stdout = std.Io.File.stdout();

    var line_editor = editor_mod.LineEditor.init(alloc);
    defer line_editor.deinit();

    main.stdoutPrint("\x1b[1;32mmini-agent\x1b[0m {s} \x1b[90m(build {s})\x1b[0m | {s} ({s})\n", .{
        version, main.BUILD_TIME, agent.backend.name(), agent.backend.model(),
    });
    try stdout.writeStreamingAll(io, "Type /help for commands, /quit to exit.\n\n");

    while (true) {
        signals.setInterrupted(false);
        line_editor.last_ctrl_c_ms = 0;
        const line = (try line_editor.readLine(io, PROMPT_PREFIX)) orelse break;
        defer alloc.free(line);

        const input = std.mem.trim(u8, line, " \t");
        if (input.len == 0) continue;

        try line_editor.addHistory(input);

        // Slash commands
        if (input[0] == '/') {
            if (handleSlashCommand(alloc, io, agent, input)) continue else break;
        }

        const media_res = (try resolveInputPrompt(alloc, io, agent, input)) orelse continue;
        defer media_res.deinit(alloc);

        if (media_res.images.len > 0) {
            main.stdoutPrint("\x1b[90m[attached {d} image(s)]\x1b[0m\n", .{media_res.images.len});
        }

        runAgentTurn(alloc, io, agent, media_res.clean_text, media_res.images);
    }

    try stdout.writeStreamingAll(io, "\nGoodbye!\n");
}

fn handleArtifactSlash(alloc: Allocator, io: std.Io, sub_raw: []const u8) void {
    // PSEUDOCODE:
    // 1. Trim sub-command arguments.
    // 2. If empty or "list", list artifacts and print.
    // 3. If "show"/"read"/"view", extract artifact name and print content.
    // 4. If "dir"/"path", resolve and print artifacts directory path.
    const sub = std.mem.trim(u8, sub_raw, " \t");
    if (sub.len == 0 or std.mem.eql(u8, sub, "list")) {
        const list = artifacts_mod.listArtifacts(alloc, io) catch |e| {
            main.stdoutPrint("Error reading artifacts list: {s}\n", .{@errorName(e)});
            return;
        };
        defer alloc.free(list);
        main.stdoutPrint("{s}\n", .{list});
        return;
    }
    if (std.mem.startsWith(u8, sub, "show ") or std.mem.startsWith(u8, sub, "read ") or std.mem.startsWith(u8, sub, "view ")) {
        const space = std.mem.indexOfScalar(u8, sub, ' ') orelse sub.len;
        const name = std.mem.trim(u8, sub[space..], " \t");
        const content = artifacts_mod.readArtifact(alloc, io, name) catch |e| {
            main.stdoutPrint("Error reading artifact '{s}': {s}\n", .{ name, @errorName(e) });
            return;
        };
        defer alloc.free(content);
        main.stdoutPrint("\n--- [Artifact: {s}] ---\n{s}\n--- [End of Artifact] ---\n\n", .{ name, content });
        return;
    }
    if (std.mem.eql(u8, sub, "dir") or std.mem.eql(u8, sub, "path")) {
        const dir = artifacts_mod.resolveArtifactsDir(alloc, io) catch |e| {
            main.stdoutPrint("Error resolving artifacts directory: {s}\n", .{@errorName(e)});
            return;
        };
        defer alloc.free(dir);
        main.stdoutPrint("Current Artifacts directory: {s}\n", .{dir});
        return;
    }
    main.stdoutPrint("Usage: /artifact [list | show <name> | path]\n", .{});
}

fn handleProviderSlash(agent: *agent_mod.AgentLoop, key_raw: []const u8) void {
    // PSEUDOCODE:
    // 1. Trim provider key; if empty, print usage.
    // 2. Verify backend is OpenAI-compat; switch provider key.
    // 3. Update current renderer's thinking tags.
    const provider_key = std.mem.trim(u8, key_raw, " \t");
    if (provider_key.len == 0) {
        main.stdoutPrint("Usage: /provider <key>\n  Available: openai, deepseek, qwen, minimax, glm, kimi, xai, vllm, agnes, generic\n", .{});
        return;
    }
    switch (agent.backend) {
        .openai => |*c| c.provider_key = provider_key,
        else => {
            main.stdoutPrint("Provider switch only works with OpenAI-compatible backend.\n", .{});
            return;
        },
    }
    while (!g_renderer_mutex.tryLock()) {
        if (signals.isInterrupted()) return;
    }
    const r = current_renderer;
    g_renderer_mutex.unlock();
    if (r) |renderer| {
        renderer.parser.thinking_tags = main.backends.provider_mod.getProfile(provider_key).thinking_tags;
    }
    main.stdoutPrint("Provider set to: {s}\n", .{provider_key});
}

fn printHelp(io: std.Io) void {
    // PSEUDOCODE:
    // 1. Write REPL help text and tool reference to stdout.
    std.Io.File.stdout().writeStreamingAll(io,
        \\
        \\## REPL Commands
        \\  /clear              Clear conversation history
        \\  /model <backend>    Switch backend (openai, claude, ollama)
        \\  /provider <key>     Switch OpenAI provider profile (openai|deepseek|qwen|minimax|glm|kimi|xai|vllm|agnes|generic)
        \\  /config [show]      Show current configuration
        \\  /config protocol <auto|chat|responses>  Set OpenAI protocol mode
        \\  /config thinking <on|off>               Toggle dynamic thinking governor
        \\  /config reasoning <auto|low|med|high|none> Set reasoning effort
        \\  /plan on/off/status/approve/reject/list  Structured planning control
        \\  /artifact [list]    View session artifacts list
        \\  /artifact show <fn> Read an artifact content
        \\  /terminal-setup     Inspect & configure Shift+Enter / multiline terminal support
        \\  /quit, /exit, /q    Exit
        \\  /help               Show this help guide
        \\
        \\## Artifact References
        \\  Use @artifact:<name> syntax directly in prompts to inject artifact into context.
        \\
        \\## Available Tools
        \\  bash, file_read, file_write, file_edit, artifact_write, artifact_read, artifact_list
        \\  glob, grep, http_request, skills, invoke_subagent, batch_invoke_subagents
        \\
    ) catch {};
}

fn printTerminalSetup(io: std.Io) void {
    // PSEUDOCODE:
    // 1. Write terminal multiline keybindings setup guide to stdout.
    std.Io.File.stdout().writeStreamingAll(io,
        \\
        \\## Terminal Multiline Input Setup & Capabilities
        \\
        \\mini-agent supports 4 distinct ways to insert newlines without submitting:
        \\  1. Shift + Enter:
        \\     - Native in Kitty, Ghostty, WezTerm, Foot, and modern xterm.
        \\     - In VS Code / Cursor: Enabled via Kitty protocol or keybinding:
        \\       "terminal.integrated.enableKittyKeyboardProtocol": true
        \\       Or add to keybindings.json:
        \\       { "key": "shift+enter", "command": "workbench.action.terminal.sendSequence", "args": { "text": "\u001b[13;2u" }, "when": "terminalFocus" }
        \\  2. Alt + Enter / Option + Enter:
        \\     - Instant newline across all terminals (sends ESC+Enter).
        \\  3. Ctrl + J:
        \\     - Standard ASCII linefeed (0x0A), 100% universal across all environments.
        \\  4. Backslash (\) + Enter:
        \\     - Line continuation: type \ at the end of a line and press Enter to continue on the next line.
        \\
    ) catch {};
}

fn handleModelSlash(agent: *agent_mod.AgentLoop, arg_raw: []const u8) void {
    // PSEUDOCODE:
    // 1. Trim model argument string.
    // 2. If whitespace present, split into backend and model name; otherwise pass backend only.
    const backend_arg = std.mem.trim(u8, arg_raw, " \t");
    if (std.mem.indexOfScalar(u8, backend_arg, ' ')) |space| {
        agent.switchBackend(backend_arg[0..space], backend_arg[space + 1 ..]);
    } else {
        agent.switchBackend(backend_arg, null);
    }
}

fn handleConfigSlash(agent: *agent_mod.AgentLoop, io: std.Io, sub_raw: []const u8) void {
    // PSEUDOCODE:
    // 1. Check subcommand: show, help, protocol, thinking, reasoning.
    // 2. Dispatch to appropriate config setter or printer.
    const sub = std.mem.trim(u8, sub_raw, " \t");
    if (sub.len == 0 or std.mem.eql(u8, sub, "show") or std.mem.startsWith(u8, sub, "show ")) {
        printConfig(agent);
    } else if (std.mem.eql(u8, sub, "help")) {
        printConfigHelp(io);
    } else if (std.mem.startsWith(u8, sub, "protocol")) {
        const mode_str = std.mem.trim(u8, sub["protocol".len..], " \t");
        if (mode_str.len > 0) agent.setProtocol(mode_str) else main.stdoutPrint("Usage: /config protocol <auto|chat|responses>\n", .{});
    } else if (std.mem.startsWith(u8, sub, "thinking")) {
        const val_str = std.mem.trim(u8, sub["thinking".len..], " \t");
        if (std.mem.eql(u8, val_str, "on") or std.mem.eql(u8, val_str, "1") or std.mem.eql(u8, val_str, "true")) {
            agent.setDynamicThinking(true);
        } else if (std.mem.eql(u8, val_str, "off") or std.mem.eql(u8, val_str, "0") or std.mem.eql(u8, val_str, "false")) {
            agent.setDynamicThinking(false);
        } else {
            main.stdoutPrint("Usage: /config thinking <on|off>\n", .{});
        }
    } else if (std.mem.startsWith(u8, sub, "reasoning")) {
        const effort_str = std.mem.trim(u8, sub["reasoning".len..], " \t");
        if (effort_str.len > 0) agent.setReasoningEffort(effort_str) else main.stdoutPrint("Usage: /config reasoning <auto|low|medium|high|none>\n", .{});
    } else {
        main.stdoutPrint("Usage: /config [show] | protocol <auto|chat|responses> | thinking <on|off> | reasoning <auto|low|medium|high|none>\n", .{});
    }
}

fn handlePlanSlash(agent: *agent_mod.AgentLoop, sub_raw: []const u8) void {
    // PSEUDOCODE:
    // 1. Trim sub-command.
    // 2. If empty or "status", print current status.
    // 3. If "on", enable structured planning; if "off", disable.
    const sub = std.mem.trim(u8, sub_raw, " \t");
    if (sub.len == 0 or std.mem.eql(u8, sub, "status")) {
        main.stdoutPrint("[plan] Structured planning: {s}\n", .{if (agent.plan.enable_structured_planning) "ON" else "OFF"});
    } else if (std.mem.eql(u8, sub, "on") or std.mem.eql(u8, sub, "true") or std.mem.eql(u8, sub, "1")) {
        agent.plan.enable_structured_planning = true;
        main.stdoutPrint("[plan] Structured planning enabled.\n", .{});
    } else if (std.mem.eql(u8, sub, "off") or std.mem.eql(u8, sub, "false") or std.mem.eql(u8, sub, "0")) {
        agent.plan.enable_structured_planning = false;
        main.stdoutPrint("[plan] Structured planning disabled.\n", .{});
    } else if (std.mem.eql(u8, sub, "approve") or std.mem.eql(u8, sub, "yes")) {
        if (agent.approvePlan()) {
            main.stdoutPrint("[plan] Plan approved — execution active.\n", .{});
        } else {
            main.stdoutPrint("[plan] No active plan to approve.\n", .{});
        }
    } else if (std.mem.eql(u8, sub, "reject") or std.mem.eql(u8, sub, "no")) {
        if (agent.rejectPlan()) {
            main.stdoutPrint("[plan] Plan rejected.\n", .{});
        } else {
            main.stdoutPrint("[plan] No active plan to reject.\n", .{});
        }
    } else if (std.mem.eql(u8, sub, "list")) {
        _ = agent.plan.listPlans(); // prints summary / error to stderr
    } else {
        main.stdoutPrint("Usage: /plan on | off | status | approve | reject | list\n", .{});
    }
}

/// Process slash command. Returns true to continue, false to exit.
pub fn handleSlashCommand(alloc: Allocator, io: std.Io, agent: *agent_mod.AgentLoop, input: []const u8) bool {
    // PSEUDOCODE:
    // 1. Check for quit/exit command prefixes.
    // 2. Check for clear command.
    // 3. Dispatch to sub-command handlers (artifact, provider, help, terminal, model, config, plan).
    // 4. Fallback to custom slash commands or print invalid command.
    if (std.mem.eql(u8, input, "/quit") or std.mem.eql(u8, input, "/exit") or std.mem.eql(u8, input, "/q")) return false;
    if (std.mem.eql(u8, input, "/clear")) {
        agent.clearHistory();
        std.Io.File.stdout().writeStreamingAll(io, "\x1b[2J\x1b[H[History cleared]\n") catch {};
        return true;
    }
    if (std.mem.startsWith(u8, input, "/artifact")) {
        handleArtifactSlash(alloc, io, input["/artifact".len..]);
        return true;
    }
    if (std.mem.startsWith(u8, input, "/provider ")) {
        handleProviderSlash(agent, input["/provider ".len..]);
        return true;
    }
    if (std.mem.eql(u8, input, "/help")) {
        printHelp(io);
        return true;
    }
    if (std.mem.eql(u8, input, "/terminal-setup") or std.mem.eql(u8, input, "/terminal")) {
        printTerminalSetup(io);
        return true;
    }
    if (std.mem.startsWith(u8, input, "/model ")) {
        handleModelSlash(agent, input["/model ".len..]);
        return true;
    }
    if (std.mem.eql(u8, input, "/config") or std.mem.startsWith(u8, input, "/config ")) {
        handleConfigSlash(agent, io, input["/config".len..]);
        return true;
    }
    if (std.mem.startsWith(u8, input, "/plan")) {
        handlePlanSlash(agent, input["/plan".len..]);
        return true;
    }
    if (tryExecuteCustomSlashCommand(alloc, io, agent, input) catch false) return true;
    main.stdoutPrint("Invalid command: {s}. Type /help to view list.\n", .{input});
    return true;
}

const BackendInfo = struct {
    endpoint: []const u8,
    proto_str: []const u8,
    api_key_status: []const u8,
};

fn getBackendInfo(agent: *agent_mod.AgentLoop, proto_buf: []u8) BackendInfo {
    // PSEUDOCODE:
    // 1. Match agent.backend.
    // 2. Extract endpoint, protocol mode (including auto/negotiated/cached), and api key status.
    switch (agent.backend) {
        .openai => |c| {
            var proto_str: []const u8 = @tagName(c.protocol_mode);
            if (c.cached_protocol) |cached| {
                if (c.protocol_mode == .auto) {
                    proto_str = std.fmt.bufPrint(proto_buf, "auto (negotiated: {s})", .{@tagName(cached)}) catch "auto";
                } else if (cached != c.protocol_mode) {
                    proto_str = std.fmt.bufPrint(proto_buf, "{s} (active: {s})", .{ @tagName(c.protocol_mode), @tagName(cached) }) catch @tagName(c.protocol_mode);
                }
            }
            return .{
                .endpoint = c.base_url,
                .proto_str = proto_str,
                .api_key_status = if (c.api_key.len > 0) "configured" else "none",
            };
        },
        .claude => |c| return .{
            .endpoint = "https://api.anthropic.com/v1",
            .proto_str = "N/A",
            .api_key_status = if (c.api_key.len > 0) "configured" else "none",
        },
        .ollama => |c| return .{
            .endpoint = c.base_url,
            .proto_str = "N/A",
            .api_key_status = "not required",
        },
    }
}

fn getReasoningInfo(agent: *agent_mod.AgentLoop, buf: []u8) []const u8 {
    // PSEUDOCODE:
    // 1. If reasoning_effort_disabled, return "disabled".
    // 2. Otherwise format based on backend (openai last_effort/dynamic, claude thinking budget).
    if (agent.config.reasoning_effort_disabled) return "disabled";
    switch (agent.backend) {
        .openai => |c| {
            if (c.disable_reasoning_effort) return "disabled (endpoint incompatible)";
            if (agent.last_effort) |last| {
                return if (agent.dynamic_thinking)
                    std.fmt.bufPrint(buf, "auto (active: {s})", .{last}) catch "auto"
                else
                    last;
            }
            if (agent.dynamic_thinking) {
                if (agent.config.reasoning_effort) |re| {
                    return std.fmt.bufPrint(buf, "auto (configured: {s})", .{re}) catch "auto";
                }
                return "auto (dynamic)";
            }
            return agent.config.reasoning_effort orelse "none";
        },
        .claude => |c| {
            const budget = c.active_thinking_budget orelse agent.config.thinking_budget_tokens;
            if (budget) |b| {
                return std.fmt.bufPrint(buf, "{d} tokens", .{b}) catch "enabled";
            }
            return "none";
        },
        .ollama => return "none",
    }
}

fn printConfig(agent: *agent_mod.AgentLoop) void {
    // PSEUDOCODE:
    // 1. Format backend protocol and endpoint details.
    // 2. Format reasoning effort string.
    // 3. Print unified configuration summary to stdout.
    var proto_buf: [64]u8 = undefined;
    const be_info = getBackendInfo(agent, &proto_buf);

    var reasoning_buf: [64]u8 = undefined;
    const reasoning_str = getReasoningInfo(agent, &reasoning_buf);

    const dynamic_thinking_str: []const u8 = if (agent.dynamic_thinking) "enabled (Cognitive Governor)" else "disabled";
    const memact_str: []const u8 = if (agent.config.memact_enabled) "enabled" else "disabled";
    const image_gen_str: []const u8 = if (agent.config.image_gen_enabled) agent.config.image_gen_model else "disabled";
    const video_gen_str: []const u8 = if (agent.config.video_gen_enabled) agent.config.video_gen_model else "disabled";

    main.stdoutPrint(
        "\n\x1b[1;36mmini-agent Configuration\x1b[0m\n" ++
            "  \x1b[1mBackend:\x1b[0m          {s}\n" ++
            "  \x1b[1mModel:\x1b[0m            {s}\n" ++
            "  \x1b[1mEndpoint:\x1b[0m         {s}\n" ++
            "  \x1b[1mProtocol:\x1b[0m         {s}\n" ++
            "  \x1b[1mAPI Key:\x1b[0m          {s}\n" ++
            "  \x1b[1mExecution Mode:\x1b[0m   {s}\n" ++
            "  \x1b[1mContext Window:\x1b[0m   {d} tokens\n" ++
            "  \x1b[1mMax Tokens:\x1b[0m       {d} tokens\n" ++
            "  \x1b[1mDynamic Thinking:\x1b[0m {s}\n" ++
            "  \x1b[1mReasoning Effort:\x1b[0m {s}\n" ++
            "  \x1b[1mMemAct:\x1b[0m           {s}\n" ++
            "  \x1b[1mImage Input:\x1b[0m        {s}\n" ++
            "  \x1b[1mImage Gen:\x1b[0m          {s}\n" ++
            "  \x1b[1mVideo Gen:\x1b[0m          {s}\n\n",
        .{
            agent.backend.name(),
            agent.backend.model(),
            be_info.endpoint,
            be_info.proto_str,
            be_info.api_key_status,
            @tagName(agent.config.execution_mode),
            agent.config.context_window,
            agent.config.max_tokens,
            dynamic_thinking_str,
            reasoning_str,
            memact_str,
            if (agent.config.image_input_enabled) "enabled" else "disabled",
            image_gen_str,
            video_gen_str,
        },
    );
}

fn printBasicConfigHelp(io: std.Io) void {
    // PSEUDOCODE:
    // 1. Output AI Backend, Agent Reasoning, and Execution Mode config variables to stdout.
    std.Io.File.stdout().writeStreamingAll(io,
        \\
        \\## /config — Configuration Variables Reference
        \\
        \\### AI Backend
        \\  OPENAI_COMPAT_URL       OpenAI-compatible API endpoint URL (highest priority backend)
        \\  OPENAI_COMPAT_MODEL     Model name for OpenAI-compat endpoint (default: gpt-4o-mini)
        \\  OPENAI_COMPAT_API_KEY   API key for OpenAI-compatible endpoint (optional)
        \\  OPENAI_COMPAT_API_HEADER Header name for API key (default: Authorization)
        \\  OPENAI_COMPAT_PROVIDER  Provider profile key: openai|deepseek|qwen|minimax|glm|kimi|xai|vllm|agnes|generic
        \\  OPENAI_COMPAT_PROVIDER_JS Custom provider JS adapter path
        \\  ANTHROPIC_API_KEY       Anthropic Claude API key
        \\  CLAUDE_MODEL            Claude model ID (default: claude-opus-4-5)
        \\  OLLAMA_HOST             Ollama base URL (default: http://localhost:11434)
        \\  OLLAMA_MODEL            Ollama model name (default: llama3)
        \\
        \\### Agent & Reasoning (RFC-009)
        \\  MINI_MAX_TOKENS                   Max tokens per response (default: 24000)
        \\  MINI_MAX_TOKENS_CONTINUE_CAP      Max consecutive auto-continuations on truncation (default: 3)
        \\  MINI_USE_COMPLETION_TOKENS        Use max_completion_tokens instead of max_tokens ("1"/"0")
        \\  MINI_SYSTEM_FILE                  Path to system prompt .md file
        \\  MINI_DYNAMIC_THINKING             Enable adaptive thinking governor ("0"=off, default: on)
        \\  MINI_REASONING_EFFORT             Static reasoning effort: minimal|low|medium|high|none
        \\  MINI_REASONING_EFFORT_DISABLED    Skip reasoning params for incompatible endpoints ("1"/"0")
        \\  MINI_THINKING_BUDGET              Thinking budget in tokens for Claude (>= 1024)
        \\
        \\### Execution Mode
        \\  MINI_EXECUTION_MODE   Agent execution mode: codeact|tools|auto (default: auto)
        \\  MINI_LOOP_CONSECUTIVE_CAP  Max consecutive identical tool calls (default: 3)
        \\  MINI_LOOP_WINDOW_CAP    Max identical tool calls in sliding window (default: 4)
        \\
    ) catch {};
}

fn printAdvancedConfigHelp(io: std.Io) void {
    // PSEUDOCODE:
    // 1. Output MemAct, Tools, Media I/O, MCP, Hooks, and Budget configuration variables.
    std.Io.File.stdout().writeStreamingAll(io,
        \\
        \\### MemAct (RFC-003) & Procedural Graph (RFC-010)
        \\  MINI_MEMACT_ENABLED          Enable MemAct memory system ("0" to disable)
        \\  MINI_CONTEXT_WINDOW          Context window size in tokens (auto-detected if unset)
        \\  MINI_CTX_SAFETY_MARGIN       Safety margin ratio for context (default: 0.15)
        \\  MINI_CTX_COMPACT_THRESHOLD   History compaction trigger ratio (default: 0.85)
        \\  MINI_MEMACT_TOP_K            Max memory items injected into prompt (default: 8)
        \\  MINI_MEMACT_MEMORY_BUDGET    Token budget for memory block (default: 2000)
        \\  MINI_MEMACT_EXTRACT          Memory extraction mode: async|sync|off (default: async)
        \\  MINI_MEMORY_DIR              Custom memory directory path
        \\  MINI_MEMACT_PG_ENABLED       Enable procedural graph guidance ("0" to disable)
        \\  MINI_MEMACT_PG_H             Neighborhood hop distance (default: 2)
        \\  MINI_MEMACT_PG_W             Recent trajectory window size (default: 3)
        \\  MINI_MEMACT_PG_AUTO_POPULATE Auto-learn frequent tool transitions (default: on)
        \\
        \\### Tools & Media I/O (RFC-011)
        \\  MINI_TOOL_ALLOWLIST           Comma-separated list of allowed tools (null = allow all)
        \\  MINI_TOOL_BLOCKLIST           Comma-separated list of blocked tools (null = block none)
        \\  MINI_IMAGE_INPUT_ENABLED      Enable @image:path parsing ("0" to disable)
        \\  MINI_IMAGE_INPUT_MAX_PER_TURN Max image attachments per turn (default: 5)
        \\  MINI_IMAGE_INPUT_MAX_BYTES    Max image file size in bytes (default: 10MB)
        \\  MINI_IMAGE_GEN_ENABLED        Enable generate_image tool ("1" to enable)
        \\  MINI_IMAGE_GEN_PROVIDER       Image gen provider: openai|openai_compat
        \\  MINI_IMAGE_GEN_MODEL          Image generation model (default: gpt-image-1)
        \\  MINI_IMAGE_GEN_SIZE           Default image size (default: 1024x1024)
        \\  MINI_VIDEO_GEN_ENABLED        Enable generate_video tool ("1" to enable)
        \\  MINI_VIDEO_GEN_MODEL          Video generation model (default: sora-2)
        \\  MINI_MEDIA_OUTPUT_DIR         Media output directory
        \\  MINI_VIDEO_POLL_TIMEOUT_SECS  Video job polling timeout in seconds (default: 600)
        \\
        \\### MCP, Hooks & Sessions
        \\  MINI_MCP_CONFIG       Path to mcp.json server configuration
        \\  MINI_HOOK_COMMAND     Global hook command to run on events
        \\  MINI_HOOKS_CONFIG     Path to hooks configuration file
        \\  MINI_SESSION          Override session ID
        \\  MINI_SESSION_FILE     Direct path to session JSON file
        \\  MINI_NO_HISTORY       Disable in-memory history saving ("1" to disable)
        \\  MINI_BUDGET_MAX_TOKENS Maximum token budget per session (default: 10000000)
        \\
        \\Note: Shell environment variables always override .env and config.json values.
        \\
    ) catch {};
}

fn printConfigHelp(io: std.Io) void {
    // PSEUDOCODE:
    // 1. Output basic configuration help block.
    // 2. Output advanced configuration help block.
    printBasicConfigHelp(io);
    printAdvancedConfigHelp(io);
}

fn loadCustomCommandTemplate(alloc: Allocator, io: std.Io, cmd_name: []const u8) ?[]u8 {
    // PSEUDOCODE:
    // 1. Resolve agent directory and command file path.
    // 2. Open file and verify size (0 < size <= 128KB).
    // 3. Read entire file content into buffer and return.
    const agent_dir = utils.getEnvSlice("MINI_AGENT_FOLDER") orelse ".agent";
    const cmd_path = std.fmt.allocPrint(alloc, "{s}/commands/{s}.md", .{ agent_dir, cmd_name }) catch return null;
    defer alloc.free(cmd_path);

    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, cmd_path, .{}) catch return null;
    defer file.close(io);

    const stat = file.stat(io) catch return null;
    if (stat.size == 0 or stat.size > 128 * 1024) return null;

    const template_buf = alloc.alloc(u8, @intCast(stat.size)) catch return null;
    errdefer alloc.free(template_buf);

    const n = utils.readAll(io, file, template_buf) catch {
        alloc.free(template_buf);
        return null;
    };
    return template_buf[0..n];
}

fn tryExecuteCustomSlashCommand(alloc: Allocator, io: std.Io, agent: *agent_mod.AgentLoop, input: []const u8) !bool {
    // PSEUDOCODE:
    // 1. Guard against non-slash input.
    // 2. Parse command name and arguments string.
    // 3. Load command markdown template; return false if not found.
    // 4. Expand template with arguments.
    // 5. Run agent turn with expanded command prompt.
    if (!std.mem.startsWith(u8, input, "/")) return false;

    const cmd_line = input[1..];
    const space_idx = std.mem.indexOfScalar(u8, cmd_line, ' ') orelse cmd_line.len;
    const cmd_name = cmd_line[0..space_idx];
    if (cmd_name.len == 0) return false;

    const args_str = if (space_idx < cmd_line.len) std.mem.trim(u8, cmd_line[space_idx..], " \t") else "";
    const template = loadCustomCommandTemplate(alloc, io, cmd_name) orelse return false;
    defer alloc.free(template);

    const expanded = try expandCommandTemplate(alloc, template, args_str);
    defer alloc.free(expanded);

    main.stdoutPrint("\x1b[90m[command /{s}]\x1b[0m\n", .{cmd_name});
    runAgentTurn(alloc, io, agent, expanded, &.{});
    return true;
}

fn expandCommandTemplate(alloc: Allocator, template: []const u8, args_str: []const u8) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(alloc);

    var positional: [10][]const u8 = undefined;
    var arg_count: usize = 0;
    var it = std.mem.tokenizeAny(u8, args_str, " \t");
    while (it.next()) |arg| {
        if (arg_count < 9) {
            arg_count += 1;
            positional[arg_count] = arg;
        }
    }

    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '$') {
            if (std.mem.startsWith(u8, template[i..], "$ARGUMENTS")) {
                try result.appendSlice(alloc, args_str);
                i += "$ARGUMENTS".len;
                continue;
            } else if (i + 1 < template.len and template[i + 1] >= '1' and template[i + 1] <= '9') {
                const idx = template[i + 1] - '0';
                if (idx <= arg_count) {
                    try result.appendSlice(alloc, positional[idx]);
                }
                i += 2;
                continue;
            }
        }
        try result.append(alloc, template[i]);
        i += 1;
    }

    return result.toOwnedSlice(alloc);
}

test "expandCommandTemplate positional and arguments substitution" {
    const alloc = std.testing.allocator;
    const template = "Commit: $ARGUMENTS (task=$1, file=$2)";
    const args_str = "fix-bug main.zig";

    const expanded = try expandCommandTemplate(alloc, template, args_str);
    defer alloc.free(expanded);

    try std.testing.expectEqualStrings("Commit: fix-bug main.zig (task=fix-bug, file=main.zig)", expanded);
}

test "turn status label includes the terminal failure reason" {
    var reason_buf: [64]u8 = undefined;
    const failed = try turnStatusLabel(&reason_buf, .failed, .provider_unavailable);
    try std.testing.expectEqualStrings("failed: provider_unavailable", failed);

    const stalled = try turnStatusLabel(&reason_buf, .stalled, null);
    try std.testing.expectEqualStrings("stalled", stalled);
}

// ---------------------------------------------------------------------------
// Streaming callback handlers (TurnRenderer-aware)
// ---------------------------------------------------------------------------

pub fn printThinkText(text: []const u8) void {
    while (!g_renderer_mutex.tryLock()) {
        if (signals.isInterrupted()) return;
    }
    const r = current_renderer;
    g_renderer_mutex.unlock();
    if (r) |renderer| {
        renderer.streamThinking(text);
    } else {
        const io = main.getIo();
        std.Io.File.stderr().writeStreamingAll(io, "\x1b[90m") catch {};
        std.Io.File.stderr().writeStreamingAll(io, text) catch {};
        std.Io.File.stderr().writeStreamingAll(io, "\x1b[0m") catch {};
    }
}

pub fn printRawText(text: []const u8) void {
    while (!g_renderer_mutex.tryLock()) {
        if (signals.isInterrupted()) return;
    }
    const r = current_renderer;
    g_renderer_mutex.unlock();
    if (r) {
        r.streamResponse(text);
    } else {
        const io = main.getIo();
        std.Io.File.stdout().writeStreamingAll(io, text) catch {};
    }
}

pub fn printText(text: []const u8) void {
    while (!g_renderer_mutex.tryLock()) {
        if (signals.isInterrupted()) return;
    }
    const r = current_renderer;
    g_renderer_mutex.unlock();
    if (r) |renderer| {
        renderer.processTextChunk(text);
    } else {
        const io = main.getIo();
        std.Io.File.stdout().writeStreamingAll(io, text) catch {};
    }
}

pub fn resetThinkState() void {
    while (!g_renderer_mutex.tryLock()) {
        if (signals.isInterrupted()) return;
    }
    const r = current_renderer;
    g_renderer_mutex.unlock();
    if (r) |renderer| {
        if (renderer.ui_state == .thinking or renderer.is_thinking) {
            renderer.endThinking();
        }
        if (renderer.ui_state == .codeact_live or renderer.ui_state == .codeact_ready or renderer.is_codeact) {
            renderer.endCodeAct();
        }
        renderer.parser.resetAct();
    }
}

pub fn beginAct(act_id: usize) void {
    // PSEUDOCODE:
    // 1. Lock g_renderer_mutex using spin-wait tryLock().
    // 2. Obtain current_renderer pointer.
    // 3. Unlock g_renderer_mutex.
    // 4. If current_renderer exists and act_id > 1, reset act parser state and restart waiting indicator.
    while (!g_renderer_mutex.tryLock()) {
        if (signals.isInterrupted()) return;
    }
    const r = current_renderer;
    g_renderer_mutex.unlock();
    if (r) |renderer| {
        if (act_id > 1) {
            renderer.parser.resetAct();
            renderer.startWaiting();
        }
    }
}
