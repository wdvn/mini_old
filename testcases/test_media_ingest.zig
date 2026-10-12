//! testcases/test_media_ingest.zig — Integration tests for Media Ingestion (Phase 0).
//!
//! Validates:
//!   1. Magic bytes sniffing (blocking polyglot files)
//!   2. Prompt token parser (@image:<path> with escaped spaces)
//!   3. Token estimation without caching raw base64
//!   4. Backend serialization across Anthropic Claude, OpenAI, and Ollama
//!   5. History message handling and image blocks

const std = @import("std");
const testing = std.testing;
const mini = @import("mini");
const proto = mini.protocol_mod;
const history_mod = mini.history_mod;
const media_lib = mini.media_lib;
const tokens_mod = mini.tokens_mod;
const openai_backend = mini.backends.openai_mod;
const claude_backend = mini.backends.claude_mod;
const ollama_backend = mini.backends.ollama_mod;

test "media_ingest: sniffMimeFromMagic detects formats and blocks polyglots" {
    // 1. Valid PNG
    const png_header = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR";
    try testing.expectEqualStrings("image/png", media_lib.sniffMimeFromMagic(png_header).?);

    // 2. Valid JPEG
    const jpeg_header = "\xFF\xD8\xFF\xE0\x00\x10JFIF\x00";
    try testing.expectEqualStrings("image/jpeg", media_lib.sniffMimeFromMagic(jpeg_header).?);

    // 3. Valid GIF
    const gif_header = "GIF89a\x0A\x00\x0A\x00";
    try testing.expectEqualStrings("image/gif", media_lib.sniffMimeFromMagic(gif_header).?);

    // 4. Valid WEBP
    const webp_header = "RIFF\x20\x00\x00\x00WEBPVP8 ";
    try testing.expectEqualStrings("image/webp", media_lib.sniffMimeFromMagic(webp_header).?);

    // 5. Impostor / polyglot: text file with .png content
    const polyglot = "<?php echo 'malicious'; ?>";
    try testing.expect(media_lib.sniffMimeFromMagic(polyglot) == null);

    const empty = "";
    try testing.expect(media_lib.sniffMimeFromMagic(empty) == null);
}

test "media_ingest: parsePromptImages parses escaped paths and cleans prompt" {
    const alloc = testing.allocator;
    const cwd = std.Io.Dir.cwd();
    const test_dir = "zig-cache/tmp_test_ingest";
    cwd.createDirPath(testing.io, test_dir) catch {};
    defer cwd.deleteTree(testing.io, test_dir) catch {};

    const img1_name = "zig-cache/tmp_test_ingest/test_img1.png";
    const f1 = try cwd.createFile(testing.io, img1_name, .{});
    defer f1.close(testing.io);
    // Write valid PNG header + IHDR
    try f1.writeStreamingAll(testing.io, "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x10\x00\x00\x00\x10\x08\x06\x00\x00\x00");

    const img2_name = "zig-cache/tmp_test_ingest/my test img2.gif";
    const f2 = try cwd.createFile(testing.io, img2_name, .{});
    defer f2.close(testing.io);
    // Write valid GIF
    try f2.writeStreamingAll(testing.io, "GIF89a\x10\x00\x10\x00\x80\x00\x00");

    // Escape space in img2_name for prompt: my\ test\ img2.gif
    var escaped_img2 = std.ArrayList(u8).empty;
    defer escaped_img2.deinit(alloc);
    for (img2_name) |c| {
        if (c == ' ') try escaped_img2.appendSlice(alloc, "\\ ");
        if (c != ' ') try escaped_img2.append(alloc, c);
    }

    const input_prompt = try std.fmt.allocPrint(alloc, "@image:{s} Describe this and compare with @image:{s} please", .{ img1_name, escaped_img2.items });
    defer alloc.free(input_prompt);

    const parsed = try media_lib.parsePromptImages(alloc, testing.io, input_prompt, .{ .max_per_turn = 5, .max_bytes = 10 * 1024 * 1024 });
    defer parsed.deinit(alloc);

    try testing.expectEqual(@as(usize, 2), parsed.images.len);
    try testing.expectEqualStrings("image/png", parsed.images[0].media_type);
    try testing.expectEqualStrings("image/gif", parsed.images[1].media_type);
    try testing.expectEqualStrings("Describe this and compare with please", parsed.clean_text);
}

test "media_ingest: token estimator handles ImageBlock directly without cache bloat" {
    const alloc = testing.allocator;
    var estimator = tokens_mod.TokenEstimator.init(alloc);
    defer estimator.deinit();

    // 1MB fake base64 data
    const fake_data = try alloc.alloc(u8, 1000 * 1000);
    defer alloc.free(fake_data);
    @memset(fake_data, 'A');

    const img_block = proto.ContentBlock{
        .image = .{
            .data = fake_data,
            .media_type = "image/png",
        },
    };

    const msgs = [_]proto.Message{
        .{
            .role = .user,
            .content = &[_]proto.ContentBlock{img_block},
            .tier = .recent,
        },
    };

    const estimated = estimator.estimateMessages(&msgs);
    // Expected ~ 1000 tokens (1000000 / 1000)
    try testing.expect(estimated >= 1000);

    // Ensure StringHashMap has NOT cached the 1MB data
    try testing.expectEqual(@as(u32, 0), estimator.cache.count());
}

test "media_ingest: claude backend serializes image blocks" {
    const alloc = testing.allocator;

    const img_block = proto.ContentBlock{
        .image = .{
            .data = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
            .media_type = "image/png",
        },
    };
    const text_block = proto.ContentBlock{ .text = "What is in this image?" };
    const content = [_]proto.ContentBlock{ text_block, img_block };

    const msgs = [_]proto.Message{
        .{ .role = .user, .content = &content, .tier = .recent },
    };

    // Instantiate claude client and build request body
    const client = claude_backend.Client.init(alloc, "test-key", "claude-3-5-sonnet-20241022", 1024);

    // Exported request building test
    const tools = [_]proto.ToolDefinition{};
    const req = try claude_backend.buildRequestBody(alloc, client.model, client.max_tokens, null, "Sys prompt", &msgs, &tools);
    defer alloc.free(req);

    try testing.expect(std.mem.indexOf(u8, req, "\"type\":\"image\"") != null);
    try testing.expect(std.mem.indexOf(u8, req, "\"media_type\":\"image/png\"") != null);
    try testing.expect(std.mem.indexOf(u8, req, "\"data\":\"iVBORw0KGgoAAAAN") != null);
}

test "media_ingest: openai backend serializes image blocks in chat completions and responses api" {
    const alloc = testing.allocator;

    const img_block = proto.ContentBlock{
        .image = .{
            .data = "ZmFrZV9iNjRfaW1hZ2VfZGF0YQ==",
            .media_type = "image/png",
        },
    };
    const text_block = proto.ContentBlock{ .text = "Inspect UI" };
    const content = [_]proto.ContentBlock{ text_block, img_block };

    const msgs = [_]proto.Message{
        .{ .role = .user, .content = &content, .tier = .recent },
    };
    const tools = [_]proto.ToolDefinition{};

    // 1. Chat Completions
    const cc_body = try openai_backend.buildRequestBody(alloc, "gpt-4o", 1024, false, false, null, false, "Sys", &msgs, &tools);
    defer alloc.free(cc_body);

    try testing.expect(std.mem.indexOf(u8, cc_body, "\"type\":\"image_url\"") != null);
    try testing.expect(std.mem.indexOf(u8, cc_body, "data:image/png;base64,ZmFrZV9iNjRfaW1hZ2VfZGF0YQ==") != null);

    // 2. Responses API
    const resp_body = try openai_backend.buildResponsesRequestBody(alloc, "gpt-5.6-terra", 1024, false, null, null, "Sys", &msgs, &tools, mini.backends.provider_mod.getProfile("openai"));
    defer alloc.free(resp_body);

    try testing.expect(std.mem.indexOf(u8, resp_body, "\"type\":\"input_image\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp_body, "\"image_url\":\"data:image/png;base64,ZmFrZV9iNjRfaW1hZ2VfZGF0YQ==\"") != null);
}

test "media_ingest: ollama backend serializes image blocks into top-level images array" {
    const alloc = testing.allocator;

    const img_block = proto.ContentBlock{
        .image = .{
            .data = "b2xsYW1hX2Jhc2U2NF9kYXRh",
            .media_type = "image/png",
        },
    };
    const text_block = proto.ContentBlock{ .text = "Describe" };
    const content = [_]proto.ContentBlock{ text_block, img_block };

    const msgs = [_]proto.Message{
        .{ .role = .user, .content = &content, .tier = .recent },
    };
    const tools = [_]proto.ToolDefinition{};

    const body = try ollama_backend.buildRequestBody(alloc, "llava", "Sys", &msgs, &tools);
    defer alloc.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"images\":[\"b2xsYW1hX2Jhc2U2NF9kYXRh\"]") != null);
}

test "media_ingest: history addUserWithImages stores and frees image blocks cleanly" {
    const alloc = testing.allocator;
    var history = history_mod.History.init(alloc);
    defer history.deinit();

    const images = [_]proto.ImageBlock{
        .{ .data = "data1", .media_type = "image/png" },
        .{ .data = "data2", .media_type = "image/jpeg" },
    };

    try history.addUserWithImages("Look at these", &images);

    try testing.expectEqual(@as(usize, 1), history.len());
    const msg = history.messages()[0];
    try testing.expectEqual(@as(usize, 3), msg.content.len);
    try testing.expectEqualStrings("Look at these", msg.content[0].text);
    try testing.expectEqualStrings("data1", msg.content[1].image.data);
    try testing.expectEqualStrings("image/png", msg.content[1].image.media_type);
    try testing.expectEqualStrings("data2", msg.content[2].image.data);
    try testing.expectEqualStrings("image/jpeg", msg.content[2].image.media_type);
}

test "media_ingest: pure image prompt without text does not emit empty text blocks in Claude and OpenAI" {
    const alloc = testing.allocator;

    // 1. History addUserWithImages with empty text should only contain the image block
    var history = history_mod.History.init(alloc);
    defer history.deinit();

    const images = [_]proto.ImageBlock{
        .{ .data = "ZmFrZV9iNjRfaW1hZ2VfZGF0YQ==", .media_type = "image/png" },
    };
    try history.addUserWithImages("", &images);

    try testing.expectEqual(@as(usize, 1), history.len());
    const msg = history.messages()[0];
    try testing.expectEqual(@as(usize, 1), msg.content.len);
    try testing.expect(msg.content[0] == .image);

    // 2. Claude serialization must not emit {"type":"text","text":""}
    const tools = [_]proto.ToolDefinition{};
    const claude_body = try claude_backend.buildRequestBody(alloc, "claude-3-5-sonnet", 1024, null, "Sys", history.messages(), &tools);
    defer alloc.free(claude_body);

    try testing.expect(std.mem.indexOf(u8, claude_body, "\"type\":\"text\",\"text\":\"\"") == null);
    try testing.expect(std.mem.indexOf(u8, claude_body, "\"type\":\"image\"") != null);

    // 3. OpenAI Chat Completions serialization must not emit {"type":"text","text":""}
    const openai_body = try openai_backend.buildRequestBody(alloc, "gpt-4o", 1024, false, false, null, false, "Sys", history.messages(), &tools);
    defer alloc.free(openai_body);

    try testing.expect(std.mem.indexOf(u8, openai_body, "\"type\":\"text\",\"text\":\"\"") == null);
    try testing.expect(std.mem.indexOf(u8, openai_body, "\"type\":\"image_url\"") != null);
}

