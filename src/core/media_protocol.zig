//! core/media_protocol.zig — Universal Multimodal Media Protocol.
//!
//! Provides normalized types, enums, raw string passthrough, and request/response
//! structures for multimodal image and video synthesis compatible across OpenAI,
//! OpenRouter, Agnes AI, and custom proxies without vendor lock-in.

const std = @import("std");

pub const AspectRatio = enum {
    ar_1_1,
    ar_16_9,
    ar_9_16,
    ar_4_3,
    ar_3_4,
    ar_21_9,

    pub fn asString(self: AspectRatio) []const u8 {
        return switch (self) {
            .ar_1_1 => "1:1",
            .ar_16_9 => "16:9",
            .ar_9_16 => "9:16",
            .ar_4_3 => "4:3",
            .ar_3_4 => "3:4",
            .ar_21_9 => "21:9",
        };
    }

    pub fn parse(s: []const u8) ?AspectRatio {
        if (std.mem.eql(u8, s, "1:1") or std.mem.eql(u8, s, "square")) return .ar_1_1;
        if (std.mem.eql(u8, s, "16:9") or std.mem.eql(u8, s, "landscape")) return .ar_16_9;
        if (std.mem.eql(u8, s, "9:16") or std.mem.eql(u8, s, "portrait")) return .ar_9_16;
        if (std.mem.eql(u8, s, "4:3")) return .ar_4_3;
        if (std.mem.eql(u8, s, "3:4")) return .ar_3_4;
        if (std.mem.eql(u8, s, "21:9")) return .ar_21_9;
        return null;
    }
};

pub const Resolution = enum {
    res_720p,
    res_1080p,
    res_1k,
    res_2k,
    res_4k,

    pub fn asString(self: Resolution) []const u8 {
        return switch (self) {
            .res_720p => "720p",
            .res_1080p => "1080p",
            .res_1k => "1K",
            .res_2k => "2K",
            .res_4k => "4K",
        };
    }

    pub fn parse(s: []const u8) ?Resolution {
        if (std.ascii.eqlIgnoreCase(s, "720p")) return .res_720p;
        if (std.ascii.eqlIgnoreCase(s, "1080p")) return .res_1080p;
        if (std.ascii.eqlIgnoreCase(s, "1k") or std.mem.eql(u8, s, "1024x1024")) return .res_1k;
        if (std.ascii.eqlIgnoreCase(s, "2k") or std.mem.eql(u8, s, "1536x1024") or std.mem.eql(u8, s, "1024x1536")) return .res_2k;
        if (std.ascii.eqlIgnoreCase(s, "4k")) return .res_4k;
        return null;
    }
};

pub const JobState = enum {
    queued,
    processing,
    completed,
    failed,
    timeout,

    pub fn asString(self: JobState) []const u8 {
        return switch (self) {
            .queued => "queued",
            .processing => "processing",
            .completed => "completed",
            .failed => "failed",
            .timeout => "timeout",
        };
    }

    pub fn parse(s: []const u8) JobState {
        if (std.ascii.eqlIgnoreCase(s, "completed") or std.ascii.eqlIgnoreCase(s, "succeeded")) return .completed;
        if (std.ascii.eqlIgnoreCase(s, "failed") or std.ascii.eqlIgnoreCase(s, "error")) return .failed;
        if (std.ascii.eqlIgnoreCase(s, "processing") or std.ascii.eqlIgnoreCase(s, "in_progress") or std.ascii.eqlIgnoreCase(s, "running")) return .processing;
        return .queued;
    }
};

pub const LegacyCoercedSize = struct {
    res: Resolution,
    aspect: AspectRatio,
    raw: ?[]const u8 = null,
};

pub fn coerceLegacySize(size_str: []const u8) LegacyCoercedSize {
    if (std.mem.eql(u8, size_str, "1024x1024") or std.mem.eql(u8, size_str, "512x512") or std.mem.eql(u8, size_str, "256x256")) {
        return .{ .res = .res_1k, .aspect = .ar_1_1, .raw = size_str };
    }
    if (std.mem.eql(u8, size_str, "1536x1024") or std.mem.eql(u8, size_str, "1792x1024") or std.mem.eql(u8, size_str, "1280x720")) {
        return .{ .res = .res_2k, .aspect = .ar_16_9, .raw = size_str };
    }
    if (std.mem.eql(u8, size_str, "1024x1536") or std.mem.eql(u8, size_str, "1024x1792") or std.mem.eql(u8, size_str, "720x1280")) {
        return .{ .res = .res_2k, .aspect = .ar_9_16, .raw = size_str };
    }
    return .{ .res = .res_1k, .aspect = .ar_1_1, .raw = size_str };
}

pub fn coerceLegacySeconds(seconds: u32) u32 {
    if (seconds == 0) return 4;
    if (seconds > 60) return 60;
    return seconds;
}

pub const ImageGenRequest = struct {
    prompt: []const u8,
    model: ?[]const u8 = null,
    resolution: ?Resolution = null,
    raw_resolution: ?[]const u8 = null,
    aspect_ratio: ?AspectRatio = null,
    raw_aspect_ratio: ?[]const u8 = null,
    n: u8 = 1,
    filename: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    input_references: []const []const u8 = &.{},

    pub fn getAspectRatioString(self: ImageGenRequest) ?[]const u8 {
        if (self.raw_aspect_ratio) |raw| return raw;
        if (self.aspect_ratio) |ar| return ar.asString();
        return null;
    }

    pub fn getResolutionString(self: ImageGenRequest) ?[]const u8 {
        if (self.raw_resolution) |raw| return raw;
        if (self.resolution) |res| return res.asString();
        return null;
    }
};

pub const VideoGenRequest = struct {
    prompt: []const u8,
    model: ?[]const u8 = null,
    duration: u32 = 4,
    resolution: ?Resolution = null,
    raw_resolution: ?[]const u8 = null,
    aspect_ratio: ?AspectRatio = null,
    raw_aspect_ratio: ?[]const u8 = null,
    generate_audio: bool = false,
    filename: ?[]const u8 = null,
    provider: ?[]const u8 = null,

    pub fn getAspectRatioString(self: VideoGenRequest) ?[]const u8 {
        if (self.raw_aspect_ratio) |raw| return raw;
        if (self.aspect_ratio) |ar| return ar.asString();
        return null;
    }

    pub fn getResolutionString(self: VideoGenRequest) ?[]const u8 {
        if (self.raw_resolution) |raw| return raw;
        if (self.resolution) |res| return res.asString();
        return null;
    }
};
