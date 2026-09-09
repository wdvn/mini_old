---
name: codebase-analysis
description: Analyze codebase structure, module architecture, execution flow tracing, and inter-component dependencies. Use when understanding architecture, mapping execution flow, or locating relevant components.
---

# Codebase Analysis Skill

Comprehensive guide for analyzing source code structure, mapping module responsibilities, and tracing data flow in the `mini` project.

---

## 1. When to Activate This Skill?

- When handling requests to analyze new features or understand how a module operates.
- When locating where specific logic is implemented (e.g., "where is slash command handling?", "how does SSE parse responses?").
- When mapping call flows from REPL -> Core Agent Loop -> Backends -> QuickJS VM.

---

## 2. 4-Step Codebase Analysis Process

### Step 1: Survey Directory Structure & Module Responsibilities
Quick layer breakdown:
```
src/
├── main.zig             # Entrypoint CLI & REPL wiring
├── core/                # Agent loop, config, history, protocol, journaling, MemAct
│   ├── agent.zig        # Act loop, error handling, compaction, state rollback
│   ├── config.zig       # Reads .env, config.json, environment variables
│   ├── history.zig      # Message history management, MemAct compaction
│   └── journal.zig      # Event sourcing logger (JSONL format)
├── runtime/             # QuickJS-ng engine, JS bindings (mini.*), process manager
│   ├── js_bindings.zig  # Implements all mini.read/write/sh/http... functions
│   └── quickjs_engine.zig
├── backends/            # AI Client adapters (OpenAI-compat, Claude, Ollama, SSE)
├── tools/               # Built-in tool implementations (bash, file, glob, search...)
├── tooling/             # MCP client, tool registry
└── ui/                  # REPL, Terminal UI, chat_stream, line editor
```

### Step 2: Locate Entrypoint & Trace Data Flow
- **Interactive REPL Flow**: `main.zig` -> `ui/repl.zig` -> `core/agent.zig:processInput` -> `core/agent.zig:executeStep`.
- **Single-shot Flow**: `main.zig:runSingleShot` -> `core/agent.zig:processInput`.
- **Backend Flow**: `core/agent.zig:sendToBackend` -> `backends/<backend>.zig:sendMessage` -> `lib/http_request.zig:postStream`.
- **CodeAct Execution Flow**: `core/agent.zig:findJsCodeInResponse` -> `runtime/quickjs_engine.zig:eval` -> `runtime/js_bindings.zig` -> `core/snapshot.zig`.

### Step 3: Pattern Matching & Search
- Locate function/struct definitions: `grep_search` with keywords `fn <function_name>` or `pub const <StructName>`.
- Find references: `grep_search` across `src/`.
- Review top-level `//!` doc-comments in each `.zig` file to quickly understand module responsibilities.

### Step 4: Synthesize Analysis Map
When answering or creating analysis documentation, structure findings into:
1. **Module Purpose**: Core functions and constraints.
2. **Data Flow**: Input -> Transform -> Output.
3. **Integration Points**: Interfaces / Structs.
4. **Memory & Concurrency Considerations**: Allocator, Threading, I/O.
