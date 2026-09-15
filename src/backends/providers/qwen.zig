//! qwen.zig — Qwen / DashScope (Alibaba Cloud) provider profile and URL matcher (RFC-012).

const std = @import("std");
const base = @import("../provider.zig");
const ProviderProfile = base.ProviderProfile;

pub const key = "qwen";

pub const profile: ProviderProfile = .{
    .name = "Qwen / DashScope",
    .protocol = .chat_completions,
    .reasoning_field = .both,
    .echo_policy = .drop,
    .thinking_tags = .english_and_chinese,
    .reasoning_param = .top_level_effort,
    .supports_stream_options = true,
    .use_completion_tokens = false,
};

pub fn matchesUrl(url: []const u8) bool {
    return std.mem.indexOf(u8, url, "dashscope") != null or
        std.mem.indexOf(u8, url, "qwen") != null or
        std.mem.indexOf(u8, url, "aliyun") != null;
}
