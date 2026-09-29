//! Incremental provider thinking-tag normalization, independent of terminal rendering.
const std = @import("std");
const provider = @import("provider.zig");

pub const Filter = struct {
    tags: provider.ThinkingTagSet = .none,
    pending: [32]u8 = undefined,
    len: usize = 0,
    thinking: bool = false,
    fenced: bool = false,
    ticks: usize = 0,

    const opens = [_][]const u8{ "<think>", "<思考>", "<推理>", "<反思>", "<推敲>" };
    const closes = [_][]const u8{ "</think>", "</思考>", "</推理>", "</反思>", "</推敲>" };

    pub fn feed(self: *Filter, bytes: []const u8, ctx: anytype) !void {
        if (self.tags == .none) return ctx.emitNormalized(bytes, false);
        if (bytes.len == 0) return;

        var i: usize = 0;
        var start: usize = 0;

        while (i < bytes.len) {
            if (self.len > 0) {
                // Buffering potential tag bytes into pending
                self.pending[self.len] = bytes[i];
                self.len += 1;
                i += 1;

                const candidates = if (self.thinking) &closes else &opens;
                const count: usize = if (self.tags == .english_only) 1 else opens.len;
                var prefix = false;
                var matched = false;

                for (candidates[0..count]) |tag| {
                    if (std.mem.eql(u8, self.pending[0..self.len], tag)) {
                        self.thinking = !self.thinking;
                        self.len = 0;
                        matched = true;
                        start = i;
                        break;
                    }
                    if (std.mem.startsWith(u8, tag, self.pending[0..self.len])) {
                        prefix = true;
                    }
                }

                if (!matched and !prefix) {
                    const keep: usize = if (bytes[i - 1] == '<') 1 else 0;
                    if (self.len > keep) {
                        try ctx.emitNormalized(self.pending[0 .. self.len - keep], self.thinking);
                    }
                    self.len = keep;
                    if (keep != 0) self.pending[0] = '<';
                    start = i;
                }
                continue;
            }

            // self.len == 0: scanning normal / thinking text
            if (!self.thinking) {
                if (bytes[i] == '`') {
                    self.ticks += 1;
                    if (self.ticks == 3) {
                        self.fenced = !self.fenced;
                        self.ticks = 0;
                    }
                    i += 1;
                    continue;
                } else {
                    self.ticks = 0;
                }

                if (!self.fenced and bytes[i] == '<') {
                    if (i > start) {
                        try ctx.emitNormalized(bytes[start..i], false);
                    }
                    self.pending[0] = '<';
                    self.len = 1;
                    i += 1;
                    start = i;
                    continue;
                }

                i += 1;
            } else {
                if (bytes[i] == '<') {
                    if (i > start) {
                        try ctx.emitNormalized(bytes[start..i], true);
                    }
                    self.pending[0] = '<';
                    self.len = 1;
                    i += 1;
                    start = i;
                    continue;
                }

                i += 1;
            }
        }

        if (self.len == 0 and i > start) {
            try ctx.emitNormalized(bytes[start..i], self.thinking);
        }
    }

    pub fn finish(self: *Filter, ctx: anytype) !void {
        if (self.len != 0) try ctx.emitNormalized(self.pending[0..self.len], self.thinking);
        self.len = 0;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const MockCtx = struct {
    output: std.ArrayListUnmanaged(u8) = .empty,
    thinking_output: std.ArrayListUnmanaged(u8) = .empty,
    call_count: usize = 0,

    pub fn emitNormalized(self: *MockCtx, slice: []const u8, is_thinking: bool) !void {
        self.call_count += 1;
        const alloc = std.testing.allocator;
        if (is_thinking) {
            try self.thinking_output.appendSlice(alloc, slice);
        } else {
            try self.output.appendSlice(alloc, slice);
        }
    }

    pub fn deinit(self: *MockCtx) void {
        self.output.deinit(std.testing.allocator);
        self.thinking_output.deinit(std.testing.allocator);
    }
};

test "vietnamese text chunk preserved without byte splitting" {
    var f = Filter{ .tags = .english_only };
    var ctx = MockCtx{};
    defer ctx.deinit();

    const input = "BÁO CÁO NGHIÊN CỨU XU HƯỚNG FACEBOOK";
    try f.feed(input, &ctx);
    try f.finish(&ctx);

    try std.testing.expectEqualStrings(input, ctx.output.items);
    try std.testing.expectEqual(@as(usize, 1), ctx.call_count);
}

test "thinking tags separation" {
    var f = Filter{ .tags = .english_only };
    var ctx = MockCtx{};
    defer ctx.deinit();

    try f.feed("Hello <think>my thoughts</think> World", &ctx);
    try f.finish(&ctx);

    try std.testing.expectEqualStrings("Hello  World", ctx.output.items);
    try std.testing.expectEqualStrings("my thoughts", ctx.thinking_output.items);
}

test "split across chunks" {
    var f = Filter{ .tags = .english_only };
    var ctx = MockCtx{};
    defer ctx.deinit();

    try f.feed("Báo cáo ", &ctx);
    try f.feed("<thi", &ctx);
    try f.feed("nk>suy nghĩ", &ctx);
    try f.feed("</thi", &ctx);
    try f.feed("nk>kết quả", &ctx);
    try f.finish(&ctx);

    try std.testing.expectEqualStrings("Báo cáo kết quả", ctx.output.items);
    try std.testing.expectEqualStrings("suy nghĩ", ctx.thinking_output.items);
}
