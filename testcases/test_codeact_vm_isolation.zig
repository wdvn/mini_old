//! Đảm bảo mỗi lần eval() đều có 1 JSContext & JSRuntime mới tinh, không ô nhiễm scope giữa các turn.

const std = @import("std");
const quickjs = @import("mini").quickjs_engine;
const js_bindings = @import("mini").js_bindings;

test "codeact: per-act fresh context isolation (const / let re-declaration across turns)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var engine = try quickjs.Engine.init(alloc, io);
    defer engine.deinit();

    // Turn 1: Khai báo top-level const 'data' và 'lines'
    var res1 = try engine.eval(
        \\const data = "hello world from turn 1";
        \\const lines = data.split(" ");
        \\console.log("turn1 len:", lines.length);
        \\lines.length;
    , "turn1.js");
    defer res1.deinit();

    try std.testing.expect(!res1.is_error);
    try std.testing.expectEqualStrings("turn1 len: 5\n", res1.stdout);

    // Turn 2: Khai báo CÙNG TÊN top-level const 'data' và 'lines' (Bug cũ ném SyntaxError: Identifier 'data' has already been declared)
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

    // Turn 1: Đặt biến var toàn cục
    var res1 = try engine.eval(
        \\var secret_token = 12345;
        \\console.log("set secret_token:", secret_token);
    , "turn1.js");
    defer res1.deinit();
    try std.testing.expect(!res1.is_error);

    // Turn 2: Kiểm tra secret_token không bị rò rỉ sang turn 2
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

    // Turn 1: Gọi mini.exists
    var res1 = try engine.eval("const exists = mini.exists('build.zig'); console.log('exists:', exists);", "turn1.js");
    defer res1.deinit();
    try std.testing.expect(!res1.is_error);
    try std.testing.expectEqualStrings("exists: true\n", res1.stdout);

    // Turn 2: Gọi lại mini.exists trên context mới
    var res2 = try engine.eval("const exists = mini.exists('build.zig'); console.log('exists again:', exists);", "turn2.js");
    defer res2.deinit();
    try std.testing.expect(!res2.is_error);
    try std.testing.expectEqualStrings("exists again: true\n", res2.stdout);
}

