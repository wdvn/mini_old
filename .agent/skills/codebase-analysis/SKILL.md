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

---

## 3. Output Quality Rules: Readable & Non-Adhoc

### 3.1 Readable Output — Structured Presentation

Every analysis output must follow this consistent structure, regardless of topic:

```
## [Title]: [Component/Flow Name]
### Overview
[1–2 sentences summarizing what this component does.]

### Data Flow
Input → [transform] → Output
(Use arrows, not paragraphs, for flow descriptions.)

### Key Functions / Structs
| Name | Location | Responsibility |
|------|----------|----------------|
| `foo()` | `path/to/file.zig:42` | [One-line description] |

### Integration Points
- Called by: [list]
- Calls: [list]
- Shared types/interfaces: [list]

### Known Constraints
- [Memory, concurrency, protocol, or behavioral constraints]
```

Rules for readability:
- **No wall of text** — use tables, bullet lists, and arrows wherever possible.
- **Path + line number** on every reference (e.g., `core/agent.zig:128`).
- **One concept per section** — don't mix data flow with constraints in the same paragraph.
- **Keep it scannable** — a reader should grasp the answer in ≤10 seconds by scanning headings and tables.
- **Use backtick code references** for all identifiers: `fn processInput`, `error.UnknownStopReason`, `HistoryMessage`.

### 3.2 Non-Adhoc — Systematic, Repeatable Method

Never improvise the investigation path. Follow the defined 4-step process in order:

1. **Survey first, deep-dive second** — always run Step 1 (directory scan) before going into any file. Never jump straight to reading source.
2. **Trace before you conclude** — every claim about "how X works" must be backed by an observed call path, not inferred from names.
3. **Cite evidence for every assertion** — if you say "Y calls Z", you must show the grep result or line reference that proves it.
4. **One source of truth per question** — if multiple paths exist, document them explicitly as alternatives rather than picking one silently.
5. **Reuse the same output template** — always produce the structure from §3.1. Never invent a new format per answer.
6. **Verify before reporting** — cross-check any assumption against actual code before including it in the final output.

### 3.3 Anti-Patterns to Avoid

| Anti-pattern | Why it's bad | Correct approach |
|-------------|-------------|-----------------|
| Scattered file reads without prior directory survey | Misses context, leads to wrong conclusions | Step 1 first, then targeted Step 2–3 |
| Assertions without code references | Unverifiable, speculative | Every claim → `path.zig:line` or grep output |
| Mixed-flow paragraphs | Hard to parse, loses signal | Use tables and arrow notation for flows |
| Picking one hypothesis without mentioning alternatives | Confirmation bias, misses edge cases | List alternatives explicitly, explain why one wins |
| Inconsistent output format across answers | Reader has to re-adapt each time | Always use the §3.1 template |
| Skipping Step 1 because "I already know the structure" | Stale mental model, missed new files/modules | Re-run survey when the project has changed |
