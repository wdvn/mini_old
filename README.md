# mini-agent

[![Zig 0.16.0](https://img.shields.io/badge/Zig-0.16.0-orange.svg)](https://ziglang.org/)
[![Architecture](https://img.shields.io/badge/Architecture-Code--Centric%20%7C%20QuickJS%20VM-blue.svg)](#core-architecture--codeact-paradigm)
[![Tests](https://img.shields.io/badge/Tests-544%20passed%20(21%2F21%20steps)-brightgreen.svg)](#testing--verification)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**`mini-agent`** is a high-performance, autonomous terminal AI coding agent written in **Zig 0.16.0**. It employs a **Code-Centric** execution model: instead of invoking isolated tools one-by-one via repetitive JSON RPC roundtrips, the agent writes structured JavaScript (`ES2023+`) executed inside an embedded, sandboxed QuickJS engine, interacting with the host system via high-speed C-ABI bindings (`mini.*`).

All agent subsystems—including an interactive line editor with bracketed paste, an event-sourced knowledge graph, DAG-based plan orchestration, crash-safe durable task resumption, and an Agent Client Protocol (ACP) server—compile into a **single self-contained binary** with zero external runtime dependencies.

---

## Technical Documentation Index

For in-depth architectural and developer documentation, consult the dedicated manuals in `docs/`:

| Technical Manual | Scope & Contents |
|---|---|
| 📐 [**System Architecture**](docs/architecture.md) | Architectural topology, component decomposition, state machines, and threading model. |
| ⚡ [**CodeAct Runtime & JS VM**](docs/codeact_runtime.md) | QuickJS sandboxing, Per-Act VM isolation, and complete `mini.*` JavaScript API reference. |
| ⚙️ [**Configuration & Environment**](docs/configuration.md) | Precedence hierarchy, `.env` file loading, and complete environment variables dictionary. |
| 🛠️ [**Tools, Skills & MCP**](docs/tools_and_skills.md) | 15 built-in tools, RFC-031 multi-tier skills specification, custom slash commands, and MCP. |
| 🧠 [**Memory, Graph & Planning**](docs/memory_and_planning.md) | MemAct long-term store, Reactive Compaction, Procedural Graph (CSR/CSC), and DAG plans. |
| 🔌 [**AI Backends & Wire Protocols**](docs/backends_and_providers.md) | OpenAI Dual-Protocol Auto-Negotiation, Claude Messages API, Ollama, and provider profiles. |
| 💾 [**Durable Tasks & Sessions**](docs/durable_tasks_and_sessions.md) | RFC-030 durable checkpoints, cross-session resume (`--resume`), WAL journaling, and CAS. |
| 🖥️ [**Agent Client Protocol (ACP)**](docs/acp_server.md) | JSON-RPC 2.0 stdio specification and integration guides for Zed AI and JetBrains IDEs. |
| 🧪 [**Testing & Benchmarks**](docs/testing_and_benchmarks.md) | 3-tier test suite, mock LLM server, SWE-bench, BFCL, and ARC benchmark harnesses. |
| 📊 [**Graph Engine Internals**](docs/core/graph.md) | Low-level data structures, CSR/CSC traversal views, and graph cycle repair algorithms. |

---

## System Architecture

```
                          ┌────────────────────────────┐
                          │   Terminal / IDE Client    │
                          │ (REPL, Single-Shot, ACP)   │
                          └──────────────┬─────────────┘
                                         │ User Prompt / Input
                                         ▼
                          ┌────────────────────────────┐
                          │     src/main.zig           │
                          │  (Composition Root / CLI)  │
                          └──────────────┬─────────────┘
                                         │
                 ┌───────────────────────┴───────────────────────┐
                 ▼                                               ▼
     ┌────────────────────────┐                     ┌────────────────────────┐
     │   Interactive REPL     │                     │     ACP Server         │
     │   (src/ui/repl.zig)    │                     │   (src/acp/server.zig) │
     └───────────┬────────────┘                     └───────────┬────────────┘
                 │                                               │
                 └───────────────────────┬───────────────────────┘
                                         ▼
                          ┌────────────────────────────┐
                          │    Agent Loop (Core)       │
                          │   (src/core/agent.zig)     │
                          └──────┬───────────────▲─────┘
             1. Query / Context  │               │ 4. Observation / Tool Results
                                 ▼               │
    ┌───────────────────────────────────┐        │
    │        Backend Adapter Layer      │        │
    │ (OpenAI-compat, Claude, Ollama)   │        │
    │  - Dual-Protocol Auto-Negotiation │        │
    │  - Streaming SSE / Chunk Parser   │        │
    └─────────────────┬─────────────────┘        │
                      │ 2. SSE Tokens / JS Block │
                      ▼                          │
    ┌───────────────────────────────────┐        │
    │    CodeAct Runtime Sandbox        │        │
    │ (src/runtime/quickjs_engine.zig)  │        │
    │  - Per-Act VM Isolation           │        │
    │  - Resource Limits (128M / 5s)    │        │
    └─────────────────┬─────────────────┘        │
                      │ 3. mini.* Tool Invocations
                      ▼                          │
    ┌───────────────────────────────────┐        │
    │      Tool Registry & Policy       ├────────┘
    │   (src/tooling/registry.zig)      │
    │  - Allowlist / Blocklist Guard    │
    │  - Builtin Tools & MCP Dispatcher │
    └─────────────────┬─────────────────┘
                      ▼
    ┌────────────────────────────────────────────────────────┐
    │ Persistence, Telemetry & Storage Engine                │
    │  - MemAct Memory Store (~/.mini/memory/memory.jsonl)   │
    │  - Procedural Graph (~/.mini/memory/pgraph.jsonl)      │
    │  - Durable Task Store (~/.mini/tasks/)                 │
    │  - CAS File Snapshots (~/.mini/cas/)                   │
    │  - Write-Ahead Journal (~/.mini/sessions/journal_*.log)│
    └────────────────────────────────────────────────────────┘
```

---

## Core Capabilities

- **CodeAct JavaScript Engine**: Evaluates programs inside QuickJS with **Per-Act VM Isolation** (independent `JSContext` per act to eliminate global scope pollution) and a CPU burst watchdog.
- **Dual-Protocol Auto-Negotiation**: Automatically arbitrates between the Chat Completions API (`/v1/chat/completions`) and Responses API (`/v1/responses`) for reasoning models, caching the negotiated protocol per session.
- **Reactive Context Compaction**: Triggers automatically on HTTP 400 (context limit overflow) to compress intermediate turns at index 1 while strictly preserving the initial user prompt at index 0.
- **Durable Task Checkpoints (RFC-030)**: Crash-safe task resumption (`--resume [id]`, `--continue`) via append-only history logs at act boundaries.
- **Multi-Tier Skills Standard (RFC-031)**: Structured skill packages with `SKILL.md`, `references/`, `templates/`, `scripts/`, rich YAML frontmatter, and path-traversal sandboxing.
- **Procedural Knowledge Graph**: Event-sourced graph serialized to `pgraph.jsonl`, compiling to CSR/CSC views for sub-millisecond 2-hop neighborhood guidance and automated tool transition learning ($N \ge 3$).
- **Structured Planning (RFC-019)**: DAG plan resolution, dual Markdown/JSON parsing, optimistic CAS persistence, and real-time execution drift monitoring.
- **Content-Addressed Storage (CAS)**: SHA-256 pre-mutation snapshots enabling instantaneous rollback and audit logging.
- **Agent Client Protocol (ACP)**: Native JSON-RPC 2.0 stdio server for integration into Zed AI, JetBrains, and external IDE clients.

---

## Quickstart

### 1. Prerequisites

- Linux (x86_64, aarch64), macOS (Apple Silicon, Intel), or Windows (WSL2/native).
- **Zig 0.16.0**:
  ```bash
  curl -LO https://ziglang.org/download/0.16.0/zig-linux-x86_64-0.16.0.tar.xz
  tar -xf zig-linux-x86_64-0.16.0.tar.xz
  export PATH="$PWD/zig-linux-x86_64-0.16.0:$PATH"
  ```

### 2. Build & Install

```bash
git clone https://github.com/wdvn/mini.git && cd mini
zig build

# Initialize user environment (~/.mini/ directory, skills library, config templates)
./scripts/setup_home_mini.sh

# Optional: Install to system PATH
sudo cp zig-out/bin/mini /usr/local/bin/mini-agent
```

### 3. Configure AI Backend

Configure your preferred backend in your shell or `~/.mini/.env`:

```bash
# Option A: OpenAI-compatible (OpenAI, OpenRouter, LM Studio, vLLM, DeepSeek)
export OPENAI_COMPAT_URL="https://api.openai.com/v1"
export OPENAI_COMPAT_API_KEY="sk-..."
export OPENAI_COMPAT_MODEL="gpt-4o"

# Option B: Anthropic Claude
export ANTHROPIC_API_KEY="sk-ant-..."
export CLAUDE_MODEL="claude-3-7-sonnet-20250219"

# Option C: Local Ollama (zero configuration fallback)
export OLLAMA_HOST="http://localhost:11434"
export OLLAMA_MODEL="qwen2.5-coder:32b"
```

### 4. Run

```bash
# Single-shot prompt
mini-agent -e "Analyze the repository structure and list top modules"

# Interactive REPL
mini-agent
```

---

## Execution Modes

| Mode | Command | Description |
|---|---|---|
| **Interactive REPL** | `mini-agent` | Terminal line editor with streaming markdown, real-time thinking displays, bracketed paste, and slash commands. |
| **Single-Shot** | `mini-agent -e "<prompt>"` | Executes a prompt, runs required tools or JavaScript in the VM, prints the final result, and exits. |
| **ACP Server** | `mini-agent --acp` | Runs as a JSON-RPC 2.0 daemon over stdio for IDE integration (Zed AI, JetBrains). |
| **Task Resume** | `mini-agent --resume [id]` | Restores full context from a durable checkpoint (RFC-030) after an interruption or crash. |
| **Task Continue** | `mini-agent --continue` | Automatically locates and continues the most recent unfinished task in the current workspace. |
| **Cron Setup** | `mini-agent --install-cron "*/10 * * * *" -e "..."` | Installs an automated recurring single-shot execution into system `crontab`. |

---

## CodeAct JavaScript Reference (`mini.*`)

When running in CodeAct mode, the language model composes JavaScript using the `mini.*` runtime bridge:

```javascript
// Search repository and inspect files
const files = mini.glob("**/*.zig", "src");
console.log(`Found ${files.length} source files`);

const mainCode = mini.read("src/main.zig", 1, 50);

// Perform exact string substitution
mini.patch("src/main.zig", 'const VERSION = "1.0.0";', 'const VERSION = "1.1.0";');

// Execute shell command synchronously
const gitStatus = mini.sh("git status --short");
console.log("Git Status:\n", gitStatus);

// Launch background service and inspect logs
const jobId = mini.shBackground("npm run dev");
const status = mini.jobStatus(jobId);
console.log(`Dev server running on PID ${status.pid}`);

// Fetch external API
const res = mini.http("GET", "https://api.github.com/zen");
console.log("Zen:", res.body);

// Adjust cognitive reasoning effort for upcoming turns
mini.setThinking("high");
```

Full API specifications and error handling rules: [CodeAct Runtime Manual](docs/codeact_runtime.md).

---

## Built-in Tools Summary

| Tool | Category | Summary Description |
|---|---|---|
| `bash` | Execution | Runs shell commands with safety filters preventing destructive operations. |
| `file_read` | Filesystem | Reads file content with 1-indexed pagination and line limits. |
| `file_write` | Filesystem | Writes or overwrites files with automatic CAS pre-mutation snapshotting. |
| `file_edit` | Filesystem | Performs exact, unique string replacement. |
| `glob` | Search | Finds paths matching wildcard patterns. |
| `grep` | Search | Searches text using literal strings or regular expressions. |
| `http_request` | Network | Outbound HTTP requests via pure Zig `std.http.Client` with timeout and size bounds. |
| `invoke_subagent` | Multi-Agent | Spawns an isolated child agent to complete a dedicated sub-task. |
| `batch_invoke_subagents` | Multi-Agent | Executes multiple subagents in parallel for independent tasks. |
| `artifact_write` | Deliverables | Persists plans, diffs, or reports to session storage with live-preview hooks. |
| `artifact_read` | Deliverables | Reads saved session artifacts. |
| `artifact_list` | Deliverables | Lists all deliverables in the active session. |
| `session_diagnostics` | Telemetry | Inspects session logs, error taxonomy, token metrics, and thinking profiles. |
| `skills` | Knowledge | Discovers and inspects RFC-031 multi-tier skills and sub-resources. |
| `tool_search` | Meta | Performs deferred keyword discovery for extended tool capabilities. |
| `codeact` | Runtime | Direct JavaScript evaluation inside QuickJS. |

Detailed JSON schemas and operational constraints: [Tools & Skills Manual](docs/tools_and_skills.md).

---

## CLI & REPL Commands

### CLI Options

```
Usage: mini [options] [prompt]

Options:
  -e, --exec <prompt>      Execute prompt in single-shot mode and exit
  --single <prompt>        Run single prompt with explicit exit
  --mode, -m <mode>        Execution mode: auto (default), codeact, tools
  --model <backend>        Select backend: openai, claude, ollama
  --system <file>          Path to custom markdown system prompt
  --session <id>           Session identifier (stored at ~/.mini/sessions/<id>.json)
  --session-file <path>    Direct path to session JSON file
  --resume [task_id]       Resume task from durable checkpoint (RFC-030)
  --continue               Resume most recent unfinished task in workspace
  --acp                    Start in Agent Client Protocol server mode (stdio JSON-RPC)
  --install-cron <expr>    Install cron job for single-shot execution
  --hook-command <cmd>     Lifecycle hook command
  --no-mcp                 Disable Model Context Protocol server connections
  --mcp-config <path>      Custom path to mcp.json
  -v, --version            Display version information and build timestamp
  -h, --help               Display help message
```

### Interactive REPL Slash Commands

Within interactive REPL mode, commands start with `/`:

- `/help` — Display list of available commands and registered tools.
- `/clear` — Clear terminal screen and reset turn history.
- `/model <backend> [model]` — Switch backend (`openai`, `claude`, `ollama`) on the fly.
- `/session` — Display active session metadata and checkpoint status.
- `/quit`, `/exit`, `/q` — Orderly process exit.
- `/<custom>` — Any markdown prompt defined in `.agent/commands/<name>.md`.

---

## Configuration Cheatsheet

Configuration values resolve hierarchically: **CLI Flags** > **Shell Environment** > **`$MINI_ENV_FILE`** > **`./.env`** > **`~/.mini/.env`** > **Defaults**.

```ini
# ~/.mini/.env or ./.env

# AI Backend
OPENAI_COMPAT_URL=https://api.openai.com/v1
OPENAI_COMPAT_API_KEY=sk-...
OPENAI_COMPAT_MODEL=gpt-4o
OPENAI_PROTOCOL=auto

# Agent Behavior
MINI_EXECUTION_MODE=auto
MINI_MAX_TOKENS=8192
MINI_DYNAMIC_THINKING=1

# Tool Policy
MINI_TOOL_ALLOWLIST=bash,file_read,file_write,file_edit,glob,grep

# Context & Memory
MINI_MEMACT_ENABLED=1
MINI_MEMACT_TOP_K=8
MINI_MEMACT_MEMORY_BUDGET=2000

# Procedural Graph
MINI_MEMACT_PG_ENABLED=1
MINI_MEMACT_PG_AUTO_POPULATE=1
```

Exhaustive configuration reference: [Configuration Guide](docs/configuration.md).

---

## Testing & Verification

`mini-agent` features a pre-commit verified test suite covering all 21 compilation and verification steps (544+ tests passing, 0 leaks):

```bash
# Run entire All-In-One test suite (Unit + Security Integration + E2E Mock LLM)
zig build test --summary all

# Run unit and integration tests only (no Node.js required)
zig build test-unit

# Run E2E tests against local mock LLM server
zig build test-e2e
```

Full testing specifications and benchmark evaluation harnesses: [Testing Manual](docs/testing_and_benchmarks.md).

---

## Contributing

1. **Pseudocode First**: Outline changes in comments before modifying code.
2. **Standard Library**: Do not introduce external dependencies; use Zig standard library facilities.
3. **Pre-commit Gate**: Ensure `zig build test --summary all` passes with 21/21 steps green prior to proposing changes.

---

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.
