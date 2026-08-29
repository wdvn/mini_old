//! repl.zig — Interactive Terminal REPL & UI Presentation Layer cho mini-agent (RFC-007).
//!
//! Tách biệt hoàn toàn phần giao diện người dùng, xử lý lệnh Slash (/help, /model, /artifact, /clear),
//! và streaming markdown / thinking text ra khỏi composition root.

const std = @import("std");
const Allocator = std.mem.Allocator;
const agent_mod = @import("../core/agent.zig");
const artifacts_mod = @import("../core/artifacts.zig");
const editor_mod = @import("editor.zig");
const main = @import("../main.zig");
const utils = @import("../core/utils.zig");
const signals = @import("../core/signals.zig");
pub const chat_stream = @import("chat_stream.zig");

pub const PROMPT_PREFIX = "\x1b[1;34mYou\x1b[0m > ";

/// Renderer toàn cục của turn hiện tại (nếu đang xử lý).
pub var current_renderer: ?*chat_stream.TurnRenderer = null;

/// Chạy vòng lặp tương tác REPL.
pub fn runRepl(alloc: Allocator, io: std.Io, agent: *agent_mod.AgentLoop, version: []const u8) !void {
    signals.initSignalHandlers();
    const stdout = std.Io.File.stdout();

    var line_editor = editor_mod.LineEditor.init(alloc);
    defer line_editor.deinit();

    main.stdoutPrint("\x1b[1;32mmini-agent\x1b[0m {s} \x1b[90m(build {s})\x1b[0m | {s} ({s})\n", .{
        version, main.BUILD_TIME, agent.backend.name(), agent.backend.model(),
    });
    try stdout.writeStreamingAll(io, "Gõ /help để xem lệnh, /quit để thoát.\n\n");

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

        // Mở rộng tham chiếu @artifact:<name>
        const expanded_input = try artifacts_mod.expandArtifactReferences(alloc, io, input);
        defer alloc.free(expanded_input);

        // Khởi tạo TurnRenderer cho lượt chat này
        var renderer = chat_stream.TurnRenderer.init(alloc, io);
        defer renderer.deinit();
        current_renderer = &renderer;
        defer current_renderer = null;

        renderer.startTurn(expanded_input);
        const start_ms = utils.milliTimestamp();

        // Gửi đến agent
        agent.processInput(expanded_input, printText, printThinkText) catch |e| {
            if (e != error.Interrupted) {
                main.stdoutPrint("\x1b[31m[lỗi]\x1b[0m {s}\n", .{@errorName(e)});
            }
        };

        if (signals.checkAndResetInterrupted()) {
            continue;
        }

        const end_ms = utils.milliTimestamp();
        const duration = if (end_ms >= start_ms) @as(u64, @intCast(end_ms - start_ms)) else 0;
        const ctx_tokens = agent.token_estimator.estimateMessages(agent.history.messages());

        renderer.finishTurn(.{
            .prompt_tokens = agent.token_estimator.estimate(expanded_input),
            .completion_tokens = agent.last_turn_completion_tokens,
            .context_tokens = ctx_tokens,
            .max_context_tokens = agent.config.context_window,
            .duration_ms = duration,
            .acts_count = if (agent.last_turn_acts > 0) agent.last_turn_acts else 1,
        });
    }

    try stdout.writeStreamingAll(io, "\nTạm biệt!\n");
}

/// Xử lý slash command. Trả về true để tiếp tục, false để thoát.
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
        std.Io.File.stdout().writeStreamingAll(io, "[Lịch sử đã xóa]\n") catch {};
        return true;
    }

    if (std.mem.startsWith(u8, input, "/artifact")) {
        const sub = std.mem.trim(u8, input["/artifact".len..], " \t");
        if (sub.len == 0 or std.mem.eql(u8, sub, "list")) {
            const list = artifacts_mod.listArtifacts(alloc, io) catch |e| {
                main.stdoutPrint("Lỗi đọc danh sách artifacts: {s}\n", .{@errorName(e)});
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
                main.stdoutPrint("Lỗi đọc artifact '{s}': {s}\n", .{ name, @errorName(e) });
                return true;
            };
            defer alloc.free(content);
            main.stdoutPrint("\n--- [Artifact: {s}] ---\n{s}\n--- [Hết Artifact] ---\n\n", .{ name, content });
            return true;
        }
        if (std.mem.eql(u8, sub, "dir") or std.mem.eql(u8, sub, "path")) {
            const dir = artifacts_mod.resolveArtifactsDir(alloc, io) catch |e| {
                main.stdoutPrint("Lỗi lấy đường dẫn artifacts: {s}\n", .{@errorName(e)});
                return true;
            };
            defer alloc.free(dir);
            main.stdoutPrint("Thư mục Artifacts hiện tại: {s}\n", .{dir});
            return true;
        }
        main.stdoutPrint("Cú pháp: /artifact [list | show <name> | path]\n", .{});
        return true;
    }

    if (std.mem.eql(u8, input, "/help")) {
        std.Io.File.stdout().writeStreamingAll(io,
            \\
            \\## Lệnh REPL
            \\  /clear              Xóa lịch sử hội thoại
            \\  /model <backend>    Đổi backend (openai, claude, ollama)
            \\  /artifact [list]    Xem danh sách artifacts của session
            \\  /artifact show <fn> Đọc nội dung một artifact
            \\  /quit, /exit, /q    Thoát
            \\  /help               Hiện hướng dẫn này
            \\
            \\## Tham chiếu Artifact
            \\  Dùng cú pháp @artifact:<name> trực tiếp trong câu hỏi để chèn artifact vào context.
            \\
            \\## Tools có sẵn
            \\  bash, file_read, file_write, file_edit, artifact_write, artifact_read, artifact_list
            \\  glob, grep, http_request, skills, invoke_subagent, batch_invoke_subagents
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

    if (tryExecuteCustomSlashCommand(alloc, io, agent, input) catch false) {
        return true;
    }

    main.stdoutPrint("Lệnh không hợp lệ: {s}. Gõ /help để xem danh sách.\n", .{input});
    return true;
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
