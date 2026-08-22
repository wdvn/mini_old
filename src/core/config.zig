//! config.zig — Tải cấu hình từ biến môi trường và file .env.
//!
//! ## Thứ tự tìm file .env (ưu tiên từ cao xuống thấp)
//!   1. `$MINI_ENV_FILE`      — đường dẫn chỉ định rõ
//!   2. `./.env`              — thư mục làm việc hiện tại (project-level)
//!   3. `~/.mini/.env`        — user-level config
//!
//! Shell environment variables luôn CÓ ƯU TIÊN CAO HƠN giá trị trong file .env
//! (dùng `setenv` với overwrite=0).
//!
//! ## Biến môi trường được hỗ trợ
//!
//! ### Backend AI
//!   `OPENAI_COMPAT_URL`     URL OpenAI-compatible (ưu tiên cao nhất)
//!   `OPENAI_COMPAT_MODEL`   Tên model (mặc định: gpt-4o-mini)
//!   `OPENAI_COMPAT_API_KEY` API key (tuỳ chọn, một số endpoint không cần)
//!   `OPENAI_COMPAT_API_HEADER` Header tên (mặc định: Authorization)
//!   `ANTHROPIC_API_KEY`     Claude API key
//!   `OLLAMA_HOST`           Ollama base URL (mặc định: http://localhost:11434)
//!   `OLLAMA_MODEL`          Ollama model (mặc định: llama3)
//!
//! ### Agent
//!   `MINI_MAX_TOKENS`       Giới hạn token response (mặc định: 8192)
//!   `MINI_SYSTEM_FILE`      Đường dẫn file system prompt (.md)
//!   `MINI_NO_HISTORY`       "1" để tắt lưu lịch sử in-memory
//!
//! ### Tools
//!   `MINI_TOOL_ALLOWLIST`   Chỉ cho phép các tool này (comma-separated)
//!   `MINI_TOOL_BLOCKLIST`   Chặn các tool này (comma-separated)
//!
//! ### MCP
//!   `MINI_MCP_CONFIG`       Đường dẫn file mcp.json (mặc định: ~/.mini/mcp.json)

const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");
const main = @import("../main.zig");


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

/// Cấu hình đầy đủ của mini-agent, đọc từ biến môi trường.
pub const Config = struct {
    // Mode
    execution_mode: ExecutionMode = .auto,
    // Backend
    /// URL OpenAI-compatible (ưu tiên cao nhất). Null = không cấu hình.
    openai_compat_url: ?[]const u8,
    /// API key cho OpenAI-compatible endpoint. Null = không cần key.
    openai_compat_key: ?[]const u8,
    /// Header tên chứa API key (mặc định: Authorization).
    openai_compat_api_header: []const u8,
    /// Model cho OpenAI-compatible endpoint.
    openai_compat_model: []const u8,
    /// Cờ sử dụng max_completion_tokens thay vì max_tokens.
    openai_compat_use_completion_tokens: bool,
    /// Anthropic API key. Null = không cấu hình.
    anthropic_key: ?[]const u8,
    /// Claude model ID.
    claude_model: []const u8,
    /// Ollama base URL.
    ollama_url: []const u8,
    /// Ollama model name.
    ollama_model: []const u8,

    // Agent
    /// Số token tối đa trong một response.
    max_tokens: u32,
    /// Nội dung system prompt (đọc từ file hoặc dùng default).
    system_prompt: []const u8,
    /// Bộ nhớ được cấp phát cho system_prompt (null nếu dùng default).
    system_prompt_buf: ?[]u8,

    // Tools
    /// Comma-separated allowlist. Null = cho phép tất cả.
    tool_allowlist: ?[]const u8,
    /// Comma-separated blocklist. Null = không chặn gì.
    tool_blocklist: ?[]const u8,

    // MCP
    /// Đường dẫn file mcp.json. Null = dùng default ~/.mini/mcp.json.
    mcp_config_path: ?[]const u8,

    // History
    /// false = không lưu lịch sử.
    history_enabled: bool,

    // Hooks
    /// Lệnh hook toàn cục. Null = không kích hoạt hook.
    hook_command: ?[]const u8,
    /// Đường dẫn file cấu hình hooks. Null = dùng default.
    hooks_config_path: ?[]const u8,

    // Session
    /// Session ID (tự động lưu/khôi phục tại ~/.mini/sessions/<id>.json).
    session_id: ?[]const u8,
    /// Đường dẫn file session trực tiếp.
    session_file: ?[]const u8,

    /// Default system prompt khi không cấu hình MINI_SYSTEM_FILE.
    pub const default_system_prompt =
        \\Bạn là mini-agent, một AI assistant mạnh mẽ chạy trên terminal.
        \\Bạn hỗ trợ cơ chế Code-Centric Agent (CodeAct): bạn có thể viết mã JavaScript bên trong khối ```js ... ``` để tự động hóa, xử lý dữ liệu hoặc phối hợp nhiều công cụ trong 1 lượt chạy.
        \\
        \\Bên trong JavaScript VM, bạn có object toàn cục `mini`:
        \\  - `mini.read(path, offset?, limit?)`: Đọc file dạng chuỗi
        \\  - `mini.write(path, content)`: Ghi/tạo file
        \\  - `mini.patch(path, oldStr, newStr)`: Sửa file theo đoạn code cũ/mới
        \\  - `mini.exists(path)`: Kiểm tra file tồn tại
        \\  - `mini.stat(path)`: { size, isFile, isDir, modified }
        \\  - `mini.glob(pattern, basePath?)`: Tìm file theo glob
        \\  - `mini.grep(pattern, path?)`: Tìm chuỗi trong file [{ path, line, text }]
        \\  - `mini.sh(command)`: Chạy lệnh shell { exitCode, stdout, stderr, ok }
        \\  - `mini.shBackground(command)`: Chạy ngầm { jobId, pid, logPath }
        \\  - `mini.jobStatus(jobId)`: Kiểm tra job { running, exitCode, pid }
        \\  - `mini.jobLogs(jobId, lines?)`: Đọc log gần nhất của job
        \\  - `mini.jobKill(jobId, signal?)`: Dừng job
        \\  - `mini.http(method, url)`: HTTP request { status, body }
        \\  - `mini.artifact(name, content)`: Lưu artifact
        \\  - `mini.env(name)`: Đọc biến môi trường
        \\  - `console.log(...)`: In kết quả ra output
        \\
        \\Bạn cũng có thể dùng legacy JSON tools nếu cần. Hãy trả lời ngắn gọn, chính xác và hiệu quả bằng tiếng Việt.
    ;

    /// Đọc cấu hình từ biến môi trường (sau khi đã gọi loadDotEnv).
    /// `alloc` dùng để đọc file system prompt nếu cần.
    pub fn load(alloc: Allocator, env_map: *const std.process.Environ.Map, io: std.Io) !Config {
        const exec_mode = if (env_map.get("MINI_EXECUTION_MODE")) |m| ExecutionMode.fromString(m) else .auto;
        const openai_url = env_map.get("OPENAI_COMPAT_URL");
        const openai_key = env_map.get("OPENAI_COMPAT_API_KEY");
        const openai_api_header = env_map.get("OPENAI_COMPAT_API_HEADER") orelse "Authorization";
        const openai_model = env_map.get("OPENAI_COMPAT_MODEL") orelse "gpt-4o-mini";
        const anthropic_key = env_map.get("ANTHROPIC_API_KEY");
        const claude_model = env_map.get("CLAUDE_MODEL") orelse "claude-opus-4-5";
        const ollama_url = env_map.get("OLLAMA_HOST") orelse "http://localhost:11434";
        const ollama_model = env_map.get("OLLAMA_MODEL") orelse "llama3";
        const hook_cmd = env_map.get("MINI_HOOK_COMMAND") orelse env_map.get("MINI_PREHOOK") orelse env_map.get("MINI_HOOK_CMD");
        const hooks_cfg = env_map.get("MINI_HOOKS_CONFIG");
        const session_id = env_map.get("MINI_SESSION");
        const session_file = env_map.get("MINI_SESSION_FILE");

        // Kiểm tra có ít nhất một backend
        if (openai_url == null and anthropic_key == null) {
            main.stderrPrint(
                \\[config] Lỗi: chưa cấu hình AI backend.
                \\
                \\Thiết lập một trong các biến sau:
                \\  OPENAI_COMPAT_URL=http://localhost:11434/v1
                \\  ANTHROPIC_API_KEY=sk-ant-...
                \\
                \\Hoặc tạo file .env trong thư mục hiện tại.
                \\
            , .{});
            return error.MissingBackend;
        }

        const max_tokens: u32 = blk: {
            const s = env_map.get("MINI_MAX_TOKENS") orelse break :blk 8192;
            break :blk std.fmt.parseInt(u32, s, 10) catch 8192;
        };

        const history_enabled = blk: {
            const v = env_map.get("MINI_NO_HISTORY") orelse break :blk true;
            break :blk !std.mem.eql(u8, v, "1");
        };

        // System prompt: từ file hoặc default
        const sp_result = loadSystemPrompt(alloc, env_map, io);

        const use_completion_tokens = blk: {
            const v = env_map.get("MINI_USE_COMPLETION_TOKENS") orelse "0";
            break :blk std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true");
        };

        main.stderrPrint("[config] Env bindings: OPENAI_COMPAT_URL={s}, OPENAI_COMPAT_MODEL={s}, MINI_HOME={s}\n", .{
            openai_url orelse "(null)",
            openai_model,
            env_map.get("MINI_HOME") orelse "(null)",
        });

        return .{
            .execution_mode = exec_mode,
            .openai_compat_url = openai_url,
            .openai_compat_key = openai_key,
            .openai_compat_api_header = openai_api_header,
            .openai_compat_model = openai_model,
            .openai_compat_use_completion_tokens = use_completion_tokens,
            .anthropic_key = anthropic_key,
            .claude_model = claude_model,
            .ollama_url = ollama_url,
            .ollama_model = ollama_model,
            .max_tokens = max_tokens,
            .system_prompt = sp_result.text,
            .system_prompt_buf = sp_result.buf,
            .tool_allowlist = env_map.get("MINI_TOOL_ALLOWLIST"),
            .tool_blocklist = env_map.get("MINI_TOOL_BLOCKLIST"),
            .mcp_config_path = env_map.get("MINI_MCP_CONFIG"),
            .history_enabled = history_enabled,
            .hook_command = hook_cmd,
            .hooks_config_path = hooks_cfg,
            .session_id = session_id,
            .session_file = session_file,
        };
    }

    /// Giải phóng bộ nhớ được cấp phát (chỉ system_prompt_buf).
    pub fn deinit(self: *Config, alloc: Allocator) void {
        if (self.system_prompt_buf) |buf| {
            alloc.free(buf);
            self.system_prompt_buf = null;
            self.system_prompt = default_system_prompt;
        }
    }
};

// ---------------------------------------------------------------------------
// System prompt loading
// ---------------------------------------------------------------------------

const SpResult = struct { buf: ?[]u8, text: []const u8 };

fn loadSystemPrompt(alloc: Allocator, env_map: *const std.process.Environ.Map, io: std.Io) SpResult {
    const path = env_map.get("MINI_SYSTEM_FILE") orelse
        return .{ .buf = null, .text = Config.default_system_prompt };

    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, path, .{}) catch {
        main.stderrPrint("[config] Không mở được system prompt: {s}, dùng default.\n", .{path});
        return .{ .buf = null, .text = Config.default_system_prompt };
    };
    defer file.close(io);

    const stat = file.stat(io) catch return .{ .buf = null, .text = Config.default_system_prompt };
    if (stat.size == 0 or stat.size > 64 * 1024)
        return .{ .buf = null, .text = Config.default_system_prompt };

    const buf = alloc.alloc(u8, @intCast(stat.size)) catch
        return .{ .buf = null, .text = Config.default_system_prompt };

    const n = utils.readAll(io, file, buf) catch {
        alloc.free(buf);
        return .{ .buf = null, .text = Config.default_system_prompt };
    };

    main.stderrPrint("[config] System prompt: {s} ({d} bytes)\n", .{ path, n });
    return .{ .buf = buf, .text = buf[0..n] };
}

// ---------------------------------------------------------------------------
// .env loader
// ---------------------------------------------------------------------------

/// Tải biến môi trường từ các file .env theo thứ tự ưu tiên:
///   1. $MINI_ENV_FILE — đường dẫn tường minh
///   2. ./.env         — thư mục hiện tại
///   3. ~/.mini/.env   — user-level
///
/// Shell env variables luôn có ưu tiên cao hơn (setenv overwrite=0).
/// Hỗ trợ cú pháp: `KEY=VALUE`, `KEY="VALUE"`, `KEY='VALUE'`,
///                 `export KEY=VALUE`, `# comment`, dòng trống.
pub fn loadDotEnv(env_map: *std.process.Environ.Map, io: std.Io) void {
    const home = env_map.get("HOME");

    // Danh sách ứng viên
    var paths: [3][512]u8 = undefined;
    var path_lens: [3]usize = .{ 0, 0, 0 };
    var n: usize = 0;

    // 1. Explicit override
    if (env_map.get("MINI_ENV_FILE")) |explicit| {
        if (explicit.len > 0 and explicit.len < 512) {
            @memcpy(paths[n][0..explicit.len], explicit);
            path_lens[n] = explicit.len;
            n += 1;
        }
    }

    // 2. CWD/.env
    {
        const name = ".env";
        @memcpy(paths[n][0..name.len], name);
        path_lens[n] = name.len;
        n += 1;
    }

    // 3. MINI_HOME/.env hoặc ~/.mini/.env
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

fn tryLoadFile(env_map: *std.process.Environ.Map, io: std.Io, path: []const u8) void {
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

        // Không ghi đè nếu đã có trong shell env
        if (env_map.get(key) != null) continue;
        env_map.put(key, val) catch continue;
        loaded += 1;
    }

    if (loaded > 0) {
        main.stderrPrint("[config] Loaded {d} vars from {s}\n", .{ loaded, path });
    }
}
