# Kiến trúc mini-agent

## Tổng quan

mini-agent là một terminal-based AI agent với kiến trúc **Code-Centric** — agent viết code JavaScript chạy trong một embedded VM (QuickJS), gọi các công cụ qua `mini.*` object. Dự án được viết bằng Zig 0.16.0, chỉ dùng standard library (ngoại lệ: libcurl động, QuickJS tĩnh).

```
src/
  main.zig            — Composition root: DI, CLI, khởi tạo các module
  core/               — Agent loop, config, history, hooks, protocol, JSON
  runtime/            — QuickJS engine, JS bindings (mini.*), process manager
  tools/              — Công cụ: bash, file, glob, grep, http, subagent...
  tooling/            — Registry & dispatch công cụ
  ui/                 — Terminal UI: editor, REPL, chat stream, markdown
  backends/           — AI providers: openai, claude, ollama
docs/                 — RFC proposals & technical docs
testcases/            — Unit tests + E2E mock LLM
```

---

## Luồng thực thi chính

```
User input
    │
    ▼
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│   UI / REPL  │────▶│  Agent Loop  │────▶│  Backend     │
│  (repl.zig)  │     │  (agent.zig) │     │  (openai/    │
│              │◀────│              │◀────│   claude/    │
│  streaming   │     │  TurnRenderer│     │   ollama)    │
└──────────────┘     └──────────────┘     └──────────────┘
                              │
                              ▼
                     ┌──────────────┐
                     │  Tool Call?  │
                     └──────────────┘
                        │ yes    no
                        ▼        ▼
                  ┌──────────┐  ┌──────────┐
                  │Registry  │  │  Finish  │
                  │dispatch  │  │  response│
                  └────┬─────┘  └──────────┘
                       │
               ┌───────┴────────┐
               ▼               ▼
         ┌──────────┐    ┌──────────────┐
         │ CodeAct  │    │ Direct tool  │
         │ (JS VM)  │    │ (Zig native) │
         └──────────┘    └──────────────┘
```

---

## Core Components

### 1. Agent Loop (`core/agent.zig`)

Vòng lặp chính xử lý input của user qua nhiều iteration:

```
user_text → history.addUser()
          → sendToBackend(system, history, tools)  ← streaming
          → response.stop_reason == .tool_use?
              YES → executeTools() → history.addToolResults() → continue
              NO  → finish, return
```

- Chọn backend tại startup: OpenAI-compatible → Claude → Ollama
- Hỗ trợ Retry loop cho transient transport errors
- Reactive compaction khi backend trả về context limit error

### 2. Protocol & Data Types (`core/protocol.zig`)

Shared types giữa backends, agent loop và tool dispatcher:

```zig
Message       // user/assistant role
ContentBlock  // text | thinking | tool_use | tool_result | image
ToolUse       // id, name, input_json
ToolResult    // tool_use_id, content, is_error
Response      // từ backend, chứa choices + finish_reason
ToolDefinition // tool schema gửi cho API
```

### 3. History (`core/history.zig`)

In-memory conversation history:
- Tự động compact khi số message > threshold (DEFAULT_MAX_MESSAGES = 40)
- Giữ lại half messages gần nhất khi compact
- CAS snapshot để rollback file changes

### 4. Config (`core/config.zig`)

Configured qua environment variables và `.env` files:

| Category | Variables |
|----------|-----------|
| Backend | `OPENAI_COMPAT_URL`, `ANTHROPIC_API_KEY`, `OLLAMA_HOST` |
| Agent | `MINI_MAX_TOKENS`, `MINI_REASONING_EFFORT`, `MINI_DYNAMIC_THINKING` |
| MemAct | `MINI_MEMACT_ENABLED`, `MINI_CONTEXT_WINDOW`, `MINI_MEMACT_TOP_K` |
| Tools | `MINI_TOOL_ALLOWLIST`, `MINI_TOOL_BLOCKLIST` |

Priority: env vars > `$MINI_ENV_FILE` > `./.env` > `~/.mini/.env`

### 5. Hooks (`core/hooks.zig`)

Lifecycle hooks system:
- Claude Code CLI hooks: pre-prompt, post-response, pre-tool-use, post-tool-use
- API streaming events: message_start, content_block_start/delta/stop, message_delta/stop
- In-memory listener callback

---

## Runtime Layer

### QuickJS Engine (`runtime/quickjs_engine.zig`)

Embedded JavaScript VM cho CodeAct mode:
- Sandbox isolation: 128MB RAM, 1MB stack limit
- Heartbeat watchdog: catch infinite loops (>5s CPU burst)
- Output capture: console.log → 64KB buffer (head-truncation)
- Stack trace extraction cho self-correction loops
- **Per-Act VM isolation**: mỗi Act có JSContext độc lập, không share global scope

### JS Bindings (`runtime/js_bindings.zig`)

C-ABI exports tất cả công cụ vào `mini.*` object:

```javascript
mini.read(path, offset?, limit?)
mini.write(path, content)
mini.patch(path, oldStr, newStr)
mini.exists(path), mini.stat(path)
mini.sh(command, opts?)           // synchronous
mini.shStream(command, opts?)     // streaming output
mini.shBackground(command, opts?) // returns jobId
mini.jobStatus(jobId)
mini.jobLogs(jobId, lines?)
mini.jobKill(jobId, signal?)
mini.http(method, url, opts?)     // → { status, body, truncated }
mini.artifact(name, content)
mini.env(varName)
mini.setThinking(levelOrTokens)
```

Security guard: tất cả tools phải pass qua allowlist/blocklist policy trước khi execute.

### Process Manager (`runtime/process_manager.zig`)

Background job management (OpenHands pattern):
- `spawnBackground()` — redirect stdout/stderr vào log file
- `getJobStatus()` — running/exitCode
- `readJobLogs()` — last N lines
- `killJob()` — safe kill (killpg)

---

## Tools System

### Registry (`tooling/registry.zig`)

Dispatcher trung tâm routing tool calls từ AI đến handlers:

```
AI tool_use → Registry
              ├── Allowlist check
              ├── Blocklist check
              ├── Core tools (always sent to API):
              │   bash, file_write, file_edit, http_request, skills
              ├── Extended tools (keyword-triggered):
              │   file_read, glob, grep (internal dispatch only)
              └── Subagent tools: subagent, batch_subagent
```

### Built-in Tools (`tools/`)

| Tool | Mô tả |
|------|-------|
| `bash.zig` | Chạy shell commands |
| `file.zig` | read/write/patch/delete files |
| `glob.zig` | File pattern matching |
| `grep.zig` | Content search |
| `http.zig` | HTTP requests (libcurl) |
| `subagent.zig` | Spawn single subagent |
| `batch_subagent.zig` | Spawn multiple parallel subagents |
| `artifact.zig` | Create/update artifacts |
| `session_diagnostics.zig` | Inspect session logs & telemetry |
| `media_gen.zig` | Image/video generation |

---

## Backends (`backends/`)

### OpenAI-Compatible (`backends/openai.zig`)

Support mọi endpoint compatible OpenAI Chat Completions:
- OpenAI, Ollama, LM Studio, vLLM, OpenRouter, custom endpoints

**Dual-protocol auto-negotiation**:
- Chat Completions API (`/v1/chat/completions`)
- Responses API (`/v1/responses`)
- Tự động switch và nhớ protocol đã chọn

**Thinking filter**: Lọc Chinese thinking tags (`<思考>`, `<推理>`, etc.)

### Provider Abstraction (`backends/provider.zig`)

Normalizes wire protocol differences:
- Protocol selection (Chat vs Responses)
- Reasoning parameter format
- Reasoning echo policy (DeepSeek assistant history)
- Chinese thinking tag filtering

### Other Backends
- `claude.zig` — Anthropic Claude API
- `ollama.zig` — Local Ollama server
- `js_provider.zig` — JavaScript provider adapter

---

## Procedural Graph

Event-sourced directed graph trong `~/.mini/memory/<project_hash>/pgraph.jsonl`:

```
PGraphStore
  ├── Graph (CSR representation)
  ├── Transitions map (tool frequency counting)
  └── Auto-populate pipeline
```

**3 responsibilities:**
- **PG-1**: Persistent storage replay
- **PG-2**: Learn frequent tool transitions (N ≥ 3)
- **PG-3**: Extract 2-hop neighborhood, inject ephemeral guidance blocks

---

## MemAct Memory

Long-term memory system:

```
MemoryStore (~/.mini/memory/<project_hash>/memory.jsonl)
  ├── Event-sourced append-only log
  ├── Keyword matching (ASCII case-insensitive)
  ├── Supersession (new entry replaces old)
  └── Touch-based access tracking
```

**Memory types:**
- `semantic` — general knowledge
- `episodic` — session-specific memories
- `project_state` — project state snapshots

**Config:**
- `MINI_MEMACT_ENABLED` — toggle on/off
- `MINI_MEMACT_TOP_K` — max injected items (default: 8)
- `MINI_MEMACT_MEMORY_BUDGET` — token budget (default: 2000)
- `MINI_MEMACT_EXTRACT` — async|sync|off

---

## Structured Planning

LLM-driven planning system với DAG dependency resolution:

```
Plan (JSON/Markdown)
  ├── PlanParser — dual-format extraction
  ├── PlanStore — CAS cross-turn persistence
  ├── PlanExecutor — step execution lifecycle
  └── PlanMonitor — drift detection (soft-enforcement)
```

**Step statuses:** pending → active → completed/failed/skipped

---

## CAS (Content-Addressed Storage) (`core/cas.zig`)

SHA-256 based file content storage:
- Store file contents indexed by hash
- Enable snapshot and rollback
- Path: `~/.mini/cas/`

---

## Journal / Event Sourcing (`core/journal.zig`)

Write-ahead log (WAL) for Act architecture:

**Event types:**
- `act_started`, `act_completed`, `act_failed`
- `llm_call_throttled`, `llm_provider_error`, `llm_context_overflow`
- `rollback_requested`, `rollback_completed`
- `task_completed`, `task_interrupted`
- `memact_compacted`, `checkpoint_created`

Retention: `~/.mini/sessions/journal_<pid>.jsonl`, max files controlled by `MINI_JOURNAL_KEEP`

---

## UI Layer (`ui/`)

### REPL (`ui/repl.zig`)

Interactive terminal interface:
- Slash commands: `/help`, `/model`, `/artifact`, `/clear`
- Streaming markdown & thinking text
- Image input parsing

### Chat Stream (`ui/chat_stream.zig`)

Unified stream event lifecycle pipeline:

```
AI Backend (SSE chunks)
    │
    ▼
StreamEventParser (FSM Lexer/Tokenizer)
    ├── .think_start/chunk/end
    ├── .codeact_start/chunk/end
    └── .text_start/chunk/end
    │
    ▼
TurnRenderer (UI FSM)
    ├── waiting → thinking → codeact_live → codeact_ready → tool_executing
    └── Telemetry Status Footer
```

### Editor (`ui/editor.zig`)

Incremental bracketed paste parser, UTF-8 width, single-line byte-based editing.

### Markdown (`ui/markdown.zig`)

Streaming markdown rendering.

---

## Graph Library (`lib/graph/`)

Procedural graph data structures:

```
lib/graph.zig
  ├── types.zig       — NodeId, EdgeId, NodeType, RelationType
  ├── csr.zig         — Compressed Sparse Row representation
  ├── algorithms.zig  — traversal, cycle repair, reachability
  ├── serialization.zig — JSONL event stream
  └── storage.zig     — persistent storage interface
```

---

## HTTP Library (`lib/http_request.zig`)

Thin wrapper around libcurl for AI API requests and web search.

---

## Media Library (`lib/media.zig`)

Image handling:
- Prompt parsing for image attachments
- Image block creation for protocol messages
- Max bytes/per-turn limits

---

## Testing

**All-In-One test suite** (`zig build test`):

| Tier | Command | Description |
|------|---------|-------------|
| 1 | `zig build test-unit` | Unit tests (core/tools/ui) |
| 2 | `zig build test-unit` | Integration testcases (security, VM isolation, CAS) |
| 3 | `zig build test-e2e` | E2E with mock LLM server (3 flows: text, stream, multi-turn) |

Mock server: `scripts/mock_llm_server.js` on port 8399.

---

## Execution Modes

| Mode | Flag | Description |
|------|------|-------------|
| Interactive | `mini` | REPL terminal mode |
| Single-shot | `mini -e "prompt"` | One-shot prompt execution |
| Cron Install | `mini --install-cron` | Linux cronjob setup |

---

## Key Design Principles

1. **Code-Centric**: Agent viết JS code trong embedded VM thay vì direct tool calls
2. **Per-Act VM Isolation**: Independent JSContext per act eliminates global scope pollution
3. **Event-Sourced Memory**: MemAct + PGraph dùng append-only JSONL logs
4. **Dual-Protocol Auto-Negotiation**: Switch giữa Chat Completions và Responses API
5. **Reactive Compaction**: Context compression chỉ trigger khi context limit error
6. **Structured Planning**: LLM-generated plans với DAG dependency resolution
7. **CAS File Snapshots**: Content-addressed storage cho rollback capability
