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
