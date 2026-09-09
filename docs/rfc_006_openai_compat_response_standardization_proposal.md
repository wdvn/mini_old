# RFC-006: Standardizing Response Parsing for OpenAI/OpenAI-compat Backends

| Attribute | Value |
|---|---|
| RFC | 006 |
| Title | Standardizing response parsing (SSE stream + usage) for OpenAI/OpenAI-compat |
| Status | **Implemented / Production** — SSE stream chunk parsing (usage, finish_reasons, delta.reasoning, HTTP error path) is completed and verified |
| Version | 0.1 |
| Dependencies | None (RFC-001 indirectly related — shares `core/protocol.zig` backend model) |
| References | [OpenAI Chat Completions API — streaming](https://platform.openai.com/docs/api-reference/chat/streaming), [Chat Completions object](https://platform.openai.com/docs/api-reference/chat/object); compat variants: [DeepSeek reasoning_content](https://api-docs.deepseek.com/api/create-chat-completion), vLLM, LM Studio, Ollama `/v1` |
| Author | mini-agent |
| Date | 2026-08-23 |

---

## 1. Motivation

`src/backends/openai.zig` is the single backend catering to the "OpenAI-compatible" ecosystem — one backend serving numerous providers (official OpenAI, DeepSeek, vLLM, LM Studio, Ollama `/v1`, OpenRouter, internal APIs, etc.). Prior response parsing suffered from 4 flaws:

1. **Usage was completely ignored.** Since the cache-hit optimization commit, requests included `"stream_options":{"include_usage":true}`, but the parser **never read the usage chunk** — the `Chunk` struct lacked a `usage` field, so token counts, throughput, and costs were never recorded. `include_usage` remained dead weight: returned by providers but unconsumed by mini.

2. **Reasoning content supported only one variant.** DeepSeek and various compat APIs returned reasoning via `delta.reasoning_content` (supported), but official OpenAI (o-series/gpt-5) returned `delta.reasoning` — which was silently dropped (`ignore_unknown_fields = true`). The same semantic data under two field names had only one parsed.

3. **Stop reasons lacked `refusal` and `content_filter`.** OpenAI defines `finish_reason` values: `stop`, `length`, `tool_calls`, `content_filter`, `function` (legacy). Previously only `stop`/`length`/`tool_calls` were mapped — any unfamiliar finish_reason collapsed into `stop_reason == .unknown`, causing the agent loop to misclassify policy terminations as transport failures.

4. **No distinction between HTTP errors and valid streams.** When `http_code >= 400`, JSON error bodies (not SSE streams) were still passed into the SSE parser → failing silently → resulting in `stop_reason = .unknown` + `raw_debug_info` containing error bodies (captured by `raw_accum`). An explicit error branch at the response head was missing.

RFC Scope: **Response handling only** (SSE parsing + usage + finish_reason + error path) for `openai.zig`. Request generation (standardized static prefix for cache-hit in commit `7203038`) and alternative backends (claude.zig, native ollama.zig) are out of scope.

## 2. Objectives

1. Fully parse usage from the final SSE chunk (`stream_options.include_usage`) → record into `proto.Response.usage`, wired to journal/stats.
2. Ingest reasoning from both `delta.reasoning_content` (DeepSeek-style) and `delta.reasoning` (OpenAI o-series-style), prioritizing whichever is present.
3. Map all 5 OpenAI `finish_reason` values; unknown values remain `.unknown` with raw string for debugging.
4. Clean error paths: `http_code >= 400` → bypass SSE parser, returning structured error responses.
5. Preserve backward compatibility with `proto.Response` API (additive fields only).
6. Unit test coverage across provider variants.

## 3. Detailed Design

### 3.1. Usage Struct in `proto.Response`

Add to `src/core/protocol.zig`:

```zig
/// Token usage statistics returned by backend (OpenAI usage object format).
pub const Usage = struct {
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    total_tokens: u64 = 0,
    /// Prompt tokens charged at cache-hit rates (prompt_tokens - cached_tokens).
    cached_tokens: u64 = 0,
    /// Reasoning tokens returned by provider (e.g. DeepSeek reasoner).
    reasoning_tokens: u64 = 0,
};
```

Extend `Response` struct (defaulting to zero — existing constructors require no edits):

```zig
pub const Response = struct {
    // ... existing fields ...
    usage: Usage = .{},
};
```

OpenAI → mini Field Mapping:

| OpenAI (usage object) | mini `Usage` | Notes |
|---|---|---|
| `prompt_tokens` | `prompt_tokens` | |
| `completion_tokens` | `completion_tokens` | |
| `total_tokens` | `total_tokens` | |
| `prompt_tokens_details.cached_tokens` | `cached_tokens` | optional in OpenAI; DeepSeek uses `prompt_cache_hit_tokens` |
| `completion_tokens_details.reasoning_tokens` | `reasoning_tokens` | optional |

Compat Aliases (in openai.zig parser layer only):
- DeepSeek: `prompt_cache_hit_tokens` → `cached_tokens`; `prompt_cache_miss_tokens` ignored (deducible).
- Missing fields default to 0 without errors.

### 3.2. Parsing Usage Chunk in StreamCtx

SSE delivers usage in the **final chunk**: `choices: []` (empty array) + `usage: {...}`. Update `Chunk` struct in `openai.zig`:

```zig
const UsageJson = struct {
    prompt_tokens: ?u64 = null,
    completion_tokens: ?u64 = null,
    total_tokens: ?u64 = null,
    prompt_tokens_details: ?struct {
        cached_tokens: ?u64 = null,
    } = null,
    completion_tokens_details: ?struct {
        reasoning_tokens: ?u64 = null,
    } = null,
    // DeepSeek aliases
    prompt_cache_hit_tokens: ?u64 = null,
};

const Chunk = struct {
    // ... existing fields ...
    usage: ?UsageJson = null,
};
```

Handled in `processLine`:

```zig
if (chunk.usage) |u| {
    self.response.usage = .{
        .prompt_tokens = u.prompt_tokens orelse 0,
        .completion_tokens = u.completion_tokens orelse 0,
        .total_tokens = u.total_tokens orelse 0,
        .cached_tokens = if (u.prompt_tokens_details) |d|
            d.cached_tokens orelse u.prompt_cache_hit_tokens orelse 0
        else
            u.prompt_cache_hit_tokens orelse 0,
        .reasoning_tokens = if (u.completion_tokens_details) |d|
            d.reasoning_tokens orelse 0
        else
            0,
    };
}
```

### 3.3. Reasoning: Handling Both Field Variants

Extend `ChoiceDelta` with `reasoning: ?[]const u8 = null` (parallel to `reasoning_content`).
Resolution logic:

```zig
const reasoning = delta.reasoning_content orelse delta.reasoning orelse {
    // No reasoning in this chunk
} ...
```

Prioritizes `reasoning_content`; falls back to `reasoning`. If both occur simultaneously, `reasoning_content` is taken with a debug journal log.

Output produces standard `ThinkingBlock` (`signature = ""` — OpenAI-compat lacks Anthropic signature concepts).

### 3.3.1. Non-stream Reasoning: `message.reasoning_content`

Some proxies/providers return non-stream reasoning under `choices[0].message.reasoning_content`. Because mini always streams, this route is **unsupported** in this RFC to avoid scope creep.

### 3.4. Comprehensive finish_reason Mapping

Mapping in `processLine`:

| OpenAI `finish_reason` | mini `StopReason` |
|---|---|
| `stop` | `.end_turn` |
| `length` | `.max_tokens` |
| `tool_calls` | `.tool_use` |
| `content_filter` | `.unknown` + records `raw_debug_info` |
| `function` (legacy) | `.tool_use` (mapped as tool_calls) |
| other / null | preserves current state |

`content_filter` is not mapped directly to `.max_tokens` or `.end_turn`, which would trigger incorrect agent loop continuation semantics. `.unknown` + debug info is safest until `proto.StopReason` gains dedicated variants.

### 3.5. Explicit Error Handling Path

In `sendMessage`, following `postStream`:

```zig
if (req_http_code >= 400) {
    // Skip SSE parsing - raw error body is already captured in ctx.raw_accum
}
```

If body data is already in `ctx.raw_accum` (capped at first 4096 bytes), skip SSE parsing and return early with `stop_reason = .unknown`, `http_code`, and `raw_debug_info = raw_accum` — explicit and easily testable.

### 3.6. Disabling `include_usage` for Incompatible Endpoints

Legacy compat endpoints may return HTTP 400 when receiving `stream_options`. Extending adaptive retries (`use_completion_tokens`, `disable_reasoning_effort`):

```
400 + body containing "stream_options" or "include_usage"
→ rebuild request omitting stream_options, retry once
```

Sets `self.disable_stream_options: bool`. Usage defaults to 0 on these endpoints, falling back to MemAct's independent token estimation (`TokenEstimator`).

### 3.7. Agent Loop & MemAct Optimizations

Standardizing `usage`, `reasoning`, and `finish_reason` parsing enables optimizations for the Agent Loop and **MemAct (RFC-003 updated)**:

1. **Real Token Feedback Calibration for MemAct**:
   - *MemAct Mechanism*: Compaction preserves `msgs[0]` (original user prompt), inserts/updates context summaries at `msgs[1]` (tier `.summarized`), and drops intermediate conversation history.
   - *Calibration with Real Usage*: When providers return actual `response.usage.prompt_tokens`, `AgentLoop` feeds this into `TokenEstimator` (`src/core/memact/tokens.zig`) and `ContextWindow` (`src/core/memact/window.zig`). This allows `findSplitIndex()` and `needsCompaction()` to trigger compaction accurately at `MINI_CTX_COMPACT_THRESHOLD` (85%), removing heuristic drift.

2. **Prompt Cache-Hit Rate Telemetry Post-Compaction**:
   - `cached_tokens` measures token reuse through provider prompt caching.
   - Because MemAct freezes `msgs[0]` and consolidates summaries at `msgs[1]`, request prefixes remain highly cache-friendly.
   - `AgentLoop` computes cache-hit rates (`cached_tokens / prompt_tokens`) and logs them to the Journal, validating prompt caching gains across providers (DeepSeek, OpenAI, Claude).

3. **Reasoning Token Budget Management**:
   - Reasoning models incur `reasoning_tokens` during thinking phases.
   - `AgentLoop` distinguishes thinking costs from output generation, enabling dynamic adjustments to `max_tokens` and alerts if reasoning consumes excessive budget.

4. **Graceful Handling of Content Filter / Refusals**:
   - Accurate `finish_reason` mapping distinguishes policy aborts (`content_filter`/`refusal`) from transient transport failures (`.unknown`), allowing clear user explanations instead of futile retries.

5. **Accurate Session Token Budget Tracking**:
   - Deducts actual `usage.total_tokens` directly from `budget_max_tokens`.

---

## 4. Code Modifications

| File | Changes |
|---|---|
| `src/core/protocol.zig` | Added `Usage` struct + `usage` field to `Response` (additive) |
| `src/backends/openai.zig` | Nested `UsageJson` parsing; `reasoning` alias; comprehensive `finish_reason` mapping; early error branch; `stream_options` retry |
| `src/core/agent.zig` | Wire usage to journal (`[usage] prompt=X completion=Y cache_hit=Z`), calibrate MemAct token feedback & deduct session budget |
| `testcases/test_openai_response_parse.zig` | Table-driven SSE fixtures across 4 provider variants |

Test Fixtures (simulating SSE chunks fed into `StreamCtx.onChunk`):
1. **Standard OpenAI + tools + usage** — verify tool_calls accumulation, usage parsing, `cached_tokens` from `prompt_tokens_details`.
2. **DeepSeek reasoner** — `reasoning_content` deltas + `prompt_cache_hit_tokens` alias.
3. **OpenAI o-series** — `delta.reasoning` (without `_content`).
4. **Error 429/500** — JSON error body, verify `stop_reason == .unknown`, `http_code` set, `raw_debug_info` contains body.
5. **finish_reason content_filter** — verify `.unknown` + debug info, not `.end_turn`.

---

## 5. Milestones

| # | Item | Target |
|---|---|---|
| M1 | `proto.Usage` + parsing in openai.zig + fixtures 1–2 | protocol.zig, openai.zig |
| M2 | `reasoning` alias + fixture 3 | openai.zig |
| M3 | finish_reason mapping + error branch + fixtures 4–5 | openai.zig |
| M4 | Adaptive `stream_options` retry | openai.zig |
| M5 | Journal usage line + MemAct usage feedback calibration + cache-hit display | agent.zig, history.zig |

---

## 6. Acceptance Criteria

- [ ] Real or mock OpenAI stream returns usage: `response.usage.total_tokens > 0`.
- [ ] MemAct receives real `usage` to calibrate context token estimation.
- [ ] DeepSeek: reasoning lands in `ThinkingBlock`, `cached_tokens` > 0 when reported.
- [ ] `delta.reasoning` (without suffix) parsed as thinking.
- [ ] `finish_reason: "content_filter"` → `.unknown` + debug info, NOT `.end_turn`.
- [ ] HTTP 400 stream_options rejection triggers auto-retry without stream_options.
- [ ] All test suites pass cleanly.

---

## 7. Risks & Mitigations

| Risk | Probability | Mitigation |
|---|---|---|
| Provider returns undocumented usage formats | Medium | `ignore_unknown_fields` + optional fields → worst case usage = 0, no crash |
| `prompt_tokens_details` has `cached_tokens: null` | Real occurrence | Defensive null-checks on nested structs (`orelse 0`) |
| Infinite loop retrying stream_options | Low | One-way flag (`disable_stream_options` transitions false→true only) |
| Additional `usage` field bloats Response allocation | Low | `Usage` is a plain struct (~40 bytes), zero-cost when unset |
| `reasoning` field renamed again in future OpenAI APIs | Medium | Parsed in a single location (`ChoiceDelta`); alias updates touch one struct |

---

## 8. Alternatives Considered

1. **Defining `Usage` per backend** — Rejected: claude.zig also requires usage metrics; sharing a single proto struct avoids fragmentation.
2. **Parsing non-stream responses** — Rejected: mini operates exclusively on streaming responses; non-streaming paths represent dead code.
3. **Adding `StopReason.refusal`/`.content_filter` to proto** — Deferred: adding enum variants requires updating exhaustive switches throughout agent loops without immediate behavioral divergence.
4. **Adopting official OpenAI SDK** — Rejected: AGENTS.md prohibits unvetted external dependencies; parsing needs are covered within ~100 lines of Zig.

---

## 9. Future Work

- Add `.refusal` and `.content_filter` to `proto.StopReason` when the agent loop develops specialized handling.
- Claude backend parsing for `message_start` usage (`input_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`).
- Aggregators (OpenRouter) returning `usage.cost` — consider `cost_usd: f64` field.

---

## 10. Open Questions

1. Should usage be logged to the journal per LLM call or aggregated per turn?
   — Preference: per LLM call, aligning with act/event granularity.
2. Should DeepSeek `prompt_cache_hit_tokens` accumulate with OpenAI `cached_tokens` if proxies combine both?
   — Current policy: pick first non-zero field.
