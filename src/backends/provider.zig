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

pub const providers = @import("providers/mod.zig");

/// Built-in provider profiles.
/// Keyed by provider slug (matched from config or auto-detected from URL).
pub const profiles = [_]struct { key: []const u8, profile: ProviderProfile }{
    .{ .key = providers.openai.key, .profile = providers.openai.profile },
    .{ .key = providers.deepseek.key, .profile = providers.deepseek.profile },
    .{ .key = providers.qwen.key, .profile = providers.qwen.profile },
    .{ .key = providers.minimax.key, .profile = providers.minimax.profile },
    .{ .key = providers.glm.key, .profile = providers.glm.profile },
    .{ .key = providers.kimi.key, .profile = providers.kimi.profile },
    .{ .key = providers.xai.key, .profile = providers.xai.profile },
    .{ .key = providers.vllm.key, .profile = providers.vllm.profile },
    .{ .key = providers.generic.key, .profile = providers.generic.profile },
};

/// Lookup profile by key. Returns generic if not found.
pub fn getProfile(key: []const u8) ProviderProfile {
    for (profiles) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry.profile;
    }
    return getProfile(providers.generic.key);
}

/// Auto-detect provider from base URL.
pub fn detectFromUrl(url: []const u8) []const u8 {
    if (providers.deepseek.matchesUrl(url)) return providers.deepseek.key;
    if (providers.qwen.matchesUrl(url)) return providers.qwen.key;
    if (providers.minimax.matchesUrl(url)) return providers.minimax.key;
    if (providers.glm.matchesUrl(url)) return providers.glm.key;
    if (providers.kimi.matchesUrl(url)) return providers.kimi.key;
    if (providers.xai.matchesUrl(url)) return providers.xai.key;
    if (providers.openai.matchesUrl(url)) return providers.openai.key;
    if (providers.vllm.matchesUrl(url)) return providers.vllm.key;
    return providers.generic.key;
}

/// Resolve profile from explicit key or auto-detected URL.
pub fn resolveProfile(explicit_key: ?[]const u8, url: ?[]const u8) ProviderProfile {
    // RFC-012 §3.3: an explicit, non-empty provider key always wins;
    // URL auto-detection applies only when no explicit key is given.
    if (explicit_key) |k| {
        if (k.len > 0) return getProfile(k);
    }
    if (url) |u| {
        if (u.len > 0) {
            const detected = detectFromUrl(u);
            return getProfile(detected);
        }
    }
    return getProfile("generic");
}
