# Agent Loop Execution Architecture

This document details and visualizes the complete execution flow of **1 Agent Loop (1 Turn / Multi-Act Loop)** in `mini-agent` — from receiving a User Prompt, multi-tier resolution, single tool execution to the **Hierarchical / Recursive Sub-agent Execution Tree**.

---

## 1. End-to-End Execution Flowchart

```mermaid
flowchart TD
    Start(["User Input (REPL / CLI -e)"]) --> InitTurn["Initialize new Turn: Reset Metrics & Allocator"]
    InitTurn --> AddUserHist["Add User Message to History"]
    AddUserHist --> EnterLoop

    subgraph ActLoop ["ACT LOOP (while true : act_id += 1)"]
        direction TB
        EnterLoop(["Start Act"]) --> CheckSignal{"User pressed Ctrl+C?"}
        
        CheckSignal -- "YES" --> SigInt["Write journal: task_interrupted -> Stop Turn"]
        CheckSignal -- "NO" --> JournalStart["Write Journal: act_started"]
        
        JournalStart --> Sanitize["Bidirectional History Sanitization: ensureOpenAICompatible / ensureClaudeCompatible"]
        Sanitize --> FilterTools["Filter Tool Definitions by execution_mode (codeact / tools / auto)"]
        FilterTools --> SendBackend["Send Request to AI Backend (SSE Streaming / Dual-Protocol Auto-Negotiation)"]
        
        SendBackend --> StreamUI["Stream UI Realtime: Reasoning/Thinking, Markdown Text, Inplace Retry & Action Cards"]
        StreamUI --> AddAssistantHist["Add Assistant Response to History"]
        AddAssistantHist --> Classify{"Classify Response & Stop Reason"}
        
        %% Backend Error & Recovery Branches
        Classify -- "Error 429 RateLimit / 5xx / 520, 522" --> RetryBackoff["Write llm_call_throttled -> Inplace Terminal Overwrite (\x1b[1A\x1b[2K\r) -> Exponential Backoff -> Retry Act"]
        RetryBackoff --> SendBackend
        
        Classify -- "Error 400 Context Overflow" --> ForceCompact["Write llm_context_overflow -> MemAct Reactive Compaction (drop-all + summary at index 1, preserve index 0) -> Retry Act"]
        ForceCompact --> SendBackend
        
        Classify -- "Error Auth / Max Retries" --> AbortAct["Write act_failed -> Rollback CAS Snapshot -> Stop Turn"]
        
        %% Tool Execution Branches
        Classify -- "stop_reason = tool_use (Leaf Tool)" --> ExecLeaf["Execute Leaf Tool (bash, grep, file_read, session_diag...)"]
        Classify -- "stop_reason = tool_use (Sub-Agent Tool)" --> ExecSubTree["HIERARCHICAL SPAWN: Spawn Child Process (invoke_subagent / batch)"]
        Classify -- "stop_reason = end_turn + Has JS block" --> ExecJS["Execute JS in embedded QuickJS VM (mini.* object)"]
        
        ExecLeaf --> SnapshotCAS["Create CAS Snapshot for modified files"]
        ExecSubTree --> CollectSubOut["Collect results from Sub-Agent pipe"]
        ExecJS --> AddJSResult["Add CodeAct stdout / return value / error to History"]
        
        SnapshotCAS --> AddToolResult["Add tool_result to History"]
        CollectSubOut --> AddToolResult
        AddJSResult --> JournalActDone["Write Journal: act_completed & Log Act Replay JSON"]
        AddToolResult --> JournalActDone
        
        %% Turn Completion Branch
        Classify -- "stop_reason = end_turn + NO tool/JS call" --> TaskCompleted["Write Journal: act_completed & task_completed -> Exit Loop"]
        
        JournalActDone --> NextAct(["Advance to next Act: act_id += 1"])
        NextAct --> EnterLoop
    end

    TaskCompleted --> CheckExecMode{"Execution Mode?"}
    CheckExecMode -- "Interactive REPL (mini)" --> WaitStdin["Print prompt 'You > ' and wait for keyboard input: read(stdin) (State: idle_waiting_input)"]
    CheckExecMode -- "Single-shot / Subagent (mini -e)" --> ExitProcess(["exit 0 - Terminate process (State: completed)"])
```

---

## 2. Single-Level Sequence Diagram

```mermaid
sequenceDiagram
    autonumber
    actor User as User
    participant REPL as UI / REPL (ui/repl.zig & chat_stream.zig)
    participant Agent as AgentLoop (src/core/agent.zig)
    participant Hist as History & MemAct (core/history.zig & memact/)
    participant Backend as AI Backend (OpenAI / Claude / Ollama)
    participant Tool as Tool Registry / CodeAct VM (registry.zig / QuickJS)
    participant Jour as ActJournal & CAS (core/journal.zig & cas.zig)
    participant ActLog as Act Logger (core/act_logger.zig)

    User->>REPL: Input prompt (e.g. "Check system status and run tests")
    REPL->>Agent: processInput(user_text, text_cb, think_cb)
    Agent->>Hist: addUser(user_text)
    Note over Agent,Hist: MemAct reactive compaction (only triggered on context length error)

    rect rgb(240, 248, 255)
        Note over Agent,ActLog: ACT 1 (Investigation via Native Tool Calling)
        Agent->>Jour: recordEvent(act_id=1, "act_started")
        Agent->>Hist: ensureOpenAICompatible() (Bidirectional sanitization of orphan tool blocks)
        Agent->>Backend: sendMessage(stream=true, system_prompt, history, tools)
        Backend-->>REPL: SSE chunks: reasoning / thinking -> streamThinking()
        Backend-->>REPL: SSE chunks: tool_call -> startTool("session_diagnostics")
        REPL-->>User: Render realtime Thinking & Tool Header (⚡ session_diagnostics list)
        Backend-->>Agent: Response (stop_reason: .tool_use, tool_calls: [session_diagnostics])
        Agent->>Hist: addAssistantResponse(&response)
        
        Agent->>Tool: executeTool("session_diagnostics", "{\"operation\":\"list\"}")
        Tool-->>Agent: Tool output string (Sessions status table)
        Agent->>REPL: finishTool("session_diagnostics", output) -> Preview up to 3 lines
        REPL-->>User: Render "✓ Completed (5ms)" + output preview
        Agent->>Hist: addToolResult(call_id, output)
        Agent->>Jour: recordEvent(act_id=1, "act_completed")
        Agent->>ActLog: logAct(act_1.json)
    end

    rect rgb(255, 250, 240)
        Note over Agent,ActLog: ACT 2 (Execute CodeAct JS in QuickJS VM)
        Agent->>Jour: recordEvent(act_id=2, "act_started")
        Agent->>Backend: sendMessage(stream=true, history)
        Backend-->>REPL: SSE chunks: JS Code Block (```javascript mini.sh(...)```)
        Backend-->>Agent: Response (stop_reason: .end_turn, contains JS code block)
        Agent->>Hist: addAssistantResponse(&response)
        
        Agent->>Tool: engine.eval(js_code) -> QuickJS VM (mini.sh, CAS Snapshot)
        Tool-->>Agent: Execution output (stdout, return value)
        Agent->>REPL: finishTool("codeact", stdout) -> Rolling preview 3 lines
        Agent->>Hist: addUser("[CodeAct Output]: " + stdout)
        Agent->>Jour: recordEvent(act_id=2, "act_completed", snapshots)
        Agent->>ActLog: logAct(act_2.json)
    end

    rect rgb(240, 255, 240)
        Note over Agent,ActLog: ACT 3 (Final Answer & Turn Completion)
        Agent->>Jour: recordEvent(act_id=3, "act_started")
        Agent->>Backend: sendMessage(stream=true, history)
        Backend-->>REPL: SSE chunks: Markdown Text -> streamTextResponse()
        REPL-->>User: Render Markdown Streaming (Syntax Highlighted)
        Backend-->>Agent: Response (stop_reason: .end_turn, content: [text], NO tool/JS call)
        Agent->>Hist: addAssistantResponse(&response)
        Agent->>Jour: recordEvent(act_id=3, "act_completed")
        Agent->>Jour: recordEvent(act_id=3, "task_completed")
        Agent->>ActLog: logAct(act_3.json)
    end

    alt Interactive REPL mode (mini)
        Agent-->>REPL: Complete Turn (Return to REPL loop)
        REPL->>User: Display prompt "You > " and wait for stdin (read(stdin) - State: idle_waiting_input)
    else Subagent / Single-shot mode (mini -e)
        Agent-->>REPL: Exit process
        REPL->>User: exit(0) (State: completed)
    end
```

---

## 3. Recursive / Inductive Sub-Agent Tree

A tool such as `invoke_subagent` or `batch_invoke_subagents` **is not a leaf tool**, but an **intermediate Subtree Generator node**. Each subagent spawns an independent process and executes a complete recursive `AgentLoop`.

### A. Execution Tree

```mermaid
graph TD
    User([User Prompt]) --> RootAgent["Parent AgentLoop (PID: 1000, Depth: 0)"]
    
    RootAgent -->|Act 1: tool_use| Sub1["Sub-agent 1 (PID: 1001, Depth: 1)\nTask: 'Investigate log and trace code'"]
    RootAgent -->|Act 2: tool_use| Sub2["Sub-agent 2 (PID: 1002, Depth: 1)\nTask: 'Run benchmark & refactor'"]
    RootAgent -->|Act 3: text| FinalResponse["Final Synthesized Answer to User"]

    %% Subagent 1 Subtree
    Sub1 -->|Sub-Act 1| Leaf1["Leaf Tool: grep 'error' src/"]
    Sub1 -->|Sub-Act 2| Leaf2["Leaf Tool: file_read src/core/agent.zig"]
    Sub1 -->|Sub-Act 3| SubReport1["Sub-agent 1 Result (stdout blob)"]

    %% Subagent 2 Subtree
    Sub2 -->|Sub-Act 1| Leaf3["Leaf Tool: bash 'zig build test'"]
    Sub2 -->|Sub-Act 2| Leaf4["CodeAct QuickJS: mini.patch(...)"]
    Sub2 -->|Sub-Act 3| SubReport2["Sub-agent 2 Result (stdout blob)"]

    SubReport1 -->|Pipe stdout| RootAgent
    SubReport2 -->|Pipe stdout| RootAgent
```

---

### B. Inductive Recursive Sequence Diagram

```mermaid
sequenceDiagram
    autonumber
    actor User as User
    participant ParentREPL as Parent UI / REPL (Depth 0)
    participant ParentAgent as Parent AgentLoop (Depth 0, PID 1000)
    participant SubTool as Subagent Tool Wrapper (src/tools/subagent.zig)
    participant ChildAgent as Child AgentLoop (Depth 1, PID 1001)
    participant ChildBackend as Child AI Backend
    participant LeafTools as Leaf Tools (grep, bash, file_write)

    User->>ParentREPL: Complex prompt (e.g. "Investigate crash and fix code")
    ParentREPL->>ParentAgent: processInput()
    
    rect rgb(240, 248, 255)
        Note over ParentAgent,SubTool: PARENT ACT 1 (Delegate sub-task)
        ParentAgent->>ParentAgent: Backend calls tool `invoke_subagent`
        ParentAgent->>ParentREPL: startTool("invoke_subagent", "task: 'Trace bug'")
        ParentREPL-->>User: Render: "⚡ invoke_subagent (Task: Trace bug)"
        ParentAgent->>SubTool: executeTool("invoke_subagent", task_json)
        
        SubTool->>SubTool: Check Guard: MINI_SUBAGENT_DEPTH (0 < 2)
        SubTool->>ChildAgent: spawn("mini", ["-e", task], env: {DEPTH: 1, QUIET: 1})
    end

    rect rgb(255, 250, 240)
        Note over ChildAgent,LeafTools: CHILD AGENT LOOP (Depth 1)
        Note right of ChildAgent: Initialize History, Journal_1001.jsonl, separate CAS
        ChildAgent->>ChildBackend: sendMessage(history)
        ChildBackend-->>ChildAgent: Response { stop_reason: .tool_use, tool: "grep" }
        ChildAgent->>LeafTools: executeTool("grep", "query: 'panic'")
        LeafTools-->>ChildAgent: "Found in line 42"
        
        ChildAgent->>ChildBackend: sendMessage(history + tool_result)
        ChildBackend-->>ChildAgent: Response { stop_reason: .tool_use, tool: "bash" }
        ChildAgent->>LeafTools: executeTool("bash", "zig build test")
        LeafTools-->>ChildAgent: "All tests pass"
        
        ChildAgent->>ChildBackend: sendMessage(history + tool_result)
        ChildBackend-->>ChildAgent: Response { stop_reason: .end_turn, content: "Report: Bug at line 42 has been patched." }
        ChildAgent-->>SubTool: Output report to stdout & exit(0)
    end

    rect rgb(240, 248, 255)
        Note over ParentAgent,SubTool: PARENT ACT 1 (Receive inductive result & continue)
        SubTool->>SubTool: Read complete stdout pipe from ChildAgent
        SubTool-->>ParentAgent: Return stdout blob ("Report: Bug at line 42...")
        ParentAgent->>ParentREPL: finishTool("invoke_subagent", child_stdout)
        ParentREPL-->>User: Render: "✓ Completed (1.8s)" + preview child output
        ParentAgent->>ParentAgent: Append `tool_result` to Parent History
    end

    rect rgb(240, 255, 240)
        Note over ParentAgent,ParentREPL: PARENT ACT 2 (Synthesize final response)
        ParentAgent->>ParentREPL: streamTextResponse()
        ParentREPL-->>User: Render Markdown Streaming: "I delegated investigation to a subagent and completed the fix..."
    end
```

---

## 4. Stream Aggregation & Isolation

| Aspect | Parent Process (Depth $d$) | Child Process (Subagent - Depth $d+1$) |
|---|---|---|
| **PID & Process** | Runs interactive REPL or primary CLI. | Independent subprocess spawned via `std.process.spawn`. |
| **History & Context** | Manages main user conversation. | Local context serving assigned `task` only. |
| **Event Sourcing Journal** | `~/.mini/sessions/journal_<parent_pid>.jsonl` | Independent `~/.mini/sessions/journal_<child_pid>.jsonl`. |
| **Telemetry & State** | `executing_act` $\to$ `idle_waiting_input`. | `executing_act` $\to$ `completed` (exit 0). |
| **Stream UI & Output** | Renders directly to Terminal (Thinking, Tools, Markdown). | `stdout`/`stderr` redirected to Pipe; startup banner suppressed (`QUIET=1`). Final output rolled up into Parent `tool_result`. |
| **Depth Guard** | Verifies `depth < max_depth` (default $\le 2$). | Automatically increments `MINI_SUBAGENT_DEPTH = d + 1`. Prevents recursive fork bomb. |

---

## 5. Loop States & Telemetry Meanings

When inspecting processes via `session_diagnostics` or journal file `~/.mini/sessions/journal_<pid>.jsonl`, process states are precisely defined as:

| State | Last Event | OS State | Operational Meaning |
|---|---|---|---|
| `idle_waiting_input` | `task_completed` | `ALIVE` (`anon_pipe_read`) | **REPL process is idle**, turn finished, waiting for user keyboard input at `You > ` prompt. |
| `executing_act` | `act_started` | `ALIVE` | Sending request to LLM backend (waiting for stream) or executing Tool / Sub-agent. |
| `between_acts` | `act_completed` | `ALIVE` | Just completed an Act, transitioning context to next Act. |
| `completed` | `task_completed` | `DEAD` (Exit 0) | Subagent or single-shot `-e` process completed all work and exited cleanly. |
| `crashed` / `failed`| `act_failed` | `DEAD` / `ALIVE` | Encountered terminal error (auth failure, network crash, unrecoverable syntax error). |

---

## 6. Resilience & Safety Guards

1. **Subagent Depth Guard (`src/tools/subagent.zig`)**:
   - Verifies `MINI_SUBAGENT_DEPTH <= MINI_MAX_SUBAGENT_DEPTH` (default = 2).
   - Prevents infinite recursion or fork bombs when a subagent calls itself.
2. **CAS State Snapshot & Rollback (`src/core/snapshot.zig` + `cas.zig`)**:
   - Before overwriting files (`file_write`, `file_edit`, `mini.write`, `mini.patch`), previous contents are SHA-256 hashed and stored in Content-Addressed Storage (`~/.mini/cas/`).
   - If an Act fails terminally or the user requests rollback, files are restored to their exact original state.
3. **MemAct Compaction (`src/core/history.zig`)**:
   - Automatically compacts context when token threshold is exceeded without losing initial System Prompt or User Intent.
4. **Tool Argument Sanitizer (`src/backends/openai.zig`)**:
   - Automatically unescapes JSON arguments from Responses API SSE streams to guarantee tools receive clean JSON objects without double-escaped `\"`.

