# RFC-010: Procedural Graph — Self-Evolving Execution Guidance Anchored on MemAct

> **Date:** 2026-09-10
> **Status:** Proposed
> **Author:** mini-agent team
> **Source:** Adapted from [arXiv:2609.09153v1](https://arxiv.org/html/2609.09153v1) — *"Procedural Graphs: Self-Evolving Execution Structures for LLM Agents"* (Google / Georgia Tech / PKU)
> **Goal:** Introduce a **Procedural Graph (PG)** data layer inside MemAct — turning the flat memory store into graph data for "what-to-do" knowledge — then wire online situational guidance and (deferred) offline self-evolution on top of it.
> **Dependencies:** RFC-001 (CodeAct), RFC-002 (Event-Driven Act), RFC-003 (MemAct — Normative for history/memory)

> **Note on merge:** This RFC merges the previously drafted *RFC-010 (paper adaptation overview)* and *RFC-011 (MemAct → graph store)* into a single normative proposal. The analysis artifacts (`procedural-graphs-adaptation-analysis.md`, `memact-to-procedural-graph.md`) remain as supporting references.

---

## 1. Problem Statement

### 1.1. Agent Action Selection Has No Procedural Structure

mini-agent's act loop (RFC-002) selects actions via unconstrained code generation over a flat, growing history — exactly the failure mode the source paper documents: as trajectories lengthen, agents lose track of objectives, invoke tools out of order, and repeat unproductive actions. Procedural knowledge today lives implicitly in the system prompt, AGENTS.md, and skills (retrieved passively, at the agent's own initiative), with no notion of *progress-conditioned* guidance.

### 1.2. MemAct Memory Is Flat and Unwired

Per RFC-003:
- `MemoryStore` (`src/core/memact/store.zig`) implements an append-only JSONL store at `~/.mini/memory/<project_hash>/memory.jsonl` with three entry types (`semantic` / `episodic` / `project_state`), keyword filtering, and `supersedes`-based revision — **implemented but never wired** (M3/M4 deferred).
- Compaction (reactive, production) produces structured stencil summaries containing `decisions[]`, `learned_errors[]`, `files_touched[]`, `next_step` — rich procedural signal that is currently written into ephemeral conversation history only, never persisted as reusable memory.

### 1.3. Design Window

Because the memory store has never been wired, **there is no backward-compatibility burden on its data model**. This is the ideal moment to extend it from flat text records to graph data — before M3/M4 wiring locks the flat schema in. The Procedural Graph paper's mechanism (triplet-organized procedures, step-level guidance, gated self-evolution) maps onto mini's existing infrastructure with near-zero conceptual friction (§3).

---

## 2. Goals & Non-Goals

### Goals
1. **PG data layer in MemAct** — nodes, typed attributed edges, JSONL event-sourced persistence reusing the existing `supersedes` idiom, without touching `agent.zig` in the data phase.
2. **Population from existing signal** — derive candidate graph edges from compaction stencils and journal traces with no additional LLM calls.
3. **Online generative guidance** — localize the active node from the last tool call, serialize the h-hop subgraph, and inject ephemeral situational guidance into the solver prompt (paper's core online mechanism).
4. **Gated self-evolution (deferred)** — offline refiner proposes Add/Delete edits; a validation gate commits only non-regressing candidates; rejected candidates persist as negative evidence (rejection memory).
5. **Zero change to RFC-003 semantics** — flat memory types remain untouched; the graph is an additional, disjoint data class.

### Non-Goals
- Replacing the CodeAct loop or constraining code generation (guidance biases, never dictates).
- Knowledge-graph features over `semantic` entries (future work; out of scope).
- Vector / embedding retrieval — graphs are small (paper: 7–17 nodes per domain) and matched structurally, not semantically.
- Proactive compaction changes — guidance blocks are ephemeral and MUST NOT interact with reactive compaction (§4.5).
- Cross-project graph sharing.

---

## 3. Background: the Procedural Graph Model (from the Paper)

A Procedural Graph is a directed, attributed graph `𝒢 = (𝒱, ℛ, ℰ, Φ)`:

- **Nodes** abstract tool actions, skills, reasoning steps, or task states.
- **Edges** are triplets `(procedure, relation, procedure)` — node `v` is admissible after node `u` under relation `r`. The relation vocabulary is fixed to four types: `LEADS_TO`, `TRIGGERS`, `PROVIDES_INPUT_FOR`, `CONVERGES_TO`.
- **Edge attributes Φ** use three textual fields: `condition` (when the transition applies), `guidance` (how to proceed), `pitfalls` (what to avoid).

Online, each decision step: (1) **locate** the active node by exactly matching the most recent action; (2) extract the directed **h=2-hop neighborhood** (full graph on match failure) plus the last w=3 trajectory steps; (3) a guidance LLM translates the subgraph into situational guidance appended to the solver prompt. Localization is critical — the paper's ablation shows full-graph injection *degrades* embodied-task success (72.58 → 54.48 on ALFWorld) while localized subgraph guidance improves every benchmark.

Offline, a refiner contrasts successful vs. failed trajectories, proposes structural edits (Add / Delete; attribute revision = delete + re-add), applies them to a copy with cycle repair and terminal-reachability checks, and commits only if held-out validation score does not decrease (ties accepted). Rejected candidates and their evidence are retained in a rejection memory to discourage repeated unsuccessful proposals.

Key empirical results: first place in 21/24 model–benchmark settings vs. seven memory baselines; evolution from scratch matches or beats hand-crafted graphs; a flawed expert prior initially *hurts* (87.5% → 58.93%) and the evolution loop repairs it (→ 92.86%).

---

## 4. Detailed Design

### 4.1. Memory Class Layering

| Class (RFC-003) | Question answered | Representation |
|---|---|---|
| `semantic` | what-is | Flat entry (unchanged) |
| `episodic` | what-happened | Flat entry (unchanged) — **population source** |
| `project_state` | current status | Flat entry (unchanged) |
| **`procedural` (new)** | **what-to-do** | **Graph triplets (this RFC)** |

### 4.2. Event-Sourced Graph Records

Same JSONL discipline as `store.zig` — one event per line, never rewritten:

```jsonc
// Node
{"ev":"add_node","id":"pgn_<ts>_<ctr>","ts":...,
 "node":{"name":"run_test_suite","type":"tool_action","desc":"Run zig build test --summary all"}}

// Edge — triplet + attributes Φ
{"ev":"add_edge","id":"pge_<ts>_<ctr>","ts":...,
 "edge":{"src":"edit_code","rel":"LEADS_TO","dst":"run_test_suite",
         "condition":"code change finished and compiles",
         "guidance":"run full All-In-One suite, all 13 steps must pass",
         "pitfalls":"do not commit scratch test files outside testcases/"}}

// Attribute revision = REUSE store.zig `supersedes` (paper: delete + re-add)
{"ev":"add_edge","id":"pge_...","supersedes":"pge_<old>","edge":{...updated...}}

// Paper op Delete
{"ev":"delete_edge","id":"pge_...","ts":...}

// Paper Algorithm 1 Step 4 — Rejection Memory as event lines
{"ev":"reject_candidate","round":3,"ts":...,
 "reason":"validation score dropped","edits":[...]}
```

- `rel` is validated against the four-relation vocabulary at parse time; invalid lines are skipped (same policy as `parseLine` today).
- `loadIndex` is extended to rebuild a nodes map + edges list; `supersedes` on an edge atomically replaces the prior edge in the index while the old line remains on disk — free audit trail and rollback, consistent with RFC-002 Event Sourcing.
- Candidate validation runs against the *rebuilt index*, never the raw file.

### 4.3. Module Layout

```
src/core/memact/
  store.zig        — unchanged (semantic/episodic/project_state)
  tokens.zig       — unchanged
  graph.zig        — NEW: PGraphNode, PGraphEdge, PGraph (V/R/E/Φ), structural validator
  graph_store.zig  — NEW: JSONL append/loadIndex/rebuild (store.zig idiom)
                     + matchNode(tool_call) + serializeSubgraph(h)
```

No changes to `agent.zig` in the data phase (PG-1/PG-2).

### 4.4. Structural Validator (paper B.6 semantics)

`PrepareCandidate` equivalent:
1. Apply edits to a **copy**: delete edges/nodes before adding.
2. Reject malformed edits, invalid relation types, missing endpoints — reported as diagnostics (feeds `reject_candidate`), no validation rollout.
3. Cycle policy: when disallowed, remove detected cycle-closing edges before validation.
4. Reachability: every node must retain a directed path to a terminal node (zero out-degree).

### 4.5. Online Injection (replaces RFC-003 M4 Top-K)

- After each act, `matchNode(last_tool_call)` → serialize the **2-hop subgraph** (header: node id/type/desc; transitions grouped by hop, each printing `condition`/`guidance`/`pitfalls`; relation labels omitted) together with the last 3 acts.
- Match failure → serialize the **full graph** (cheap: ≤ 17 nodes in practice; the paper's 131-node outlier is a function-catalog artifact not expected here).
- The guidance block is injected as an **ephemeral message** — present for the next backend call, never persisted into history — so MemAct reactive compaction is unaffected.
- **Selective guidance** (deviation from the paper, justified by its own efficiency findings): generate the guidance LLM call only when (a) the active node changed, (b) the previous act failed, or (c) the next candidate tool has multiple outgoing edges. The paper reports +33–55% token overhead vs. baseline and lists selective generation as future work.
- Config extensions in `config.zig` (alongside existing `memact_*`): `memact_pg_enabled: bool = false`, `memact_pg_h: u32 = 2`, `memact_pg_w: u32 = 3`.

### 4.6. Population Pipeline (PG-2, local-only)

1. **Compaction stencil** (already produced reactively): `decisions[i] → decisions[i+1]` as candidate `LEADS_TO` edges; `learned_errors[i]` as `pitfalls`; `files_touched` as `tool_action` node suggestions.
2. **Journal traces** (`~/.mini/sessions/journal_*.jsonl`): per-task tool sequences; node name = tool name from the 15-tool registry (the registry provides the tool-catalog membership the paper's generic validator leaves to the refiner).
3. **Frequency gate**: an edge is persisted only after being observed ≥ N times across tasks (N=3 default), suppressing one-off noise. No LLM calls in this phase.

### 4.7. Self-Evolution Loop (PG-4, deferred)

- Scheduled offline ( leveraging `cron.zig`): run batch tasks, collect traces + scores; an offline refiner LLM contrasts high/low scorers and emits an edit set (`add_node` / `add_edge` / `delete_edge`); `graph.zig` validates; a small held-out validation set gates commit (`S_cand ≥ S_val(current)`, ties accepted per the paper); every decision — accepted or rejected — is appended as an event line; graph checkpoints ride on CAS snapshots for rollback.

### 4.8. Procedure Unit in CodeAct (key adaptation decision)

CodeAct acts are free-form JS; one act may contain multiple `mini.*` calls. **Decision: the matching unit is the individual `mini.*` tool call, not the act** — a node represents a tool action; the act is merely its envelope. Matching uses the tool name parsed from executed bindings (journal `act_completed` deltas), falling back to the first call when several fire in one act.

---

## 5. Implementation Plan

| Milestone | Scope | Verification |
|---|---|---|
| **PG-1 — Data layer** | `graph.zig` + `graph_store.zig`; round-trip JSONL (append → loadIndex → supersedes replacement → 4-relation validation → validator incl. cycle repair) | Unit tests in `testcases/test_procedural_graph.zig`; `zig build test` green; nothing wired |
| **PG-2 — Population** | Journal/stencil pipeline with frequency gate; writes only via `append` | Fixtures: synthetic journal JSONL → expected edges; no LLM |
| **PG-3 — Injection** | `matchNode` + `serializeSubgraph` + ephemeral block in agent loop + config flags; selective-guidance triggers | E2E mock-server flow extension (two-call loop); manual REPL inspection of the injected block |
| **PG-4 — Evolution (deferred)** | Offline refiner prompt, validation gate, rejection memory, CAS checkpoints | Benchmark before/after on mini's own tasks (steps-to-solution, tool-repeat rate, token cost) — not external benchmarks |

---

## 6. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Guidance call overhead per step (paper: +33–55% tokens) | Selective guidance triggers (§4.5); flag default **off**; measure before enabling |
| Noise edges from single-task idiosyncrasies | Frequency gate N≥3; graph remains small (≤ ~20 nodes) |
| `touch()`-style full-file rewrite is O(n) | Acceptable at expected graph sizes; recorded as v1 constraint |
| Graph misleads on tasks where paper showed ~zero gain (pure text QA) | Population draws only from tool-execution signal; text-only flows produce no edges |
| Ephemeral guidance blocks confuse backends with strict role rules | Injected as a user-role system-style message consistent with existing `[System]` continuations; Claude role normalization already handled (RFC-003 §4.5) |
| Evolution gate flapping on small validation sets (paper §5.4 caveat) | Tie-accept + require ≥ Δ0 improvement for *commit logging clarity*; validation set sized > 20 episodes when feasible |

---

## 7. Open Questions

1. **Procedure unit**: per-`mini.*`-call matching (proposed, §4.8) vs. per-act — confirm before PG-3.
2. **Guidance model selection**: same backend as solver (paper's choice) vs. cheaper dedicated model via existing multi-backend config.
3. **Graph scoping**: per-project-hash (aligned with memory dir) vs. global `~/.mini/graphs/` shared across projects — proposal leans per-project to respect MemAct isolation.
4. Should `reject_candidate` lines be excluded from the live index (evidence-only) — assumed yes.

---

## 8. Tracking Checklist

- [ ] PG-1: `graph.zig` + `graph_store.zig` + unit tests (round-trip, supersedes, validator)
- [ ] PG-2: population pipeline + fixtures
- [ ] PG-3: matchNode / serializeSubgraph / ephemeral injection + config flags + E2E flow
- [ ] PG-3: `memact_pg_*` config documentation
- [ ] PG-4 (deferred): refiner + validation gate + rejection memory + CAS checkpoints
- [ ] Update `AGENTS.md` Architecture Notes upon PG-3 landing

---

## 9. References

- [arXiv:2609.09153v1](https://arxiv.org/html/2609.09153v1) — Procedural Graphs: Self-Evolving Execution Structures for LLM Agents
- RFC-002 — Long-Horizon Event-Driven Act Architecture (journal, act model, CAS)
- RFC-003 — MemAct: Context Compaction & Memory Management (store idiom, reactive compaction, M3/M4 deferral)
- Session artifacts: `procedural-graphs-adaptation-analysis.md`, `memact-to-procedural-graph.md`
