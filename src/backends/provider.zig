//! provider.zig — Provider Abstraction Layer (RFC-012).
//!
//! Static profiles describing provider-specific wire protocol quirks.
//! Normalizes differences in:
//! - Wire protocol: Chat Completions API vs Responses API vs Auto-negotiate
//! - Reasoning field: reasoning_content vs reasoning vs both
//! - Echo policy: drop vs echo_required in assistant message history
//! - Thinking tag sets: English only vs English and Chinese variants
//! - Reasoning parameter format: top-level effort vs nested object vs unsupported
//! - Feature flags: stream_options, use_completion_tokens

const std = @import("std");

pub const WireProtocol = enum {
    /// OpenAI Chat Completions API (POST /v1/chat/completions)
    chat_completions,
    /// OpenAI Responses API (POST /v1/responses)
    responses,
    /// Try Responses first, fallback to Chat Completions (default auto-negotiate)
    auto,
};

pub const ReasoningField = enum {
    /// delta.reasoning_content (DeepSeek, Qwen, MiniMax, GLM, Moonshot)
    reasoning_content,
    /// delta.reasoning (OpenAI o-series, GPT-5.x, vLLM ≥0.23)
    reasoning,
    /// Both fields checked with fallback
    both,
};

pub const EchoPolicy = enum {
    /// Do NOT send reasoning back in history (default, most providers)
    drop,
    /// MUST echo reasoning_content in assistant message history (DeepSeek)
    echo_required,
    /// Echo if available but don't fail if missing
    echo_optional,
};

pub const ThinkingTagSet = enum {
    /// Only <think>...</think> (English standard)
    english_only,
    /// English + Chinese variants: <思考>, <推理>, <反思>, <推敲>
    english_and_chinese,
    /// No tag-based thinking (uses reasoning_content field only)
    none,
};

pub const ReasoningParamFormat = enum {
    /// Top-level "reasoning_effort": "medium" (OpenAI Chat Completions)
    top_level_effort,
    /// Nested "reasoning": {"effort": "medium"} (OpenAI Responses API)
    nested_reasoning_object,
    /// No reasoning parameter supported (DeepSeek, MiniMax, GLM)
    unsupported,
};

/// Static profile describing a provider's wire protocol quirks.
pub const ProviderProfile = struct {
    /// Human-readable provider name.
    name: []const u8,
    /// Wire protocol to use.
    protocol: WireProtocol,
    /// Which JSON field carries reasoning deltas.
    reasoning_field: ReasoningField,
    /// Whether to echo reasoning in multi-turn history.
    echo_policy: EchoPolicy,
    /// Which thinking tags to parse/strip from content.
    thinking_tags: ThinkingTagSet,
    /// How to format reasoning effort parameter in request.
    reasoning_param: ReasoningParamFormat,
    /// Whether provider supports stream_options.include_usage.
    supports_stream_options: bool,
    /// Whether provider supports max_completion_tokens (vs max_tokens).
    use_completion_tokens: bool,
};

/// Built-in provider profiles.
/// Keyed by provider slug (matched from config or auto-detected from URL).
pub const profiles = [_]struct { key: []const u8, profile: ProviderProfile }{
    // ── OpenAI Official ──
    .{ .key = "openai", .profile = .{
        .name = "OpenAI",
        .protocol = .auto,
        .reasoning_field = .reasoning,
        .echo_policy = .drop,
        .thinking_tags = .none,
        .reasoning_param = .top_level_effort,
        .supports_stream_options = true,
        .use_completion_tokens = true,
    } },

    // ── DeepSeek ──
    .{ .key = "deepseek", .profile = .{
        .name = "DeepSeek",
        .protocol = .chat_completions, // Never use Responses API
        .reasoning_field = .reasoning_content,
        .echo_policy = .echo_required, // MUST echo reasoning_content
        .thinking_tags = .none,
        .reasoning_param = .unsupported, // DeepSeek ignores/rejects reasoning_effort
        .supports_stream_options = true,
        .use_completion_tokens = false,
    } },

    // ── Qwen / DashScope (Alibaba Cloud) ──
    .{ .key = "qwen", .profile = .{
        .name = "Qwen / DashScope",
        .protocol = .chat_completions,
        .reasoning_field = .both,
        .echo_policy = .drop,
        .thinking_tags = .english_and_chinese,
        .reasoning_param = .top_level_effort,
        .supports_stream_options = true,
        .use_completion_tokens = false,
    } },

    // ── MiniMax ──
    .{ .key = "minimax", .profile = .{
        .name = "MiniMax",
        .protocol = .chat_completions,
        .reasoning_field = .reasoning_content,
        .echo_policy = .drop,
        .thinking_tags = .english_and_chinese,
        .reasoning_param = .unsupported,
        .supports_stream_options = false,
        .use_completion_tokens = false,
    } },

    // ── GLM / ZhipuAI ──
    .{ .key = "glm", .profile = .{
        .name = "GLM / ZhipuAI",
        .protocol = .chat_completions,
        .reasoning_field = .reasoning_content,
        .echo_policy = .drop,
        .thinking_tags = .english_and_chinese,
        .reasoning_param = .unsupported,
        .supports_stream_options = false,
        .use_completion_tokens = false,
    } },

    // ── Kimi / Moonshot ──
    .{ .key = "kimi", .profile = .{
        .name = "Kimi / Moonshot",
        .protocol = .chat_completions,
        .reasoning_field = .reasoning_content,
        .echo_policy = .drop,
        .thinking_tags = .english_only,
        .reasoning_param = .top_level_effort,
        .supports_stream_options = true,
        .use_completion_tokens = false,
    } },

    // ── xAI (Grok) ──
    .{ .key = "xai", .profile = .{
        .name = "xAI Grok",
        .protocol = .responses,
        .reasoning_field = .reasoning,
        .echo_policy = .drop,
        .thinking_tags = .none,
        .reasoning_param = .nested_reasoning_object,
        .supports_stream_options = true,
        .use_completion_tokens = true,
    } },

    // ── vLLM ──
    .{ .key = "vllm", .profile = .{
        .name = "vLLM",
        .protocol = .chat_completions,
        .reasoning_field = .both,
        .echo_policy = .drop,
        .thinking_tags = .english_only,
        .reasoning_param = .top_level_effort,
        .supports_stream_options = true,
        .use_completion_tokens = false,
    } },

    // ── Generic (default fallback) ──
    .{ .key = "generic", .profile = .{
        .name = "Generic OpenAI-compat",
        .protocol = .auto,
        .reasoning_field = .both,
        .echo_policy = .drop,
        .thinking_tags = .english_only,
        .reasoning_param = .top_level_effort,
        .supports_stream_options = true,
        .use_completion_tokens = false,
    } },
};

/// Lookup profile by key. Returns generic if not found.
pub fn getProfile(key: []const u8) ProviderProfile {
    for (profiles) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry.profile;
    }
    return getProfile("generic");
}

/// Auto-detect provider from base URL.
pub fn detectFromUrl(url: []const u8) []const u8 {
    if (std.mem.indexOf(u8, url, "deepseek") != null) return "deepseek";
    if (std.mem.indexOf(u8, url, "dashscope") != null or
        std.mem.indexOf(u8, url, "qwen") != null or
        std.mem.indexOf(u8, url, "aliyun") != null) return "qwen";
    if (std.mem.indexOf(u8, url, "minimax") != null) return "minimax";
    if (std.mem.indexOf(u8, url, "zhipuai") != null or
        std.mem.indexOf(u8, url, "bigmodel") != null or
        std.mem.indexOf(u8, url, "glm") != null) return "glm";
    if (std.mem.indexOf(u8, url, "moonshot") != null or
        std.mem.indexOf(u8, url, "kimi") != null) return "kimi";
    if (std.mem.indexOf(u8, url, "x.ai") != null or
        std.mem.indexOf(u8, url, "grok") != null) return "xai";
    if (std.mem.indexOf(u8, url, "openai.com") != null) return "openai";
    if (std.mem.indexOf(u8, url, "vllm") != null) return "vllm";
    return "generic";
}

/// Resolve profile from explicit key or auto-detected URL.
pub fn resolveProfile(explicit_key: ?[]const u8, url: ?[]const u8) ProviderProfile {
    if (explicit_key) |k| {
        if (k.len > 0 and !std.mem.eql(u8, k, "generic")) {
            return getProfile(k);
        }
    }
    if (url) |u| {
        const detected = detectFromUrl(u);
        if (!std.mem.eql(u8, detected, "generic")) {
            return getProfile(detected);
        }
    }
    return getProfile("generic");
}
