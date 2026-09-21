# RFC-015: 3-Thread Architecture & Unified Watchdog Runtime

| Attribute | Value |
|---|---|
| RFC | 015 |
| Title | 3-Thread Architecture: REPL Chat, Watchdog Monitor, and Act Executor |
| Status | **Approved / In Progress** |
| Version | 1.0 |
| Dependencies | RFC-001 (Code-Centric), RFC-007 (REPL UI), RFC-010 (Procedural Graph), RFC-014 (Dead Code Audit) |
| Author | mini-agent |
| Date | 2026-09-19 |

---

## 1. Executive Summary

This RFC refactors mini-agent's execution model from a single-threaded sequential execution pattern into a decoupled **3-Thread Architecture**:

1. **Thread 1 (Main Thread - REPL Chat)**: Handles user interaction, line editing, slash commands, Ctrl+C signals, and real-time streaming output (`TurnRenderer`).
2. **Thread 2 (Watchdog Monitor)**: A dedicated supervisor thread that monitors the health and state of active acts on Thread 3:
   - **Act Observation**: Tracks what each act is currently doing (LLM call, CodeAct JS eval, tool execution).
   - **10s Act Tracking**: Emits status notifications every 10 seconds of active execution to keep the user informed.
   - **Timeout Intervention**: Detects hung or unresponsive acts exceeding `act_timeout_secs` (default 120s) and triggers execution interrupts.
   - **10-Act Recap & Checkpoint**: Every 10 acts completed (configurable), evaluates the trajectory across the last 10 acts for circular loops, duplicate calls, and hallucinations (similar to the rule checkpoint), injecting an advisory prompt into the agent's context.
3. **Thread 3 (Act Executor)**: A dedicated worker thread executing the act loop (backend LLM calls, QuickJS evaluation, tool execution) and continuously reporting heartbeat/status to Thread 2.

Simultaneously, this RFC strips out all redundant and obsolete features from `src/core/act_queue.zig` (such as 5 priority levels, priority queues, multi-worker pools, batch execution, subagent fork flags, and deprecated `std.Thread.Condition`), replacing them with a lean, thread-safe `ActCoordinator`.

---

## 2. Background & Motivation

### 2.1 The Problem with Single-Threaded Execution
In the previous architecture, the REPL loop in `ui/repl.zig` called `agent.processInput()` synchronously on the main thread:
- If a tool or network call stalled, the main thread was completely blocked, preventing clean signal handling or external supervision.
- Real-time status was limited to passive callbacks.
- Long-running sessions (such as the incident analyzed in the session hang RCA where PID 35537 hung for 178 minutes) lacked a persistent watchdog to monitor time elapsed and trigger recovery.

### 2.2 Redundant Code in `act_queue.zig`
An earlier design proposal (RFC-013) introduced an over-engineered queue with:
- 5 priority levels (`critical`, `high`, `normal`, `low`, `idle`)
- A priority heap (`std.PriorityQueue`)
- Multi-worker execution and batch processing
- Subagent isolation flags and callback pointers
- Obsolete Zig threading constructs (`std.Thread.Condition` which does not exist in Zig 0.16.0)

None of these were used in the interactive REPL or single-shot modes. They introduced compilation failures and maintenance burden.

---

## 3. Architecture Specification

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                             3-Thread Model                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌──────────────────────┐   Dispatch Turn    ┌───────────────────────────┐  │
│  │   Thread 1 (Main)    │ ─────────────────> │     Thread 3 (Worker)     │  │
│  │      REPL Chat       │ <───────────────── │       Act Executor        │  │
│  │                      │   Stream Events/   │                           │  │
│  │  - Line editor input │   Turn Complete    │  - LLM backend call       │  │
│  │  - Slash commands    │                    │  - CodeAct JS eval        │  │
│  │  - TurnRenderer UI   │                    │  - Tool execution         │  │
│  │  - Ctrl+C handling   │                    │  - State & Heartbeat pub  │  │
│  └──────────────────────┘                    └─────────────┬─────────────┘  │
│                                                            │                │
│                                              Shared State  │ Heartbeat /    │
│                                              & Trajectory  │ Status         │
│                                                            ▼                │
│                                              ┌───────────────────────────┐  │
│                                              │    Thread 2 (Watchdog)    │  │
│                                              │      Monitor Thread       │  │
│                                              │                           │  │
│                                              │  - Inspects active act    │  │
│                                              │  - 10s progress tracking  │  │
│                                              │  - Timeout intervention   │  │
│                                              │  - Recap & Loop     │  │
│                                              │    Checkpoint Advisory    │  │
│                                              └───────────────────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.1 Thread 1: REPL Chat (Main Thread)
- **Role**: User Interface and Interaction.
- **Components**:
  - `src/ui/editor.zig`: Byte-based line editor with ANSI escape and UTF-8 support.
  - `src/ui/repl.zig`: REPL command loop, slash command dispatcher (`/help`, `/model`, `/clear`, `/quit`).
  - `src/ui/chat_stream.zig`: `TurnRenderer` displaying streaming Markdown, reasoning tags, tool status spinners, and diff rendering.
- **Turn Lifecycle**:
  1. Reads user prompt.
  2. Dispatches prompt to `ActCoordinator`.
  3. Displays live streaming tokens and tool execution notifications sent from Thread 3.
  4. Catches `SIGINT` (Ctrl+C) and cleanly signals cancellation without crashing the REPL.
  5. Waits for turn completion and displays turn summary metrics.

### 3.2 Thread 2: Watchdog Monitor Thread
- **Role**: Act Health Supervisor, Timeout Guardian, and Trajectory Recap Analyzer.
- **Module**: `src/core/watchdog.zig`.
- **Key Behaviors**:
  1. **Ticking Cycle**: Runs continuously in the background, sleeping 500ms between evaluations.
  2. **Active Act Tracking (every 10s)**:
     - When Thread 3 is executing an act, Watchdog calculates elapsed time `now - act_start_ms`.
     - At every 10-second milestone (10s, 20s, 30s...), emits a tracking notification:
       `[watchdog] Act {d} in progress ({d}s): {s}`
  3. **Timeout Intervention**:
     - If an act exceeds `act_timeout_secs` (configurable, default 120s) without progress:
       - Sets `is_timed_out = true`.
       - Requests QuickJS VM interrupt via `quickjs_engine.requestInterrupt()`.
       - Sets signal interrupt flag to abort HTTP stream or child process.
       - Logs timeout intervention.
  4. **Recap & Checkpoint Advisory (default interval: 10 acts)**:
     - Monitored at act boundaries (`completed_acts % 3 == 0`).
     - Analyzes trajectory across the last recap_interval_acts (default: 10) acts:
       - Checks for duplicate tool invocations with identical parameters.
       - Checks for cycling tool loops (e.g. A ↔ B, A → B → C).
       - Checks for read-only exploration budget exhaustion (e.g. repeated grep/read without code modification).
     - Formulates an advisory message:
       ```
       [Watchdog Checkpoint & Recap (Act {d})]
       📍 Trajectory: {tool_1} → {tool_2} → {tool_3}
       🔍 Diagnosis: {Status}
       ⚠️ Advisory: Heuristic check. Assess if you have gathered sufficient context to proceed to modifying code or answering the user.
       ```
     - Enqueues the advisory for Thread 3 to inject into history prior to the next act.

### 3.3 Thread 3: Act Executor (Worker Thread)
- **Role**: Concrete Act Execution.
- **Execution Flow per Act**:
  1. **Pre-act**: Checks `ActCoordinator` for pending Watchdog recap advisory; injects into context if present.
  2. **LLM Invocation**: Calls `sendToBackend()`, publishing `.calling_llm` status and streaming chunks to Thread 1.
  3. **Action Execution**:
     - CodeAct JS: Updates status to `.executing_codeact`, runs QuickJS VM.
     - Tool calls: Updates status to `.executing_tool` (`tool_name`), runs tool.
  4. **Post-act**: Updates act completion counter, records tool record to trajectory history, transitions to `.idle`.

---

## 4. Coordination & Synchronization

### 4.1 `ActCoordinator` Data Structures

```zig
pub const ActStatus = enum {
    idle,
    preparing,
    calling_llm,
    executing_codeact,
    executing_tool,
    completed,
    failed,
};

pub const ActMonitorState = struct {
    act_id: usize = 0,
    status: ActStatus = .idle,
    action_desc: [128]u8 = [_]u8{0} ** 128,
    action_desc_len: usize = 0,
    act_start_ms: i64 = 0,
    last_heartbeat_ms: i64 = 0,
    last_reported_10s: u32 = 0,
    completed_acts: usize = 0,
    is_timed_out: bool = false,
};
```

### 4.2 Trajectory Record for Recap & Checkpoint

```zig
pub const ToolRecord = struct {
    tool_name: [32]u8,
    tool_name_len: usize,
    args_hash: u64,
    is_read_only: bool,
    timestamp_ms: i64,
};
```

### 4.3 Primitives
- Mutex: `std.Thread.Mutex` protects shared trajectory history and status descriptions.
- Signaling: `std.Thread.ResetEvent` handles turn dispatch and completion without CPU spinning.
- Fast status reads: Locked access guarantees safe reading across threads.

---

## 5. Configuration Options

| Config Key | Env Variable | Default | Description |
|---|---|---|---|
| `act_timeout_secs` | `MINI_ACT_TIMEOUT_SECS` | `120` | Max seconds before Watchdog aborts an act |
| `watchdog_interval_ms` | `MINI_WATCHDOG_INTERVAL_MS` | `500` | Watchdog polling frequency in ms |
| `watchdog_tracking_interval_s` | `MINI_WATCHDOG_TRACKING_S` | `10` | Frequency of act progress notifications |
| `watchdog_recap_interval` | `MINI_WATCHDOG_RECAP_INTERVAL` | `10` | Number of acts between trajectory recap checks |

---

## 6. Migration & Deprecation

1. `src/core/act_queue.zig` is rewritten:
   - Deprecated: `ActPriority`, `PriorityQueue`, `QueueWorker`, `std.Thread.Condition`.
   - New: `ActCoordinator`, `ActMonitorState`, `ToolRecord`.
2. `src/core/agent.zig`:
   - Fragmented `plan_watchdog_retries` is superseded by Watchdog's 10-act recap and checkpoint advisory.
3. Backward compatibility:
   - CLI flags `-e`, `--single`, `--acp`, and interactive REPL continue to function seamlessly.
