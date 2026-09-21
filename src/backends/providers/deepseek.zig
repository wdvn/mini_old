//! deepseek.zig — DeepSeek provider profile and URL matcher (RFC-012).

const std = @import("std");
const base = @import("../provider.zig");
const ProviderProfile = base.ProviderProfile;

pub const key = "deepseek";

pub const profile: ProviderProfile = .{
    .name = "DeepSeek",
    .protocol = .chat_completions, // Never use Responses API
    .reasoning_field = .reasoning_content,
    .echo_policy = .echo_required, // MUST echo reasoning_content
    .thinking_tags = .none,
    .reasoning_param = .unsupported, // DeepSeek ignores/rejects reasoning_effort
    .supports_stream_options = true,
    .use_completion_tokens = false,
};

pub fn matchesUrl(url: []const u8) bool {
    return std.mem.indexOf(u8, url, "deepseek") != null;
}
