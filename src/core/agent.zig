//! agent.zig — AgentLoop: vòng lặp chính của mini-agent.
//!
//! AgentLoop xử lý một user input qua nhiều iterations cho đến khi
//! AI trả về `end_turn` (không còn muốn gọi tool).
//!
//! ## Luồng một iteration
//! ```
//! user_text → history.addUser()
//!           → sendToBackend(system, history, tools)  ← streaming
//!           → response.stop_reason == .tool_use?
//!               YES → executeTools() → history.addToolResults() → tiếp tục
//!               NO  → kết thúc, trả về
//! ```
//!
//! ## Backends
//! Agent ưu tiên backend theo thứ tự:
//!   1. OpenAI-compatible (nếu có OPENAI_COMPAT_URL)
//!   2. Claude (nếu có ANTHROPIC_API_KEY)
//!   3. Ollama (fallback local)
//!
//! ## Fallback
//! Nếu primary backend lỗi, agent thử các backend còn lại.
//!
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const proto = @import("protocol.zig");
const config_mod = @import("config.zig");
const history_mod = @import("history.zig");
const tools_mod = @import("../tooling/registry.zig");
const json_mod = @import("json.zig");
const openai_mod = @import("../backends/openai.zig");
const claude_mod = @import("../backends/claude.zig");
const ollama_mod = @import("../backends/ollama.zig");
const hooks_mod = @import("hooks.zig");
const main = @import("../main.zig");
const utils = @import("utils.zig");
const quickjs = @import("../runtime/quickjs_engine.zig");
const js_bindings = @import("../runtime/js_bindings.zig");
const tokens_mod = @import("memact/tokens.zig");
const snapshot_mod = @import("snapshot.zig");
const cas_mod = @import("cas.zig");
pub const journal_mod = @import("journal.zig");
pub const signals = @import("signals.zig");

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
fn getEnvVar(name: [*:0]const u8) ?[]const u8 {
    if (getenv(name)) |ptr| {
        return std.mem.span(ptr);
    }
    return null;
}

/// Số lần retry tối đa khi gặp rate limit.
const MAX_RATE_LIMIT_RETRIES = 5;
/// Thời gian chờ ban đầu khi gặp rate limit (giây).
const RATE_LIMIT_BASE_DELAY_S: u64 = 5;

// ---------------------------------------------------------------------------
// Backend union
// ---------------------------------------------------------------------------

/// Backend AI đang sử dụng.
pub const Backend = union(enum) {
    openai: openai_mod.Client,
    claude: claude_mod.Client,
    ollama: ollama_mod.Client,

    /// Tên hiển thị của backend.
    pub fn name(self: Backend) []const u8 {
        return switch (self) {
            .openai => "openai-compat",
            .claude => "claude",
            .ollama => "ollama",
        };
    }

    /// Tên model đang dùng.
    pub fn model(self: Backend) []const u8 {
        return switch (self) {
            .openai => |c| c.model,
            .claude => |c| c.model,
            .ollama => |c| c.model,
        };
    }

    /// Gửi message đến backend. Trả về Response đầy đủ.
    fn send(
        self: *Backend,
        system_prompt: []const u8,
        msgs: []const proto.Message,
        tool_defs: []const proto.ToolDefinition,
        text_cb: ?*const fn ([]const u8) void,
        think_cb: ?*const fn ([]const u8) void,
    ) !proto.Response {
        return switch (self.*) {
            .openai => |*c| c.sendMessage(system_prompt, msgs, tool_defs, text_cb, think_cb),
            .claude => |*c| c.sendMessage(system_prompt, msgs, tool_defs, text_cb, think_cb),
            .ollama => |*c| c.sendMessage(system_prompt, msgs, tool_defs, text_cb, think_cb),
        };
    }
};

// ---------------------------------------------------------------------------
// AgentLoop
// ---------------------------------------------------------------------------

/// Vòng lặp agent chính.
pub const AgentLoop = struct {
    alloc: Allocator,
    io: std.Io,
    /// Backend đang sử dụng.
    backend: Backend,
    /// Lịch sử hội thoại.
    history: history_mod.History,
    /// Config đã load.
    config: *const config_mod.Config,
    /// QuickJS-ng embedded engine cho CodeAct.
    engine: *quickjs.Engine,
    /// Đếm số lần tự sửa lỗi JavaScript liên tiếp.
    js_retry_count: usize = 0,
    /// Đếm số lần sửa lỗi role/first-message (Claude 400) trong turn.
    role_fix_attempts: usize = 0,
    /// Đếm số lần liên tiếp response bị cắt do max_tokens trong turn.
    max_tokens_continues: usize = 0,
    /// Trình ước lượng token (MemAct).
    token_estimator: tokens_mod.TokenEstimator,
    /// Content-Addressed Storage (RFC-002).
    cas: cas_mod.CAS,
    /// Act Journal (RFC-002). Null nếu chưa processInput.
    journal: ?journal_mod.ActJournal = null,
    /// Snapshot tracker (RFC-002/ISSUE-CODEACT-001 M4) — track mini.write/patch/sh.
    snapshot_tracker: ?snapshot_mod.SnapshotTracker = null,
    /// HTTP code của lỗi backend gần nhất (đưa vào journal ErrorDetail).
    last_backend_http_code: u32 = 0,
    /// Raw body lỗi backend gần nhất (bản dupe, agent sở hữu — đưa vào journal).
    last_backend_raw_error: ?[]u8 = null,
    /// Số act đã chạy trong turn gần nhất.
    last_turn_acts: usize = 0,
    /// Số token completion đã nhận trong turn gần nhất.
    last_turn_completion_tokens: usize = 0,

    pub const Error = error{
        LLMAuthenticationError,
        LLMRateLimitExceeded,
        LLMProviderUnavailable,
        LLMMalformedJsonOutput,
        LLMContextWindowExceeded,
        UnknownStopReason,
        UserCancelled,
    };

    /// Khởi tạo AgentLoop từ config.
    /// Chọn backend dựa trên config theo thứ tự ưu tiên.
    pub fn init(alloc: Allocator, io: std.Io, config: *const config_mod.Config) !AgentLoop {
        // Khởi tạo QuickJS-ng engine & đăng ký mini bindings
        const engine = try quickjs.Engine.init(alloc, io);
        errdefer engine.deinit();
        try js_bindings.registerBindings(engine);

        // Chọn backend theo thứ tự ưu tiên
        const backend: Backend = blk: {
            if (config.openai_compat_url) |url| {
                main.stderrPrint("[agent] Backend: OpenAI-compat @ {s} ({s})\n", .{ url, config.openai_compat_model });
                break :blk .{ .openai = openai_mod.Client.init(
                    alloc,
                    url,
                    config.openai_compat_key orelse "",
                    config.openai_compat_api_header,
                    config.openai_compat_model,
                    config.max_tokens,
                ) };
            }
            if (config.anthropic_key) |key| {
                main.stderrPrint("[agent] Backend: Claude ({s})\n", .{config.claude_model});
                break :blk .{ .claude = claude_mod.Client.init(
                    alloc,
                    key,
                    config.claude_model,
                    config.max_tokens,
                ) };
            }
            // Fallback: Ollama
            main.stderrPrint("[agent] Backend: Ollama @ {s} ({s})\n", .{ config.ollama_url, config.ollama_model });
            break :blk .{ .ollama = ollama_mod.Client.init(
                alloc,
                config.ollama_url,
                config.ollama_model,
                config.max_tokens,
            ) };
        };

        // Thiết lập tool policy
        tools_mod.setPolicy(config.tool_allowlist, config.tool_blocklist);

        var path_buf: [256]u8 = undefined;
        const home_dir = getEnvVar("HOME") orelse ".";
        const cas_path = try std.fmt.bufPrint(&path_buf, "{s}/.mini/cas", .{home_dir});
        const cas = try cas_mod.CAS.init(alloc, io, cas_path);

        return .{
            .alloc = alloc,
            .io = io,
            .backend = backend,
            .history = history_mod.History.init(alloc),
            .config = config,
            .engine = engine,
            .js_retry_count = 0,
            .token_estimator = tokens_mod.TokenEstimator.init(alloc),
            .cas = cas,
            .journal = null,
        };
    }

    /// Giải phóng bộ nhớ.
    pub fn deinit(self: *AgentLoop) void {
        if (self.snapshot_tracker) |*t| {
            snapshot_mod.setTracker(null);
            t.deinit();
        }
        self.history.deinit();
        self.engine.deinit();
        self.token_estimator.deinit();
        self.cas.deinit();
        if (self.journal) |*j| j.deinit();
        if (self.last_backend_raw_error) |raw| self.alloc.free(raw);
    }

    /// Lưu ngữ cảnh lỗi backend gần nhất để journal recordError dùng sau đó.
    /// Dupe raw (response bị deinit trước khi error bubble lên processInput).
    fn setLastErrorContext(self: *AgentLoop, http_code: u32, raw: ?[]const u8) void {
        self.last_backend_http_code = http_code;
        if (self.last_backend_raw_error) |old| self.alloc.free(old);
        self.last_backend_raw_error = null;
        if (raw) |r| {
            self.last_backend_raw_error = self.alloc.dupe(u8, r) catch null;
        }
    }

    const StepResult = enum {
        continue_loop,
        exit_loop,
    };

    fn executeStep(
        self: *AgentLoop,
        act_id: usize,
        tool_defs: []const proto.ToolDefinition,
        text_cb: ?*const fn ([]const u8) void,
        think_cb: ?*const fn ([]const u8) void,
    ) !StepResult {
        if (signals.isInterrupted()) return error.Interrupted;

        if (main.ui_repl.current_renderer == null) {
            if (act_id > 1) {
                main.stderrPrint("\x1b[90m[agent] --- Vòng lặp {d} ---\x1b[0m\n", .{act_id});
            } else {
                main.stderrPrint("\n\x1b[90m[agent] --- Bắt đầu quy trình ---\x1b[0m\n", .{});
            }
            main.stderrPrint("\x1b[36m[agent]\x1b[0m \x1b[93mĐang suy nghĩ / Phân tích yêu cầu... \x1b[0m\n", .{});
        }

        // Gửi lên AI backend (streaming)
        var response = try self.sendToBackend(
            act_id,
            self.config.system_prompt,
            self.history.messages(),
            tool_defs,
            text_cb,
            think_cb,
        );
        main.resetThinkState();
        if (signals.isInterrupted()) {
            response.deinit();
            return error.Interrupted;
        }
        
        defer response.deinit();

        // Xuống dòng sau khi stream xong
        if (main.ui_repl.current_renderer == null) {
            try std.Io.File.stdout().writeStreamingAll(self.io, "\n");
        }

        // Thêm response vào history (nếu có nội dung)
        _ = try self.history.addAssistantResponse(&response);

        // Tích luỹ token completion
        for (response.content.items) |block| {
            switch (block) {
                .text => |t| self.last_turn_completion_tokens += self.token_estimator.estimate(t),
                .thinking => |th| self.last_turn_completion_tokens += self.token_estimator.estimate(th.thinking),
                .tool_use => |tu| self.last_turn_completion_tokens += self.token_estimator.estimate(tu.name) + self.token_estimator.estimate(tu.input_json),
                else => {},
            }
        }

        // 1. CodeAct: Kiểm tra có khối mã JavaScript trong response không
        if (self.config.execution_mode != .tools) {
            if (findJsCodeInResponse(self.alloc, &response)) |js_code| {
                defer self.alloc.free(js_code);

                const start_codeact_ms = utils.milliTimestamp();
                if (main.ui_repl.current_renderer) |r| {
                    r.startTool("codeact", "{}");
                } else {
                    main.stderrPrint("\x1b[90m[codeact]\x1b[0m \x1b[35mExecuting QuickJS-ng script...\x1b[0m ", .{});
                }

                signals.registerActiveEngine(self.engine);
                defer signals.registerActiveEngine(null);

                var res = self.engine.eval(js_code, "agent_codeact.js") catch |e| {
                    const end_err_ms = utils.milliTimestamp();
                    const dur_ms = if (end_err_ms >= start_codeact_ms) @as(u64, @intCast(end_err_ms - start_codeact_ms)) else 0;
                    if (signals.isInterrupted()) return error.Interrupted;
                    if (main.ui_repl.current_renderer) |r| {
                        r.finishTool("codeact", @errorName(e), true, dur_ms, null, null);
                    } else {
                        main.stderrPrint("\x1b[31m[engine error: {s}]\x1b[0m\n", .{@errorName(e)});
                    }
                    const err_msg = try std.fmt.allocPrint(self.alloc, "[CodeAct System Error]: {s}", .{@errorName(e)});
                    defer self.alloc.free(err_msg);
                    try self.history.addUser(err_msg);
                    return .continue_loop;
                };
                defer res.deinit();

                if (signals.isInterrupted()) return error.Interrupted;

                const end_codeact_ms = utils.milliTimestamp();
                const dur_ms = if (end_codeact_ms >= start_codeact_ms) @as(u64, @intCast(end_codeact_ms - start_codeact_ms)) else 0;

                if (!res.is_error) {
                    if (main.ui_repl.current_renderer) |r| {
                        r.finishTool("codeact", if (res.return_value_json) |ret| ret else res.stdout, false, dur_ms, null, null);
                    } else {
                        main.stderrPrint("\x1b[32m[ok]\x1b[0m\n", .{});
                    }
                    self.js_retry_count = 0;

                    var out_buf = utils.BufWriter.init(self.alloc);
                    defer out_buf.deinit();

                    try out_buf.writeAll("[CodeAct Execution Output]\n");
                    if (res.stdout.len > 0) {
                        try out_buf.print("stdout:\n{s}\n", .{res.stdout});
                    }
                    if (res.return_value_json) |ret| {
                        try out_buf.print("return value:\n{s}\n", .{ret});
                    }
                    if (res.stdout.len == 0 and res.return_value_json == null) {
                        try out_buf.writeAll("(Code executed successfully with no output)\n");
                    }

                    try self.history.addUser(out_buf.list.items);
                    return .continue_loop;
                } else {
                    if (main.ui_repl.current_renderer) |r| {
                        r.finishTool("codeact", if (res.error_message) |m| m else "JS Error", true, dur_ms, null, null);
                    } else {
                        main.stderrPrint("\x1b[31m[error]\x1b[0m\n", .{});
                    }
                    self.js_retry_count += 1;

                    var err_buf = utils.BufWriter.init(self.alloc);
                    defer err_buf.deinit();

                    try err_buf.writeAll("[CodeAct JavaScript Error]\n");
                    if (res.error_message) |m| {
                        try err_buf.print("Error: {s}\n", .{m});
                    }
                    if (res.stack_trace) |st| {
                        try err_buf.print("Stack trace:\n{s}\n", .{st});
                    }
                    if (res.stdout.len > 0) {
                        try err_buf.print("stdout before error:\n{s}\n", .{res.stdout});
                    }
                    if (self.js_retry_count >= 3) {
                        try err_buf.writeAll("Notice: 3 consecutive JavaScript execution errors occurred. You may fall back to standard tool calling or simplify your code.\n");
                    } else {
                        try err_buf.writeAll("Please analyze the error and retry by outputting corrected JavaScript code inside ```js ... ``` block.\n");
                    }

                    try self.history.addUser(err_buf.list.items);
                    return .continue_loop;
                }
            }
        }

        switch (response.stop_reason) {
            .end_turn, .stop_sequence => {
                if (main.ui_repl.current_renderer == null) {
                    main.stderrPrint("\n\x1b[92m[agent] ✓ Hoàn thành sau {d} vòng lặp.\x1b[0m\n", .{act_id});
                }
                return .exit_loop;
            },
            .max_tokens => {
                // Response bị cắt giữa chừng. KHÔNG exit — chèn observation
                // yêu cầu model tiếp tục đúng từ chỗ dừng (không lặp lại phần đã
                // viết) để hoàn thành khối đang dở (JS block / tool_use / văn bản).
                self.max_tokens_continues += 1;
                main.stderrPrint("\n\x1b[33m[agent] ⚠️ Response bị cắt (max_tokens), yêu cầu tiếp tục (lần {d})...\x1b[0m\n", .{self.max_tokens_continues});
                var buf = utils.BufWriter.init(self.alloc);
                defer buf.deinit();
                try buf.print(
                    "[System] Phản hồi vừa rồi bị cắt do đạt giới hạn max_tokens (lần {d}). Hãy tiếp tục ĐÚNG từ chỗ dừng — không lặp lại phần đã viết, không giới thiệu lại. Nếu khối ```js ... ``` hoặc tool call đang dở dang, viết tiếp phần còn lại để hoàn thành.",
                    .{self.max_tokens_continues},
                );
                try self.history.addUser(buf.list.items);
                return .continue_loop;
            },
            .tool_use => {
                try self.executeTools(act_id, &response);
                main.stderrPrint("\n", .{});
                return .continue_loop;
            },
            .unknown => {
                // Phân loại lỗi HTTP. Capture ngữ cảnh trước để error bubble lên
                // processInput vẫn ghi đủ journal (response bị deinit trên đường).
                if (response.http_code >= 400) {
                    self.setLastErrorContext(response.http_code, response.raw_debug_info);
                }
                if (response.http_code == 401 or response.http_code == 403) return error.LLMAuthenticationError;
                if (response.http_code == 429) return error.LLMRateLimitExceeded;
                if (response.http_code >= 500 and response.http_code < 600) return error.LLMProviderUnavailable;

                if (response.http_code == 400) {
                    if (response.raw_debug_info) |raw| {
                        if (std.mem.indexOf(u8, raw, "context_length_exceeded") != null or 
                            std.mem.indexOf(u8, raw, "max_tokens") != null) {
                            return error.LLMContextWindowExceeded;
                        }
                    }
                }

                if (response.raw_debug_info) |raw| {
                    if (std.mem.indexOf(u8, raw, "rate_limit") != null) return error.LLMRateLimitExceeded;
                }

                // Detect lỗi role/first-message: Claude từ chối do thứ tự role
                // (ví dụ first message không phải user, hoặc role không hợp lệ).
                if (response.http_code == 400) {
                    if (response.raw_debug_info) |raw| {
                        const has_first_msg = std.mem.indexOf(u8, raw, "first message") != null;
                        const has_role_and_assistant = std.mem.indexOf(u8, raw, "role") != null and
                            std.mem.indexOf(u8, raw, "assistant") != null;
                        if (has_first_msg or has_role_and_assistant) {
                            main.stderrPrint("\n\x1b[33m[agent] Claude từ chối do thứ tự role (HTTP 400). Đang sửa history...\x1b[0m\n", .{});
                            _ = self.history.ensureClaudeCompatible();
                            if (self.role_fix_attempts < 2) {
                                self.role_fix_attempts += 1;
                                // Retry executeStep với history đã sửa, không đi qua nhánh error/retry-truncate
                                return .continue_loop;
                            }
                            // Vượt số lần cho phép — rơi xuống error như cũ
                        }
                    }
                }

                main.stderrPrint("[agent] Cảnh báo: stop_reason không xác định (HTTP {d})\n", .{response.http_code});
                if (response.raw_debug_info) |raw| {
                    main.stderrPrint("\n--- RAW BACKEND RESPONSE ---\n{s}\n----------------------------\n", .{raw});
                } else {
                    main.stderrPrint("\n--- RAW BACKEND RESPONSE ---\n(Không có nội dung trả về từ server)\n----------------------------\n", .{});
                }
                // Đảm bảo ngữ cảnh đã capture (HTTP < 400 nhưng response rác)
                self.setLastErrorContext(response.http_code, response.raw_debug_info);
                return error.UnknownStopReason;
            },
        }
    }

    /// Xử lý input của user qua agentic loop.
    /// `text_cb`: được gọi với mỗi text chunk khi AI đang stream.
    pub fn processInput(
        self: *AgentLoop,
        user_text: []const u8,
        text_cb: ?*const fn ([]const u8) void,
        think_cb: ?*const fn ([]const u8) void,
    ) !void {
        // Cấp phát ArenaAllocator riêng cho từng lượt xử lý (turn-scoped memory)
        var turn_arena = std.heap.ArenaAllocator.init(self.alloc);
        defer turn_arena.deinit();
        const turn_alloc = turn_arena.allocator();

        // Phát pre-prompt hook
        hooks_mod.dispatch(turn_alloc, self.io, .{
            .event = "pre-prompt",
            .user_prompt = user_text,
        });
        defer {
            hooks_mod.dispatch(turn_alloc, self.io, .{
                .event = "post-response",
                .user_prompt = user_text,
            });
        }

        // Thêm user message vào history
        try self.history.addUser(user_text);

        // Reset turn metrics
        self.last_turn_acts = 0;
        self.last_turn_completion_tokens = 0;

        // Reset bộ đếm retry sửa lỗi role cho turn mới
        self.role_fix_attempts = 0;
        // Reset bộ đếm continue-max_tokens cho turn mới
        self.max_tokens_continues = 0;

        // Lấy danh sách tools phù hợp với user message dựa trên execution_mode
        const tool_defs = switch (self.config.execution_mode) {
            .codeact => &[_]proto.ToolDefinition{}, // Tắt 100% mảng tools gửi lên API khi ở mode codeact để ép LLM viết JS CodeAct
            .tools => blk: {
                const all_defs = tools_mod.getRelevantDefinitions(turn_alloc, user_text);
                var list = std.ArrayListUnmanaged(proto.ToolDefinition).empty;
                for (all_defs) |td| {
                    if (!std.mem.eql(u8, td.name, "codeact")) {
                        list.append(turn_alloc, td) catch {};
                    }
                }
                break :blk list.items;
            },
            .auto => tools_mod.getRelevantDefinitions(turn_alloc, user_text),
        };


        if (self.journal == null) {
            var path_buf: [256]u8 = undefined;
            const home_dir = getEnvVar("HOME") orelse ".";
            const journal_path = std.fmt.bufPrint(&path_buf, "{s}/.mini/sessions/journal_{d}.jsonl", .{ home_dir, std.os.linux.getpid() }) catch "/tmp/mini_journal.jsonl";
            self.journal = journal_mod.ActJournal.init(self.alloc, self.io, journal_path) catch null;
        }

        // ISSUE-CODEACT-001 M4: snapshot tracker dùng chung CAS, global cho mini.* bindings
        if (self.snapshot_tracker == null) {
            self.snapshot_tracker = snapshot_mod.SnapshotTracker.init(self.alloc, self.io, &self.cas, if (self.journal != null) &self.journal.? else null);
            snapshot_mod.setTracker(if (self.snapshot_tracker != null) &self.snapshot_tracker.? else null);
        }

        var act_id: usize = 1;
        var rate_limit_retries: usize = 0;
        const max_retries = 3;

        // Không giới hạn số act — model tự quyết định khi nào dừng (exit_loop).
        while (true) : (act_id += 1) {
            self.last_turn_acts = act_id;
            var try_count: usize = 0;

            while (try_count <= max_retries) : (try_count += 1) {
                if (self.journal) |*j| j.recordEvent(self.io, act_id, .act_started, "Bắt đầu Act") catch {};

                const history_len = self.history.messages().len;

                const result = self.executeStep(act_id, tool_defs, text_cb, think_cb) catch |e| {
                    switch (e) {
                        error.Interrupted => {
                            if (main.ui_repl.current_renderer) |r| {
                                r.stopWaiting();
                                if (r.is_thinking) r.endThinking();
                                r.ensureNewline();
                                r.write(" \x1b[33m[Đã dừng bởi người dùng (Ctrl+C)]\x1b[0m\n");
                            } else {
                                main.stderrPrint("\n\x1b[33m[Đã dừng bởi người dùng (Ctrl+C)]\x1b[0m\n", .{});
                            }
                            if (self.journal) |*j| {
                                j.recordEvent(self.io, act_id, .task_interrupted, "Người dùng đã dừng tác vụ (Ctrl+C)") catch {};
                            }
                            return;
                        },
                        error.LLMAuthenticationError => {
                            main.stderrPrint("\n\x1b[31m[agent] ⛔ Lỗi xác thực/quyền truy cập backend (HTTP {d})! Vui lòng kiểm tra API key hoặc tài khoản.\x1b[0m\n", .{self.last_backend_http_code});
                            if (self.journal) |*j| j.recordError(self.io, act_id, .act_failed, "Lỗi xác thực/quyền backend — abort", .{
                                .backend = self.backend.name(),
                                .model = self.backend.model(),
                                .error_name = @errorName(e),
                                .http_code = self.last_backend_http_code,
                                .attempt = 1,
                                .raw_snippet = self.last_backend_raw_error,
                            }) catch {};
                            return e;
                        },
                        error.LLMRateLimitExceeded, error.LLMProviderUnavailable => {
                            // Journal: đủ ngữ cảnh debug — backend, model, error name,
                            // HTTP code (classify từ response), lần thử, raw body server.
                            if (self.journal) |*j| {
                                const ev_type: journal_mod.ActEventType = if (e == error.LLMRateLimitExceeded)
                                    .llm_call_throttled
                                else
                                    .llm_provider_error;
                                const desc = if (e == error.LLMRateLimitExceeded)
                                    "Rate limit (429) từ backend"
                                else
                                    "Backend lỗi (5xx / provider unavailable)";
                                j.recordError(self.io, act_id, ev_type, desc, .{
                                    .backend = self.backend.name(),
                                    .model = self.backend.model(),
                                    .error_name = @errorName(e),
                                    .http_code = self.last_backend_http_code,
                                    .attempt = rate_limit_retries + 1,
                                    .raw_snippet = self.last_backend_raw_error,
                                }) catch {};
                            }
                            
                            rate_limit_retries += 1;
                            if (rate_limit_retries > 5) return e; // Giới hạn 5 lần
                            
                            const backoff_s: u64 = (@as(u64, 1) << @as(u6, @intCast(rate_limit_retries))) * 2;
                            main.stderrPrint("\n\x1b[33m[agent] ⚠ Rate limit / 503! Thử lại sau {d}s...\x1b[0m\n", .{ backoff_s });
                            std.Io.sleep(self.io, std.Io.Duration.fromSeconds(@intCast(backoff_s)), .awake) catch {};
                            
                            if (self.history.last_compaction_act_id < act_id) {
                                self.history.truncate(history_len);
                            }
                            continue;
                        },
                        error.LLMContextWindowExceeded => {
                            main.stderrPrint("\n\x1b[33m[agent] ⚠️ Model báo vượt quá context limit (HTTP 400)! Đang nén MemAct khẩn cấp...\x1b[0m\n", .{});
                            if (self.journal) |*j| j.recordError(self.io, act_id, .llm_context_overflow, "Model báo quá tải context — nén MemAct khẩn cấp", .{
                                .backend = self.backend.name(),
                                .model = self.backend.model(),
                                .error_name = @errorName(e),
                                .http_code = self.last_backend_http_code,
                                .attempt = try_count + 1,
                                .raw_snippet = self.last_backend_raw_error,
                            }) catch {};

                            self.compactContext(act_id) catch {
                                self.history.compact();
                            };

                            if (self.history.last_compaction_act_id < act_id) {
                                self.history.truncate(history_len);
                            }
                            continue;
                        },

                        else => {
                            if (try_count == max_retries) {
                                main.stderrPrint("\n[agent] Act {d} lỗi liên tiếp {d} lần. Ngắt tiến trình: {s}\n", .{ act_id, max_retries + 1, @errorName(e) });
                                if (self.journal) |*j| j.recordError(self.io, act_id, .act_failed, "Act lỗi terminal — abort", .{
                                    .backend = self.backend.name(),
                                    .model = self.backend.model(),
                                    .error_name = @errorName(e),
                                    .http_code = self.last_backend_http_code,
                                    .attempt = try_count + 1,
                                    .raw_snippet = self.last_backend_raw_error,
                                }) catch {};
                                if (self.history.last_compaction_act_id < act_id) {
                                    self.history.truncate(history_len);
                                    if (self.journal) |*j| j.recordEvent(self.io, act_id, .rollback_completed, "Rollback state due to terminal error") catch {};
                                }
                                return e;
                            }

                            main.stderrPrint("\n[agent] Act {d} gặp sự cố ({s}). Rollback (lần {d}/{d})...\n", .{ act_id, @errorName(e), try_count + 1, max_retries });
                            
                            if (self.journal) |*j| j.recordError(self.io, act_id, .act_failed, "Act lỗi — rollback & retry", .{
                                .backend = self.backend.name(),
                                .model = self.backend.model(),
                                .error_name = @errorName(e),
                                .http_code = self.last_backend_http_code,
                                .attempt = try_count + 1,
                                .raw_snippet = self.last_backend_raw_error,
                            }) catch {};
                            
                            if (self.history.last_compaction_act_id < act_id) {
                                self.history.truncate(history_len);
                                try self.history.addSystemErrorObservation(@errorName(e));
                                if (self.journal) |*j| j.recordEvent(self.io, act_id, .rollback_completed, "Rollback state due to error") catch {};
                            } else {
                                main.stderrPrint("[agent] Không thể rollback vì đã qua mốc nén bộ nhớ.\n", .{});
                                return e;
                            }
                            continue;
                        }
                    }
                };

                // Flush toàn bộ snapshot mini.write/patch/sh đã track trong act này (M4)
                var recorded_delta = false;
                if (self.snapshot_tracker) |*t| {
                    if (t.tracked.items.len > 0) {
                        t.flush(act_id);
                        recorded_delta = true;
                    }
                    t.reset();
                }

                if (!recorded_delta) {
                    if (self.journal) |*j| {
                        j.recordActComplete(self.io, act_id, .{
                            .act_id = act_id,
                            .file_snapshots = &.{}, 
                        }) catch {};
                    }
                }

                if (result == .exit_loop) {
                    if (self.journal) |*j| j.recordEvent(self.io, act_id, .task_completed, "Nhiệm vụ hoàn thành") catch {};
                    return;
                }
                break; 
            }
        }
    }

    /// Xóa lịch sử hội thoại (bắt đầu conversation mới).
    pub fn clearHistory(self: *AgentLoop) void {
        self.history.clear();
    }

    /// Đổi backend tại runtime.
    /// name: "openai", "claude", "ollama"
    pub fn switchBackend(self: *AgentLoop, backend_name: []const u8, model_override: ?[]const u8) void {
        const cfg = self.config;

        if (std.mem.eql(u8, backend_name, "openai") or std.mem.eql(u8, backend_name, "openai-compat")) {
            const url = cfg.openai_compat_url orelse {
                main.stderrPrint("[agent] OPENAI_COMPAT_URL chưa được thiết lập\n", .{});
                return;
            };
            self.backend = .{ .openai = openai_mod.Client.init(
                self.alloc,
                url,
                cfg.openai_compat_key orelse "",
                cfg.openai_compat_api_header,
                model_override orelse cfg.openai_compat_model,
                cfg.max_tokens,
            ) };
        } else if (std.mem.eql(u8, backend_name, "claude")) {
            const key = cfg.anthropic_key orelse {
                main.stderrPrint("[agent] ANTHROPIC_API_KEY chưa được thiết lập\n", .{});
                return;
            };
            self.backend = .{ .claude = claude_mod.Client.init(
                self.alloc,
                key,
                model_override orelse cfg.claude_model,
                cfg.max_tokens,
            ) };
        } else if (std.mem.eql(u8, backend_name, "ollama")) {
            self.backend = .{ .ollama = ollama_mod.Client.init(
                self.alloc,
                cfg.ollama_url,
                model_override orelse cfg.ollama_model,
                cfg.max_tokens,
            ) };
        } else {
            main.stderrPrint("[agent] Backend không hợp lệ: {s}. Chọn: openai, claude, ollama\n", .{backend_name});
            return;
        }

        main.stderrPrint("[agent] Switched to {s} ({s})\n", .{ self.backend.name(), self.backend.model() });
    }

    // -----------------------------------------------------------------------
    // Internal
    // -----------------------------------------------------------------------

    fn sendToBackend(
        self: *AgentLoop,
        act_id: usize,
        system_prompt: []const u8,
        msgs: []const proto.Message,
        tool_defs: []const proto.ToolDefinition,
        text_cb: ?*const fn ([]const u8) void,
        think_cb: ?*const fn ([]const u8) void,
    ) !proto.Response {
        if (signals.isInterrupted()) return error.Interrupted;

        // Primary backend
        const primary = self.backend.send(system_prompt, msgs, tool_defs, text_cb, think_cb);
        if (primary) |resp| return resp else |e| {
            if (e == error.Interrupted or signals.isInterrupted()) {
                return error.Interrupted;
            }
            // Fallback: thử Ollama nếu primary không phải Ollama
            main.stderrPrint("\n[agent] {s} lỗi ({s}), thử Ollama...\n", .{ self.backend.name(), @errorName(e) });
            if (self.backend != .ollama) {
                var fallback = ollama_mod.Client.init(
                    self.alloc,
                    self.config.ollama_url,
                    self.config.ollama_model,
                    self.config.max_tokens,
                );
                if (fallback.sendMessage(system_prompt, msgs, tool_defs, text_cb, think_cb)) |resp| {
                    main.stderrPrint("[agent] Ollama fallback thành công\n", .{});
                    // Journal: primary lỗi (transport/parse — vd ReadFailed) nhưng
                    // fallback thành công. Turn vẫn tiếp tục, nhưng phải ghi lại
                    // lỗi primary để debug từ journal (stderr là ephemeral).
                    if (self.journal) |*j| {
                        j.recordError(self.io, act_id, .llm_provider_error, "Primary backend lỗi, fallback Ollama thành công — tiếp tục turn", .{
                            .backend = self.backend.name(),
                            .model = self.backend.model(),
                            .error_name = @errorName(e),
                            .http_code = self.last_backend_http_code,
                            .attempt = 1,
                            .raw_snippet = self.last_backend_raw_error,
                        }) catch {};
                    }
                    return resp;
                } else |fb_err| {
                    // Journal: fallback cũng thất bại — ghi cả 2 lỗi để debug
                    // (primary + ollama fallback) trong cùng 1 event.
                    if (self.journal) |*j| {
                        const desc = std.fmt.allocPrint(
                            self.alloc,
                            "Primary {s} lỗi ({s}), fallback Ollama cũng lỗi ({s})",
                            .{ self.backend.name(), @errorName(e), @errorName(fb_err) },
                        ) catch "Primary + fallback đều lỗi";
                        defer self.alloc.free(desc);
                        j.recordError(self.io, act_id, .llm_provider_error, desc, .{
                            .backend = self.backend.name(),
                            .model = self.backend.model(),
                            .error_name = @errorName(fb_err),
                            .attempt = 1,
                            .raw_snippet = self.last_backend_raw_error,
                        }) catch {};
                    }
                }
            }
            return e;
        }
    }

    /// Thực hiện nén ngữ cảnh (MemAct compaction) khi model thực sự trả về lỗi quá context limit.
    pub fn compactContext(self: *AgentLoop, act_id: usize) !void {
        if (self.history.messages().len <= 2) {
            self.history.compact();
            return;
        }

        main.stderrPrint("\x1b[33m[agent] Đang tổng hợp tóm tắt ngữ cảnh (MemAct compaction)...\x1b[0m\n", .{});

        if (self.config.memact_enabled) {
            var msg_blocks = try self.alloc.alloc(proto.ContentBlock, 1);
            msg_blocks[0] = .{ .text = try self.alloc.dupe(u8, 
                "SYSTEM: Bạn là bộ nhớ MemAct. Hãy tóm tắt ngắn gọn phần hội thoại trước thành JSON, tuân thủ đúng stencil:\n" ++
                "{\n" ++
                "  \"type\": \"context_summary\",\n" ++
                "  \"iteration_range\": [1, 99],\n" ++
                "  \"task_state\": \"mô tả tiến độ\",\n" ++
                "  \"decisions\": [\"quyết định 1\"],\n" ++
                "  \"open_questions\": [],\n" ++
                "  \"learned_errors\": [],\n" ++
                "  \"files_touched\": [],\n" ++
                "  \"next_step\": \"bước tiếp theo\"\n" ++
                "}\n" ++
                "Nếu hội thoại đầu vào đã chứa block \"[MemAct Context Summary]\", hãy gộp (merge) nội dung summary cũ vào summary mới, giữ lại các thông tin quan trọng, vẫn theo đúng stencil JSON trên.\n" ++
                "Chỉ xuất JSON, không có markdown text khác."
            ) };
            const sys_msg = proto.Message{ .role = .user, .content = msg_blocks };
            defer {
                self.alloc.free(sys_msg.content[0].text);
                self.alloc.free(sys_msg.content);
            }
            
            var temp_msgs = std.ArrayListUnmanaged(proto.Message).empty;
            defer temp_msgs.deinit(self.alloc);
            try temp_msgs.appendSlice(self.alloc, self.history.messages());
            try temp_msgs.append(self.alloc, sys_msg);

            var summary_resp = try self.sendToBackend(act_id, self.config.system_prompt, temp_msgs.items, &[_]proto.ToolDefinition{}, null, null);
            defer summary_resp.deinit();

            var compacted = false;
            for (summary_resp.content.items) |block| {
                if (block == .text) {
                    try self.history.compactMemAct(act_id, block.text);
                    compacted = true;
                    break;
                }
            }
            if (!compacted) {
                main.stderrPrint("[agent] Cảnh báo: LLM không trả về text summary, fallback.\n", .{});
                self.history.compact();
            }
        } else {
            main.stderrPrint("\n\x1b[33m[agent] Lịch sử quá dài (MemAct tắt), đang nén cũ...\x1b[0m\n", .{});
            
            var msg_blocks = try self.alloc.alloc(proto.ContentBlock, 1);
            msg_blocks[0] = .{ .text = try self.alloc.dupe(u8, "SYSTEM: Lịch sử đã đầy. Hãy tóm tắt trạng thái công việc hiện tại (đã làm gì, kết quả ra sao, cần làm gì tiếp). Không gọi tool, chỉ trả về văn bản tóm tắt.") };
            const sys_msg = proto.Message{ .role = .user, .content = msg_blocks };
            defer {
                self.alloc.free(sys_msg.content[0].text);
                self.alloc.free(sys_msg.content);
            }
            
            var temp_msgs = std.ArrayListUnmanaged(proto.Message).empty;
            defer temp_msgs.deinit(self.alloc);
            try temp_msgs.appendSlice(self.alloc, self.history.messages());
            try temp_msgs.append(self.alloc, sys_msg);
            
            var summary_resp = try self.sendToBackend(act_id, self.config.system_prompt, temp_msgs.items, &[_]proto.ToolDefinition{}, null, null);
            defer summary_resp.deinit();
            
            var compacted = false;
            for (summary_resp.content.items) |block| {
                if (block == .text) {
                    try self.history.compactWithSummary(block.text);
                    compacted = true;
                    break;
                }
            }
            if (!compacted) {
                self.history.compact();
            }
        }
    }

    /// Thực thi tất cả tool_use blocks trong response.

    fn executeTools(self: *AgentLoop, act_id: usize, response: *const proto.Response) !void {
        _ = act_id;
        var results = ArrayList(proto.ToolResult).empty;
        defer results.deinit(self.alloc);
        
        var allocated_strings = ArrayList([]u8).empty;
        defer {
            for (allocated_strings.items) |s| self.alloc.free(s);
            allocated_strings.deinit(self.alloc);
        }

        for (response.content.items) |block| {
            if (signals.isInterrupted()) return error.Interrupted;
            switch (block) {
                .tool_use => |tu| {
                    const start_tool_ms = utils.milliTimestamp();
                    if (main.ui_repl.current_renderer) |r| {
                        r.startTool(tu.name, tu.input_json);
                    } else {
                        // Hiển thị tên tool và tham số chính (fallback log)
                        if (std.mem.eql(u8, tu.name, "bash")) {
                            if (json_mod.findString(tu.input_json, "command")) |cmd| {
                                var cmd_buf: [100]u8 = undefined;
                                const display_cmd = if (cmd.len > 97) std.fmt.bufPrint(&cmd_buf, "{s}...", .{cmd[0..97]}) catch cmd else cmd;
                                main.stderrPrint("\x1b[90m[bash]\x1b[0m \x1b[35m{s}\x1b[0m ", .{display_cmd});
                            } else {
                                main.stderrPrint("\x1b[90m[tool: {s}]\x1b[0m ", .{tu.name});
                            }
                        } else if (std.mem.eql(u8, tu.name, "file_read") or std.mem.eql(u8, tu.name, "file_write") or std.mem.eql(u8, tu.name, "file_edit")) {
                            if (json_mod.findString(tu.input_json, "path")) |path| {
                                main.stderrPrint("\x1b[90m[{s}]\x1b[0m \x1b[34m{s}\x1b[0m ", .{tu.name, path});
                            } else {
                                main.stderrPrint("\x1b[90m[tool: {s}]\x1b[0m ", .{tu.name});
                            }
                        } else if (std.mem.eql(u8, tu.name, "web_search")) {
                            if (json_mod.findString(tu.input_json, "query")) |query| {
                                main.stderrPrint("\x1b[90m[search]\x1b[0m \x1b[32m{s}\x1b[0m ", .{query});
                            } else {
                                main.stderrPrint("\x1b[90m[tool: {s}]\x1b[0m ", .{tu.name});
                            }
                        } else if (std.mem.eql(u8, tu.name, "codeact")) {
                            main.stderrPrint("\x1b[90m[codeact]\x1b[0m \x1b[35mExecuting QuickJS-ng script...\x1b[0m ", .{});
                        } else {
                            main.stderrPrint("\x1b[90m[tool: {s}]\x1b[0m ", .{tu.name});
                        }
                    }

                    // Phát pre-tool-use hook
                    hooks_mod.dispatch(self.alloc, self.io, .{
                        .event = "pre-tool-use",
                        .tool_id = tu.id,
                        .tool_name = tu.name,
                        .input_json = tu.input_json,
                    });

                    // Snapshot file nếu là công cụ chỉnh sửa
                    if (std.mem.eql(u8, tu.name, "file_edit") or std.mem.eql(u8, tu.name, "file_write")) {
                        if (json_mod.findString(tu.input_json, "path")) |path| {
                            if (self.snapshot_tracker) |*t| {
                                t.beforeFileWrite(path);
                            }
                        }
                    }

                    var is_err = false;
                    const result = tools_mod.executeTool(self.alloc, self.io, tu.name, tu.input_json) catch |e| blk: {
                        is_err = true;
                        const msg = try std.fmt.allocPrint(self.alloc, "Lỗi tool: {s}", .{@errorName(e)});
                        break :blk msg;
                    };
                    try allocated_strings.append(self.alloc, result);

                    // Truncate nếu quá lớn
                    const max_tool_result = 64 * 1024;
                    const truncated = if (result.len > max_tool_result) result[0..max_tool_result] else result;

                    // Phát post-tool-use hook
                    hooks_mod.dispatch(self.alloc, self.io, .{
                        .event = "post-tool-use",
                        .tool_id = tu.id,
                        .tool_name = tu.name,
                        .input_json = tu.input_json,
                        .tool_result = truncated,
                        .is_error = is_err,
                    });

                    try results.append(self.alloc, .{
                        .tool_use_id = tu.id,
                        .content = truncated,
                        .is_error = is_err,
                    });

                    const end_tool_ms = utils.milliTimestamp();
                    const dur_ms = if (end_tool_ms >= start_tool_ms) @as(u64, @intCast(end_tool_ms - start_tool_ms)) else 0;

                    if (main.ui_repl.current_renderer) |r| {
                        var patch_path: ?[]const u8 = null;
                        var patch_diff: ?[]const u8 = null;
                        if (std.mem.eql(u8, tu.name, "file_edit") or std.mem.eql(u8, tu.name, "file_write")) {
                            patch_path = json_mod.findString(tu.input_json, "path");
                            patch_diff = json_mod.findString(tu.input_json, "patch") orelse json_mod.findString(tu.input_json, "content");
                        }
                        r.finishTool(tu.name, result, is_err, dur_ms, patch_path, patch_diff);
                    } else {
                        if (is_err) {
                            main.stderrPrint("\x1b[31m[lỗi]\x1b[0m\n", .{});
                        } else {
                            main.stderrPrint("\x1b[32m[ok]\x1b[0m\n", .{});
                        }
                    }
                },
                else => {},
            }
        }

        if (results.items.len > 0) {
            try self.history.addToolResults(results.items);
        }
    }
};

/// Bóc tách khối mã JavaScript từ markdown text (```js ... ``` hoặc ```javascript ... ```).
pub fn extractJsCodeBlock(alloc: Allocator, text: []const u8) ?[]const u8 {
    const markers = [_][]const u8{
        "```javascript\n",
        "```js\n",
        "```javascript\r\n",
        "```js\r\n",
    };
    for (markers) |m| {
        if (std.mem.indexOf(u8, text, m)) |start_idx| {
            const code_start = start_idx + m.len;
            if (std.mem.indexOf(u8, text[code_start..], "```")) |end_idx| {
                const code = text[code_start .. code_start + end_idx];
                const trimmed = std.mem.trim(u8, code, " \r\n\t");
                if (trimmed.len > 0) {
                    return alloc.dupe(u8, trimmed) catch null;
                }
            }
        }
    }
    return null;
}

fn extractXmlAttr(tag_str: []const u8, attr_name: []const u8) ?[]const u8 {
    var search_buf: [64]u8 = undefined;
    const pat = std.fmt.bufPrint(&search_buf, "{s}=\"", .{attr_name}) catch return null;
    if (std.mem.indexOf(u8, tag_str, pat)) |start_idx| {
        const val_start = start_idx + pat.len;
        if (std.mem.indexOfPos(u8, tag_str, val_start, "\"")) |val_end| {
            return tag_str[val_start..val_end];
        }
    }
    const pat_sq = std.fmt.bufPrint(&search_buf, "{s}='", .{attr_name}) catch return null;
    if (std.mem.indexOf(u8, tag_str, pat_sq)) |start_sq| {
        const val_start = start_sq + pat_sq.len;
        if (std.mem.indexOfPos(u8, tag_str, val_start, "'")) |val_end| {
            return tag_str[val_start..val_end];
        }
    }
    return null;
}

/// Chuyển đổi các thẻ XML giả lập (<file_read>, <glob>, <grep>, <bash>, <file_write>) thành mã JS mini.*
pub fn convertXmlToolTagsToJs(alloc: Allocator, text: []const u8) ?[]const u8 {
    var js_buf = utils.BufWriter.init(alloc);
    errdefer js_buf.deinit();

    var has_tags = false;
    var pos: usize = 0;

    while (pos < text.len) {
        const tag_start = std.mem.indexOfPos(u8, text, pos, "<") orelse break;
        pos = tag_start + 1;

        const tag_names = [_][]const u8{ "file_read", "glob", "grep", "bash", "file_write", "file_edit", "http_request", "web_search" };
        var matched_tag: ?[]const u8 = null;
        for (tag_names) |tn| {
            if (std.mem.startsWith(u8, text[tag_start + 1 ..], tn)) {
                matched_tag = tn;
                break;
            }
        }
        if (matched_tag == null) continue;

        const tag_name = matched_tag.?;
        const tag_end = std.mem.indexOfPos(u8, text, tag_start, ">") orelse continue;
        const tag_str = text[tag_start .. tag_end + 1];
        pos = tag_end + 1;

        has_tags = true;

        if (std.mem.eql(u8, tag_name, "file_read")) {
            const file_path = extractXmlAttr(tag_str, "file") orelse extractXmlAttr(tag_str, "path") orelse "";
            if (file_path.len > 0) {
                const escaped = json_mod.escape(alloc, file_path) catch continue;
                defer alloc.free(escaped);
                js_buf.print("console.log('=== file_read: ' + \"{s}\" + ' ===');\nconsole.log(mini.read(\"{s}\"));\n", .{ escaped, escaped }) catch {};
            }
        } else if (std.mem.eql(u8, tag_name, "glob")) {
            const pattern = extractXmlAttr(tag_str, "pattern") orelse "*";
            const path = extractXmlAttr(tag_str, "path") orelse ".";
            const esc_pat = json_mod.escape(alloc, pattern) catch continue;
            defer alloc.free(esc_pat);
            const esc_path = json_mod.escape(alloc, path) catch continue;
            defer alloc.free(esc_path);
            js_buf.print("console.log('=== glob: ' + \"{s}\" + ' ===');\nconsole.log(JSON.stringify(mini.glob(\"{s}\", \"{s}\")));\n", .{ esc_pat, esc_pat, esc_path }) catch {};
        } else if (std.mem.eql(u8, tag_name, "grep")) {
            const pattern = extractXmlAttr(tag_str, "pattern") orelse "";
            const path = extractXmlAttr(tag_str, "path") orelse ".";
            const esc_pat = json_mod.escape(alloc, pattern) catch continue;
            defer alloc.free(esc_pat);
            const esc_path = json_mod.escape(alloc, path) catch continue;
            defer alloc.free(esc_path);
            js_buf.print("console.log('=== grep: ' + \"{s}\" + ' ===');\nconsole.log(JSON.stringify(mini.grep(\"{s}\", \"{s}\")));\n", .{ esc_pat, esc_pat, esc_path }) catch {};
        } else if (std.mem.eql(u8, tag_name, "bash")) {
            const cmd = extractXmlAttr(tag_str, "command") orelse extractXmlAttr(tag_str, "cmd") orelse "";
            if (cmd.len > 0) {
                const esc_cmd = json_mod.escape(alloc, cmd) catch continue;
                defer alloc.free(esc_cmd);
                js_buf.print("console.log('=== bash: ' + \"{s}\" + ' ===');\nconst r = mini.sh(\"{s}\");\nconsole.log(r.stdout);\nif (r.stderr) console.log('stderr: ' + r.stderr);\n", .{ esc_cmd, esc_cmd }) catch {};
            }
        } else if (std.mem.eql(u8, tag_name, "file_write")) {
            const path = extractXmlAttr(tag_str, "path") orelse extractXmlAttr(tag_str, "file") orelse "";
            const content = extractXmlAttr(tag_str, "content") orelse "";
            if (path.len > 0) {
                const esc_path = json_mod.escape(alloc, path) catch continue;
                defer alloc.free(esc_path);
                const esc_content = json_mod.escape(alloc, content) catch continue;
                defer alloc.free(esc_content);
                js_buf.print("mini.write(\"{s}\", \"{s}\");\nconsole.log('file written: {s}');\n", .{ esc_path, esc_content, esc_path }) catch {};
            }
        }
    }

    if (!has_tags or js_buf.list.items.len == 0) {
        js_buf.deinit();
        return null;
    }

    return js_buf.toOwnedSlice() catch null;
}

/// Tìm kiếm khối mã JavaScript trong phản hồi của Assistant
pub fn findJsCodeInResponse(alloc: Allocator, response: *const proto.Response) ?[]const u8 {
    for (response.content.items) |block| {
        switch (block) {
            .text => |t| {
                if (extractJsCodeBlock(alloc, t)) |code| return code;
            },
            else => {},
        }
    }
    for (response.content.items) |block| {
        switch (block) {
            .text => |t| {
                if (convertXmlToolTagsToJs(alloc, t)) |code| return code;
            },
            else => {},
        }
    }
    return null;
}


test "agent - extractJsCodeBlock" {
    const alloc = std.testing.allocator;
    const md =
        \\Dưới đây là đoạn mã thực thi:
        \\```js
        \\const a = 10;
        \\const b = 20;
        \\console.log(a + b);
        \\```
        \\Hãy xem kết quả bên trên.
    ;

    const extracted = extractJsCodeBlock(alloc, md);
    try std.testing.expect(extracted != null);
    defer alloc.free(extracted.?);

    try std.testing.expectEqualStrings("const a = 10;\nconst b = 20;\nconsole.log(a + b);", extracted.?);
}

test "agent - convertXmlToolTagsToJs" {
    const alloc = std.testing.allocator;
    const text =
        \\<file_read file="/home/mypc/project/rfc_003_summary.md" />
        \\<glob path="/home/mypc/project" pattern="**/*rfc_003*" />
    ;

    const js = convertXmlToolTagsToJs(alloc, text);
    try std.testing.expect(js != null);
    defer alloc.free(js.?);

    try std.testing.expect(std.mem.indexOf(u8, js.?, "mini.read") != null);
    try std.testing.expect(std.mem.indexOf(u8, js.?, "mini.glob") != null);
}

