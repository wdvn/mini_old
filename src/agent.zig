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
//! ## Giới hạn
//! Tối đa `MAX_ITERATIONS` iterations mỗi lần gọi processInput.
//! Ngăn vòng lặp vô tận khi AI liên tục gọi tool.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const proto = @import("protocol.zig");
const config_mod = @import("config.zig");
const history_mod = @import("history.zig");
const tools_mod = @import("tools.zig");
const json_mod = @import("json.zig");
const openai_mod = @import("backend/openai.zig");
const claude_mod = @import("backend/claude.zig");
const ollama_mod = @import("backend/ollama.zig");
const hooks_mod = @import("hooks.zig");
const main = @import("main.zig");
const utils = @import("utils.zig");
const quickjs = @import("runtime/quickjs_engine.zig");
const js_bindings = @import("runtime/js_bindings.zig");

/// Số iterations tối đa trong một lần processInput.
const MAX_ITERATIONS = 30;
/// Số lần retry tối đa khi gặp rate limit.
const MAX_RATE_LIMIT_RETRIES = 5;
/// Thời gian chờ ban đầu khi gặp rate limit (giây).
const RATE_LIMIT_BASE_DELAY_S: u64 = 5;

pub const AgentError = error{
    MaxIterationsReached,
};

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

        return .{
            .alloc = alloc,
            .io = io,
            .backend = backend,
            .history = history_mod.History.init(alloc),
            .config = config,
            .engine = engine,
            .js_retry_count = 0,
        };
    }

    /// Giải phóng bộ nhớ.
    pub fn deinit(self: *AgentLoop) void {
        self.history.deinit();
        self.engine.deinit();
    }

    const StepResult = enum {
        continue_loop,
        exit_loop,
    };

    fn executeStep(
        self: *AgentLoop,
        iteration: usize,
        tool_defs: []const proto.ToolDefinition,
        text_cb: ?*const fn ([]const u8) void,
        think_cb: ?*const fn ([]const u8) void,
        rate_limit_retries: *usize,
    ) !StepResult {
        if (iteration > 0) {
            main.stderrPrint("\x1b[90m[agent] --- Vòng lặp {d} ---\x1b[0m\n", .{iteration + 1});
        } else {
            main.stderrPrint("\n\x1b[90m[agent] --- Bắt đầu quy trình ---\x1b[0m\n", .{});
        }

        main.stderrPrint("\x1b[36m[agent]\x1b[0m \x1b[93mĐang suy nghĩ / Phân tích yêu cầu... \x1b[0m\n", .{});

        if (self.history.needsCompaction()) {
            main.stderrPrint("\n\x1b[33m[agent] Lịch sử quá dài, đang nén ngữ cảnh...\x1b[0m\n", .{});
            
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
            
            var summary_resp = try self.sendToBackend(self.config.system_prompt, temp_msgs.items, &[_]proto.ToolDefinition{}, null, null);
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

        // Gửi lên AI backend (streaming)
        var response = try self.sendToBackend(
            self.config.system_prompt,
            self.history.messages(),
            tool_defs,
            text_cb,
            think_cb,
        );
        main.resetThinkState();
        
        defer response.deinit();

        // Xuống dòng sau khi stream xong
        try std.Io.File.stdout().writeStreamingAll(self.io, "\n");

        // Thêm response vào history (nếu có nội dung)
        const added_to_history = try self.history.addAssistantResponse(&response);

        // 1. CodeAct: Kiểm tra có khối mã JavaScript trong response không
        if (self.config.execution_mode != .tools) {
            if (findJsCodeInResponse(self.alloc, &response)) |js_code| {
                defer self.alloc.free(js_code);

                main.stderrPrint("\x1b[90m[codeact]\x1b[0m \x1b[35mExecuting QuickJS-ng script...\x1b[0m ", .{});

                var res = self.engine.eval(js_code, "agent_codeact.js") catch |e| {
                    main.stderrPrint("\x1b[31m[engine error: {s}]\x1b[0m\n", .{@errorName(e)});
                    const err_msg = try std.fmt.allocPrint(self.alloc, "[CodeAct System Error]: {s}", .{@errorName(e)});
                    defer self.alloc.free(err_msg);
                    try self.history.addUser(err_msg);
                    return .continue_loop;
                };
                defer res.deinit();

                if (!res.is_error) {
                    main.stderrPrint("\x1b[32m[ok]\x1b[0m\n", .{});
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
                    main.stderrPrint("\x1b[31m[error]\x1b[0m\n", .{});
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
                main.stderrPrint("\n\x1b[92m[agent] ✓ Hoàn thành sau {d} vòng lặp.\x1b[0m\n", .{iteration + 1});
                return .exit_loop;
            },
            .max_tokens => {
                main.stderrPrint("\n\x1b[33m[agent] ⚠️ Cảnh báo: Đạt giới hạn max_tokens. Dừng sớm.\x1b[0m\n", .{});
                return .exit_loop;
            },
            .tool_use => {
                try self.executeTools(&response);
                main.stderrPrint("\n", .{});
                return .continue_loop;
            },
            .unknown => {
                // Detect rate limit: HTTP 429 or "rate_limit" in raw body
                const is_rate_limit = blk: {
                    if (response.http_code == 429) break :blk true;
                    if (response.raw_debug_info) |raw| {
                        if (std.mem.indexOf(u8, raw, "rate_limit") != null) break :blk true;
                    }
                    break :blk false;
                };

                if (is_rate_limit and rate_limit_retries.* < MAX_RATE_LIMIT_RETRIES) {
                    rate_limit_retries.* += 1;
                    const delay = RATE_LIMIT_BASE_DELAY_S * (@as(u64, 1) << @intCast(rate_limit_retries.* - 1));
                    main.stderrPrint("\n\x1b[33m[agent] ⚠ Rate limit! Thử lại {d}/{d} sau {d}s...\x1b[0m\n", .{ rate_limit_retries.*, MAX_RATE_LIMIT_RETRIES, delay });
                    std.Io.sleep(self.io, std.Io.Duration.fromSeconds(@intCast(delay)), .awake) catch {};
                    if (added_to_history) self.history.popLast();
                    return .continue_loop;
                }

                main.stderrPrint("[agent] Cảnh báo: stop_reason không xác định (HTTP {d})\n", .{response.http_code});
                if (response.raw_debug_info) |raw| {
                    main.stderrPrint("\n--- RAW BACKEND RESPONSE ---\n{s}\n----------------------------\n", .{raw});
                } else {
                    main.stderrPrint("\n--- RAW BACKEND RESPONSE ---\n(Không có nội dung trả về từ server)\n----------------------------\n", .{});
                }
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
        // Phát pre-prompt hook
        hooks_mod.dispatch(self.alloc, self.io, .{
            .event = "pre-prompt",
            .user_prompt = user_text,
        });
        defer {
            hooks_mod.dispatch(self.alloc, self.io, .{
                .event = "post-response",
                .user_prompt = user_text,
            });
        }

        // Thêm user message vào history
        try self.history.addUser(user_text);

        // Lấy danh sách tools phù hợp với user message
        const tool_defs = tools_mod.getRelevantDefinitions(self.alloc, user_text);

        // Chuẩn bị đường dẫn backup file dựa trên PID
        var path_buf: [256]u8 = undefined;
        const backup_path = std.fmt.bufPrint(&path_buf, "/tmp/mini_agent_backup_{d}.json", .{std.os.linux.getpid()}) catch "/tmp/mini_agent_backup.json";

        var iteration: usize = 0;
        var rate_limit_retries: usize = 0;
        while (iteration < MAX_ITERATIONS) : (iteration += 1) {
            var try_count: usize = 0;
            const max_retries = 3;
            while (try_count <= max_retries) : (try_count += 1) {
                // 1. Backup state hiện tại trước khi thực hiện step
                self.history.backupToFile(self.io, backup_path) catch |e| {
                    main.stderrPrint("[agent] Cảnh báo: Không thể tạo backup file: {s}\n", .{@errorName(e)});
                };

                // 2. Chạy step
                const result = self.executeStep(iteration, tool_defs, text_cb, think_cb, &rate_limit_retries) catch |e| {
                    if (try_count == max_retries) {
                        main.stderrPrint("\n[agent] Lỗi bước {d} liên tiếp {d} lần. Dừng quy trình. Lỗi: {s}\n", .{ iteration + 1, max_retries + 1, @errorName(e) });
                        std.Io.Dir.cwd().deleteFile(self.io, backup_path) catch {};
                        return e;
                    }
                    main.stderrPrint("\n[agent] Bước {d} gặp lỗi ({s}). Khôi phục từ backup và thử lại (lần {d}/{d})...\n", .{ iteration + 1, @errorName(e), try_count + 1, max_retries });
                    
                    // 3. Khôi phục từ backup file
                    self.history.restoreFromFile(self.io, backup_path) catch |restore_err| {
                        main.stderrPrint("[agent] Lỗi nghiêm trọng: Không thể khôi phục từ backup: {s}\n", .{@errorName(restore_err)});
                        return restore_err;
                    };
                    continue;
                };

                // Nếu chạy thành công
                if (result == .exit_loop) {
                    std.Io.Dir.cwd().deleteFile(self.io, backup_path) catch {};
                    return;
                }
                break;
            }
        }

        main.stderrPrint("[agent] Đạt giới hạn {d} iterations\n", .{MAX_ITERATIONS});
        std.Io.Dir.cwd().deleteFile(self.io, backup_path) catch {};
        return error.MaxIterationsReached;
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
        system_prompt: []const u8,
        msgs: []const proto.Message,
        tool_defs: []const proto.ToolDefinition,
        text_cb: ?*const fn ([]const u8) void,
        think_cb: ?*const fn ([]const u8) void,
    ) !proto.Response {
        // Primary backend
        const primary = self.backend.send(system_prompt, msgs, tool_defs, text_cb, think_cb);
        if (primary) |resp| return resp else |e| {
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
                    return resp;
                } else |_| {}
            }
            return e;
        }
    }

    /// Thực thi tất cả tool_use blocks trong response.
    fn executeTools(self: *AgentLoop, response: *const proto.Response) !void {
        var results = ArrayList(proto.ToolResult).empty;
        defer results.deinit(self.alloc);
        
        var allocated_strings = ArrayList([]u8).empty;
        defer {
            for (allocated_strings.items) |s| self.alloc.free(s);
            allocated_strings.deinit(self.alloc);
        }

        for (response.content.items) |block| {
            switch (block) {
                .tool_use => |tu| {
                    // Hiển thị tên tool và tham số chính (verbose)
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
                    } else {
                        main.stderrPrint("\x1b[90m[tool: {s}]\x1b[0m ", .{tu.name});
                    }

                    // Phát pre-tool-use hook
                    hooks_mod.dispatch(self.alloc, self.io, .{
                        .event = "pre-tool-use",
                        .tool_id = tu.id,
                        .tool_name = tu.name,
                        .input_json = tu.input_json,
                    });

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

                    if (is_err) {
                        main.stderrPrint("\x1b[31m[lỗi]\x1b[0m\n", .{});
                    } else {
                        main.stderrPrint("\x1b[32m[ok]\x1b[0m\n", .{});
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
