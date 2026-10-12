//! test_provider_profiles.zig — Integration tests for Provider Abstraction Layer.
//!
//! Validates:
//!   1. ProviderProfile lookup and fallback to generic.
//!   2. URL auto-detection across DeepSeek, Qwen, MiniMax, GLM, Moonshot/Kimi, xAI, OpenAI, etc.
//!   3. Request body normalization:
//!      - DeepSeek: omits reasoning_effort, echoes reasoning_content in assistant history.
//!      - OpenAI: formats reasoning_effort, drops reasoning_content from history.
//!      - xAI / nested reasoning object formatting.
//!   4. Chinese & English thinking tag normalization in StreamEventParser:
//!      - <think>, <思考>, <推理>, <反思>, <推敲>
//!      - Multi-byte chunk split handling.

const std = @import("std");
const testing = std.testing;
const mini = @import("mini");
const provider = mini.backends.provider_mod;
const openai = mini.backends.openai_mod;
const proto = mini.protocol_mod;
const chat_stream = mini.ui_chat_stream;

test "provider: profile registry lookup and default fallback" {
    // OpenAI
    const p_openai = provider.getProfile("openai");
    try testing.expectEqualStrings("OpenAI", p_openai.name);
    try testing.expectEqual(provider.WireProtocol.auto, p_openai.protocol);
    try testing.expectEqual(provider.EchoPolicy.drop, p_openai.echo_policy);
    try testing.expectEqual(provider.ReasoningParamFormat.top_level_effort, p_openai.reasoning_param);
    try testing.expect(p_openai.supports_stream_options);
    try testing.expect(p_openai.use_completion_tokens);

    // DeepSeek
    const p_deepseek = provider.getProfile("deepseek");
    try testing.expectEqualStrings("DeepSeek", p_deepseek.name);
    try testing.expectEqual(provider.WireProtocol.chat_completions, p_deepseek.protocol);
    try testing.expectEqual(provider.ReasoningField.reasoning_content, p_deepseek.reasoning_field);
    try testing.expectEqual(provider.EchoPolicy.echo_required, p_deepseek.echo_policy);
    try testing.expectEqual(provider.ReasoningParamFormat.unsupported, p_deepseek.reasoning_param);
    try testing.expect(!p_deepseek.use_completion_tokens);

    // Qwen
    const p_qwen = provider.getProfile("qwen");
    try testing.expectEqual(provider.WireProtocol.chat_completions, p_qwen.protocol);
    try testing.expectEqual(provider.ThinkingTagSet.english_and_chinese, p_qwen.thinking_tags);

    // MiniMax
    const p_minimax = provider.getProfile("minimax");
    try testing.expectEqual(provider.WireProtocol.chat_completions, p_minimax.protocol);
    try testing.expect(!p_minimax.supports_stream_options);
    try testing.expectEqual(provider.ReasoningParamFormat.unsupported, p_minimax.reasoning_param);

    // GLM
    const p_glm = provider.getProfile("glm");
    try testing.expectEqual(provider.WireProtocol.chat_completions, p_glm.protocol);
    try testing.expect(!p_glm.supports_stream_options);

    // Kimi
    const p_kimi = provider.getProfile("kimi");
    try testing.expectEqual(provider.WireProtocol.chat_completions, p_kimi.protocol);

    // xAI
    const p_xai = provider.getProfile("xai");
    try testing.expectEqual(provider.WireProtocol.responses, p_xai.protocol);
    try testing.expectEqual(provider.ReasoningParamFormat.nested_reasoning_object, p_xai.reasoning_param);

    // vLLM
    const p_vllm = provider.getProfile("vllm");
    try testing.expectEqual(provider.WireProtocol.chat_completions, p_vllm.protocol);

    // Fallback unknown -> generic
    const p_unknown = provider.getProfile("some_non_existent_provider");
    try testing.expectEqualStrings("Generic OpenAI-compat", p_unknown.name);
    try testing.expectEqual(provider.WireProtocol.auto, p_unknown.protocol);
}

test "provider: detectFromUrl accurately classifies vendor endpoints" {
    try testing.expectEqualStrings("deepseek", provider.detectFromUrl("https://api.deepseek.com/v1"));
    try testing.expectEqualStrings("deepseek", provider.detectFromUrl("https://api.deepseek.com/chat/completions"));

    try testing.expectEqualStrings("qwen", provider.detectFromUrl("https://dashscope.aliyuncs.com/compatible-mode/v1"));
    try testing.expectEqualStrings("qwen", provider.detectFromUrl("https://qwen.aliyun.com/v1"));

    try testing.expectEqualStrings("minimax", provider.detectFromUrl("https://api.minimax.chat/v1"));
    try testing.expectEqualStrings("minimax", provider.detectFromUrl("https://api.minimaxi.com/v1"));

    try testing.expectEqualStrings("glm", provider.detectFromUrl("https://open.bigmodel.cn/api/paas/v4"));
    try testing.expectEqualStrings("glm", provider.detectFromUrl("https://api.zhipuai.cn/v1"));

    try testing.expectEqualStrings("kimi", provider.detectFromUrl("https://api.moonshot.cn/v1"));
    try testing.expectEqualStrings("kimi", provider.detectFromUrl("https://api.kimi.ai/v1"));

    try testing.expectEqualStrings("xai", provider.detectFromUrl("https://api.x.ai/v1"));
    try testing.expectEqualStrings("xai", provider.detectFromUrl("https://grok.x.ai/v1"));

    try testing.expectEqualStrings("openai", provider.detectFromUrl("https://api.openai.com/v1"));

    try testing.expectEqualStrings("vllm", provider.detectFromUrl("http://vllm-node:8000/v1"));

    try testing.expectEqualStrings("generic", provider.detectFromUrl("http://localhost:11434/v1"));
    try testing.expectEqualStrings("generic", provider.detectFromUrl("https://custom-gateway.local/v1"));
}

test "provider: resolveProfile prioritizes explicit key over URL" {
    // Explicit non-empty key always wins, even over a vendor URL
    const p1 = provider.resolveProfile("deepseek", "https://api.openai.com/v1");
    try testing.expectEqualStrings("DeepSeek", p1.name);

    // Explicit "generic" is also a non-empty key -> wins over URL detection
    const p2 = provider.resolveProfile("generic", "https://api.deepseek.com/v1");
    try testing.expectEqualStrings("Generic OpenAI-compat", p2.name);

    // null explicit key -> auto-detect from URL
    const p3 = provider.resolveProfile(null, "https://open.bigmodel.cn/api/paas/v4");
    try testing.expectEqualStrings("GLM / ZhipuAI", p3.name);

    // Empty explicit key -> treated as unset, auto-detect from URL
    const p3b = provider.resolveProfile("", "https://api.deepseek.com/v1");
    try testing.expectEqualStrings("DeepSeek", p3b.name);

    // No key and no URL -> generic
    const p4 = provider.resolveProfile(null, null);
    try testing.expectEqualStrings("Generic OpenAI-compat", p4.name);
}

test "provider: modular provider modules match URLs and expose distinct profiles" {
    try testing.expectEqualStrings("deepseek", provider.providers.deepseek.key);
    try testing.expect(provider.providers.deepseek.matchesUrl("https://api.deepseek.com/v1"));
    try testing.expect(!provider.providers.deepseek.matchesUrl("https://api.openai.com/v1"));

    try testing.expectEqualStrings("openai", provider.providers.openai.key);
    try testing.expect(provider.providers.openai.matchesUrl("https://api.openai.com/v1"));

    try testing.expectEqualStrings("qwen", provider.providers.qwen.key);
    try testing.expect(provider.providers.qwen.matchesUrl("https://dashscope.aliyuncs.com"));

    try testing.expectEqualStrings("minimax", provider.providers.minimax.key);
    try testing.expect(provider.providers.minimax.matchesUrl("https://api.minimax.chat"));

    try testing.expectEqualStrings("glm", provider.providers.glm.key);
    try testing.expect(provider.providers.glm.matchesUrl("https://open.bigmodel.cn"));

    try testing.expectEqualStrings("kimi", provider.providers.kimi.key);
    try testing.expect(provider.providers.kimi.matchesUrl("https://api.moonshot.cn"));

    try testing.expectEqualStrings("xai", provider.providers.xai.key);
    try testing.expect(provider.providers.xai.matchesUrl("https://api.x.ai"));

    try testing.expectEqualStrings("vllm", provider.providers.vllm.key);
    try testing.expect(provider.providers.vllm.matchesUrl("http://vllm-host:8000"));

    try testing.expectEqualStrings("generic", provider.providers.generic.key);
    try testing.expect(!provider.providers.generic.matchesUrl("http://any-url"));
}

test "provider: DeepSeek request body omits reasoning_effort and echoes reasoning_content" {
    const alloc = testing.allocator;
    const profile = provider.getProfile("deepseek");

    // Create a multi-turn history with assistant thinking block
    var msgs: std.ArrayListUnmanaged(proto.Message) = .empty;
    defer msgs.deinit(alloc);

    // Turn 1: User message
    const u1_blocks = try alloc.alloc(proto.ContentBlock, 1);
    defer alloc.free(u1_blocks);
    u1_blocks[0] = .{ .text = "Solve this puzzle" };
    try msgs.append(alloc, .{ .role = .user, .content = u1_blocks });

    // Turn 2: Assistant message with thinking and text
    const a1_blocks = try alloc.alloc(proto.ContentBlock, 2);
    defer alloc.free(a1_blocks);
    a1_blocks[0] = .{ .thinking = .{ .thinking = "Step 1: analyze conditions. Step 2: verify constraints.", .signature = "" } };
    a1_blocks[1] = .{ .text = "The solution is 42." };
    try msgs.append(alloc, .{ .role = .assistant, .content = a1_blocks });

    // Turn 3: User follow-up
    const u2_blocks = try alloc.alloc(proto.ContentBlock, 1);
    defer alloc.free(u2_blocks);
    u2_blocks[0] = .{ .text = "Are you sure?" };
    try msgs.append(alloc, .{ .role = .user, .content = u2_blocks });

    const tools = [_]proto.ToolDefinition{};

    const body = try openai.buildRequestBodyWithProfile(
        alloc,
        profile,
        "deepseek-reasoner",
        4096,
        false,
        false, // disable_reasoning_effort
        "medium", // reasoning_effort requested, but profile should omit it!
        null, // reasoning_max_tokens
        false,
        "System prompt",
        msgs.items,
        &tools,
    );
    defer alloc.free(body);

    // 1. Verify reasoning_effort is completely omitted because DeepSeek profile has .unsupported
    try testing.expect(std.mem.indexOf(u8, body, "reasoning_effort") == null);

    // 2. Verify reasoning_content is echoed back in the assistant message
    try testing.expect(std.mem.indexOf(u8, body, "\"reasoning_content\":\"Step 1: analyze conditions. Step 2: verify constraints.\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"content\":\"The solution is 42.\"") != null);
}

test "provider: OpenAI request body emits reasoning_effort and drops reasoning_content" {
    const alloc = testing.allocator;
    const profile = provider.getProfile("openai");

    var msgs: std.ArrayListUnmanaged(proto.Message) = .empty;
    defer msgs.deinit(alloc);

    const a1_blocks = try alloc.alloc(proto.ContentBlock, 2);
    defer alloc.free(a1_blocks);
    a1_blocks[0] = .{ .thinking = .{ .thinking = "Private OpenAI internal thought", .signature = "" } };
    a1_blocks[1] = .{ .text = "Public answer" };
    try msgs.append(alloc, .{ .role = .assistant, .content = a1_blocks });

    const tools = [_]proto.ToolDefinition{};

    const body = try openai.buildRequestBodyWithProfile(
        alloc,
        profile,
        "o3-mini",
        2048,
        true, // use_completion_tokens
        false,
        "high",
        null, // reasoning_max_tokens
        false,
        "",
        msgs.items,
        &tools,
    );
    defer alloc.free(body);

    // 1. Verify reasoning_effort is emitted
    try testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"high\"") != null);

    // 2. Verify reasoning_content is NOT echoed (OpenAI drops it)
    try testing.expect(std.mem.indexOf(u8, body, "reasoning_content") == null);
    try testing.expect(std.mem.indexOf(u8, body, "\"content\":\"Public answer\"") != null);

    // 3. Verify max_completion_tokens is used
    try testing.expect(std.mem.indexOf(u8, body, "\"max_completion_tokens\":2048") != null);
}

test "provider: xAI request body formats nested reasoning object" {
    const alloc = testing.allocator;
    const profile = provider.getProfile("xai");
    const msgs = [_]proto.Message{};
    const tools = [_]proto.ToolDefinition{};

    const body = try openai.buildRequestBodyWithProfile(
        alloc,
        profile,
        "grok-beta",
        4096,
        false,
        false,
        "medium",
        null, // reasoning_max_tokens
        false,
        "",
        &msgs,
        &tools,
    );
    defer alloc.free(body);

    // Nested object format: "reasoning":{"effort":"medium"}
    try testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":{\"effort\":\"medium\"}") != null);
}

test "provider: Qwen request body emits reasoning_effort and uses max_tokens" {
    const alloc = testing.allocator;
    const profile = provider.getProfile("qwen");

    var msgs: std.ArrayListUnmanaged(proto.Message) = .empty;
    defer msgs.deinit(alloc);

    const a1_blocks = try alloc.alloc(proto.ContentBlock, 2);
    defer alloc.free(a1_blocks);
    a1_blocks[0] = .{ .thinking = .{ .thinking = "Qwen internal thought", .signature = "" } };
    a1_blocks[1] = .{ .text = "Qwen public answer" };
    try msgs.append(alloc, .{ .role = .assistant, .content = a1_blocks });

    const tools = [_]proto.ToolDefinition{};

    const body = try openai.buildRequestBodyWithProfile(
        alloc,
        profile,
        "qwen-max",
        4096,
        false, // use_completion_tokens (profile also has false)
        false,
        "medium",
        null, // reasoning_max_tokens
        false,
        "",
        msgs.items,
        &tools,
    );
    defer alloc.free(body);

    // 1. Qwen profile has .top_level_effort -> reasoning_effort is emitted
    try testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"medium\"") != null);

    // 2. echo_policy = drop -> reasoning_content is NOT echoed back
    try testing.expect(std.mem.indexOf(u8, body, "reasoning_content") == null);
    try testing.expect(std.mem.indexOf(u8, body, "\"content\":\"Qwen public answer\"") != null);

    // 3. use_completion_tokens = false -> max_tokens is used, NOT max_completion_tokens
    try testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":4096") != null);
    try testing.expect(std.mem.indexOf(u8, body, "max_completion_tokens") == null);
}

// ---------------------------------------------------------------------------
// Thinking Tag Parsing Tests (Chinese & English)
// ---------------------------------------------------------------------------

const EventCollector = struct {
    alloc: std.mem.Allocator,
    events: std.ArrayListUnmanaged([]const u8),
    think_text: std.ArrayListUnmanaged(u8),
    regular_text: std.ArrayListUnmanaged(u8),

    fn init(alloc: std.mem.Allocator) EventCollector {
        return .{
            .alloc = alloc,
            .events = .empty,
            .think_text = .empty,
            .regular_text = .empty,
        };
    }

    fn deinit(self: *EventCollector) void {
        for (self.events.items) |item| {
            self.alloc.free(item);
        }
        self.events.deinit(self.alloc);
        self.think_text.deinit(self.alloc);
        self.regular_text.deinit(self.alloc);
    }

    fn onEvent(self: *EventCollector, event: chat_stream.StreamEvent) void {
        switch (event) {
            .think_start => {
                const s = self.alloc.dupe(u8, "THINK_START") catch return;
                self.events.append(self.alloc, s) catch return;
            },
            .think_chunk => |c| {
                self.think_text.appendSlice(self.alloc, c) catch return;
            },
            .think_end => {
                const s = self.alloc.dupe(u8, "THINK_END") catch return;
                self.events.append(self.alloc, s) catch return;
            },
            .text_start => {
                const s = self.alloc.dupe(u8, "TEXT_START") catch return;
                self.events.append(self.alloc, s) catch return;
            },
            .text_chunk => |c| {
                self.regular_text.appendSlice(self.alloc, c) catch return;
            },
            .text_end => {
                const s = self.alloc.dupe(u8, "TEXT_END") catch return;
                self.events.append(self.alloc, s) catch return;
            },
            else => {},
        }
    }
};

test "StreamEventParser: parses Chinese <思考> thinking tags correctly" {
    const alloc = testing.allocator;
    var collector = EventCollector.init(alloc);
    defer collector.deinit();

    var parser = chat_stream.StreamEventParser.init();

    const input = "<思考>正在分析用户的问题，步骤一、步骤二。</思考>您好！这是最终的回答。";
    parser.feed(input, &collector, EventCollector.onEvent);

    try testing.expectEqualStrings("正在分析用户的问题，步骤一、步骤二。", collector.think_text.items);
    try testing.expectEqualStrings("您好！这是最终的回答。", collector.regular_text.items);
}

test "StreamEventParser: parses Chinese <推理> and <反思> thinking tags correctly" {
    const alloc = testing.allocator;

    // Test <推理>
    {
        var col = EventCollector.init(alloc);
        defer col.deinit();
        var parser = chat_stream.StreamEventParser.init();
        parser.feed("<推理>Logic deduction</推理>Final result: 100", &col, EventCollector.onEvent);

        try testing.expectEqualStrings("Logic deduction", col.think_text.items);
        try testing.expectEqualStrings("Final result: 100", col.regular_text.items);
    }

    // Test <反思>
    {
        var col = EventCollector.init(alloc);
        defer col.deinit();
        var parser = chat_stream.StreamEventParser.init();
        parser.feed("<反思>Self correction</反思>Better answer", &col, EventCollector.onEvent);

        try testing.expectEqualStrings("Self correction", col.think_text.items);
        try testing.expectEqualStrings("Better answer", col.regular_text.items);
    }
}

test "StreamEventParser: handles multi-byte chunk split across Chinese thinking tags" {
    const alloc = testing.allocator;
    var collector = EventCollector.init(alloc);
    defer collector.deinit();

    var parser = chat_stream.StreamEventParser.init();

    // UTF-8 bytes:
    // "<" (0x3C)
    // "思" (0xE6, 0x80, 0x9D)
    // "考" (0xE8, 0x80, 0x83)
    // ">" (0x3E)
    // Split right inside the tag!
    parser.feed("<思", &collector, EventCollector.onEvent);
    parser.feed("考>Deep thought in chunks</思", &collector, EventCollector.onEvent);
    parser.feed("考>Visible response", &collector, EventCollector.onEvent);

    try testing.expectEqualStrings("Deep thought in chunks", collector.think_text.items);
    try testing.expectEqualStrings("Visible response", collector.regular_text.items);
}

test "StreamEventParser: parses Chinese <推敲> thinking tag" {
    const alloc = testing.allocator;
    var collector = EventCollector.init(alloc);
    defer collector.deinit();

    var parser = chat_stream.StreamEventParser.init();

    const input = "<推敲>Weighing each word carefully.</推敲>Here is the polished answer.";
    parser.feed(input, &collector, EventCollector.onEvent);

    try testing.expectEqualStrings("Weighing each word carefully.", collector.think_text.items);
    try testing.expectEqualStrings("Here is the polished answer.", collector.regular_text.items);
}

test "StreamEventParser: reasoning-only stream without text" {
    const alloc = testing.allocator;

    // Case 1: full reasoning-only stream (no regular text at all)
    {
        var col = EventCollector.init(alloc);
        defer col.deinit();
        var parser = chat_stream.StreamEventParser.init();

        parser.feed("<思考>Only reasoning, no visible answer.</思考>", &col, EventCollector.onEvent);

        try testing.expectEqualStrings("Only reasoning, no visible answer.", col.think_text.items);
        try testing.expectEqualStrings("", col.regular_text.items);
    }

    // Case 2: unclosed tag — must not crash and must not leak into regular_text
    {
        var col = EventCollector.init(alloc);
        defer col.deinit();
        var parser = chat_stream.StreamEventParser.init();

        parser.feed("<推理>unfinished without a close tag", &col, EventCollector.onEvent);

        try testing.expectEqualStrings("unfinished without a close tag", col.think_text.items);
        try testing.expectEqualStrings("", col.regular_text.items);
    }
}

test "StreamEventParser: english_only set ignores Chinese tags" {
    const alloc = testing.allocator;
    var collector = EventCollector.init(alloc);
    defer collector.deinit();

    var parser = chat_stream.StreamEventParser.initWithTags(.english_only);

    parser.feed("<思考>x</思考>hello", &collector, EventCollector.onEvent);

    // Chinese tags are not recognized: everything flows through as regular text
    try testing.expectEqualStrings("", collector.think_text.items);
    try testing.expectEqualStrings("<思考>x</思考>hello", collector.regular_text.items);
}

test "StreamEventParser: none set passes everything as text" {
    const alloc = testing.allocator;
    var collector = EventCollector.init(alloc);
    defer collector.deinit();

    var parser = chat_stream.StreamEventParser.initWithTags(.none);

    parser.feed("<think>y</think>z", &collector, EventCollector.onEvent);

    // Tag parsing disabled: '<' bytes flow straight through as plain text
    try testing.expectEqualStrings("", collector.think_text.items);
    try testing.expectEqualStrings("<think>y</think>z", collector.regular_text.items);
}
