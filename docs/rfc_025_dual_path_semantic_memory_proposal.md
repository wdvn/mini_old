# RFC-025: Dual-Path Semantic Memory — Declarative Store + Procedural Graph Consolidation

**Status**: Implemented (Phases 0–3, landed on `feat/rfc_025`; Phase 4 deferred to 2026)
**Date**: 2026-09-25
**Author**: MemAct Engineering
**Related**: RFC-003 (MemAct MemoryStore), RFC-010 (Procedural Graph)
**Supersedes**: `docs/proposal_agent_memory_architecture.md` (promoted to this RFC; original removed)
**Tags**: Agent Memory, Retrieval, Graph, Embedding-Free

---

## 1. Executive Summary

This RFC consolidates mini's two memory subsystems into a single **Dual-Memory Architecture**:

1. **Declarative Memory** (`MemoryStore`, `src/core/memact/store.zig`) — text records +
   metadata, retrieved by an **Embedding-Free Dual-Path LLM Query Expansion** design
   (Exp4Fuse, ACL 2025): run BM25 on the *original query* and on an *LLM-expanded query*
   in parallel, fuse with Reciprocal Rank Fusion (RRF, k=60). No vector DB, no embedding
   API cost, lexical-exact recall of private entities (error codes, identifiers) preserved
   by the original-query path.
2. **Procedural Memory** (`PGraphStore`, `src/core/memact/graph_store.zig`, RFC-010) —
   event-sourced DAG of tool nodes and transitions with h-hop neighborhood guidance and
   orbit detection.

Retrieved declarative records carry a `node_ref` mapping into the procedural graph, so a
single lookup returns not only *facts* but also the **causal chain / workflow** around them
(2-hop traversal via `traverseNeighborhood` over the CSR view).

In addition to the forward design, this RFC records a **remediation of the current
episodic write-path** (§2), which today stores only a tool name with a hardcoded
confidence and is pure noise in the semantic-memory injection block.

---

## 2. Current State — What mini Already Has (Evidence)

### 2.1 Implemented components

| Component | File | Evidence |
|---|---|---|
| Declarative store (JSONL, append-only, supersedes) | `src/core/memact/store.zig` | `MemoryEntry { id, ts, type, content, keywords, source_session, confidence, supersedes, access_count, last_access }`; `append()` is pure-append, `loadIndex()` rebuilds active index with audit trail preserved |
| Procedural graph (event-sourced DAG, h-hop guidance, orbit detection) | `src/core/memact/graph_store.zig` | `PGraphStore` at `~/.mini/memory/<project_hash>/pgraph.jsonl`; `recordTransition()` auto-promotes frequent transitions (N ≥ 3); `serializeGuidance()` renders 2-hop advisory or orbit checkpoint |
| Token estimation (compaction + injection budget) | `src/core/memact/tokens.zig` | `TokenEstimator.estimate()` heuristic (~4 chars/token EN, ~1.5 CJK) |
| Semantic injection (keyword match, top-k, budget-capped) | `src/core/agent.zig` L980+ | `injectSemanticMemory()`: loads index, scores `confidence * (access_count+1) + 0.5 * keyword_matches`, injects top-8 within 2000-token budget |

### 2.2 Defect: the episodic write-path is noise (RFC-025 Phase 0)

`AgentLoop.appendEpisodicMemory()` (`src/core/agent.zig` L710–743) appends, on **every
successful tool call**, an entry whose entire payload is the tool name:

```zig
.content    = tool_name,          // "file_read"
.keywords   = &[tool_name],
.confidence = 0.7,                // hardcoded constant, no epistemic meaning
```

Consequences (observed, not theoretical):

1. **Redundant with PGraph.** The same `onToolCompleted` (L747) already calls
   `pg.recordTransition(prev_tool, tool_name)`. The episodic entry is a strictly
   weaker copy of what the graph tracks (transitions + frequency gate + guidance text).
2. **Redundant with the journal.** `src/core/journal.zig` already logs full audit events
   including tool calls, inputs, outputs, and errors.
3. **Poisons the injection block.** `injectSemanticMemory()` keyword-matches tool names
   out of the prompt (any 3–30 char word like "file" or "read" matches). High-frequency
   tool names dominate top-k, so the 2000-token semantic memory budget is consumed by
   rows such as `[episodic] file_read` × N with zero task context. Every current
   session prompt shows exactly this.
4. **`confidence` is decorative.** Nothing in the codebase assigns confidence
   meaningfully; it cannot serve as a ranking signal.

**Decision (Phase 0):** remove the per-tool-call episodic write-path. `MemoryStore`
retains only `semantic` and `project_state` entries whose `content` carries real
information. This is a ~50-line deletion with no schema migration.

### 2.3 Design alignment gap

Even after Phase 0, the store's retrieval is single-path exact keyword matching
(`matchKeyword`, ASCII case-insensitive substring). The forward design (dual-path
expansion + RRF + graph enrichment) is not implemented and is the subject of Phases 1–4.

---

## 3. Proposed Design

### 3.1 Retrieval architecture

```text
                    [ User / Agent Query ]
                          │
       ┌──────────────────┴──────────────────┐
       ▼                                     ▼
  (Original Query)                  (LLM Query Expansion)
  "Why did deploy fail?"            "CI/CD crash, OOMKilled, error 137"
       │                                     │
       ▼                                     ▼
   [ BM25 ]                             [ BM25 ]
       └──────────────────┬──────────────────┘
                         ▼
          [ Reciprocal Rank Fusion (k=60) ]
          Score = 1/(k+rank_A) + 1/(k+rank_B)
                         ▼
               [ Declarative Memory ]
         record: "Container OOMKilled" (node_ref: 42)
                         ▼
              [ PGraphStore: traverseNeighborhood(42, 2) ]
                         ▼
                 [ Enriched Context ]
  "record + causes: NodeId 45 rollback script + LEADS_TO guidance/pitfalls"
```

Design principle: **semantic understanding at the query layer (stateless),
lexical exact-match at the storage layer, causal traversal at the graph layer.**

- **Path A (original query):** guarantees exact recall of private entities — error
  codes, identifiers, internal names.
- **Path B (LLM-expanded query):** a semantic safety net for synonyms and related
  concepts. Prompt template requires keyword/pseudo-doc output only (no prose).
- **RRF fusion:** documents matching both paths float to the top; `k=60`.
- **Storage:** plain text + metadata + `node_ref`. No embeddings, no ontology
  maintenance at write time.

### 3.2 Consolidation semantics (PG ↔ Memory)

| Concern | Owner | Rationale |
|---|---|---|
| Tool transitions, workflow causality, guidance/pitfalls | `PGraphStore` | Already event-sourced with frequency gate and cycle repair |
| Facts, project state, distilled lessons | `MemoryStore` | `content` text + metadata; `supersedes` handles correction |
| Cross-link | `MemoryEntry.node_ref: ?NodeId` (new, nullable) | Retrieval returns record, then 2-hop graph traversal enriches |

Rules:

1. **No dual writes.** A tool call populates *only* the PGraph transition counter
   (existing `recordTransition`). The declarative store is written only by
   (a) LLM extraction of durable facts/lessons (Phase 3) or (b) `project_state`
   supersede updates.
2. **Confidence is re-defined, not kept.** For LLM-extracted records, `confidence`
   comes from the extraction prompt (model self-report + verification flag:
   "confirmed by successful test run" → high, "inferred" → low). Hardcoded
   constants are banned.
3. **Injection filter:** an entry is eligible for `[MemAct Semantic Memory]` only
   if `len(content)` exceeds a small threshold (rejects tool-name-only rows
   defensively, even if legacy files exist on disk).
4. Legacy episodic lines remain in `memory.jsonl` (event-sourcing audit trail)
   but are filtered from the active index / injection.

### 3.3 Orbit & checkpoint

Already implemented in RFC-010 (`detectTrajectoryOrbit`, 3D domain model
EXPLORE/MUTATE/VERIFY/META). Unchanged; listed here for completeness of the
consolidated memory surface.

---

## 4. Implementation Phases

### Phase 0 — Kill the noise write-path (do first, unblocks all else)
- Delete `appendEpisodicMemory` and its call in `onToolCompleted` (`agent.zig`).
- Add content-length guard in `injectSemanticMemory` (filter `len(content) < 20`).
- `zig build test --summary all` → 13/13 pass.

### Phase 1 — Lexical foundation (BM25)
- Replace `matchKeyword` with a small in-tree BM25 over `content` + `keywords`
  (Zig, std-only). FTS5/SQLite is explicitly out of scope (no new deps).
- Metadata filter support for record type / session scope.

### Phase 2 — Dual-path expansion + RRF
- LLM expansion prompt template (keywords only, capped latency; runs concurrently
  with BM25(original), awaited before fusion).
- RRF fusion, k=60; top-K selected by fused score.

### Phase 3 — Graph enrichment + LLM extraction
- Add `node_ref` to `MemoryEntry` (nullable; old lines parse as `null`).
- Retrieval pipeline: RRF top-K → for each record with `node_ref`,
  `traverseNeighborhood(node_ref, h=2)` → merge guidance/pitfalls into context block.
- Background/async LLM extraction (config `memact_extract: "async"` already exists,
  currently unwired) writes `semantic` records with meaningful `confidence`.

### Phase 4 — Auto-tuning (2026, future extension)
- Offline background job samples existing memory records as in-domain few-shot
  exemplars for the Phase 2 expansion prompt, adapting to project jargon without
  fine-tuning.

---

## 5. Files Modified / Created

| File | Change |
|---|---|
| `src/core/agent.zig` | Remove `appendEpisodicMemory`; add content-length guard in injection (Phase 0) |
| `src/core/memact/store.zig` | `node_ref` field; BM25 retrieval API (Phase 1/3); legacy-line filtering |
| `src/core/memact/bm25.zig` | *(new)* BM25 + RRF |
| `src/core/memact/graph_store.zig` | No structural change; expose `traverseNeighborhood` for enrichment |
| `src/core/config.zig` | Wire `memact_extract` (Phase 3); tuning job toggle (Phase 4) |

## 6. Success Metrics

1. **Prompt hygiene:** zero tool-name-only rows in `[MemAct Semantic Memory]` blocks
   (verify by grepping session journals after Phase 0).
2. **Recall:** on a curated 20-query eval set (error codes, synonyms, project
   state), dual-path RRF ≥ single-path keyword on 15/20; exact-match recall of
   private entities never regresses below keyword baseline (Path A guarantee).
3. **Token efficiency:** injection block token-per-relevant-record ratio improves
   (relevant = record cited in ≥1 successful act) vs. pre-Phase-0 baseline.
4. **Learning:** auto-promoted graph edges from `recordTransition` continue to
   accumulate (no regression from write-path removal).

## 7. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| LLM expansion adds latency to every retrieval | Expansion is async and capped; on timeout, Path A results stand alone (graceful degrade) |
| RRF over small memory sets behaves like plain keyword match | Acceptable at v1; re-evaluate once store exceeds a few hundred records |
| `node_ref` dangling after graph repairs/eviction | Null-guard at enrichment; record renders without graph context |
| Extraction hallucination pollutes store | Confidence + verification flag gating; `supersedes` correction path already exists |
| Legacy noise lines persist on user machines | Injection filter (content-length guard) makes them inert without data migration |

## 8. Benefits Summary

1. **Zero embedding cost** — no per-write embedding API calls.
2. **Stateless, editable knowledge** — memory is plain text; auditable and supersede-able.
3. **No ontology maintenance** — the graph stores procedural causality only; the
   LLM handles semantics at query time.
4. **Private-entity resilience** — the original-query path guarantees 100% lexical
   recall of identifiers, error codes, and internal names.
