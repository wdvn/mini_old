# .agent/AGENTS.md — Advanced Rules and Guidelines for mini-agent

This document complements the root `AGENTS.md`, focusing on **analysis, root cause investigation (RCA), and problem troubleshooting** within the **mini** project.

---

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

---

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

---

## 3. Technical Component Map for Debugging

- **Agent Core Loop**: `src/core/agent.zig` (act loop, HTTP error classification, journaling, reactive compaction, 4 stopping rules).
- **CodeAct VM & JS Bindings**: `src/runtime/quickjs_engine.zig`, `src/runtime/js_bindings.zig` (Per-Act VM isolation, policy & hook enforcement, CAS file snapshotting).
- **Backends & Adapters**: `src/backends/openai.zig` (Dual-protocol auto-negotiation, responses API, usage & reasoning parsing), `src/backends/claude.zig`, `src/backends/ollama.zig`.
- **UI & Terminal Stream**: `src/ui/chat_stream.zig` (TurnRenderer, in-place retry replacements, ANSI truncation, raw backend error formatting), `src/ui/repl.zig`, `src/ui/editor.zig`, `src/ui/paste.zig`.
- **Memory & History**: `src/core/history.zig`, `src/core/memact/`.
- **Tools & Registry**: `src/tooling/registry.zig` (15 built-in tools + MCP dispatcher), `src/tools/session_diagnostics.zig`, `src/core/skills.zig`.
