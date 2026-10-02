//! history/root.zig — Modular conversation history package root for mini-agent.
//!
//! Submodules:
//!   - `types`: History struct definition, memory management, content cloning.
//!   - `append`: Message appending, image blocks, error observations, rollback.
//!   - `compact`: Auto-compaction, summary compaction, and MemAct context compression.
//!   - `compat`: Claude and OpenAI protocol compatibility sanitizers.
//!   - `backup`: Serialization and file backup/restore.

const std = @import("std");
const proto = @import("../protocol.zig");
const main = @import("../../main.zig");

pub const types = @import("types.zig");
pub const backup = @import("backup.zig");
pub const append = @import("append.zig");
pub const compact = @import("compact.zig");
pub const compat = @import("compat.zig");

// Re-exports
pub const History = types.History;
pub const DEFAULT_MAX_MESSAGES = types.DEFAULT_MAX_MESSAGES;

test "compactMemAct preserves msgs[0], puts .user/.summarized summary at index 1, drops all following" {
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

test {
    _ = types;
    _ = backup;
    _ = append;
    _ = compact;
    _ = compat;
}
