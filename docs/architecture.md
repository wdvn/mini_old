# mini-agent Architecture Specification

## 1. Executive Overview

`mini-agent` is an autonomous, terminal-based AI coding agent built with a **Code-Centric** execution model. Instead of relying on repetitive, isolated JSON tool invocations, the agent writes JavaScript programs executed inside an embedded, sandboxed QuickJS Virtual Machine. Tool interactions occur through a high-performance C-ABI bridge exposed as the `mini.*` runtime namespace.

The system is implemented entirely in **Zig 0.16.0** using the standard library and:
- **QuickJS** (statically linked): ES2023+ JavaScript engine for CodeAct execution.
- **Pure Zig HTTP/TLS** (`std.http.Client` & `src/lib/http_request.zig`): High-performance, streaming HTTP/1.1 and TLS transport built into the Zig standard library with zero external networking dependencies (no `libcurl`).

All runtime functionality—including the REPL line editor with bracketed paste, event-sourced memory, DAG-based plan orchestration, durable task checkpoints, and an Agent Client Protocol (ACP) server—compiles into a single self-contained binary with zero external runtime dependencies.

```
src/
├── main.zig              # Composition root: CLI parsing, DI wiring, execution dispatcher
├── core/                 # Agent loop, config, history, journaling, CAS, tasks, planning
├── runtime/              # QuickJS engine, JS bindings (mini.*), background process manager
├── tools/                # Native tool implementations (bash, file, grep, http, subagents)
├── tooling/              # Tool registry, multi-tier policy guards, MCP client
├── ui/                   # Terminal line editor (UTF-8), REPL, streaming chat renderer
├── backends/             # AI providers: OpenAI-compat, Claude, Ollama, provider profiles
├── lib/                  # Graph engine (CSR/CSC), HTTP client, image/media processing
└── acp/                  # Agent Client Protocol server (JSON-RPC 2.0 stdio)
```

---

## 2. High-Level System Architecture

The following diagram illustrates the end-to-end data flow and component relationships during a user interaction:

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

## 3. Core Subsystems

### 3.1. Agent Loop & State Machine (`src/core/agent.zig`)

The agent loop orchestrates multi-turn reasoning and acting cycles until a completion condition is reached:

1. **Context Preparation**: Assembles the conversation history, injects workspace context (`AGENTS.md`, detected project markers), retrieves relevant long-term memories via MemAct, and generates tool definitions matching active policy rules.
2. **Streaming Execution**: Dispatches context to the active backend over an SSE HTTP connection. The streaming tokens pass through `StreamEventParser` in `src/ui/chat_stream.zig`, segregating reasoning/thinking blocks from code/text.
3. **Execution Routing**:
   - If the model emits standard text with an `end_turn` signal, the turn finalizes and control returns to the user.
   - If the model emits a ```js code block (CodeAct mode) or JSON `tool_use`, the payload is routed to the runtime layer.
4. **Observation Feedback**: The stdout/stderr, return values, or tool errors are formatted into a `tool_result` message and appended to `History`.
5. **Reactive Context Compaction**: If an API call fails with HTTP 400 (Context Length Exceeded), the compaction engine automatically triggers, creating an extractive summary of turns at index 1 while preserving the root user prompt at index 0, and re-dispatches the request.

### 3.2. CodeAct JavaScript Engine (`src/runtime/`)

The CodeAct runtime executes model-generated JavaScript in a controlled environment:

- **Per-Act VM Isolation**: Each execution turn initializes an independent `JSContext`. This eliminates variable shadowing errors (`const`/`let` re-declarations) and prevents leaky state across turns while sharing the underlying `JSRuntime`.
- **Resource Sandboxing**: Configured with a 128 MB heap ceiling and a 1 MB stack limit. A preemptive interrupt watchdog halts script execution if a synchronous CPU burst exceeds 5.0 seconds.
- **C-ABI Bridge (`src/runtime/js_bindings.zig`)**: Maps all native capabilities to `mini.*` methods:
  - File operations (`mini.read`, `mini.write`, `mini.patch`, `mini.exists`, `mini.stat`)
  - Command execution (`mini.sh`, `mini.shStream`, `mini.shBackground`)
  - Process lifecycle (`mini.jobStatus`, `mini.jobLogs`, `mini.jobKill`)
  - Network requests (`mini.http`)
  - Skill and knowledge loading (`mini.skill`, `mini.artifact`)
  - Dynamic thinking regulation (`mini.setThinking`)
- **Safety Interceptor**: Automatically converts legacy pseudo-XML tags (such as `<file_read>` or `<bash>`) into syntactically valid JavaScript before evaluation.

### 3.3. Tool Registry & Policy Guard (`src/tooling/registry.zig`)

All tool executions—whether initiated via CodeAct `mini.*` calls or direct JSON schema tool calls—pass through a centralized policy gate:

- **Allowlist & Blocklist**: If `MINI_TOOL_ALLOWLIST` is defined, only explicitly enumerated tools may execute. If `MINI_TOOL_BLOCKLIST` is defined, listed tools are denied. The allowlist takes precedence.
- **Execution Guard**: Checks loop frequency counters and dedup hashes before allowing execution.
- **MCP Client Bridge (`src/tooling/mcp.zig`)**: Connects to external servers over stdio JSON-RPC 2.0. Discovered tools are dynamically exposed under the `<server>__<tool>` namespace.

### 3.4. Provider Abstraction & Dual-Protocol Negotiation (`src/backends/`)

`mini-agent` normalizes provider discrepancies across AI providers:

- **OpenAI-Compatible (`backends/openai.zig`)**:
  - **Dual-Protocol Auto-Negotiation**: Automatically arbitrates between the traditional Chat Completions API (`/v1/chat/completions`) and the newer Responses API (`/v1/responses`).
  - **Session Protocol Cache**: Remembers negotiated endpoint protocols to eliminate probing overhead on subsequent turns.
  - **Chinese Thinking Tag Filter**: Cleanses raw stream outputs of reasoning tokens like `<思考>` or `<推理>`.
  - **Provider Profiles (`backends/providers/`)**: Dedicated profiles configure provider-specific parameters for DeepSeek, Kimi, MiniMax, Qwen, GLM, vLLM, and xAI.
- **Anthropic Claude (`backends/claude.zig`)**: Native Messages API streaming, thinking token budgets, and input cache control.
- **Ollama (`backends/ollama.zig`)**: Local LLM execution over HTTP streaming.

### 3.5. Memory & Procedural Graph Engine (`src/core/memact/`, `src/lib/graph/`)

Context awareness is sustained across long sessions through two complementary mechanisms:

1. **MemAct Store (`src/core/memact/store.zig`)**: An append-only event-sourced log (`~/.mini/memory/<project_hash>/memory.jsonl`). It supports semantic, episodic, and project-state memory entries indexed via an in-memory BM25 tokenizer and case-insensitive keyword matcher.
2. **Procedural Knowledge Graph (`src/lib/graph.zig`)**:
   - Directed attributed graph serialized to `pgraph.jsonl`.
   - Converted on-demand to **Compressed Sparse Row (CSR)** and **Compressed Sparse Column (CSC)** compact arrays for sub-millisecond graph traversal.
   - Computes 2-hop neighborhoods to inject localized procedural guidance into the prompt.
   - Detects cycles via three-color DFS and automatically repairs them.
   - Learns frequent tool transitions ($N \ge 3$) automatically across sessions.

### 3.6. Structured Planning Engine (`src/core/plan/`)

For complex engineering tasks, `mini-agent` uses a Directed Acyclic Graph (DAG) planning system:

- **Dual-Format Parser (`parser.zig`)**: Extracts structured step lists from Markdown checklists or JSON DAG blocks.
- **Plan Store (`store.zig`)**: Persists active plans with optimistic concurrency control (CAS) at `~/.mini/plans/`.
- **Plan Monitor (`monitor.zig`)**: Tracks progress, flags execution drift when actions diverge from planned steps, and soft-enforces dependencies.
- **Plan Dispatcher (`dispatch.zig`)**: Dispatches independent plan steps to parallel subagents when configured.

### 3.7. Durable Task Layer (`src/core/task/`)

Following RFC-030, tasks survive crashes, interruptions, and power loss:

- **Checkpoint Persistence**: Conversation history and task metadata are durably appended to disk at act boundaries (`~/.mini/tasks/<task_id>/`).
- **Resumption**: Running `mini --resume <task_id>` or `mini --continue` loads the full conversation history up to the last successful act and continues without redundant re-planning.
- **Atomic Journaling (WAL)**: `journal_<pid>.jsonl` records structured act events, token consumption metrics, and execution latencies.

### 3.8. Two-Tier Configuration & Context Discovery (`src/core/config/`)

The configuration subsystem enforces a clean two-tier separation between user-wide defaults and project-specific constraints:

- **Global Tier (`~/.mini/`)**: Holds user-wide credentials (`~/.mini/.env`), default runtime options (`~/.mini/config.json`), universal behavioral guidelines (`~/.mini/AGENTS.md`), global skills (`~/.mini/skills/`), and persistent stores (`memory/`, `tasks/`, `cas/`, `sessions/`).
- **Project Workspace Tier (`<workspace_root>/` & `.agent/`)**:
  - Automatically identifies repository root via `MINI_WORKSPACE_ROOT`, `MINI_AGENT_FOLDER`, or markers (`build.zig`, `package.json`, `Cargo.toml`, `go.mod`).
  - Reads project environment (`./.env`, `.agent/.env`) and project options (`.agent/config.json`), overriding global values.
  - Implements **additive rule inheritance**: Aggregates `<workspace_root>/AGENTS.md` + `.agent/AGENTS.md` + `~/.mini/AGENTS.md` into `<RULE[AGENTS.md]>` in the system prompt.
  - Prioritizes project skills (`.agent/skills/`), overriding global skills with matching names.
  - Partitions long-term memory and knowledge graphs by workspace root hash (`~/.mini/memory/<project_hash>/`).

### 3.9. UI Terminal & Stream FSM (`src/ui/`)

- **Line Editor (`ui/editor.zig`)**: Custom byte-based editor supporting UTF-8 character widths, history traversal (↑/↓), word navigation, and an incremental parser for ANSI bracketed paste mode.
- **Streaming FSM (`ui/chat_stream.zig`)**: Finite-state machine that processes tokens in real-time, cleanly switching between thinking blocks, code evaluation progress spinners, live diff blocks, and markdown text.

---

## 4. Concurrency & Process Model

`mini-agent` maintains a deterministic single-process core with controlled external concurrency:

1. **Main Agent Thread**: Executes the REPL, reads CLI input, drives the state machine, and evaluates QuickJS scripts.
2. **Watchdog & Telemetry Coordinator (`src/core/watchdog.zig`)**:
   - Periodically monitors long-running generation turns.
   - Alerts the user if generation exceeds `slow_turn_threshold_secs`.
   - Triggers the QuickJS interrupt handler if execution hangs.
3. **Background Process Manager (`src/runtime/process_manager.zig`)**:
   - Spawns asynchronous child processes via `mini.shBackground`.
   - Redirects stdout and stderr to isolated log files in `~/.mini/jobs/`.
   - Provides non-blocking polling (`mini.jobStatus`), log slicing (`mini.jobLogs`), and process group termination (`mini.jobKill`).

---

## 5. Security & Isolation Architecture

| Layer | Security Mechanism |
|---|---|
| **JavaScript VM** | Sandboxed QuickJS: no native `require`, no `eval` of arbitrary C bindings. All host access is mediated through validated `mini.*` methods. |
| **Tool Policy** | Multi-tier allowlist and blocklist applied before execution at both the registry dispatch and C-ABI layer. |
| **Command Safety** | `bash` tool rejects dangerous commands (`rm -rf /`, fork bombs, raw block device writes). |
| **Filesystem Boundaries** | Native file tools prevent operations on system directories (`/etc`, `/proc`, `/sys`, `/dev`). Path traversal in skill sub-resources is strictly blocked. |
| **Content-Addressed Rollback** | Before mutating any file, SHA-256 CAS snapshots are recorded in `~/.mini/cas/`, enabling state auditing and recovery. |
