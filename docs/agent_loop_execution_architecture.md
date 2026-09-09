# Kiến Trúc Vòng Lặp Xử Lý Của Agent (Agent Loop Execution Architecture)

Tài liệu này mô tả chi tiết và trực quan toàn bộ luồng thực thi của **1 Vòng lặp Agent (1 Turn / Multi-Act Loop)** trong `mini-agent` — từ lúc tiếp nhận User Prompt, phân giải đa tầng, thực thi công cụ đơn lẻ cho đến **Mô hình Quy nạp Đệ quy Đa tầng (Hierarchical / Recursive Sub-agent Execution Tree)**.

---

## 1. Sơ đồ Luồng Tổng Thể Của 1 Vòng Lặp (End-to-End Execution Flowchart)

```mermaid
flowchart TD
    Start(["User Input (REPL / CLI -e)"]) --> InitTurn["Khởi tạo Turn mới: Reset Metrics & Allocator"]
    InitTurn --> AddUserHist["Thêm User Message vào History"]
    AddUserHist --> EnterLoop

    subgraph ActLoop ["VÒNG LẶP ACT (while true : act_id += 1)"]
        direction TB
        EnterLoop(["Bắt đầu Act"]) --> CheckSignal{"Người dùng nhấn Ctrl+C?"}
        
        CheckSignal -- "YES" --> SigInt["Ghi journal: task_interrupted -> Dừng Turn"]
        CheckSignal -- "NO" --> JournalStart["Ghi Journal: act_started"]
        
        JournalStart --> Sanitize["Vệ sinh History 2 chiều: ensureOpenAICompatible / ensureClaudeCompatible"]
        Sanitize --> FilterTools["Lọc Tool Definitions theo execution_mode (codeact / tools / auto)"]
        FilterTools --> SendBackend["Gửi Request lên AI Backend (SSE Streaming / Dual-Protocol Auto-Negotiation)"]
        
        SendBackend --> StreamUI["Stream UI Realtime: Reasoning/Thinking, Markdown Text, Inplace Retry & Action Cards"]
        StreamUI --> AddAssistantHist["Thêm Assistant Response vào History"]
        AddAssistantHist --> Classify{"Phân loại Response & Stop Reason"}
        
        %% Nhánh Lỗi Backend & Phục Hồi
        Classify -- "Lỗi 429 RateLimit / 5xx / 520, 522" --> RetryBackoff["Ghi llm_call_throttled -> Inplace Terminal Overwrite (\x1b[1A\x1b[2K\r) -> Exponential Backoff -> Retry Act"]
        RetryBackoff --> SendBackend
        
        Classify -- "Lỗi 400 Context Overflow" --> ForceCompact["Ghi llm_context_overflow -> MemAct Reactive Compaction (drop-all + summary tại index 1, giữ index 0) -> Retry Act"]
        ForceCompact --> SendBackend
        
        Classify -- "Lỗi Auth / Max Retries" --> AbortAct["Ghi act_failed -> Rollback CAS Snapshot -> Dừng Turn"]
        
        %% Nhánh Thực Thi Công Cụ
        Classify -- "stop_reason = tool_use (Leaf Tool)" --> ExecLeaf["Thực thi Công cụ đơn (bash, grep, file_read, session_diag...)"]
        Classify -- "stop_reason = tool_use (Sub-Agent Tool)" --> ExecSubTree["QUY NẠP ĐA TẦNG: Spawn Tiến trình Con (invoke_subagent / batch)"]
        Classify -- "stop_reason = end_turn + Có block JS" --> ExecJS["Thực thi JS trong QuickJS VM nhúng (Object mini.*)"]
        
        ExecLeaf --> SnapshotCAS["Tạo CAS Snapshot cho file sửa đổi"]
        ExecSubTree --> CollectSubOut["Thu thập kết quả từ Pipe của Sub-Agent"]
        ExecJS --> AddJSResult["Thêm CodeAct stdout / return value / error vào History"]
        
        SnapshotCAS --> AddToolResult["Thêm tool_result vào History"]
        CollectSubOut --> AddToolResult
        AddJSResult --> JournalActDone["Ghi Journal: act_completed & Log Act Replay JSON"]
        AddToolResult --> JournalActDone
        
        %% Nhánh Kết thúc Turn
        Classify -- "stop_reason = end_turn + KHÔNG gọi tool/JS" --> TaskCompleted["Ghi Journal: act_completed & task_completed -> Thoát Vòng Lặp"]
        
        JournalActDone --> NextAct(["Chuyển sang Act tiếp theo: act_id += 1"])
        NextAct --> EnterLoop
    end

    TaskCompleted --> CheckExecMode{"Chế độ Chạy?"}
    CheckExecMode -- "Interactive REPL (mini)" --> WaitStdin["In prompt 'You > ' và chờ bàn phím: read(stdin) (Trạng thái: idle_waiting_input)"]
    CheckExecMode -- "Single-shot / Subagent (mini -e)" --> ExitProcess(["exit 0 - Kết thúc tiến trình (Trạng thái: completed)"])
```

---

## 2. Trình Tự Thực Thi 1 Turn Đơn Cấp (Single-Level Sequence Diagram)

```mermaid
sequenceDiagram
    autonumber
    actor User as Người dùng
    participant REPL as UI / REPL (ui/repl.zig & chat_stream.zig)
    participant Agent as AgentLoop (src/core/agent.zig)
    participant Hist as History & MemAct (core/history.zig & memact/)
    participant Backend as AI Backend (OpenAI / Claude / Ollama)
    participant Tool as Tool Registry / CodeAct VM (registry.zig / QuickJS)
    participant Jour as ActJournal & CAS (core/journal.zig & cas.zig)
    participant ActLog as Act Logger (core/act_logger.zig)

    User->>REPL: Nhập prompt (vd: "Kiểm tra hệ thống và chạy tests")
    REPL->>Agent: processInput(user_text, text_cb, think_cb)
    Agent->>Hist: addUser(user_text)
    Note over Agent,Hist: MemAct nén phản ứng (chỉ kích hoạt khi backend trả lỗi tràn token)

    rect rgb(240, 248, 255)
        Note over Agent,ActLog: VÒNG LẶP ACT 1 (Khảo sát qua Native Tool Calling)
        Agent->>Jour: recordEvent(act_id=1, "act_started")
        Agent->>Hist: ensureOpenAICompatible() (Vệ sinh orphan tool blocks 2 chiều)
        Agent->>Backend: sendMessage(stream=true, system_prompt, history, tools)
        Backend-->>REPL: SSE chunks: reasoning / thinking -> streamThinking()
        Backend-->>REPL: SSE chunks: tool_call -> startTool("session_diagnostics")
        REPL-->>User: Render realtime Thinking & Tool Header (⚡ session_diagnostics list)
        Backend-->>Agent: Response (stop_reason: .tool_use, tool_calls: [session_diagnostics])
        Agent->>Hist: addAssistantResponse(&response)
        
        Agent->>Tool: executeTool("session_diagnostics", "{\"operation\":\"list\"}")
        Tool-->>Agent: Tool output string (Bảng trạng thái sessions)
        Agent->>REPL: finishTool("session_diagnostics", output) -> Preview tối đa 3 dòng
        REPL-->>User: Render "✓ Hoàn thành (5ms)" + output preview
        Agent->>Hist: addToolResult(call_id, output)
        Agent->>Jour: recordEvent(act_id=1, "act_completed")
        Agent->>ActLog: logAct(act_1.json)
    end

    rect rgb(255, 250, 240)
        Note over Agent,ActLog: VÒNG LẶP ACT 2 (Thực thi CodeAct JS trong QuickJS VM)
        Agent->>Jour: recordEvent(act_id=2, "act_started")
        Agent->>Backend: sendMessage(stream=true, history)
        Backend-->>REPL: SSE chunks: JS Code Block (```javascript mini.sh(...)```)
        Backend-->>Agent: Response (stop_reason: .end_turn, contains JS code block)
        Agent->>Hist: addAssistantResponse(&response)
        
        Agent->>Tool: engine.eval(js_code) -> QuickJS VM (mini.sh, CAS Snapshot)
        Tool-->>Agent: Execution output (stdout, return value)
        Agent->>REPL: finishTool("codeact", stdout) -> Preview rolling 3 dòng
        Agent->>Hist: addUser("[CodeAct Output]: " + stdout)
        Agent->>Jour: recordEvent(act_id=2, "act_completed", snapshots)
        Agent->>ActLog: logAct(act_2.json)
    end

    rect rgb(240, 255, 240)
        Note over Agent,ActLog: VÒNG LẶP ACT 3 (Trả Lời Hoàn Tất & Kết Thúc Turn)
        Agent->>Jour: recordEvent(act_id=3, "act_started")
        Agent->>Backend: sendMessage(stream=true, history)
        Backend-->>REPL: SSE chunks: Markdown Text -> streamTextResponse()
        REPL-->>User: Render Markdown Streaming (Syntax Highlighted)
        Backend-->>Agent: Response (stop_reason: .end_turn, content: [text], KHÔNG gọi tool/JS)
        Agent->>Hist: addAssistantResponse(&response)
        Agent->>Jour: recordEvent(act_id=3, "act_completed")
        Agent->>Jour: recordEvent(act_id=3, "task_completed")
        Agent->>ActLog: logAct(act_3.json)
    end

    alt Chế độ Interactive REPL (mini)
        Agent-->>REPL: Hoàn thành Turn (Return về vòng lặp REPL)
        REPL->>User: In dấu nhắc "You > " và chờ stdin (read(stdin) - State: idle_waiting_input)
    else Chế độ Subagent / Single-shot (mini -e)
        Agent-->>REPL: Thoát tiến trình
        REPL->>User: exit(0) (Trạng thái: completed)
    end
```

---

## 3. Mô Hình Quy Nạp Đa Tầng (Recursive / Inductive Sub-Agent Tree)

Một công cụ như `invoke_subagent` hay `batch_invoke_subagents` **không phải là một hàm lá (Leaf Tool)**, mà là một **Node trung gian sinh cây con (Subtree Generator)**. Mỗi subagent sinh ra một tiến trình độc lập và khởi chạy một vòng lặp `AgentLoop` đệ quy hoàn chỉnh.

### A. Sơ đồ Cây Thực Thi Đa Tầng (Execution Tree)

```mermaid
graph TD
    User([User Prompt]) --> RootAgent["Parent AgentLoop (PID: 1000, Depth: 0)"]
    
    RootAgent -->|Act 1: tool_use| Sub1["Sub-agent 1 (PID: 1001, Depth: 1)\nTask: 'Điều tra log và trace code'"]
    RootAgent -->|Act 2: tool_use| Sub2["Sub-agent 2 (PID: 1002, Depth: 1)\nTask: 'Chạy benchmark & refactor'"]
    RootAgent -->|Act 3: text| FinalResponse["Final Synthesized Answer to User"]

    %% Cây con của Subagent 1
    Sub1 -->|Sub-Act 1| Leaf1["Leaf Tool: grep 'error' src/"]
    Sub1 -->|Sub-Act 2| Leaf2["Leaf Tool: file_read src/core/agent.zig"]
    Sub1 -->|Sub-Act 3| SubReport1["Sub-agent 1 Result (stdout blob)"]

    %% Cây con của Subagent 2
    Sub2 -->|Sub-Act 1| Leaf3["Leaf Tool: bash 'zig build test'"]
    Sub2 -->|Sub-Act 2| Leaf4["CodeAct QuickJS: mini.patch(...)"]
    Sub2 -->|Sub-Act 3| SubReport2["Sub-agent 2 Result (stdout blob)"]

    SubReport1 -->|Pipe stdout| RootAgent
    SubReport2 -->|Pipe stdout| RootAgent
```

---

### B. Sơ đồ Tuần Tự Quy Nạp Đệ Quy (Inductive Recursive Sequence Diagram)

```mermaid
sequenceDiagram
    autonumber
    actor User as Người dùng
    participant ParentREPL as Parent UI / REPL (Depth 0)
    participant ParentAgent as Parent AgentLoop (Depth 0, PID 1000)
    participant SubTool as Subagent Tool Wrapper (src/tools/subagent.zig)
    participant ChildAgent as Child AgentLoop (Depth 1, PID 1001)
    participant ChildBackend as Child AI Backend
    participant LeafTools as Leaf Tools (grep, bash, file_write)

    User->>ParentREPL: Prompt phức tạp (vd: "Điều tra lỗi crash và sửa code")
    ParentREPL->>ParentAgent: processInput()
    
    rect rgb(240, 248, 255)
        Note over ParentAgent,SubTool: PARENT ACT 1 (Ủy quyền tác vụ con)
        ParentAgent->>ParentAgent: Backend gọi tool `invoke_subagent`
        ParentAgent->>ParentREPL: startTool("invoke_subagent", "task: 'Trace bug'")
        ParentREPL-->>User: Render: "⚡ invoke_subagent (Task: Trace bug)"
        ParentAgent->>SubTool: executeTool("invoke_subagent", task_json)
        
        SubTool->>SubTool: Kiểm tra Guard: MINI_SUBAGENT_DEPTH (0 < 2)
        SubTool->>ChildAgent: spawn("mini", ["-e", task], env: {DEPTH: 1, QUIET: 1})
    end

    rect rgb(255, 250, 240)
        Note over ChildAgent,LeafTools: VÒNG LẶP CON (CHILD AGENT LOOP - Depth 1)
        Note right of ChildAgent: Khởi tạo History, Journal_1001.jsonl, CAS riêng
        ChildAgent->>ChildBackend: sendMessage(history)
        ChildBackend-->>ChildAgent: Response { stop_reason: .tool_use, tool: "grep" }
        ChildAgent->>LeafTools: executeTool("grep", "query: 'panic'")
        LeafTools-->>ChildAgent: "Found in line 42"
        
        ChildAgent->>ChildBackend: sendMessage(history + tool_result)
        ChildBackend-->>ChildAgent: Response { stop_reason: .tool_use, tool: "bash" }
        ChildAgent->>LeafTools: executeTool("bash", "zig build test")
        LeafTools-->>ChildAgent: "All tests pass"
        
        ChildAgent->>ChildBackend: sendMessage(history + tool_result)
        ChildBackend-->>ChildAgent: Response { stop_reason: .end_turn, content: "Báo cáo: Bug tại dòng 42 đã được vá." }
        ChildAgent-->>SubTool: In báo cáo ra stdout & exit(0)
    end

    rect rgb(240, 248, 255)
        Note over ParentAgent,SubTool: PARENT ACT 1 (Nhận kết quả quy nạp & tiếp tục)
        SubTool->>SubTool: Đọc toàn bộ stdout pipe từ ChildAgent
        SubTool-->>ParentAgent: Trả về stdout blob ("Báo cáo: Bug tại dòng 42...")
        ParentAgent->>ParentREPL: finishTool("invoke_subagent", child_stdout)
        ParentREPL-->>User: Render: "✓ Hoàn thành (1.8s)" + preview kết quả con
        ParentAgent->>ParentAgent: Thêm `tool_result` vào Parent History
    end

    rect rgb(240, 255, 240)
        Note over ParentAgent,ParentREPL: PARENT ACT 2 (Tổng hợp kết quả cuối cùng)
        ParentAgent->>ParentREPL: streamTextResponse()
        ParentREPL-->>User: Render Markdown Streaming: "Tôi đã cho subagent điều tra và hoàn tất sửa lỗi..."
    end
```

---

## 4. Cơ Chế Cách Ly & Tổng Hợp Stream Đa Tầng (Stream Aggregation & Isolation)

| Khía cạnh | Tiến trình Cha (Parent - Depth $d$) | Tiến trình Con (Subagent - Depth $d+1$) |
|---|---|---|
| **PID & Process** | Chạy interactive REPL hoặc CLI chính. | Subprocess độc lập được spawn qua `std.process.spawn`. |
| **History & Context** | Quản lý hội thoại chính với người dùng. | Context cục bộ chỉ phục vụ riêng `task` được giao. |
| **Event Sourcing Journal** | `~/.mini/sessions/journal_<parent_pid>.jsonl` | `~/.mini/sessions/journal_<child_pid>.jsonl` độc lập. |
| **Telemetry & State** | `executing_act` $\to$ `idle_waiting_input`. | `executing_act` $\to$ `completed` (exit 0). |
| **Stream UI & Output** | Render trực tiếp ra Terminal (Thinking, Tools, Markdown). | `stdout`/`stderr` được chuyển hướng vào Pipe; banner khởi động bị dập tắt (`QUIET=1`). Kết quả cuối cùng được rollup vào `tool_result` của Cha. |
| **Depth Guard** | Kiểm tra `depth < max_depth` (mặc định $\le 2$). | Tự động tăng `MINI_SUBAGENT_DEPTH = d + 1`. Chặn fork bomb đệ quy. |

---

## 5. Các Trạng Thái Vòng Lặp & Ý Nghĩa Telemetry

Khi kiểm tra tiến trình qua tool `session_diagnostics` hoặc file journal `~/.mini/sessions/journal_<pid>.jsonl`, trạng thái của tiến trình được định nghĩa chuẩn xác như sau:

| State | Event cuối | Trạng thái OS | Ý nghĩa nghiệp vụ |
|---|---|---|---|
| `idle_waiting_input` | `task_completed` | `ALIVE` (`anon_pipe_read`) | **Tiến trình REPL đang rảnh**, đã trả lời xong và đang đứng chờ người dùng gõ câu lệnh tiếp theo tại dấu nhắc `You > `. |
| `executing_act` | `act_started` | `ALIVE` | Đang gửi request lên LLM backend (chờ streaming) hoặc đang chạy Tool / Sub-agent. |
| `between_acts` | `act_completed` | `ALIVE` | Vừa thực thi xong 1 Act, đang chuẩn bị chuyển ngữ cảnh sang Act tiếp theo. |
| `completed` | `task_completed` | `DEAD` (Exit 0) | Tiến trình subagent hoặc single-shot `-e` đã hoàn thành toàn bộ công việc và tự thoát an toàn. |
| `crashed` / `failed`| `act_failed` | `DEAD` / `ALIVE` | Gặp lỗi terminal (xác thực, sập mạng, syntax crash không thể retry). |

---

## 6. Các Chốt Chặn An Toàn & Khả Năng Tự Phục Hồi (Resilience & Guards)

1. **Subagent Depth Guard (`src/tools/subagent.zig`)**:
   - Kiểm tra `MINI_SUBAGENT_DEPTH <= MINI_MAX_SUBAGENT_DEPTH` (mặc định = 2).
   - Tự động chặn nguy cơ đệ quy vô hạn hoặc fork bomb khi subagent tự gọi chính nó.
2. **CAS State Snapshot & Rollback (`src/core/snapshot.zig` + `cas.zig`)**:
   - Trước khi ghi đè tệp (`file_write`, `file_edit`, `mini.write`, `mini.patch`), nội dung cũ được hash SHA-256 và lưu vào Content-Addressed Storage (`~/.mini/cas/`).
   - Nếu Act bị lỗi terminal hoặc người dùng yêu cầu rollback, hệ thống khôi phục nguyên trạng tệp gốc.
3. **MemAct Compaction (`src/core/history.zig`)**:
   - Tự động nén ngữ cảnh khi token vượt ngưỡng mà không làm mất System Prompt hay User Intent ban đầu.
4. **Tool Argument Sanitizer (`src/backends/openai.zig`)**:
   - Tự động unescape JSON arguments từ SSE stream Responses API để đảm bảo tool luôn nhận đúng đối tượng JSON thuần không bị double-escape `\"`.
