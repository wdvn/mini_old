//! tools/media_gen.zig — Media generation (Image & Video) and Vision Loop-Back tools.
//!
//! Implements:
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


// Per-plane configuration structs
pub const ImagePlaneConfig = struct {
    enabled: bool = false,
    provider: []const u8 = "openai",
    model: []const u8 = "gpt-image-1",
    url: ?[]const u8 = null,
    key: ?[]const u8 = null,
    api_header: []const u8 = "Authorization",
    endpoint: []const u8 = "images/generations",
    resolution: ?[]const u8 = null,
    aspect_ratio: ?[]const u8 = null,
    size: []const u8 = "1024x1024",
    n: u8 = 1,
    quality: ?[]const u8 = null,
    output_format: ?[]const u8 = null,
    background: ?[]const u8 = null,
    output_compression: ?u8 = null,
    stream: bool = false,
    seed: ?i64 = null,
    provider_only: ?[]const []const u8 = null,
    provider_order: ?[]const []const u8 = null,
    provider_ignore: ?[]const []const u8 = null,
    provider_sort: ?[]const u8 = null,
    provider_allow_fallbacks: ?bool = null,
    provider_options: ?[]const u8 = null,
};

pub const VideoPlaneConfig = struct {
    enabled: bool = false,
    provider: []const u8 = "openai",
    model: []const u8 = "sora-2",
    url: ?[]const u8 = null,
    key: ?[]const u8 = null,
    api_header: []const u8 = "Authorization",
    endpoint: []const u8 = "videos",
    resolution: ?[]const u8 = null,
    aspect_ratio: ?[]const u8 = null,
    size: ?[]const u8 = null,
    duration: u32 = 4,
    generate_audio: bool = false,
    seed: ?i64 = null,
    callback_url: ?[]const u8 = null,
    provider_only: ?[]const []const u8 = null,
    provider_order: ?[]const []const u8 = null,
    provider_ignore: ?[]const []const u8 = null,
    provider_sort: ?[]const u8 = null,
    provider_allow_fallbacks: ?bool = null,
    provider_options: ?[]const u8 = null,
    poll_interval_secs: u32 = 5,
    poll_timeout_secs: u32 = 300,
};

pub const MediaGenConfig = struct {
    image: ImagePlaneConfig = .{},
    video: VideoPlaneConfig = .{},
    media_output_dir: ?[]const u8 = null,
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
// Path & Filename Sanitization
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

pub const UnknownProvider = error{UnknownProvider};

pub fn buildAuthHeaders(alloc: Allocator, header_name: []const u8, key: ?[]const u8) ![]const u8 {
    if (key) |k| {
        if (std.mem.eql(u8, header_name, "Authorization")) {
            return std.fmt.allocPrint(alloc, "{{\"Authorization\":\"Bearer {s}\",\"Content-Type\":\"application/json\"}}", .{k});
        }
        return std.fmt.allocPrint(alloc, "{{\"{s}\":\"{s}\",\"Content-Type\":\"application/json\"}}", .{header_name, k});
    }
    return std.fmt.allocPrint(alloc, "{{\"Content-Type\":\"application/json\"}}", .{});
}

// ---------------------------------------------------------------------------
// generate_image Tool
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

    return std.fmt.allocPrint(
        alloc,
        "Generated image: {s} ({s}{s}, {d} bytes)",
        .{ result.path, result.media_type, dims_str, result.bytes },
    );
}

// PSEUDOCODE:
// 1. Detect if provider is OpenAI-compatible or Agnes AI (matches "openai_compat", "agnes", "agnesai").
// 2. Clean base URL by removing endpoint suffixes (/chat/completions, etc.).
// 3. Fallback base URL for Agnes to "https://apihub.agnes.ai/v1" if custom URL not specified.

pub fn isCompatOrAgnes(provider: []const u8) bool {
    return std.mem.eql(u8, provider, "openai_compat") or
        std.mem.eql(u8, provider, "agnes") or
        std.mem.eql(u8, provider, "agnesai") or
        std.mem.indexOf(u8, provider, "agnes") != null;
}

fn cleanBaseUrl(raw: []const u8) []const u8 {
    var u = std.mem.trimEnd(u8, raw, "/ \t\r\n");
    const suffixes = [_][]const u8{ "/chat/completions", "/responses", "/response", "/images/generations", "/videos" };
    for (suffixes) |suffix| {
        if (std.mem.endsWith(u8, u, suffix)) {
            u = std.mem.trimEnd(u8, u[0 .. u.len - suffix.len], "/");
        }
    }
    return u;
}

fn makeFailedMediaResult(alloc: Allocator, msg: []const u8) !MediaResult {
    return MediaResult{
        .path = try alloc.dupe(u8, ""),
        .media_type = try alloc.dupe(u8, ""),
        .bytes = 0,
        .ok = false,
        .message = try alloc.dupe(u8, msg),
    };
}

fn makeFailedMediaResultFmt(alloc: Allocator, comptime fmt: []const u8, args: anytype) !MediaResult {
    return MediaResult{
        .path = try alloc.dupe(u8, ""),
        .media_type = try alloc.dupe(u8, ""),
        .bytes = 0,
        .ok = false,
        .message = try std.fmt.allocPrint(alloc, fmt, args),
    };
}

pub fn resolveBaseUrl(alloc: Allocator, provider: []const u8, dedicated_url: ?[]const u8) ![]const u8 {
    if (dedicated_url) |u| {
        return try alloc.dupe(u8, u);
    }
    if (std.mem.eql(u8, provider, "openai")) {
        return try alloc.dupe(u8, "https://api.openai.com/v1");
    }
    if (std.mem.eql(u8, provider, "openai_compat")) {
        return try alloc.dupe(u8, "https://api.openai.com/v1");
    }
    if (std.mem.indexOf(u8, provider, "agnes") != null) {
        return try alloc.dupe(u8, "https://apihub.agnes.ai/v1");
    }
    return error.UnknownProvider;
}

fn resolveEndpointUrl(alloc: Allocator, base_url: []const u8, suffix: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, base_url, "/v1")) {
        return std.fmt.allocPrint(alloc, "{s}/{s}", .{ base_url, suffix });
    }
    return std.fmt.allocPrint(alloc, "{s}/v1/{s}", .{ base_url, suffix });
}

pub fn resolveApiUrl(alloc: Allocator, base_url: []const u8, endpoint: []const u8, _provider_override: ?[]const u8) ![]u8 {
    _ = _provider_override;
    if (std.mem.endsWith(u8, base_url, "/v1")) {
        return std.fmt.allocPrint(alloc, "{s}/{s}", .{ base_url, endpoint });
    }
    return std.fmt.allocPrint(alloc, "{s}/v1/{s}", .{ base_url, endpoint });
}

fn extractImageData(alloc: Allocator, io: std.Io, body: []const u8) anyerror!?[]u8 {
    if (json.findString(body, "b64_json")) |b64_str| {
        const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(b64_str);
        const bin_buf = try alloc.alloc(u8, decoded_len);
        errdefer alloc.free(bin_buf);
        try std.base64.standard.Decoder.decode(bin_buf, b64_str);
        return bin_buf;
    }
    if (json.findString(body, "url")) |img_url| {
        var img_res = try http_lib.fetch(alloc, io, .{
            .url = img_url,
            .method = "GET",
            .max_body_size = 20 * 1024 * 1024,
            .timeout_s = 60,
        });
        defer img_res.deinit(alloc);
        if (img_res.status == 200 and img_res.body.len > 0) {
            return try alloc.dupe(u8, img_res.body);
        }
    }
    return null;
}

fn mimeToImageExtension(mime: []const u8) []const u8 {
    if (std.mem.eql(u8, mime, "image/jpeg")) return ".jpg";
    if (std.mem.eql(u8, mime, "image/webp")) return ".webp";
    if (std.mem.eql(u8, mime, "image/gif")) return ".gif";
    return ".png";
}

fn saveImageResult(
    alloc: Allocator,
    io: std.Io,
    data: []const u8,
    filename_opt: ?[]const u8,
) !MediaResult {
    const detected_mime = media_lib.sniffMimeFromMagic(data) orelse "image/png";
    const dims = media_lib.extractDimensions(data, detected_mime);
    const ext = mimeToImageExtension(detected_mime);

    const base_filename = if (filename_opt) |f| try sanitizeFilename(alloc, f) else try alloc.dupe(u8, "image");
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

    const cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(io, final_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, data);

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

fn buildImageGenRequestBody(alloc: Allocator, model: []const u8, prompt: []const u8, size: []const u8) ![]u8 {
    const escaped_prompt = try json.escape(alloc, prompt);
    defer alloc.free(escaped_prompt);
    return std.fmt.allocPrint(alloc,
        \\{{"model":"{s}","prompt":"{s}","size":"{s}","n":1,"response_format":"b64_json"}}
    , .{ model, escaped_prompt, size });
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
        return makeFailedMediaResult(alloc, "Prompt must be between 1 and 4000 characters");
    }

    const model = model_opt orelse g_config.image.model;
    const size = size_opt orelse g_config.image.size;
    const base_url = resolveBaseUrl(alloc, g_config.image.provider, g_config.image.url) catch |err| {
        return if (err == error.UnknownProvider)
            makeFailedMediaResultFmt(alloc, "Unknown image provider '{s}'. Set MINI_IMAGE_GEN_URL (and MINI_IMAGE_GEN_KEY) to configure it, or use one of: openai, openai_compat, agnes", .{g_config.image.provider})
        else err;
    };
    defer alloc.free(base_url);
    const api_url = try resolveEndpointUrl(alloc, base_url, "images/generations");
    defer alloc.free(api_url);

    const headers_json = try buildAuthHeaders(alloc, g_config.image.api_header, g_config.image.key);
    defer alloc.free(headers_json);
    const req_body = try buildImageGenRequestBody(alloc, model, prompt, size);
    defer alloc.free(req_body);

    var res = http_lib.fetch(alloc, io, .{
        .url = api_url,
        .method = "POST",
        .body = req_body,
        .headers_json = headers_json,
        .max_body_size = 20 * 1024 * 1024,
        .timeout_s = 120,
    }) catch |e| return makeFailedMediaResultFmt(alloc, "HTTP request failed: {s}", .{@errorName(e)});
    defer res.deinit(alloc);

    if (res.status < 200 or res.status >= 300) {
        const body_snippet = if (res.body.len > 256) res.body[0..256] else res.body;
        return makeFailedMediaResultFmt(alloc, "Provider returned HTTP {d}: {s}", .{ res.status, body_snippet });
    }

    const binary_data = (try extractImageData(alloc, io, res.body)) orelse
        return makeFailedMediaResult(alloc, "No image data (b64_json or url) returned in provider response");
    defer alloc.free(binary_data);

    return saveImageResult(alloc, io, binary_data, filename_opt);
}

// ---------------------------------------------------------------------------
// generate_video Tool
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

    return std.fmt.allocPrint(
        alloc,
        "Generated video: {s} ({s}, {d} bytes)",
        .{ result.path, result.media_type, result.bytes },
    );
}

fn buildVideoFilePath(alloc: Allocator, io: std.Io, filename_opt: ?[]const u8) ![]u8 {
    const base_filename = if (filename_opt) |f| try sanitizeFilename(alloc, f) else try alloc.dupe(u8, "video");
    defer alloc.free(base_filename);
    const safe_name = if (std.mem.endsWith(u8, base_filename, ".mp4"))
        try alloc.dupe(u8, base_filename)
    else
        try std.fmt.allocPrint(alloc, "{s}.mp4", .{base_filename});
    defer alloc.free(safe_name);

    const output_dir = g_config.media_output_dir orelse "media";
    try ensureOutputDir(alloc, io, output_dir);
    const ts = utils.milliTimestamp();
    return std.fmt.allocPrint(alloc, "{s}/{d}_{s}", .{ output_dir, ts, safe_name });
}

fn downloadAndSaveVideo(
    alloc: Allocator,
    io: std.Io,
    video_url: []const u8,
    headers_json: []const u8,
    filename_opt: ?[]const u8,
) !MediaResult {
    const final_path = try buildVideoFilePath(alloc, io, filename_opt);
    errdefer alloc.free(final_path);

    const dl_res = http_lib.downloadToFile(alloc, io, .{
        .url = video_url,
        .method = "GET",
        .headers_json = headers_json,
        .max_body_size = 200 * 1024 * 1024,
        .timeout_s = 300,
    }, final_path) catch |e| {
        return makeFailedMediaResultFmt(alloc, "Failed to download video: {s}", .{@errorName(e)});
    };
    defer if (dl_res.error_message) |m| alloc.free(m);

    if (dl_res.status != 200 or dl_res.total_bytes == 0) {
        const err_msg = dl_res.error_message orelse "Failed to download video content";
        return makeFailedMediaResult(alloc, err_msg);
    }

    hooks.dispatch(alloc, io, .{
        .event = "media_saved",
        .artifact_path = final_path,
        .artifact_type = "video/mp4",
    });

    return MediaResult{
        .path = final_path,
        .media_type = try alloc.dupe(u8, "video/mp4"),
        .bytes = dl_res.total_bytes,
        .ok = true,
        .message = try alloc.dupe(u8, "Video generated successfully"),
    };
}

const PollResult = struct {
    completed: bool,
    last_body: ?[]u8 = null,
    error_msg: ?[]u8 = null,

    pub fn deinit(self: *PollResult, alloc: Allocator) void {
        if (self.last_body) |b| alloc.free(b);
        if (self.error_msg) |m| alloc.free(m);
    }
};

fn pollVideoJob(
    alloc: Allocator,
    io: std.Io,
    poll_url: []const u8,
    headers_json: []const u8,
    timeout_secs: u32,
) !PollResult {
    const start_time = utils.milliTimestamp();
    const timeout_ms: i64 = @as(i64, @intCast(timeout_secs)) * 1000;
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
                return PollResult{ .completed = true, .last_body = try alloc.dupe(u8, poll_res.body) };
            } else if (std.mem.eql(u8, status, "failed")) {
                const err_msg = json.findString(poll_res.body, "error") orelse "Video generation job failed";
                return PollResult{ .completed = false, .error_msg = try alloc.dupe(u8, err_msg) };
            }
        }
        std.Io.sleep(io, std.Io.Duration.fromSeconds(1), .awake) catch {};
    }
    return PollResult{ .completed = false, .error_msg = try alloc.dupe(u8, "Video job polling timed out") };
}

fn buildVideoPollUrl(
    alloc: Allocator,
    base_url: []const u8,
    job_id: []const u8,
    video_id: []const u8,
    model: []const u8,
    is_compat: bool,
) ![]u8 {
    if (is_compat) {
        return std.fmt.allocPrint(alloc, "{s}/agnesapi?video_id={s}&model_name={s}", .{ base_url, video_id, model });
    }
    const path = try std.fmt.allocPrint(alloc, "videos/{s}", .{job_id});
    defer alloc.free(path);
    return resolveEndpointUrl(alloc, base_url, path);
}

fn resolveVideoDownloadUrl(
    alloc: Allocator,
    base_url: []const u8,
    job_id: []const u8,
    is_compat: bool,
    last_body: ?[]const u8,
) anyerror!?[]u8 {
    if (is_compat and last_body != null) {
        const vid_url = json.findString(last_body.?, "url") orelse
            json.findString(last_body.?, "video_url") orelse
            json.findString(last_body.?, "metadata.url");
        if (vid_url) |u| return try alloc.dupe(u8, u);
        return null;
    }
    const path = try std.fmt.allocPrint(alloc, "videos/{s}/content", .{job_id});
    defer alloc.free(path);
    return try resolveEndpointUrl(alloc, base_url, path);
}

fn buildVideoGenRequestBody(alloc: Allocator, model: []const u8, prompt: []const u8, seconds: u32, is_compat: bool) ![]u8 {
    const escaped_prompt = try json.escape(alloc, prompt);
    defer alloc.free(escaped_prompt);

    if (is_compat) {
        return std.fmt.allocPrint(alloc,
            \\{{"model":"{s}","prompt":"{s}","seconds":"{d}","mode":"text","size":"720P","aspect_ratio":"16:9"}}
        , .{ model, escaped_prompt, seconds });
    }
    return std.fmt.allocPrint(alloc,
        \\{{"model":"{s}","prompt":"{s}","duration":{d}}}
    , .{ model, escaped_prompt, seconds });
}

const VideoJobIds = struct {
    job_id: []const u8,
    video_id: []const u8,
};

fn extractVideoJobIds(body: []const u8) ?VideoJobIds {
    const job_id = json.findString(body, "id") orelse
        json.findString(body, "task_id") orelse
        json.findString(body, "video_id") orelse
        return null;
    const video_id = json.findString(body, "video_id") orelse job_id;
    return VideoJobIds{ .job_id = job_id, .video_id = video_id };
}

fn pollAndDownloadVideo(
    alloc: Allocator,
    io: std.Io,
    base_url: []const u8,
    ids: VideoJobIds,
    model: []const u8,
    is_compat: bool,
    headers_json: []const u8,
    filename_opt: ?[]const u8,
) !MediaResult {
    const poll_url = try buildVideoPollUrl(alloc, base_url, ids.job_id, ids.video_id, model, is_compat);
    defer alloc.free(poll_url);

    var poll_res = try pollVideoJob(alloc, io, poll_url, headers_json, g_config.video.poll_timeout_secs);
    defer poll_res.deinit(alloc);
    if (!poll_res.completed) {
        return makeFailedMediaResult(alloc, poll_res.error_msg orelse "Video job polling timed out");
    }

    const vid_url = (try resolveVideoDownloadUrl(alloc, base_url, ids.job_id, is_compat, poll_res.last_body)) orelse
        return makeFailedMediaResult(alloc, "Video completed but no metadata.url found");
    defer alloc.free(vid_url);

    return downloadAndSaveVideo(alloc, io, vid_url, headers_json, filename_opt);
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
        return makeFailedMediaResult(alloc, "Prompt cannot be empty");
    }

    const model = model_opt orelse g_config.video.model;
    const is_compat = isCompatOrAgnes(g_config.video.provider);
    const base_url = resolveBaseUrl(alloc, g_config.video.provider, g_config.video.url) catch |err| {
        return if (err == error.UnknownProvider)
            makeFailedMediaResultFmt(alloc, "Unknown video provider '{s}'. Set MINI_VIDEO_GEN_URL (and MINI_VIDEO_GEN_KEY) to configure it, or use one of: openai, openai_compat, agnes", .{g_config.video.provider})
        else err;
    };
    defer alloc.free(base_url);
    const create_url = try resolveEndpointUrl(alloc, base_url, "videos");
    defer alloc.free(create_url);

    const headers_json = try buildAuthHeaders(alloc, g_config.video.api_header, g_config.video.key);
    defer alloc.free(headers_json);
    const req_body = try buildVideoGenRequestBody(alloc, model, prompt, seconds, is_compat);
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
        return makeFailedMediaResultFmt(alloc, "Failed to start video job (HTTP {d})", .{res.status});
    }

    const ids = extractVideoJobIds(res.body) orelse
        return makeFailedMediaResult(alloc, "Video job ID missing from response");

    return pollAndDownloadVideo(alloc, io, base_url, ids, model, is_compat, headers_json, filename_opt);
}

// Provider options routing object assembly
pub const InvalidProviderOptions = error{InvalidProviderOptions};

pub fn resolveProviderOptionsJson(
    alloc: Allocator,
    provider_only: ?[]const []const u8,
    provider_order: ?[]const []const u8,
    provider_ignore: ?[]const []const u8,
    provider_sort: ?[]const u8,
    allow_fallbacks: ?bool,
    raw_options: ?[]const u8,
) anyerror!?[]u8 {
    const has_routing = provider_only != null or
        provider_order != null or
        provider_ignore != null or
        provider_sort != null or
        allow_fallbacks != null;
    if (!has_routing and raw_options == null) {
        return null;
    }

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);
    try buf.append(alloc, '{');

    var first = true;
    if (provider_only) |po| {
        if (!first) try buf.append(alloc, ',');
        first = false;
        try buf.appendSlice(alloc, "\"only\":");
        try writeStringSlice(alloc, &buf, po);
    }
    if (provider_order) |po| {
        if (!first) try buf.append(alloc, ',');
        first = false;
        try buf.appendSlice(alloc, "\"order\":");
        try writeStringSlice(alloc, &buf, po);
    }
    if (provider_ignore) |pi| {
        if (!first) try buf.append(alloc, ',');
        first = false;
        try buf.appendSlice(alloc, "\"ignore\":");
        try writeStringSlice(alloc, &buf, pi);
    }
    if (provider_sort) |ps| {
        if (!first) try buf.append(alloc, ',');
        first = false;
        try buf.appendSlice(alloc, "\"sort\":");
        try jsonEscapeString(alloc, &buf, ps);
    }
    if (allow_fallbacks) |af| {
        if (!first) try buf.append(alloc, ',');
        first = false;
        try buf.appendSlice(alloc, "\"allow_fallbacks\":");
        try buf.appendSlice(alloc, if (af) "true" else "false");
    }

    if (raw_options) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \\t\\n\\r");
        if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') {
            return error.InvalidProviderOptions;
        }
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, trimmed, .{}) catch {
            return error.InvalidProviderOptions;
        };
        defer parsed.deinit();
        if (parsed.value != .object) {
            return error.InvalidProviderOptions;
        }
        if (!first) try buf.append(alloc, ',');
        first = false;
        try buf.appendSlice(alloc, trimmed[1 .. trimmed.len - 1]);
    }

    try buf.append(alloc, '}');
    return try buf.toOwnedSlice(alloc);
}

fn writeStringSlice(alloc: Allocator, buf: *std.ArrayList(u8), items: []const []const u8) !void {
    try buf.append(alloc, '[');
    for (items, 0..) |item, i| {
        if (i > 0) try buf.append(alloc, ',');
        try jsonEscapeString(alloc, buf, item);
    }
    try buf.append(alloc, ']');
}

fn jsonEscapeString(alloc: Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '"' => try buf.appendSlice(alloc, "\""),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => |c2| try buf.append(alloc, c2),
        }
    }
    try buf.append(alloc, '"');
}


// ---------------------------------------------------------------------------
// image_attach Tool
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

    return std.fmt.allocPrint(
        alloc,
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
