# AI Backends, Provider Profiles & Wire Protocols

## 1. Provider Abstraction Architecture

`mini-agent` communicates with upstream language models through a modular backend abstraction (`src/backends/`). This architecture isolates wire protocol differences, streaming event quirks, reasoning formats, and authentication schemes behind a unified client interface.

```
                         ┌──────────────────────────────┐
                         │      Agent Core Loop         │
                         └──────────────┬───────────────┘
                                        │ proto.Request
                                        ▼
                         ┌──────────────────────────────┐
                         │   Backend Dispatcher         │
                         │  (src/core/agent.zig)        │
                         └──────┬───────────────┬───────┘
                                │               │
        ┌───────────────────────┘               └───────────────────────┐
        ▼                                                               ▼
┌────────────────────────────────┐                             ┌────────────────────────────────┐
│   OpenAI-Compatible Backend    │                             │       Claude Backend           │
│   (src/backends/openai.zig)    │                             │    (src/backends/claude.zig)   │
├────────────────────────────────┤                             ├────────────────────────────────┤
│ - Dual-Protocol Auto-Negotiate │                             │ - Messages API Streaming       │
│ - Provider Profiles & JS Shims │                             │ - Extended Thinking Budget     │
│ - Chinese Thinking Filter      │                             │ - Prompt Caching               │
└────────────────────────────────┘                             └────────────────────────────────┘
```

The agent automatically selects the active backend at startup based on configured environment variables:
1. **OpenAI-Compatible**: Selected when `OPENAI_COMPAT_URL` is set.
2. **Anthropic Claude**: Selected when `ANTHROPIC_API_KEY` is set.
3. **Local Ollama**: Fallback when `OLLAMA_HOST` is configured or defaults to `http://localhost:11434`.

---

## 2. OpenAI-Compatible Backend

The OpenAI backend supports any API that adheres to OpenAI wire formats, including OpenAI official endpoints, OpenRouter, LM Studio, vLLM, DeepSeek, and Groq.

### 2.1. Dual-Protocol Auto-Negotiation

Modern reasoning models (such as o-series, GPT-5.x, or custom reasoning proxies) often require the newer **Responses API** when combining function calling with reasoning output, whereas standard models utilize the **Chat Completions API**.

When `OPENAI_PROTOCOL=auto` (default):
1. **Model ID Probing**: Checks model prefixes to select the most probable endpoint.
2. **Dynamic Fallback**: If an initial request to `/chat/completions` fails with an HTTP 400 error indicating schema or protocol incompatibility, the client automatically falls back to `/responses` (and vice-versa).
3. **Session Protocol Cache**: Once a successful exchange occurs, the negotiated protocol is stored in process memory, eliminating probing latency for all subsequent turns in that session.

### 2.2. Provider Profiles (`src/backends/providers/`)

Different inference providers implement slight variations of the OpenAI specification. `mini-agent` normalizes these behaviors using **Provider Profiles** (`OPENAI_COMPAT_PROVIDER`):

| Profile | Target Provider | Characteristics & Normalization |
|---|---|---|
| `deepseek` | DeepSeek official / OpenRouter | Retains thinking content in assistant message history; strips `<think>` tokens from final responses. |
| `kimi` | Moonshot AI | Formats reasoning parameters; supports large context sliding. |
| `minimax` | MiniMax Hailuo | Custom tool calling serialization adjustments. |
| `qwen` | Alibaba Cloud DashScope | Manages function calling schema quirks for Qwen 2.5 series. |
| `glm` | Zhipu AI | Strips Chinese thinking tags (`<思考>`, `<推理>`). |
| `vllm` | Self-hosted vLLM | Optimizes streaming chunks without reasoning payload overhead. |
| `xai` | xAI Grok | Adapts thinking effort formatting. |
| `agnes` | Agnes API Hub | Custom endpoint URL structure normalization. |
| `generic` | Standard OpenAI / LM Studio | Standard Chat Completions and Responses API implementation. |

### 2.3. JavaScript Provider Adapters

For providers requiring custom transformations that cannot be captured in static profiles, `mini-agent` supports dynamic JavaScript provider adapters:
- Set `OPENAI_COMPAT_PROVIDER_JS=/path/to/adapter.js` (or place in `providers/<name>.js`).
- The adapter script executes inside the embedded QuickJS engine, allowing custom payload mutation, header injection, or response reformatting prior to agent consumption.

---

## 3. Anthropic Claude Backend

The Claude client (`src/backends/claude.zig`) communicates with Anthropic's Messages API over HTTP Server-Sent Events (SSE).

### 3.1. Extended Thinking Support

When `MINI_THINKING_BUDGET_TOKENS` is configured:
- The client injects the `thinking` object with the specified token budget into the request.
- Automatically locks the request `temperature` to `1.0` (mandated by Anthropic when thinking is active).
- Processes `thinking_delta` stream events, routing them directly to the `TurnRenderer` thinking display in the terminal.

### 3.2. Prompt Caching

The Claude backend automatically injects `cache_control: { "type": "ephemeral" }` breakpoints into the system prompt and long history turns to take advantage of Anthropic's prompt caching, substantially reducing cost and latency on long turns.

---

## 4. Local Ollama Backend

The Ollama client (`src/backends/ollama.zig`) enables completely offline, private agent execution:
- Connects to `OLLAMA_HOST` (default: `http://localhost:11434`).
- Uses NDJSON streaming over `/api/chat`.
- Translates `mini-agent` tools into Ollama function calling format.
- Automatically handles local models with or without native tool calling support via CodeAct JavaScript fallback.

---

## 5. Streaming Event Pipeline & Thinking Filter

All backends feed raw tokens into the unified `StreamEventParser` (`src/ui/chat_stream.zig`).

### 5.1. Thinking Tag Filter (`src/backends/thinking_filter.zig`)

Certain providers (such as DeepSeek R1, Qwen reasoning variants, or GLM) output chain-of-thought tokens directly into the text stream enclosed in XML-like tags. The thinking filter automatically strips and redirects these tags:
- Enclosing patterns: `<think>...</think>`, `<思考>...</思考>`, `<推理>...</推理>`, `<thought>...</thought>`.
- The enclosed content is routed to the thinking display rather than polluting the final output.
- Incomplete tags at stream chunk boundaries are buffered until the closing tag arrives.

### 5.2. Capability Cache & Dynamic Thinking Governor

At startup or upon switching models:
1. The agent queries the `/models` endpoint to probe model metadata.
2. Caches supported reasoning efforts and token limits in memory.
3. The **Dynamic Thinking Governor** (`MINI_DYNAMIC_THINKING=1`) inspects upcoming turn complexity and modulates reasoning parameters:
   - Routine commands and directory listings run with `"low"` or `"minimal"` reasoning.
   - Refactoring, bug diagnosis, and architecture queries dynamically elevate reasoning to `"high"`.
   - The agent can also self-adjust thinking via `mini.setThinking("low" | "high")`.
