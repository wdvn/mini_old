//! test_js_provider.zig — Integration tests for JS Provider Adapter.

const std = @import("std");
const testing = std.testing;
const mini = @import("mini");
const js_provider = mini.backends.js_provider;

test "js_provider: load JS adapter and extract nested detail.reasoning_content" {
    const alloc = testing.allocator;

    const js_source =
        \\export default {
        \\    name: "Custom Proxy",
        \\    protocol: "chat_completions",
        \\    extractReasoning(chunk) {
        \\        return chunk?.choices?.[0]?.delta?.detail?.reasoning_content || null;
        \\    },
        \\    transformRequest(req) {
        \\        req.custom_injected = "verified";
        \\        return req;
        \\    }
        \\};
    ;

    var adapter = try js_provider.JsProviderAdapter.initFromSource(alloc, js_source);
    defer adapter.deinit();

    try testing.expectEqualStrings("Custom Proxy", adapter.profile.name);
    try testing.expectEqual(mini.backends.provider_mod.WireProtocol.chat_completions, adapter.profile.protocol);

    // Test 1: Extract nested detail.reasoning_content
    const chunk_with_detail =
        \\{"id":"c1","choices":[{"index":0,"delta":{"detail":{"reasoning_content":"Step 1: deduction completed."}}}]}
    ;
    const reasoning = adapter.extractReasoning(alloc, chunk_with_detail);
    try testing.expect(reasoning != null);
    defer alloc.free(reasoning.?);
    try testing.expectEqualStrings("Step 1: deduction completed.", reasoning.?);

    // Test 2: Chunk without reasoning returns null
    const chunk_without_reasoning =
        \\{"id":"c2","choices":[{"index":0,"delta":{"content":"Final answer."}}]}
    ;
    const no_reasoning = adapter.extractReasoning(alloc, chunk_without_reasoning);
    try testing.expect(no_reasoning == null);

    // Test 3: Request transformation hook
    const raw_req =
        \\{"model":"deepseek-chat","messages":[]}
    ;
    const transformed = try adapter.transformRequest(alloc, raw_req);
    defer alloc.free(transformed);
    try testing.expect(std.mem.indexOf(u8, transformed, "\"custom_injected\":\"verified\"") != null);
}

test "js_provider: CommonJS and object returning syntax" {
    const alloc = testing.allocator;

    const js_source =
        \\({
        \\    name: "Object Format Provider",
        \\    protocol: "responses",
        \\    extractReasoning(chunk) {
        \\        return chunk?.choices?.[0]?.delta?.details?.reasoning_content || null;
        \\    }
        \\})
    ;

    var adapter = try js_provider.JsProviderAdapter.initFromSource(alloc, js_source);
    defer adapter.deinit();

    try testing.expectEqualStrings("Object Format Provider", adapter.profile.name);
    try testing.expectEqual(mini.backends.provider_mod.WireProtocol.responses, adapter.profile.protocol);

    const chunk_with_details =
        \\{"choices":[{"delta":{"details":{"reasoning_content":"Thinking with details plural"}}}]}
    ;
    const reasoning = adapter.extractReasoning(alloc, chunk_with_details);
    try testing.expect(reasoning != null);
    defer alloc.free(reasoning.?);
    try testing.expectEqualStrings("Thinking with details plural", reasoning.?);
}

test "js_provider: load from file path providers/agnes.js via initFromSourceWithProfile" {
    const alloc = testing.allocator;
    const path = "providers/agnes.js";

    // Mimics openai.zig's Client.loadAdapter with base profile
    const profile = mini.backends.provider_mod.getProfile("generic");
    var adapter = try js_provider.JsProviderAdapter.initFromSourceWithProfile(alloc, path, profile);
    defer adapter.deinit();

    try testing.expectEqualStrings("Agnes AI", adapter.profile.name);
    try testing.expectEqual(mini.backends.provider_mod.WireProtocol.chat_completions, adapter.profile.protocol);
    try testing.expectEqual(mini.backends.provider_mod.EchoPolicy.drop, adapter.profile.echo_policy);
    try testing.expectEqual(mini.backends.provider_mod.ThinkingTagSet.english_only, adapter.profile.thinking_tags);
    try testing.expectEqual(mini.backends.provider_mod.ReasoningParamFormat.top_level_effort, adapter.profile.reasoning_param);

    // Verify extractReasoning on nested delta.detail.reasoning_content
    const chunk_json =
        \\{"choices":[{"delta":{"detail":{"reasoning_content":"Thinking step via Agnes adapter"}}}]}
    ;
    const reasoning = adapter.extractReasoning(alloc, chunk_json);
    try testing.expect(reasoning != null);
    defer alloc.free(reasoning.?);
    try testing.expectEqualStrings("Thinking step via Agnes adapter", reasoning.?);
}

test "js_provider: leading comments and helper declarations before export default" {
    const alloc = testing.allocator;

    const js_source =
        \\//! Line comment 1
        \\// Line comment 2
        \\/* Block comment */
        \\const PREFIX = "Helper_";
        \\function getPrefix() { return PREFIX; }
        \\
        \\export default {
        \\    name: getPrefix() + "Provider",
        \\    protocol: "responses"
        \\};
    ;

    var adapter = try js_provider.JsProviderAdapter.initFromSource(alloc, js_source);
    defer adapter.deinit();

    try testing.expectEqualStrings("Helper_Provider", adapter.profile.name);
    try testing.expectEqual(mini.backends.provider_mod.WireProtocol.responses, adapter.profile.protocol);
}

test "js_provider: syntax error logs cleanly and returns JsEvaluationFailed" {
    const alloc = testing.allocator;

    const invalid_js =
        \\function broken( { return 123; }
    ;

    const res = js_provider.JsProviderAdapter.initFromSource(alloc, invalid_js);
    try testing.expectError(error.JsEvaluationFailed, res);
}

test "js_provider: non-null-terminated buffer with 0xAA suffix" {
    const alloc = testing.allocator;
    const path = "providers/agnes.js";
    var adapter = try js_provider.JsProviderAdapter.initFromFile(alloc, path);
    defer adapter.deinit();

    const json_str = "{\"choices\":[{\"delta\":{\"detail\":{\"reasoning_content\":\"Hello\"}}}]}";
    var buf: [256]u8 = undefined;
    @memset(&buf, 0xaa);
    @memcpy(buf[0..json_str.len], json_str);
    const non_null_term_slice = buf[0..json_str.len];

    const reasoning = adapter.extractReasoning(alloc, non_null_term_slice);
    try testing.expect(reasoning != null);
    defer alloc.free(reasoning.?);
    try testing.expectEqualStrings("Hello", reasoning.?);
}

test "js_provider: load JSON provider profile as adapter" {
    const alloc = testing.allocator;

    const json_source =
        \\{
        \\    "name": "CustomJSONProvider",
        \\    "protocol": "chat_completions",
        \\    "reasoning_field": "reasoning_content",
        \\    "echo_policy": "drop",
        \\    "thinking_tags": "english_only",
        \\    "reasoning_param": "top_level_effort",
        \\    "supports_stream_options": true,
        \\    "use_completion_tokens": true
        \\}
    ;

    var adapter = try js_provider.JsProviderAdapter.initFromSource(alloc, json_source);
    defer adapter.deinit();

    try testing.expectEqualStrings("CustomJSONProvider", adapter.profile.name);
    try testing.expectEqual(mini.backends.provider_mod.WireProtocol.chat_completions, adapter.profile.protocol);
    try testing.expectEqual(mini.backends.provider_mod.ReasoningField.reasoning_content, adapter.profile.reasoning_field);
    try testing.expectEqual(mini.backends.provider_mod.EchoPolicy.drop, adapter.profile.echo_policy);
    try testing.expectEqual(mini.backends.provider_mod.ThinkingTagSet.english_only, adapter.profile.thinking_tags);
    try testing.expectEqual(mini.backends.provider_mod.ReasoningParamFormat.top_level_effort, adapter.profile.reasoning_param);
    try testing.expect(adapter.profile.supports_stream_options);
    try testing.expect(adapter.profile.use_completion_tokens);
}

test "config: auto-detects $MINI_HOME/providers/<provider>.json" {
    const alloc = testing.allocator;
    const io = mini.getIo();

    // Create temporary directory structure: /tmp/test_mini_home_providers_json/providers/testmodel.json
    const tmp_home = "/tmp/test_mini_home_providers_json";
    const tmp_providers_dir = "/tmp/test_mini_home_providers_json/providers";
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, tmp_providers_dir) catch {};
    defer cwd.deleteTree(io, tmp_home) catch {};

    const json_file_path = "/tmp/test_mini_home_providers_json/providers/testmodel.json";
    const test_json =
        \\{
        \\    "name": "TestModelAI",
        \\    "protocol": "chat_completions",
        \\    "url": "https://api.testmodel.ai/v1",
        \\    "model": "testmodel-v1"
        \\}
    ;
    {
        const f = try cwd.createFile(io, json_file_path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, test_json);
    }

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();

    try env.put("MINI_HOME", tmp_home);
    try env.put("OPENAI_COMPAT_PROVIDER", "testmodel");

    // Call provider config loader directly to avoid .env file interference
    mini.config_mod.loadActiveProviderConfig(alloc, &env, io);

    try testing.expectEqualStrings("https://api.testmodel.ai/v1", env.get("OPENAI_COMPAT_URL").?);
    try testing.expectEqualStrings("testmodel-v1", env.get("OPENAI_COMPAT_MODEL").?);
    try testing.expectEqualStrings("chat_completions", env.get("OPENAI_PROTOCOL").?);
    try testing.expectEqualStrings(json_file_path, env.get("OPENAI_COMPAT_PROVIDER_JS").?);
}


