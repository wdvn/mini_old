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
        for (bytes) |byte| {
            if (!self.thinking and self.len == 0) {
                if (byte == '`') {
                    self.ticks += 1;
                    if (self.ticks == 3) {
                        self.fenced = !self.fenced;
                        self.ticks = 0;
                    }
                } else self.ticks = 0;
                if (self.fenced or byte != '<') {
                    try ctx.emitNormalized(&.{byte}, false);
                    continue;
                }
            } else if (self.len == 0 and byte != '<') {
                try ctx.emitNormalized(&.{byte}, self.thinking);
                continue;
            }
            self.pending[self.len] = byte;
            self.len += 1;
            const candidates = if (self.thinking) &closes else &opens;
            const count: usize = if (self.tags == .english_only) 1 else opens.len;
            var prefix = false;
            for (candidates[0..count]) |tag| {
                if (std.mem.eql(u8, self.pending[0..self.len], tag)) {
                    self.thinking = !self.thinking;
                    self.len = 0;
                    prefix = true;
                    break;
                }
                if (std.mem.startsWith(u8, tag, self.pending[0..self.len])) prefix = true;
            }
            if (!prefix) {
                // Reconsider a trailing '<' as the beginning of a new tag.
                const keep: usize = if (byte == '<') 1 else 0;
                try ctx.emitNormalized(self.pending[0 .. self.len - keep], self.thinking);
                self.len = keep;
                if (keep != 0) self.pending[0] = '<';
            }
        }
    }

    pub fn finish(self: *Filter, ctx: anytype) !void {
        if (self.len != 0) try ctx.emitNormalized(self.pending[0..self.len], self.thinking);
        self.len = 0;
    }
};
