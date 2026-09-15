# RFC-012: Provider Abstraction Layer — Unified Wire Protocol Normalization

| Attribute | Value |
|---|---|
| RFC | 012 |
| Title | Provider Abstraction Layer — Unified Wire Protocol Normalization for Multi-Provider Compatibility |
| Status | **Proposed** |
| Version | 0.1 |
| Dependencies | RFC-006 (SSE parsing), RFC-009 (reasoning effort), RFC-001 (CodeAct architecture) |
| References | [DeepSeek API](https://api-docs.deepseek.com/api/create-chat-completion), [Qwen DashScope](https://help.aliyun.com/zh/model-studio/), [MiniMax API](https://platform.minimaxi.com/document/ChatCompletion), [OpenAI Responses API](https://platform.openai.com/docs/api-reference/responses) |
| Author | mini-agent |
| Date | 2026-09-15 |

---

## 1. Motivation

### 1.1. Problem: Single Client Serving Incompatible Providers

`src/backends/openai.zig` is a **monolithic client** serving all OpenAI-compatible providers through a single code path. This worked when providers closely followed OpenAI's Chat Completions spec, but the ecosystem has **fragmented into 3+ incompatible wire protocol variants**:

```
┌─────────────────────────────────────────────────────────────┐
│  Current Architecture (Broken for many providers)           │
│                                                             │
│  Agent ──► openai.zig ──► Auto-Negotiate Protocol ──► ANY   │
│                           (responses vs chat)       Provider│
│                                                             │
│  Problems:                                                  │
│  • Agnes AI: accepts /v1/responses HTTP 200 but drops text  │
│  • DeepSeek: needs reasoning echo-back, mini doesn't send   │
│  • MiniMax: leaks Chinese thinking tags into content         │
│  • Qwen: uses <think> tags, not reasoning_content field     │
└─────────────────────────────────────────────────────────────┘
```

### 1.2. Root Cause Analysis (Provider Compatibility Gaps)

| # | Gap | Impact |
|---|---|---|
| G1 | **No per-provider protocol selection** | Auto-negotiate sends Responses API to providers that accept it syntactically but don't implement it correctly (Agnes AI, SiliconFlow proxies) |
| G2 | **No reasoning echo-back** | DeepSeek requires `reasoning_content` in assistant message history; mini drops it → HTTP 400 on multi-turn |
| G3 | **No Chinese thinking tag filter** | MiniMax/GLM leak `<思考>`, `<推理>`, `<反思>` tags into `content`; `StreamEventParser` only handles `<think>` |
| G4 | **No provider-specific profile configuration** | Monolithic client treats all endpoints with identical parameters, missing endpoint-tailored quirks |
| G5 | **No adaptive parameter mapping** | `reasoning_effort` vs `reasoning.effort` vs `thinking.budget_tokens` differs per provider; mini sends one format blindly |

### 1.3. Design Goal

Introduce a **Provider Abstraction Layer** that normalizes the data flow:

```
┌──────────────────────────────────────────────────────────────────────────┐
│  RFC-012 Architecture                                                    │
│                                                                          │
│  Agent Loop ──► proto.Message[] ──► ProviderAdapter.encodeRequest()      │
│  (standard)     (standard)         ├─ select protocol (chat/responses)   │
│                                    ├─ serialize reasoning echo policy    │
│                                    ├─ map reasoning_effort format        │
│                                    └─► provider-specific HTTP body       │
│                                                │                         │
│                                                ▼                         │
│                                         HTTP POST (SSE)                  │
│                                                │                         │
│                                                ▼                         │
│  Agent Loop ◄── proto.Response ◄── ProviderAdapter.normalizeResponse()  │
│  (standard)     (standard)         ├─ strip provider-specific tags       │
│                                    ├─ normalize reasoning fields         │
│                                    └─ map stop_reason variants           │
└──────────────────────────────────────────────────────────────────────────┘
```

**Key Principle**: The agent loop (`src/core/agent.zig`) and CodeAct runtime (`src/runtime/`) **never see provider-specific details**. All provider quirks are isolated inside `ProviderAdapter`.

---

## 2. Objectives & Non-Goals

### Objectives

1. **Provider Profile Registry**: Static lookup table mapping provider names to protocol, echo policy, tag filters, and parameter format.
2. **Request Normalization**: `proto.Message[]` → provider-specific wire format (protocol selection, reasoning echo, parameter mapping).
3. **Response Normalization**: Provider-specific SSE stream → `proto.Response` (tag stripping, field unification, stop_reason mapping).
4. **Auto-Detection**: Infer provider from base URL when not explicitly configured (e.g. `api.deepseek.com` → `deepseek` profile).
5. **Backward Compatibility**: Default `generic` profile behaves identically to current code.

### Non-Goals

- Adding new backend types (Anthropic, Ollama remain separate).
- Modifying the agent loop or CodeAct protocol.
- Runtime provider switching mid-session.
- Supporting non-OpenAI-compatible APIs through this layer.

---

## 3. Detailed Design

### 3.1. Provider Profile (`src/backends/provider.zig` — NEW)

```zig
//! provider.zig — Provider Abstraction Layer (RFC-012).
//!
//! Static profiles describing provider-specific wire protocol quirks.
//! The agent loop and CodeAct runtime never import this module directly;
//! openai.zig consults it during request building and response parsing.

pub const WireProtocol = enum {
    /// OpenAI Chat Completions API (POST /v1/chat/completions)
    chat_completions,
    /// OpenAI Responses API (POST /v1/responses)
    responses,
    /// Try Responses first, fallback to Chat Completions (current default)
    auto,
};

pub const ReasoningField = enum {
    /// delta.reasoning_content (DeepSeek, Qwen, MiniMax, most Chinese models)
    reasoning_content,
    /// delta.reasoning (OpenAI o-series, GPT-5.x, vLLM ≥0.23)
    reasoning,
    /// Both fields checked with fallback (current behavior)
    both,
};

pub const EchoPolicy = enum {
    /// Do NOT send reasoning back in history (default, most providers)
    drop,
    /// MUST echo reasoning_content in assistant message history (DeepSeek)
    echo_required,
    /// Echo if available but don't fail if missing (Qwen hybrid)
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
    /// No reasoning parameter supported
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
```

### 3.2. Built-in Provider Registry & Modular Structure

Each provider profile is encapsulated in its own dedicated file under `src/backends/providers/` (`openai.zig`, `deepseek.zig`, `qwen.zig`, `minimax.zig`, `glm.zig`, `kimi.zig`, `xai.zig`, `vllm.zig`, `generic.zig`), defining its identifier, `ProviderProfile`, and endpoint URL matcher:

```zig
//! src/backends/providers/deepseek.zig
pub const key = "deepseek";
pub const profile: ProviderProfile = .{
    .name = "DeepSeek",
    .protocol = .chat_completions,
    .reasoning_field = .reasoning_content,
    .echo_policy = .echo_required,
    .thinking_tags = .none,
    .reasoning_param = .unsupported,
    .supports_stream_options = true,
    .use_completion_tokens = false,
};
pub fn matchesUrl(url: []const u8) bool {
    return std.mem.indexOf(u8, url, "deepseek") != null;
}
```

`src/backends/provider.zig` aggregates all provider submodules and exports unified lookups:

```zig
pub const providers = @import("providers/mod.zig");

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
    }},

    // ── DeepSeek ──
    .{ .key = "deepseek", .profile = .{
        .name = "DeepSeek",
        .protocol = .chat_completions,          // Never use Responses API
        .reasoning_field = .reasoning_content,
        .echo_policy = .echo_required,           // MUST echo reasoning_content
        .thinking_tags = .none,
        .reasoning_param = .unsupported,         // DeepSeek ignores reasoning_effort
        .supports_stream_options = true,
        .use_completion_tokens = false,
    }},

    // ── Qwen / DashScope (Alibaba) ──
    .{ .key = "qwen", .profile = .{
        .name = "Qwen / DashScope",
        .protocol = .chat_completions,
        .reasoning_field = .both,
        .echo_policy = .drop,
        .thinking_tags = .english_and_chinese,   // Qwen uses <think> tags in content
        .reasoning_param = .top_level_effort,
        .supports_stream_options = true,
        .use_completion_tokens = false,
    }},

    // ── MiniMax ──
    .{ .key = "minimax", .profile = .{
        .name = "MiniMax",
        .protocol = .chat_completions,
        .reasoning_field = .reasoning_content,
        .echo_policy = .drop,
        .thinking_tags = .english_and_chinese,   // Known to leak Chinese tags
        .reasoning_param = .unsupported,
        .supports_stream_options = false,
        .use_completion_tokens = false,
    }},

    // ── GLM / z.ai (ZhipuAI) ──
    .{ .key = "glm", .profile = .{
        .name = "GLM / ZhipuAI",
        .protocol = .chat_completions,
        .reasoning_field = .reasoning_content,
        .echo_policy = .drop,
        .thinking_tags = .english_and_chinese,
        .reasoning_param = .unsupported,
        .supports_stream_options = false,
        .use_completion_tokens = false,
    }},

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
    }},

    // ── xAI (Grok) ──
    .{ .key = "xai", .profile = .{
        .name = "xAI Grok",
        .protocol = .responses,                  // xAI requires Responses API
        .reasoning_field = .reasoning,
        .echo_policy = .drop,
        .thinking_tags = .none,
        .reasoning_param = .nested_reasoning_object,
        .supports_stream_options = true,
        .use_completion_tokens = true,
    }},

    // ── vLLM ──
    .{ .key = "vllm", .profile = .{
        .name = "vLLM",
        .protocol = .chat_completions,
        .reasoning_field = .both,                // vLLM ≥0.23 renamed field
        .echo_policy = .drop,
        .thinking_tags = .english_only,
        .reasoning_param = .top_level_effort,
        .supports_stream_options = true,
        .use_completion_tokens = false,
    }},

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
    }},
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
        std.mem.indexOf(u8, url, "qwen") != null) return "qwen";
    if (std.mem.indexOf(u8, url, "minimax") != null) return "minimax";
    if (std.mem.indexOf(u8, url, "zhipuai") != null or
        std.mem.indexOf(u8, url, "bigmodel") != null) return "glm";
    if (std.mem.indexOf(u8, url, "moonshot") != null or
        std.mem.indexOf(u8, url, "kimi") != null) return "kimi";
    if (std.mem.indexOf(u8, url, "x.ai") != null or
        std.mem.indexOf(u8, url, "grok") != null) return "xai";
    if (std.mem.indexOf(u8, url, "openai.com") != null) return "openai";
    return "generic";
}
```

### 3.3. Config Integration (`src/core/config.zig`)

New environment variable:

```
OPENAI_COMPAT_PROVIDER=deepseek|qwen|minimax|glm|kimi|xai|openai|vllm|generic
```

Priority (highest first):
1. Explicit `OPENAI_COMPAT_PROVIDER` env var
2. `config.json` field: `openai_compat_provider`
3. Auto-detect from `OPENAI_COMPAT_URL` via `provider.detectFromUrl()`
4. Fallback: `"generic"`

New config field:
```zig
/// Provider profile key for OpenAI-compat backend (RFC-012).
openai_provider: []const u8 = "generic",
```

### 3.4. Request Normalization — ProviderAdapter.encodeRequest()

Located in `src/backends/openai.zig`, modifying the existing `sendMessage()` flow:

```
sendMessage() {
    profile = provider.getProfile(self.provider_key);
    
    // 1. Protocol Selection (replaces auto-negotiate default)
    active_protocol = switch (profile.protocol) {
        .chat_completions => .chat_completions,
        .responses => .responses,
        .auto => self.cached_protocol orelse .responses,  // existing behavior
    };
    
    // 2. Build Request Body (provider-aware)
    body = buildRequestBody(profile, ...);
    //   - reasoning_param format selection
    //   - stream_options toggle
    //   - max_tokens vs max_completion_tokens
    
    // 3. Message Serialization (reasoning echo)
    serializeMessages(profile, msgs);
    //   - if profile.echo_policy == .echo_required:
    //       include reasoning_content in assistant messages
    //   - if profile.echo_policy == .drop:
    //       omit thinking blocks (current behavior)
}
```

#### 3.4.1. Reasoning Echo in Message Serialization

Current code in `buildRequestBody()` (lines 500-548) for assistant messages:

```zig
// Current: only sends content + tool_calls, drops thinking blocks
if (has_text and text_content != null) {
    try w.print("\"content\":\"{s}\"", .{escaped});
} else {
    try w.print("\"content\":null", .{});
}
```

**RFC-012 change** — when `profile.echo_policy == .echo_required`:

```zig
// Check for thinking block to echo
var reasoning_text: ?[]const u8 = null;
for (msg.content) |block| {
    if (block == .thinking) {
        reasoning_text = block.thinking.thinking;
        break;
    }
}

if (has_text and text_content != null) {
    try w.print("\"content\":\"{s}\"", .{escaped});
} else {
    try w.print("\"content\":null", .{});
}

// Echo reasoning_content for providers that require it (DeepSeek)
if (reasoning_text) |rt| {
    if (profile.echo_policy == .echo_required or profile.echo_policy == .echo_optional) {
        const escaped_rt = try json.escape(alloc, rt);
        defer alloc.free(escaped_rt);
        try w.print(",\"reasoning_content\":\"{s}\"", .{escaped_rt});
    }
}
```

#### 3.4.2. Reasoning Parameter Format

Current hardcoded format → provider-aware:

```zig
// Before (hardcoded):
try w.print("\"reasoning_effort\":\"{s}\",", .{effort});

// After (profile-driven):
switch (profile.reasoning_param) {
    .top_level_effort => {
        try w.print("\"reasoning_effort\":\"{s}\",", .{effort});
    },
    .nested_reasoning_object => {
        try w.print("\"reasoning\":{{\"effort\":\"{s}\"}},", .{effort});
    },
    .unsupported => {}, // Skip entirely
}
```

### 3.5. Response Normalization — StreamCtx Enhancements

#### 3.5.1. Reasoning Field Selection

Current code (line 849):
```zig
const reasoning = delta.reasoning_content orelse delta.reasoning;
```

**RFC-012**: No change needed — `both` fallback already works. The `reasoning_field` enum is informational for documentation and future optimization (skip parsing unused field).

#### 3.5.2. Thinking Tag Expansion in StreamEventParser

Current `StreamEventParser` in `src/ui/chat_stream.zig` only recognizes `<think>` and `</think>`.

**RFC-012 addition** — extend to Chinese variants when profile says `english_and_chinese`:

```zig
// New: Chinese thinking tag detection
const chinese_think_tags = [_][]const u8{
    "<思考>",   // sīkǎo (thinking)
    "<推理>",   // tuīlǐ (reasoning)
    "<反思>",   // fǎnsī (reflection)
    "<推敲>",   // tuīqiāo (deliberation)
};
const chinese_think_end_tags = [_][]const u8{
    "</思考>",
    "</推理>",
    "</反思>",
    "</推敲>",
};
```

Implementation approach: The `StreamEventParser.feed()` state machine extends the `<think>` detection to also match UTF-8 sequences for Chinese tags. Since these tags are multi-byte, the tag_buf (currently 16 bytes) is sufficient — the longest tag `</推敲>` is 11 bytes in UTF-8.

### 3.6. Auto-Negotiation Refinement

Current auto-negotiate (lines 159-166) defaults to trying Responses API first. RFC-012 changes the default based on profile:

```
Before:  .auto → try .responses first
After:   .auto → profile.protocol determines initial attempt
         .auto + profile says .chat_completions → skip Responses API entirely
```

This eliminates the "Agnes AI trap" where the provider accepts `/v1/responses` with HTTP 200 but streams incomplete data.

### 3.7. Dynamic JavaScript Provider Adapter (`JsProviderAdapter`)

To eliminate the need to recompile `mini` for third-party proxies, aggregator gateways, or proprietary wrappers that emit non-standard JSON envelopes (such as `delta.detail.reasoning_content` or `delta.details.reasoning_content`), RFC-012 defines a dynamic JavaScript provider extension mechanism running in an isolated embedded QuickJS instance (`src/backends/js_provider.zig`).

#### 3.7.1. JavaScript Provider Adapter Contract

A provider adapter script can be defined in a `.js` file or inline string adhering to ESM `export default`, CommonJS `module.exports`, or direct object literal:

```javascript
export default {
    name: "Custom Proxy",
    protocol: "chat_completions", // "chat_completions" | "responses" | "auto"
    echo_policy: "drop",          // "drop" | "echo_required"
    thinking_tags: "english_only", // "english_and_chinese" | "english_only" | "none"
    reasoning_param: "top_level_effort", // "nested_reasoning_object" | "top_level_effort" | "unsupported"

    // Hook: extract custom reasoning content from raw SSE chunk JSON
    extractReasoning(chunk) {
        return chunk?.choices?.[0]?.delta?.detail?.reasoning_content ||
               chunk?.choices?.[0]?.delta?.details?.reasoning_content ||
               null;
    },

    // Hook: extract custom text content from raw SSE chunk JSON
    extractContent(chunk) {
        return chunk?.choices?.[0]?.delta?.content || null;
    },

    // Hook: pre-flight request payload transformation
    transformRequest(req) {
        // e.g. inject vendor-specific routing headers or mutate options
        return req;
    }
};
```

#### 3.7.2. Integration & Native Fallback

1. **Native Fallback in `ChoiceDelta`**: Even without a JS file, `src/backends/openai.zig` natively parses `delta.detail` and `delta.details` to catch common proxy wrapping patterns out-of-the-box.
2. **Dynamic Overrides via `JsProviderAdapter`**: When custom behavior is provided via a JS script, `JsProviderAdapter` executes `extractReasoning()`, `extractContent()`, and `transformRequest()` hooks with zero rebuild of the binary.

---

## 4. Data Flow Diagram

```
 ┌───────────────────────────────────────────────────────────────────┐
 │                     FULL REQUEST/RESPONSE FLOW                    │
 │                                                                   │
 │  ┌─────────┐    proto.Message[]     ┌──────────────────────┐     │
 │  │  Agent   │ ──────────────────►   │  ProviderAdapter     │     │
 │  │  Loop    │    (standard)         │  ┌────────────────┐  │     │
 │  │          │                       │  │ProviderProfile │  │     │
 │  │ agent.zig│                       │  │ • protocol     │  │     │
 │  └─────────┘                       │  │ • echo_policy  │  │     │
 │       ▲                             │  │ • tags         │  │     │
 │       │                             │  │ • param_format │  │     │
 │       │                             │  └────────────────┘  │     │
 │       │                             │         │            │     │
 │       │                             │         ▼            │     │
 │       │                             │  encodeRequest()     │     │
 │       │                             │  ├─ select endpoint  │     │
 │       │                             │  ├─ echo reasoning?  │     │
 │       │                             │  ├─ format params    │     │
 │       │                             │  └─► HTTP body       │     │
 │       │                             └──────────┬───────────┘     │
 │       │                                        │                  │
 │       │                                        ▼                  │
 │       │                              ┌─────────────────┐          │
 │       │                              │   HTTP POST     │          │
 │       │                              │   (SSE stream)  │          │
 │       │                              │   Provider API  │          │
 │       │                              └────────┬────────┘          │
 │       │                                       │                   │
 │       │                                       ▼                   │
 │       │                             ┌──────────────────────┐      │
 │       │     proto.Response          │  ProviderAdapter     │      │
 │       │ ◄───────────────────────    │  normalizeResponse() │      │
 │       │     (standard)              │  ├─ parse reasoning  │      │
 │       │                             │  ├─ strip tags       │      │
 │       │                             │  ├─ map stop_reason  │      │
 │       │                             │  └─ unify usage      │      │
 │       │                             └──────────────────────┘      │
 └───────────────────────────────────────────────────────────────────┘
```

---

## 5. Implementation Plan

### Phase 1: ProviderProfile Registry (Low risk)
- **New file**: `src/backends/provider.zig`
- **Modify**: `src/core/config.zig` — add `OPENAI_COMPAT_PROVIDER` env, auto-detect from URL
- **Modify**: `src/backends/openai.zig` `Client` struct — add `provider_key: []const u8` field
- **Test**: Unit test `provider.detectFromUrl()` with known URLs

### Phase 2: Request Normalization (Medium risk)
- **Modify**: `src/backends/openai.zig` `buildRequestBody()` — profile-driven reasoning param format
- **Modify**: `src/backends/openai.zig` `sendMessage()` — profile-driven protocol selection (replace auto-negotiate default)
- **Modify**: `src/backends/openai.zig` message serialization — reasoning echo policy
- **Test**: Unit test request body generation for `deepseek`, `qwen`, `openai` profiles

### Phase 3: Response Normalization (Medium risk)
- **Modify**: `src/ui/chat_stream.zig` `StreamEventParser` — Chinese thinking tag recognition
- **Verify**: SSE parsing already handles `reasoning_content` + `reasoning` fallback (no change needed)
- **Test**: Unit test Chinese tag parsing, reasoning-only responses

### Phase 4: Integration & Verification (Low risk)
- **Modify**: `src/core/config.zig` `loadDotEnv` — add `openai_compat_provider` to JsonConfig
- **Modify**: `AGENTS.md` — document `OPENAI_COMPAT_PROVIDER`
- **Test**: E2E mock server test with DeepSeek-style reasoning echo

---

## 6. Files Modified

| File | Change Type | Description |
|---|---|---|
| `src/backends/provider.zig` | **NEW** | ProviderProfile struct, facade registry, URL auto-detect |
| `src/backends/providers/*.zig` | **NEW** | Dedicated profile files for each provider (`openai`, `deepseek`, `qwen`, `minimax`, `glm`, `kimi`, `xai`, `vllm`, `generic`) |
| `src/backends/js_provider.zig` | **NEW** | Dynamic JavaScript provider adapter running in isolated QuickJS |
| `src/backends/openai.zig` | MODIFY | Profile-driven protocol, echo policy, param format, detail.reasoning_content |
| `src/core/config.zig` | MODIFY | `OPENAI_COMPAT_PROVIDER` env, `openai_provider` config field |
| `src/ui/chat_stream.zig` | MODIFY | Chinese thinking tag recognition in `StreamEventParser` |
| `testcases/test_provider_profiles.zig` | **NEW** | Unit tests for profile lookup and URL detection |
| `testcases/test_js_provider.zig` | **NEW** | Integration tests for dynamic JS provider adapter |

---

## 7. Migration & Backward Compatibility

- **Default profile is `generic`** — identical behavior to current code (auto-negotiate, no echo, English tags only).
- **Existing `.env` files**: No changes required. `OPENAI_PROTOCOL=chat` continues to override protocol selection.
- **Priority**: Explicit `OPENAI_PROTOCOL` > `ProviderProfile.protocol` > auto-negotiate. Existing overrides always win.
- **Zero breaking changes**: All new fields have defaults matching current behavior.

---

## 8. Future Extensions (Out of Scope)

- **Runtime provider catalog dynamic sync**.
- **Provider-specific OAuth/credential rotation flows**.
- **Multi-provider routing** (send different tasks to different providers within one session).
- **Encrypted reasoning content** (some providers return `encrypted_content` blobs).
