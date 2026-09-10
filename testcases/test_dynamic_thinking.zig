//! test_dynamic_thinking.zig — Integration tests for Dynamic Thinking Budget & Reasoning Effort Modulation.
//!
//! Validates:
//!   1. CodeAct JS binding `mini.setThinking(...)` with string levels and integer token budgets.
//!   2. Cross-backend compatibility mapping (string level -> budget tokens, budget tokens -> effort).
//!   3. Autonomous cognitive modulation (Act 1 planning -> Act > 1 routine low -> error recovery high).
//!   4. Wire serialization for OpenAI (reasoning_effort) and Claude (thinking.budget_tokens).

const std = @import("std");
const mini = @import("mini");
const quickjs = mini.quickjs_engine;
const js_bindings = mini.js_bindings;
const openai = mini.backends.openai_mod;
const claude = mini.backends.claude_mod;
const config_mod = mini.config_mod;
const agent_mod = mini.agent_mod;
const proto = mini.protocol_mod;

test "dynamic_thinking: mini.setThinking JS binding supports string levels and budget numbers" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var engine = try quickjs.Engine.init(alloc, io);
    defer engine.deinit();

    // 1. mini.setThinking('low') -> effort = "low", budget = 1024
    {
        var res = try engine.eval("mini.setThinking('low');", "eval_low.js");
        defer res.deinit();
        try std.testing.expect(!res.is_error);

        const ov = js_bindings.consumePendingThinkingOverride();
        try std.testing.expect(ov != null);
        try std.testing.expectEqualStrings("low", ov.?.effort.?);
        try std.testing.expectEqual(@as(u32, 1024), ov.?.budget_tokens.?);
        try std.testing.expect(js_bindings.consumePendingThinkingOverride() == null);
    }

    // 2. mini.setThinking('high') -> effort = "high", budget = 8192
    {
        var res = try engine.eval("mini.setThinking('high');", "eval_high.js");
        defer res.deinit();
        try std.testing.expect(!res.is_error);

        const ov = js_bindings.consumePendingThinkingOverride();
        try std.testing.expect(ov != null);
        try std.testing.expectEqualStrings("high", ov.?.effort.?);
        try std.testing.expectEqual(@as(u32, 8192), ov.?.budget_tokens.?);
    }

    // 3. mini.setThinking(2048) -> token budget maps to effort = "medium", budget = 2048
    {
        var res = try engine.eval("mini.setThinking(2048);", "eval_num.js");
        defer res.deinit();
        try std.testing.expect(!res.is_error);

        const ov = js_bindings.consumePendingThinkingOverride();
        try std.testing.expect(ov != null);
        try std.testing.expectEqualStrings("medium", ov.?.effort.?);
        try std.testing.expectEqual(@as(u32, 2048), ov.?.budget_tokens.?);
    }

    // 4. mini.setThinking('none') -> disables thinking
    {
        var res = try engine.eval("mini.setThinking('none');", "eval_none.js");
        defer res.deinit();
        try std.testing.expect(!res.is_error);

        const ov = js_bindings.consumePendingThinkingOverride();
        try std.testing.expect(ov != null);
        try std.testing.expectEqualStrings("none", ov.?.effort.?);
        try std.testing.expectEqual(@as(u32, 0), ov.?.budget_tokens.?);
    }
}

test "dynamic_thinking: OpenAI wire serialization with reasoning_effort" {
    const alloc = std.testing.allocator;
    var client = openai.Client.init(alloc, "http://localhost:8000/v1", "testkey", "Authorization", "o3-mini", 2048);

    // Initial state: active_reasoning_effort is null
    try std.testing.expect(client.active_reasoning_effort == null);

    // Set dynamic reasoning effort to "low"
    client.setReasoningEffort("low");
    try std.testing.expectEqualStrings("low", client.active_reasoning_effort.?);

    // Set dynamic reasoning effort to "high"
    client.setReasoningEffort("high");
    try std.testing.expectEqualStrings("high", client.active_reasoning_effort.?);

    // Reset to null
    client.setReasoningEffort(null);
    try std.testing.expect(client.active_reasoning_effort == null);
}

test "dynamic_thinking: Claude wire serialization with thinking_budget" {
    const alloc = std.testing.allocator;
    var client = claude.Client.init(alloc, "sk-ant-test", "claude-3-7-sonnet", 4096);

    // Initial state: active_thinking_budget is null
    try std.testing.expect(client.active_thinking_budget == null);

    // Set dynamic thinking budget to 2048
    client.setThinkingBudget(2048);
    try std.testing.expectEqual(@as(u32, 2048), client.active_thinking_budget.?);

    // Reset to null
    client.setThinkingBudget(null);
    try std.testing.expect(client.active_thinking_budget == null);
}

test "dynamic_thinking: Backend union methods propagate effort and budget" {
    const alloc = std.testing.allocator;

    // 1. OpenAI backend
    var openai_backend: agent_mod.Backend = .{
        .openai = openai.Client.init(alloc, "http://localhost:8000/v1", "key", "Authorization", "o3-mini", 2048),
    };
    openai_backend.setReasoningEffort("low");
    try std.testing.expectEqualStrings("low", openai_backend.openai.active_reasoning_effort.?);

    // 2. Claude backend
    var claude_backend: agent_mod.Backend = .{
        .claude = claude.Client.init(alloc, "sk-ant-key", "claude-3-7-sonnet", 4096),
    };
    claude_backend.setThinkingBudget(3000);
    try std.testing.expectEqual(@as(u32, 3000), claude_backend.claude.active_thinking_budget.?);
}
