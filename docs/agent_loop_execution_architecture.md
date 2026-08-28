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
    participant REPL as UI / REPL (editor.zig / repl.zig)
    participant Loop as AgentLoop (src/core/agent.zig)
    participant Hist as History & MemAct (src/core/history.zig)
    participant Back as AI Backend (OpenAI / Claude / Ollama)
    participant Tool as Tooling / CodeAct VM (registry.zig / QuickJS)
    participant Jour as ActJournal & CAS (journal.zig / cas.zig)
    participant ActLog as Act Logger (src/core/act_logger.zig)

    User->>REPL: Nhập prompt (vd: "Kiểm tra hệ thống và chạy tests")
    REPL->>Loop: processInput(user_text, text_cb, think_cb)
    Loop->>Hist: addUser(user_text)
    Loop->>Hist: compactContext(act_id) [Kiểm tra & nén chủ động nếu vượt token]

    rect rgb(240, 248, 255)
        Note over Loop,ActLog: VÒNG LẶP ACT 1 (Khảo sát qua Tool)
        Loop->>Jour: recordEvent(act_id=1, "act_started")
        Loop->>Hist: ensureOpenAICompatible() [Vệ sinh orphan tool blocks]
        Loop->>Back: sendMessage(stream=true, system_prompt, history, tools)
        Back-->>REPL: SSE chunks: reasoning / thinking
        Back-->>REPL: SSE chunks: tool_call (name: "session_diagnostics", args: "{\"operation\":\"list\"}")
        Back-->>Loop: Response { stop_reason: .tool_use, tool_calls: [session_diagnostics] }
        Loop->>Hist: addAssistantResponse(&response)
        
        Loop->>Tool: executeTool("session_diagnostics", "{\"operation\":\"list\"}")
        Tool-->>Loop: output: "[Bảng trạng thái sessions...]"
        Loop->>Hist: addToolResult(call_id, output)
        Loop->>Jour: recordEvent(act_id=1, "act_completed", snapshots)
        Loop->>ActLog: logAct(act_1.json)
    end

    rect rgb(255, 250, 240)
        Note over Loop,ActLog: VÒNG LẶP ACT 2 (Thực thi Lệnh Shell)
        Loop->>Jour: recordEvent(act_id=2, "act_started")
        Loop->>Back: sendMessage(stream=true, history)
        Back-->>Loop: Response { stop_reason: .tool_use, tool_calls: [bash] }
        Loop->>Hist: addAssistantResponse(&response)
        
        Loop->>Tool: executeTool("bash", "{\"command\":\"zig build test\"}")
        Tool-->>Loop: output: "All 140 tests passed"
        Loop->>Hist: addToolResult(call_id, output)
        Loop->>Jour: recordEvent(act_id=2, "act_completed")
        Loop->>ActLog: logAct(act_2.json)
    end

    rect rgb(240, 255, 240)
        Note over Loop,ActLog: VÒNG LẶP ACT 3 (Trả Lời Hoàn Tất)
        Loop->>Jour: recordEvent(act_id=3, "act_started")
        Loop->>Back: sendMessage(stream=true, history)
        Back-->>REPL: SSE Stream Text: "Đã kiểm tra xong: 140/140 tests đều đạt."
        Back-->>Loop: Response { stop_reason: .end_turn, content: [text] }
        Loop->>Hist: addAssistantResponse(&response)
        Loop->>Jour: recordEvent(act_id=3, "act_completed")
        Loop->>Jour: recordEvent(act_id=3, "task_completed")
        Loop->>ActLog: logAct(act_3.json)
    end

    alt Chế độ Interactive REPL
        Loop-->>REPL: Hoàn thành Turn (Return)
        REPL->>User: In prompt "You > " và chờ stdin (anon_pipe_read)
    else Chế độ Subagent / Single-shot (-e)
        Loop-->>REPL: Thoát tiến trình
        REPL->>User: exit(0)
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
