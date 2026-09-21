//! testcases/test_media_gen.zig — Integration tests for RFC-011 Media Generation & Vision Loop-Back.
//!
//! Validates:
//!   1. Filename sanitization & path traversal mitigation (RFC-011 §3.2)
//!   2. Tool capability gates (opt-in via image_gen_enabled / video_gen_enabled)
//!   3. image_attach loop-back vision tool
//!   4. mini.media JS bindings in QuickJS CodeAct VM
//!   5. media_saved hook event dispatch

const std = @import("std");
const testing = std.testing;
const mini = @import("mini");
const registry = mini.tools_mod;
const media_gen_tool = mini.media_gen_tool;
const hooks = mini.hooks_mod;
const quickjs = mini.quickjs_engine;
const js_bindings = mini.js_bindings;

test "media_gen: sanitizeFilename neutralizes path traversal and illegal chars" {
    const alloc = testing.allocator;

    // 1. Simple path traversal
    const safe1 = try media_gen_tool.sanitizeFilename(alloc, "../../etc/shadow.png");
    defer alloc.free(safe1);
    try testing.expectEqualStrings("etcshadow.png", safe1);

    // 2. Windows-style backslashes and tricky dot sequences
    const safe2 = try media_gen_tool.sanitizeFilename(alloc, "..\\..\\evil_script..jpg");
    defer alloc.free(safe2);
    try testing.expectEqualStrings("evil_script.jpg", safe2);

    // 3. Excessive length (> 64 chars)
    const long_name = "a_very_long_filename_that_exceeds_sixty_four_characters_limit_to_prevent_buffer_overflow.png";
    const safe3 = try media_gen_tool.sanitizeFilename(alloc, long_name);
    defer alloc.free(safe3);
    try testing.expect(safe3.len <= 64);
    try testing.expect(std.mem.startsWith(u8, safe3, "a_very_long_filename"));

    // 4. Empty or only invalid characters
    const safe4 = try media_gen_tool.sanitizeFilename(alloc, "///???###$$$");
    defer alloc.free(safe4);
    try testing.expectEqualStrings("generated_media", safe4);
}

test "media_gen: capability gates in registry.isPermitted" {
    // Reset policy
    registry.setPolicy(null, null);

    // 1. Default: generation tools are disabled, ingestion tool is enabled
    registry.setMediaConfig(false, false, true);
    try testing.expect(!registry.isPermitted("generate_image"));
    try testing.expect(!registry.isPermitted("generate_video"));
    try testing.expect(registry.isPermitted("image_attach"));

    // 2. Enable image gen
    registry.setMediaConfig(true, false, true);
    try testing.expect(registry.isPermitted("generate_image"));
    try testing.expect(!registry.isPermitted("generate_video"));

    // 3. Enable video gen
    registry.setMediaConfig(true, true, true);
    try testing.expect(registry.isPermitted("generate_image"));
    try testing.expect(registry.isPermitted("generate_video"));

    // 4. Disable image input
    registry.setMediaConfig(true, true, false);
    try testing.expect(!registry.isPermitted("image_attach"));

    // Reset back to defaults
    registry.setMediaConfig(false, false, true);
}

test "media_gen: image_attach attaches image for turn and clearTurnAttachments resets" {
    const alloc = testing.allocator;
    const cwd = std.Io.Dir.cwd();
    const test_dir = "zig-cache/tmp_test_media_gen";
    cwd.createDirPath(testing.io, test_dir) catch {};
    defer cwd.deleteTree(testing.io, test_dir) catch {};

    const test_img = "zig-cache/tmp_test_media_gen/sample.png";
    const f = try cwd.createFile(testing.io, test_img, .{});
    defer f.close(testing.io);
    // Write valid 1x1 PNG
    try f.writeStreamingAll(testing.io, "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89");

    media_gen_tool.clearTurnAttachments(alloc);
    defer media_gen_tool.clearTurnAttachments(alloc);

    media_gen_tool.setConfig(.{
        .image_input_max_bytes = 10 * 1024 * 1024,
        .image_input_max_per_turn = 2,
    });

    const input_json = try std.fmt.allocPrint(alloc, "{{\"path\":\"{s}\"}}", .{test_img});
    defer alloc.free(input_json);

    const out = try media_gen_tool.attachImageTool(alloc, testing.io, input_json);
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "Attached image:") != null);
    try testing.expectEqual(@as(usize, 1), media_gen_tool.getTurnAttachments().len);
    try testing.expectEqualStrings("image/png", media_gen_tool.getTurnAttachments()[0].media_type);

    media_gen_tool.clearTurnAttachments(alloc);
    try testing.expectEqual(@as(usize, 0), media_gen_tool.getTurnAttachments().len);
}

// Hook listener for media_saved verification
const MediaHookCapture = struct {
    var saved_path: ?[]const u8 = null;
    var saved_type: ?[]const u8 = null;

    fn reset(alloc: std.mem.Allocator) void {
        if (saved_path) |p| alloc.free(p);
        if (saved_type) |t| alloc.free(t);
        saved_path = null;
        saved_type = null;
    }

    fn listener(payload: hooks.HookPayload) void {
        if (std.mem.eql(u8, payload.event, "media_saved")) {
            if (payload.artifact_path) |p| {
                saved_path = testing.allocator.dupe(u8, p) catch null;
            }
            if (payload.artifact_type) |t| {
                saved_type = testing.allocator.dupe(u8, t) catch null;
            }
        }
    }
};

test "media_gen: media_saved hook is fired on media dispatch" {
    const alloc = testing.allocator;
    MediaHookCapture.reset(alloc);
    defer MediaHookCapture.reset(alloc);

    hooks.setHookListener(&MediaHookCapture.listener);
    defer hooks.setHookListener(null);

    hooks.dispatch(alloc, testing.io, .{
        .event = "media_saved",
        .artifact_path = "media/test_art.png",
        .artifact_type = "image/png",
    });

    try testing.expect(MediaHookCapture.saved_path != null);
    try testing.expectEqualStrings("media/test_art.png", MediaHookCapture.saved_path.?);
    try testing.expectEqualStrings("image/png", MediaHookCapture.saved_type.?);
}

test "media_gen: CodeAct JS VM binding mini.media policy enforcement" {
    const alloc = testing.allocator;

    const engine = try quickjs.Engine.init(alloc, testing.io);
    defer engine.deinit();

    try js_bindings.registerBindings(engine);

    // Disable media generation capabilities
    registry.setPolicy(null, null);
    registry.setMediaConfig(false, false, true);

    // Running mini.media("image", "test") must throw Security Policy Error
    const code = "mini.media('image', 'a scenic view');";
    var res = try engine.eval(code, "test_media_sec.js");
    defer res.deinit();

    try testing.expect(res.is_error);
    try testing.expect(res.error_message != null);
    try testing.expect(std.mem.indexOf(u8, res.error_message.?, "Security Policy Error") != null);
}

test "media_gen: CodeAct mini.media attach integrates with turn attachments" {
    const alloc = testing.allocator;
    const cwd = std.Io.Dir.cwd();
    const test_dir = "zig-cache/tmp_test_media_codeact";
    cwd.createDirPath(testing.io, test_dir) catch {};
    defer cwd.deleteTree(testing.io, test_dir) catch {};

    const test_img = "zig-cache/tmp_test_media_codeact/sample.png";
    const f = try cwd.createFile(testing.io, test_img, .{});
    defer f.close(testing.io);
    try f.writeStreamingAll(testing.io, "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89");

    media_gen_tool.clearTurnAttachments(alloc);
    defer media_gen_tool.clearTurnAttachments(alloc);

    media_gen_tool.setConfig(.{
        .image_input_max_bytes = 10 * 1024 * 1024,
        .image_input_max_per_turn = 2,
    });

    const engine = try quickjs.Engine.init(alloc, testing.io);
    defer engine.deinit();

    try js_bindings.registerBindings(engine);
    registry.setPolicy(null, null);
    registry.setMediaConfig(false, false, true);

    const code = try std.fmt.allocPrint(alloc, "const r = mini.media('attach', '{s}'); r.ok;", .{test_img});
    defer alloc.free(code);

    var res = try engine.eval(code, "test_attach.js");
    defer res.deinit();

    try testing.expect(!res.is_error);
    try testing.expectEqual(@as(usize, 1), media_gen_tool.getTurnAttachments().len);

    // Simulate agent recording execution output to history
    var history = mini.history_mod.History.init(alloc);
    defer history.deinit();

    const turn_attached = media_gen_tool.getTurnAttachments();
    if (turn_attached.len > 0) {
        try history.addUserWithImages("[CodeAct Output]", turn_attached);
        media_gen_tool.clearTurnAttachments(alloc);
    }

    try testing.expectEqual(@as(usize, 0), media_gen_tool.getTurnAttachments().len);
    try testing.expectEqual(@as(usize, 1), history.len());
    const msg = history.messages()[0];
    try testing.expectEqual(@as(usize, 2), msg.content.len);
    try testing.expectEqualStrings("[CodeAct Output]", msg.content[0].text);
    try testing.expect(msg.content[1] == .image);
    try testing.expectEqualStrings("image/png", msg.content[1].image.media_type);
}

