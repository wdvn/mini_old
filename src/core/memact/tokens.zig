//! tokens.zig — TokenEstimator for MemAct
//! Estimates token count of strings using heuristics, without needing a real tokenizer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("../protocol.zig");

pub const TokenEstimator = struct {
    cache: std.StringHashMap(u32),
    alloc: Allocator,

    pub fn init(alloc: Allocator) TokenEstimator {
        return .{
            .cache = std.StringHashMap(u32).init(alloc),
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *TokenEstimator) void {
        var it = self.cache.keyIterator();
        while (it.next()) |k| {
            self.alloc.free(k.*);
        }
        self.cache.deinit();
    }

    /// Count CJK characters (codepoint > 0x2E80)
    fn countWideChars(text: []const u8) usize {
        var count: usize = 0;
        var i: usize = 0;
        while (i < text.len) {
            const bytes_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            if (bytes_len > 1 and i + bytes_len <= text.len) {
                if (std.unicode.utf8Decode(text[i .. i + bytes_len])) |cp| {
                    if (cp > 0x2E80) {
                        count += 1;
                    }
                } else |_| {}
            }
            i += bytes_len;
        }
        return count;
    }

    /// Heuristic: ~4 chars/token for EN/code, ~1.5 chars/token for CJK.
    pub fn estimate(self: *TokenEstimator, text: []const u8) u32 {
        if (text.len == 0) return 0;
        if (self.cache.get(text)) |v| return v;

        const n_cjk = countWideChars(text);
        const n_ascii = text.len - n_cjk; // approximation

        const tokens_ascii = @as(u32, @intFromFloat(@as(f64, @floatFromInt(n_ascii)) / 3.8));
        const tokens_cjk = @as(u32, @intFromFloat(@as(f64, @floatFromInt(n_cjk)) / 1.4));
        const tokens = tokens_ascii + tokens_cjk;

        // Store in cache
        if (self.alloc.dupe(u8, text)) |dup_text| {
            self.cache.put(dup_text, tokens) catch {
                self.alloc.free(dup_text);
            };
        } else |_| {}

        return tokens;
    }

    /// Estimate for a Message (including overhead for tool_use/result).
    pub fn estimateMessage(self: *TokenEstimator, msg: *const proto.Message) u32 {
        var total: u32 = 0;
        for (msg.content) |block| {
            switch (block) {
                .text => |t| total += self.estimate(t),
                .thinking => |th| {
                    total += self.estimate(th.thinking);
                    total += self.estimate(th.signature);
                },
                .tool_use => |tu| {
                    total += 40; // overhead
                    total += self.estimate(tu.name);
                    total += self.estimate(tu.input_json);
                },
                .tool_result => |tr| {
                    total += 20; // overhead
                    total += self.estimate(tr.content);
                },
                .image => |img| {
                    // Direct calculation without caching raw base64 in StringHashMap
                    const cost = @as(u32, @intCast(@max(85, img.data.len / 1000)));
                    total += cost;
                },
            }
        }
        return total;
    }

    /// Estimate for an array of Messages.
    pub fn estimateMessages(self: *TokenEstimator, msgs: []const proto.Message) u32 {
        var total: u32 = 0;
        for (msgs) |*msg| {
            total += self.estimateMessage(msg);
        }
        return total;
    }
};

test "token estimator heuristic" {
    const alloc = std.testing.allocator;
    var est = TokenEstimator.init(alloc);
    defer est.deinit();

    const en = est.estimate("Hello world! This is a simple test.");
    try std.testing.expect(en > 0 and en < 20);

    const vn = est.estimate("Xin chào, đây là một bài kiểm tra với tiếng Việt có dấu.");
    try std.testing.expect(vn > 0 and vn < 50);
}
