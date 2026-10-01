# RFC-026: Model-Driven Global Memory — Tiered Memory Store + `memory` Tool

**Status**: Proposed (Revised with Technical Review & Concurrency Hardening)  
**Date**: 2026-09-25 (Updated 2026-09-30)  
**Author**: MemAct Engineering  
**Related**: RFC-003 (MemoryStore), RFC-010 (Procedural Graph), RFC-025 (Dual-Path Semantic Memory)  
**Tags**: Agent Memory, Cross-Project, Tool Design, Multi-Process Safety  

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
2. Uniform taxonomy: All APIs and schemas standardize on
   `tier: "local" | "global"` (default `local`). **Only `tier: "global"`
   writes** to `$MINI_HOME/memory/global/memory.jsonl`; everything else
   writes to the per-project store exactly as today.
3. Multi-process safety: Unlike per-project files, `global/memory.jsonl`
   is shared across all concurrent `mini` sessions on the machine. File
   mutations enforce POSIX advisory locks (`flock`) to prevent race
   conditions and JSONL corruption.
4. Dependency Injection: QuickJS C-ABI bindings cannot hold an `AgentLoop`
   pointer. A dedicated `MemoryStoreManager` singleton (`manager.zig`,
   mirroring `src/core/snapshot.zig`'s `SnapshotTracker` pattern) bridges
   the stores to the VM and tool registry.
5. Latency discipline: Active tool `retrieve` executes **Path A only**
   (lexical BM25 ranking across tiers) to eliminate synchronous nested LLM
   expansion calls inside in-flight Acts. Passive turn injection
   (`injectSemanticMemory`) executes the full RFC-025 dual-path pipeline
   (BM25 Path A + LLM expansion Path B, RRF $k=60$) per tier, merged
   with a quota-bounded slice (default 30% of `memact_memory_budget`)
   without starving local project memories.

Rejected alternatives (decision log, §7): global procedural graph,
auto-mirrored transitions, automatic scope classification, two separate
`mem_insert`/`mem_retrieve` tools, lockless concurrent JSONL append, and
in-Act nested LLM query expansion.

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
| C-ABI state bridge | `src/core/snapshot.zig` | `SnapshotTracker` global singleton pattern (`g_tracker`) bridging QuickJS C-ABI to agent state |
| CodeAct prompt | `src/core/prompts.zig` | Defines CodeAct system prompt documenting available `mini.*` APIs |

On disk, `~/.mini/memory/` contains only `<project_hash>/` directories;
**no `global/` directory exists yet** (verified).

---

## 3. Design

### 3.1 Storage Layout & Multi-Process Concurrency Safety

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
- **Multi-Process Concurrency Protection:** Because multiple `mini` instances
  (e.g., in different project directories) may read and write to
  `global/memory.jsonl` concurrently, positional writes without locks cause
  interleaved corruptions.
  - Write path (`append`): Must acquire an exclusive advisory lock
    (`std.posix.flock(fd, std.posix.LOCK.EX)`) before seeking to end and
    flushing, or open with `O_APPEND` and write single atomic buffers under
    `PIPE_BUF` (4096 bytes).
  - Read path (`loadIndex`): Must acquire a shared lock
    (`std.posix.flock(fd, std.posix.LOCK.SH)`) during whole-file read.
  - **Prohibition of `touch()` on global store:** `MemoryStore.touch`
    truncates and rewrites the entire file (`createFile(..., .{ .truncate = true })`),
    which would erase concurrent writes. `touch()` is strictly banned on the
    global store.
  - Trailing newline verification: Appends must verify that the existing
    file ends with a newline byte before writing the next entry to avoid
    line splicing on partial writes.

### 3.2 Tool: `memory` (One Tool, Two Actions)

Registered in `registry.zig` as a single tool; bound in `js_bindings.zig` as:

```javascript
mini.memory("insert", {
  tier: "local" | "global",    // default "local"
  type: "preference" | "environment" | "convention" | "lesson" | "project_state",
  content: "string",           // min 20 chars
  keywords: ["..."],
  confidence: 0.0 - 1.0,       // model self-report; required, hardcoded values banned (RFC-025 §3.2 rule 2)
  supersedes: "mem_..."        // optional, must be within same tier
})
// → { ok: true, id: "mem_...", tier: "global" }

mini.memory("retrieve", {
  query: "string",
  tiers: ["local", "global"],  // default both
  limit: 8,                    // default, capped by budget
  type: "..."                  // optional metadata filter
})
// → { results: [{ tier: "global", type: "...", content: "...", keywords: [...], confidence: 0.85, enriched: false }] }
```

Prompt-facing description (documented in `src/core/prompts.zig` and `registry.zig`):

> Store or search durable memories.
> - `insert`: use `tier:"global"` only for knowledge that is independent
>   of the current project — user preferences, machine/environment facts,
>   cross-project conventions, and reusable lessons; everything else stays
>   `tier:"local"` (default) in the current project. Both tiers enforce min
>   20 characters and require confidence in (0, 1].
> - `retrieve`: search memories across tiers using lexical BM25 for a query;
>   returns top-k with global-tier results capped by a fixed token quota.

### 3.3 Write Path — Routing, Guards & Validation

| Rule | Enforcement Point | Behavior on Violation |
|---|---|---|
| `tier:"global"` writes to `global/` store; `local` (default) to project store | `src/tools/memory.zig` (routing via `manager.zig`) | Routes write to designated `MemoryStore` |
| Content length $\ge 20$ chars for **both** local and global | insert handler | **Reject** with `error.ContentTooShort` (prevents unsearchable legacy records) |
| `type: "project_state"` is **local-only** | insert handler | **Reject** with `error.GlobalProjectStateForbidden` |
| Validated `type` taxonomy | insert handler | Must match `preference`, `environment`, `convention`, `lesson`, or `project_state` |
| `confidence` must be in $(0, 1]$ | insert handler | **Reject** with `error.InvalidConfidence` |
| `supersedes` is **within-tier only** and target must exist | insert handler | Scan target index; if target missing or from other tier, **reject** with `error.InvalidSupersedesTarget` |
| Global inserts never populate `node_ref` | insert handler | Hardcode `node_ref = null` for global |
| Concurrency lock | `store.zig` / `memory.zig` | Acquire exclusive `flock` during append on `global/memory.jsonl` |
| Policy block / dedup / hooks | `js_bindings.zig` | `guardPolicy("memory")`, `isSeenCall` dedup |

The model remains free to insert *wrongly*-scoped content; the system
deliberately does not add a semantic classifier (see §7.2). The
append-only JSONL stays human-editable — a polluted global store is
fixed by deleting or `supersedes`-ing lines.

### 3.4 Read Path — Per-Tier Retrieval & Quota-Bounded Merge

#### Distinct Retrieval Pathways
To avoid latency spikes inside the interactive Act execution loop:
1. **Tool `retrieve` (In-Act):** Executes **Path A only** (lexical BM25) across
   the requested tiers. The query is already formulated by the LLM in CodeAct;
   running an in-flight nested LLM expansion request during an Act evaluator
   would block the QuickJS runtime, increase token costs, and risk watchdog burst timeouts.
2. **Passive Injection (`injectSemanticMemory`):** Executes the full **Dual-Path**
   pipeline (Path A BM25 + Path B LLM expansion via `expandMemActQuery`, fused
   via RRF $k=60$) because raw user prompts benefit from keyword generalization.

#### Memory Management & Lifecycle in `search.zig` (Zig 0.16.0)
`MemoryStore.loadIndex(io)` returns dynamically allocated `[]MemoryEntry`
structs containing heap-allocated string slices. To prevent dangling pointers
when returning search results:
- `searchTier` accepts an `ArenaAllocator`.
- All parsed entries, generated `doc_texts`, BM25 indices, and ranked result
  slices are allocated within the arena.
- Caller frees the arena in one operation after rendering/JSON-serialization.

```text
PSEUDOCODE (searchTier — Path A Lexical):
  entries = store.loadIndex(io)              # active entries (supersedes resolved)
  if entries.len == 0 → return []
  eligible = filter(entries, content.len >= 20)
  if eligible.len == 0 → return []
  index = bm25.Index.build(arena, eligible)
  ranked = index.rank(arena, query, limit)
  return ranked

PSEUDOCODE (Score-Aware Quota Merge):
  local_results  = searchTier(local_store, query, arena)
  global_results = searchTier(global_store, query, arena) if global_enabled else []
  
  # Priority discipline: Local memories take precedence for project work.
  # Global quota caps maximum global intrusion (default: 30% of budget).
  global_budget_cap = min(total_budget * global_quota, total_budget)
  
  emit local_results while budget_used + tokens <= (total_budget - global_budget_cap)
  emit global_results while global_used + tokens <= global_budget_cap
  emit remaining local_results while budget_used + tokens <= total_budget
```

- **Tier-scoped enrichment:** Local results carrying `node_ref` are enriched
  via project `PGraphStore.enrichNode`. Global results render plain (no graph).
- **Passive block formatting:** Rendered entries carry uniform tier tags:
  `[local/<type>] ...`, `[global/<type>] ...` within `[MemAct Semantic Memory]`.

### 3.5 State Access & Dependency Injection Architecture

Because QuickJS C-ABI functions in `src/runtime/js_bindings.zig` receive only
`*quickjs.Engine` and cannot access `AgentLoop`, we follow the proven
architecture of [`SnapshotTracker`](file:///mnt/hdd/projects/persional/mini/src/core/snapshot.zig#L15):

```text
src/core/memact/manager.zig (NEW)
  ├── var g_manager: ?*MemoryStoreManager = null
  ├── init(alloc, io, config, local_store, global_store, pg_store, estimator)
  ├── get() ?*MemoryStoreManager
  └── deinit()
```

- `AgentLoop.init` instantiates and sets `MemoryStoreManager`.
- `src/tools/memory.zig` and `src/runtime/js_bindings.zig` fetch the active
  manager via `manager.get()`.
- Thread-safety: Access is guarded by an internal atomic spin-mutex
  (`std.atomic.Mutex`), ensuring safety across subagents and REPL turns.

### 3.6 Config

| Key | Default | Env | Notes |
|---|---|---|---|
| `memact_global_enabled` | `true` | `MINI_MEMACT_GLOBAL_ENABLED` | Master switch; `false` → global tier fully inert (inserts rejected with config error) |
| `memact_global_quota` | `0.3` | `MINI_MEMACT_GLOBAL_QUOTA` | Maximum fraction of `memact_memory_budget` allocated to global-tier results |

Wiring follows the existing `config.zig` pattern (`MINI_` env → `Config` struct field).

---

## 4. Files Modified / Created

| File | Change |
|---|---|
| `src/core/memact/manager.zig` | **NEW** — `MemoryStoreManager` singleton bridging stores to QuickJS C-ABI & tool registry |
| `src/core/memact/search.zig` | **NEW** — Extracted `searchTier` BM25 pipeline with arena lifecycle and quota merge |
| `src/tools/memory.zig` | **NEW** — Tool implementation: action dispatch, tier routing, validation guards (§3.3), retrieval formatting |
| `src/core/prompts.zig` | Document `mini.memory(action, args)` in CodeAct system prompt |
| `src/tooling/registry.zig` | Register `memory` tool (15 → 16 tools), policy permissions, and schema definitions |
| `src/runtime/js_bindings.zig` | Bind `mini.memory`, attach `guardPolicy("memory")`, add `isSeenCall` dedup |
| `src/core/agent.zig` | Initialize `global_memory_store`; wire `manager.zig`; refactor `injectSemanticMemory` onto `search.zig` |
| `src/core/config.zig` | Add `memact_global_enabled` and `memact_global_quota` options |
| `build.zig` | Register `testcases/test_memory_tool.zig` in unit/testcase test runner |
| `testcases/test_memory_tool.zig` | **NEW** — Unit, multi-process concurrency, and guard rejection tests |

Unchanged by design: `memact/graph_store.zig` (per-project only), `memact/bm25.zig` (consumed as-is).

---

## 5. Phases

| Phase | Scope | Gate (Verify) |
|---|---|---|
| **0** | `manager.zig` + Global store instance with POSIX `flock` + `memory` tool with `insert` (routing, symmetric 20-char guard, within-tier supersedes) + `prompts.zig` integration | Unit tests: global insert lands exclusively in `global/memory.jsonl`; local insert only in project dir; all §3.3 guard rejections pass; `zig build test-unit` green |
| **1** | `retrieve` action (Path A BM25) + `search.zig` arena allocation + score-aware quota merge; empty global returns zero-cost no-op | Unit tests: seeded global+local fixtures respect 30% quota without starving local records; no dangling memory under arena leak check |
| **2** | Passive injection reads unified stores (Path A + Path B expansion); config flags; E2E mock flow where LLM emits `mini.memory` and next turn contains global entry | `zig build test --summary all` passes 13/13; multi-process concurrency stress test passes with 0 corruptions |

---

## 6. Test Plan

- `testcases/test_memory_tool.zig`:
  - **Routing matrix:** `tier: "local"` lands in `<project_hash>/`, `tier: "global"` lands in `global/`.
  - **Guard enforcement:** Reject `content.len < 20` for both tiers; reject `type: "project_state"` on global; reject out-of-range confidence; reject cross-tier supersedes; reject nonexistent supersedes targets.
  - **Multi-process concurrency:** Spawn 4 concurrent child processes appending 50 global entries each; assert exactly 200 valid JSONL lines in `global/memory.jsonl` with 0 parse errors.
  - **Arena lifecycle:** Verify no heap memory leaks or use-after-free during search ranking.
- **Mock-server E2E:** LLM turn emits `mini.memory("insert", { tier: "global", ... })`, next turn asserts `[MemAct Semantic Memory]` contains `[global/...]`.
- **Pre-commit Gate:** All existing 13/13 All-In-One test steps must pass cleanly.

---

## 7. Decision Log (Alternatives Rejected)

| # | Alternative | Why Rejected |
|---|---|---|
| 1 | Global procedural graph + auto-mirrored tool transitions | Rejected: Principle is **model-driven global writes only**. Auto-mirroring reintroduces noise and acts as a cross-project token leakage vector. |
| 2 | Automatic scope classification on LLM-extracted records | Rejected: The model calling `memory insert` with explicit `tier` is the decision point; hidden classifiers are non-deterministic and untestable. |
| 3 | Two separate tools (`mem_insert`, `mem_retrieve`) | Rejected: One tool keeps registry overhead minimal (15 → 16) and mirrors multi-action patterns like `sessionDetail`/`sessionKill`. |
| 4 | A `scope` field on `MemoryEntry` | Rejected: Modifying append-only legacy lines requires schema migrations; directory isolation cleanly defines the tier. |
| 5 | Single fused BM25 index over global+local pre-RRF | Rejected: Makes quota enforcement impossible (a large global corpus would drown out local project entries). |
| 6 | Synchronous LLM query expansion inside tool `retrieve` | Rejected by technical review: Calling `backend.send()` inside an active CodeAct turn blocks QuickJS, adds multi-second network latency, and risks watchdog timeouts. The tool uses Path A; passive prompt injection retains dual-path. |
| 7 | Lockless append on shared `global/memory.jsonl` | Rejected by technical review: Multiple concurrent `mini` sessions racing on `file.length()` cause truncated lines and corrupt JSONL files. POSIX advisory locking is mandatory. |
| 8 | Asymmetric 20-char content guard (global only) | Rejected by technical review: RFC-025 Phase 0 drops any record with `content.len < 20` during retrieval. Allowing local inserts $< 20$ chars creates silent unsearchable writes. Both tiers must enforce min 20 chars. |
| 9 | Passing `AgentLoop` directly into QuickJS C-ABI | Rejected by technical review: Violates engine sandbox isolation. The `SnapshotTracker` singleton pattern (`manager.zig`) is the established clean pattern in this codebase. |

---

## 8. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Multi-process race condition on global JSONL | Mandatory POSIX advisory file locking (`flock(LOCK_EX)`) during writes; `touch()` method banned on global store |
| Model over-inserts into global tier (pollution) | Append-only JSONL remains human-editable; model-reported confidence allows weighting; strict validation guards (§3.3) |
| Dangling pointers in search ranking results | `searchTier` uses an `ArenaAllocator` encompassing entries, doc texts, indices, and ranked results |
| Quota starves project-specific knowledge | Score-aware merge reserves primary budget for local memories; global entries are strictly capped at `global_quota * budget` |
| In-Act tool execution latency | Tool `retrieve` uses lexical BM25 Path A only, avoiding secondary LLM HTTP roundtrips |
| Global store empty on fresh install | Zero-cost early return (`doc_texts.items.len == 0`) without disk scanning |
| Global index scaling over time | `loadIndex` caches entries based on file `$mtime`, invalidating only when modified |

---

## 9. Success Metrics

1. **Routing correctness:** 100% of `tier: "global"` inserts land in `global/memory.jsonl` and never in project stores (test-enforced).
2. **Concurrency safety:** Zero corruptions or line interleaving under 4-way parallel CLI process writes (test-enforced).
3. **Cross-project recall:** Records seeded in project A appear in project B's top-k merged prompt block under `[global/<type>]`.
4. **Budget discipline:** Global contribution never exceeds `quota × memact_memory_budget`.
5. **No regressions:** All existing test steps (`zig build test --summary all`, 13/13) remain fully green.
