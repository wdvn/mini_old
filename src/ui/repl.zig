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
pub var current_renderer: ?*chat_stream.TurnRenderer = null;

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
        const line_opt = try line_editor.readLine(io, PROMPT_PREFIX);
        const line = line_opt orelse break;
        defer alloc.free(line);

        const input = std.mem.trim(u8, line, " \t");
        if (input.len == 0) continue;

        try line_editor.addHistory(input);

        // Slash commands
        if (input[0] == '/') {
            if (handleSlashCommand(alloc, io, agent, input)) continue else break;
        }

        // Expand @artifact:<name> references
        const expanded_input = try artifacts_mod.expandArtifactReferences(alloc, io, input);
        defer alloc.free(expanded_input);

        // Parse @image:<path> references if media ingestion is enabled
        const media_res = if (agent.config.image_input_enabled)
            media_lib.parsePromptImages(alloc, io, expanded_input, .{
                .max_per_turn = agent.config.image_input_max_per_turn,
                .max_bytes = agent.config.image_input_max_bytes,
            }) catch |err| {
                main.stdoutPrint("\x1b[31m[media error]\x1b[0m Failed to process image attachment: {s}\n", .{@errorName(err)});
                continue;
            }
        else
            media_lib.PromptParseResult{ .clean_text = try alloc.dupe(u8, expanded_input), .images = try alloc.alloc(proto.ImageBlock, 0) };
        defer media_res.deinit(alloc);

        if (media_res.images.len > 0) {
            main.stdoutPrint("\x1b[90m[attached {d} image(s)]\x1b[0m\n", .{media_res.images.len});
        }

        // Initialize TurnRenderer for this chat turn
        var renderer = chat_stream.TurnRenderer.init(alloc, io);
        renderer.parser.thinking_tags = main.backends.provider_mod.getProfile(agent.config.openai_provider).thinking_tags;
        defer renderer.deinit();
        current_renderer = &renderer;
        defer current_renderer = null;

        renderer.startTurn(media_res.clean_text);
        const start_ms = utils.milliTimestamp();

        // Send to agent
        agent.processInputWithImages(media_res.clean_text, media_res.images, printText, printThinkText) catch |e| {
            if (e != error.Interrupted) {
                main.stdoutPrint("\x1b[31m[error]\x1b[0m {s}\n", .{@errorName(e)});
            }
        };

        if (signals.checkAndResetInterrupted()) {
            continue;
        }

        const end_ms = utils.milliTimestamp();
        const duration = if (end_ms >= start_ms) @as(u64, @intCast(end_ms - start_ms)) else 0;
        const ctx_tokens = agent.token_estimator.estimateMessages(agent.history.messages());

        renderer.finishTurn(.{
            .prompt_tokens = agent.token_estimator.estimate(media_res.clean_text),
            .completion_tokens = agent.last_turn_completion_tokens,
            .context_tokens = ctx_tokens,
            .max_context_tokens = agent.config.context_window,
            .duration_ms = duration,
            .acts_count = if (agent.last_turn_acts > 0) agent.last_turn_acts else 1,
        });
    }

    try stdout.writeStreamingAll(io, "\nGoodbye!\n");
}

/// Process slash command. Returns true to continue, false to exit.
pub fn handleSlashCommand(alloc: Allocator, io: std.Io, agent: *agent_mod.AgentLoop, input: []const u8) bool {
    if (std.mem.eql(u8, input, "/quit") or
        std.mem.eql(u8, input, "/exit") or
        std.mem.eql(u8, input, "/q"))
    {
        return false;
    }

    if (std.mem.eql(u8, input, "/clear")) {
        agent.clearHistory();
        std.Io.File.stdout().writeStreamingAll(io, "\x1b[2J\x1b[H") catch {};
        std.Io.File.stdout().writeStreamingAll(io, "[History cleared]\n") catch {};
        return true;
    }

    if (std.mem.startsWith(u8, input, "/artifact")) {
        const sub = std.mem.trim(u8, input["/artifact".len..], " \t");
        if (sub.len == 0 or std.mem.eql(u8, sub, "list")) {
            const list = artifacts_mod.listArtifacts(alloc, io) catch |e| {
                main.stdoutPrint("Error reading artifacts list: {s}\n", .{@errorName(e)});
                return true;
            };
            defer alloc.free(list);
            main.stdoutPrint("{s}\n", .{list});
            return true;
        }
        if (std.mem.startsWith(u8, sub, "show ") or std.mem.startsWith(u8, sub, "read ") or std.mem.startsWith(u8, sub, "view ")) {
            const space = std.mem.indexOfScalar(u8, sub, ' ') orelse sub.len;
            const name = std.mem.trim(u8, sub[space..], " \t");
            const content = artifacts_mod.readArtifact(alloc, io, name) catch |e| {
                main.stdoutPrint("Error reading artifact '{s}': {s}\n", .{ name, @errorName(e) });
                return true;
            };
            defer alloc.free(content);
            main.stdoutPrint("\n--- [Artifact: {s}] ---\n{s}\n--- [End of Artifact] ---\n\n", .{ name, content });
            return true;
        }
        if (std.mem.eql(u8, sub, "dir") or std.mem.eql(u8, sub, "path")) {
            const dir = artifacts_mod.resolveArtifactsDir(alloc, io) catch |e| {
                main.stdoutPrint("Error resolving artifacts directory: {s}\n", .{@errorName(e)});
                return true;
            };
            defer alloc.free(dir);
            main.stdoutPrint("Current Artifacts directory: {s}\n", .{dir});
            return true;
        }
        main.stdoutPrint("Usage: /artifact [list | show <name> | path]\n", .{});
        return true;
    }

    if (std.mem.eql(u8, input, "/help")) {
        std.Io.File.stdout().writeStreamingAll(io,
            \\
            \\## REPL Commands
            \\  /clear              Clear conversation history
            \\  /model <backend>    Switch backend (openai, claude, ollama)
            \\  /config [show]      Show current configuration
            \\  /config protocol <auto|chat|responses>  Set OpenAI protocol mode
            \\  /config thinking <on|off>               Toggle dynamic thinking governor
            \\  /config reasoning <auto|low|med|high|none> Set reasoning effort
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
        return true;
    }

    if (std.mem.eql(u8, input, "/terminal-setup") or std.mem.eql(u8, input, "/terminal")) {
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
        return true;
    }

    if (std.mem.startsWith(u8, input, "/model ")) {
        const backend_arg = std.mem.trim(u8, input["/model ".len..], " \t");
        if (std.mem.indexOfScalar(u8, backend_arg, ' ')) |space| {
            agent.switchBackend(backend_arg[0..space], backend_arg[space + 1 ..]);
        } else {
            agent.switchBackend(backend_arg, null);
        }
        return true;
    }

    if (std.mem.eql(u8, input, "/config") or std.mem.startsWith(u8, input, "/config ")) {
        const sub = std.mem.trim(u8, input["/config".len..], " \t");
        if (sub.len == 0 or std.mem.eql(u8, sub, "show") or std.mem.startsWith(u8, sub, "show ")) {
            printConfig(agent);
        } else if (std.mem.startsWith(u8, sub, "protocol")) {
            const mode_str = std.mem.trim(u8, sub["protocol".len..], " \t");
            if (mode_str.len > 0) {
                agent.setProtocol(mode_str);
            } else {
                main.stdoutPrint("Usage: /config protocol <auto|chat|responses>\n", .{});
            }
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
            if (effort_str.len > 0) {
                agent.setReasoningEffort(effort_str);
            } else {
                main.stdoutPrint("Usage: /config reasoning <auto|low|medium|high|none>\n", .{});
            }
        } else {
            main.stdoutPrint("Usage: /config [show] | protocol <auto|chat|responses> | thinking <on|off> | reasoning <auto|low|medium|high|none>\n", .{});
        }
        return true;
    }

    if (tryExecuteCustomSlashCommand(alloc, io, agent, input) catch false) {
        return true;
    }

    main.stdoutPrint("Invalid command: {s}. Type /help to view list.\n", .{input});
    return true;
}

fn printConfig(agent: *agent_mod.AgentLoop) void {
    const backend_name = agent.backend.name();
    const model_name = agent.backend.model();

    var endpoint: []const u8 = "N/A";
    var proto_buf: [64]u8 = undefined;
    var proto_str: []const u8 = "N/A";
    var api_key_status: []const u8 = "none";

    switch (agent.backend) {
        .openai => |c| {
            endpoint = c.base_url;
            if (c.api_key.len > 0) api_key_status = "configured";
            if (c.cached_protocol) |cached| {
                if (c.protocol_mode == .auto) {
                    proto_str = std.fmt.bufPrint(&proto_buf, "auto (negotiated: {s})", .{
                        @tagName(cached),
                    }) catch "auto";
                } else if (cached != c.protocol_mode) {
                    proto_str = std.fmt.bufPrint(&proto_buf, "{s} (active: {s})", .{
                        @tagName(c.protocol_mode),
                        @tagName(cached),
                    }) catch @tagName(c.protocol_mode);
                } else {
                    proto_str = @tagName(c.protocol_mode);
                }
            } else {
                proto_str = @tagName(c.protocol_mode);
            }
        },
        .claude => |c| {
            endpoint = "https://api.anthropic.com/v1";
            if (c.api_key.len > 0) api_key_status = "configured";
        },
        .ollama => |c| {
            endpoint = c.base_url;
            api_key_status = "not required";
        },
    }

    var reasoning_buf: [64]u8 = undefined;
    var reasoning_str: []const u8 = "none";

    if (agent.config.reasoning_effort_disabled) {
        reasoning_str = "disabled";
    } else {
        switch (agent.backend) {
            .openai => |c| {
                if (c.disable_reasoning_effort) {
                    reasoning_str = "disabled (endpoint incompatible)";
                } else if (agent.last_effort) |last| {
                    if (agent.dynamic_thinking) {
                        reasoning_str = std.fmt.bufPrint(&reasoning_buf, "auto (active: {s})", .{last}) catch "auto";
                    } else {
                        reasoning_str = last;
                    }
                } else if (agent.dynamic_thinking) {
                    if (agent.config.reasoning_effort) |re| {
                        reasoning_str = std.fmt.bufPrint(&reasoning_buf, "auto (configured: {s})", .{re}) catch "auto";
                    } else {
                        reasoning_str = "auto (dynamic)";
                    }
                } else if (agent.config.reasoning_effort) |re| {
                    reasoning_str = re;
                }
            },
            .claude => |c| {
                const budget = c.active_thinking_budget orelse agent.config.thinking_budget_tokens;
                if (budget) |b| {
                    reasoning_str = std.fmt.bufPrint(&reasoning_buf, "{d} tokens", .{b}) catch "enabled";
                }
            },
            .ollama => {},
        }
    }

    const dynamic_thinking_str: []const u8 = if (agent.dynamic_thinking) "enabled (Cognitive Governor)" else "disabled";
    const memact_str: []const u8 = if (agent.config.memact_enabled) "enabled" else "disabled";

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
            "  \x1b[1mMemAct:\x1b[0m           {s}\n\n",
        .{
            backend_name,
            model_name,
            endpoint,
            proto_str,
            api_key_status,
            @tagName(agent.config.execution_mode),
            agent.config.context_window,
            agent.config.max_tokens,
            dynamic_thinking_str,
            reasoning_str,
            memact_str,
        },
    );
}

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
fn getEnvVar(name: [*:0]const u8) ?[]const u8 {
    if (getenv(name)) |ptr| {
        return std.mem.span(ptr);
    }
    return null;
}

fn tryExecuteCustomSlashCommand(alloc: Allocator, io: std.Io, agent: *agent_mod.AgentLoop, input: []const u8) !bool {
    if (!std.mem.startsWith(u8, input, "/")) return false;

    const cmd_line = input[1..];
    const space_idx = std.mem.indexOfScalar(u8, cmd_line, ' ') orelse cmd_line.len;
    const cmd_name = cmd_line[0..space_idx];
    if (cmd_name.len == 0) return false;

    const args_str = if (space_idx < cmd_line.len) std.mem.trim(u8, cmd_line[space_idx..], " \t") else "";

    const agent_dir = getEnvVar("MINI_AGENT_FOLDER") orelse ".agent";
    const cmd_path = std.fmt.allocPrint(alloc, "{s}/commands/{s}.md", .{ agent_dir, cmd_name }) catch return false;
    defer alloc.free(cmd_path);

    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, cmd_path, .{}) catch return false;
    defer file.close(io);

    const stat = file.stat(io) catch return false;
    if (stat.size == 0 or stat.size > 128 * 1024) return false;

    const template_buf = alloc.alloc(u8, @intCast(stat.size)) catch return false;
    defer alloc.free(template_buf);

    const n = utils.readAll(io, file, template_buf) catch return false;
    const template = template_buf[0..n];

    const expanded = try expandCommandTemplate(alloc, template, args_str);
    defer alloc.free(expanded);

    main.stdoutPrint("\x1b[90m[command /{s}]\x1b[0m\n", .{cmd_name});

    var renderer = chat_stream.TurnRenderer.init(alloc, io);
    renderer.parser.thinking_tags = main.backends.provider_mod.getProfile(agent.config.openai_provider).thinking_tags;
    defer renderer.deinit();
    current_renderer = &renderer;
    defer current_renderer = null;

    renderer.startTurn(expanded);
    const start_ms = utils.milliTimestamp();

    try agent.processInput(expanded, printText, printThinkText);

    const end_ms = utils.milliTimestamp();
    const duration = if (end_ms >= start_ms) @as(u64, @intCast(end_ms - start_ms)) else 0;
    const ctx_tokens = agent.token_estimator.estimateMessages(agent.history.messages());

    renderer.finishTurn(.{
        .prompt_tokens = agent.token_estimator.estimate(expanded),
        .completion_tokens = agent.last_turn_completion_tokens,
        .context_tokens = ctx_tokens,
        .max_context_tokens = agent.config.context_window,
        .duration_ms = duration,
        .acts_count = if (agent.last_turn_acts > 0) agent.last_turn_acts else 1,
    });

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

// ---------------------------------------------------------------------------
// Streaming callback handlers (TurnRenderer-aware)
// ---------------------------------------------------------------------------

pub fn printThinkText(text: []const u8) void {
    if (current_renderer) |r| {
        r.streamThinking(text);
    } else {
        const io = main.getIo();
        std.Io.File.stderr().writeStreamingAll(io, "\x1b[90m") catch {};
        std.Io.File.stderr().writeStreamingAll(io, text) catch {};
        std.Io.File.stderr().writeStreamingAll(io, "\x1b[0m") catch {};
    }
}

pub fn printRawText(text: []const u8) void {
    if (current_renderer) |r| {
        r.streamResponse(text);
    } else {
        const io = main.getIo();
        std.Io.File.stdout().writeStreamingAll(io, text) catch {};
    }
}

pub fn printText(text: []const u8) void {
    if (current_renderer) |r| {
        r.processTextChunk(text);
    } else {
        const io = main.getIo();
        std.Io.File.stdout().writeStreamingAll(io, text) catch {};
    }
}

pub fn resetThinkState() void {
    if (current_renderer) |r| {
        if (r.ui_state == .thinking or r.is_thinking) {
            r.endThinking();
        }
        if (r.ui_state == .codeact_live or r.ui_state == .codeact_ready or r.is_codeact) {
            r.endCodeAct();
        }
        r.parser.resetAct();
    }
}
