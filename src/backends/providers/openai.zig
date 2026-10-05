//! openai.zig — OpenAI official provider profile and URL matcher.

const std = @import("std");
const base = @import("../provider.zig");
const ProviderProfile = base.ProviderProfile;

pub const key = "openai";

pub const profile: ProviderProfile = .{
    .name = "OpenAI",
    .protocol = .auto,
    .reasoning_field = .reasoning,
    .echo_policy = .drop,
    .thinking_tags = .none,
    .reasoning_param = .top_level_effort,
    .supports_stream_options = true,
    .use_completion_tokens = true,
};

pub fn matchesUrl(url: []const u8) bool {
    return std.mem.indexOf(u8, url, "openai.com") != null;
}
