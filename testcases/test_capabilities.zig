//! test_capabilities.zig — Integration tests for Model Capabilities, Alias Normalization, and Reasoning Budgeting.
//!
//! Validates:
//!   1. normalizeModelAlias: prefix '~', provider '/~', suffix '~variant'.
//!   2. parseModelCapabilityFromJson: schema parsing, reasoning object, supported_efforts.
//!   3. clipEffort: bounds checking, mandatory reasoning enforcement against "none".
//!   4. guardReasoningMaxTokens: strict '<' for Anthropic, '<=' for OpenAI.
//!   5. CapabilityCache: thread-safe caching, alias retrieval, leak-free under DebugAllocator.
//!   6. Backend union routing: setReasoningMaxTokens dispatch for OpenAI and Claude.

const std = @import("std");
const mini = @import("mini");
const capabilities = mini.capabilities_mod;
const ModelCapability = capabilities.ModelCapability;
const CapabilityCache = capabilities.CapabilityCache;
const openai = mini.backends.openai_mod;
const claude = mini.backends.claude_mod;
const agent_mod = mini.agent_mod;
const config_mod = mini.config_mod;
const journal_mod = mini.journal_mod;

test "capabilities: normalizeModelAlias comprehensive matrix" {
    // Leading '~'
    try std.testing.expectEqualStrings("gpt-4o", capabilities.normalizeModelAlias("~gpt-4o"));
    try std.testing.expectEqualStrings("claude-3-7-sonnet", capabilities.normalizeModelAlias("~claude-3-7-sonnet"));

    // Trailing '~variant'
    try std.testing.expectEqualStrings("o3-mini", capabilities.normalizeModelAlias("o3-mini~high"));
    try std.testing.expectEqualStrings("o1", capabilities.normalizeModelAlias("o1~medium"));
    try std.testing.expectEqualStrings("deepseek-reasoner", capabilities.normalizeModelAlias("deepseek-reasoner~low"));

    // Provider prefix with '/~'
    try std.testing.expectEqualStrings("o3-mini", capabilities.normalizeModelAlias("openai/~o3-mini"));
    try std.testing.expectEqualStrings("gpt-4o", capabilities.normalizeModelAlias("custom-provider/~gpt-4o"));

    // Combination: provider prefix with '/~' and suffix '~variant'
    try std.testing.expectEqualStrings("o3-mini", capabilities.normalizeModelAlias("openai/~o3-mini~high"));

    // Provider prefix without '~'
    try std.testing.expectEqualStrings("openai/gpt-4o", capabilities.normalizeModelAlias("~openai/gpt-4o"));
    try std.testing.expectEqualStrings("openai/gpt-4o", capabilities.normalizeModelAlias("openai/gpt-4o"));
}

test "capabilities: ModelCapability clipEffort behavior" {
    const efforts = [_][]const u8{ "low", "medium", "high" };

    // Case 1: Optional reasoning
    const opt_model = ModelCapability{
        .id = "mock-opt",
        .supports_reasoning = true,
        .reasoning_mandatory = false,
        .supported_efforts = &efforts,
    };

    // Valid requests match
    try std.testing.expectEqualStrings("low", opt_model.clipEffort("low").?);
    try std.testing.expectEqualStrings("medium", opt_model.clipEffort("medium").?);
    try std.testing.expectEqualStrings("high", opt_model.clipEffort("high").?);

    // Unsupported effort clips to first supported ("low")
    try std.testing.expectEqualStrings("low", opt_model.clipEffort("extreme").?);

    // "none" is permitted when reasoning is not mandatory
    try std.testing.expectEqualStrings("none", opt_model.clipEffort("none").?);

    // null remains null
    try std.testing.expect(opt_model.clipEffort(null) == null);

    // Case 2: Mandatory reasoning (e.g. o1 / o3-mini)
    const man_model = ModelCapability{
        .id = "o3-mini",
        .supports_reasoning = true,
        .reasoning_mandatory = true,
        .supported_efforts = &efforts,
    };

    // "none" is disallowed and falls back to lowest supported effort
    try std.testing.expectEqualStrings("low", man_model.clipEffort("none").?);

    // null falls back to lowest supported effort
    try std.testing.expectEqualStrings("low", man_model.clipEffort(null).?);

    // Valid supported requests still match
    try std.testing.expectEqualStrings("high", man_model.clipEffort("high").?);
}

test "capabilities: guardReasoningMaxTokens Anthropic vs OpenAI constraints" {
    // Anthropic requires strictly: reasoning.max_tokens < max_tokens
    // Equal to max_tokens -> clamped strictly below max_tokens
    try std.testing.expectEqual(@as(u32, 3072), ModelCapability.guardReasoningMaxTokens(4096, 4096, true));
    // Greater than max_tokens -> clamped strictly below max_tokens
    try std.testing.expectEqual(@as(u32, 3072), ModelCapability.guardReasoningMaxTokens(5000, 4096, true));
    // Valid strictly less than max_tokens -> unchanged
    try std.testing.expectEqual(@as(u32, 2048), ModelCapability.guardReasoningMaxTokens(2048, 4096, true));

    // OpenAI allows <= max_tokens
    // Equal to max_tokens -> unchanged
    try std.testing.expectEqual(@as(u32, 4096), ModelCapability.guardReasoningMaxTokens(4096, 4096, false));
    // Greater than max_tokens -> clamped to max_tokens
    try std.testing.expectEqual(@as(u32, 4096), ModelCapability.guardReasoningMaxTokens(6000, 4096, false));
    // Less than max_tokens -> unchanged
    try std.testing.expectEqual(@as(u32, 1024), ModelCapability.guardReasoningMaxTokens(1024, 4096, false));
}

test "capabilities: parseModelCapabilityFromJson parses list format" {
    const alloc = std.testing.allocator;
    const json_data =
        \\{
        \\  "object": "list",
        \\  "data": [
        \\    {
        \\      "id": "gpt-4o",
        \\      "max_tokens": 4096
        \\    },
        \\    {
        \\      "id": "o3-mini",
        \\      "max_tokens": 8192,
        \\      "reasoning": {
        \\        "mandatory": true,
        \\        "max_tokens": 4096,
        \\        "supported_efforts": ["low", "medium", "high"]
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    const cap = capabilities.parseModelCapabilityFromJson(alloc, json_data, "o3-mini");
    try std.testing.expect(cap != null);
    defer {
        alloc.free(cap.?.id);
        for (cap.?.supported_efforts) |e| alloc.free(e);
        alloc.free(cap.?.supported_efforts);
    }

    try std.testing.expectEqualStrings("o3-mini", cap.?.id);
    try std.testing.expect(cap.?.supports_reasoning);
    try std.testing.expect(cap.?.reasoning_mandatory);
    try std.testing.expectEqual(@as(?u32, 8192), cap.?.max_tokens);
    try std.testing.expectEqual(@as(?u32, 4096), cap.?.reasoning_max_tokens);
    try std.testing.expectEqual(@as(usize, 3), cap.?.supported_efforts.len);
}

test "capabilities: CapabilityCache memory lifecycle" {
    const alloc = std.testing.allocator;
    var cache = CapabilityCache.init(alloc);
    defer cache.deinit();

    const id = try alloc.dupe(u8, "model-x");
    const efforts = try alloc.alloc([]const u8, 2);
    efforts[0] = try alloc.dupe(u8, "low");
    efforts[1] = try alloc.dupe(u8, "high");

    try cache.put("model-x", .{
        .id = id,
        .supports_reasoning = true,
        .supported_efforts = efforts,
    });

    // Lookup via normalized alias
    const found = cache.get("~model-x~variant");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("model-x", found.?.id);
    try std.testing.expectEqual(@as(usize, 2), found.?.supported_efforts.len);
}

test "capabilities: Backend setReasoningMaxTokens dispatch" {
    const alloc = std.testing.allocator;

    // 1. OpenAI Backend
    var openai_backend: agent_mod.Backend = .{
        .openai = openai.Client.init(alloc, "http://127.0.0.1:8000/v1", "key", "Authorization", "o3-mini", 4096),
    };
    try std.testing.expect(openai_backend.openai.active_reasoning_max_tokens == null);

    openai_backend.setReasoningMaxTokens(2048);
    try std.testing.expectEqual(@as(?u32, 2048), openai_backend.openai.active_reasoning_max_tokens);

    openai_backend.setReasoningMaxTokens(null);
    try std.testing.expect(openai_backend.openai.active_reasoning_max_tokens == null);

    // 2. Claude Backend
    var claude_backend: agent_mod.Backend = .{
        .claude = claude.Client.init(alloc, "sk-ant-test", "claude-3-7-sonnet", 4096),
    };
    try std.testing.expect(claude_backend.claude.active_thinking_budget == null);

    claude_backend.setReasoningMaxTokens(3072);
    try std.testing.expectEqual(@as(?u32, 3072), claude_backend.claude.active_thinking_budget);
}

test "capabilities: journal act_generation_slow event exists" {
    const event = journal_mod.ActEventType.act_generation_slow;
    try std.testing.expectEqualStrings("act_generation_slow", @tagName(event));
}

test "capabilities: deinitGlobalCache clears global cache leak-free under DebugAllocator" {
    var gpa = std.heap.DebugAllocator(.{ .stack_trace_frames = 16 }){};
    const alloc = gpa.allocator();
    {
        const cache = capabilities.getGlobalCache(alloc);
        const id_dup = try alloc.dupe(u8, "model-global");
        try cache.put("model-global", .{
            .id = id_dup,
            .supports_reasoning = true,
            .supported_efforts = &.{},
        });
        capabilities.deinitGlobalCache();
    }
    try std.testing.expectEqual(std.heap.Check.ok, gpa.deinit());
}

test "capabilities: fetchOrLookupCapability handles connection error and cleans up leak-free" {
    var gpa = std.heap.DebugAllocator(.{ .stack_trace_frames = 16 }){};
    const alloc = gpa.allocator();
    {
        const io = std.testing.io;
        // Unreachable port returns null and negative-caches
        const res = capabilities.fetchOrLookupCapability(
            alloc,
            io,
            "http://127.0.0.1:9999/v1",
            "mock-key",
            "Authorization",
            "~test-model-fail",
        );
        try std.testing.expect(res == null);
        capabilities.deinitGlobalCache();
    }
    try std.testing.expectEqual(std.heap.Check.ok, gpa.deinit());
}

