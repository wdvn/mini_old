# RFC-030: Durable Task Layer — Checkpoint & Cross-Session Resume

- **Status**: Draft
- **Date**: 2026-10
- **Scope**: `src/core/` (new `task/` module), `src/core/journal.zig`, `src/core/agent/`, `src/main.zig` (CLI), `src/tooling/registry.zig` (minor)
- **Related**: RFC-019 (Structured Planning), MemAct reactive compaction, `core/cas.zig`, `core/plan/store.zig`, `core/history/backup.zig`

---

## 1. Problem Statement

A mini-agent task (a user request spanning multiple acts/turns) currently lives only
in process memory:

1. **Crash / kill / power loss**: a long task (multi-file refactor, benchmark run,
   background jobs) is lost. The journal (`~/.mini/sessions/journal_<pid>.jsonl`)
   records *what happened* for diagnostics, but nothing consumes it to *continue*.
2. **Interrupt (Ctrl+C)**: `task_interrupted` is journaled, but there is no path to
   pick the task back up; the user must re-explain the goal and re-do completed work.
3. **Context overflow / stall**: the agent can end a task in a `task_stalled` /
   `task_failed` state with no durable pointer back to "where we were".
4. **Cross-session**: plans persist via `PlanStore` (CAS + `metadata.jsonl`), but a
   plan alone does not restore conversation history, file-side-effect state, or
   in-flight work.

This is the single largest differentiator vs. Pi Durable: **durable task/checkpoint
resume** — a task is a first-class, crash-safe, resumable entity.

## 2. Goals / Non-Goals

**Goals**

- G1: Every user request that becomes a multi-act task gets a durable `TaskRecord`.
- G2: Conversation history is durably appended at act boundaries; a crash between
  appends loses at most the last act's messages.
- G3: Resume restores the **full prior context** — the model sees the entire
  conversation history up to the last completed act and continues from where the
  task stopped. Resume granularity is the act/turn, never the individual tool call.
- G4: Resume is explicit and opt-in at startup (`mini --resume`, `mini --continue`);
  normal fresh sessions are unaffected.
- G5: **Tool dispatch is untouched.** No request-id generation, no pre-execution
  ledger checks, no cached observations. The act loop and tool dispatch path
  behave identically in fresh and resumed sessions; replay decisions (e.g. "was
  that interrupted bash call already effective?") belong to the model, which is
  given the full context plus an explicit uncertainty note.

**Non-Goals**

- Distributed/multi-process task execution; tasks remain single-process.
- Time-travel to arbitrary past points (the history log is linear per task).
- Automatic background resume of interrupted tasks.
- Exactly-once tool execution semantics (requestId ledger, cached observations).
  Model-driven replay with full context is sufficient for the accepted risk
  profile; a requestId/EffectLedger layer can be added by a later RFC if
  duplicate-effect guarantees become necessary.

## 3. Design Overview

```
                    ┌──────────────────────────────┐
   user request ───▶│ TaskManager (core/task/)     │
                    │  TaskRecord (tasks.jsonl)    │
                    │  History log (history.jsonl) │
                    │  Snapshot blobs    (CAS)     │
                    └──────┬───────────────┬───────┘
                           │               │
              append new messages     restore full
              at act boundaries       context + recap
                           │               │
              ┌────────────▼───┐   ┌───────▼──────────┐
              │ Agent loop     │   │ mini --resume /  │
              │ (act boundary) │   │ --continue       │
              └────────────────┘   └──────────────────┘
                           │
                    journal.zig (existing WAL, extended)
```

Two new durable primitives (plus the reused journal), all built on existing
infrastructure (CAS for content, JSONL for metadata — same pattern as
`PlanStore`):

| Primitive | Storage | Purpose |
|---|---|---|
| `TaskRecord` | `~/.mini/tasks/<project_hash>/tasks.jsonl` | Task identity, status, pointers |
| `History log` | `~/.mini/tasks/<project_hash>/<task_id>/history.jsonl` | Append-only conversation history; full-context restore |
| `Snapshot` | CAS blob, referenced from history log | Pinned history state after MemAct compaction |

## 4. Detailed Design

### 4.1 TaskRecord

Created lazily: only requests that enter the act loop (>= 2 acts or >= 1
side-effecting tool call) become durable tasks. Pure Q&A stays ephemeral
(no I/O cost for trivia).

```zig
// src/core/task/types.zig
pub const TaskStatus = enum {
    running,
    completed,
    failed,
    interrupted,
    stalled,
    resumable, // derived: interrupted | failed | stalled with durable history
};

pub const TaskRecord = struct {
    task_id: []const u8,        // uuid v4 (hex, 32 chars)
    request_hash: u64,          // hash of user request (links to PlanStore)
    request_text_hash: []const u8, // CAS hash of the original prompt (verbatim)
    project_hash: []const u8,
    status: TaskStatus,
    created_at: i64,
    updated_at: i64,
    /// CAS hash of latest full-history snapshot (written on MemAct compaction).
    snapshot_hash: ?[]const u8,
    /// Number of history log lines consumed by the latest snapshot.
    snapshot_seq: u64,
    /// Byte offset into the task's history log persisted at last task update.
    history_offset: u64,
    /// Aggregated usage for post-hoc cost analysis.
    llm_calls: u64,
    tool_calls: u64,
    title: []const u8,          // short LLM-free title (first 80 chars of request)
};
```

Storage mirrors `PlanStore`: append-only `tasks.jsonl` per project
(`~/.mini/tasks/<project_hash>/`), last line per `task_id` wins (linear scan on
resume; file stays small — one record per multi-act task).

### 4.2 Append-Only History Log (Full-Context Restore)

Per-task directory `~/.mini/tasks/<project_hash>/<task_id>/` contains one
`history.jsonl`: the durable mirror of the agent's conversation history. The
design goal is **full-context resume** — on `--resume`, the model sees the entire
conversation up to the last completed act and continues from there; it is never
reduced to a summary-only "checkpoint state".

**Record shapes** (one JSON object per line):

```json
// Snapshot line: full history state (written when the log baseline must be pinned).
{ "type": "snapshot", "seq": 3, "cas_hash": "<full serialized history>", "plan_phase": "executing", "ts": ... }

// Delta line: messages appended since the previous line (normal case).
{ "type": "delta", "seq": 4, "messages": [ { "role": "user", "content": "..." }, ... ], "act_id": 12, "ts": ... }
```

**Append triggers** (act boundaries where the loop is quiescent — write cost is
O(new messages), never O(history)):

1. After `act_completed`: append the messages the act added to history
   (assistant response, CodeAct outputs, tool results) as one `delta` line.
2. After MemAct compaction (`memact_compacted`): write a `snapshot` line with
   the full compacted history in CAS, and continue appending deltas on top.
3. On terminal/interrupt states (`task_interrupted`, `task_completed`,
   `task_failed`, `task_stalled`): flush any pending delta and update the
   `TaskRecord`.

**Restore** = read the last `snapshot` line, then replay all subsequent `delta`
lines. Result is byte-identical to the in-memory history at the last completed
act boundary — full context, not a summary. Because appends happen only at act
boundaries, a crash mid-act loses at most the in-flight act's messages.

`act_history_checkpoint` is set to the end of the restored prefix on resume, so
the existing retry-rollback machinery (`turn.zig`) keeps working unchanged.

### 4.3 Interruption Surface (No Tool-Dispatch Changes)

Tool dispatch is completely untouched: no request-id, no ledger, no cached
observations — the same code path runs for fresh and resumed sessions. The only
resume-time addition is an **uncertainty note** derived from the journal tail
(events after the last history-log line):

- If the last act started but never completed, the note states which tool it was
  executing and that completion is unknown:
  > "The previous session was interrupted while executing `bash: zig build test`.
  > Its completion state is unknown — verify before relying on the outcome."
- If any file was changed after the last history line (detected via CAS file
  snapshot hashes in the journal tail), the note lists the drift.

The note is injected as an ephemeral guidance block (same mechanism as
post-compaction reinjection). What to re-run — if anything — is the model's
decision, made with full context. Repeated identical effects are accepted as a
known limitation of model-driven replay (see Non-Goals); a requestId/EffectLedger
exactly-once layer is deliberately deferred to a future RFC.

### 4.4 Journal Integration

`journal.zig` keeps its role as the WAL. Changes:

- New `ActEventType`s: `task_history_appended`, `task_resumed`.
- On resume, the journal file is **continued** (same `task_id` namespace) rather
  than a fresh anonymous file; the history log's last line index tells the
  reader where the pre-crash conversation ends and the journal tail begins.

### 4.5 Resume Flow

```
mini --resume <task_id>          # resume a specific task
mini --continue                  # interactive picker: most recent resumable task
```

Resume procedure (implemented in `core/task/resume.zig`):

1. Load `TaskRecord` (must be `interrupted` | `failed` | `stalled`); status → `running`.
2. Restore **full history** from the history log (last `snapshot` + subsequent
   `delta` lines); set `act_history_checkpoint` = end of restored prefix so the
   retry-rollback machinery keeps working unchanged.
3. Restore plan from `PlanStore.restoreRunning(request_hash)` (existing) if the
   TaskRecord/plan links to one.
4. Build the interruption-surface note from the journal tail (§4.3): incomplete
   last act + external file drift — injected as an ephemeral guidance block.
5. Drop the stale process-bound state (background jobs, VM globals) — Per-Act VM
   isolation means a fresh `JSContext` is created anyway; `process_manager`
   children are reported as orphaned in the note, never silently revived.
6. Continue the act loop with the original user request (already message 0 of the
   restored history) — the model sees the entire prior conversation and decides
   the next step itself.

Crash during resume is safe: history-log appends are crash-tolerant by
construction (append-only; a torn last line is detected by JSON parse failure
and truncated on init).

### 4.6 Retention & GC

- `tasks.jsonl` compaction on init: fold to latest record per `task_id`
  (same append-log discipline as journal pruning).
- Terminal tasks (`completed`) keep their task directory (history log) for N days
  (`durable_tasks.retention_days`, default 14) then drop it; the
  `TaskRecord` line is kept for the journal-style cost/usage analytics.
- CAS GC reuses the existing content store; no separate refcounting in this RFC.

## 5. Module Layout

```
src/core/task/
  root.zig        — re-exports, wiring for main.zig DI
  types.zig       — TaskRecord, TaskStatus, HistoryLine (snapshot|delta)
  store.zig       — TaskStore: tasks.jsonl read/append/compact (mirrors plan/store.zig)
  history_log.zig — per-task history.jsonl: delta appends at act boundaries,
                    snapshot on MemAct compaction, restore = snapshot + deltas
  resume.zig      — resume procedure (§4.5) + interruption-surface note (§4.3)
```

Integration points (all small, mirror existing seams; **none** touch tool
dispatch):

- `core/agent/execution.zig`: call `TaskManager.appendHistoryDelta()` after
  `act_completed`.
- `core/agent/turn.zig`: on SIGINT path, flush pending delta + update TaskRecord.
- `core/memact/`: on `memact_compacted`, write snapshot line into history log.
- `main.zig`: `--resume` / `--continue` CLI flags → `task/resume.zig`.

## 6. Testing Plan

- **Unit (Tier 1, `src/core/task/*`)**: TaskStore append/compact/latest-wins;
  history log snapshot+delta restore round-trip; torn-last-line truncation;
  delta append at act boundary.
- **Integration (Tier 2, `testcases/test_durable_task.zig`)**:
  - Kill a task mid-way (simulate: write N acts, drop process) → `--resume`
    restores the full history (assert message count/order identical to the
    pre-crash in-memory history) → a mock backend continues and the final
    answer matches a non-interrupted reference run.
  - Incomplete last act: journal tail shows the interrupted tool call →
    interruption note names the tool and marks completion unknown.
  - File drift: mutate a file after the last history line → resume surfaces
    drift in the note.
- **E2E (Tier 3)**: extend mock LLM flows with a "resume" flow — mock server
  emits a task that stalls, then a second `mini --resume` invocation completes it.

## 7. Migration / Rollout

1. Phase 1: `types.zig` + `store.zig` + history-log appends at act boundaries
   (record everything, resume nothing) — pure write path, tool dispatch and turn
   semantics untouched.
2. Phase 2: `--resume` / `--continue` CLI + full-context restore +
   interruption-surface note.
3. Phase 3: retention/GC + usage analytics queries over TaskRecords.

Each phase ships independently; Phase 1 alone already answers "what was I doing
when it died" from `tasks.jsonl` + history log.

## 8. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| History append I/O slows long tasks | Only at quiescent act boundaries; cost is O(new messages), not O(history); snapshots only on compaction |
| Duplicate side effects after resume (model re-runs an interrupted call) | Accepted, model-driven: interruption note marks completion unknown so the model verifies first; requestId/EffectLedger layer deferred to a future RFC if needed |
| Torn last line after crash | Append-only JSONL; torn tail detected by JSON parse failure and truncated on init |
| History log format drift | Version field on snapshot line; resume refuses unknown versions with a clear error |
| Scope creep toward workflow engine | Task = single-process linear chain; no DAG, no retries-of-tasks — plans (RFC-019) stay the DAG layer |

## 9. Alternatives Considered

- **SQLite task store** (libsqlite3 is reserved in `build.zig`): rejected for now —
  JSONL + CAS matches PlanStore/journal conventions, needs no new linkage, and the
  data volume (one record per multi-act task) is tiny. A later RFC can migrate the
  store behind `TaskStore`'s interface without touching call sites.
- **Full-history CAS snapshot at every act** (initial draft): correct but O(history)
  per boundary; the snapshot+delta log achieves the same restore result at
  O(new messages) per boundary.
- **requestId/EffectLedger exactly-once dispatch** (initial draft): rejected for
  this RFC — it modifies the tool dispatch hot path (pre-execution ledger checks,
  cached observations) for a guarantee that model-driven replay with full context
  makes mostly unnecessary. Kept as a possible follow-up RFC if duplicate-effect
  risk proves unacceptable in practice.
- **Resume from journal replay only** (no history log): the journal records
  diagnostics, not the verbatim conversation messages; a durable history log is
  required for byte-identical full-context restore.
- **Auto-resume on next REPL start**: rejected (surprising mutations); explicit
  `--continue` keeps the user in control, consistent with "Confirm Before Mutation".
