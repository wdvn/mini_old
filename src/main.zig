//! main.zig — Entry point của mini-agent.
//!
//! ## Luồng khởi động
//! ```
//! parse CLI args
//!   → config.loadDotEnv()       load .env files
//!   → Config.load()             đọc env vars → Config struct
//!   → McpClientManager.init()   kết nối MCP servers (nếu không có --no-mcp)
//!   → tools.setMcpManager()     đăng ký MCP vào tool dispatcher
//!   → AgentLoop.init()          chọn backend, khởi tạo history
//!   → [single-shot] -e "..."    gửi prompt, in kết quả, thoát
//!   → [REPL]                    vòng lặp đọc stdin
//! ```
//!
//! ## CLI flags
//! ```
//! mini-agent [options]
//!   -e <prompt>        Chạy single-shot và thoát
//!   --system <file>    Dùng file này làm system prompt
//!   --no-mcp           Không kết nối MCP servers
//!   --model <backend>  Chọn backend: openai, claude, ollama
//!   --version          In phiên bản
//!   --help, -h         In hướng dẫn
//! ```
//!
//! ## Slash commands trong REPL
//! ```
//! /quit, /exit, /q   Thoát
//! /clear             Xóa lịch sử hội thoại
//! /help              Xem danh sách tools và lệnh
//! /model <backend>   Đổi backend
//! ```

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const config_mod = @import("config.zig");
const agent_mod = @import("agent.zig");
const tools_mod = @import("tools.zig");
const mcp_mod = @import("mcp.zig");
const utils = @import("utils.zig");
const cron_mod = @import("cron.zig");
const hooks_mod = @import("hooks.zig");
const editor_mod = @import("editor.zig");
const artifacts_mod = @import("artifacts.zig");
const acp_mod = @import("acp.zig");
pub const quickjs_engine = @import("runtime/quickjs_engine.zig");
pub const js_bindings = @import("runtime/js_bindings.zig");
pub const process_manager = @import("runtime/process_manager.zig");

const VERSION = "1.0.0";
const PROMPT_PREFIX = "\x1b[1;34mYou\x1b[0m > ";

pub var g_io: std.Io = undefined;

/// Lấy Io instance: tự động dùng std.testing.io khi chạy test (comptime), hoặc g_io khi runtime.
pub fn getIo() std.Io {
    if (comptime builtin.is_test) {
        return std.testing.io;
    }
    return g_io;
}

// ---------------------------------------------------------------------------
// I/O helpers — Zig 0.15.2: File.writeAll() + bufPrint, std.debug.print
// ---------------------------------------------------------------------------

/// In formatted string ra stdout.
pub fn stdoutPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stdout().writer(g_io, &buf);
    w.interface.print(fmt, args) catch return;
    w.flush() catch {};
}

/// In formatted string ra stderr.
pub fn stderrPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writer(g_io, &buf);
    w.interface.print(fmt, args) catch return;
    w.flush() catch {};
}



// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    g_io = init.io;
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
        stdoutPrint("mini-agent {s}\n", .{VERSION});
        return;
    }

    // Thiết lập env file từ --system trước khi loadDotEnv nếu cần
    // (MINI_SYSTEM_FILE có thể được set trong .env)
    config_mod.loadDotEnv(init.environ_map, init.io);

    // Load config
    var cfg = config_mod.Config.load(alloc, init.environ_map, init.io) catch |e| {
        stderrPrint("Lỗi load config: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    defer cfg.deinit(alloc);

    // Override system prompt từ CLI
    if (args.system_file) |sfile| {
        const cwd = std.Io.Dir.cwd();
        const file = cwd.openFile(init.io, sfile, .{}) catch |e| {
            stderrPrint("Không mở được system file '{s}': {s}\n", .{ sfile, @errorName(e) });
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

    // Override execution mode từ CLI
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
        mcp.loadFromConfig(init.environ_map, init.io, cfg.mcp_config_path);
        tools_mod.setMcpManager(&mcp);
        if (mcp.toolCount() > 0) {
            stderrPrint("[main] MCP: {d} tools từ {d} server(s)\n", .{ mcp.toolCount(), mcp.servers.items.len });
        }
    }

    // Khởi tạo AgentLoop
    var agent = agent_mod.AgentLoop.init(alloc, init.io, &cfg) catch |e| {
        stderrPrint("Lỗi init agent: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    defer agent.deinit();

    // Override backend từ CLI
    if (args.backend) |b| agent.switchBackend(b, null);

    // Cài đặt cronjob
    if (args.cron) |cron_expr| {
        if (args.prompt == null) {
            stderrPrint("Lỗi: --install-cron yêu cầu phải có -e <prompt>\n", .{});
            std.process.exit(1);
        }
        
        const exe_path = try getAbsoluteExePath(alloc, init.io, args_raw[0]);
        defer alloc.free(exe_path);
        
        cron_mod.installCronjob(alloc, init.io, cron_expr, exe_path, args.prompt.?) catch |e| {
            if (e == error.AlreadyExists) {
                stdoutPrint("Cronjob này đã tồn tại trong hệ thống!\n", .{});
            } else {
                stderrPrint("Lỗi khi cài đặt cronjob: {s}\n", .{@errorName(e)});
                std.process.exit(1);
            }
            return;
        };
        stdoutPrint("Đã cài đặt cronjob thành công: {s}\n", .{cron_expr});
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
                stderrPrint("[main] Cảnh báo: Lỗi nạp session file '{s}': {s}, tạo session mới.\n", .{ spath, @errorName(e) });
            };
        } else |_| {}
    }

    // Tự động lưu session khi thoát
    defer {
        if (session_path) |spath| {
            agent.history.backupToFile(init.io, spath) catch |e| {
                stderrPrint("[main] Cảnh báo: Không thể lưu session file: {s}\n", .{@errorName(e)});
            };
        }
    }

    // ACP server mode (Agent Client Protocol over stdin/stdout)
    if (args.acp) {
        try acp_mod.runServer(alloc, init.io, &agent, &cfg);
        return;
    }

    // Single-shot mode
    if (args.prompt) |prompt| {
        const expanded = try artifacts_mod.expandArtifactReferences(alloc, init.io, prompt);
        defer alloc.free(expanded);
        try agent.processInput(expanded, printText, printThinkText);
        return;
    }

    // Single-shot mode from file
    if (args.single) |prompt_file| {
        const cwd = std.Io.Dir.cwd();
        const file = cwd.openFile(init.io, prompt_file, .{}) catch |e| {
            stderrPrint("Không mở được prompt file '{s}': {s}\n", .{ prompt_file, @errorName(e) });
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
        try agent.processInput(expanded, printText, printThinkText);
        return;
    }

    // REPL mode
    try runRepl(alloc, &agent);
}

// ---------------------------------------------------------------------------
// REPL
// ---------------------------------------------------------------------------

fn runRepl(alloc: Allocator, agent: *agent_mod.AgentLoop) !void {
    const stdout = std.Io.File.stdout();

    var line_editor = editor_mod.LineEditor.init(alloc);
    defer line_editor.deinit();

    stdoutPrint("\x1b[1;32mmini-agent\x1b[0m {s} | {s} ({s})\n", .{
        VERSION, agent.backend.name(), agent.backend.model(),
    });
    try stdout.writeStreamingAll(g_io, "Gõ /help để xem lệnh, /quit để thoát.\n\n");

    while (true) {
        const line_opt = try line_editor.readLine(g_io, PROMPT_PREFIX);
        const line = line_opt orelse break;
        defer alloc.free(line);

        const input = std.mem.trim(u8, line, " \t");
        if (input.len == 0) continue;

        try line_editor.addHistory(input);

        // Slash commands
        if (input[0] == '/') {
            if (handleSlashCommand(alloc, agent, input)) continue else break;
        }

        // Mở rộng tham chiếu @artifact:<name>
        const expanded_input = try artifacts_mod.expandArtifactReferences(alloc, g_io, input);
        defer alloc.free(expanded_input);

        // Gửi đến agent
        agent.processInput(expanded_input, printText, printThinkText) catch |e| {
            stdoutPrint("\x1b[31m[lỗi]\x1b[0m {s}\n", .{@errorName(e)});
        };
    }

    try stdout.writeStreamingAll(g_io, "\nTạm biệt!\n");
}

/// Xử lý slash command. Trả về true để tiếp tục, false để thoát.
fn handleSlashCommand(alloc: Allocator, agent: *agent_mod.AgentLoop, input: []const u8) bool {
    if (std.mem.eql(u8, input, "/quit") or
        std.mem.eql(u8, input, "/exit") or
        std.mem.eql(u8, input, "/q"))
    {
        return false;
    }

    if (std.mem.eql(u8, input, "/clear")) {
        agent.clearHistory();
        std.Io.File.stdout().writeStreamingAll(g_io, "\x1b[2J\x1b[H") catch {};
        std.Io.File.stdout().writeStreamingAll(g_io, "[Lịch sử đã xóa]\n") catch {};
        return true;
    }

    if (std.mem.startsWith(u8, input, "/artifact")) {
        const sub = std.mem.trim(u8, input["/artifact".len..], " \t");
        if (sub.len == 0 or std.mem.eql(u8, sub, "list")) {
            const list = artifacts_mod.listArtifacts(alloc, g_io) catch |e| {
                stdoutPrint("Lỗi đọc danh sách artifacts: {s}\n", .{@errorName(e)});
                return true;
            };
            defer alloc.free(list);
            stdoutPrint("{s}\n", .{list});
            return true;
        }
        if (std.mem.startsWith(u8, sub, "show ") or std.mem.startsWith(u8, sub, "read ") or std.mem.startsWith(u8, sub, "view ")) {
            const space = std.mem.indexOfScalar(u8, sub, ' ') orelse sub.len;
            const name = std.mem.trim(u8, sub[space..], " \t");
            const content = artifacts_mod.readArtifact(alloc, g_io, name) catch |e| {
                stdoutPrint("Lỗi đọc artifact '{s}': {s}\n", .{ name, @errorName(e) });
                return true;
            };
            defer alloc.free(content);
            stdoutPrint("\n--- [Artifact: {s}] ---\n{s}\n--- [Hết Artifact] ---\n\n", .{ name, content });
            return true;
        }
        if (std.mem.eql(u8, sub, "dir") or std.mem.eql(u8, sub, "path")) {
            const dir = artifacts_mod.resolveArtifactsDir(alloc, g_io) catch |e| {
                stdoutPrint("Lỗi lấy đường dẫn artifacts: {s}\n", .{@errorName(e)});
                return true;
            };
            defer alloc.free(dir);
            stdoutPrint("Thư mục Artifacts hiện tại: {s}\n", .{dir});
            return true;
        }
        stdoutPrint("Cú pháp: /artifact [list | show <name> | path]\n", .{});
        return true;
    }

    if (std.mem.eql(u8, input, "/help")) {
        std.Io.File.stdout().writeStreamingAll(g_io,
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
            \\  glob, grep, http_request, web_search, skills, browser, invoke_subagent
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

    stdoutPrint("Lệnh không hợp lệ: {s}. Gõ /help để xem danh sách.\n", .{input});
    return true;
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
// Streaming callback
// ---------------------------------------------------------------------------

var is_thinking = false;

pub fn printThinkText(text: []const u8) void {
    if (!is_thinking) {
        std.Io.File.stderr().writeStreamingAll(g_io, "\x1b[90m\n[Suy nghĩ]\n") catch {};
        is_thinking = true;
    }
    std.Io.File.stderr().writeStreamingAll(g_io, text) catch {};
}

pub fn printRawText(text: []const u8) void {
    if (is_thinking) {
        std.Io.File.stderr().writeStreamingAll(g_io, "\x1b[0m\n\n") catch {};
        is_thinking = false;
    }
    std.Io.File.stdout().writeStreamingAll(g_io, text) catch {};
}

var think_tag_buf: [16]u8 = undefined;
var think_tag_len: usize = 0;
var in_think_tag: bool = false;

pub fn printText(text: []const u8) void {
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (in_think_tag) {
            const expected = "</think>";
            if (c == '<' or think_tag_len > 0) {
                if (i > start) {
                    printThinkText(text[start..i]);
                }
                think_tag_buf[think_tag_len] = c;
                think_tag_len += 1;
                i += 1;
                start = i;

                if (think_tag_buf[think_tag_len - 1] == expected[think_tag_len - 1]) {
                    if (think_tag_len == expected.len) {
                        in_think_tag = false;
                        think_tag_len = 0;
                        resetThinkState();
                    }
                } else {
                    printThinkText(think_tag_buf[0..think_tag_len]);
                    think_tag_len = 0;
                }
            } else {
                i += 1;
            }
        } else {
            const expected = "<think>";
            if (c == '<' or think_tag_len > 0) {
                if (i > start) {
                    printRawText(text[start..i]);
                }
                think_tag_buf[think_tag_len] = c;
                think_tag_len += 1;
                i += 1;
                start = i;

                if (think_tag_buf[think_tag_len - 1] == expected[think_tag_len - 1]) {
                    if (think_tag_len == expected.len) {
                        in_think_tag = true;
                        think_tag_len = 0;
                    }
                } else {
                    printRawText(think_tag_buf[0..think_tag_len]);
                    think_tag_len = 0;
                }
            } else {
                i += 1;
            }
        }
    }
    if (start < text.len) {
        if (in_think_tag) {
            printThinkText(text[start..]);
        } else {
            printRawText(text[start..]);
        }
    }
}

pub fn resetThinkState() void {
    if (is_thinking) {
        std.Io.File.stderr().writeStreamingAll(g_io, "\x1b[0m\n") catch {};
        is_thinking = false;
    }
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
        \\mini-agent — AI agent trên terminal
        \\
        \\CÁCH DÙNG:
        \\  mini-agent [options]
        \\
        \\OPTIONS:
        \\  -e, --exec <prompt>    Chạy single-shot và thoát
        \\  --system <file>        Dùng file làm system prompt
        \\  -m, --mode <mode>      Chế độ thực thi: codeact (QuickJS-ng JS engine), tools (JSON), auto
        \\  --session <id>         Tự động nạp/lưu session tại ~/.mini/sessions/<id>.json
        \\  --session-file <path>  Chỉ định đường dẫn file session JSON trực tiếp
        \\  --acp                  Chạy chế độ ACP server (Agent Client Protocol qua stdin/stdout)
        \\  --install-cron <expr>  Tạo cronjob Linux chạy tự động (cần dùng chung với -e)
        \\  --model <backend>      Chọn backend: openai, claude, ollama
        \\  --hook-command <cmd>   Lệnh prehook / monitoring hook chạy trước/sau các hành động
        \\  --no-mcp               Không kết nối MCP servers
        \\  --version, -v          In phiên bản
        \\  --help, -h             In hướng dẫn này
        \\
        \\VÍ DỤ:
        \\  mini-agent -e "Tóm tắt README.md"
        \\  mini-agent --session test-sess -e "Tên tôi là An."
        \\  mini-agent --session test-sess -e "Tên tôi là gì?"
        \\  mini-agent --system prompt.md
        \\  mini-agent --model claude
        \\  mini-agent --hook-command 'echo "[HOOK] $MINI_HOOK_EVENT tool=$MINI_TOOL_NAME"'
        \\  MINI_TOOL_BLOCKLIST=bash mini-agent
        \\
        \\CẤU HÌNH (.env hoặc biến môi trường):
        \\  MINI_HOME              Thư mục gốc lưu trữ cấu hình & session (mặc định: ~/.mini)
        \\  OPENAI_COMPAT_URL      URL OpenAI-compatible
        \\  OPENAI_COMPAT_MODEL    Tên model
        \\  OPENAI_COMPAT_API_HEADER Header tên (mặc định: Authorization)
        \\  ANTHROPIC_API_KEY      Claude API key
        \\  OLLAMA_HOST            Ollama URL (mặc định: localhost:11434)
        \\  MINI_SYSTEM_FILE       System prompt file
        \\  MINI_SESSION            Session ID (lưu tại <MINI_HOME>/sessions/<id>.json)
        \\  MINI_SESSION_FILE       Đường dẫn file session JSON
        \\  MINI_HOOK_COMMAND      Lệnh hook giám sát toàn cục (pre-tool-use, pre-prompt, MCP...)
        \\  MINI_TOOL_ALLOWLIST    Chỉ cho phép tools này (comma-separated)
        \\  MINI_TOOL_BLOCKLIST    Chặn tools này (comma-separated)
        \\  MINI_MCP_CONFIG        Đường dẫn mcp.json (mặc định: <MINI_HOME>/mcp.json)
        \\
    ) catch {};
}

test {
    _ = @import("artifacts.zig");
    _ = @import("acp.zig");
    _ = quickjs_engine;
    _ = js_bindings;
    _ = process_manager;
}

