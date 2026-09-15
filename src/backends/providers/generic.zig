//! generic.zig — Generic OpenAI-compatible fallback provider profile (RFC-012).

const base = @import("../provider.zig");
const ProviderProfile = base.ProviderProfile;

pub const key = "generic";

pub const profile: ProviderProfile = .{
    .name = "Generic OpenAI-compat",
    .protocol = .auto,
    .reasoning_field = .both,
    .echo_policy = .drop,
    .thinking_tags = .english_only,
    .reasoning_param = .top_level_effort,
    .supports_stream_options = true,
    .use_completion_tokens = false,
};

pub fn matchesUrl(url: []const u8) bool {
    _ = url;
    return false;
}
