# Configuration & Environment Variables Reference

## 1. Configuration Architecture & Precedence

`mini-agent` uses a layered configuration system designed for flexible local development and production automation. Configuration values are resolved in the following strict order of precedence (highest to lowest):

1. **CLI Arguments**: Command-line flags (e.g. `--model`, `--mode`, `--session`) take absolute precedence.
2. **Shell Environment Variables**: Variables explicitly exported in the current shell environment (`export OPENAI_COMPAT_URL=...`).
3. **Explicit Dotenv File**: File specified via `MINI_ENV_FILE` or `--env-file`.
4. **Project Workspace Dotenv**: Local `./.env` in the current working directory.
5. **Project JSON Configuration**: `./.agent/config.json` in the active workspace.
6. **Global User Dotenv**: `~/.mini/.env` (or `$MINI_HOME/.env`).
7. **Global User Configuration**: `~/.mini/config.json`.
8. **Provider Profiles**: Active provider JSON defaults from `~/.mini/providers/<name>.json` or builtin definitions.
9. **Hardcoded Defaults**: Safe fallbacks defined in `src/core/config/types.zig`.

> [!NOTE]
> Environment variables already set in the parent process shell are **never overwritten** by variables defined in `.env` files.

---

## 2. Environment Variables Reference

### 2.1. AI Provider & Backend Settings

| Variable | Type | Default | Description |
|---|---|---|---|
| `OPENAI_COMPAT_URL` | String | — | Base URL for OpenAI-compatible endpoint (e.g., `https://api.openai.com/v1`). Highest priority backend. |
| `OPENAI_COMPAT_API_KEY` | String | — | API key for OpenAI-compatible endpoint (alias: `OPENAI_API_KEY`). |
| `OPENAI_COMPAT_MODEL` | String | `gpt-4o-mini` | Model identifier to request from the OpenAI-compatible endpoint. |
| `OPENAI_COMPAT_API_HEADER` | String | `Authorization` | HTTP header name containing the API key. |
| `OPENAI_PROTOCOL` | Enum | `auto` | Protocol mode: `auto` (auto-negotiates `/chat/completions` vs `/responses`), `chat_completions`, or `responses`. |
| `OPENAI_COMPAT_PROVIDER` | String | `generic` | Provider profile identifier (`deepseek`, `kimi`, `minimax`, `qwen`, `glm`, `vllm`, `xai`, `agnes`). |
| `OPENAI_COMPAT_PROVIDER_JS` | String | — | Path to a custom JavaScript provider adapter script. |
| `MINI_USE_COMPLETION_TOKENS` | Boolean | `0` | Set `1` to send `max_completion_tokens` instead of `max_tokens` in request payloads. |
| `ANTHROPIC_API_KEY` | String | — | Anthropic API key. Activates Claude backend if OpenAI URL is not set. |
| `CLAUDE_MODEL` | String | `claude-opus-4-5` | Model ID for Anthropic backend. |
| `OLLAMA_HOST` | String | `http://localhost:11434` | Base URL for local Ollama server. Fallback backend. |
| `OLLAMA_MODEL` | String | `llama3` | Model name for local Ollama execution. |

### 2.2. Execution Mode & Agent Parameters

| Variable | Type | Default | Description |
|---|---|---|---|
| `MINI_HOME` | Path | `~/.mini` | Root directory for configuration, sessions, artifacts, skills, and memory logs. |
| `MINI_EXECUTION_MODE` | Enum | `auto` | Execution mode: `auto` (model decides format), `codeact` (forces JavaScript in VM), or `tools` (native JSON schemas). |
| `MINI_MAX_TOKENS` | Integer | `8192` | Maximum generation tokens requested per turn. |
| `MINI_SYSTEM_FILE` | Path | — | Path to a custom markdown file (`.md`) defining the base system prompt. |
| `MINI_TOOL_ALLOWLIST` | String | — | Comma-separated list of permitted tool names. If set, all other tools are blocked. |
| `MINI_TOOL_BLOCKLIST` | String | — | Comma-separated list of blocked tool names. |
| `MINI_DEFERRED_TOOLS` | Boolean | `1` | Set `0` to disable deferred tool loading via the `tool_search` meta-tool. |
| `MINI_BUDGET_MAX_TOKENS` | Integer | `0` | Cumulative token budget cap for an entire task. `0` disables budget enforcement. |

### 2.3. Reasoning & Thinking Controls

| Variable | Type | Default | Description |
|---|---|---|---|
| `MINI_REASONING_EFFORT` | String | `null` | Reasoning effort for supported models: `"minimal"`, `"low"`, `"medium"`, `"high"`, or `"none"`. |
| `MINI_REASONING_EFFORT_DISABLED` | Boolean | `0` | Set `1` to strip reasoning effort parameters from all API requests. |
| `MINI_REASONING_MAX_TOKENS` | Integer | `null` | Explicit token budget ceiling for reasoning/thinking blocks. |
| `MINI_DYNAMIC_THINKING` | Boolean | `1` | Enables adaptive thinking governor, adjusting reasoning effort per turn based on complexity. |
| `MINI_SLOW_TURN_THRESHOLD_SECS` | Integer | `120` | Execution latency threshold (in seconds) before emitting a slow-turn diagnostic alert. |
| `MINI_THINKING_BUDGET_TOKENS` | Integer | `null` | Anthropic extended thinking token budget. |
| `MINI_MAX_TOKENS_CONTINUE_CAP` | Integer | `3` | Maximum automatic continuation turns if generation is truncated by `max_tokens`. |

### 2.4. MemAct Context & Memory Management

| Variable | Type | Default | Description |
|---|---|---|---|
| `MINI_MEMACT_ENABLED` | Boolean | `1` | Set `0` to completely disable long-term memory retrieval and extraction. |
| `MINI_CONTEXT_WINDOW` | Integer | Auto | Model context window size in tokens (auto-detected from model capabilities). |
| `MINI_CTX_COMPACT_THRESHOLD` | Float | `0.85` | Ratio of context window usage that triggers reactive compaction. |
| `MINI_CTX_SAFETY_MARGIN` | Float | `0.15` | Safety margin deducted from total context capacity. |
| `MINI_MEMACT_TOP_K` | Integer | `8` | Maximum relevant memory records injected into the context prompt. |
| `MINI_MEMACT_MEMORY_BUDGET` | Integer | `2000` | Maximum token allotment reserved for the retrieved memory block. |
| `MINI_MEMACT_EXTRACT` | Enum | `async` | Long-term memory extraction mode: `async` (background task), `sync`, or `off`. |
| `MINI_MEMACT_EXPANSION` | Boolean | `1` | Set `0` to disable dual-path BM25 query expansion during memory retrieval. |
| `MINI_MEMORY_DIR` | Path | `~/.mini/memory` | Custom directory for persisting project memory and knowledge stores. |

### 2.5. Procedural Graph (PGraph)

| Variable | Type | Default | Description |
|---|---|---|---|
| `MINI_MEMACT_PG_ENABLED` | Boolean | `1` | Set `0` to disable the Procedural Knowledge Graph engine. |
| `MINI_MEMACT_PG_ADVISORY` | Boolean | `1` | Set `0` to silence procedural advisory and checkpoint notifications in stderr. |
| `MINI_MEMACT_PG_H` | Integer | `2` | Hop distance ($H$) for extracting localized graph neighborhoods around active tools. |
| `MINI_MEMACT_PG_W` | Integer | `3` | Window size ($W$) of recent trajectory acts evaluated for graph localization. |
| `MINI_MEMACT_PG_AUTO_POPULATE` | Boolean | `1` | Automatically learn and persist frequent tool transitions ($N \ge 3$) across sessions. |

### 2.6. Action Loop Circuit Breaker

| Variable | Type | Default | Description |
|---|---|---|---|
| `MINI_ACTION_LOOP_CONSECUTIVE_CAP` | Integer | `3` | Maximum consecutive identical tool calls before circuit breaker trips. |
| `MINI_ACTION_LOOP_WINDOW_CAP` | Integer | `4` | Maximum identical tool calls within a sliding window before tripping. |
| `MINI_ACTION_LOOP_READONLY_WARN_CAP` | Integer | `5` | Consecutive read-only exploratory actions before warning advisory is logged. |
| `MINI_ACTION_LOOP_READONLY_TRIP_CAP` | Integer | `10` | Consecutive read-only actions before tripping the circuit breaker. |
| `MINI_ACTION_LOOP_MACRO_CYCLE_CAP` | Integer | `2` | Repetition threshold for alternating macro-tool cycles. |
| `MINI_ACTION_LOOP_DISPLAY` | Boolean | `1` | Set `0` to suppress action loop warnings from terminal output. |

### 2.7. Structured Planning System

| Variable | Type | Default | Description |
|---|---|---|---|
| `MINI_ENABLE_STRUCTURED_PLANNING` | Boolean | `1` | Enables DAG-based planning engine and plan parsing. |
| `MINI_PLAN_DRIFT_DETECTION` | Boolean | `1` | Automatically detects when agent actions diverge from the active plan. |
| `MINI_PLAN_MAX_STEPS` | Integer | `20` | Upper limit on steps allowed in a single generated plan. |
| `MINI_PLANS_DIR` | Path | `~/.mini/plans` | Storage directory for active and archived plans. |
| `MINI_PLAN_VERIFICATION_GATE` | Boolean | `0` | Set `1` to require automated verification checks before marking plan steps complete. |
| `MINI_PLAN_APPROVAL_GATE` | Boolean | `0` | Set `1` to prompt user for explicit interactive approval before executing a plan. |
| `MINI_PLAN_SUBAGENT_DISPATCH` | Boolean | `0` | Set `1` to dispatch independent plan steps to parallel subagents. |
| `MINI_PLAN_REVIEW_GATE` | Boolean | `0` | Set `1` to mandate a two-stage code review after subagent execution. |

### 2.8. Durable Tasks, Sessions & Journaling

| Variable | Type | Default | Description |
|---|---|---|---|
| `MINI_SESSION` | String | — | Session identifier. Automatically loads and saves to `~/.mini/sessions/<id>.json`. |
| `MINI_SESSION_FILE` | Path | — | Direct path to a specific session JSON file. |
| `MINI_NO_HISTORY` | Boolean | `0` | Set `1` to run without persisting conversation history. |
| `MINI_JOURNAL_KEEP` | Integer | `10` | Maximum historical `journal_*.jsonl` files retained before automatic pruning. |
| `MINI_TASKS_DIR` | Path | `~/.mini/tasks` | Directory for durable task checkpoints under RFC-030. |

### 2.9. Media & Vision Generation

| Variable | Type | Default | Description |
|---|---|---|---|
| `MINI_IMAGE_INPUT_ENABLED` | Boolean | `1` | Enables ingestion of `@image:<path>` markers in user prompts. |
| `MINI_IMAGE_INPUT_MAX_PER_TURN` | Integer | `5` | Maximum image attachments parsed in a single turn. |
| `MINI_IMAGE_INPUT_MAX_BYTES` | Integer | `10485760` | Maximum file size for input images (default: 10 MB). |
| `MINI_IMAGE_GEN_ENABLED` | Boolean | `0` | Set `1` to enable the `generate_image` tool. |
| `MINI_IMAGE_GEN_MODEL` | String | `gpt-image-1` | Model ID for image generation (e.g. `dall-e-3`). |
| `MINI_IMAGE_GEN_SIZE` | String | `1024x1024` | Target resolution for generated images. |
| `MINI_VIDEO_GEN_ENABLED` | Boolean | `0` | Set `1` to enable the `generate_video` tool. |
| `MINI_MEDIA_OUTPUT_DIR` | Path | `<workspace>/media` | Directory where generated images and videos are written. |

### 2.10. Observability & Lifecycle Hooks

| Variable | Type | Default | Description |
|---|---|---|---|
| `MINI_HOOK_COMMAND` | String | — | Shell command executed on agent lifecycle events. Receives event payload via stdin. |
| `MINI_HOOKS_CONFIG` | Path | — | Path to a structured `hooks.json` configuration file. |
| `MINI_MCP_CONFIG` | Path | `~/.mini/mcp.json` | Path to Model Context Protocol server configuration file. |

---

## 3. Example Configurations

### OpenAI GPT-4o with Native Reasoning
```bash
export OPENAI_COMPAT_URL="https://api.openai.com/v1"
export OPENAI_COMPAT_API_KEY="sk-proj-..."
export OPENAI_COMPAT_MODEL="gpt-4o"
export OPENAI_PROTOCOL="auto"
export MINI_DYNAMIC_THINKING="1"
```

### Anthropic Claude 3.5 Sonnet / 3.7 Sonnet
```bash
export ANTHROPIC_API_KEY="sk-ant-..."
export CLAUDE_MODEL="claude-3-7-sonnet-20250219"
export MINI_THINKING_BUDGET_TOKENS="4096"
```

### Local Ollama Server
```bash
export OLLAMA_HOST="http://localhost:11434"
export OLLAMA_MODEL="qwen2.5-coder:32b"
export MINI_EXECUTION_MODE="codeact"
```

### OpenRouter Multi-Provider Setup
```bash
export OPENAI_COMPAT_URL="https://openrouter.ai/api/v1"
export OPENAI_COMPAT_API_KEY="sk-or-..."
export OPENAI_COMPAT_MODEL="deepseek/deepseek-chat"
export OPENAI_COMPAT_PROVIDER="deepseek"
```
