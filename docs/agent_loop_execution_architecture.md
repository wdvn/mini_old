# Kiến Trúc Vòng Lặp Xử Lý Của Agent (Agent Loop Execution Architecture)

Tài liệu này mô tả chi tiết và trực quan toàn bộ luồng thực thi của **1 Vòng lặp Agent (1 Turn / Multi-Act Loop)** trong `mini-agent` — từ lúc tiếp nhận User Prompt cho đến khi hoàn thành nhiệm vụ và quay về trạng thái nhàn rỗi (REPL Idle) hoặc thoát tiến trình.

---

## 1. Sơ đồ Luồng Tổng Thể (End-to-End Execution Flowchart)

```mermaid
flowchart TD
    Start(["User Input (REPL / CLI -e)"]) --> InitTurn["Khởi tạo Turn mới: Reset Metrics & Allocator"]
    InitTurn --> AddUserHist["Thêm User Message vào History"]
    AddUserHist --> CheckMemAct{"Context Tokens > Threshold?"}
    
    CheckMemAct -- "YES" --> ProactiveCompact["MemAct: Tóm tắt lịch sử & nén ngữ cảnh chủ động"]
    CheckMemAct -- "NO" --> EnterLoop
    ProactiveCompact --> EnterLoop

    subgraph ActLoop ["VÒNG LẶP ACT (while true : act_id += 1)"]
        direction TB
        EnterLoop(["Bắt đầu Act"]) --> CheckSignal{"Người dùng nhấn Ctrl+C?"}
        
        CheckSignal -- "YES" --> SigInt["Ghi journal: task_interrupted -> Dừng Turn"]
        CheckSignal -- "NO" --> JournalStart["Ghi Journal: act_started"]
        
        JournalStart --> Sanitize["Vệ sinh History 2 chiều: ensureOpenAICompatible / ensureClaudeCompatible"]
        Sanitize --> FilterTools["Lọc Tool Definitions theo execution_mode (codeact / tools / auto)"]
        FilterTools --> SendBackend["Gửi Request lên AI Backend (SSE Streaming)"]
        
        SendBackend --> StreamUI["Stream UI Realtime: Reasoning/Thinking, Markdown Text, Tool Preview"]
        StreamUI --> AddAssistantHist["Thêm Assistant Response vào History"]
        AddAssistantHist --> Classify{"Phân loại Response & Stop Reason"}
        
        %% Nhánh Lỗi Backend & Phục Hồi
        Classify -- "Lỗi 429 RateLimit / 5xx" --> RetryBackoff["Ghi llm_call_throttled / provider_error -> Exponential Backoff Sleep -> Retry Act"]
        RetryBackoff --> SendBackend
        
        Classify -- "Lỗi 400 Context Overflow" --> ForceCompact["Ghi llm_context_overflow -> Kích hoạt MemAct nén khẩn cấp -> Retry Act"]
        ForceCompact --> SendBackend
        
        Classify -- "Lỗi Auth / Max Retries" --> AbortAct["Ghi act_failed -> Rollback CAS Snapshot -> Dừng Turn"]
        
        %% Nhánh Native Tool Calling
        Classify -- "stop_reason = tool_use" --> ExecNative["Thực thi Native Tool: bash, subagent, session_diagnostics, file..."]
        ExecNative --> SnapshotCAS["Tạo CAS Snapshot cho file sửa đổi"]
        SnapshotCAS --> AddToolResult["Thêm tool_result vào History"]
        AddToolResult --> JournalActDone["Ghi Journal: act_completed & Log Act Replay JSON"]
        
        %% Nhánh CodeAct JS Execution
        Classify -- "stop_reason = end_turn + Có block JS" --> ExecJS["Thực thi JS trong QuickJS VM nhúng (Object mini.*)"]
        ExecJS --> AddJSResult["Thêm CodeAct stdout / return value / error vào History"]
        AddJSResult --> JournalActDone
        
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

## 2. Trình Tự Thực Thi Chi Tiết Từng Bước (Detailed Sequence Diagram)

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
    Agent->>Hist: compactContext() (Kiểm tra MemAct nén chủ động nếu vượt token)

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

## 3. Các Trạng Thái Vòng Lặp & Ý Nghĩa Telemetry

Khi kiểm tra tiến trình qua tool `session_diagnostics` hoặc file journal `~/.mini/sessions/journal_<pid>.jsonl`, trạng thái của tiến trình được định nghĩa chuẩn xác như sau:

| State | Event cuối | Trạng thái OS | Ý nghĩa nghiệp vụ |
|---|---|---|---|
| `idle_waiting_input` | `task_completed` | `ALIVE` (`anon_pipe_read`) | **Tiến trình REPL đang rảnh**, đã trả lời xong và đang đứng chờ người dùng gõ câu lệnh tiếp theo tại dấu nhắc `You > `. |
| `executing_act` | `act_started` | `ALIVE` | Đang gửi request lên LLM backend (chờ streaming) hoặc đang chạy Tool (bash, subagent...). |
| `between_acts` | `act_completed` | `ALIVE` | Vừa thực thi xong 1 Act, đang chuẩn bị chuyển ngữ cảnh sang Act tiếp theo. |
| `completed` | `task_completed` | `DEAD` (Exit 0) | Tiến trình subagent hoặc single-shot `-e` đã hoàn thành toàn bộ công việc và tự thoát an toàn. |
| `crashed` / `failed`| `act_failed` | `DEAD` / `ALIVE` | Gặp lỗi terminal (xác thực, sập mạng, syntax crash không thể retry). |

---

## 4. Các Chốt Chặn An Toàn & Khả Năng Tự Phục Hồi (Resilience & Guards)

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
