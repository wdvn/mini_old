//! history/append.zig — Message appending and truncation operations for History.

const std = @import("std");
const proto = @import("../protocol.zig");
const types = @import("types.zig");
const History = types.History;

/// Appends user message.
/// `text` is copied into memory owned by History.
pub fn addUser(self: *History, text: []const u8) !void {
    const text_copy = try self.alloc.dupe(u8, text);
    const blocks = try self.alloc.alloc(proto.ContentBlock, 1);
    blocks[0] = .{ .text = text_copy };
    try self.msgs.append(self.alloc, .{ .role = .user, .content = blocks, .tier = .recent });
}

/// Appends user message with image attachments (RFC-011 Media Ingestion).
pub fn addUserWithImages(self: *History, text: []const u8, images: []const proto.ImageBlock) !void {
    const has_text = text.len > 0;
    const total_blocks = (if (has_text) @as(usize, 1) else 0) + images.len;
    if (total_blocks == 0) return;
    const blocks = try self.alloc.alloc(proto.ContentBlock, total_blocks);
    var offset: usize = 0;
    if (has_text) {
        blocks[0] = .{ .text = try self.alloc.dupe(u8, text) };
        offset = 1;
    }
    for (images, 0..) |img, idx| {
        blocks[offset + idx] = .{ .image = .{
            .data = try self.alloc.dupe(u8, img.data),
            .media_type = try self.alloc.dupe(u8, img.media_type),
        } };
    }
    try self.msgs.append(self.alloc, .{ .role = .user, .content = blocks, .tier = .recent });
}

/// Appends assistant message (text response).
pub fn addAssistantText(self: *History, text: []const u8) !void {
    const text_copy = try self.alloc.dupe(u8, text);
    const blocks = try self.alloc.alloc(proto.ContentBlock, 1);
    blocks[0] = .{ .text = text_copy };
    try self.msgs.append(self.alloc, .{ .role = .assistant, .content = blocks, .tier = .recent });
}

/// Appends full AI response (may contain text + tool_use).
/// Content blocks are deeply copied into History. Returns true if message was added.
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
            } },
            .tool_result => |tr| .{ .tool_result = .{
                .tool_use_id = try self.alloc.dupe(u8, tr.tool_use_id),
                .content = try self.alloc.dupe(u8, tr.content),
                .is_error = tr.is_error,
            } },
            .image => |img| .{ .image = .{
                .data = try self.alloc.dupe(u8, img.data),
                .media_type = try self.alloc.dupe(u8, img.media_type),
            } },
        };
    }
    try self.msgs.append(self.alloc, .{ .role = .assistant, .content = blocks, .tier = .recent });
    return true;
}

/// Appends tool execution results to history (as user message with tool_result blocks).
pub fn addToolResults(self: *History, results: []const proto.ToolResult) !void {
    if (results.len == 0) return;
    const blocks = try self.alloc.alloc(proto.ContentBlock, results.len);
    for (results, 0..) |r, i| {
        blocks[i] = .{ .tool_result = .{
            .tool_use_id = try self.alloc.dupe(u8, r.tool_use_id),
            .content = try self.alloc.dupe(u8, r.content),
            .is_error = r.is_error,
        } };
    }
    try self.msgs.append(self.alloc, .{ .role = .user, .content = blocks, .tier = .recent });
}

/// Appends tool execution results + attached loop-back images (RFC-011 §3.5).
pub fn addToolResultsWithImages(self: *History, results: []const proto.ToolResult, images: []const proto.ImageBlock) !void {
    const total_blocks = results.len + images.len;
    if (total_blocks == 0) return;
    const blocks = try self.alloc.alloc(proto.ContentBlock, total_blocks);
    for (results, 0..) |r, i| {
        blocks[i] = .{ .tool_result = .{
            .tool_use_id = try self.alloc.dupe(u8, r.tool_use_id),
            .content = try self.alloc.dupe(u8, r.content),
            .is_error = r.is_error,
        } };
    }
    for (images, 0..) |img, j| {
        blocks[results.len + j] = .{ .image = .{
            .data = try self.alloc.dupe(u8, img.data),
            .media_type = try self.alloc.dupe(u8, img.media_type),
        } };
    }
    try self.msgs.append(self.alloc, .{ .role = .user, .content = blocks, .tier = .recent });
}

/// Removes the last message from history.
pub fn popLast(self: *History) void {
    if (self.msgs.items.len == 0) return;
    const last = self.msgs.items[self.msgs.items.len - 1];
    types.History.freeContentBlocks(self.alloc, last.content);
    self.msgs.items.len -= 1;
}

/// Truncates messages starting from the specified index (Rollback).
pub fn truncate(self: *History, target_len: usize) void {
    if (target_len >= self.msgs.items.len) return;
    for (self.msgs.items[target_len..]) |msg| {
        types.History.freeContentBlocks(self.alloc, msg.content);
    }
    self.msgs.items.len = target_len;
}

/// Appends a system error observation from Agent.
pub fn addSystemErrorObservation(self: *History, err_msg: []const u8) !void {
    const text_copy = try self.alloc.dupe(u8, err_msg);
    const blocks = try self.alloc.alloc(proto.ContentBlock, 1);
    blocks[0] = .{ .text = text_copy };
    // Must be .user so LLM can read as an observation
    try self.msgs.append(self.alloc, .{ .role = .user, .content = blocks, .tier = .recent });
}
