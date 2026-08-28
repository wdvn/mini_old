//! history.zig — Lịch sử hội thoại in-memory.
//!
//! Quản lý danh sách các `Message` trong một phiên hội thoại.
//! Tự động compact khi số lượng tin nhắn vượt ngưỡng để tránh
//! overflow context window của AI model.
//!
//! ## Cách dùng
//! ```zig
//! var h = History.init(alloc);
//! defer h.deinit();
//! try h.addUser("Xin chào!");
//! try h.addAssistant("Chào bạn!");
//! const msgs = h.messages();  // gửi lên API
//! ```
//!
//! ## Compact
//! Khi `messages.len > max_messages`, gọi `compact()` để giữ lại
//! chỉ một nửa số tin nhắn gần nhất (tính theo cặp user/assistant).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const proto = @import("protocol.zig");
const main = @import("../main.zig");
const utils = @import("utils.zig");



/// Số tin nhắn tối đa trước khi tự động compact.
const DEFAULT_MAX_MESSAGES = 40;

/// Lịch sử hội thoại cho một phiên làm việc.
pub const History = struct {
    alloc: Allocator,
    msgs: ArrayList(proto.Message),
    /// Ngưỡng tự động compact.
    max_messages: usize,
    /// ID của Act tại lần compact gần nhất (để block rollback vượt quá mốc này).
    last_compaction_act_id: usize,

    /// Khởi tạo History rỗng.
    pub fn init(alloc: Allocator) History {
        return .{
            .alloc = alloc,
            .msgs = .empty,
            .max_messages = DEFAULT_MAX_MESSAGES,
            .last_compaction_act_id = 0,
        };
    }

    fn freeContentBlocks(alloc: Allocator, blocks: []const proto.ContentBlock) void {
        for (blocks) |block| {
            switch (block) {
                .text => |t| alloc.free(t),
                .thinking => |th| {
                    if (th.thinking.len > 0) alloc.free(th.thinking);
                    if (th.signature.len > 0) alloc.free(th.signature);
                },
                .tool_use => |tu| {
                    alloc.free(tu.id);
                    alloc.free(tu.name);
                    alloc.free(tu.input_json);
                },
                .tool_result => |tr| {
                    alloc.free(tr.tool_use_id);
                    alloc.free(tr.content);
                },
            }
        }
        alloc.free(blocks);
    }

    /// Giải phóng tất cả bộ nhớ.
    pub fn deinit(self: *History) void {
        for (self.msgs.items) |msg| {
            freeContentBlocks(self.alloc, msg.content);
        }
        self.msgs.deinit(self.alloc);
    }

    /// Backup lịch sử ra file JSON.
    pub fn backupToFile(self: *const History, io: std.Io, path: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        const file = try cwd.createFile(io, path, .{ .truncate = true });
        defer file.close(io);

        var out_buf = std.ArrayList(u8).empty;
        defer out_buf.deinit(self.alloc);
        var aw = std.Io.Writer.Allocating.fromArrayList(self.alloc, &out_buf);
        try std.json.Stringify.value(self.msgs.items, .{}, &aw.writer);
        out_buf = aw.toArrayList();

        try file.writeStreamingAll(io, out_buf.items);
    }

    /// Khôi phục lịch sử từ file JSON.
    pub fn restoreFromFile(self: *History, io: std.Io, path: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        const file = try cwd.openFile(io, path, .{});
        defer file.close(io);

        const stat = try file.stat(io);
        const buf = try self.alloc.alloc(u8, @intCast(stat.size));
        defer self.alloc.free(buf);

        const n = try utils.readAll(io, file, buf);
        const json_data = buf[0..n];

        const parsed = try std.json.parseFromSlice([]proto.Message, self.alloc, json_data, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        self.clear();

        for (parsed.value) |msg| {
            const content_copy = try self.alloc.alloc(proto.ContentBlock, msg.content.len);
            for (msg.content, 0..) |block, i| {
                content_copy[i] = switch (block) {
                    .text => |t| .{ .text = try self.alloc.dupe(u8, t) },
                    .thinking => |th| .{ .thinking = .{
                        .thinking = try self.alloc.dupe(u8, th.thinking),
                        .signature = try self.alloc.dupe(u8, th.signature),
                    } },
                    .tool_use => |tu| .{ .tool_use = .{
                        .id = try self.alloc.dupe(u8, tu.id),
                        .name = try self.alloc.dupe(u8, tu.name),
                        .input_json = try self.alloc.dupe(u8, tu.input_json),
                    } },
                    .tool_result => |tr| .{ .tool_result = .{
                        .tool_use_id = try self.alloc.dupe(u8, tr.tool_use_id),
                        .content = try self.alloc.dupe(u8, tr.content),
                        .is_error = tr.is_error,
                    } },
                };
            }
            try self.msgs.append(self.alloc, .{
                .role = msg.role,
                .content = content_copy,
                .tier = msg.tier,
            });
        }
    }


    /// Thêm tin nhắn của user.
    /// `text` được copy vào bộ nhớ sở hữu bởi History.
    pub fn addUser(self: *History, text: []const u8) !void {
        const text_copy = try self.alloc.dupe(u8, text);
        const blocks = try self.alloc.alloc(proto.ContentBlock, 1);
        blocks[0] = .{ .text = text_copy };
        try self.msgs.append(self.alloc, .{ .role = .user, .content = blocks, .tier = .recent });
    }

    /// Thêm tin nhắn của assistant (text response).
    pub fn addAssistantText(self: *History, text: []const u8) !void {
        const text_copy = try self.alloc.dupe(u8, text);
        const blocks = try self.alloc.alloc(proto.ContentBlock, 1);
        blocks[0] = .{ .text = text_copy };
        try self.msgs.append(self.alloc, .{ .role = .assistant, .content = blocks, .tier = .recent });
    }

    /// Thêm phản hồi đầy đủ từ AI (có thể chứa text + tool_use).
    /// Content blocks được copy sâu vào History. Trả về true nếu tin nhắn được thêm.
    pub fn addAssistantResponse(self: *History, response: *const proto.Response) !bool {
        if (response.content.items.len == 0) return false;
        const blocks = try self.alloc.alloc(proto.ContentBlock, response.content.items.len);
        for (response.content.items, 0..) |block, i| {
            blocks[i] = switch (block) {
                .text => |t| .{ .text = try self.alloc.dupe(u8, t) },
                .thinking => |th| .{ .thinking = .{
                    .thinking = try self.alloc.dupe(u8, th.thinking),
                    .signature = try self.alloc.dupe(u8, th.signature),
                } },
                .tool_use => |tu| .{ .tool_use = .{
                    .id = try self.alloc.dupe(u8, tu.id),
                    .name = try self.alloc.dupe(u8, tu.name),
                    .input_json = try self.alloc.dupe(u8, tu.input_json),
                }},
                .tool_result => |tr| .{ .tool_result = .{
                    .tool_use_id = try self.alloc.dupe(u8, tr.tool_use_id),
                    .content = try self.alloc.dupe(u8, tr.content),
                    .is_error = tr.is_error,
                }},
            };
        }
        try self.msgs.append(self.alloc, .{ .role = .assistant, .content = blocks, .tier = .recent });
        return true;
    }

    /// Thêm kết quả tool execution vào lịch sử (dạng user message với tool_result blocks).
    pub fn addToolResults(self: *History, results: []const proto.ToolResult) !void {
        if (results.len == 0) return;
        const blocks = try self.alloc.alloc(proto.ContentBlock, results.len);
        for (results, 0..) |r, i| {
            blocks[i] = .{ .tool_result = .{
                .tool_use_id = try self.alloc.dupe(u8, r.tool_use_id),
                .content = try self.alloc.dupe(u8, r.content),
                .is_error = r.is_error,
            }};
        }
        try self.msgs.append(self.alloc, .{ .role = .user, .content = blocks, .tier = .recent });
    }

    /// Trả về slice tin nhắn hiện tại (không owned).
    pub fn messages(self: *const History) []const proto.Message {
        return self.msgs.items;
    }

    /// Số tin nhắn hiện tại.
    pub fn len(self: *const History) usize {
        return self.msgs.items.len;
    }

    /// Xóa toàn bộ lịch sử.
    pub fn clear(self: *History) void {
        for (self.msgs.items) |msg| freeContentBlocks(self.alloc, msg.content);
        self.msgs.clearRetainingCapacity();
    }

    /// Xóa tin nhắn cuối cùng khỏi lịch sử.
    pub fn popLast(self: *History) void {
        if (self.msgs.items.len == 0) return;
        const last = self.msgs.items[self.msgs.items.len - 1];
        freeContentBlocks(self.alloc, last.content);
        self.msgs.items.len -= 1;
    }

    /// Xóa các tin nhắn từ index được chỉ định trở đi (Rollback)
    pub fn truncate(self: *History, target_len: usize) void {
        if (target_len >= self.msgs.items.len) return;
        for (self.msgs.items[target_len..]) |msg| {
            freeContentBlocks(self.alloc, msg.content);
        }
        self.msgs.items.len = target_len;
    }

    /// Thêm thông báo lỗi hệ thống từ Agent
    pub fn addSystemErrorObservation(self: *History, err_msg: []const u8) !void {
        const text_copy = try self.alloc.dupe(u8, err_msg);
        const blocks = try self.alloc.alloc(proto.ContentBlock, 1);
        blocks[0] = .{ .text = text_copy };
        // Phải là .user để LLM có thể đọc như một observation
        try self.msgs.append(self.alloc, .{ .role = .user, .content = blocks, .tier = .recent });
    }

    /// Compact: giữ lại chỉ một nửa các tin nhắn gần nhất.
    /// Luôn giữ theo cặp chẵn (user + assistant) để không phá vỡ cấu trúc.
    pub fn compact(self: *History) void {
        const n = self.msgs.items.len;
        if (n <= 2) return;

        // Giữ lại nửa sau, tính theo bội số 2
        const keep = (n / 2) & ~@as(usize, 1); // làm tròn xuống số chẵn
        const drop = n - keep;

        // Free các message bị bỏ
        for (self.msgs.items[0..drop]) |msg| freeContentBlocks(self.alloc, msg.content);

        // Shift left
        std.mem.copyForwards(proto.Message, self.msgs.items[0..keep], self.msgs.items[drop..]);
        self.msgs.items.len = keep;

        if (!utils.isSubagent()) main.stderrPrint("[history] Compacted: giữ {d}/{d} messages\n", .{ keep, n });
    }

    /// Kiểm tra xem lịch sử có vượt quá ngưỡng hay không
    pub fn needsCompaction(self: *const History) bool {
        return self.msgs.items.len > self.max_messages;
    }

    /// Reset lịch sử: giữ lại tin nhắn đầu tiên và chèn summary
    pub fn compactWithSummary(self: *History, summary: []const u8) !void {
        if (self.msgs.items.len <= 1) return;

        // Free các tin nhắn từ index 1 trở đi
        for (self.msgs.items[1..]) |msg| {
            freeContentBlocks(self.alloc, msg.content);
        }

        self.msgs.items.len = 1;

        const summary_copy = try self.alloc.dupe(u8, summary);
        const blocks = try self.alloc.alloc(proto.ContentBlock, 1);
        blocks[0] = .{ .text = summary_copy };
        try self.msgs.append(self.alloc, .{ .role = .assistant, .content = blocks, .tier = .summarized });

        if (!utils.isSubagent()) main.stderrPrint("\n[history] Đã dọn dẹp bộ nhớ và lưu tóm tắt ngữ cảnh.\n", .{});
    }

    /// Compact theo logic MemAct (bản mới): GIỮ NGUYÊN msgs.items[0] (user prompt gốc),
    /// đặt summary message tại index 1, DROP toàn bộ phần còn lại.
    ///
    /// Không còn giữ N messages gần nhất: với window lớn, phần giữ lại (~60% window)
    /// vẫn vượt ngưỡng compact → mỗi vòng lặp lại nén (tốn LLM call, history không
    /// bao giờ xuống dưới ngưỡng). Trạng thái "đang ở bước nào" được đưa vào
    /// summary (task_state/next_step) nên model vẫn tiếp tục đúng chỗ.
    ///
    /// Nếu msgs.items[1] đã là summary từ lần compact trước (tier .summarized)
    /// thì summary cũ bị thay thế bởi summary mới (dồn tích lũy).
    pub fn compactMemAct(self: *History, act_id: usize, summary: []const u8) !void {
        // No-op: không có gì để nén (chưa qua prompt gốc)
        if (self.msgs.items.len <= 1) return;

        // Cập nhật mốc compact
        self.last_compaction_act_id = act_id;

        // Nếu msgs[1] là summary từ lần compact trước → thay thế; ngược lại → chèn mới.
        const replace_old_summary = self.msgs.items[1].tier == .summarized;

        // Free toàn bộ messages từ index 1 trở đi (không đụng tới msgs[0] — prompt gốc)
        const dropped = self.msgs.items.len - 1;
        for (self.msgs.items[1..]) |msg| freeContentBlocks(self.alloc, msg.content);
        self.msgs.items.len = 1;

        // Tạo summary message. Role phải là .user để Claude API không từ chối
        // với lỗi 400 "first message must be user" (session cũ compact kiểu cũ).
        const summary_text = try std.fmt.allocPrint(self.alloc, "[MemAct Context Summary]\n{s}", .{summary});
        errdefer self.alloc.free(summary_text);
        const blocks = try self.alloc.alloc(proto.ContentBlock, 1);
        errdefer self.alloc.free(blocks);
        blocks[0] = .{ .text = summary_text };
        const summary_msg = proto.Message{ .role = .user, .content = blocks, .tier = .summarized };
        try self.msgs.append(self.alloc, summary_msg);

        if (!utils.isSubagent()) main.stderrPrint("\n[history] Đã nén ngữ cảnh (MemAct): giữ prompt gốc (index 0), {s} summary tại index 1, drop {d} messages.\n", .{ if (replace_old_summary) "thay thế" else "chèn mới", dropped });
    }

    /// Đảm bảo history tương thích Claude API (message đầu tiên phải có role .user).
    /// Session cũ compact kiểu cũ có thể có msgs[0].role == .assistant → đổi thành .user.
    /// KHÔNG đụng vào content. Trả về true nếu đã sửa, false nếu không cần.
    pub fn ensureClaudeCompatible(self: *History) bool {
        if (self.msgs.items.len > 0 and self.msgs.items[0].role == .assistant) {
            self.msgs.items[0].role = .user;
            return true;
        }
        return false;
    }

    /// Đảm bảo history tương thích OpenAI API:
    /// 1. Loại bỏ/chuyển đổi các block tool_result mồ côi (không có assistant message mang tool_use tương ứng đi trước).
    ///    Tránh lỗi OpenAI 400: "No tool call found for function call output with call_id ...".
    /// 2. Loại bỏ/chuyển đổi các block tool_use mồ côi (không có user message mang tool_result tương ứng đi sau).
    ///    Tránh lỗi OpenAI 400: "No tool output found for function call ...".
    pub fn ensureOpenAICompatible(self: *History) bool {
        var modified = false;
        var valid_tool_ids = std.StringHashMap(void).init(self.alloc);
        defer valid_tool_ids.deinit();
        var valid_result_ids = std.StringHashMap(void).init(self.alloc);
        defer valid_result_ids.deinit();

        for (self.msgs.items) |msg| {
            if (msg.role == .assistant) {
                for (msg.content) |block| {
                    if (block == .tool_use) {
                        valid_tool_ids.put(block.tool_use.id, {}) catch {};
                    }
                }
            } else {
                for (msg.content) |block| {
                    if (block == .tool_result) {
                        valid_result_ids.put(block.tool_result.tool_use_id, {}) catch {};
                    }
                }
            }
        }

        // Pass 1: Xử lý assistant messages chứa tool_use không có tool_result đi sau
        for (self.msgs.items) |*msg| {
            if (msg.role == .assistant) {
                var has_orphan_call = false;
                for (msg.content) |block| {
                    if (block == .tool_use and !valid_result_ids.contains(block.tool_use.id)) {
                        has_orphan_call = true;
                        break;
                    }
                }

                if (has_orphan_call) {
                    var new_blocks = self.alloc.alloc(proto.ContentBlock, msg.content.len) catch continue;
                    for (msg.content, 0..) |block, bi| {
                        if (block == .tool_use and !valid_result_ids.contains(block.tool_use.id)) {
                            const formatted = std.fmt.allocPrint(self.alloc, "[Tool Call: {s}({s})]", .{ block.tool_use.name, block.tool_use.input_json }) catch {
                                new_blocks[bi] = block;
                                continue;
                            };
                            self.alloc.free(block.tool_use.id);
                            self.alloc.free(block.tool_use.name);
                            self.alloc.free(block.tool_use.input_json);
                            new_blocks[bi] = .{ .text = formatted };
                        } else {
                            new_blocks[bi] = block;
                        }
                    }
                    self.alloc.free(msg.content);
                    msg.content = new_blocks;
                    modified = true;
                }
            }
        }

        // Pass 2: Xử lý user messages chứa tool_result không có tool_use đi trước
        for (self.msgs.items) |*msg| {
            if (msg.role != .assistant) {
                var has_orphan_res = false;
                for (msg.content) |block| {
                    if (block == .tool_result and !valid_tool_ids.contains(block.tool_result.tool_use_id)) {
                        has_orphan_res = true;
                        break;
                    }
                }

                if (has_orphan_res) {
                    var new_blocks = self.alloc.alloc(proto.ContentBlock, msg.content.len) catch continue;
                    for (msg.content, 0..) |block, bi| {
                        if (block == .tool_result and !valid_tool_ids.contains(block.tool_result.tool_use_id)) {
                            const formatted = std.fmt.allocPrint(self.alloc, "[Observation]: {s}", .{block.tool_result.content}) catch {
                                new_blocks[bi] = block;
                                continue;
                            };
                            self.alloc.free(block.tool_result.content);
                            self.alloc.free(block.tool_result.tool_use_id);
                            new_blocks[bi] = .{ .text = formatted };
                        } else {
                            new_blocks[bi] = block;
                        }
                    }
                    self.alloc.free(msg.content);
                    msg.content = new_blocks;
                    msg.role = .user;
                    modified = true;
                }
            }
        }
        return modified;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "compactMemAct giữ msgs[0], summary .user/.summarized ở index 1, drop toàn bộ phần sau" {
    // compactMemAct log qua main.stderrPrint dùng g_io — trong test mode g_io
    // chưa được init (chỉ set trong main()) → gán std.testing.io cho an toàn.
    main.g_io = std.testing.io;
    const alloc = std.testing.allocator;
    var h = History.init(alloc);
    defer h.deinit();

    try h.addUser("prompt gốc");
    try h.addAssistantText("trả lời 1");
    try h.addUser("câu hỏi 2");
    try h.addAssistantText("trả lời 2");
    try h.addUser("câu hỏi 3");
    try h.addAssistantText("trả lời 3");

    try h.compactMemAct(7, "tóm tắt ngữ cảnh");

    // Chỉ còn prompt gốc + summary
    try std.testing.expectEqual(@as(usize, 2), h.msgs.items.len);

    // msgs[0] nguyên vẹn: role .user, text prompt gốc
    try std.testing.expect(h.msgs.items[0].role == .user);
    try std.testing.expectEqualStrings("prompt gốc", h.msgs.items[0].content[0].text);

    // Summary tại index 1: role .user (Claude-compatible), tier .summarized, có prefix
    try std.testing.expect(h.msgs.items[1].role == .user);
    try std.testing.expect(h.msgs.items[1].tier == .summarized);
    try std.testing.expectEqualStrings("[MemAct Context Summary]\ntóm tắt ngữ cảnh", h.msgs.items[1].content[0].text);

    try std.testing.expect(h.last_compaction_act_id == 7);
}

test "compactMemAct lần 2 dồn tích lũy: thay summary cũ, msgs[0] vẫn nguyên, không leak" {
    main.g_io = std.testing.io; // xem comment test phía trên
    const alloc = std.testing.allocator;
    var h = History.init(alloc);
    defer h.deinit(); // std.testing.allocator bắt leak nếu compact xử lý bộ nhớ sai

    try h.addUser("prompt gốc");
    try h.addAssistantText("trả lời 1");
    try h.addUser("câu hỏi 2");
    try h.addAssistantText("trả lời 2");

    // Compact lần 1: còn [prompt gốc, summary v1]
    try h.compactMemAct(3, "summary v1");
    try std.testing.expectEqual(@as(usize, 2), h.msgs.items.len);

    // Thêm hội thoại mới rồi compact lần 2: summary cũ bị thay thế
    try h.addUser("câu hỏi 3");
    try h.addAssistantText("trả lời 3");
    try h.compactMemAct(9, "summary v2 merged");

    try std.testing.expectEqual(@as(usize, 2), h.msgs.items.len);

    // msgs[0] vẫn nguyên vẹn qua cả 2 lần compact
    try std.testing.expect(h.msgs.items[0].role == .user);
    try std.testing.expectEqualStrings("prompt gốc", h.msgs.items[0].content[0].text);

    // msgs[1] là summary MỚI (thay thế summary cũ đã được free đúng)
    try std.testing.expect(h.msgs.items[1].role == .user);
    try std.testing.expect(h.msgs.items[1].tier == .summarized);
    try std.testing.expectEqualStrings("[MemAct Context Summary]\nsummary v2 merged", h.msgs.items[1].content[0].text);

    try std.testing.expect(h.last_compaction_act_id == 9);
}

test "compactMemAct no-op khi history quá ngắn (chỉ prompt gốc hoặc rỗng)" {
    const alloc = std.testing.allocator;
    var h = History.init(alloc);
    defer h.deinit();

    try h.addUser("a");
    try h.compactMemAct(5, "sum");
    try std.testing.expectEqual(@as(usize, 1), h.msgs.items.len);
    try std.testing.expectEqualStrings("a", h.msgs.items[0].content[0].text);
    try std.testing.expect(h.last_compaction_act_id == 0); // không cập nhật mốc

    // History rỗng → no-op
    var h2 = History.init(alloc);
    defer h2.deinit();
    try h2.compactMemAct(2, "sum");
    try std.testing.expectEqual(@as(usize, 0), h2.msgs.items.len);
    try std.testing.expect(h2.last_compaction_act_id == 0);
}

test "ensureClaudeCompatible đổi role assistant đầu tiên và trả đúng bool" {
    const alloc = std.testing.allocator;
    var h = History.init(alloc);
    defer h.deinit();

    // Trường hợp không cần sửa: history rỗng
    try std.testing.expect(h.ensureClaudeCompatible() == false);

    // Session cũ compact kiểu cũ: msgs[0].role == .assistant
    try h.addAssistantText("summary cũ assistant-first");
    try h.addUser("câu hỏi mới");

    try std.testing.expect(h.ensureClaudeCompatible() == true);
    try std.testing.expect(h.msgs.items[0].role == .user);
    // Content không bị đụng tới
    try std.testing.expectEqualStrings("summary cũ assistant-first", h.msgs.items[0].content[0].text);
    try std.testing.expect(h.msgs.items[1].role == .user);

    // Lần gọi thứ hai: msgs[0] đã là .user → không sửa, trả false
    try std.testing.expect(h.ensureClaudeCompatible() == false);
    try std.testing.expect(h.msgs.items[0].role == .user);
}

test "ensureOpenAICompatible chuyển đổi orphan tool_result thành text an toàn" {
    const alloc = std.testing.allocator;
    var h = History.init(alloc);
    defer h.deinit();

    // Thêm 1 tool_result mồ côi (không có assistant tool_use trước đó)
    const blocks = try alloc.alloc(proto.ContentBlock, 1);
    blocks[0] = .{ .tool_result = .{
        .tool_use_id = try alloc.dupe(u8, "call_orphan_123"),
        .content = try alloc.dupe(u8, "output of orphan tool"),
        .is_error = false,
    } };
    try h.msgs.append(alloc, .{ .role = .user, .content = blocks });

    try std.testing.expect(h.ensureOpenAICompatible() == true);
    try std.testing.expect(h.msgs.items[0].content[0] == .text);
    try std.testing.expect(std.mem.indexOf(u8, h.msgs.items[0].content[0].text, "output of orphan tool") != null);

    // Lần 2: Đã là text, không sửa nữa
    try std.testing.expect(h.ensureOpenAICompatible() == false);
}

test "ensureOpenAICompatible chuyển đổi orphan tool_use thành text an toàn" {
    const alloc = std.testing.allocator;
    var h = History.init(alloc);
    defer h.deinit();

    // Thêm 1 tool_use mồ côi (không có user tool_result theo sau)
    const blocks = try alloc.alloc(proto.ContentBlock, 1);
    blocks[0] = .{ .tool_use = .{
        .id = try alloc.dupe(u8, "call_orphan_456"),
        .name = try alloc.dupe(u8, "bash"),
        .input_json = try alloc.dupe(u8, "{\"cmd\":\"ls\"}"),
    } };
    try h.msgs.append(alloc, .{ .role = .assistant, .content = blocks });

    try std.testing.expect(h.ensureOpenAICompatible() == true);
    try std.testing.expect(h.msgs.items[0].content[0] == .text);
    try std.testing.expect(std.mem.indexOf(u8, h.msgs.items[0].content[0].text, "[Tool Call: bash({\"cmd\":\"ls\"})]") != null);

    // Lần 2: Đã là text, không sửa nữa
    try std.testing.expect(h.ensureOpenAICompatible() == false);
}
