//! agnes.zig — Agnes AI provider profile and URL matcher.
//!
//! Agnes AI is an OpenAI-compatible LLM provider with custom reasoning
//! field handling (delta.detail.reasoning_content).

const std = @import("std");
const base = @import("../provider.zig");
const ProviderProfile = base.ProviderProfile;

pub const key = "agnes";

pub const profile: ProviderProfile = .{
    .name = "Agnes AI",
    .protocol = .chat_completions,
    .reasoning_field = .reasoning_content,
    .echo_policy = .drop,
    .thinking_tags = .english_only,
    .reasoning_param = .top_level_effort,
    .supports_stream_options = true,
    .use_completion_tokens = false,
};

pub fn matchesUrl(url: []const u8) bool {
    return std.mem.indexOf(u8, url, "agnes") != null or
        std.mem.indexOf(u8, url, "apihub.agnes") != null;
}
