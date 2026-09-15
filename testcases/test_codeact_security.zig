//! test_codeact_security.zig — Integration test ISSUE-CODEACT-001 (M10).
//!
//! Validates inside CodeAct environment (CodeAct VM):
//!   1. MINI_TOOL_BLOCKLIST / MINI_TOOL_ALLOWLIST enforced at C-bindings mini.* (M2)
//!   2. Hook Dispatcher fires pre-tool-use / post-tool-use for mini.*, including when blocked (M3)
//!   3. Per-Act VM Isolation — global variables do not leak across 2 eval turns (M1)
//!
//! Run via `zig build test` — imports "mini" module (rooted at src/main.zig).

const std = @import("std");
const mini = @import("mini");
const quickjs = mini.quickjs_engine;
const registry = mini.tools_mod;
const hooks = mini.hooks_mod;

// Bundle other CodeAct test cases into the same test binary
test {
    _ = @import("test_codeact_as_tool.zig");
    _ = @import("test_codeact_vm_isolation.zig");
    _ = @import("test_ui_chat_stream.zig");
    _ = @import("test_signals.zig");
    _ = @import("test_openai_dual_protocol.zig");
    _ = @import("test_act_logger.zig");
    _ = @import("test_backend_error_inplace.zig");
    _ = @import("test_session_diagnostics.zig");
    _ = @import("test_procedural_graph.zig");
    _ = @import("test_dynamic_thinking.zig");
    _ = @import("test_media_ingest.zig");
    _ = @import("test_media_gen.zig");
    _ = @import("test_provider_profiles.zig");
    _ = @import("test_js_provider.zig");
}

// ---------------------------------------------------------------------------
// In-memory event counter hook listener (M3)
// ---------------------------------------------------------------------------
const HookCounter = struct {
    var pre_count: usize = 0;
    var post_ok_count: usize = 0;
    var post_err_count: usize = 0;

    fn reset() void {
        pre_count = 0;
        post_ok_count = 0;
        post_err_count = 0;
    }

    fn listener(payload: hooks.HookPayload) void {
        if (std.mem.eql(u8, payload.event, "pre-tool-use")) {
            pre_count += 1;
        } else if (std.mem.eql(u8, payload.event, "post-tool-use")) {
            if (payload.is_error) {
                post_err_count += 1;
            } else {
                post_ok_count += 1;
            }
        }
    }
};

// ---------------------------------------------------------------------------
// M2: Blocklist — C-bindings mini.* must enforce policy
// ---------------------------------------------------------------------------
test "security: blocklist blocks mini.sh (mapped to tool bash)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    registry.setPolicy(null, "bash");
    defer registry.setPolicy(null, null);

    var engine = try quickjs.Engine.init(alloc, io);
    defer engine.deinit();

    var res = try engine.eval(
\\ const out = mini.sh("echo should-not-run");
\\ out.stdout;
    , "blk_sh.js");
    defer res.deinit();

    try std.testing.expect(res.is_error);
    try std.testing.expect(res.error_message != null);
    try std.testing.expect(std.mem.indexOf(u8, res.error_message.?, "Security Policy Error") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.error_message.?, "bash") != null);
}

test "security: blocklist blocks mini.write (mapped to tool file_write) — file not created" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const target = "/tmp/mini_codeact_sec_blocked.txt";

    registry.setPolicy(null, "file_write");
    defer registry.setPolicy(null, null);

    var engine = try quickjs.Engine.init(alloc, io);
    defer engine.deinit();

    var res = try engine.eval(
\\ const r = mini.write("/tmp/mini_codeact_sec_blocked.txt", "nope");
\\ r.ok;
    , "blk_write.js");
    defer res.deinit();

    try std.testing.expect(res.is_error);
    try std.testing.expect(res.error_message != null);
    try std.testing.expect(std.mem.indexOf(u8, res.error_message.?, "Security Policy Error") != null);

    // File MUST NOT exist after block
    const cwd = std.Io.Dir.cwd();
    const exists = if (cwd.statFile(io, target, .{})) |_| true else |_| false;
    try std.testing.expect(!exists);
}

test "security: blocklist blocks mini.http (mapped to tool http_request) — no request dispatched" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    registry.setPolicy(null, "http_request");
    defer registry.setPolicy(null, null);

    var engine = try quickjs.Engine.init(alloc, io);
    defer engine.deinit();

    var res = try engine.eval(
\\ const r = mini.http("GET", "http://127.0.0.1:1/");
\\ r.status;
    , "blk_http.js");
    defer res.deinit();

    try std.testing.expect(res.is_error);
    try std.testing.expect(res.error_message != null);
    try std.testing.expect(std.mem.indexOf(u8, res.error_message.?, "Security Policy Error") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.error_message.?, "http_request") != null);
}

// ---------------------------------------------------------------------------
// M2: Allowlist (takes precedence over blocklist)
// ---------------------------------------------------------------------------
test "security: allowlist only permits specified tools — mini.read OK, mini.sh blocked" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    registry.setPolicy("file_read,glob", null);
    defer registry.setPolicy(null, null);

    var engine = try quickjs.Engine.init(alloc, io);
    defer engine.deinit();

    // file_read is in allowlist → mini.read succeeds
    var res_ok = try engine.eval(
\\ const content = mini.read("build.zig");
\\ console.log("read_len:", content.length > 0);
\\ content.length > 0;
    , "allow_read.js");
    defer res_ok.deinit();
    try std.testing.expect(!res_ok.is_error);
    try std.testing.expect(std.mem.indexOf(u8, res_ok.stdout, "read_len: true") != null);

    // bash is NOT in allowlist → mini.sh blocked
    var res_blk = try engine.eval(
\\ const out = mini.sh("echo nope");
\\ out;
    , "allow_sh.js");
    defer res_blk.deinit();
    try std.testing.expect(res_blk.is_error);
    try std.testing.expect(std.mem.indexOf(u8, res_blk.error_message.?, "Security Policy Error") != null);
}

// ---------------------------------------------------------------------------
// M3: Hook Dispatcher
// ---------------------------------------------------------------------------
test "security: hook dispatcher dispatches pre/post-tool-use for mini.sh successfully" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    registry.setPolicy(null, null);
    defer registry.setPolicy(null, null);

    HookCounter.reset();
    hooks.setHookListener(HookCounter.listener);
    defer hooks.setHookListener(null);

    var engine = try quickjs.Engine.init(alloc, io);
    defer engine.deinit();

    var res = try engine.eval(
\\ const out = mini.sh("echo hook-test-marker");
\\ console.log("ok:", out.ok);
\\ out.ok;
    , "hook_ok.js");
    defer res.deinit();

    try std.testing.expect(!res.is_error);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "ok: true") != null);
    try std.testing.expect(HookCounter.pre_count >= 1);
    try std.testing.expect(HookCounter.post_ok_count >= 1);
}

test "security: hook dispatcher dispatches post-tool-use is_error when mini.sh is blocked" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    registry.setPolicy(null, "bash");
    defer registry.setPolicy(null, null);

    HookCounter.reset();
    hooks.setHookListener(HookCounter.listener);
    defer hooks.setHookListener(null);

    var engine = try quickjs.Engine.init(alloc, io);
    defer engine.deinit();

    var res = try engine.eval(
\\ mini.sh("echo blocked-marker");
    , "hook_blk.js");
    defer res.deinit();

    try std.testing.expect(res.is_error);
    // Blocked at policy check → no pre-hook, only post-tool-use is_error
    try std.testing.expectEqual(@as(usize, 0), HookCounter.pre_count);
    try std.testing.expectEqual(@as(usize, 1), HookCounter.post_err_count);
}

test "security: hook dispatcher dispatches pre/post-tool-use for mini.write" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const target = "/tmp/mini_codeact_sec_hook.txt";
    const cwd = std.Io.Dir.cwd();
    cwd.deleteFile(io, target) catch {};

    registry.setPolicy(null, null);
    defer registry.setPolicy(null, null);

    HookCounter.reset();
    hooks.setHookListener(HookCounter.listener);
    defer hooks.setHookListener(null);

    var engine = try quickjs.Engine.init(alloc, io);
    defer engine.deinit();

    var res = try engine.eval(
\\ const r = mini.write("/tmp/mini_codeact_sec_hook.txt", "hooked");
\\ console.log("write ok:", r.ok);
\\ r.ok;
    , "hook_write.js");
    defer res.deinit();

    try std.testing.expect(!res.is_error);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "write ok: true") != null);
    try std.testing.expect(HookCounter.pre_count >= 1);
    try std.testing.expect(HookCounter.post_ok_count >= 1);

    cwd.deleteFile(io, target) catch {};
}

// ---------------------------------------------------------------------------
// M1: Per-Act VM Isolation (complements test_codeact_vm_isolation.zig)
// ---------------------------------------------------------------------------
test "security: per-act VM isolation — global variables do not leak across 2 eval turns" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var engine = try quickjs.Engine.init(alloc, io);
    defer engine.deinit();

    var res1 = try engine.eval(
\\ var leak = "turn1";
\\ console.log("set:", leak);
    , "iso1.js");
    defer res1.deinit();
    try std.testing.expect(!res1.is_error);
    try std.testing.expectEqualStrings("set: turn1", std.mem.trim(u8, res1.stdout, "\n"));

    var res2 = try engine.eval(
\\ console.log("leaked:", typeof leak);
\\ typeof leak;
    , "iso2.js");
    defer res2.deinit();
    try std.testing.expect(!res2.is_error);
    try std.testing.expectEqualStrings("leaked: undefined", std.mem.trim(u8, res2.stdout, "\n"));
}
