//! history/types.zig — Conversation history data structures and memory lifecycle.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const proto = @import("../protocol.zig");
const backup = @import("backup.zig");
const append = @import("append.zig");
const compact_mod = @import("compact.zig");
const compat = @import("compat.zig");

/// Maximum messages before auto-compaction.
pub const DEFAULT_MAX_MESSAGES = 100;

/// Conversation history for a session.
pub const History = struct {
    alloc: Allocator,
    msgs: ArrayList(proto.Message),
    /// Auto-compaction threshold.
    max_messages: usize,
    /// Act ID at last compaction (to block rollbacks beyond this checkpoint).
    last_compaction_act_id: usize,

    /// Initializes an empty History.
    pub fn init(alloc: Allocator) History {
        return .{
            .alloc = alloc,
            .msgs = .empty,
            .max_messages = DEFAULT_MAX_MESSAGES,
            .last_compaction_act_id = 0,
        };
    }

    pub fn freeContentBlocks(alloc: Allocator, blocks: []const proto.ContentBlock) void {
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
                .image => |img| {
                    alloc.free(img.data);
                    alloc.free(img.media_type);
                },
            }
        }
        alloc.free(blocks);
    }

    /// Releases all memory.
    pub fn deinit(self: *History) void {
        for (self.msgs.items) |msg| {
            freeContentBlocks(self.alloc, msg.content);
        }
        self.msgs.deinit(self.alloc);
    }

    /// Returns slice of current messages (unowned).
    pub fn messages(self: *const History) []const proto.Message {
        return self.msgs.items;
    }

    /// Current message count.
    pub fn len(self: *const History) usize {
        return self.msgs.items.len;
    }

    /// Clears entire history.
    pub fn clear(self: *History) void {
        for (self.msgs.items) |msg| freeContentBlocks(self.alloc, msg.content);
        self.msgs.clearRetainingCapacity();
    }

    pub fn cloneContentBlock(alloc: Allocator, block: proto.ContentBlock) !proto.ContentBlock {
        // PSEUDOCODE: Deep-clone a ContentBlock using the provided allocator.
        return switch (block) {
            .text => |t| .{ .text = try alloc.dupe(u8, t) },
            .thinking => |th| .{ .thinking = .{
                .thinking = try alloc.dupe(u8, th.thinking),
                .signature = try alloc.dupe(u8, th.signature),
            } },
            .tool_use => |tu| .{ .tool_use = .{
                .id = try alloc.dupe(u8, tu.id),
                .name = try alloc.dupe(u8, tu.name),
                .input_json = try alloc.dupe(u8, tu.input_json),
            } },
            .tool_result => |tr| .{ .tool_result = .{
                .tool_use_id = try alloc.dupe(u8, tr.tool_use_id),
                .content = try alloc.dupe(u8, tr.content),
                .is_error = tr.is_error,
            } },
            .image => |img| .{ .image = .{
                .data = try alloc.dupe(u8, img.data),
                .media_type = try alloc.dupe(u8, img.media_type),
            } },
        };
    }

    pub fn cloneContent(alloc: Allocator, content: []const proto.ContentBlock) ![]proto.ContentBlock {
        // PSEUDOCODE: Allocate and clone all ContentBlocks in a slice.
        const copy = try alloc.alloc(proto.ContentBlock, content.len);
        for (content, 0..) |block, i| {
            copy[i] = try cloneContentBlock(alloc, block);
        }
        return copy;
    }

    // Method delegations
    pub const backupToFile = backup.backupToFile;
    pub const restoreFromFile = backup.restoreFromFile;
    pub const addUser = append.addUser;
    pub const addUserWithImages = append.addUserWithImages;
    pub const addAssistantText = append.addAssistantText;
    pub const addAssistantResponse = append.addAssistantResponse;
    pub const addToolResults = append.addToolResults;
    pub const addToolResultsWithImages = append.addToolResultsWithImages;
    pub const addSystemErrorObservation = append.addSystemErrorObservation;
    pub const popLast = append.popLast;
    pub const truncate = append.truncate;
    pub const compact = compact_mod.compact;
    pub const needsCompaction = compact_mod.needsCompaction;
    pub const compactWithSummary = compact_mod.compactWithSummary;
    pub const compactMemAct = compact_mod.compactMemAct;
    pub const ensureClaudeCompatible = compat.ensureClaudeCompatible;
    pub const ensureOpenAICompatible = compat.ensureOpenAICompatible;
};
