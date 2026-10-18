# Memory, Context Compaction & Structured Planning

## 1. MemAct Long-Term Memory System

The **MemAct Memory System** equips `mini-agent` with persistent, project-localized memory that survives across independent process runs without requiring an external vector database.

### 1.1. Storage & Data Layout

MemAct stores all knowledge in an event-sourced, append-only JSONL log at:
```
~/.mini/memory/<project_hash>/memory.jsonl
```
Where `<project_hash>` is the SHA-256 hash of the canonical project workspace root directory.

Each JSON record conforms to the following schema:
```json
{
  "id": "mem_1729281234_abc",
  "type": "semantic",
  "content": "Project uses Zig 0.16.0 with standard library only; QuickJS is statically linked.",
  "keywords": ["zig", "quickjs", "build", "dependencies"],
  "created_at": 1729281234,
  "accessed_at": 1729281234,
  "access_count": 1,
  "superseded_by": null
}
```

### 1.2. Memory Categorization

MemAct organizes memories into three functional categories:
- **`semantic`**: Permanent architectural facts, invariants, design decisions, and external constraints.
- **`episodic`**: Records of past bug investigations, resolved incidents, and testing outcomes.
- **`project_state`**: Snapshots of ongoing migrations, feature branches, and temporary configuration states.

### 1.3. Retrieval Pipeline

1. **Query Formulation**: During context preparation, the agent extracts search terms from the latest user prompt.
2. **Dual-Path BM25 & Keyword Retrieval**:
   - Matches terms against an in-memory BM25 index built from the active memory log.
   - Evaluates ASCII case-insensitive keyword overlap.
   - Filters out entries marked as superseded.
3. **Budget Ranking & Injection**:
   - Ranks candidates by BM25 score and recency.
   - Takes up to `MINI_MEMACT_TOP_K` (default: 8) items within the token budget `MINI_MEMACT_MEMORY_BUDGET` (default: 2000 tokens).
   - Injects the resulting block into the system context.

---

## 2. Reactive Context Compaction

Large tasks that span many turns can exhaust the model's context window. Rather than proactively compressing context on every turn, `mini-agent` uses **Reactive Compaction**.

### 2.1. The Reactive Compaction Mechanism

```
[Normal Agent Loop]
       │
       ▼
[Backend returns HTTP 400 Context Length Overflow]
       │
       ▼
┌────────────────────────────────────────────────────────┐
│ Reactive Compactor                                     │
│ 1. Preserves Initial Prompt at index 0                 │
│ 2. Extracts structured summary of acts 1..(N - K)      │
│ 3. Collapses intermediate turns into single summary    │
│ 4. Retains last K recent interaction turns             │
│ 5. Re-injects active plan & task state                 │
└──────────────────────┬─────────────────────────────────┘
                       │
                       ▼
[Automatically Re-Dispatches Request to Backend]
```

### 2.2. Invariants Preserved
- **Root Intent Preservation**: Message index 0 (the original user prompt that defined the task) is never dropped or summarized.
- **Recent Turn Fidelity**: The most recent turns ($K$, typically 4–6 messages) are preserved verbatim so the model retains fine-grained observation state.
- **Automatic Continuation**: The user experiences no interruption; the compaction and re-dispatch occur transparently within the turn.

---

## 3. Procedural Knowledge Graph (PGraph)

While MemAct handles declarative facts, the **Procedural Graph Engine** captures sequential operational knowledge: how tools, skills, and states transition during real-world tasks.

### 3.1. Architecture & Compact Representations

- **Event-Sourced Graph Log**: Stored at `~/.mini/memory/<project_hash>/pgraph.jsonl`.
- **Dual Representation**:
  - **Mutable Graph (`src/lib/graph/storage.zig`)**: Dynamic node and edge storage used during graph mutation and event replay.
  - **CSR/CSC Arrays (`src/lib/graph/csr.zig`)**: Compiled into **Compressed Sparse Row** and **Compressed Sparse Column** views for zero-allocation, sub-millisecond traversal.

For in-depth algorithmic and data structure specifications, refer to [Graph Engine Specification](core/graph.md).

### 3.2. Online Guidance Injection

During each execution turn:
1. The engine identifies active tool nodes from the recent trajectory window ($W=3$).
2. Extracts the **2-hop neighborhood** ($H=2$) via breadth-first search on the CSR topology.
3. Formats connected guidance notes and common pitfall warnings into an ephemeral prompt block.
4. Alerts the model to recommended next steps without constraining its decision space.

### 3.3. Automated Transition Learning

When `MINI_MEMACT_PG_AUTO_POPULATE=1`:
- The engine tracks pairwise tool transitions across acts.
- If a specific tool sequence (e.g., `grep` $\to$ `file_read` $\to$ `file_edit`) occurs **3 or more times**, a directed edge is automatically committed to the procedural graph with an incremented weight.

---

## 4. Structured Planning Engine (RFC-019)

Complex tasks involving multiple files or multi-step refactoring require disciplined forward planning. `mini-agent` features a built-in Directed Acyclic Graph (DAG) planning system.

```
       ┌────────────────────────┐
       │   User Complex Prompt  │
       └───────────┬────────────┘
                   │
                   ▼
       ┌────────────────────────┐
       │   Plan Parser          │
       │ (JSON DAG / Markdown)  │
       └───────────┬────────────┘
                   │
                   ▼
       ┌────────────────────────┐      CAS Persistence
       │       Plan Store       │ ───────────────────────► ~/.mini/plans/
       └───────────┬────────────┘
                   │
                   ▼
       ┌────────────────────────┐
       │     Plan Executor      │ ◄──── Execution Lifecycle
       └───────────┬────────────┘
                   │
                   ▼
       ┌────────────────────────┐
       │      Plan Monitor      │ ─────► Soft Drift Detection & Warnings
       └────────────────────────┘
```

### 4.1. Dual-Format Plan Parser (`core/plan/parser.zig`)

The plan parser automatically detects and parses plans in two formats:
1. **Markdown Checklist Format**:
   ```markdown
   - [x] Step 1: Analyze directory layout
   - [ ] Step 2: Implement core algorithm <!-- id: step_2 -->
   - [ ] Step 3: Run unit tests <!-- id: step_3, deps: [step_2] -->
   ```
2. **JSON DAG Format**:
   ```json
   {
     "title": "Module Refactoring",
     "steps": [
       { "id": "1", "title": "Audit dependencies", "status": "completed", "deps": [] },
       { "id": "2", "title": "Refactor interface", "status": "active", "deps": ["1"] },
       { "id": "3", "title": "Run test suite", "status": "pending", "deps": ["2"] }
     ]
   }
   ```

### 4.2. Plan Store & Optimistic Concurrency (`core/plan/store.zig`)

- Plans are persisted to disk under `~/.mini/plans/<plan_id>.json`.
- Uses Content-Addressed Storage (CAS) hashes to detect concurrent mutations across turns or between subagents.

### 4.3. Plan Monitor & Soft Drift Enforcement (`core/plan/monitor.zig`)

- Monitors executed actions against the active plan.
- If the agent performs actions that diverge from the dependencies of the active step, the monitor logs an advisory message in stderr and guides the agent back to the structured plan.
- Optional gates (`MINI_PLAN_APPROVAL_GATE` and `MINI_PLAN_VERIFICATION_GATE`) enforce explicit verification before advancing step state.
