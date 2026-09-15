//! history.zig — In-memory conversation history.
//!
//! Manages the list of `Message`s in a conversation session.
//! Automatically compacts when message count exceeds threshold to prevent
//! overflowing the AI model's context window.
//!
//! ## Usage
//! ```zig
//! var h = History.init(alloc);
//! defer h.deinit();
//! try h.addUser("Hello!");
//! try h.addAssistant("Hi there!");
//! const msgs = h.messages();  // send to API
//! ```
//!
//! ## Compact
//! When `messages.len > max_messages`, call `compact()` to retain
//! only the most recent half of the messages (counted by user/assistant pairs).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const proto = @import("protocol.zig");
const main = @import("../main.zig");
const utils = @import("utils.zig");



/// Maximum messages before auto-compaction.
const DEFAULT_MAX_MESSAGES = 40;

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

    /// Backs up history to a JSON file.
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

    /// Restores history from a JSON file.
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
                    .image => |img| .{ .image = .{
                        .data = try self.alloc.dupe(u8, img.data),
                        .media_type = try self.alloc.dupe(u8, img.media_type),
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
        const text_copy = try self.alloc.dupe(u8, text);
        const total_blocks = 1 + images.len;
        const blocks = try self.alloc.alloc(proto.ContentBlock, total_blocks);
        blocks[0] = .{ .text = text_copy };
        for (images, 0..) |img, idx| {
            blocks[1 + idx] = .{ .image = .{
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
                }},
                .tool_result => |tr| .{ .tool_result = .{
                    .tool_use_id = try self.alloc.dupe(u8, tr.tool_use_id),
                    .content = try self.alloc.dupe(u8, tr.content),
                    .is_error = tr.is_error,
                }},
                .image => |img| .{ .image = .{
                    .data = try self.alloc.dupe(u8, img.data),
                    .media_type = try self.alloc.dupe(u8, img.media_type),
                }},
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
            }};
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
            }};
        }
        for (images, 0..) |img, j| {
            blocks[results.len + j] = .{ .image = .{
                .data = try self.alloc.dupe(u8, img.data),
                .media_type = try self.alloc.dupe(u8, img.media_type),
            }};
        }
        try self.msgs.append(self.alloc, .{ .role = .user, .content = blocks, .tier = .recent });
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

    /// Removes the last message from history.
    pub fn popLast(self: *History) void {
        if (self.msgs.items.len == 0) return;
        const last = self.msgs.items[self.msgs.items.len - 1];
        freeContentBlocks(self.alloc, last.content);
        self.msgs.items.len -= 1;
    }

    /// Truncates messages starting from the specified index (Rollback).
    pub fn truncate(self: *History, target_len: usize) void {
        if (target_len >= self.msgs.items.len) return;
        for (self.msgs.items[target_len..]) |msg| {
            freeContentBlocks(self.alloc, msg.content);
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

    /// Compact: retains only the recent half of messages.
    /// Always keeps an even pair (user + assistant) to maintain conversation structure.
    pub fn compact(self: *History) void {
        const n = self.msgs.items.len;
        if (n <= 2) return;

        // Keep latter half, rounded down to even count
        const keep = (n / 2) & ~@as(usize, 1);
        const drop = n - keep;

        // Free discarded messages
        for (self.msgs.items[0..drop]) |msg| freeContentBlocks(self.alloc, msg.content);

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
            freeContentBlocks(self.alloc, msg.content);
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
    ///
    /// Does not keep N recent messages: with large windows, keeping (~60% window)
    /// still exceeds compaction threshold -> compacts every turn (wasting LLM calls,
    /// history never drops below threshold). State of "current step" is preserved in
    /// summary (task_state/next_step) so the model continues properly.
    ///
    /// If msgs.items[1] is already a summary from previous compaction (.summarized tier),
    /// the old summary is replaced by the new cumulative summary.
    pub fn compactMemAct(self: *History, act_id: usize, summary: []const u8) !void {
        // No-op: nothing to compact (haven't progressed past original prompt)
        if (self.msgs.items.len <= 1) return;

        // Update compaction act mark
        self.last_compaction_act_id = act_id;

        // If msgs[1] is summary from previous compaction -> replace; otherwise -> insert new.
        const replace_old_summary = self.msgs.items[1].tier == .summarized;

        // Free all messages from index 1 onwards (do not touch msgs[0] — original prompt)
        const dropped = self.msgs.items.len - 1;
        for (self.msgs.items[1..]) |msg| freeContentBlocks(self.alloc, msg.content);
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

    /// Ensures history compatibility with OpenAI API:
    /// 1. Strips/converts orphan tool_result blocks (without preceding assistant message holding corresponding tool_use).
    ///    Prevents OpenAI 400 error: "No tool call found for function call output with call_id ...".
    /// 2. Strips/converts orphan tool_use blocks (without succeeding user message holding corresponding tool_result).
    ///    Prevents OpenAI 400 error: "No tool output found for function call ...".
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

        // Pass 1: Handle assistant messages containing tool_use without succeeding tool_result
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

        // Pass 2: Handle user messages containing tool_result without preceding tool_use
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

test "compactMemAct preserves msgs[0], puts .user/.summarized summary at index 1, drops all following" {
    // compactMemAct logs via main.stderrPrint using g_io — in test mode g_io
    // is uninitialized (only set in main()) -> assign std.testing.io for safety.
    main.g_io = std.testing.io;
    const alloc = std.testing.allocator;
    var h = History.init(alloc);
    defer h.deinit();

    try h.addUser("original prompt");
    try h.addAssistantText("reply 1");
    try h.addUser("question 2");
    try h.addAssistantText("reply 2");
    try h.addUser("question 3");
    try h.addAssistantText("reply 3");

    try h.compactMemAct(7, "context summary");

    // Only original prompt + summary remain
    try std.testing.expectEqual(@as(usize, 2), h.msgs.items.len);

    // msgs[0] intact: role .user, text original prompt
    try std.testing.expect(h.msgs.items[0].role == .user);
    try std.testing.expectEqualStrings("original prompt", h.msgs.items[0].content[0].text);

    // Summary at index 1: role .user (Claude-compatible), tier .summarized, prefixed
    try std.testing.expect(h.msgs.items[1].role == .user);
    try std.testing.expect(h.msgs.items[1].tier == .summarized);
    try std.testing.expectEqualStrings("[MemAct Context Summary]\ncontext summary", h.msgs.items[1].content[0].text);

    try std.testing.expect(h.last_compaction_act_id == 7);
}

test "second compactMemAct cumulatively aggregates: replaces old summary, msgs[0] intact, no leak" {
    main.g_io = std.testing.io;
    const alloc = std.testing.allocator;
    var h = History.init(alloc);
    defer h.deinit();

    try h.addUser("original prompt");
    try h.addAssistantText("reply 1");
    try h.addUser("question 2");
    try h.addAssistantText("reply 2");

    // Compact 1: remaining [original prompt, summary v1]
    try h.compactMemAct(3, "summary v1");
    try std.testing.expectEqual(@as(usize, 2), h.msgs.items.len);

    // Add new turns and compact 2nd time: old summary is replaced
    try h.addUser("question 3");
    try h.addAssistantText("reply 3");
    try h.compactMemAct(9, "summary v2 merged");

    try std.testing.expectEqual(@as(usize, 2), h.msgs.items.len);

    // msgs[0] remains intact across both compactions
    try std.testing.expect(h.msgs.items[0].role == .user);
    try std.testing.expectEqualStrings("original prompt", h.msgs.items[0].content[0].text);

    // msgs[1] is NEW summary (replaces old summary which was properly freed)
    try std.testing.expect(h.msgs.items[1].role == .user);
    try std.testing.expect(h.msgs.items[1].tier == .summarized);
    try std.testing.expectEqualStrings("[MemAct Context Summary]\nsummary v2 merged", h.msgs.items[1].content[0].text);

    try std.testing.expect(h.last_compaction_act_id == 9);
}

test "compactMemAct no-op when history is too short (original prompt only or empty)" {
    const alloc = std.testing.allocator;
    var h = History.init(alloc);
    defer h.deinit();

    try h.addUser("a");
    try h.compactMemAct(5, "sum");
    try std.testing.expectEqual(@as(usize, 1), h.msgs.items.len);
    try std.testing.expectEqualStrings("a", h.msgs.items[0].content[0].text);
    try std.testing.expect(h.last_compaction_act_id == 0); // checkpoint not updated

    // Empty history -> no-op
    var h2 = History.init(alloc);
    defer h2.deinit();
    try h2.compactMemAct(2, "sum");
    try std.testing.expectEqual(@as(usize, 0), h2.msgs.items.len);
    try std.testing.expect(h2.last_compaction_act_id == 0);
}

test "ensureClaudeCompatible changes role of first assistant message and returns correct bool" {
    const alloc = std.testing.allocator;
    var h = History.init(alloc);
    defer h.deinit();

    // No fix needed: empty history
    try std.testing.expect(h.ensureClaudeCompatible() == false);

    // Old session legacy compacted: msgs[0].role == .assistant
    try h.addAssistantText("old summary assistant-first");
    try h.addUser("new question");

    try std.testing.expect(h.ensureClaudeCompatible() == true);
    try std.testing.expect(h.msgs.items[0].role == .user);
    // Content untouched
    try std.testing.expectEqualStrings("old summary assistant-first", h.msgs.items[0].content[0].text);
    try std.testing.expect(h.msgs.items[1].role == .user);

    // Second call: msgs[0] is already .user -> no fix, returns false
    try std.testing.expect(h.ensureClaudeCompatible() == false);
    try std.testing.expect(h.msgs.items[0].role == .user);
}

test "ensureOpenAICompatible safely converts orphan tool_result to text" {
    const alloc = std.testing.allocator;
    var h = History.init(alloc);
    defer h.deinit();

    // Add 1 orphan tool_result (without preceding assistant tool_use)
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

    // Run 2: already text, no modification
    try std.testing.expect(h.ensureOpenAICompatible() == false);
}

test "ensureOpenAICompatible safely converts orphan tool_use to text" {
    const alloc = std.testing.allocator;
    var h = History.init(alloc);
    defer h.deinit();

    // Add 1 orphan tool_use (without succeeding user tool_result)
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

    // Run 2: already text, no modification
    try std.testing.expect(h.ensureOpenAICompatible() == false);
}
