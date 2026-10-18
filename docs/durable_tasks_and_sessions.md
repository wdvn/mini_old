# Durable Tasks, Sessions & Write-Ahead Journaling

## 1. Durable Task Layer (RFC-030)

Traditional terminal coding agents hold multi-turn state exclusively in volatile process memory. If the process is interrupted (Ctrl+C), terminated, or killed due to a power outage or system crash, all progress is lost, forcing the user to re-state the problem and the model to repeat completed work.

`mini-agent` addresses this with the **Durable Task Layer** ([RFC-030](rfc_030_durable_task_resume_proposal.md)).

```
┌────────────────────────────────────────────────────────┐
│ Turn Execution (Act N)                                 │
│ 1. LLM Streams Response                                │
│ 2. Tools Execute in VM                                 │
│ 3. CAS Captures File Snapshots                         │
└───────────────────────────┬────────────────────────────┘
                            │
                            ▼
┌────────────────────────────────────────────────────────┐
│ Act Boundary Checkpoint Commit                         │
│ 1. Append messages to ~/.mini/tasks/<task_id>/history  │
│ 2. Update TaskRecord status in task.json               │
│ 3. Flush journal event act_completed                   │
└───────────────────────────┬────────────────────────────┘
                            │
                            ▼
           [Process Crash / Power Loss / Ctrl+C]
                            │
                            ▼
┌────────────────────────────────────────────────────────┐
│ Recovery & Resume (mini --resume <task_id>)            │
│ 1. Read TaskRecord & verify consistency                │
│ 2. Replay history.jsonl into memory                    │
│ 3. Invalidate dangling intermediate state               │
│ 4. Re-enter Agent Loop with full context preserved     │
└────────────────────────────────────────────────────────┘
```

### 1.1. Storage Layout & Schema

Every multi-act task receives an isolated checkpoint directory under:
```
~/.mini/tasks/<task_id>/
├── task.json               # Task metadata, status, root goal, created/updated timestamps
└── history.jsonl           # Append-only record of conversation messages up to the last act
```

#### `task.json` Schema
```json
{
  "task_id": "task_1729281234_abc",
  "root_goal": "Refactor protocol parser and add tests",
  "status": "in_progress",
  "created_at": 1729281234,
  "updated_at": 1729281290,
  "last_completed_act": 4,
  "workspace_root": "/home/user/projects/mini"
}
```

### 1.2. Resumption Semantics (`--resume` and `--continue`)

- **Resumption via ID**:
  ```bash
  mini-agent --resume task_1729281234_abc
  ```
- **Continue Most Recent Task**:
  ```bash
  mini-agent --continue
  ```
  Automatically discovers and resumes the most recent unfinished task in the current workspace.
- **Context Reconstruction**: The model context is reconstructed up to the exact state of `last_completed_act`. The model receives an explicit resumption note detailing that execution is continuing from a checkpoint, allowing it to inspect disk state and proceed without repeating completed actions.

---

## 2. Session Persistence

In addition to durable task checkpoints, `mini-agent` supports simple session saving and restoring for conversations that do not require full task lifecycle management.

### 2.1. Usage

```bash
# Start a named session (automatically saved to ~/.mini/sessions/refactor-ui.json)
mini-agent --session refactor-ui

# Continue the named session in a single-shot prompt
mini-agent --session refactor-ui -e "Continue with step 2"

# Use a direct session file path
mini-agent --session-file ./history.json
```

- When `--session` is provided, the agent loads previous messages upon startup and automatically persists the updated history upon exit.
- History saving can be globally suppressed using `MINI_NO_HISTORY=1`.

---

## 3. Write-Ahead Journaling (WAL) & Observability

`mini-agent` writes an event-sourced audit log for every session to enable post-mortem analysis and telemetry inspection:
```
~/.mini/sessions/journal_<pid>.jsonl
```

### 3.1. Journal Event Taxonomy

Each line is a self-contained JSON object recording a lifecycle event:

| Event Type | Description |
|---|---|
| `task_started` | Task initiation with initial prompt and configuration parameters. |
| `act_started` | Beginning of a model turn / action cycle. |
| `act_completed` | Successful completion of an act, including delta token usage and latency. |
| `act_failed` | Turn failure with structured error classification. |
| `llm_call_throttled` | Upstream rate limit (HTTP 429) event with retry backoff duration. |
| `llm_provider_error` | Upstream outage (HTTP 500, 502, 503, Cloudflare 520, 522). |
| `memact_compacted` | Reactive compaction event showing pre- and post-compaction token counts. |
| `task_completed` | Orderly task finalization. |
| `task_interrupted` | User abort via SIGINT (Ctrl+C). |

### 3.2. Telemetry & Token Usage Tracking

The `act_completed` event records precise execution metrics:
```json
{
  "event": "act_completed",
  "pid": 41230,
  "act_index": 3,
  "timestamp": 1729281280,
  "duration_ms": 1420,
  "delta": {
    "usage": {
      "input_tokens": 1240,
      "output_tokens": 310,
      "reasoning_tokens": 180
    },
    "context_tokens": 8450
  }
}
```

These journal logs are directly consumed by the `session_diagnostics` tool to generate latency curves, token percentile distributions, and provider reliability metrics.

---

## 4. Content-Addressed Storage (CAS) & Rollback

To guard against destructive or unintended modifications, `mini-agent` integrates a Content-Addressed Storage (CAS) mechanism (`src/core/cas.zig`).

### 4.1. File Snapshotting

- Before any mutation tool (`file_write`, `file_edit`, `mini.write`, `mini.patch`) alters a file on disk, the current contents are hashed using SHA-256.
- The snapshot blob is stored under `~/.mini/cas/blobs/<sha256>`.
- The session journal links the file modification to the CAS hash.

### 4.2. Rollback Capability

If a task fails or the user requests an undo:
- The agent reads the pre-modification CAS hash from the journal.
- Restores the original content from the CAS blob store without relying on git state or version control working trees.
