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
//! ### MemAct (RFC-003)
//!   `MINI_MEMACT_ENABLED`       "0" để tắt MemAct (mặc định: bật)
//!   `MINI_CONTEXT_WINDOW`       Context window tokens; nếu không set sẽ
//!                               auto-detect theo backend (openai-compat 128000,
//!                               anthropic 200000, ollama 8192)
//!   `MINI_CTX_SAFETY_MARGIN`    Hệ số biên an toàn (mặc định: 0.15)
//!   `MINI_CTX_COMPACT_THRESHOLD` Ngưỡng nén lịch sử (mặc định: 0.85)
//!   `MINI_MEMACT_TOP_K`         Số memory item tối đa inject (mặc định: 8)
//!   `MINI_MEMACT_MEMORY_BUDGET` Ngân sách token cho memory block (mặc định: 2000)
//!   `MINI_MEMACT_EXTRACT`       Chế độ extract memory: async|sync|off (mặc định: async)
//!   `MINI_MEMORY_DIR`           Thư mục memory (mặc định: ~/.mini/memory)
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
const skills_mod = @import("skills.zig");
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

/// Giao thức OpenAI-compatible (ISSUE-BACKEND-001).
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

/// Cấu hình đầy đủ của mini-agent, đọc từ biến môi trường.
pub const Config = struct {
    // Mode
    execution_mode: ExecutionMode = .auto,
    // Backend
    /// Giao thức OpenAI-compatible (mặc định: auto).
    openai_protocol: OpenAiProtocol = .auto,
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

    // MemAct Config
    memact_enabled: bool,
    context_window: u32,
    ctx_safety_margin: f32,
    ctx_compact_threshold: f32,
    /// Số memory item tối đa inject vào prompt (RFC-003).
    memact_top_k: u32 = 8,
    /// Ngân sách token dành cho memory block (RFC-003).
    memact_memory_budget: u32 = 2000,
    /// Chế độ extract memory: async | sync | off (RFC-003).
    memact_extract: []const u8 = "async",
    /// Thư mục memory. Null = caller tự build ~/.mini/memory.
    memory_dir: ?[]const u8 = null,

    // Budget Limits (RFC-002)
    budget_max_tokens: usize,

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
        \\Bạn hỗ trợ cơ chế Code-Centric Agent (CodeAct): để đọc/ghi file, tìm kiếm, chạy shell command hoặc tự động hóa, bạn BẮT BUỘC phải viết mã JavaScript bên trong khối ```js ... ``` (sử dụng đối tượng toàn cục `mini`). Tuyệt đối KHÔNG sử dụng các thẻ XML giả định như <file_read>, <glob>, <bash>.
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
        \\## Quy tắc tương tác CodeAct (BẮT BUỘC):
        \\1. Mỗi lượt (turn) bạn chỉ được viết ĐÚNG 1 khối ```js ... ``` duy nhất.
        \\2. Ngay sau khi đóng thẻ ``` bạn BẮT BUỘC DỪNG LẠI (yield turn) để hệ thống thực thi và trả về kết quả qua lượt tiếp theo.
        \\3. Tuyệt đối KHÔNG tự giả định output, KHÔNG tự độc thoại suy đoán kết quả và KHÔNG viết nhiều khối code trong cùng một lượt trả lời.
        \\
        \\Hãy trả lời ngắn gọn, chính xác và hiệu quả bằng tiếng Việt.
    ;




    /// Đọc cấu hình từ biến môi trường (sau khi đã gọi loadDotEnv).
    /// `alloc` dùng để đọc file system prompt nếu cần.
    pub fn load(alloc: Allocator, env_map: *const std.process.Environ.Map, io: std.Io) !Config {
        const exec_mode = if (env_map.get("MINI_EXECUTION_MODE")) |m| ExecutionMode.fromString(m) else .auto;
        const openai_proto = if (env_map.get("OPENAI_PROTOCOL") orelse env_map.get("MINI_OPENAI_PROTOCOL") orelse env_map.get("OPENAI_COMPAT_PROTOCOL")) |p| OpenAiProtocol.fromString(p) else .auto;
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

        const memact_enabled = blk: {
            const s = env_map.get("MINI_MEMACT_ENABLED") orelse "1";
            break :blk std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "true");
        };

        // Auto-detect context window (RFC-003 §5) khi MINI_CONTEXT_WINDOW không set:
        // chọn theo backend sẽ dùng, đúng thứ tự ưu tiên như AgentLoop.init —
        // openai_compat_url → anthropic → ollama.
        const context_window: u32 = blk: {
            if (env_map.get("MINI_CONTEXT_WINDOW")) |s| {
                break :blk std.fmt.parseInt(u32, s, 10) catch 128000;
            }
            if (openai_url != null) break :blk 128000;
            if (anthropic_key != null) break :blk 200000;
            break :blk 8192; // fallback Ollama
        };

        const ctx_safety_margin: f32 = blk: {
            const s = env_map.get("MINI_CTX_SAFETY_MARGIN") orelse break :blk 0.15;
            break :blk std.fmt.parseFloat(f32, s) catch 0.15;
        };

        const ctx_compact_threshold: f32 = blk: {
            const s = env_map.get("MINI_CTX_COMPACT_THRESHOLD") orelse break :blk 0.85;
            break :blk std.fmt.parseFloat(f32, s) catch 0.85;
        };

        const memact_top_k: u32 = blk: {
            const s = env_map.get("MINI_MEMACT_TOP_K") orelse break :blk 8;
            break :blk std.fmt.parseInt(u32, s, 10) catch 8;
        };

        const memact_memory_budget: u32 = blk: {
            const s = env_map.get("MINI_MEMACT_MEMORY_BUDGET") orelse break :blk 2000;
            break :blk std.fmt.parseInt(u32, s, 10) catch 2000;
        };

        const memact_extract: []const u8 = blk: {
            const s = env_map.get("MINI_MEMACT_EXTRACT") orelse break :blk "async";
            // Chỉ chấp nhận async|sync|off, giá trị lạ fallback về async.
            if (std.mem.eql(u8, s, "sync") or std.mem.eql(u8, s, "off")) break :blk s;
            if (std.mem.eql(u8, s, "async")) break :blk s;
            break :blk "async";
        };

        const memory_dir: ?[]const u8 = env_map.get("MINI_MEMORY_DIR");

        const budget_max_tokens: usize = blk: {
            const s = env_map.get("MINI_BUDGET_MAX_TOKENS") orelse break :blk 10_000_000; // default large budget
            break :blk std.fmt.parseInt(usize, s, 10) catch 10_000_000;
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

        if (!utils.isSubagent()) {
            main.stderrPrint("[config] Env bindings: OPENAI_COMPAT_URL={s}, OPENAI_COMPAT_MODEL={s}, MINI_HOME={s}\n", .{
                openai_url orelse "(null)",
                openai_model,
                env_map.get("MINI_HOME") orelse "(null)",
            });
            main.stderrPrint("[config] Build: {s} | {s} | {s} | zig {s}\n", .{
                main.BUILD_TIME, main.BUILD_OPTIMIZE, main.BUILD_TARGET, main.ZIG_VERSION,
            });
            if (memact_enabled) {
                const window_src = if (env_map.get("MINI_CONTEXT_WINDOW") != null) "env" else "auto/backend";
                main.stderrPrint("[config] MemAct: window={d} ({s}), top_k={d}, budget={d}, extract={s}\n", .{
                    context_window, window_src, memact_top_k, memact_memory_budget, memact_extract,
                });
            }
        }

        return .{
            .execution_mode = exec_mode,
            .openai_protocol = openai_proto,
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
            .memact_enabled = memact_enabled,
            .context_window = context_window,
            .ctx_safety_margin = ctx_safety_margin,
            .ctx_compact_threshold = ctx_compact_threshold,
            .memact_top_k = memact_top_k,
            .memact_memory_budget = memact_memory_budget,
            .memact_extract = memact_extract,
            .memory_dir = memory_dir,
            .budget_max_tokens = budget_max_tokens,
            .mcp_config_path = env_map.get("MINI_MCP_CONFIG"),
            .history_enabled = history_enabled,
            .hook_command = hook_cmd,
            .hooks_config_path = hooks_cfg,
            .session_id = session_id,
            .session_file = session_file,
        };
    }

    /// Giải phóng bộ nhớ được cấp phát (system_prompt_buf + skills arena).
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

fn loadSystemPrompt(alloc: Allocator, env_map: *const std.process.Environ.Map, io: std.Io) SpResult {
    var base_buf: ?[]u8 = null;
    var base_text: []const u8 = Config.default_system_prompt;

    if (env_map.get("MINI_SYSTEM_FILE")) |path| {
        const cwd = std.Io.Dir.cwd();
        if (cwd.openFile(io, path, .{})) |file| {
            defer file.close(io);
            if (file.stat(io)) |stat| {
                if (stat.size > 0 and stat.size <= 64 * 1024) {
                    if (alloc.alloc(u8, @intCast(stat.size))) |buf| {
                        if (utils.readAll(io, file, buf)) |n| {
                            base_buf = buf;
                            base_text = buf[0..n];
                            if (!utils.isSubagent()) main.stderrPrint("[config] System prompt: {s} ({d} bytes)\n", .{ path, n });
                        } else |_| {
                            alloc.free(buf);
                        }
                    } else |_| {}
                }
            } else |_| {}
        } else |_| {
            if (!utils.isSubagent()) main.stderrPrint("[config] Không mở được system prompt: {s}, dùng default.\n", .{path});
        }
    }

    var result = SpResult{ .buf = base_buf, .text = base_text };

    var agents_text_accum = std.ArrayList(u8).empty;
    defer agents_text_accum.deinit(alloc);

    // 1. Global AGENTS.md (~/.mini/AGENTS.md)
    if (env_map.get("HOME")) |home| {
        const global_path = std.fmt.allocPrint(alloc, "{s}/.mini/AGENTS.md", .{home}) catch null;
        if (global_path) |gp| {
            defer alloc.free(gp);
            if (readAgentFile(alloc, io, gp)) |text| {
                defer alloc.free(text);
                agents_text_accum.appendSlice(alloc, text) catch {};
                agents_text_accum.appendSlice(alloc, "\n\n") catch {};
                if (!utils.isSubagent()) main.stderrPrint("[config] Loaded global AGENTS.md ({d} bytes)\n", .{text.len});
            }
        }
    }

    // 2. Project AGENTS.md (MINI_AGENT_FOLDER/AGENTS.md)
    if (env_map.get("MINI_AGENT_FOLDER")) |agent_dir| {
        const project_path = std.fmt.allocPrint(alloc, "{s}/AGENTS.md", .{agent_dir}) catch null;
        if (project_path) |pp| {
            defer alloc.free(pp);
            if (readAgentFile(alloc, io, pp)) |text| {
                defer alloc.free(text);
                agents_text_accum.appendSlice(alloc, text) catch {};
                agents_text_accum.appendSlice(alloc, "\n\n") catch {};
                if (!utils.isSubagent()) main.stderrPrint("[config] Loaded project AGENTS.md ({d} bytes)\n", .{text.len});
            }
        }
    }

    if (agents_text_accum.items.len > 0) {
        const combined_text = std.fmt.allocPrint(alloc, "{s}\n\n<RULE[AGENTS.md]>\n{s}</RULE[AGENTS.md]>\n", .{ result.text, agents_text_accum.items }) catch return appendSkillsBlock(alloc, env_map, io, result);
        if (result.buf) |b| alloc.free(b);
        result = .{ .buf = combined_text, .text = combined_text };
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

/// Inject skills block vào cuối system prompt.
/// Load skills từ đĩa trước (loadSkills), rồi build block và nối vào.
/// Trả về SpResult mới; nếu không có skill nào, trả về nguyên bản.
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

/// Tải biến môi trường từ các file .env theo thứ tự ưu tiên:
///   1. $MINI_ENV_FILE — đường dẫn tường minh
///   2. ./.env         — thư mục hiện tại
///   3. ~/.mini/.env   — user-level
///
/// Shell env variables luôn có ưu tiên cao hơn (setenv overwrite=0).
/// Hỗ trợ cú pháp: `KEY=VALUE`, `KEY="VALUE"`, `KEY='VALUE'`,
///                 `export KEY=VALUE`, `# comment`, dòng trống.
pub const JsonConfig = struct {
    execution_mode: ?[]const u8 = null,
    openai_protocol: ?[]const u8 = null,
    openai_compat_url: ?[]const u8 = null,
    openai_compat_api_key: ?[]const u8 = null,
    openai_compat_api_header: ?[]const u8 = null,
    openai_compat_model: ?[]const u8 = null,
    openai_compat_use_completion_tokens: ?bool = null,
    anthropic_api_key: ?[]const u8 = null,
    claude_model: ?[]const u8 = null,
    ollama_host: ?[]const u8 = null,
    ollama_model: ?[]const u8 = null,
    max_tokens: ?u32 = null,
    memact_enabled: ?bool = null,
    context_window: ?u32 = null,
    tool_allowlist: ?[]const u8 = null,
    tool_blocklist: ?[]const u8 = null,
    mcp_config: ?[]const u8 = null,
    hook_command: ?[]const u8 = null,
    session: ?[]const u8 = null,
};

/// Tải biến môi trường từ các file .env và config.json theo thứ tự ưu tiên:
///   1. $MINI_ENV_FILE
///   2. ./.env
///   3. .agent/.env
///   4. ~/.mini/.env
///   5. .agent/config.json
///   6. ~/.mini/config.json
pub fn loadDotEnv(alloc: Allocator, env_map: *std.process.Environ.Map, io: std.Io) void {
    const home = env_map.get("HOME");

    // 1. Tải các file .env
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

    {
        const name = ".env";
        @memcpy(paths[n][0..name.len], name);
        path_lens[n] = name.len;
        n += 1;
    }

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

    // 2. Tải các file config.json (project -> global)
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

fn tryLoadJsonConfig(alloc: Allocator, env_map: *std.process.Environ.Map, io: std.Io, path: []const u8) void {
    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, path, .{}) catch return;
    defer file.close(io);

    const stat = file.stat(io) catch return;
    if (stat.size == 0 or stat.size > 64 * 1024) return;

    const buf = alloc.alloc(u8, @intCast(stat.size)) catch return;
    defer alloc.free(buf);

    const n = utils.readAll(io, file, buf) catch return;
    const data = buf[0..n];

    var parsed = std.json.parseFromSlice(JsonConfig, alloc, data, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();

    const cfg = parsed.value;
    var count: usize = 0;

    if (cfg.execution_mode) |val| count += setEnvDefault(env_map, "MINI_EXECUTION_MODE", val);
    if (cfg.openai_protocol) |val| count += setEnvDefault(env_map, "OPENAI_PROTOCOL", val);
    if (cfg.openai_compat_url) |val| count += setEnvDefault(env_map, "OPENAI_COMPAT_URL", val);
    if (cfg.openai_compat_api_key) |val| count += setEnvDefault(env_map, "OPENAI_COMPAT_API_KEY", val);
    if (cfg.openai_compat_api_header) |val| count += setEnvDefault(env_map, "OPENAI_COMPAT_API_HEADER", val);
    if (cfg.openai_compat_model) |val| count += setEnvDefault(env_map, "OPENAI_COMPAT_MODEL", val);
    if (cfg.openai_compat_use_completion_tokens) |val| count += setEnvDefault(env_map, "MINI_USE_COMPLETION_TOKENS", if (val) "1" else "0");
    if (cfg.anthropic_api_key) |val| count += setEnvDefault(env_map, "ANTHROPIC_API_KEY", val);
    if (cfg.claude_model) |val| count += setEnvDefault(env_map, "CLAUDE_MODEL", val);
    if (cfg.ollama_host) |val| count += setEnvDefault(env_map, "OLLAMA_HOST", val);
    if (cfg.ollama_model) |val| count += setEnvDefault(env_map, "OLLAMA_MODEL", val);
    if (cfg.max_tokens) |val| {
        var num_buf: [32]u8 = undefined;
        if (std.fmt.bufPrint(&num_buf, "{d}", .{val})) |s| count += setEnvDefault(env_map, "MINI_MAX_TOKENS", s) else |_| {}
    }
    if (cfg.memact_enabled) |val| count += setEnvDefault(env_map, "MINI_MEMACT_ENABLED", if (val) "1" else "0");
    if (cfg.context_window) |val| {
        var num_buf: [32]u8 = undefined;
        if (std.fmt.bufPrint(&num_buf, "{d}", .{val})) |s| count += setEnvDefault(env_map, "MINI_CONTEXT_WINDOW", s) else |_| {}
    }
    if (cfg.tool_allowlist) |val| count += setEnvDefault(env_map, "MINI_TOOL_ALLOWLIST", val);
    if (cfg.tool_blocklist) |val| count += setEnvDefault(env_map, "MINI_TOOL_BLOCKLIST", val);
    if (cfg.mcp_config) |val| count += setEnvDefault(env_map, "MINI_MCP_CONFIG", val);
    if (cfg.hook_command) |val| count += setEnvDefault(env_map, "MINI_HOOK_COMMAND", val);
    if (cfg.session) |val| count += setEnvDefault(env_map, "MINI_SESSION", val);

    if (count > 0) {
        if (!utils.isSubagent()) main.stderrPrint("[config] Loaded {d} settings from {s}\n", .{ count, path });
    }
}

fn setEnvDefault(env_map: *std.process.Environ.Map, key: []const u8, val: []const u8) usize {
    if (env_map.get(key) != null) return 0;
    env_map.put(key, val) catch return 0;
    return 1;
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
        \\  "memact_enabled": true
        \\}
    ;

    var parsed = try std.json.parseFromSlice(JsonConfig, alloc, json_str, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("codeact", parsed.value.execution_mode.?);
    try std.testing.expectEqualStrings("responses", parsed.value.openai_protocol.?);
    try std.testing.expectEqualStrings("gpt-4o", parsed.value.openai_compat_model.?);
    try std.testing.expectEqual(4096, parsed.value.max_tokens.?);
    try std.testing.expectEqual(true, parsed.value.memact_enabled.?);
}
