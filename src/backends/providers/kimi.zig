//! kimi.zig — Kimi / Moonshot provider profile and URL matcher (RFC-012).

const std = @import("std");
const base = @import("../provider.zig");
const ProviderProfile = base.ProviderProfile;

pub const key = "kimi";

pub const profile: ProviderProfile = .{
    .name = "Kimi / Moonshot",
    .protocol = .chat_completions,
    .reasoning_field = .reasoning_content,
    .echo_policy = .drop,
    .thinking_tags = .english_only,
    .reasoning_param = .top_level_effort,
    .supports_stream_options = true,
    .use_completion_tokens = false,
};

pub fn matchesUrl(url: []const u8) bool {
    return std.mem.indexOf(u8, url, "moonshot") != null or
        std.mem.indexOf(u8, url, "kimi") != null;
}
