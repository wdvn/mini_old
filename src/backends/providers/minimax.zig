//! minimax.zig — MiniMax provider profile and URL matcher (RFC-012).

const std = @import("std");
const base = @import("../provider.zig");
const ProviderProfile = base.ProviderProfile;

pub const key = "minimax";

pub const profile: ProviderProfile = .{
    .name = "MiniMax",
    .protocol = .chat_completions,
    .reasoning_field = .reasoning_content,
    .echo_policy = .drop,
    .thinking_tags = .english_and_chinese,
    .reasoning_param = .unsupported,
    .supports_stream_options = false,
    .use_completion_tokens = false,
};

pub fn matchesUrl(url: []const u8) bool {
    return std.mem.indexOf(u8, url, "minimax") != null;
}
