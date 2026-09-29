# RFC-026: Model-Driven Global Memory — Tiered Memory Store + `memory` Tool

**Status**: Proposed
**Date**: 2026-09-25
**Author**: MemAct Engineering
**Related**: RFC-003 (MemoryStore), RFC-010 (Procedural Graph), RFC-025 (Dual-Path Semantic Memory)
**Tags**: Agent Memory, Cross-Project, Tool Design

---

## 1. Executive Summary

Today mini's memory is **hard-isolated per project**: both `MemoryStore`
(`memory.jsonl`) and `PGraphStore` (`pgraph.jsonl`) are bound to
`$MINI_HOME/memory/<project_hash>/` (cwd FNV-1a hash, `agent.zig`
`initMemoryStore`/`initPGraphStore`). Knowledge acquired in project A
(user preferences, machine environment quirks, cross-project
conventions) is invisible in project B.

This RFC adds a **global tier** under a strict decision principle:

> **The model is the sole writer of global memory.** The system only
> enforces storage routing and guards. There is no automatic LLM
> extraction classifier, no auto-promotion of records, and no
> automated mirroring of tool transitions into a global graph.

Mechanically:

1. A new single tool `memory` (registry size 15 → 16) with two
   actions: `insert` and `retrieve`, exposed to the CodeAct VM as
   `mini.memory(action, args)` (RFC-001 tool-call-via-VM principle).
2. `insert` carries `level: "local" | "global"` (default `local`).
   **Only `level: "global"` writes** to
   `$MINI_HOME/memory/global/memory.jsonl`; everything else writes to
   the per-project store exactly as today.
3. `retrieve` runs the RFC-025 dual-path pipeline (BM25 on the
   original query + optional LLM-expanded query, RRF k=60)
   **per tier**, then merges with a fixed global token quota
   (default 30% of `memact_memory_budget`).
4. Passive injection (`injectSemanticMemory`) reads the same union,
   so global memories surface both when the model actively retrieves
   and on every turn.

Rejected alternatives (decision log, §7): global procedural graph,
auto-mirrored transitions, automatic scope classification, and two
separate `mem_insert`/`mem_retrieve` tools.

---

## 2. Current State (Evidence)

| Component | File | Behavior |
|---|---|---|
| Per-project store init | `src/core/agent.zig` `initMemoryStore` | `mem_base + "/" + FNV1a(cwd)`; `MemoryStore` instance |
| Per-project graph init | `src/core/agent.zig` `initPGraphStore` | same dir; `PGraphStore` instance |
| Dual-path retrieval | `src/core/agent.zig` `injectSemanticMemory` (RFC-025 Phase 2/3) | BM25 index built from active entries; Path A (original query) + Path B (`expandMemActQuery` LLM expansion, capped, graceful degrade); `rrfFuse` k=60; top-k; token budget; `node_ref` → `pg.enrichNode` |
| Retrieval primitives | `src/core/memact/bm25.zig` | `Index.build`, `Index.rank`, `rrfFuse` |
| JS tool surface | `src/runtime/js_bindings.zig` | `mini.*` C-ABI bindings, `guardPolicy` blocklist, `isSeenCall` dedup, hooks dispatch |
| Tool registry | `src/tooling/registry.zig` | 15 built-in tools + MCP dispatcher |

On disk, `~/.mini/memory/` contains only `<project_hash>/`
directories; **no `global/` directory exists yet** (verified).

## 3. Design

### 3.1 Storage layout (no schema change)

```text
$MINI_HOME/memory/
├── global/                  # NEW: one declarative store for the user
│   └── memory.jsonl         # same MemoryEntry schema as project stores
└── <project_hash>/          # UNCHANGED
    ├── memory.jsonl
    └── pgraph.jsonl
```

- `global/` is a **second `MemoryStore` instance** initialized with the
  same type and the same schema — no new fields, no scope attribute on
  entries. The tier is the directory, not an entry property.
- **No `global/pgraph.jsonl`.** Procedural graphs stay strictly
  per-project (decision §7.1). The `node_ref` schema field still
  exists on global entries, but global inserts never populate it
  (it is `null`); consequently global retrieval results render
  without graph enrichment.
- The directory is auto-created on first write by the existing
  `MemoryStore.init` behavior; an absent/empty global store is a no-op
  (zero-cost early return in retrieval, reusing RFC-025's
  `doc_texts.items.len == 0` guard).

### 3.2 Tool: `memory` (one tool, two actions)

Registered in `registry.zig` as a single tool; bound in
`js_bindings.zig` as:

```js
mini.memory("insert", {
  level: "local" | "global",   // default "local"
  type: "preference" | "environment" | "convention" | "lesson" | "project_state",
  content: "string",
  keywords: ["..."],
  confidence: 0.0 - 1.0,       // model self-report; required, hardcoded values banned (RFC-025 §3.2 rule 2)
})
// → { ok: true, id: "mem_...", tier: "global" }

mini.memory("retrieve", {
  query: "string",
  levels: ["local", "global"], // default both
  limit: 8,                    // default, capped by budget
  type: "..."                  // optional metadata filter
})
// → { results: [{ level, type, content, keywords, confidence, enriched? }] }
```

Prompt-facing description (drives the model's insert decisions):

> Store or search durable memories. `insert`: use `level:"global"`
> only for knowledge that is independent of the current project —
> user preferences, machine/environment facts, cross-project
> conventions, and reusable lessons; everything else stays
> `level:"local"` (default) in the current project. `retrieve`:
> search memories across tiers for a query; returns top-k with
> global-tier results capped by a fixed token quota.

### 3.3 Write path — routing and guards

| Rule | Enforcement point |
|---|---|
| `level:"global"` writes to `global/` store only; `local` (default) to project store only | `src/tools/memory.zig` (routing by tier instance) |
| Global `content` ≥ 20 chars, else **reject** (model receives a readable error, unlike RFC-025 Phase 0's filter-and-keep posture) | insert handler |
| `type: "project_state"` is **local-only** (project state is meaningless across projects) | insert handler |
| `confidence` must be provided and in `(0, 1]` | insert handler |
| `supersedes` is **within-tier only** — a global entry cannot supersede a local one and vice versa (audit-trail isolation) | insert handler |
| Global inserts never populate `node_ref` (no global graph exists) | insert handler |
| Policy block / dedup / hooks, same as every other `mini.*` tool | `guardPolicy("memory")`, `isSeenCall` in `js_bindings.zig` |

The model remains free to insert *wrongly*-scoped content; the system
deliberately does not add a semantic classifier (see §7.1). The
append-only JSONL stays human-editable — a polluted global store is
fixed by deleting/`supersedes`-ing lines, consistent with the
event-sourcing posture of both stores.

### 3.4 Read path — per-tier retrieval, quota-bounded merge

The dual-path pipeline currently inline in `injectSemanticMemory`
is extracted to a reusable function (single caller in `agent.zig`
today, two callers after this RFC — tool `retrieve` and passive
injection):

```text
PSEUDOCODE (searchTier):
  entries = store.activeEntries()            # supersedes-resolved, content ≥ 20 guard (RFC-025)
  if empty → return []
  rank A = bm25.rank(original_query)
  rank B = bm25.rank(llm_expansion) if config.memact_expansion else []   # capped, graceful degrade (RFC-025 risk table)
  fused  = rrfFuse(A, B, k=60)
  return fused[0..limit]

PSEUDOCODE (merged retrieval):
  local_res  = searchTier(project_store, query)
  global_res = searchTier(global_store, query) if global enabled else []
  budget_g   = min(budget_total * global_quota, budget_total)   # default quota 0.30
  emit global_res while estimate(content) fits budget_g          # token-capped, like today's loop
  emit local_res  while remaining budget fits                   # remaining budget
```

- **Tier-scoped enrichment:** a local result's `node_ref` is enriched
  via the *project* `PGraphStore.enrichNode` exactly as today; global
  results render plain (no graph enrichment — no global graph).
- **Rendering in the passive block:** entries keep tier+type tags —
  `[local/semantic] ...`, `[global/preference] ...` — inside the
  existing `[MemAct Semantic Memory]` block.
- LLM expansion runs **at most once per retrieval call** (shared by
  both tiers on the same text), preserving RFC-025's latency cap.

### 3.5 Config

| Key | Default | Env | Notes |
|---|---|---|---|
| `memact_global_enabled` | `true` | `MINI_MEMACT_GLOBAL_ENABLED` | Master switch; `false` → global tier fully inert (no read, no write — inserts with `level:"global"` are rejected with a config error) |
| `memact_global_quota` | `0.3` | `MINI_MEMACT_GLOBAL_QUOTA` | Fraction of `memact_memory_budget` reserved for global-tier results in both read paths |

Wiring follows the existing `config.zig` pattern
(`MINI_` env → `Config` field, verified section ~L1092–1314).

## 4. Files Modified / Created

| File | Change |
|---|---|
| `src/tools/memory.zig` | **NEW** — tool implementation: action dispatch, tier routing, guards (§3.3), merged retrieval (§3.4) |
| `src/core/memact/search.zig` | **NEW** — extracted `searchTier` dual-path pipeline (BM25 A/B + RRF + expansion); reused by tool and passive injection |
| `src/tooling/registry.zig` | register `memory` (15 → 16 tools) with the prompt-facing description (§3.2) |
| `src/runtime/js_bindings.zig` | `mini.memory(action, args)` binding, `guardPolicy("memory")` entry, docs header line |
| `src/core/agent.zig` | `initGlobalMemoryStore()` (second `MemoryStore` instance at `{mem_base}/global`); `AgentLoop` gains `global_memory_store: ?*MemoryStore`; `injectSemanticMemory` refactored onto `search.zig` + quota merge |
| `src/core/config.zig` | two new flags (§3.5) |
| `testcases/test_memory_tool.zig` | **NEW** — see §6 |

Unchanged by design: `memact/store.zig` (schema, append semantics),
`memact/graph_store.zig` (per-project only), `memact/bm25.zig`
(consumed as-is).

## 5. Phases

| Phase | Scope | Gate (verify) |
|---|---|---|
| **0** | Global store instance + `memory` tool with `insert` (routing, guards) + `search.zig` extraction | Unit tests: a global insert lands only in `global/memory.jsonl`; local insert only in project dir; all §3.3 guard rejections; `zig build test-unit` green |
| **1** | `retrieve` action: per-tier pipeline + quota merge; global empty → zero-cost no-op | Unit tests: seeded global+local fixtures → merged ranking respects 30% quota; empty global returns local-only with no LLM expansion call |
| **2** | Passive injection reads the union; config flags; E2E mock flow where the LLM emits a `mini.memory` tool call and the next turn's prompt block contains the global entry | 3-flow E2E unchanged + new flow; `zig build test --summary all` 13/13; manual cross-project check: seed `global/memory.jsonl` from project A, start project B, grep the next-turn journal prompt for `[global/...]` |

Each phase is independently shippable; Phase 0 has no read-side
behavior change (global writes simply have no reader yet).

## 6. Test Plan

- `testcases/test_memory_tool.zig` (unit): routing matrix
  (level × tier × file), every §3.3 guard, within-tier supersede,
  quota math (deterministic: fixed fixtures, fixed budget), dangling
  `node_ref` on local results degrades to plain record.
- Mock-server E2E (Phase 2): assistant turn emitting
  `mini.memory("insert", {..., level:"global"})`, second turn asserts
  `[MemAct Semantic Memory]` contains the entry; negative case:
  `memact_global_enabled=false` → insert rejected with config error.
- Existing 13/13 All-In-One suite must stay green after every phase.

## 7. Decision Log (alternatives rejected)

| # | Alternative | Why rejected |
|---|---|---|
| 1 | Global procedural graph + auto-mirrored tool transitions (edge-only, guidance generalized by an LLM gate) | Rejected by design review: the project's stated principle is **model-driven global writes only**. An auto-mirrored global graph reintroduces exactly the "system decides what is global" behavior RFC-025 Phase 0 removed for the per-project noise path, and a global graph with raw cross-project guidance text is a contamination vector (project tokens in suggestions). Reusable *workflows* can be expressed as global `lesson` records by the model when it sees them; a second abstraction is YAGNI until the corpus proves it. |
| 2 | Automatic scope classification on LLM-extracted records | Same reason — the model calling `memory insert` with `level` *is* the decision point; adding a hidden classifier is a second, untestable decision-maker. |
| 3 | Two separate tools (`mem_insert`, `mem_retrieve`) | One tool keeps the registry at +1 (15 → 16) and the prompt surface smaller; two actions in one tool mirrors the existing multi-action binding pattern in `js_bindings.zig`. |
| 4 | A `scope` field on `MemoryEntry` | A scope attribute on every legacy line complicates the append-only schema; the directory *is* the tier. No migration, no dual meaning. |
| 5 | A single fused BM25 index over global+local pre-RRF | Makes a tier quota impossible (a large global corpus would displace local hits); per-tier RRF + quota merge preserves the locality guarantee. |

## 8. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Model over-inserts to global (pollution) | Human-editable append-only JSONL (delete/`supersedes`); guards §3.3; confidence is model-reported and visible in retrieval output so the model can weigh it |
| Global entry wrong for another project | The model wrote it knowing it is cross-project; retrieval returns `confidence` and `source_session` alongside content so the model can discard stale entries; within-tier supersede covers corrections |
| Extra LLM expansion latency on `retrieve` | Expansion runs once per call, capped, Path A stands alone on failure — identical to RFC-025's graceful degrade |
| Global store absence / empty on fresh install | Early-return no-op (existing empty-index guard), zero cost until first insert |
| Quota starves local knowledge | Local takes *remaining* budget after the capped global slice (never inverted); quota configurable; default 0.3 chosen conservative |

## 9. Success Metrics

1. **Routing correctness:** 100% of `level:"global"` inserts land in
   `global/memory.jsonl` and no other (test-enforced).
2. **Cross-project recall:** manual scenario (seed in project A,
   query from project B) returns the entry in the merged top-k with
   the `[global/<type>]` tag in the passive block.
3. **Budget discipline:** global-tier contribution to the injection
   block never exceeds `quota × memact_memory_budget` (test-enforced).
4. **No regressions:** `zig build test --summary all` 13/13 after
   each phase; E2E mock flows unchanged.
