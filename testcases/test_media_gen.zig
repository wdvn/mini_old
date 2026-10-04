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

// PSEUDOCODE:
// 1. Validate isCompatOrAgnes against openai, openai_compat, agnes, agnesai, proxy-agnes.
// 2. Ensure only openai returns false, while agnes-related and openai_compat return true.
test "media_gen: isCompatOrAgnes recognizes agnes and compat providers" {
    try testing.expect(!media_gen_tool.isCompatOrAgnes("openai"));
    try testing.expect(media_gen_tool.isCompatOrAgnes("openai_compat"));
    try testing.expect(media_gen_tool.isCompatOrAgnes("agnes"));
    try testing.expect(media_gen_tool.isCompatOrAgnes("agnesai"));
    try testing.expect(media_gen_tool.isCompatOrAgnes("custom-agnes-proxy"));
}

// PSEUDOCODE:
// 1. Set environment variables for Agnes video generation.
// 2. Verify config.Config.load extracts agnes provider and custom video model.
test "media_gen: config loads agnes provider and custom model from env" {
    const alloc = testing.allocator;
    const io = testing.io;

    var env_map = std.process.Environ.Map.init(alloc);
    defer env_map.deinit();

    try env_map.put("MINI_VIDEO_GEN_PROVIDER", "agnes");
    try env_map.put("MINI_VIDEO_GEN_MODEL", "agnes-video-2.5");
    try env_map.put("OPENAI_COMPAT_URL", "https://apihub.agnes.ai/v1/chat/completions");
    try env_map.put("OPENAI_COMPAT_API_KEY", "sk-agnes-test-123");

    var cfg = try mini.config_mod.Config.load(alloc, &env_map, io);
    defer cfg.deinit(alloc);

    try testing.expectEqualStrings("agnes", cfg.video_gen_provider);
    try testing.expectEqualStrings("agnes-video-2.5", cfg.video_gen_model);
    try testing.expectEqualStrings("sk-agnes-test-123", cfg.openai_compat_key.?);
}

// PSEUDOCODE:
// 1. Set OPENAI_COMPAT_PROVIDER=agnes without MINI_VIDEO_GEN_PROVIDER.
// 2. Verify config.Config.load automatically falls back video_gen_provider and image_gen_provider to agnes.
test "media_gen: config falls back to agnes when OPENAI_COMPAT_PROVIDER is agnes" {
    const alloc = testing.allocator;
    const io = testing.io;

    var env_map = std.process.Environ.Map.init(alloc);
    defer env_map.deinit();

    try env_map.put("OPENAI_COMPAT_PROVIDER", "agnes");
    try env_map.put("OPENAI_COMPAT_URL", "https://apihub.agnes.ai/v1");

    var cfg = try mini.config_mod.Config.load(alloc, &env_map, io);
    defer cfg.deinit(alloc);

    try testing.expectEqualStrings("agnes", cfg.video_gen_provider);
    try testing.expectEqualStrings("agnes", cfg.image_gen_provider);
}

// ---------------------------------------------------------------------------
// RFC-028 Task A: strict base URL resolution, plane configs, auth header
// ---------------------------------------------------------------------------

// PSEUDOCODE:
// 1. Unknown provider with no dedicated URL must NOT silently route to OpenAI.
// 2. generateImageDirect must return ok=false with a message naming the
//    provider and MINI_IMAGE_GEN_URL (fail-fast contract, RFC-028 §3.2).
test "media_gen: unknown image provider fails fast with actionable error" {
    const alloc = testing.allocator;

    media_gen_tool.setConfig(.{
        .image = .{
            .enabled = true,
            .provider = "openrouter",
            .model = "gpt-image-1",
            .size = "1024x1024",
            .url = null,
            .key = null,
        },
    });

    const res = try media_gen_tool.generateImageDirect(alloc, testing.io, "a scenic view", null, null, null);
    defer {
        alloc.free(res.path);
        alloc.free(res.media_type);
        if (res.message.len > 0) alloc.free(res.message);
    }

    try testing.expect(!res.ok);
    try testing.expect(std.mem.indexOf(u8, res.message, "openrouter") != null);
    try testing.expect(std.mem.indexOf(u8, res.message, "MINI_IMAGE_GEN_URL") != null);
}

// PSEUDOCODE:
// 1. Video plane mirrors the image plane: unknown provider fails fast.
// 2. Error message must name MINI_VIDEO_GEN_URL.
test "media_gen: unknown video provider fails fast with actionable error" {
    const alloc = testing.allocator;

    media_gen_tool.setConfig(.{
        .video = .{
            .enabled = true,
            .provider = "fal",
            .model = "sora-2",
            .url = null,
            .key = null,
        },
    });

    const res = try media_gen_tool.generateVideoDirect(alloc, testing.io, "waves crashing", 4, null, null);
    defer {
        alloc.free(res.path);
        alloc.free(res.media_type);
        if (res.message.len > 0) alloc.free(res.message);
    }

    try testing.expect(!res.ok);
    try testing.expect(std.mem.indexOf(u8, res.message, "fal") != null);
    try testing.expect(std.mem.indexOf(u8, res.message, "MINI_VIDEO_GEN_URL") != null);
}

// PSEUDOCODE:
// 1. A dedicated MINI_IMAGE_GEN_URL is used verbatim (no cleanBaseUrl
//    truncation, RFC-028 §3.3) and the endpoint is appended directly.
// 2. Since resolveBaseUrl needs the env at call time, drive it through the
//    process env via Config-independent pure helper if exposed; otherwise
//    verify via resolveBaseUrl-equivalent behavior in the direct path.
test "media_gen: dedicated image gen URL is used verbatim with endpoint appended" {
    // The verbatim-URL behavior lives in resolveBaseUrlUrl/resolveApiUrl in
    // media_gen.zig; verify the pure composition function directly.
    const alloc = testing.allocator;

    const api_url = try media_gen_tool.resolveApiUrl(
        alloc,
        "http://localhost:7860/sdapi/v1",
        "txt2img",
        null,
    );
    defer alloc.free(api_url);
    try testing.expectEqualStrings("http://localhost:7860/sdapi/v1/txt2img", api_url);
}

// PSEUDOCODE:
// 1. buildAuthHeaders is parameterized by header name (RFC-028 §3.4).
// 2. Authorization keeps the Bearer prefix; custom headers do not.
// 3. null key yields only the Content-Type header.
test "media_gen: buildAuthHeaders supports custom header names without Bearer" {
    const alloc = testing.allocator;

    // Authorization keeps Bearer prefix (existing contract)
    const h1 = try media_gen_tool.buildAuthHeaders(alloc, "Authorization", "sk-test-123");
    defer alloc.free(h1);
    try testing.expectEqualStrings(
        "{\"Authorization\":\"Bearer sk-test-123\",\"Content-Type\":\"application/json\"}",
        h1,
    );

    // Custom header: no Bearer prefix
    const h2 = try media_gen_tool.buildAuthHeaders(alloc, "X-API-Key", "k");
    defer alloc.free(h2);
    try testing.expectEqualStrings(
        "{\"X-API-Key\":\"k\",\"Content-Type\":\"application/json\"}",
        h2,
    );

    // null key: Content-Type only
    const h3 = try media_gen_tool.buildAuthHeaders(alloc, "Authorization", null);
    defer alloc.free(h3);
    try testing.expectEqualStrings("{\"Content-Type\":\"application/json\"}", h3);
}

// PSEUDOCODE:
// 1. resolveProviderOptionsJson returns null when no routing field is set.
// 2. With routing fields set it emits the OpenRouter provider object JSON.
// 3. Raw provider_options must be a JSON object (array/scalar/malformed →
//    error); valid object merges under the routing keys.
test "media_gen: resolveProviderOptionsJson routing object assembly" {
    const alloc = testing.allocator;

    // No routing fields → null
    const none = try media_gen_tool.resolveProviderOptionsJson(alloc, null, null, null, null, null, null);
    try testing.expect(none == null);

    // Routing fields set → provider object
    const only = [_][]const u8{"openai/gpt-image-1"};
    const opts = try media_gen_tool.resolveProviderOptionsJson(
        alloc,
        &only,
        null,
        null,
        "price",
        false,
        null,
    );
    defer if (opts) |o| alloc.free(o);
    try testing.expect(opts != null);
    const got = opts.?;
    try testing.expect(std.mem.indexOf(u8, got, "\"only\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"sort\":\"price\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"allow_fallbacks\":false") != null);

    // Raw JSON object merges under routing keys
    const raw = "{\"data\":{\"plan\":\"free\"}}";
    const merged = try media_gen_tool.resolveProviderOptionsJson(alloc, &only, null, null, null, null, raw);
    defer if (merged) |m| alloc.free(m);
    try testing.expect(merged != null);
    try testing.expect(std.mem.indexOf(u8, merged.?, "\"data\"") != null);
    try testing.expect(std.mem.indexOf(u8, merged.?, "\"only\"") != null);

    // Raw JSON array → error
    try testing.expectError(error.InvalidProviderOptions, media_gen_tool.resolveProviderOptionsJson(
        alloc, null, null, null, null, null, "[1,2]",
    ));
    // Malformed text → error
    try testing.expectError(error.InvalidProviderOptions, media_gen_tool.resolveProviderOptionsJson(
        alloc, null, null, null, null, null, "{not json",
    ));
}

// PSEUDOCODE:
// 1. The plane structs must exist with the RFC-028 §2.1 field surface.
// 2. Nested MediaGenConfig carries no chat-plane fields (§3.1 decision b).
test "media_gen: plane config structs expose the RFC-028 field surface" {
    // Compile-time surface check: all fields from RFC-028 §2.1 are addressable.
    const img = media_gen_tool.ImagePlaneConfig{
        .enabled = true,
        .provider = "openrouter",
        .model = "gpt-image-1",
        .url = "https://example.test/api/v1",
        .key = "sk-or",
        .api_header = "Authorization",
        .endpoint = "images/generations",
        .resolution = "1K",
        .aspect_ratio = "16:9",
        .size = "1024x1024",
        .n = 2,
        .quality = "high",
        .output_format = "webp",
        .background = "opaque",
        .output_compression = 80,
        .stream = false,
        .seed = 42,
        .provider_only = null,
        .provider_order = null,
        .provider_ignore = null,
        .provider_sort = null,
        .provider_allow_fallbacks = null,
        .provider_options = null,
    };
    try testing.expect(img.n == 2);
    try testing.expectEqualStrings("openrouter", img.provider);

    const vid = media_gen_tool.VideoPlaneConfig{
        .enabled = true,
        .provider = "openrouter",
        .model = "sora-2",
        .url = "https://example.test/api/v1",
        .key = "sk-or",
        .api_header = "Authorization",
        .endpoint = "videos",
        .resolution = "720p",
        .aspect_ratio = "16:9",
        .size = "1280x720",
        .duration = 4,
        .generate_audio = false,
        .seed = 7,
        .callback_url = "https://hooks.example.test/cb",
        .poll_interval_secs = 5,
        .poll_timeout_secs = 300,
        .provider_only = null,
        .provider_order = null,
        .provider_ignore = null,
        .provider_sort = null,
        .provider_allow_fallbacks = null,
        .provider_options = null,
    };
    try testing.expect(vid.duration == 4);
    try testing.expectEqualStrings("sora-2", vid.model);

    // MediaGenConfig is nested and carries no chat-plane fields.
    const cfg = media_gen_tool.MediaGenConfig{
        .image = img,
        .video = vid,
        .media_output_dir = "media",
        .image_input_max_bytes = 10 * 1024 * 1024,
        .image_input_max_per_turn = 5,
    };
    try testing.expect(cfg.image.enabled);
    try testing.expect(cfg.video.enabled);
    try testing.expectEqualStrings("media", cfg.media_output_dir.?);
}

