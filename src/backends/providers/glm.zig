//! glm.zig — GLM / ZhipuAI provider profile and URL matcher (RFC-012).

const std = @import("std");
const base = @import("../provider.zig");
const ProviderProfile = base.ProviderProfile;

pub const key = "glm";

pub const profile: ProviderProfile = .{
    .name = "GLM / ZhipuAI",
    .protocol = .chat_completions,
    .reasoning_field = .reasoning_content,
    .echo_policy = .drop,
    .thinking_tags = .english_and_chinese,
    .reasoning_param = .unsupported,
    .supports_stream_options = false,
    .use_completion_tokens = false,
};

pub fn matchesUrl(url: []const u8) bool {
    return std.mem.indexOf(u8, url, "zhipuai") != null or
        std.mem.indexOf(u8, url, "bigmodel") != null or
        std.mem.indexOf(u8, url, "glm") != null;
}
