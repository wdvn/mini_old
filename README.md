# mini-agent overview

Terminal AI agent, code-centric: the agent writes JavaScript executed within an embedded CodeAct VM to invoke tools, rather than calling isolated tools one by one.

mini-agent is a command-line AI agent written in Zig: it accepts prompts, autonomously plans steps, and executes by running shell commands, reading/editing files, making HTTP requests, searching the web, or controlling a browser. Results from each turn are fed back to the model until task completion; all operations run inside a single binary without external runtime dependencies.

## What do you need?

| If you... | Use | Why |
|---|---|---|
| Run an interactive agent in the terminal | [REPL](#interactive-repl) | Streaming conversation turns, slash commands, on-the-fly backend switching |
| Run a single prompt and exit (scripts, cron) | [Single-shot](#single-shot) | `-e` flag or positional argument, exits immediately upon completion |
| Use agent inside Zed or JetBrains | [ACP server](#acp-agent-client-protocol) | JSON-RPC 2.0 over stdin/stdout following Agent Client Protocol standard |
| Persist/restore conversation context across runs | [Session](#session-persistence) | Automatically persist history to JSON file, restore in subsequent runs |
| Extend capabilities with external tools | [MCP](#mcp-model-context-protocol) | Connect to any MCP servers over JSON-RPC stdio |
| Audit/monitor all agent actions | [Hooks](#hooks-monitoring--observability) | Hook scripts run on all lifecycle events, tool calls, and streaming chunks |

## Capability map

| Capability | What it does | Learn more |
|---|---|---|
| AI Backends | OpenAI-compatible (Chat Completions & Responses API), Anthropic Claude, Ollama local | [AI Backends](#ai-backends) |
| Built-in tools | 15 tools: shell, file, glob, grep, HTTP, subagents, artifacts, session diagnostics, skills, codeact | [Tools](#tools) |
| CodeAct runtime | Agent writes JS in ```js``` blocks running on embedded CodeAct engine, calling `mini.*` APIs (Per-Act VM isolation) | [Execution modes](#execution-modes) |
| MemAct | Automatic context compaction (Reactive Compaction) when exceeding context window limits | [MemAct & Context](#memact--context-management) |
| Workspace `.agent/` | Local configuration directory: instructions (`AGENTS.md`), project skills, custom slash commands | [Workspace .agent](#agent-workspace-folder) |
| Session persistence | Save/restore conversations and audit journals (`journal_*.jsonl`) by ID | [Session](#session-persistence) |
| Hooks & Sidecars | Script hooks at all lifecycle events and tool calls; proxy router integration for latency/TPS optimization | [Hooks](#hooks-monitoring--observability) |
| MCP | Consume tools from external MCP servers via stdio JSON-RPC | [MCP](#mcp-model-context-protocol) |
| ACP | Integrate into Zed AI, JetBrains as external agent | [ACP](#acp-agent-client-protocol) |
| Artifacts | Export plans, reports, HTML/SVG to session directory, trigger preview hooks | [Tools](#tools) |
| Tool policy | Allowlist/blocklist controlling tool execution (applied to both JSON tools and JS bindings) | [Tool policy](#tool-policy) |
| Cron | Install cron jobs for recurring single-shot execution | [Cron](#cron-recurring-execution) |

## Quickstart

```bash
git clone <repo-url> && cd mini
zig build
./scripts/setup_home_mini.sh    # Initialize ~/.mini directory and sync skills/config
./zig-out/bin/mini --version
```

Zig 0.16.0 requirement:

```bash
curl -LO https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz
tar -xf zig-x86_64-linux-0.16.0.tar.xz
export PATH="$PWD/zig-x86_64-linux-0.16.0:$PATH"
```

Configure backend (choose one of three):

```bash
export OPENAI_COMPAT_URL=https://api.openai.com/v1
export OPENAI_COMPAT_API_KEY=sk-...

# or Claude
export ANTHROPIC_API_KEY=sk-ant-...

# or local Ollama (no key needed)
export OLLAMA_HOST=http://localhost:11434
```

Run:

```bash
./zig-out/bin/mini -e "Summarize the README.md of this project"
```

Build details: [Build](#build--test).

## AI Backends

Agent selects backends in priority order:

1. **OpenAI-compatible** — when `OPENAI_COMPAT_URL` is set (supports both Chat Completions API & Responses API with auto-negotiation)
2. **Anthropic Claude** — when `ANTHROPIC_API_KEY` is set
3. **Ollama** — local fallback

| Environment Variable | Description | Default |
|---|---|---|
| `OPENAI_COMPAT_URL` | Base URL for OpenAI-compatible API | — |
| `OPENAI_COMPAT_MODEL` | Model name | `gpt-4o-mini` |
| `OPENAI_COMPAT_API_KEY` | API key | — |
| `OPENAI_COMPAT_API_HEADER` | HTTP header name containing key | `Authorization` |
| `OPENAI_PROTOCOL` | OpenAI protocol: `auto`, `chat_completions`, `responses` | `auto` |
| `ANTHROPIC_API_KEY` | Claude API key | — |
| `CLAUDE_MODEL` | Claude model ID | `claude-opus-4-5` |
| `OLLAMA_HOST` | Ollama server URL | `http://localhost:11434` |
| `OLLAMA_MODEL` | Ollama model name | `llama3` |

Switch backends in REPL using `/model <backend> [model]`, where `backend` is one of `openai` | `claude` | `ollama`.

#### Dual-Protocol Auto-Negotiation (OpenAI & Responses API)

For next-gen reasoning models (e.g. GPT-5.x, o3-pro) requiring the Responses API when combining reasoning with function calling:
- When `OPENAI_PROTOCOL=auto`, `mini` automatically identifies model prefixes or falls back between `/chat/completions` and `/responses` on HTTP 400 errors.
- Remembers negotiated protocol for the session (Session Cache) to eliminate probing overhead on subsequent turns.

Different endpoint examples:

```bash
# OpenRouter (multi-model)
export OPENAI_COMPAT_URL=https://openrouter.ai/api/v1
export OPENAI_COMPAT_MODEL=anthropic/claude-3-5-sonnet

# LM Studio local
export OPENAI_COMPAT_URL=http://localhost:1234/v1
```

## Configuration

mini-agent reads configuration from environment variables. `.env` files are automatically loaded in order:

1. `$MINI_ENV_FILE` — explicit path
2. `./.env` — current working directory (project-level)
3. `~/.mini/.env` — user-level

> Variables already present in the shell environment **are not overwritten** by `.env` files.

`.env` syntax supports `KEY=value` declarations (with or without quotes), `export` prefix, and `#` comments.

### General Environment Variables

| Variable | Description | Default |
|---|---|---|
| `MINI_HOME` | Root directory for config, sessions, artifacts, skills | `~/.mini` |
| `MINI_MAX_TOKENS` | Maximum tokens per response | `8192` |
| `MINI_SYSTEM_FILE` | Path to custom system prompt file (`.md`) | — |
| `MINI_NO_HISTORY` | Set `"1"` to disable saving conversation history | — |
| `MINI_EXECUTION_MODE` | Execution mode: `codeact`, `tools`, `auto` | `auto` |
| `MINI_TOOL_ALLOWLIST` | Comma-separated list of allowed tools | — |
| `MINI_TOOL_BLOCKLIST` | Comma-separated list of blocked tools | — |
| `MINI_MCP_CONFIG` | Path to `mcp.json` file | `<MINI_HOME>/mcp.json` |
| `MINI_HOOK_COMMAND` | Monitoring hook command | — |
| `MINI_HOOKS_CONFIG` | Path to hooks configuration file (`hooks.json`) | — |
| `MINI_SESSION` | Session ID (stored at `<MINI_HOME>/sessions/<id>.json`) | — |
| `MINI_SESSION_FILE` | Direct path to session JSON file | — |
| `MINI_ENV_FILE` | Explicit `.env` path | — |
| `MINI_BUDGET_MAX_TOKENS` | Maximum token consumption budget for a task (RFC-002) | `0` (unlimited) |

### MemAct & Context Management (RFC-003)

| Variable | Description | Default |
|---|---|---|
| `MINI_MEMACT_ENABLED` | Set `"0"` to disable MemAct | `1` (enabled) |
| `MINI_CONTEXT_WINDOW` | Model context window size in tokens | Auto per backend |
| `MINI_CTX_COMPACT_THRESHOLD` | Active / fallback compaction threshold | `0.85` |
| `MINI_CTX_SAFETY_MARGIN` | Context safety margin | `0.15` |
| `MINI_MEMACT_TOP_K` | Maximum memory items to inject into prompt | `8` |
| `MINI_MEMACT_MEMORY_BUDGET` | Token budget dedicated to memory block | `2000` |
| `MINI_MEMACT_EXTRACT` | Long-term memory extraction mode: `async`, `sync`, `off` | `async` |
| `MINI_MEMORY_DIR` | Directory for storing memories | `~/.mini/memory` |

> **Reactive Compaction (v0.3)**: When the LLM backend returns a context length error (e.g. HTTP 400 Context Length Exceeded), mini-agent automatically triggers history summarization and compaction (drops intermediate messages, inserts structured summary at index 1, preserves initial prompt at index 0) and re-executes the request automatically.

### Tool Policy

- Allowlist has higher priority than blocklist: when set, only tools in the allowlist can run.
- **Multi-tier enforcement**: Policy is strictly enforced across both **Native JSON Tool Calling** and **CodeAct JavaScript Bindings** (`mini.sh`, `mini.write`, `mini.patch`, `mini.read`, etc.).

```bash
# Allow only file reading and search tools
MINI_TOOL_ALLOWLIST=file_read,glob,grep mini-agent

# Block shell execution in both JSON tools and CodeAct VM
MINI_TOOL_BLOCKLIST=bash mini-agent
```

## Usage

### Interactive REPL

```bash
# Start REPL
mini-agent

# Custom system prompt
mini-agent --system ./my_system.md

# Specific backend
mini-agent --model claude

# Disable MCP connections
mini-agent --no-mcp
```

Slash commands:

| Command | Description |
|---|---|
| `/help` | View list of commands and tools |
| `/clear` | Clear conversation history and screen |
| `/model <backend> [model]` | Switch backend (`openai`, `claude`, `ollama`) |
| `/quit`, `/exit`, `/q` | Exit |

```
You > /model claude
[agent] Switched to claude (claude-opus-4-5)

You > /model openai gpt-4o
[agent] Switched to openai-compat (gpt-4o)
```

### Single-shot

```bash
# Using -e / --exec flag
mini-agent -e "Summarize README.md of this project"

# Or positional argument
mini-agent "What is today's date?"

# In shell scripts
RESULT=$(mini-agent -e "Write a unit test for a fibonacci function")
echo "$RESULT" > test_fibonacci.py
```

### Execution Modes

Execution modes (via `-m`/`--mode` flag or `MINI_EXECUTION_MODE`):

- **`auto`** (default) — model chooses response format.
- **`codeact`** — agent writes JavaScript in ```js ... ``` blocks running in the embedded CodeAct engine (ES2023+), calling tools via the `mini.*` object:
  - **Per-Act VM Isolation**: Each turn creates an isolated `JSContext` to prevent variable scope conflicts and redeclaration errors between acts.
  - File I/O: `mini.read`, `mini.write`, `mini.patch`, `mini.exists`, `mini.stat`.
  - Search: `mini.glob`, `mini.grep`.
  - Shell: `mini.sh`, `mini.shStream`, `mini.shBackground` + job management (`mini.jobStatus`, `mini.jobLogs`, `mini.jobKill`).
  - Others: `mini.http`, `mini.artifact`, `mini.env`.
  - Safety: Automatically intercepts pseudo-XML (`<file_read>`, `<bash>`) and converts them to JS blocks; enforces allowlist/blocklist and hook dispatch at C bindings.
- **`tools`** — agent calls individual tools via traditional JSON schemas.

Explicit CodeAct execution:

```bash
mini-agent -m codeact -e "Use mini.sh to run 'date +%s' and report result"
```

### Execution Rules

The agent adheres to core operational rules injected directly into the system prompt:
1. **Stop on Completion**: As soon as sufficient data is gathered or the goal is achieved, stop calling tools and reply immediately without redundant actions.
2. **Confirm Before Mutation**: While investigating or diagnosing, do not modify files or configurations without explicit user instruction.
3. **Avoid Action Loops & Plan Ahead**: If an approach fails after 2–3 attempts or an exploratory loop occurs, formulate a concrete execution plan and proceed with an alternate strategy rather than repeating failed operations.
4. **Cognitive Efficiency**: Modulate thinking latency on routine operations with `mini.setThinking("low")`, reserving high effort for architecture and complex debugging.

### Session Persistence

```bash
# Load and automatically save session at ~/.mini/sessions/my-project.json
mini-agent --session my-project -e "My name is Alice."

# Continue context in subsequent command
mini-agent --session my-project -e "What is my name?"
# -> AI responds: "Alice."

# Or use custom JSON file path
mini-agent --session-file ./history.json -e "Analyze main.zig"
```

### Cron (Recurring Execution)

```bash
# Install cron job to run single-shot every 5 minutes
mini-agent --install-cron "*/5 * * * *" -e "say hello"
```

`--install-cron` requires `-e`. When executed, mini-agent:

1. Resolves its absolute binary path.
2. Safely escapes the `-e` argument content.
3. Installs the cron job via `crontab` (skips if identical entry exists).

### Hooks (Monitoring & Observability)

Configure via `MINI_HOOK_COMMAND` or `--hook-command` flag:

```bash
mini-agent --hook-command 'echo "[HOOK] $MINI_HOOK_EVENT tool=$MINI_TOOL_NAME" >> /tmp/mini_audit.log'
```

Event categories:

- **CLI lifecycle**: `pre-prompt`, `post-response`, `pre-tool-use`, `post-tool-use` (with `is_error` flag).
- **API streaming**: `message_start`, `content_block_start`, `content_block_delta`, `content_block_stop`, `message_delta`, `message_stop`.
- **MCP**: `OnNotification`, `OnRequest`, `OnError`.
- **Artifact**: `artifact_saved` (with name, path, type).

Hook scripts receive data via two channels:

1. Environment variables (by event type):
   - Common events: `MINI_HOOK_EVENT`, `MINI_PID`, `MINI_TIMESTAMP`.
   - Tool events: `MINI_TOOL_NAME`, `MINI_TOOL_INPUT`, `MINI_TOOL_RESULT`.
   - Prompt events: `MINI_USER_PROMPT`.
   - MCP events: `MINI_MCP_SERVER`, `MINI_MCP_METHOD`, `MINI_ERROR_MESSAGE`.
2. stdin: JSON payload containing complete event information.

Audit logger example (`monitor.py`):

```python
import sys, json

payload_raw = sys.stdin.read()
if payload_raw:
    data = json.loads(payload_raw)
    print(f"[MONITOR PID {data.get('pid')}] Event: {data.get('event')} | Data: {data}")
```

```bash
MINI_HOOK_COMMAND='python3 monitor.py >> /tmp/agent_telemetry.log' mini-agent -e "Create file /tmp/hello.txt"
```

#### Sidecar Proxy Pattern (e.g. OpenRouter Low-Latency & High-TPS Routing)

To route or optimize requests (e.g. automatically selecting the lowest latency or highest TPS provider on OpenRouter) **without modifying mini-agent source code**, combine hooks with a Sidecar Proxy:

1. Place sidecar proxy script (e.g. `openrouter_proxy.py`) and hook script in `~/.mini/hook/`.
2. The sidecar proxy runs in the background on `http://127.0.0.1:8787`, listens for requests, probes OpenRouter metrics (`/api/v1/endpoints/z-scores` or provider latency), and forwards to the optimal provider.
3. In `~/.mini/.env`, configure:
   ```bash
   OPENAI_COMPAT_URL=http://127.0.0.1:8787/v1
   MINI_HOOK_COMMAND=~/.mini/hook/pre_prompt_hook.sh
   ```
4. The hook script `pre_prompt_hook.sh` checks the proxy process, launches it if not running, and logs audit data prior to each prompt.

## Tools

15 built-in tools. The model autonomously decides which tool to call; run `skills` tool to self-list.

### bash

Run shell command, returning stdout + stderr.

```json
{ "command": "git log --oneline -5" }
```

Dangerous patterns (`rm -rf /`, fork bomb, `mkfs`, `dd if=`, `> /dev/sda`...) are blocked by safety filters.

### file_read

Read file content, returning numbered lines.

```json
{ "path": "src/main.zig", "offset": 100, "limit": 50 }
```

Limits: 2000 lines per call, max 10MB file size.

### file_write

Create or overwrite file; automatically creates parent directories.

```json
{ "path": "output/report.md", "content": "# Report\n..." }
```

Limits: cannot write to `/etc`, `/sys`, `/proc`, `/dev`.

### file_edit

Find old string (must be unique in file) and replace with new string.

```json
{
  "path": "src/main.zig",
  "old_string": "const VERSION = \"1.0.0\";",
  "new_string": "const VERSION = \"1.1.0\";"
}
```

### glob

Find files matching wildcard `*`, `**`, `?`.

```json
{ "pattern": "**/*.zig", "path": "./src" }
```

### grep

Recursively search file/directory contents. Returns `path:line:line_content`.

```json
{ "pattern": "fn main", "path": "./src", "case_insensitive": "true" }
```

Limits: 200 results, skips binary files and files > 1MB.

### http_request

Send HTTP request (GET/POST/PUT/DELETE/HEAD).

```json
{
  "url": "https://api.github.com/repos/ziglang/zig/releases/latest",
  "method": "GET",
  "headers": { "Accept": "application/json" }
}
```

Limits: max 30KB response, 30-second timeout.

### invoke_subagent

Spawn a subagent to perform complex tasks (directory analysis, multi-file refactoring).

```json
{ "task": "Analyze src/core structure and summarize module responsibilities" }
```

### batch_invoke_subagents

Run multiple subagents concurrently for independent tasks.

```json
{ "tasks": ["Detailed Task 1...", "Detailed Task 2..."] }
```

### skills

List or inspect tool details.

```json
{ "operation": "list" }
{ "operation": "detail", "name": "bash" }
```

### artifact_write / artifact_read / artifact_list

Manage artifacts — standalone deliverables (plans, walkthroughs, HTML/SVG previews) stored at `<MINI_HOME>/artifacts/<session_id>/`. Writing triggers `artifact_saved` hook for external live-preview UIs.

```json
{ "name": "plan.md", "content": "# Plan...", "type": "markdown" }
{ "name": "plan.md" }
{}
```

### session_diagnostics

Deep diagnosis and telemetry analysis for agent sessions:
- Reads and parses `journal_*.jsonl` in `~/.mini/sessions/`.
- Error taxonomy: `rate_limit_exceeded`, `provider_error` (HTTP 500, 502, 503, Cloudflare 520, 522), `context_length_exceeded`, `timeout`.
- Evaluates retry backoff effectiveness and file modification history (CAS snapshots).

```json
{ "action": "analyze_recent", "limit": 5 }
{ "action": "inspect_session", "session_id": "session-1234" }
```

### codeact

Directly executes JavaScript within the embedded QuickJS-ng engine. Standard output and return value are fed back into the next conversation turn.

```json
{ "code": "const files = mini.glob('**/*.zig'); console.log('Found:', files.length);" }
```

## Agent Workspace Folder (`.agent/`)

Per **RFC-005**, each project can contain an `.agent/` folder at its workspace root to manage local agent knowledge and behavior without polluting global configs:

```
.agent/
├── AGENTS.md               # Project-specific rules and instructions for agents
├── config.json             # Project runtime configuration (model, tool allowlist, etc.)
├── skills/                 # Skills adhering to Agent Skills standard (agentskills.io)
│   ├── codebase-analysis/
│   │   └── SKILL.md
│   └── root-cause-analysis/
│       └── SKILL.md
└── commands/               # Custom Slash Commands for REPL
    ├── review.md           # Invoked via /review
    └── deploy.md           # Invoked via /deploy
```

- **Skills Discovery**: Agent automatically discovers and loads skills from `.agent/skills/` (workspace) alongside `~/.mini/skills/` (global).
- **Custom Commands**: Any markdown file in `.agent/commands/<name>.md` becomes a `/<name>` command in REPL mode.

## MCP (Model Context Protocol)

Connect to external MCP servers via JSON-RPC 2.0 over stdio. Server tools are prefixed with `<server>__<tool>`.

Create `~/.mini/mcp.json` (or specify via `MINI_MCP_CONFIG`):

```json
{
  "servers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home/user/projects"]
    },
    "database": {
      "command": "python3",
      "args": ["-m", "mcp_server_sqlite", "mydb.sqlite"]
    }
  }
}
```

With this config, the agent can call `filesystem__read_file`, `database__query`... Disable MCP with `--no-mcp`.

## ACP (Agent Client Protocol)

Run as an ACP server for integration into Zed AI, JetBrains, or other ACP clients:

```bash
mini-agent --acp
```

Configuration in Zed AI (`settings.json`):

```json
{
  "agent": {
    "external_agents": {
      "mini": {
        "command": "mini-agent",
        "args": ["--acp"]
      }
    }
  }
}
```

Supported methods:

- `initialize` — handshake, negotiate protocolVersion (v1) and capabilities.
- `session/new` — initialize session with `cwd` and MCP server list.
- `session/load` — restore session from history file.
- `session/prompt` — receive prompt, stream real-time `session/update`:
  - `agent_message_chunk`: text response chunk.
  - `agent_thought_chunk`: thinking/reasoning stream.
  - `tool_call` & `tool_call_update`: tool invocation and execution state.
- `session/cancel` — cancel active turn.
- `session/close` — close and save context.
- `ping` — liveness check.

## Build & Test

```bash
zig build                 # Debug — binary at zig-out/bin/mini
sudo cp zig-out/bin/mini /usr/local/bin/mini-agent   # install to PATH
zig build -Doptimize=ReleaseSafe   # Production
zig build -Dtarget=aarch64-linux-gnu  # Cross-compile
```

### Multi-Tier All-In-One Test Suite

The project features an All-In-One automated test suite running 13/13 steps (159 tests passed, 4 skipped):

```bash
# Run entire test suite (Unit + Security Integration + E2E Mock LLM)
zig build test --summary all

# Run only unit tests and CodeAct integration tests (no Node.js required)
zig build test-unit
# or
zig build test -Dskip-e2e=true

# Run only E2E tests with mock LLM server
zig build test-e2e

# Specify alternate port for mock server if default port (8399) is occupied
zig build test -Dtest-port=8400
```

1. **Tier 1 (Unit Tests)**: 118 unit tests covering core, protocol, JSON parser, ANSI tokenizer, history, config, and tool handlers.
2. **Tier 2 (Integration Testcases)**: 45 tests in `testcases/test_codeact_security.zig` strictly verifying VM isolation (Per-Act VM isolation), tool policy allowlist/blocklist, hook dispatching, and CAS snapshot rollback.
3. **Tier 3 (E2E Mock LLM)**: Launches local SSE mock server (`scripts/mock_llm_server.js`) and tests 3 complete end-to-end flows: single-turn text, long streaming text, and multi-turn bash tool calls.

Multi-platform release packaging (Linux/macOS/Windows, x86_64/aarch64): `scripts/build_release.sh` outputs to `releases/`. GitHub Actions automatically builds and releases on push to tag `v*`.

## Architecture

```
src/
  main.zig            — entry point: CLI parsing, wiring, mode dispatcher
  core/               — agent loop, config, history (MemAct compaction),
                        hooks, journal + CAS snapshot (rollback), artifacts,
                        protocol, JSON utils, cron
  runtime/            — CodeAct engine, JS bindings (mini.*), background jobs
  tools/              — bash, file, glob, grep, http,
                        subagent, batch_subagent, artifact
  tooling/            — MCP client, tool registry (definitions + policy)
  ui/                 — line editor (UTF-8), REPL, unicode
  backends/           — openai, claude, ollama, sse transport
  acp/                — ACP server (JSON-RPC 2.0 stdio)
```

Agentic loop execution flow:

```
User input
    │
    ▼
history.addUser(text)
    │
    ▼
tools.getRelevantDefinitions(text)   ← filter tools by policy
    │
    ▼
┌────────────────────────────────────┐
│            Agentic Loop            │
│                                    │
│  backend.sendMessage()  (SSE/NDJSON streaming)
│        │                           │
│        ▼                           │
│  response.stop_reason?             │
│      ├── end_turn ────────────────►│ return
│      └── tool_use ──┐              │
│                     ▼              │
│           tools.executeTool() × N  │
│                     │              │
│                     ▼              │
│        history.addToolResults()    │
│                     └─── continue ─┘
└────────────────────────────────────┘
```

Internal design documentation: `docs/` directory (Numbered RFCs — CodeAct architecture, event sourcing, MemAct context memory, AGENTS.md standard).

## Examples

- [examples/arxiv/](examples/arxiv/README.md) — ArXiv Paper Aggregator: agent queries, filters, and summarizes Computer Science papers from arXiv, outputting a structured Markdown report.

## Contributing

### Adding a New Tool

1. Create `src/tools/mytool.zig` with `executeTool(alloc, io, input_json) ![]u8`.
2. Register in `src/tooling/registry.zig`:
   - Dispatch: `if (std.mem.eql(u8, name, "mytool")) return mytool.executeTool(alloc, io, input_json);`
   - Definition: add to `definitions` array (name, description, `input_schema_json`).
   - Core list: add `"mytool"` to `core_tools`.
3. Run `zig build test` — ensure all tests pass.

### Adding a New Backend

1. Implement `Client` with `sendMessage(system_prompt, msgs, tools, text_cb) !proto.Response`.
2. Register in `src/core/agent.zig` — `Backend` union and `AgentLoop.init()`.

## License

MIT — see [LICENSE](LICENSE).
