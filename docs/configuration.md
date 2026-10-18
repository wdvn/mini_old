# Configuration & Environment Variables Reference

## 1. Two-Tier Configuration Architecture: Global vs. Project

`mini-agent` uses a two-tier configuration hierarchy that cleanly separates machine-wide user defaults from repository-specific settings. This enables developers to establish global defaults across all tasks while maintaining strict, version-controlled project rules and tool permissions.

```
┌────────────────────────────────────────────────────────────────────────┐
│ Global Level (~/.mini/ or $MINI_HOME)                                  │
│  - User-wide credentials (~/.mini/.env)                                │
│  - Machine-wide settings (~/.mini/config.json)                         │
│  - Universal agent behavior rules (~/.mini/AGENTS.md)                  │
│  - Global skills library (~/.mini/skills/)                             │
│  - Global MCP server definitions (~/.mini/mcp.json)                    │
│  - Project-isolated stores (~/.mini/memory/<hash>/, ~/.mini/tasks/)    │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ Overridden / Supplemented by
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Project Workspace Level (<workspace_root>/ & .agent/)                  │
│  - Project environment overrides (./.env, .agent/.env)                 │
│  - Project runtime settings (.agent/config.json)                       │
│  - Project guidelines & conventions (AGENTS.md, .agent/AGENTS.md)      │
│  - Project-specific skills (.agent/skills/ -> overrides global)        │
│  - Project custom slash commands (.agent/commands/<name>.md)           │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ Overridden by
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Runtime Process & CLI Level                                            │
│  - Shell environment variables (export OPENAI_COMPAT_URL=...)          │
│  - Explicit dotenv file ($MINI_ENV_FILE)                               │
│  - Command-line flags (--model, --mode, --session, --resume)           │
└────────────────────────────────────────────────────────────────────────┘
```

### 1.1. Tier Comparison Matrix

| Component | Global Level (`~/.mini/`) | Project Workspace Level (`.agent/` & `<root>/`) | Precedence & Inheritance Behavior |
|---|---|---|---|
| **Environment (`.env`)** | `~/.mini/.env` | `<workspace_root>/.env`<br>`.agent/.env` | **Override**: Project `.env` values override Global `.env`. Shell variables take absolute precedence over both. |
| **JSON Config** | `~/.mini/config.json` | `.agent/config.json` | **Override**: Settings in `.agent/config.json` override keys in `~/.mini/config.json`. |
| **Instructions (`AGENTS.md`)** | `~/.mini/AGENTS.md` | `<workspace_root>/AGENTS.md`<br>`.agent/AGENTS.md` | **Additive / Concatenated**: All files are read and appended together into `<RULE[AGENTS.md]>` in the system prompt. |
| **Skills Library** | `~/.mini/skills/<name>/` | `.agent/skills/<name>/` | **Override**: Skills in `.agent/skills/` with matching names completely override global skills of the same name. |
| **Slash Commands** | `~/.mini/commands/<name>.md` | `.agent/commands/<name>.md` | **Registered**: Project commands become `/<name>` in REPL; global commands serve as defaults. |
| **MCP Servers** | `~/.mini/mcp.json` | Configured via `MINI_MCP_CONFIG` | **Direct**: Defaults to `~/.mini/mcp.json` unless overridden by environment variable or project JSON config. |
| **Memory & Graph** | `~/.mini/memory/<hash>/` | Keyed by workspace root hash | **Isolated**: Data is stored under `~/.mini/`, but strictly partitioned by the SHA-256 hash of the workspace directory. |
| **Checkpoints & Tasks** | `~/.mini/tasks/<task_id>/` | Bounded to `workspace_root` | **Global Store, Local Scope**: Task directories live in `~/.mini/tasks/` but store the canonical workspace path. |

---

### 1.2. Configuration Resolution Order

When resolving configuration settings, `mini-agent` evaluates sources in the following strict order (highest to lowest priority):

1. **CLI Arguments**: Command-line flags (e.g. `--model`, `--mode`, `--session`) take absolute precedence.
2. **Shell Environment Variables**: Variables explicitly exported in the current shell process (`export OPENAI_COMPAT_URL=...`).
3. **Explicit Dotenv File**: File specified via `MINI_ENV_FILE` or `--env-file`.
4. **Project Workspace Dotenv**: Local `./.env` in the current working directory.
5. **Project Agent Dotenv**: `.agent/.env` in the workspace.
6. **Project JSON Configuration**: `.agent/config.json` in the active workspace.
7. **Global User Dotenv**: `~/.mini/.env` (or `$MINI_HOME/.env`).
8. **Global User Configuration**: `~/.mini/config.json`.
9. **Provider Profiles**: Active provider JSON defaults from `~/.mini/providers/<name>.json` or builtin definitions.
10. **Hardcoded Defaults**: Safe fallbacks defined in `src/core/config/types.zig`.

> [!NOTE]
> Environment variables already present in the active shell environment are **never overwritten** by values loaded from `.env` or `config.json` files.

---

### 1.3. Project JSON Configuration Schema (`.agent/config.json`)

Projects can define a `.agent/config.json` to lock in repository-specific settings (such as model, allowed tools, execution mode, or reasoning tokens) without requiring team members to configure shell variables manually:

```json
{
  "execution_mode": "auto",
  "openai_compat_model": "gpt-4o",
  "tool_allowlist": "bash,file_read,file_write,file_edit,glob,grep",
  "max_tokens": 8192,
  "dynamic_thinking_enabled": true,
  "reasoning_effort": "high",
  "memact_enabled": true,
  "memact_top_k": 8,
  "enable_structured_planning": true,
  "plan_drift_detection": true,
  "action_loop_consecutive_cap": 3,
  "action_loop_readonly_trip_cap": 10
}
```

This file is typically committed to version control so all agents operating on the codebase adhere to identical runtime constraints.

---

### 1.4. Rule Inheritance & Aggregation (`AGENTS.md`)

Unlike configurations where local values override global keys, behavioral rules follow an **additive inheritance model**:

1. **Workspace Root Rules**: `<workspace_root>/AGENTS.md` (or `CLAUDE.md`) is read first, establishing project coding conventions and repository layout instructions.
2. **Agent Directory Rules**: `.agent/AGENTS.md` is appended, specifying agent-specific operational constraints and workflows.
3. **Global Machine Rules**: `~/.mini/AGENTS.md` is appended last, adding universal preferences (e.g. personal style preferences, sensitive data redaction policies).

All discovered rules are concatenated and enclosed in `<RULE[AGENTS.md]>` tags directly inside the system prompt before every turn.

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
