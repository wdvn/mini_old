const std = @import("std");
const testing = std.testing;
const mini = @import("mini");
const openai = mini.backends.openai_mod;
const proto = mini.protocol_mod;
const history_mod = mini.history_mod;

test "dual-protocol: getRootApiUrl chuẩn hóa base URL" {
    try testing.expectEqualStrings("https://api.openai.com/v1", openai.getRootApiUrl("https://api.openai.com/v1"));
    try testing.expectEqualStrings("https://api.openai.com/v1", openai.getRootApiUrl("https://api.openai.com/v1/chat/completions"));
    try testing.expectEqualStrings("https://api.openai.com/v1", openai.getRootApiUrl("https://api.openai.com/v1/chat/completions/"));
    try testing.expectEqualStrings("https://api.openai.com/v1", openai.getRootApiUrl("https://api.openai.com/v1/responses"));
    try testing.expectEqualStrings("https://api.openai.com/v1", openai.getRootApiUrl("https://api.openai.com/v1/responses/"));
    try testing.expectEqualStrings("http://localhost:11434/v1", openai.getRootApiUrl("http://localhost:11434/v1/"));
}

test "dual-protocol: shouldUseResponsesApi heuristic cho model thế hệ mới" {
    try testing.expect(openai.shouldUseResponsesApi("gpt-5.6-luna"));
    try testing.expect(openai.shouldUseResponsesApi("gpt-5.6-terra"));
    try testing.expect(openai.shouldUseResponsesApi("gpt-5-sol"));
    try testing.expect(openai.shouldUseResponsesApi("o3-pro"));
    try testing.expect(openai.shouldUseResponsesApi("o1-pro"));

    try testing.expect(!openai.shouldUseResponsesApi("gpt-4o"));
    try testing.expect(!openai.shouldUseResponsesApi("gpt-4o-mini"));
    try testing.expect(!openai.shouldUseResponsesApi("deepseek-chat"));
    try testing.expect(!openai.shouldUseResponsesApi("claude-3-5-sonnet"));
}

test "dual-protocol: client khởi tạo và protocol enum" {
    const client = openai.Client.initWithProtocol(
        testing.allocator,
        "https://api.openai.com/v1",
        "sk-test",
        "Authorization",
        "gpt-5.6-luna",
        4096,
        .auto,
    );
    try testing.expectEqual(openai.ProtocolMode.auto, client.protocol_mode);
    try testing.expect(client.cached_protocol == null);
}

test "dual-protocol: History.ensureOpenAICompatible loại bỏ orphan tool result" {
    var h = history_mod.History.init(testing.allocator);
    defer h.deinit();

    // 1. Valid pair: assistant gọi tool_123, sau đó user trả lời tool_123
    const tu_blocks = try testing.allocator.alloc(proto.ContentBlock, 1);
    tu_blocks[0] = .{ .tool_use = .{
        .id = try testing.allocator.dupe(u8, "tool_123"),
        .name = try testing.allocator.dupe(u8, "bash"),
        .input_json = try testing.allocator.dupe(u8, "{}"),
    } };
    try h.msgs.append(testing.allocator, .{ .role = .assistant, .content = tu_blocks });

    const tr_blocks = try testing.allocator.alloc(proto.ContentBlock, 1);
    tr_blocks[0] = .{ .tool_result = .{
        .tool_use_id = try testing.allocator.dupe(u8, "tool_123"),
        .content = try testing.allocator.dupe(u8, "success output"),
        .is_error = false,
    } };
    try h.msgs.append(testing.allocator, .{ .role = .user, .content = tr_blocks });

    // 2. Orphan tool result: tool_orphan_999 (không có assistant trước đó)
    const orphan_blocks = try testing.allocator.alloc(proto.ContentBlock, 1);
    orphan_blocks[0] = .{ .tool_result = .{
        .tool_use_id = try testing.allocator.dupe(u8, "tool_orphan_999"),
        .content = try testing.allocator.dupe(u8, "orphan output"),
        .is_error = false,
    } };
    try h.msgs.append(testing.allocator, .{ .role = .user, .content = orphan_blocks });

    // Chạy sanitization
    const modified = h.ensureOpenAICompatible();
    try testing.expect(modified == true);

    // tool_123 vẫn giữ nguyên là .tool_result
    try testing.expect(h.msgs.items[1].content[0] == .tool_result);
    // tool_orphan_999 đã được convert thành .text an toàn
    try testing.expect(h.msgs.items[2].content[0] == .text);
    try testing.expect(std.mem.indexOf(u8, h.msgs.items[2].content[0].text, "orphan output") != null);
}

test "dual-protocol: History.ensureOpenAICompatible loại bỏ orphan tool_use không có tool_result" {
    var h = history_mod.History.init(testing.allocator);
    defer h.deinit();

    const orphan_tu = try testing.allocator.alloc(proto.ContentBlock, 1);
    orphan_tu[0] = .{ .tool_use = .{
        .id = try testing.allocator.dupe(u8, "tool_orphan_tu"),
        .name = try testing.allocator.dupe(u8, "invoke_subagent"),
        .input_json = try testing.allocator.dupe(u8, "{\"task\":\"scan\"}"),
    } };
    try h.msgs.append(testing.allocator, .{ .role = .assistant, .content = orphan_tu });

    const modified = h.ensureOpenAICompatible();
    try testing.expect(modified == true);
    try testing.expect(h.msgs.items[0].content[0] == .text);
    try testing.expect(std.mem.indexOf(u8, h.msgs.items[0].content[0].text, "[Tool Call: invoke_subagent") != null);
}

test "dual-protocol: Responses API unescapes tool arguments and executes bash without missing command error" {
    const alloc = testing.allocator;
    const tools_mod = mini.tools_mod;

    // Giả lập tool input sau khi parse từ SSE Responses API
    const raw_sse_event_arguments = "{\"command\":\"echo 'unit test success'\"}";
    
    // Thực thi trực tiếp qua tool dispatcher
    const result = try tools_mod.executeTool(alloc, testing.io, "bash", raw_sse_event_arguments);
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "unit test success") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Lỗi: thiếu trường 'command'") == null);
}

test "dual-protocol: Responses API subagent tool extracts task or aliases cleanly" {
    const alloc = testing.allocator;
    const json_mod = @import("../src/core/json.zig");

    const valid_json = "{\"task\":\"Khảo sát mã nguồn gateway\"}";
    const task_val = try json_mod.findStringOwned(alloc, valid_json, "task");
    defer if (task_val) |t| alloc.free(t);

    try testing.expect(task_val != null);
    try testing.expectEqualStrings("Khảo sát mã nguồn gateway", task_val.?);
}
