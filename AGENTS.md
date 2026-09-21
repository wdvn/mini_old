# AGENTS.md

Instructions for AI coding agents working on the **mini-agent** repository. Read this file before making any code changes.

## Project Overview

- **Language**: Zig 0.16.0, standard library only (exceptions: libcurl dynamic link, QuickJS/CodeAct static link).
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
- Proposals/design docs belong in `docs/`, format: `rfc_NNN_<name>_proposal.md` (RFCs sequentially numbered, snake_case; e.g. `rfc_005_agent_folder_proposal.md`). Reference docs retain standard snake_case naming.

## Architecture Notes

- Tool calls preferentially pass through the JS VM (`runtime/js_bindings.zig`) rather than introducing new JSON tool-calling paths.
- **Per-Act VM Isolation**: Each Act initializes an independent `JSContext` to eliminate global variable scope pollution (`const`/`let`) across turns.
- **MemAct Reactive Compaction**: Reactive-only context compression (triggers only when backend returns context limit error, drops-all and inserts summary at index 1, preserving original prompt at index 0).
- **Procedural Graph (RFC-010)**: Procedural knowledge stored as event-sourced directed graph in `~/.mini/memory/<project_hash>/pgraph.jsonl`. Dynamically localizes active tool nodes, extracts 2-hop neighborhood, injects ephemeral guidance blocks, and automatically learns frequent tool transitions (N >= 3).
- **Dual-Protocol Auto-Negotiation**: Automatically switch and remember protocol between Chat Completions API and Responses API for OpenAI-compatible endpoints.
- **Provider Abstraction Layer (RFC-012)**: Normalizes wire protocol differences across OpenAI-compatible endpoints (`OPENAI_COMPAT_PROVIDER` or auto-detect from URL). Manages protocol selection (Chat Completions vs Responses API), reasoning parameter format, reasoning echo policy (DeepSeek assistant history), and Chinese thinking tag filtering (`<思考>`, `<推理>`, etc.).
- **Execution Rules**: The agent strictly follows core execution rules (Stop on Completion, Confirm Before Mutation, Avoid Action Loops & Plan Ahead, Cognitive Efficiency).
- Backends conform to `core/protocol.zig`; do not make direct HTTP calls in the agent loop.
- Editor (`ui/editor.zig`) supports incremental bracketed paste parser (`ui/paste.zig`), UTF-8 width, single-line byte-based editing (multiline composer FSM roadmap at `docs/rfc_008_user_input_state_machine_proposal.md`).
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

## PR / Commit

- Commit messages must be in English, format: `module: short description` (e.g. `editor: add word motion keybindings`).
- Do not commit scratch test files outside of `testcases/`, do not commit `zig-cache/`, `zig-out/`.

---

# Advanced Rules and Guidelines for mini-agent

This document complements the sections above, focusing on **analysis, root cause investigation (RCA), and problem troubleshooting**.

## 1. Core Principles for Problem Analysis

1. **Investigate Before Mutating**:
   - Always locate the exact error origin and trace the data flow before modifying any code.
   - Use specialized analysis skills (`codebase-analysis`, `root-cause-analysis`, `session-diagnostics`) to gain complete situational awareness.

2. **Evidence-Based Diagnostics**:
   - When diagnosing runtime errors, inspect session logs under `~/.mini/sessions/journal_*.jsonl`.
   - Carefully review HTTP error codes, Zig's `error_name`, and backend server `raw_snippet` to prevent speculative assumptions.

3. **Align with RFCs & Design Docs**:
   - Before classifying a behavior as a "bug" or "feature", cross-reference the corresponding proposals in `docs/` (`rfc_001` through `rfc_009`).
   - Ensure proposed solutions conform to the project's Code-Centric (CodeAct VM) and Event Sourcing architectural direction.

4. **Multi-tier Verification**:
   - Reproduce issues with a concise unit test in `testcases/test_*.zig` when feasible.
   - After applying fixes, run the entire All-In-One test suite: `zig build test --summary all` (all 13/13 steps must pass).
     - *Tier 1 (Unit)*: Unit tests for core/tools/ui in `src/main.zig`.
     - *Tier 2 (Security/VM)*: CodeAct security, VM isolation, hooks, CAS file snapshots in `testcases/test_codeact_security.zig`.
     - *Tier 3 (E2E Mock LLM)*: Run `mini` binary against the mock OpenAI SSE server (`scripts/mock_llm_server.js`, 3 flows: simple text, long stream, multi-turn bash).
   - If isolated execution is needed: `zig build test-unit` (Tiers 1+2), `zig build test-e2e` (Tier 3), or `zig build test -Dskip-e2e=true`.

## 2. Standard RCA Workflow

```
[1. Intake & Problem Definition]
       │
       ▼
[2. Discovery & Evidence Gathering]
   ├── Read session logs: ~/.mini/sessions/journal_*.jsonl
   ├── Grep search affected areas in src/
   └── Review RFCs / Specs in docs/
       │
       ▼
[3. Hypothesis Formulation & Flow Tracing]
   ├── Map call-stack from Entry Point -> Core -> Runtime -> Backends
   └── Pinpoint breaking point / race condition / memory leak
       │
       ▼
[4. Hypothesis Verification]
   ├── Create reproduction testcase or detailed source trace
   └── Validate against Zig 0.16.0 constraints (memory, threading, I/O)
       │
       ▼
[5. Solution Proposal & Implementation]
   └── Make minimal edits, preserving existing conventions and comments
```

## 3. Technical Component Map for Debugging

- **Agent Core Loop**: `src/core/agent.zig` (act loop, HTTP error classification, journaling, reactive compaction, 4 stopping rules).
- **CodeAct VM & JS Bindings**: `src/runtime/quickjs_engine.zig`, `src/runtime/js_bindings.zig` (Per-Act VM isolation, policy & hook enforcement, CAS file snapshotting).
- **Backends & Adapters**: `src/backends/openai.zig` (Dual-protocol auto-negotiation, responses API, usage & reasoning parsing), `src/backends/claude.zig`, `src/backends/ollama.zig`.
- **UI & Terminal Stream**: `src/ui/chat_stream.zig` (TurnRenderer, in-place retry replacements, ANSI truncation, raw backend error formatting), `src/ui/repl.zig`, `src/ui/editor.zig`, `src/ui/paste.zig`.
- **Memory & History**: `src/core/history.zig`, `src/core/memact/`.
- **Tools & Registry**: `src/tooling/registry.zig` (15 built-in tools + MCP dispatcher), `src/tools/session_diagnostics.zig`, `src/core/skills.zig`.
