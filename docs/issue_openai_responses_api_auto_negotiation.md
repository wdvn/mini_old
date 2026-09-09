# Issue & Design Proposal: OpenAI Responses API Integration & Dual-Protocol Auto-Negotiation

| Attribute | Value |
|---|---|
| Issue Code | **ISSUE-BACKEND-001** |
| Title | Automatic negotiation and switching between Chat Completions API and Responses API (Dual-Protocol Auto-Negotiation & Adaptive Fallback) |
| Status | **Resolved / Implemented** (Completed 3-tier auto-negotiation, request translation, and protocol session cache) |
| Scope | `src/backends/openai.zig`, `src/core/config.zig`, `src/core/protocol.zig` |
| Date | 2026-08-26 |

---

## 1. Problem Statement

Currently, `src/backends/openai.zig` communicates with the entire OpenAI-compatible ecosystem through the traditional endpoint:
`POST {base_url}/chat/completions` (Chat Completions API).

However, the AI ecosystem is entering a major architectural transition:
1. **Next-generation model families (OpenAI GPT-5.6 Sol / Terra / Luna, o3-pro)** prioritize or require the **Responses API** (`POST {base_url}/responses`) when combining **Reasoning** and **Tool Calling**.
2. On legacy Chat Completions endpoints, sending requests with both `tools` and `reasoning_effort` causes some GPT-5.6 models to return `HTTP 400 Bad Request` (rejecting reasoning effort combined with function tools on the old protocol).
3. **Fragmented user experience**: Users typically configure only a single environment variable, `OPENAI_COMPAT_URL` (e.g. `https://api.openai.com/v1` or `https://api.openai.com/v1/chat/completions`). Users should not have to manually configure which models use `/chat/completions` and which use `/responses`.

---

## 2. Objectives

1. **Single Endpoint Configuration**:
   - Users only need to configure `OPENAI_COMPAT_URL` (or `config.json`).
   - `mini` automatically extracts the root Base URL and routes to the correct target endpoint (`/chat/completions` or `/responses`).

2. **3-Tier Auto-Negotiation & Adaptive Fallback**:
   - **Tier 1 (Model-Aware Pre-routing)**: Recognize model prefixes (e.g. `gpt-5.6*`, `o3-pro*`) to proactively use the Responses API.
   - **Tier 2 (Adaptive Error Fallback)**: When encountering HTTP 400 (indicating unsupported feature combinations on Chat Completions), automatically translate payload to Responses API format and retry immediately. Conversely, if HTTP 404 occurs on older local/proxy servers, automatically fall back to Chat Completions.
   - **Tier 3 (Protocol Memory Caching)**: Remember successful endpoints per model throughout the session (session cache) to eliminate probe latency in subsequent turns.

3. **Bidirectional Adapter Transformer**:
   - Seamlessly translate between `Message` / `ToolDefinition` (in `core/protocol.zig`) and both API request/response formats without modifying the Agent Loop.

---

## 3. Detailed Design

### 3.1. Execution Flow & Auto-Negotiation

```
                   [ Agent Loop: sendMessage ]
                               │
                               ▼
            ┌──────────────────────────────────────┐
            │ 1. URL Normalization (Extract Base)  │
            │    "https://api.openai.com/v1"       │
            └──────────────────┬───────────────────┘
                               │
                               ▼
            ┌──────────────────────────────────────┐
            │ 2. Protocol Selection Strategy       │
            │    - Session Cached Protocol?        │
            │    - Model Heuristic (gpt-5.6/o3-pro)│
            │    - Default: Chat Completions       │
            └──────────┬────────────────┬──────────┘
                       │                │
          [ Chat Completions ]     [ Responses API ]
          POST /chat/completions   POST /responses
                       │                │
               Encounter 400?       Encounter 404?
          (unsupported/tools+cot)  (server unsupported)
                       │                │
                       ▼                ▼
            ┌──────────────────────────────────────┐
            │ 3. Adaptive Cross-Protocol Fallback  │
            │    - Convert Payload to other format │
            │    - Retry Request & Cache Protocol  │
            └──────────────────────────────────────┘
```

### 3.2. Base URL Normalization

```zig
fn getRootApiUrl(base_url: []const u8) []const u8 {
    var url = std.mem.trimEnd(u8, base_url, "/");
    if (std.mem.endsWith(u8, url, "/chat/completions")) {
        return url[0 .. url.len - "/chat/completions".len];
    }
    if (std.mem.endsWith(u8, url, "/responses")) {
        return url[0 .. url.len - "/responses".len];
    }
    return url;
}
```

### 3.3. Payload Format & Streaming Events Comparison

| Category | Chat Completions API | Responses API |
|---|---|---|
| **Endpoint** | `POST {base}/chat/completions` | `POST {base}/responses` |
| **Input Payload** | `{"messages": [{"role":"user","content":"..."}]}` | `{"input": [{"role":"user","content":"..."}]}` |
| **Tools Payload** | `{"tools": [{"type":"function", "function":{...}}]}` | `{"tools": [{"type":"function", "name":..., "parameters":...}]}` |
| **Reasoning Param** | `{"reasoning_effort": "medium"}` | `{"reasoning": {"effort": "medium"}}` |
| **Stream Event** | `data: {"choices":[{"delta":{"content":"..."}}]}` | `event: response.output_text.delta`<br>`data: {"delta":"..."}` |
| **Reasoning Stream** | `data: {"choices":[{"delta":{"reasoning":"..."}}]}` | `event: response.reasoning_text.delta`<br>`data: {"delta":"..."}` |
| **Tool Stream** | `data: {"choices":[{"delta":{"tool_calls":[...]}}]}` | `event: response.tool_call.delta`<br>`data: {"delta":"..."}` |

---

## 4. Implementation Plan

1. **Phase 1 (Protocol Struct & Enum)**:
   - Add `ProtocolMode` (`auto`, `chat_completions`, `responses`) to `Config` and `Client`.
   - Implement root URL normalization via `getRootApiUrl()`.

2. **Phase 2 (Responses API Streaming Parser)**:
   - Build SSE parser for standard Responses API events (`response.output_text.delta`, `response.reasoning_text.delta`, `response.tool_call.delta`).

3. **Phase 3 (Adaptive Fallback & Caching)**:
   - Detect 400/404 errors and automatically retry across protocols.
   - Cache successfully negotiated protocol keyed by model name.

4. **Phase 4 (Testing & Fixtures)**:
   - Write unit tests simulating SSE streams for both API standards in `testcases/`.
