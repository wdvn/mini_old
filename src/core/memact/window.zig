//! window.zig — Quản lý 4-tier Context Window cho MemAct

const std = @import("std");
const proto = @import("../protocol.zig");
const TokenEstimator = @import("tokens.zig").TokenEstimator;

pub const ContextWindow = struct {
    max_tokens: u32,
    safety_margin: f32 = 0.15,
    compact_threshold: f32 = 0.85,

    pub fn init(max_tokens: u32) ContextWindow {
        return .{ .max_tokens = max_tokens };
    }

    /// Tính tổng token của history
    pub fn estimateTotal(self: *const ContextWindow, est: *TokenEstimator, msgs: []const proto.Message) u32 {
        _ = self;
        var total: u32 = 0;
        for (msgs) |m| {
            total += est.estimateMessage(&m);
        }
        return total;
    }

    /// Kiểm tra xem có cần compact không (nếu token vượt ngưỡng)
    pub fn needsCompaction(self: *const ContextWindow, est: *TokenEstimator, msgs: []const proto.Message, pinned_tokens: u32) bool {
        if (self.max_tokens <= pinned_tokens) return true; // Cảnh báo quá tải
        const budget = self.max_tokens - pinned_tokens;
        // Dành một phần budget cho output của response
        const available = @as(f32, @floatFromInt(budget)) * (1.0 - self.safety_margin);
        const current = self.estimateTotal(est, msgs);

        return @as(f32, @floatFromInt(current)) > available * self.compact_threshold;
    }

    /// Tìm điểm cắt lý tưởng (tool-boundary).
    /// Trả về index của message bắt đầu phần giữ lại (nửa sau).
    /// Phần từ 0..index sẽ được summarize (chuyển sang tier summarized/archived).
    pub fn findSplitIndex(self: *const ContextWindow, est: *TokenEstimator, msgs: []const proto.Message, pinned_tokens: u32) usize {
        const budget = if (self.max_tokens > pinned_tokens) self.max_tokens - pinned_tokens else 0;
        const available = @as(f32, @floatFromInt(budget)) * (1.0 - self.safety_margin);
        const target_keep_tokens = available * 0.6; // Giữ lại ~60% sau khi cắt

        var current_keep: u32 = 0;
        var split_idx: usize = msgs.len;

        // Đi lùi từ cuối lên để gom đủ token
        while (split_idx > 0) {
            const idx = split_idx - 1;
            const msg = msgs[idx];
            const tokens = est.estimateMessage(&msg);

            // Guard bất biến: msgs[0] = prompt gốc, msgs[1] = summary tier .summarized
            // sau compact — không bao giờ hạ split xuống dưới 2 khi history dài.
            if (idx < 2 and msgs.len > 3) break;

            // Kiểm tra tool boundary
            var is_boundary = true;
            if (msg.role == .user) {
                var has_tool_result = false;
                for (msg.content) |b| {
                    if (b == .tool_result) has_tool_result = true;
                }
                if (has_tool_result) is_boundary = false;
            } else {
                is_boundary = false; // Không cắt trước assistant
            }

            if (current_keep + tokens > @as(u32, @intFromFloat(target_keep_tokens))) {
                // Đã gom đủ. Nếu đang ở boundary thì dừng.
                if (is_boundary) {
                    split_idx = idx;
                    break;
                }
            }
            
            current_keep += tokens;
            split_idx = idx;
        }
        
        // Nếu không tìm được boundary hợp lý (vd tin nhắn quá dài), cắt đôi theo số lượng
        if (split_idx == 0 or split_idx == msgs.len) {
            split_idx = msgs.len / 2;
            // Ráng dời split_idx tới một tin nhắn user không có tool_result
            while (split_idx > 0) {
                const m = msgs[split_idx];
                if (m.role == .user) {
                    var has_tool_result = false;
                    for (m.content) |b| {
                        if (b == .tool_result) has_tool_result = true;
                    }
                    if (!has_tool_result) break;
                }
                split_idx -= 1;
            }
            // Guard bất biến: không để fallback hạ split xuống dưới 2 khi history dài
            if (split_idx < 2 and msgs.len > 3) split_idx = 2;
        }
        
        // Đảm bảo chừa lại ít nhất 2 tin nhắn nếu history đang dài
        if (split_idx >= msgs.len and msgs.len > 2) {
            split_idx = msgs.len - 2;
        }

        return split_idx;
    }
};

test "needsCompaction respects threshold" {
    const alloc = std.testing.allocator;
    var est = TokenEstimator.init(alloc);
    defer est.deinit();

    var window = ContextWindow{ .max_tokens = 1000 };
    // 1 message ~ vài token, budget ≈ 722 (1000*(1-0.15)*0.85) → chưa cần compact
    const small = [_]proto.Message{
        .{ .role = .user, .content = &.{.{ .text = "hello" }} },
    };
    try std.testing.expect(!window.needsCompaction(&est, &small, 0));

    // Vài chục KB → vượt ngưỡng
    const big_text = "a" ** 5000; // ~1315 tokens > 722
    const big = [_]proto.Message{
        .{ .role = .user, .content = &.{.{ .text = big_text }} },
        .{ .role = .assistant, .content = &.{.{ .text = big_text }} },
    };
    try std.testing.expect(window.needsCompaction(&est, &big, 0));
}

test "findSplitIndex không cắt giữa cặp tool_use/tool_result" {
    const alloc = std.testing.allocator;
    var est = TokenEstimator.init(alloc);
    defer est.deinit();

    var window = ContextWindow{ .max_tokens = 2000 };
    const text = "x" ** 200; // ~52 tokens/msg

    // 20 message: user(text) / assistant(tool_use) xen kẽ
    var msgs: [20]proto.Message = undefined;
    var i: usize = 0;
    while (i < 20) : (i += 2) {
        msgs[i] = .{ .role = .user, .content = &.{.{ .text = text }} };
        msgs[i + 1] = .{
            .role = .assistant,
            .content = &.{.{ .tool_use = .{ .id = "1", .name = "t", .input_json = "{}" } }},
        };
    }

    const split = window.findSplitIndex(&est, &msgs, 0);
    try std.testing.expect(split > 0 and split < 20);

    // Message tại split phải là user KHÔNG chứa tool_result
    const m = msgs[split];
    try std.testing.expect(m.role == .user);
    for (m.content) |b| {
        try std.testing.expect(b != .tool_result);
    }
}

test "estimateTotal cộng dồn theo message" {
    const alloc = std.testing.allocator;
    var est = TokenEstimator.init(alloc);
    defer est.deinit();

    var window = ContextWindow{ .max_tokens = 1000 };
    const msgs = [_]proto.Message{
        .{ .role = .user, .content = &.{.{ .text = "hello world foo bar" }} },
        .{ .role = .assistant, .content = &.{.{ .text = "hello world foo bar" }} },
    };
    // 2 message giống nhau → tổng = 2x single
    const single = [_]proto.Message{
        .{ .role = .user, .content = &.{.{ .text = "hello world foo bar" }} },
    };
    try std.testing.expect(window.estimateTotal(&est, &msgs) == 2 * window.estimateTotal(&est, &single));
}

test "findSplitIndex giữ nguyên prompt gốc và summary (split >= 2)" {
    const alloc = std.testing.allocator;
    var est = TokenEstimator.init(alloc);
    defer est.deinit();

    var window = ContextWindow{ .max_tokens = 2000 };
    const text = "x" ** 200; // ~52 tokens/msg

    // 20 message user(text) / assistant(text) xen kẽ.
    // Sau compact, msgs[0] = prompt gốc, msgs[1] = summary tier .summarized —
    // vòng lùi không được hạ split xuống dưới 2.
    var msgs: [20]proto.Message = undefined;
    var i: usize = 0;
    while (i < 20) : (i += 2) {
        msgs[i] = .{ .role = .user, .content = &.{.{ .text = text }} };
        msgs[i + 1] = .{ .role = .assistant, .content = &.{.{ .text = text }} };
    }

    const split = window.findSplitIndex(&est, &msgs, 0);
    try std.testing.expect(split >= 2 and split < 20);

    // Message tại split phải là user KHÔNG chứa tool_result
    const m = msgs[split];
    try std.testing.expect(m.role == .user);
    for (m.content) |b| {
        try std.testing.expect(b != .tool_result);
    }
}

test "findSplitIndex history ngắn với message rất lớn vẫn >= 2" {
    const alloc = std.testing.allocator;
    var est = TokenEstimator.init(alloc);
    defer est.deinit();

    // Window nhỏ so với từng message: target_keep ~306 token < ~1315 token/msg
    var window = ContextWindow{ .max_tokens = 600 };
    const big_text = "y" ** 5000;

    // [0] = user prompt gốc, [1] = user summary sau compact, [2..3] = assistant.
    // Code cũ có thể tụt split về 1 (cắt mất prompt gốc) — guard phải chặn.
    const msgs = [_]proto.Message{
        .{ .role = .user, .content = &.{.{ .text = big_text }} },
        .{ .role = .user, .content = &.{.{ .text = big_text }} },
        .{ .role = .assistant, .content = &.{.{ .text = big_text }} },
        .{ .role = .assistant, .content = &.{.{ .text = big_text }} },
    };

    const split = window.findSplitIndex(&est, &msgs, 0);
    try std.testing.expect(split >= 2);
    try std.testing.expect(split != 0 and split != 1);
}
