//! history/compat.zig — Protocol and vendor compatibility sanitizers for History.

const std = @import("std");
const proto = @import("../protocol.zig");
const types = @import("types.zig");
const History = types.History;

/// Ensures history compatibility with Claude API (first message must have .user role).
/// Old sessions compacted using legacy method might have msgs[0].role == .assistant -> convert to .user.
/// Does NOT touch content. Returns true if modified, false otherwise.
pub fn ensureClaudeCompatible(self: *History) bool {
    if (self.msgs.items.len > 0 and self.msgs.items[0].role == .assistant) {
        self.msgs.items[0].role = .user;
        return true;
    }
    return false;
}

pub fn collectToolAndResultIds(
    self: *History,
    valid_tool_ids: *std.StringHashMap(void),
    valid_result_ids: *std.StringHashMap(void),
) void {
    // PSEUDOCODE:
    // 1. Scan assistant messages for tool_use IDs.
    // 2. Scan other messages for tool_result IDs.
    for (self.msgs.items) |msg| {
        if (msg.role == .assistant) {
            for (msg.content) |block| {
                if (block == .tool_use) valid_tool_ids.put(block.tool_use.id, {}) catch {};
            }
        } else {
            for (msg.content) |block| {
                if (block == .tool_result) valid_result_ids.put(block.tool_result.tool_use_id, {}) catch {};
            }
        }
    }
}

pub fn convertOrphanToolCalls(self: *History, valid_result_ids: *const std.StringHashMap(void)) bool {
    // PSEUDOCODE:
    // 1. Iterate over assistant messages.
    // 2. If message contains tool_use without matching tool_result, convert to text block.
    var modified = false;
    for (self.msgs.items) |*msg| {
        if (msg.role != .assistant) continue;
        var has_orphan = false;
        for (msg.content) |block| {
            if (block == .tool_use and !valid_result_ids.contains(block.tool_use.id)) {
                has_orphan = true;
                break;
            }
        }
        if (!has_orphan) continue;

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
    return modified;
}

pub fn convertOrphanToolResults(self: *History, valid_tool_ids: *const std.StringHashMap(void)) bool {
    // PSEUDOCODE:
    // 1. Iterate over non-assistant messages.
    // 2. If message contains tool_result without matching tool_use, convert to [Observation] text.
    var modified = false;
    for (self.msgs.items) |*msg| {
        if (msg.role == .assistant) continue;
        var has_orphan = false;
        for (msg.content) |block| {
            if (block == .tool_result and !valid_tool_ids.contains(block.tool_result.tool_use_id)) {
                has_orphan = true;
                break;
            }
        }
        if (!has_orphan) continue;

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
    return modified;
}

/// Ensures history compatibility with OpenAI API:
/// 1. Strips/converts orphan tool_result blocks.
/// 2. Strips/converts orphan tool_use blocks.
pub fn ensureOpenAICompatible(self: *History) bool {
    // PSEUDOCODE:
    // 1. Collect valid tool and result IDs across history.
    // 2. Convert orphan tool calls in assistant messages to plain text.
    // 3. Convert orphan tool results in user messages to plain observation text.
    var valid_tool_ids = std.StringHashMap(void).init(self.alloc);
    defer valid_tool_ids.deinit();
    var valid_result_ids = std.StringHashMap(void).init(self.alloc);
    defer valid_result_ids.deinit();

    collectToolAndResultIds(self, &valid_tool_ids, &valid_result_ids);
    const mod1 = convertOrphanToolCalls(self, &valid_result_ids);
    const mod2 = convertOrphanToolResults(self, &valid_tool_ids);
    return mod1 or mod2;
}
