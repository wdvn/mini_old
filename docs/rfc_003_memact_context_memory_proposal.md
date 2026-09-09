# RFC-003: MemAct — Context Compaction & Memory Management for mini-agent

| Attribute | Value |
|---|---|
| RFC | 003 |
| Title | MemAct: Context Compaction & Memory Management |
| Status | **v0.3 Implemented / Production** — Agent Loop has fully transitioned to Reactive Compaction upon encountering context length errors (drop-all + accumulated summary at index 1, preserving original prompt at index 0). M3/M4/M5 deferred per roadmap |
| Role | **Normative RFC**: All other RFCs referencing history / context / memory conform to this specification. Standard terminology: conversation history (tiers PINNED/RECENT/SUMMARIZED/ARCHIVED), compaction (reactive — only triggered on model error, drop-all + accumulated summary), memory (semantic/episodic/project_state). Note that editor **prompt input history** (RFC-000) is an independent concept outside this scope. |
| Version | 0.3 — Eliminated all window-based mechanisms (TokenEstimator wiring, ContextWindow, percentage thresholds, safety margins); compaction transitioned to **reactive-only**: compressing only when the model/backend reports context errors |
| Dependencies | RFC-001 (Code-Centric CodeAct), RFC-002 (Event-Driven Act) |
| Author | mini-agent |

> [!NOTE]
> Design Evolution:
> - **v0.1**: "Sliding window" compaction (retaining last N messages) + retrieval scoring — deprecated.
> - **v0.2**: Token-aware proactive compaction (heuristic token estimation, compacting when exceeding context window threshold percentage) + drop-all + cumulative summary.
> - **v0.3 (Current)**: Completely removed window mechanics — **the concept of context window is eliminated from mini**. Compaction runs purely reactively: when backends return "context too long" errors, the agent compresses history and retries. See §1.2 for rationale.

---

## 1. Motivation

### 1.1. Historical Vulnerabilities (Addressed in v0.2, Preserved Here)

1. **"Blind" Compaction** — Counting messages instead of tokens → replaced by token-aware compaction (v0.2), and now replaced by reactive compaction (v0.3): the model itself serves as ground truth.
2. **Context Loss During Compaction** — Legacy compaction retained only the second half → replaced with structured JSON summary stencils, accumulated cumulatively (retained in v0.3).
3. **Absence of Long-Term Memory** — Sessions started from scratch → JSONL MemoryStore created (`store.zig`), awaiting integration (M3, deferred).
4. **Claude API 400 "first message must be user"** — Automatic role normalization (retained in v0.3).
5. **Infinite Compaction Loops** of sliding windows (v0.1) — Solved by drop-all (retained).

### 1.2. Why Window-Based Compaction was Replaced by Reactive-Only (Core Shift in v0.3)

The v0.2 design (heuristic token estimation + window percentage thresholds) exhibited 4 real-world flaws:

1. **Estimations Are Inaccurate** — Heuristics drift by ±15% (lacking native tokenizers) → compacting prematurely (wasting context, dropping vital details) or too late (triggering HTTP 400 anyway).
2. **Window Configuration is Fragile and Stale** — `MINI_CONTEXT_WINDOW` + per-backend auto-detection required continuous maintenance as context sizes evolve (128K → 200K → 1M...). For compat proxies (vLLM, OpenRouter, LiteLLM), actual window limits depend on server configurations and cannot be guessed reliably.
3. **Turn-Level Overhead with Zero Return** — Running estimators across complete history before EVERY backend call incurred overhead even though compaction thresholds were rarely reached.
4. **Models Report Limits Explicitly** — Major backends return distinct, identifiable error signatures when prompts exceed context limits (see §4.2). Predicting what models already communicate is redundant.

Reactive-only offers **zero configuration** (no need to know model limits beforehand), aligns with the provider's actual window, and removes per-turn estimation overhead. The trade-off: a single rejected request when overflowing — acceptable given how infrequently compaction occurs.

---

## 2. Objectives

**Goals**
1. **Reactive Compaction** — Compress exclusively upon backend context errors; retry immediately within the same turn (allowing the model to resume via `task_state`/`next_step`).
2. Context Continuity: Structured JSON summary stencils accumulated cumulatively across compaction events.
3. Zero-Config Context Limits: No environment variables, no auto-detection, no heuristics.
4. Long-Term Memory: Extract and persist knowledge across sessions (deferred — storage implementation ready).
5. Seamless Integration: Conform to RFC-002 hooks dispatch and Act event models.

**Non-Goals**
- Any proactive/predictive compaction (token heuristics, percentage thresholds, message counts) — completely discarded.
- Retrieval scoring (keyword overlap + recency + access_count) — discarded since v0.2. Practical memory scales are compact; filtering + Top-K is sufficient.
- Vector database / embedding-based retrieval (deferred).
- Cross-project memory sharing and multi-user isolation.

---

## 3. Overall Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                      AgentLoop (agent.zig)                        │
│                                                                   │
│  Each turn: INVOKE BACKEND DIRECTLY (no pre-check, no estimate)  │
│                                                                   │
│  Backend response error branch:                                   │
│   if matchContextOverflowError(raw):            ── signature match│
│     summary = buildLocalSummary(prev_summary)   ── local stencil  │
│     history.compactMemAct(act_id, summary)      ── drop-all       │
│     journal: memact_compacted (reason=reactive)                   │
│     retry backend call (max 2 attempts/turn)                      │
│     └─ persists error on minimal [prompt, summary] → terminal fail│
│                                                                   │
│  ┌────────────────────────┐   ┌────────────────────────────────┐ │
│  │ History (history.zig)  │   │ MemoryStore (M3)               │ │
│  │ compactMemAct, tiers   │   │ store.zig — JSONL (unwired)    │ │
│  │ ✅ wired               │   │ ⚠️ deferred                    │ │
│  └────────────────────────┘   └────────────────────────────────┘ │
│  (TokenEstimator — removed from loop, utility-only;              │
│   ContextWindow window.zig — DELETED)                             │
└──────────────────────────────────────────────────────────────────┘
```

| Component | File | v0.3 Status | Responsibility |
|---|---|---|---|
| History + `compactMemAct` | `memact/history.zig` | ✅ wired | Drop-all compaction, tiers, msgs[0] invariant |
| Context-overflow signature matcher | `agent.zig` (local fn) | ✅ (M2c) | Identifies overflow errors from raw backend response bodies |
| Local summary builder | `memact/history.zig` | ✅ (M2c) | Generates local JSON stencil without LLM calls |
| ~~ContextWindow~~ | ~~`memact/window.zig`~~ | ❌ **deleted** | Concept of window removed |
| ~~TokenEstimator (wired)~~ | `memact/tokens.zig` | ➖ utility-only | No loop call-sites; preserved for memory budgets (M4) |
| MemoryStore | `memact/store.zig` | ⚠️ implemented, unwired | Persists memory to disk (append-only JSONL + index) |

---

## 4. Detailed Design

### 4.1. Agent Loop — No Pre-Call Checks

Each turn calls the backend directly with complete history. All pre-call evaluation logic is removed: no `needsCompaction()`, no `pinned_tokens`, no estimator cache. The model determines context validity.

### 4.2. Context-Overflow Signature Matching (Core Mechanism of v0.3)

Upon HTTP 400 (or response error), the agent inspects the raw error body against established signatures:

| Backend | Raw Body Signature |
|---|---|
| OpenAI / compat | `context_length_exceeded` |
| Anthropic (Claude) | `prompt is too long`, `input length and max_tokens exceed context limit` |
| Ollama | `context length exceeded`, `would exceed context length` |
| OpenRouter / vLLM / LiteLLM | `maximum context length`, `requested tokens exceed context` |

Matching rule: case-insensitive substring search over the raw error body. Supporting new backends requires adding a single signature entry.

Important distinction: `max_tokens` response limits are NOT context overflow errors — v0.2 previously conflated general `"max_tokens"` strings; v0.3 matches only context-overflow signatures.

### 4.3. Compaction — DROP-ALL (Trigger Updated from v0.2)

**Mechanism (`compactMemAct`):** When context overflow is reported, history compresses to exactly 2 messages:

```
Before: [original prompt, (previous summary?), msgs... ]
After:  [original prompt (tier .pinned), new summary (role .user, tier .summarized)]
```

- **msgs[0] (original user prompt) is never dropped** — invariant across all compactions.
- New summary **merges** previous summary (if msgs[1] is tier `.summarized`) → cumulative accumulation.
- Guard: If history is already compressed to minimal `[prompt, summary]` and overflow recurs → original prompt/summary exceeds model capacity → **terminal error**, avoiding infinite loops and detailing the cause to the user.
- Retry budget: Maximum 2 reactive compaction attempts per turn (`reactive_compact_attempts`) — guarding against false-positive signature matches.

### 4.4. Summary — LOCAL Stencil (Shift from v0.2)

v0.2 invoked the LLM to generate summary stencils from discarded history. **Issue under reactive flows**: requests that failed for excessive length would likewise fail when sending the same history wrapped in a summarization prompt.

v0.3 generates summaries **entirely locally**, requiring no LLM calls:

```json
{
  "type": "context_summary",
  "trigger": "reactive",
  "error_signature": "context_length_exceeded",
  "iteration_range": [12, 87],
  "task_state": "Context exceeded model limit at Act 87; compressed 74 messages. Accumulated summary retained below.",
  "decisions": ["...preserved from prior summary..."],
  "open_questions": ["..."],
  "learned_errors": ["..."],
  "files_touched": ["..."],
  "next_step": "Review this summary and prompt user for confirmation if missing context."
}
```

- Fields `decisions/open_questions/learned_errors/files_touched` are **carried forward intact from prior summaries** — preserving historical continuity.
- First compaction without existing summary: fields initialize empty; `task_state` notes that detailed history was truncated, prompting the model to seek clarification on missing context.
- **Post-Compaction Refinement (Optional, Same Turn):** Following drop-all, history is minimal → an optional lightweight LLM call can flesh out the stencil if higher fidelity is desired (off by default).

### 4.5. Claude 400 Role Normalization (Preserved from v0.2)

- `ensureClaudeCompatible()`: Converts initial message role to `.user` if necessary.
- Agent loop detects HTTP 400 role issues → executes normalization → retries up to 2 times/turn.
- Evaluated prior to context-overflow matching.

### 4.6. MemoryStore (`store.zig`) — Implemented, Unwired (M3+)

```
~/.mini/memory/
  <project_hash>/
    memory.jsonl          # append-only, one event per line
    index.json            # materialized view: active entries (with supersedes applied)
```

Schema + 3 memory types (`semantic`/`episodic`/`project_state`) + supersedes rules conform to v0.2 definitions. When wired in M4: load index → filter type + `confidence >= 0.7` → sort `ts` → Top-K without complex scoring.

### 4.7. Integration with Existing System

| Hook / Event | v0.3 Implementation |
|---|---|
| `pre-prompt` dispatch | ✅ Preserved — no longer checks compaction (user hooks only) |
| `pre-context-build` hook + `MINI_CTX_BUDGET`/`MINI_CTX_USED` | ❌ **Removed payload fields** (ctx budget concept removed); redesign for M5 |
| `post-session-end` hook | ⚠️ Infrastructure ready, awaiting call-site (M5) |
| Act event `memact_compacted` | ✅ Added `reason="reactive"` + `error_signature` |
| `tier` field in `Message` | ✅ Preserved (`protocol.zig`) |
| Archived JSONL (undo log) | ❌ Deferred — drop-all discards raw messages post-compaction |

**Rollback Control:** `History.last_compaction_act_id` blocks rollbacks beyond compaction boundaries.

---

## 5. Configuration

Deprecated environment variables (removed in M2c):

```bash
MINI_CONTEXT_WINDOW=128000        # ❌ Removed — window concept eliminated
MINI_CTX_SAFETY_MARGIN=0.15       # ❌ Removed
MINI_CTX_COMPACT_THRESHOLD=0.85   # ❌ Removed
```

Retained variables:

```bash
MINI_MEMACT_TOP_K=8               # (M4) number of memories injected into prompt
MINI_MEMACT_MEMORY_BUDGET=2000    # (M4) token budget for memory block
MINI_MEMACT_EXTRACT=async         # (M5) async | sync | off
MINI_MEMORY_DIR=~/.mini/memory    # (M3) memory store directory
```

`MINI_MEMACT_ENABLED`: Removed (reactive compaction is standard).

---

## 6. Milestones

| M | Item | Status | Notes |
|---|---|---|---|
| **M1** | ~~TokenEstimator + ContextWindow wiring~~ | ✅ (v0.2) → **Removed in M2c** | commit `774faad` |
| **M2a** | Retain original prompt across compaction + Claude 400 role-fix | ✅ Complete | commit `1c8e721` |
| **M2b** | Drop-all + cumulative summary accumulation | ✅ Complete | commit `8d782e9` |
| **M2c** | **Reactive Rewrite**: remove needsCompaction/estimator loop wiring/window.zig, add signature matcher + local summary builder + retry-on-overflow | ✅ Complete | This RFC |
| **M3** | Wire MemoryStore into agent | ⚠️ Implemented (`373beea`), unwired | — |
| **M4** | Inject memory into system prompt (filter + Top-K) | ❌ Deferred | — |
| **M5** | Extraction pipeline + Act memory events | ❌ Deferred | — |

---

## 7. Acceptance Criteria

Established:
1. ✅ **No mid-pair split** — drop-all leaves no orphaned `tool_use`.
2. ✅ **Context continuity** — cumulative summary stencil; msgs[0] invariant.
3. ✅ **Claude 400 role-fix** — ensureClaudeCompatible + 2 retries/turn.

M2c Criteria:
4. ✅ **Zero window config** — removed deprecated env vars; zero occurrences of `MINI_CONTEXT_WINDOW`/`MINI_CTX_` in active loop logic.
5. ✅ **Reactive compact** — mock backend returning `context_length_exceeded` triggers successful compaction + retry in same turn; signature matcher tests pass.
6. ✅ **No compaction without errors** — 100+ message history accepted by model remains uncompacted.

Pending M3/M4/M5:
7. ⬜ **Cross-session recall** — new sessions in project contain project_state memory block.
8. ⬜ **Disk format** — idempotent memory.jsonl + index.
9. ⬜ **Latency** — retrieval <5ms / 1,000 entries.

---

## 8. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Wasted request on overflow (single 400 call prior to compaction) | Acceptable — compaction is rare; yields zero-config and model parity |
| False-positive signature matches | Narrow signature list; 2 retry limit per turn prevents loops |
| Unknown backend signature misclassified as generic error | Fallback pattern: HTTP 400 with `context`/`length`/`token` logs raw body with remediation guidance |
| Local summary lower fidelity than LLM summary (v0.2) | Retains fields from previous summaries; `task_state` instructs model to seek missing context |
| Context overflow persists after compressing to [prompt, summary] | Terminal error guard alerts user that prompt + summary exceeds model limits |
| Drop-all discards original messages permanently | `last_compaction_act_id` prevents invalid rollback; archived JSONL planned |
| Stale memory polluting prompts | `supersedes` + confidence threshold 0.7 (upon M4 wiring) |

---

## 9. Alternatives Considered

1. **(v0.2) Proactive Token-Aware Compaction** — Production showed: ±15% estimation drift, fragile window configurations, and per-turn overhead while still requiring reactive fallbacks. Model errors provide exact signals.
2. **tiktoken WASM Tokenizer** — More precise than heuristics but fails to address variable proxy window limits.
3. **SQLite instead of JSONL** — Adds external dependencies; JSONL + index suffices for <10K entries.
4. **Local Embedding RAG** — Architectural goal for v2, non-blocking for current architecture.
5. **Hybrid Approach** — Combining proactive estimations with reactive fallbacks retained all configuration drawbacks. Discarded.

---

## 10. Future Work (v2+)

- Wire MemoryStore into agent loop (M3): initialize per project-hash, persist on session close.
- Inject memory blocks into system prompt (M4): filter + Top-K.
- Act memory events + extraction pipeline (M5).
- Archived JSONL on compaction — enabling reversible drop-all (undo log for Act rollbacks).
- Optional LLM-assisted summary refinement post-compaction (§4.4).
- Embedding-based retrieval if memory exceeds ~1,000 entries/project.
- Memory CLI inspection: `mini memory list|prune|export`.
- User-editable memory — `MINI.md` automatically ingested into PINNED tier.
