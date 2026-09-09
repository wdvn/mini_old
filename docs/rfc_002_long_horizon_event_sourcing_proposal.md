# PROPOSAL: EVENT-DRIVEN ACT ARCHITECTURE DESIGN FOR MINI
### Eliminating `MaxIterationsReached`, Supporting Long-Lived Tasks, State Rollback & Full-Spectrum LLM / Infrastructure Error Handling
> **Document**: RFC-002 (Revision 4 — Full Failure Spectrum & LLM Fault-Tolerance)  
> **Status**: Implemented / Production  
> **Target System**: `mini-agent` (`mini`)  
> **Reference**: `event_sourcing_long_horizon_agentic_ai.md`  
> **Author**: Core Team & AI Pair Programmer  
> **Date**: 2026-08-21  

---

## 1. EXECUTIVE SUMMARY

### 1.1. Core Problem
In `src/core/agent.zig`, the agent loop was constrained by:
```zig
const MAX_ITERATIONS = 30;
// ...
while (iteration < MAX_ITERATIONS) : (iteration += 1) {
    // 1. Write full history to temporary backup /tmp/mini_agent_backup_*.json
    // 2. Run executeStep
    // 3. On error: restore from backup file
}
return error.MaxIterationsReached;
```

#### Real-World Limitations:
1. **Inability to Run Long-Lived Tasks**: Complex tasks (repository refactoring, batch repairs, migrations, subagent orchestration) require hundreds or thousands of iterations but aborted prematurely at loop 30 (`MaxIterationsReached`).
2. **Primitive Rollback Mechanism**: Each step dumped complete JSON to `/tmp/mini_agent_backup.json`. It could only rollback a single step immediately prior upon an exception, incapable of rolling back to arbitrary historical states (Act $N$) or reverting file mutations (state deltas).
3. **Overlooking Realistic LLM Failure Modes**: LLMs inevitably hit 429 Rate Limits, 503 Overloaded servers, dropped SSE connections, malformed JSON Tool Calls, output truncations (`max_tokens`), or Context Window overflows.

---

### 1.2. Solution: Comprehensive Event-Driven Act Model
Simplifying the entire architecture around a single core tenet:

> **1 Loop = 1 Act**  
> Every loop of the agent is an **Act**. The full lifecycle of an Act is driven by an **Event-Driven** model serving **two singular purposes**:
> 1. **Supporting Long-Lived Tasks** (Completely eliminating `MAX_ITERATIONS`).
> 2. **Supporting State Rollback** (Precise historical rollback to arbitrary Acts, fully handling errors across tools, system runtime, and LLM models).

```
                            TASK STREAM
                                 │
                                 ▼
 ┌──────────────────────────────────────────────────────────────┐
 │                         ACT (Loop i)                         │
 │                                                              │
 │  1. ActStarted Event                                         │
 │       ↓                                                      │
 │  2. LLM Call (With defensive handling for 429/503/JSON parse)│
 │       ↓                                                      │
 │  3. Tool / JS Execution (Capturing File/History Deltas)      │
 │       ↓                                                      │
 │  4. Observation / State Delta Captured                       │
 │       ↓                                                      │
 │  5. ActCompleted Event (or ActFailed/Rollback Event)         │
 └──────────────────────────────┬───────────────────────────────┘
                                │
          ┌─────────────────────┴─────────────────────┐
          ▼                                           ▼
    [Purpose 1]                                 [Purpose 2]
 LONG-LIVED EXECUTION                         STATE ROLLBACK
 - Uncapped Act count                         - Rollback to arbitrary Act N
 - Continuous execution to completion         - Revert History & File Deltas
 - Append-only Event Stream                   - Resilient to LLM & System faults
```

---

## 2. THE FULL FAILURE SPECTRUM

No production system is immune to faults. Over long-horizon tasks spanning hundreds of Acts, failures manifest across 3 distinct tiers:

```
                            FAILURE TIERS IN PRACTICE
                                        │
     ┌──────────────────────────────────┼──────────────────────────────────┐
     ▼                                  ▼                                  ▼
[TIER 1: LLM MODEL ERRORS]       [TIER 2: TOOL/ENV ERRORS]          [TIER 3: SYSTEM/RUNTIME ERRORS]
- 429 Rate Limit / Quota         - Bash exit code != 0              - CodeAct Panic
- 503 Provider Overloaded        - Test failure / Compile error     - Disk I/O Snapshot failure
- Truncated / Malformed JSON     - File not found                   - Killed process
- Context Window Exceeded        - Patch conflict                   - Memory Corruption
```

---

### 2.1. Tier 1: Handling LLM Model / Provider Errors

| LLM Error Type | Root Cause | Event-Driven Mechanism & Recovery Strategy |
|:---|:---|:---|
| **Rate Limit (429) & Quota** | Burst call traffic or reaching OpenAI / Claude / Ollama rate limits | - Log Event `LLMCallThrottled`.<br>- **Exponential Backoff + Jitter** (retry after 2s, 4s, 8s... up to 5 attempts).<br>- Preserve active State without corrupting History. |
| **Provider Overloaded (500/502/503)** | AI server outage or network connection drop | - Log Event `LLMProviderError`.<br>- Retry with timeout-bounded backoff.<br>- If failing after $N$ attempts $\rightarrow$ Fallback to Backup Model (e.g. OpenAI $\to$ Claude or local Ollama) or `Yield` awaiting network restoration. |
| **Malformed Tool Call / Invalid JSON** | LLM outputs unmatched brackets, invalid schema, or non-existent tools | - Log Event `LLMOutputMalformed`.<br>- **Self-Correction Feedback**: Inject into context: `"[System Error: Invalid Tool Call JSON: {err}. Please output valid JSON format.]"`.<br>- LLM autonomously repairs syntax on the next turn (up to 3 retries). |
| **Output Truncation (Max Tokens Truncation)** | LLM response exceeds `max_tokens`, abruptly cutting JSON output | - Log Event `LLMOutputTruncated`.<br>- Instruct LLM to chunk responses or resume output from the breakpoint. |
| **Context Window Exceeded (400 Context Overflow)** | Trajectory exceeds model context window | - Log Event `ContextOverflowDetected`.<br>- **Emergency Context Compaction**: invoke `window.compactWith()` per **RFC-003**; guard: if compaction cannot yield sufficient budget → abort act, avoiding infinite retries. |

---

### 2.2. Tier 2: Tool & Environment Errors
- **Nature**: Non-zero bash exit code, failed test, patch mismatch.
- **Handling**: **DO NOT rollback state**. These represent valid Observations.
  - Log Event `ActCompleted { status: .tool_error }`.
  - Ingest error output into History so the LLM in the subsequent Act can inspect and self-correct (Forward Progress).

---

### 2.3. Tier 3: Runtime & System Errors (System Crash)
- **Nature**: Panic, disk I/O corruption, killed process.
- **Handling**: 
  - **Bounded Rollback (`MAX_RETRIES_PER_ACT = 3`)**: Rollback State to Act $i - 1$, log Event `ActRollbacked`, inject warning feedback.
  - If failing after 3 attempts $\rightarrow$ Abort immediately (halting infinite recursion) and emit `ActAborted`.

---

## 3. TWO PRIMARY OBJECTIVES

### Objective 1: Supporting Long-Lived Tasks (Removing `MaxIterationsReached`)

#### A. Eliminating Hard Limits
- Completely eradicate `const MAX_ITERATIONS = 30;` and `AgentError.MaxIterationsReached`.
- Execution loop operates as an Event-Driven Stream:
  - Agent continuously executes Acts ($1, 2, 3, \dots, 500, \dots, 1000+$).
  - Termination condition: LLM signals task completion (emitting no tool calls) or receives user / ACP client cancellation (`is_cancelled`).

#### B. Fault-Tolerant Resilience Over Long Horizons
- Built-in recovery from 429/503 errors and self-correcting malformed JSON ensures tasks do not fail prematurely from transient provider hiccups.

---

### Objective 2: Supporting State Rollback (Precise State Reversion)

#### A. Event-Driven State Rollback Mechanism
Every successful Act records an associated **`StateDelta`**:
```zig
pub const StateDelta = struct {
    act_id: usize,
    history_messages_added: usize,         // Count of messages appended in this Act
    file_snapshots: []const FileSnapshot,   // Snapshot of file content prior to mutation in this Act
};

pub const FileSnapshot = struct {
    path: []const u8,
    previous_content: ?[]const u8,         // null if newly created file
};
```

When rolling back to a target Act (e.g. from Act 45 back to Act 30 due to wrong direction or system faults):
1. **Rollback File State**: Traverse backwards from Act 45 to Act 31, restoring file contents from `FileSnapshot`.
2. **Rollback History State**: Truncate message entries in `History` back to the Act 30 boundary.
3. **Record Event**: Emit `StateRollbacked { from_act: 45, to_act: 30 }`.
4. **Resume Execution**: Agent continues from the clean state of Act 30 along a corrected trajectory.

---

## 4. CODE ARCHITECTURE IN `MINI`

### 4.1. Comprehensive Event Schema (`src/core/events.zig`)

```zig
const std = @import("std");

pub const ActEventType = enum {
    act_started,
    act_completed,
    act_failed,
    
    // LLM Model Events
    llm_call_started,
    llm_call_throttled,       // 429 Rate limit
    llm_provider_error,       // 500/502/503
    llm_output_malformed,     // JSON parse error / invalid tool schema
    llm_context_overflow,     // Context window overflow
    
    // Rollback Events
    rollback_requested,
    rollback_completed,
    task_completed,
};

pub const ActEvent = struct {
    act_id: usize,
    event_type: ActEventType,
    timestamp: i64,
    description: []const u8,
    delta: ?StateDelta = null,
};

pub const EventStore = struct {
    alloc: std.mem.Allocator,
    events: std.ArrayList(ActEvent),
    deltas: std.ArrayList(StateDelta),

    pub fn init(alloc: std.mem.Allocator) EventStore {
        return .{
            .alloc = alloc,
            .events = std.ArrayList(ActEvent).init(alloc),
            .deltas = std.ArrayList(StateDelta).init(alloc),
        };
    }

    pub fn recordEvent(self: *EventStore, act_id: usize, event_type: ActEventType, desc: []const u8) !void {
        try self.events.append(.{
            .act_id = act_id,
            .event_type = event_type,
            .timestamp = std.time.milliTimestamp(),
            .description = desc,
        });
    }

    pub fn recordActComplete(self: *EventStore, act_id: usize, delta: StateDelta) !void {
        try self.deltas.append(delta);
        try self.events.append(.{
            .act_id = act_id,
            .event_type = .act_completed,
            .timestamp = std.time.milliTimestamp(),
            .description = "Completed Act",
            .delta = delta,
        });
    }

    /// Rollback entire state to conclusion boundary of target_act_id
    pub fn rollbackToAct(self: *EventStore, target_act_id: usize, history: *anyopaque) !void {
        while (self.deltas.items.len > 0) {
            const last_delta = self.deltas.items[self.deltas.items.len - 1];
            if (last_delta.act_id <= target_act_id) break;

            // Revert files modified in this delta
            for (last_delta.file_snapshots) |snap| {
                if (snap.previous_content) |content| {
                    try std.fs.cwd().writeFile(.{ .sub_path = snap.path, .data = content });
                } else {
                    std.fs.cwd().deleteFile(snap.path) catch {};
                }
            }

            _ = self.deltas.pop();
        }

        try self.events.append(.{
            .act_id = target_act_id,
            .event_type = .rollback_completed,
            .timestamp = std.time.milliTimestamp(),
            .description = "State rolled back to target Act boundary",
        });
    }

    pub fn deinit(self: *EventStore) void {
        self.events.deinit();
        self.deltas.deinit();
    }
};
```

---

### 4.2. Enhanced Agent Loop Handling LLM Faults & Crashes (`src/core/agent.zig`)

```zig
pub fn processInput(
    self: *AgentLoop,
    user_text: []const u8,
    text_cb: ?TextCallback,
    think_cb: ?ThinkCallback,
) !void {
    try self.history.addUser(user_text);
    const tool_defs = tools_mod.getRelevantDefinitions(self.alloc, user_text);

    var act_id: usize = 0;
    const MAX_SYSTEM_RETRIES_PER_ACT = 3;

    // EVENT-DRIVEN STREAM WITHOUT ARBITRARY ACT LIMITS (LONG-LIVED TASK)
    while (true) : (act_id += 1) {
        var act_try_count: usize = 0;

        // LOCAL DEFENSIVE RETRY LOOP (BOUNDED RETRY PER ACT)
        while (act_try_count <= MAX_SYSTEM_RETRIES_PER_ACT) : (act_try_count += 1) {
            try self.events.recordEvent(act_id, .act_started, "Started Act");

            var act_delta = StateDelta{
                .act_id = act_id,
                .history_messages_added = 0,
                .file_snapshots = &.{},
            };

            // Execute Act (Includes internal 429/503/JSON recovery within executeAct)
            const step_result = self.executeAct(
                act_id, 
                tool_defs, 
                text_cb, 
                think_cb, 
                &act_delta
            ) catch |err| {
                switch (err) {
                    // CASE 1: Malformed JSON Output -> Inject feedback for model self-correction
                    error.LLMMalformedJsonOutput, error.LLMInvalidToolArguments => {
                        try self.events.recordEvent(act_id, .llm_output_malformed, "LLM emitted malformed JSON syntax");
                        try self.history.addSystemErrorObservation("Invalid tool call JSON format. Please output valid JSON syntax.");
                        continue;
                    },

                    // CASE 2: Rate Limit or Server Overloaded -> Exponential Backoff
                    error.LLMRateLimitExceeded, error.LLMProviderUnavailable => {
                        try self.events.recordEvent(act_id, .llm_call_throttled, "LLM rate limited or 503 unavailable");
                        const backoff_ms: u64 = (@as(u64, 1) << @intCast(act_try_count)) * 1000;
                        std.time.sleep(backoff_ms * std.time.ns_per_ms);
                        continue;
                    },

                    // CASE 3: Context Overflow -> Emergency Context Compaction
                    error.LLMContextWindowExceeded => {
                        try self.events.recordEvent(act_id, .llm_context_overflow, "Context window overflow");
                        try self.performEmergencyCompaction();
                        continue;
                    },

                    // CASE 4: Runtime Crash / I/O Panic
                    else => {
                        if (act_try_count >= MAX_SYSTEM_RETRIES_PER_ACT) {
                            main.stderrPrint("\n[agent] Act {d} failed {d} consecutive times. Aborting: {s}\n", .{ act_id, MAX_SYSTEM_RETRIES_PER_ACT + 1, @errorName(err) });
                            if (act_id > 0) {
                                self.events.rollbackToAct(act_id - 1, &self.history) catch {};
                            }
                            return err;
                        }

                        main.stderrPrint("\n[agent] Act {d} encountered failure ({s}). Rolling back and retrying (attempt {d}/{d})...\n", .{ act_id, @errorName(err), act_try_count + 1, MAX_SYSTEM_RETRIES_PER_ACT });
                        if (act_id > 0) {
                            try self.events.rollbackToAct(act_id - 1, &self.history);
                        }
                        try self.history.addSystemErrorObservation(@errorName(err));
                        continue;
                    },
                }
            };

            // Record cleanly completed Act
            try self.events.recordActComplete(act_id, act_delta);

            // Verify task completion criteria
            if (step_result == .exit_loop) {
                return;
            }

            break; // Exit local retry loop, advance to next Act
        }
    }
}
```

---

## 5. COMPARATIVE SUMMARY

| Metric | Previous State (`MAX_ITERATIONS = 30`) | Modern Event-Driven Act Architecture |
|:---|:---|:---|
| **Loop Paradigm** | Rigid iteration counting ($0 \to 30$) | **1 Loop = 1 Act**, driven via Event Streams |
| **Long-Lived Task Support** | ❌ Aborts at loop 30 (`MaxIterationsReached`) | ✅ **Unbounded**, executes sustainably until task completion |
| **State Rollback Mechanism** | ❌ Temporary JSON overwrite, 1-step recovery only | ✅ **Precise Rollback** of History and File Deltas to arbitrary Act $N$ |
| **LLM Fault Tolerance** | ❌ 429/503/Malformed JSON crashes agent | ✅ **Self-Healing**: 429/503 Backoff, JSON Self-Correction, Emergency Compaction |
| **Safety Guardrails** | Prone to infinite loops or data loss | ✅ **Anti-Recursion Protection**: Error classification, `MAX_RETRIES_PER_ACT = 3`, Feedback injection |
| **Auditability & Observability** | Low, trajectory lost post-crash | High, full trajectory recorded as Event chains |

---

## 6. ACTION PLAN

1. **Step 1**: Remove `const MAX_ITERATIONS = 30;` and `AgentError.MaxIterationsReached` in [`src/core/agent.zig`](file:///mnt/hdd/projects/persional/mini/src/core/agent.zig).
2. **Step 2**: Create [`src/core/events.zig`](file:///mnt/hdd/projects/persional/mini/src/core/events.zig) implementing `ActEvent`, `StateDelta`, `FileSnapshot`, `EventStore`, and LLM fault events.
3. **Step 3**: Capture `FileSnapshot` records when file write tools (`file_edit`, `file_write`, `patch`) execute during Acts.
4. **Step 4**: Implement LLM defensive mechanisms (Exponential Backoff for 429/503, Self-Correction for Malformed JSON, Emergency Compaction for Context Overflow).
5. **Step 5**: Implement safe State Rollback and anti-recursion bounds (`MAX_SYSTEM_RETRIES_PER_ACT = 3`).
6. **Step 6**: Update [`src/acp/server.zig`](file:///mnt/hdd/projects/persional/mini/src/acp/server.zig) to align with standardized completion states.

---

## 7. TECHNICAL REVIEW — COUNTER ARGUMENTS

> Comparing proposal claims against active code in `src/core/agent.zig` and `src/core/history.zig`.
> **Verdict: Directionally sound, architectural scoping flaws.** The 3-tier failure classification and "tool error = observation" philosophy are strong. However, the 3 core claims — (1) durable auditability, (2) precise rollback, and (3) safety upon removing MAX_ITERATIONS — **were not met by the initial revision**, and early pseudocode contained logical bugs.

### 7.1. "Event Sourcing" Terminology Discrepancy — Lacking Persistence
Initial `EventStore` implementations relied purely on `std.ArrayList` in-memory. Process crashes wiped events and deltas.

- Comparison table (Section 5) claimed: *"High, full trajectory recorded as Event chains"* — inaccurate without disk persistence.
- True event sourcing requires append-only WAL logs with fsync per act, and replay capabilities to reconstruct state.
- **Requirement**: Event logs must be disk WALs (append-only JSONL + fsync per Act), replayable on restart to support genuine long-horizon durability.

### 7.2. History Rollback Implementation Gaps
Initial drafts specified:
```zig
pub fn rollbackToAct(self: *EventStore, target_act_id: usize, history: *anyopaque) !void
```
- The `history: *anyopaque` parameter was unused, only reverting file snapshots without truncating message arrays.
- `StateDelta.history_messages_added` was tracked without invocation to resize history.
- Corrected in production by explicitly implementing history truncation and boundary checkpoints.

### 7.3. Interaction: Rollback vs Compaction
`History.compactWithSummary()` previously deleted older messages. In long tasks, compaction precedes rollbacks.

> **Update**: RFC-003 resolved this — compacted messages transition to the **ARCHIVED** tier written to append-only JSONL on disk. The archived log provides the undo journal for rollback: paired with checkpoints marking "last compactable points", rollbacks are bounded to the nearest checkpoint. `window.compactWith()` from RFC-003 supersedes ad-hoc emergency compaction.

### 7.4. FileSnapshot: Memory Footprint & Scope
- **RAM Overhead**: Storing full string copies in memory scales at O(N_acts × file_size). Production uses Content-Addressable Storage (CAS) on disk via sha256 hashes (`.mini/cas/`), storing identical files once and keeping RAM footprint minimal.
- **Scope**: Extended to cover both native tools and CodeAct `mini.write` / `mini.patch`.

### 7.5. Replacing MAX_ITERATIONS with Explicit Budgets
Uncapped execution requires defensive guardrails against behavioral loops:
- Cumulative token and wall-clock budgets.
- Loop detection: hashing normalized tool invocations to flag repetitive ping-pong behavior.
- Soft act limits prompting user confirmation during interactive sessions.

### 7.6. Corrected Pseudocode Logic Bugs
- **Shift precedence**: Corrected Zig operator precedence `(@as(u64, 1) << @intCast(n)) * 1000` avoiding shift overflows.
- **ContextOverflow loops**: Bounded compaction retries preventing infinite loops on single oversized tool outputs.
- **Orphan tool_use handling**: Ensuring crashed steps do not leave unmatched `tool_use` blocks that fail Claude message sequence validations.

### 7.7. Preserved Core Strengths
1. 3-tier failure classification (LLM / Tool / System).
2. Tool errors treated as Observations rather than state rollbacks.
3. Self-correction feedback injection for malformed tool outputs.
4. Replacing rigid iteration limits with dynamic budget checkpoints.
