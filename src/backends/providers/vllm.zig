//! vllm.zig — vLLM provider profile and URL matcher.

const std = @import("std");
const base = @import("../provider.zig");
const ProviderProfile = base.ProviderProfile;

pub const key = "vllm";

pub const profile: ProviderProfile = .{
    .name = "vLLM",
    .protocol = .chat_completions,
    .reasoning_field = .both,
    .echo_policy = .drop,
    .thinking_tags = .english_only,
    .reasoning_param = .top_level_effort,
    .supports_stream_options = true,
    .use_completion_tokens = false,
};

pub fn matchesUrl(url: []const u8) bool {
    return std.mem.indexOf(u8, url, "vllm") != null;
}
