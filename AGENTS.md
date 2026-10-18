# AGENTS.md

Instructions for AI coding agents working on the **mini-agent** repository. Read this file before making any code changes.

## Project Overview

- **Language**: Zig 0.16.0, standard library only (exception: QuickJS/CodeAct static link; networking uses pure Zig std.http with zero external libcurl dependency).
- **Type**: Terminal-based AI agent with a Code-Centric architecture (agent writes JS running inside an embedded CodeAct VM, calling tools via the `mini.*` object).
- **Layout**:

```
src/
  main.zig            — entry point, REPL wiring
  core/               — agent loop, config, history, hooks, protocol, JSON utils
  runtime/            — CodeAct engine, JS bindings (mini.*), process manager (background jobs)
  tools/              — tool implementations (bash, file, glob, grep, http, search, subagent, ...)
  tooling/            — MCP client, tool registry
  ui/                 — terminal UI: editor.zig (line editor), repl.zig
  backends/           — AI providers: openai.zig, claude.zig, ollama.zig, sse.zig
  acp/                — ACP server
docs/                 — proposals, technical documentation (English)
scripts/build_release.sh
scripts/setup_home_mini.sh — Initialize & sync skills/config for ~/.mini
testcases/            — all test files (standalone, integration, benchmarks, ...)
```

## Build & Run

- `zig build` → binary `zig-out/bin/mini`.
- `zig build run` → build + run interactive REPL.
- `zig build run -- -e "..."` → single-shot mode.
- `zig build test` → All-In-One test suite (Unit tests + Testcases + Mock LLM E2E).
- `zig build test-unit` → Run unit tests & testcases only (no Node.js/mock server required).
- `zig build test-e2e` → Run E2E tests only with mock LLM server.
- `zig build test -Dskip-e2e=true` → Run tests skipping the E2E mock layer.
- `zig build test -Dtest-port=<port>` → Change port for mock server (default: 8399).
- Setup user environment: `scripts/setup_home_mini.sh` (create/sync `~/.mini/`).
- Release: `scripts/build_release.sh`.
- Cross-compile: `zig build -Dtarget=x86_64-linux-gnu` (or `aarch64-linux-gnu`).

## Code Conventions

- **Primary language**: English. Code, comments, docstrings, user-facing output, and documentation must be in English.
- Every `.zig` module must have a top-level doc-comment `//!` describing its responsibilities.
- Do not add external dependencies unless discussed in a proposal — open a proposal first if necessary.
- All test files (scratch experiments, standalone tests, benchmarks...) must be placed in `testcases/` and named `test_*.zig` (do not leave test files in the root directory).
- Test-generated files (temp dirs, fixtures, scratch artifacts) must be created under `/tmp` (e.g. `/tmp/test_mini_<name>`, or `std.testing.tmpDir` which auto-cleans) and cleaned up via `defer` — never relative paths inside the project root (no `zig-cache/tmp_*`, no stray dirs/files in the repo).
- Proposals/design docs belong in `docs/`, format: `rfc_NNN_<name>_proposal.md` (RFCs sequentially numbered, snake_case; e.g. `rfc_005_<topic>_proposal.md`). Reference docs retain standard snake_case naming.

## Code-Writing Workflow (MANDATORY)

When writing or modifying code, follow this 3-step workflow:

1. **Write pseudocode first** — Outline the logic in comments before implementing:
   ```zig
   // PSEUDOCODE:
   // 1. Lock mutex before accessing shared state
   // 2. Read/modify the protected variable
   // 3. Unlock mutex (use defer for safety)
   ```

2. **Verify API against source** — Check the actual Zig standard library before writing:
   ```bash
   # Example: Verify std.atomic.Mutex API
   grep -n "pub fn tryLock\|pub fn unlock" /path/to/zig/lib/std/atomic.zig
   # Output: pub fn tryLock(m: *Mutex) bool, pub fn unlock(m: *Mutex) void
   # NO lock() method exists — use tryLock() in spin-wait loop
   ```

3. **Implement with verified API** — Only write code after steps 1-2 are complete.

**Failure mode prevented**: This workflow prevents "guess-and-check" loops that cause action-loop timeouts.

## Architecture Notes

- Tool calls preferentially pass through the JS VM (`runtime/js_bindings.zig`) rather than introducing new JSON tool-calling paths.
- **Per-Act VM Isolation**: Each Act initializes an independent `JSContext` to eliminate global variable scope pollution (`const`/`let`) across turns.
- **MemAct Reactive Compaction**: Reactive-only context compression (triggers only when backend returns context limit error, drops-all and inserts summary at index 1, preserving original prompt at index 0).
- **Procedural Graph**: Procedural knowledge stored as event-sourced directed graph in `~/.mini/memory/<project_hash>/pgraph.jsonl`. Dynamically localizes active tool nodes, extracts 2-hop neighborhood, injects ephemeral guidance blocks, and automatically learns frequent tool transitions (N >= 3).
- **Structured Planning System**: LLM-driven planning with DAG dependency resolution (`core/plan.zig`), dual-format JSON/Markdown extraction (`core/plan_parser.zig`), execution lifecycle (`core/plan_executor.zig`), drift detection with soft-enforcement (`core/plan_monitor.zig`), CAS cross-turn plan persistence (`core/plan_store.zig`), and plan-aware tool registry filtering (`tooling/registry.zig`). Configured via `enable_structured_planning`.
- **Dual-Protocol Auto-Negotiation**: Automatically switch and remember protocol between Chat Completions API and Responses API for OpenAI-compatible endpoints.
- **Provider Abstraction Layer**: Normalizes wire protocol differences across OpenAI-compatible endpoints (`OPENAI_COMPAT_PROVIDER` or auto-detect from URL). Manages protocol selection (Chat Completions vs Responses API), reasoning parameter format, reasoning echo policy (DeepSeek assistant history), and Chinese thinking tag filtering (`<思考>`, `<推理>`, etc.).
- **Execution Rules**: The agent strictly follows core execution rules (Stop on Completion, Confirm Before Mutation, Avoid Action Loops & Plan Ahead, Cognitive Efficiency).
- Backends conform to `core/protocol.zig`; do not make direct HTTP calls in the agent loop.
- Editor (`ui/editor.zig`) supports incremental bracketed paste parser (`ui/paste.zig`), UTF-8 width, single-line byte-based editing (multiline composer FSM on the roadmap).
- History persistence is planned using SQLite (libsqlite3 reserved in `build.zig`).

## Testing

- **Standard pre-commit command**: Run `zig build test` (or `zig build test --summary all`), all 13/13 steps must pass.
- **All-In-One Architecture**:
  1. *Tier 1 (Unit tests)*: Test all modules in `src/main.zig`.
  2. *Tier 2 (Integration testcases)*: Test CodeAct VM isolation, security blocklist/allowlist, hooks, CAS file snapshots (`testcases/test_codeact_security.zig`).
  3. *Tier 3 (E2E Mock LLM)*: Builds `mini` binary, spawns `node scripts/mock_llm_server.js` independently on port 8399 and tests 3 complete flows (`simple text`, `long text streaming`, `tool call bash multi-turn`).
- **Flexible Options**:
  - When Node.js is unavailable or for faster iterations: `zig build test-unit` or `zig build test -Dskip-e2e=true`.
  - When running E2E tests only: `zig build test-e2e`.
  - In case of port collision: `zig build test -Dtest-port=8400`.
- **UI/editor**: Manual testing via `zig build run`, verify UTF-8 input, bracketed paste, Ctrl+A/E/U, ↑/↓ history.
- **Backends**: Never call real APIs during automated testing; verify SSE parsing via unit tests and the internal mock server.
