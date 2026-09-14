//! tools/media_gen.zig — Media generation (Image & Video) and Vision Loop-Back tools.
//!
//! Implements RFC-011:
//!   - generate_image: synchronous image generation via OpenAI Images API / compat
//!   - generate_video: asynchronous video generation with polling loop via Sora / compat
//!   - image_attach: loop-back vision attachment for multi-turn inspection

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../core/json.zig");
const proto = @import("../core/protocol.zig");
const hooks = @import("../core/hooks.zig");
const http_lib = @import("../lib/http_request.zig");
const media_lib = @import("../lib/media.zig");
const utils = @import("../core/utils.zig");
const main = @import("../main.zig");

// ---------------------------------------------------------------------------
// Configuration & State
// ---------------------------------------------------------------------------

pub const MediaGenConfig = struct {
    image_gen_enabled: bool = false,
    image_gen_provider: []const u8 = "openai",
    image_gen_model: []const u8 = "gpt-image-1",
    image_gen_size: []const u8 = "1024x1024",
    video_gen_enabled: bool = false,
    video_gen_model: []const u8 = "sora-2",
    media_output_dir: ?[]const u8 = null,
    video_poll_timeout_secs: u32 = 600,
    openai_compat_url: ?[]const u8 = null,
    openai_compat_key: ?[]const u8 = null,
    image_input_max_bytes: usize = 10 * 1024 * 1024,
    image_input_max_per_turn: u8 = 5,
};

var g_config: MediaGenConfig = .{};
var g_attached_turn_images: std.ArrayList(proto.ImageBlock) = .empty;

pub fn setConfig(cfg: MediaGenConfig) void {
    g_config = cfg;
}

pub fn getConfig() MediaGenConfig {
    return g_config;
}

pub fn clearTurnAttachments(alloc: Allocator) void {
    for (g_attached_turn_images.items) |img| {
        alloc.free(img.data);
        alloc.free(img.media_type);
    }
    g_attached_turn_images.deinit(alloc);
    g_attached_turn_images = .empty;
}

pub fn getTurnAttachments() []const proto.ImageBlock {
    return g_attached_turn_images.items;
}

pub const MediaResult = struct {
    path: []const u8,
    media_type: []const u8,
    bytes: usize,
    width: ?u32 = null,
    height: ?u32 = null,
    ok: bool = true,
    message: []const u8 = "",
};

// ---------------------------------------------------------------------------
// Path & Filename Sanitization (RFC-011 §3.2)
// ---------------------------------------------------------------------------

pub fn sanitizeFilename(alloc: Allocator, name: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(alloc);

    for (name) |c| {
        if (buf.items.len >= 64) break;
        if ((c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '-' or c == '.')
        {
            // Disallow path traversal '..'
            if (c == '.' and buf.items.len > 0 and buf.items[buf.items.len - 1] == '.') {
                continue;
            }
            try buf.append(alloc, c);
        }
    }

    const trimmed = std.mem.trim(u8, buf.items, " ._");
    if (trimmed.len == 0) {
        buf.deinit(alloc);
        return try alloc.dupe(u8, "generated_media");
    }

    if (trimmed.len != buf.items.len) {
        const copy = try alloc.dupe(u8, trimmed);
        buf.deinit(alloc);
        return copy;
    }

    return buf.toOwnedSlice(alloc);
}

fn ensureOutputDir(alloc: Allocator, io: std.Io, dir_path: []const u8) !void {
    _ = alloc;
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, dir_path) catch {};
}

fn buildAuthHeaders(alloc: Allocator, key: ?[]const u8) ![]const u8 {
    if (key) |k| {
        if (k.len > 0) {
            return std.fmt.allocPrint(alloc, "{{\"Authorization\":\"Bearer {s}\",\"Content-Type\":\"application/json\"}}", .{k});
        }
    }
    return std.fmt.allocPrint(alloc, "{{\"Content-Type\":\"application/json\"}}", .{});
}

// ---------------------------------------------------------------------------
// generate_image Tool (RFC-011 §3.2)
// ---------------------------------------------------------------------------

pub fn generateImageTool(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    const prompt = (try json.findStringOwned(alloc, input_json, "prompt")) orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'prompt' parameter for generate_image", .{});
    defer alloc.free(prompt);

    const size = json.findString(input_json, "size");
    const filename = json.findString(input_json, "filename");
    const model = json.findString(input_json, "model");

    const result = generateImageDirect(alloc, io, prompt, size, filename, model) catch |e| {
        return std.fmt.allocPrint(alloc, "Error generating image: {s}", .{@errorName(e)});
    };
    defer {
        alloc.free(result.path);
        alloc.free(result.media_type);
        if (result.message.len > 0) alloc.free(result.message);
    }

    if (!result.ok) {
        return std.fmt.allocPrint(alloc, "Error: {s}", .{result.message});
    }

    const dims_str = if (result.width != null and result.height != null)
        try std.fmt.allocPrint(alloc, ", {d}x{d}", .{ result.width.?, result.height.? })
    else
        try alloc.dupe(u8, "");
    defer alloc.free(dims_str);

    return std.fmt.allocPrint(alloc,
        "Generated image: {s} ({s}{s}, {d} bytes)",
        .{ result.path, result.media_type, dims_str, result.bytes },
    );
}

pub fn generateImageDirect(
    alloc: Allocator,
    io: std.Io,
    prompt: []const u8,
    size_opt: ?[]const u8,
    filename_opt: ?[]const u8,
    model_opt: ?[]const u8,
) !MediaResult {
    if (prompt.len == 0 or prompt.len > 4000) {
        return MediaResult{
            .path = "",
            .media_type = "",
            .bytes = 0,
            .ok = false,
            .message = try alloc.dupe(u8, "Prompt must be between 1 and 4000 characters"),
        };
    }

    const model = model_opt orelse g_config.image_gen_model;
    const size = size_opt orelse g_config.image_gen_size;
    const is_compat = std.mem.eql(u8, g_config.image_gen_provider, "openai_compat");

    var base_url: []const u8 = "https://api.openai.com/v1";
    if (is_compat) {
        if (g_config.openai_compat_url) |u| {
            base_url = std.mem.trimEnd(u8, u, "/");
        }
    } else if (g_config.openai_compat_url) |u| {
        base_url = std.mem.trimEnd(u8, u, "/");
    }

    const api_url = if (std.mem.endsWith(u8, base_url, "/v1"))
        try std.fmt.allocPrint(alloc, "{s}/images/generations", .{base_url})
    else
        try std.fmt.allocPrint(alloc, "{s}/v1/images/generations", .{base_url});
    defer alloc.free(api_url);

    const api_key = g_config.openai_compat_key;
    const headers_json = try buildAuthHeaders(alloc, api_key);
    defer alloc.free(headers_json);

    const escaped_prompt = try json.escape(alloc, prompt);
    defer alloc.free(escaped_prompt);

    const req_body = try std.fmt.allocPrint(alloc,
        \\{{"model":"{s}","prompt":"{s}","size":"{s}","n":1,"response_format":"b64_json"}}
    , .{ model, escaped_prompt, size });
    defer alloc.free(req_body);

    var res = http_lib.fetch(alloc, io, .{
        .url = api_url,
        .method = "POST",
        .body = req_body,
        .headers_json = headers_json,
        .max_body_size = 20 * 1024 * 1024,
        .timeout_s = 120,
    }) catch |e| {
        return MediaResult{
            .path = "",
            .media_type = "",
            .bytes = 0,
            .ok = false,
            .message = try std.fmt.allocPrint(alloc, "HTTP request failed: {s}", .{@errorName(e)}),
        };
    };
    defer res.deinit(alloc);

    if (res.status < 200 or res.status >= 300) {
        const body_snippet = if (res.body.len > 256) res.body[0..256] else res.body;
        return MediaResult{
            .path = "",
            .media_type = "",
            .bytes = 0,
            .ok = false,
            .message = try std.fmt.allocPrint(alloc, "Provider returned HTTP {d}: {s}", .{ res.status, body_snippet }),
        };
    }

    // Parse response: data[0].b64_json or data[0].url
    var binary_data: ?[]u8 = null;
    defer if (binary_data) |b| alloc.free(b);

    if (json.findString(res.body, "b64_json")) |b64_str| {
        const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(b64_str);
        const bin_buf = try alloc.alloc(u8, decoded_len);
        errdefer alloc.free(bin_buf);
        try std.base64.standard.Decoder.decode(bin_buf, b64_str);
        binary_data = bin_buf;
    } else if (json.findString(res.body, "url")) |img_url| {
        // Fetch binary from URL
        var img_res = try http_lib.fetch(alloc, io, .{
            .url = img_url,
            .method = "GET",
            .max_body_size = 20 * 1024 * 1024,
            .timeout_s = 60,
        });
        defer img_res.deinit(alloc);
        if (img_res.status == 200 and img_res.body.len > 0) {
            binary_data = try alloc.dupe(u8, img_res.body);
        }
    }

    if (binary_data == null) {
        return MediaResult{
            .path = "",
            .media_type = "",
            .bytes = 0,
            .ok = false,
            .message = try alloc.dupe(u8, "No image data (b64_json or url) returned in provider response"),
        };
    }

    const data = binary_data.?;
    const detected_mime = media_lib.sniffMimeFromMagic(data) orelse "image/png";
    const dims = media_lib.extractDimensions(data, detected_mime);

    // Determine extension
    const ext = if (std.mem.eql(u8, detected_mime, "image/jpeg"))
        ".jpg"
    else if (std.mem.eql(u8, detected_mime, "image/webp"))
        ".webp"
    else if (std.mem.eql(u8, detected_mime, "image/gif"))
        ".gif"
    else
        ".png";

    const base_filename = if (filename_opt) |f|
        try sanitizeFilename(alloc, f)
    else
        try alloc.dupe(u8, "image");
    defer alloc.free(base_filename);

    const safe_name = if (std.mem.endsWith(u8, base_filename, ext))
        try alloc.dupe(u8, base_filename)
    else
        try std.fmt.allocPrint(alloc, "{s}{s}", .{ base_filename, ext });
    defer alloc.free(safe_name);

    const output_dir = g_config.media_output_dir orelse "media";
    try ensureOutputDir(alloc, io, output_dir);

    const ts = utils.milliTimestamp();
    const final_path = try std.fmt.allocPrint(alloc, "{s}/{d}_{s}", .{ output_dir, ts, safe_name });
    errdefer alloc.free(final_path);

    // Save binary to file
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(io, final_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, data);

    // Hook dispatch (RFC-011 §3.2 step 6)
    hooks.dispatch(alloc, io, .{
        .event = "media_saved",
        .artifact_path = final_path,
        .artifact_type = detected_mime,
    });

    return MediaResult{
        .path = final_path,
        .media_type = try alloc.dupe(u8, detected_mime),
        .bytes = data.len,
        .width = if (dims.width > 0) dims.width else null,
        .height = if (dims.height > 0) dims.height else null,
        .ok = true,
        .message = try alloc.dupe(u8, "Image generated successfully"),
    };
}

// ---------------------------------------------------------------------------
// generate_video Tool (RFC-011 §3.3)
// ---------------------------------------------------------------------------

pub fn generateVideoTool(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    const prompt = (try json.findStringOwned(alloc, input_json, "prompt")) orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'prompt' parameter for generate_video", .{});
    defer alloc.free(prompt);

    const seconds_opt = if (json.findString(input_json, "seconds")) |s|
        std.fmt.parseInt(u32, s, 10) catch 4
    else
        4;
    const filename = json.findString(input_json, "filename");
    const model = json.findString(input_json, "model");

    const result = generateVideoDirect(alloc, io, prompt, seconds_opt, filename, model) catch |e| {
        return std.fmt.allocPrint(alloc, "Error generating video: {s}", .{@errorName(e)});
    };
    defer {
        alloc.free(result.path);
        alloc.free(result.media_type);
        if (result.message.len > 0) alloc.free(result.message);
    }

    if (!result.ok) {
        return std.fmt.allocPrint(alloc, "Error: {s}", .{result.message});
    }

    return std.fmt.allocPrint(alloc,
        "Generated video: {s} ({s}, {d} bytes)",
        .{ result.path, result.media_type, result.bytes },
    );
}

pub fn generateVideoDirect(
    alloc: Allocator,
    io: std.Io,
    prompt: []const u8,
    seconds: u32,
    filename_opt: ?[]const u8,
    model_opt: ?[]const u8,
) !MediaResult {
    if (prompt.len == 0) {
        return MediaResult{
            .path = "",
            .media_type = "",
            .bytes = 0,
            .ok = false,
            .message = try alloc.dupe(u8, "Prompt cannot be empty"),
        };
    }

    const model = model_opt orelse g_config.video_gen_model;
    var base_url: []const u8 = "https://api.openai.com/v1";
    if (g_config.openai_compat_url) |u| {
        base_url = std.mem.trimEnd(u8, u, "/");
    }

    const create_url = if (std.mem.endsWith(u8, base_url, "/v1"))
        try std.fmt.allocPrint(alloc, "{s}/videos", .{base_url})
    else
        try std.fmt.allocPrint(alloc, "{s}/v1/videos", .{base_url});
    defer alloc.free(create_url);

    const api_key = g_config.openai_compat_key;
    const headers_json = try buildAuthHeaders(alloc, api_key);
    defer alloc.free(headers_json);

    const escaped_prompt = try json.escape(alloc, prompt);
    defer alloc.free(escaped_prompt);

    const req_body = try std.fmt.allocPrint(alloc,
        \\{{"model":"{s}","prompt":"{s}","duration":{d}}}
    , .{ model, escaped_prompt, seconds });
    defer alloc.free(req_body);

    var res = try http_lib.fetch(alloc, io, .{
        .url = create_url,
        .method = "POST",
        .body = req_body,
        .headers_json = headers_json,
        .timeout_s = 60,
    });
    defer res.deinit(alloc);

    if (res.status < 200 or res.status >= 300) {
        return MediaResult{
            .path = "",
            .media_type = "",
            .bytes = 0,
            .ok = false,
            .message = try std.fmt.allocPrint(alloc, "Failed to start video job (HTTP {d})", .{res.status}),
        };
    }

    const job_id = json.findString(res.body, "id") orelse {
        return MediaResult{
            .path = "",
            .media_type = "",
            .bytes = 0,
            .ok = false,
            .message = try alloc.dupe(u8, "Video job ID missing from response"),
        };
    };

    // Polling loop
    const poll_url = if (std.mem.endsWith(u8, base_url, "/v1"))
        try std.fmt.allocPrint(alloc, "{s}/videos/{s}", .{ base_url, job_id })
    else
        try std.fmt.allocPrint(alloc, "{s}/v1/videos/{s}", .{ base_url, job_id });
    defer alloc.free(poll_url);

    const start_time = utils.milliTimestamp();
    const timeout_ms: i64 = @as(i64, @intCast(g_config.video_poll_timeout_secs)) * 1000;

    var completed = false;
    while (utils.milliTimestamp() - start_time < timeout_ms) {
        var poll_res = http_lib.fetch(alloc, io, .{
            .url = poll_url,
            .method = "GET",
            .headers_json = headers_json,
            .timeout_s = 30,
        }) catch {
            std.Io.sleep(io, std.Io.Duration.fromSeconds(2), .awake) catch {};
            continue;
        };
        defer poll_res.deinit(alloc);

        if (poll_res.status == 200) {
            const status = json.findString(poll_res.body, "status") orelse "queued";
            if (std.mem.eql(u8, status, "completed")) {
                completed = true;
                break;
            } else if (std.mem.eql(u8, status, "failed")) {
                const err_msg = json.findString(poll_res.body, "error") orelse "Video generation job failed";
                return MediaResult{
                    .path = "",
                    .media_type = "",
                    .bytes = 0,
                    .ok = false,
                    .message = try alloc.dupe(u8, err_msg),
                };
            }
        }
        std.Io.sleep(io, std.Io.Duration.fromSeconds(1), .awake) catch {};
    }

    if (!completed) {
        return MediaResult{
            .path = "",
            .media_type = "",
            .bytes = 0,
            .ok = false,
            .message = try alloc.dupe(u8, "Video job polling timed out"),
        };
    }

    // Download completed video content
    const content_url = if (std.mem.endsWith(u8, base_url, "/v1"))
        try std.fmt.allocPrint(alloc, "{s}/videos/{s}/content", .{ base_url, job_id })
    else
        try std.fmt.allocPrint(alloc, "{s}/v1/videos/{s}/content", .{ base_url, job_id });
    defer alloc.free(content_url);

    var dl_res = try http_lib.fetch(alloc, io, .{
        .url = content_url,
        .method = "GET",
        .headers_json = headers_json,
        .max_body_size = 200 * 1024 * 1024,
        .timeout_s = 300,
    });
    defer dl_res.deinit(alloc);

    if (dl_res.status != 200 or dl_res.body.len == 0) {
        return MediaResult{
            .path = "",
            .media_type = "",
            .bytes = 0,
            .ok = false,
            .message = try alloc.dupe(u8, "Failed to download video content"),
        };
    }

    const base_filename = if (filename_opt) |f|
        try sanitizeFilename(alloc, f)
    else
        try alloc.dupe(u8, "video");
    defer alloc.free(base_filename);

    const safe_name = if (std.mem.endsWith(u8, base_filename, ".mp4"))
        try alloc.dupe(u8, base_filename)
    else
        try std.fmt.allocPrint(alloc, "{s}.mp4", .{base_filename});
    defer alloc.free(safe_name);

    const output_dir = g_config.media_output_dir orelse "media";
    try ensureOutputDir(alloc, io, output_dir);

    const ts = utils.milliTimestamp();
    const final_path = try std.fmt.allocPrint(alloc, "{s}/{d}_{s}", .{ output_dir, ts, safe_name });
    errdefer alloc.free(final_path);

    const cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(io, final_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, dl_res.body);

    hooks.dispatch(alloc, io, .{
        .event = "media_saved",
        .artifact_path = final_path,
        .artifact_type = "video/mp4",
    });

    return MediaResult{
        .path = final_path,
        .media_type = try alloc.dupe(u8, "video/mp4"),
        .bytes = dl_res.body.len,
        .ok = true,
        .message = try alloc.dupe(u8, "Video generated successfully"),
    };
}

// ---------------------------------------------------------------------------
// image_attach Tool (RFC-011 §3.5 Loop-Back Vision)
// ---------------------------------------------------------------------------

pub fn attachImageTool(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    const path = (try json.findStringOwned(alloc, input_json, "path")) orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'path' parameter for image_attach", .{});
    defer alloc.free(path);

    const res = attachImageDirect(alloc, io, path) catch |e| {
        return std.fmt.allocPrint(alloc, "Error attaching image: {s}", .{@errorName(e)});
    };
    defer {
        alloc.free(res.path);
        alloc.free(res.media_type);
        if (res.message.len > 0) alloc.free(res.message);
    }

    if (!res.ok) {
        return std.fmt.allocPrint(alloc, "Error: {s}", .{res.message});
    }

    return std.fmt.allocPrint(alloc,
        "Attached image: {s} ({s}, {d} bytes)",
        .{ res.path, res.media_type, res.bytes },
    );
}

pub fn attachImageDirect(alloc: Allocator, io: std.Io, path: []const u8) !MediaResult {
    if (g_attached_turn_images.items.len >= g_config.image_input_max_per_turn) {
        return MediaResult{
            .path = try alloc.dupe(u8, path),
            .media_type = try alloc.dupe(u8, ""),
            .bytes = 0,
            .ok = false,
            .message = try std.fmt.allocPrint(alloc, "Maximum image attachments per turn reached ({d})", .{g_config.image_input_max_per_turn}),
        };
    }

    const read_res = media_lib.readImageFile(alloc, io, path, .{ .max_bytes = g_config.image_input_max_bytes }) catch |e| {
        return MediaResult{
            .path = try alloc.dupe(u8, path),
            .media_type = try alloc.dupe(u8, ""),
            .bytes = 0,
            .ok = false,
            .message = try std.fmt.allocPrint(alloc, "Failed to read image file: {s}", .{@errorName(e)}),
        };
    };
    const img = proto.ImageBlock{
        .data = read_res.data,
        .media_type = try alloc.dupe(u8, read_res.media_type),
    };

    try g_attached_turn_images.append(alloc, img);

    return MediaResult{
        .path = try alloc.dupe(u8, path),
        .media_type = try alloc.dupe(u8, img.media_type),
        .bytes = img.data.len,
        .ok = true,
        .message = try alloc.dupe(u8, "Image attached successfully"),
    };
}
