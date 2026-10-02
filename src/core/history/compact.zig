//! history/compact.zig — Compaction and MemAct reactive context compression for History.

const std = @import("std");
const proto = @import("../protocol.zig");
const main = @import("../../main.zig");
const utils = @import("../utils.zig");
const types = @import("types.zig");
const History = types.History;

/// Compact: retains only the recent half of messages.
/// Always keeps an even pair (user + assistant) to maintain conversation structure.
pub fn compact(self: *History) void {
    const n = self.msgs.items.len;
    if (n <= 2) return;

    // Keep latter half, rounded down to even count
    const keep = (n / 2) & ~@as(usize, 1);
    const drop = n - keep;

    // Free discarded messages
    for (self.msgs.items[0..drop]) |msg| types.History.freeContentBlocks(self.alloc, msg.content);

    // Shift left
    std.mem.copyForwards(proto.Message, self.msgs.items[0..keep], self.msgs.items[drop..]);
    self.msgs.items.len = keep;

    if (!utils.isSubagent()) main.stderrPrint("[history] Compacted: kept {d}/{d} messages\n", .{ keep, n });
}

/// Checks whether history has exceeded the compaction threshold.
pub fn needsCompaction(self: *const History) bool {
    return self.msgs.items.len > self.max_messages;
}

/// Resets history: retains first message and inserts summary.
pub fn compactWithSummary(self: *History, summary: []const u8) !void {
    if (self.msgs.items.len <= 1) return;

    // Free messages from index 1 onwards
    for (self.msgs.items[1..]) |msg| {
        types.History.freeContentBlocks(self.alloc, msg.content);
    }

    self.msgs.items.len = 1;

    const summary_copy = try self.alloc.dupe(u8, summary);
    const blocks = try self.alloc.alloc(proto.ContentBlock, 1);
    blocks[0] = .{ .text = summary_copy };
    try self.msgs.append(self.alloc, .{ .role = .assistant, .content = blocks, .tier = .summarized });

    if (!utils.isSubagent()) main.stderrPrint("\n[history] Memory cleaned and context summary saved.\n", .{});
}

/// Compact according to MemAct logic: PRESERVES msgs.items[0] (original user prompt),
/// places summary message at index 1, and DROPS the rest.
pub fn compactMemAct(self: *History, act_id: usize, summary: []const u8) !void {
    // No-op: nothing to compact (haven't progressed past original prompt)
    if (self.msgs.items.len <= 1) return;

    // Update compaction act mark
    self.last_compaction_act_id = act_id;

    // If msgs[1] is summary from previous compaction -> replace; otherwise -> insert new.
    const replace_old_summary = self.msgs.items[1].tier == .summarized;

    // Free all messages from index 1 onwards (do not touch msgs[0] — original prompt)
    const dropped = self.msgs.items.len - 1;
    for (self.msgs.items[1..]) |msg| types.History.freeContentBlocks(self.alloc, msg.content);
    self.msgs.items.len = 1;

    // Create summary message. Role must be .user so Claude API does not reject
    // with 400 "first message must be user" (old session legacy compaction format).
    const summary_text = try std.fmt.allocPrint(self.alloc, "[MemAct Context Summary]\n{s}", .{summary});
    errdefer self.alloc.free(summary_text);
    const blocks = try self.alloc.alloc(proto.ContentBlock, 1);
    errdefer self.alloc.free(blocks);
    blocks[0] = .{ .text = summary_text };
    const summary_msg = proto.Message{ .role = .user, .content = blocks, .tier = .summarized };
    try self.msgs.append(self.alloc, summary_msg);

    if (!utils.isSubagent()) main.stderrPrint("\n[history] Context compacted (MemAct): preserved original prompt (index 0), {s} summary at index 1, dropped {d} messages.\n", .{ if (replace_old_summary) "replaced" else "inserted", dropped });
}
