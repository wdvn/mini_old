//! media.zig — Media I/O helper library for mini-agent.
//!
//! Provides:
//!   - Strict MIME sniffing via magic bytes (PNG, JPEG, WEBP, GIF, MP4)
//!   - Image file ingestion: size verification, dimension extraction, Base64 encoding
//!   - Prompt parser for `@image:<path>` tokens with space escape support

const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("../core/protocol.zig");
const utils = @import("../core/utils.zig");

pub const ImageLimits = struct {
    max_bytes: usize = 10 * 1024 * 1024, // 10MB
    max_per_turn: u8 = 5,
};

pub const ReadImageResult = struct {
    data: []const u8, // Base64 without data: prefix
    media_type: []const u8,
    bytes: usize,
    width: u32 = 0,
    height: u32 = 0,

    pub fn deinit(self: ReadImageResult, alloc: Allocator) void {
        alloc.free(self.data);
    }
};

/// Sniff MIME strictly by magic bytes.
/// Does NOT rely on file extensions to avoid polyglot security issues.
pub fn sniffMimeFromMagic(data: []const u8) ?[]const u8 {
    if (data.len >= 8 and std.mem.eql(u8, data[0..8], "\x89PNG\r\n\x1a\n")) {
        return "image/png";
    }
    if (data.len >= 3 and data[0] == 0xFF and data[1] == 0xD8 and data[2] == 0xFF) {
        return "image/jpeg";
    }
    if (data.len >= 12 and std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WEBP")) {
        return "image/webp";
    }
    if (data.len >= 6 and (std.mem.eql(u8, data[0..6], "GIF87a") or std.mem.eql(u8, data[0..6], "GIF89a"))) {
        return "image/gif";
    }
    return null;
}

/// Detect MIME type with magic bytes first, fallback to extension.
pub fn detectMimeType(data: []const u8, filename: []const u8) []const u8 {
    if (sniffMimeFromMagic(data)) |mime| {
        return mime;
    }
    if (data.len >= 8 and std.mem.indexOf(u8, data[0..@min(data.len, 32)], "ftyp") != null) {
        return "video/mp4";
    }

    // Extension fallback (case-insensitive)
    if (filename.len >= 4) {
        const ext4 = filename[filename.len - 4 ..];
        if (std.ascii.eqlIgnoreCase(ext4, ".png")) return "image/png";
        if (std.ascii.eqlIgnoreCase(ext4, ".jpg")) return "image/jpeg";
        if (std.ascii.eqlIgnoreCase(ext4, ".gif")) return "image/gif";
        if (std.ascii.eqlIgnoreCase(ext4, ".mp4")) return "video/mp4";
    }
    if (filename.len >= 5) {
        const ext5 = filename[filename.len - 5 ..];
        if (std.ascii.eqlIgnoreCase(ext5, ".jpeg")) return "image/jpeg";
        if (std.ascii.eqlIgnoreCase(ext5, ".webp")) return "image/webp";
    }

    return "application/octet-stream";
}

pub const ImageDimensions = struct { width: u32, height: u32 };

fn extractWebpDimensions(data: []const u8) ImageDimensions {
    // PSEUDOCODE:
    // 1. Check VP8 lossy header (data[12..16] == "VP8 ")
    // 2. Check VP8L lossless header (data[12..16] == "VP8L")
    // 3. Read width and height bits according to WebP specification
    var width: u32 = 0;
    var height: u32 = 0;
    if (std.mem.eql(u8, data[12..16], "VP8 ") and data.len >= 30) {
        const raw_w = std.mem.readInt(u16, data[26..28][0..2], .little);
        const raw_h = std.mem.readInt(u16, data[28..30][0..2], .little);
        width = raw_w & 0x3FFF;
        height = raw_h & 0x3FFF;
    } else if (std.mem.eql(u8, data[12..16], "VP8L") and data.len >= 25) {
        const b0 = data[21];
        const b1 = data[22];
        const b2 = data[23];
        const b3 = data[24];
        width = 1 + (@as(u32, b0) | ((@as(u32, b1) & 0x3F) << 8));
        height = 1 + (((@as(u32, b1) >> 6) | (@as(u32, b2) << 2) | ((@as(u32, b3) & 0x0F) << 10)));
    }
    return .{ .width = width, .height = height };
}

fn extractJpegDimensions(data: []const u8) ImageDimensions {
    // PSEUDOCODE:
    // 1. Scan JPEG segments starting after initial SOI marker
    // 2. Identify SOF0/SOF1/SOF2 markers (0xFFC0, 0xFFC1, 0xFFC2)
    // 3. Parse height and width in big-endian, or stop on EOI/SOS
    var width: u32 = 0;
    var height: u32 = 0;
    var i: usize = 2;
    while (i + 8 < data.len) {
        if (data[i] != 0xFF) {
            i += 1;
            continue;
        }
        const marker = data[i + 1];
        if (marker == 0xC0 or marker == 0xC1 or marker == 0xC2) {
            height = std.mem.readInt(u16, data[i + 5 .. i + 7][0..2], .big);
            width = std.mem.readInt(u16, data[i + 7 .. i + 9][0..2], .big);
            break;
        }
        if (marker == 0xD9 or marker == 0xDA) break;
        if (i + 4 <= data.len) {
            const seg_len = std.mem.readInt(u16, data[i + 2 .. i + 4][0..2], .big);
            i += 2 + seg_len;
        } else {
            break;
        }
    }
    return .{ .width = width, .height = height };
}

/// Extract image dimensions (width, height) from header if possible.
pub fn extractDimensions(data: []const u8, mime: []const u8) ImageDimensions {
    // PSEUDOCODE:
    // 1. Identify image format by mime type
    // 2. Parse PNG / GIF directly from standard header offsets
    // 3. Delegate WebP and JPEG parsing to dedicated helper functions
    if (std.mem.eql(u8, mime, "image/png") and data.len >= 24) {
        return .{
            .width = std.mem.readInt(u32, data[16..20][0..4], .big),
            .height = std.mem.readInt(u32, data[20..24][0..4], .big),
        };
    } else if (std.mem.eql(u8, mime, "image/gif") and data.len >= 10) {
        return .{
            .width = std.mem.readInt(u16, data[6..8][0..2], .little),
            .height = std.mem.readInt(u16, data[8..10][0..2], .little),
        };
    } else if (std.mem.eql(u8, mime, "image/webp") and data.len >= 30) {
        return extractWebpDimensions(data);
    } else if (std.mem.eql(u8, mime, "image/jpeg")) {
        return extractJpegDimensions(data);
    }
    return .{ .width = 0, .height = 0 };
}

/// Read image from disk, validate size/magic bytes, and return base64-encoded result.
pub fn readImageFile(alloc: Allocator, io: std.Io, path: []const u8, limits: ImageLimits) !ReadImageResult {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.size == 0) return error.EmptyFile;
    if (stat.size > limits.max_bytes) return error.FileTooLarge;

    const raw_bytes = try alloc.alloc(u8, @intCast(stat.size));
    defer alloc.free(raw_bytes);

    const n = try utils.readAll(io, file, raw_bytes);
    const content = raw_bytes[0..n];

    const mime = sniffMimeFromMagic(content) orelse return error.UnsupportedImageFormat;
    const dims = extractDimensions(content, mime);

    // Calculate exact base64 size and encode
    const b64_len = std.base64.standard.Encoder.calcSize(content.len);
    const b64_buf = try alloc.alloc(u8, b64_len);
    _ = std.base64.standard.Encoder.encode(b64_buf, content);

    return .{
        .data = b64_buf,
        .media_type = mime,
        .bytes = content.len,
        .width = dims.width,
        .height = dims.height,
    };
}

pub const PromptParseResult = struct {
    clean_text: []const u8,
    images: []proto.ImageBlock,

    pub fn deinit(self: PromptParseResult, alloc: Allocator) void {
        alloc.free(self.clean_text);
        for (self.images) |img| {
            alloc.free(img.data);
            alloc.free(img.media_type);
        }
        alloc.free(self.images);
    }
};

fn parseImageToken(
    alloc: Allocator,
    io: std.Io,
    input: []const u8,
    i: usize,
    limits: ImageLimits,
    images_list: *std.ArrayListUnmanaged(proto.ImageBlock),
) !usize {
    // PSEUDOCODE:
    // 1. Verify images count does not exceed max_per_turn
    // 2. Parse escaped path after "@image:" marker
    // 3. Read image file and append to images_list
    // 4. Return new character index after image token
    if (images_list.items.len >= limits.max_per_turn) {
        return error.TooManyImagesPerTurn;
    }

    const path_start = i + "@image:".len;
    var path_end = path_start;
    var path_buf = std.ArrayList(u8).empty;
    defer path_buf.deinit(alloc);

    while (path_end < input.len) {
        if (input[path_end] == '\\' and path_end + 1 < input.len and input[path_end + 1] == ' ') {
            try path_buf.append(alloc, ' ');
            path_end += 2;
        } else if (input[path_end] == ' ' or input[path_end] == '\t' or input[path_end] == '\n' or input[path_end] == '\r') {
            break;
        } else {
            try path_buf.append(alloc, input[path_end]);
            path_end += 1;
        }
    }

    if (path_buf.items.len > 0) {
        var img_res = try readImageFile(alloc, io, path_buf.items, limits);
        errdefer img_res.deinit(alloc);
        try images_list.append(alloc, .{
            .data = img_res.data,
            .media_type = try alloc.dupe(u8, img_res.media_type),
        });
    }

    return path_end;
}

/// Scans prompt for `@image:<path>` tokens with space escaping (`\ `).
/// Extracts image blocks via `readImageFile` and returns cleaned prompt text.
pub fn parsePromptImages(
    alloc: Allocator,
    io: std.Io,
    input: []const u8,
    limits: ImageLimits,
) !PromptParseResult {
    // PSEUDOCODE:
    // 1. Scan input string, delegating "@image:" tokens to parseImageToken
    // 2. Collapse consecutive whitespace in clean_buf
    // 3. Return trimmed clean text and populated images slice
    var images_list = std.ArrayListUnmanaged(proto.ImageBlock).empty;
    errdefer {
        for (images_list.items) |img| {
            alloc.free(img.data);
            alloc.free(img.media_type);
        }
        images_list.deinit(alloc);
    }

    var clean_buf = std.ArrayList(u8).empty;
    defer clean_buf.deinit(alloc);

    var i: usize = 0;
    while (i < input.len) {
        if (std.mem.startsWith(u8, input[i..], "@image:")) {
            i = try parseImageToken(alloc, io, input, i, limits, &images_list);
        } else {
            const ch = input[i];
            if (!(ch == ' ' and clean_buf.items.len > 0 and clean_buf.items[clean_buf.items.len - 1] == ' ')) {
                try clean_buf.append(alloc, ch);
            }
            i += 1;
        }
    }

    const trimmed = std.mem.trim(u8, clean_buf.items, " \t\r\n");
    return .{
        .clean_text = try alloc.dupe(u8, trimmed),
        .images = try images_list.toOwnedSlice(alloc),
    };
}
