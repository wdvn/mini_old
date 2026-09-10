//! Ensure each eval() gets a fresh JSContext & JSRuntime without cross-turn scope pollution.

const std = @import("std");
const quickjs = @import("mini").quickjs_engine;
const js_bindings = @import("mini").js_bindings;

test "codeact: per-act fresh context isolation (const / let re-declaration across turns)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var engine = try quickjs.Engine.init(alloc, io);
    defer engine.deinit();

    // Turn 1: Declare top-level const 'data' and 'lines'
    var res1 = try engine.eval(
        \\const data = "hello world from turn 1";
        \\const lines = data.split(" ");
        \\console.log("turn1 len:", lines.length);
        \\lines.length;
    , "turn1.js");
    defer res1.deinit();

    try std.testing.expect(!res1.is_error);
    try std.testing.expectEqualStrings("turn1 len: 5\n", res1.stdout);

    // Turn 2: Declare SAME top-level const 'data' and 'lines' (Old bug threw SyntaxError: Identifier 'data' has already been declared)
    var res2 = try engine.eval(
        \\const data = "hello again from turn 2";
        \\const lines = data.split(" ");
        \\console.log("turn2 len:", lines.length);
        \\lines.length;
    , "turn2.js");
    defer res2.deinit();

    try std.testing.expect(!res2.is_error);
    try std.testing.expectEqualStrings("turn2 len: 5\n", res2.stdout);
}

test "codeact: global variable state wipeout across turns" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var engine = try quickjs.Engine.init(alloc, io);
    defer engine.deinit();

    // Turn 1: Set global var
    var res1 = try engine.eval(
        \\var secret_token = 12345;
        \\console.log("set secret_token:", secret_token);
    , "turn1.js");
    defer res1.deinit();
    try std.testing.expect(!res1.is_error);

    // Turn 2: Verify secret_token does not leak into turn 2
    var res2 = try engine.eval(
        \\console.log("typeof secret_token:", typeof secret_token);
        \\typeof secret_token;
    , "turn2.js");
    defer res2.deinit();
    try std.testing.expect(!res2.is_error);
    try std.testing.expectEqualStrings("typeof secret_token: undefined\n", res2.stdout);
}

test "codeact: mini bindings available on fresh context" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var engine = try quickjs.Engine.init(alloc, io);
    defer engine.deinit();

    // Turn 1: Call mini.exists
    var res1 = try engine.eval("const exists = mini.exists('build.zig'); console.log('exists:', exists);", "turn1.js");
    defer res1.deinit();
    try std.testing.expect(!res1.is_error);
    try std.testing.expectEqualStrings("exists: true\n", res1.stdout);

    // Turn 2: Call mini.exists again on fresh context
    var res2 = try engine.eval("const exists = mini.exists('build.zig'); console.log('exists again:', exists);", "turn2.js");
    defer res2.deinit();
    try std.testing.expect(!res2.is_error);
    try std.testing.expectEqualStrings("exists again: true\n", res2.stdout);
}

test "codeact: mini.setThinking sets pending override" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var engine = try quickjs.Engine.init(alloc, io);
    defer engine.deinit();

    // 1. String level: "low"
    var res1 = try engine.eval("mini.setThinking('low');", "test1.js");
    defer res1.deinit();
    try std.testing.expect(!res1.is_error);

    const override1 = js_bindings.consumePendingThinkingOverride();
    try std.testing.expect(override1 != null);
    try std.testing.expectEqualStrings("low", override1.?.effort.?);

    // After consume, pending override is reset to null
    try std.testing.expect(js_bindings.consumePendingThinkingOverride() == null);

    // 2. Budget tokens number: 4096
    var res2 = try engine.eval("mini.setThinking(4096);", "test2.js");
    defer res2.deinit();
    try std.testing.expect(!res2.is_error);

    const override2 = js_bindings.consumePendingThinkingOverride();
    try std.testing.expect(override2 != null);
    try std.testing.expectEqual(@as(u32, 4096), override2.?.budget_tokens.?);

    // 3. String level: "none"
    var res3 = try engine.eval("mini.setThinking('none');", "test3.js");
    defer res3.deinit();
    try std.testing.expect(!res3.is_error);

    const override3 = js_bindings.consumePendingThinkingOverride();
    try std.testing.expect(override3 != null);
    try std.testing.expectEqualStrings("none", override3.?.effort.?);
}

