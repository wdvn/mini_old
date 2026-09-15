//! xai.zig — xAI (Grok) provider profile and URL matcher (RFC-012).

const std = @import("std");
const base = @import("../provider.zig");
const ProviderProfile = base.ProviderProfile;

pub const key = "xai";

pub const profile: ProviderProfile = .{
    .name = "xAI Grok",
    .protocol = .responses,
    .reasoning_field = .reasoning,
    .echo_policy = .drop,
    .thinking_tags = .none,
    .reasoning_param = .nested_reasoning_object,
    .supports_stream_options = true,
    .use_completion_tokens = true,
};

pub fn matchesUrl(url: []const u8) bool {
    return std.mem.indexOf(u8, url, "x.ai") != null or
        std.mem.indexOf(u8, url, "grok") != null;
}
