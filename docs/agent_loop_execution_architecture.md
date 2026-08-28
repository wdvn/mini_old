# Kiến Trúc Vòng Lặp Xử Lý Của Agent (Agent Loop Execution Architecture)

Tài liệu này mô tả chi tiết và trực quan toàn bộ luồng thực thi của **1 Vòng lặp Agent (1 Turn / Multi-Act Loop)** trong `mini-agent` — từ lúc tiếp nhận User Prompt cho đến khi hoàn thành nhiệm vụ và quay về trạng thái nhàn rỗi (REPL Idle) hoặc thoát tiến trình.

---

## 1. Sơ đồ Luồng Tổng Thể (End-to-End Execution Flowchart)

```mermaid
flowchart TD
    Start([User Input: REPL / CLI -e]) --> InitTurn[Bắt đầu Turn mới: Reset Turn Metrics & State]
    InitTurn --> AddUserHistory[Thêm User Message vào History]
    
    subgraph ActLoop ["VÒNG LẶP ACT (while true : act_id += 1)"]
        direction TB
        CheckInterrupted{Người dùng Ctrl+C?}
        CheckInterrupted -- YES --> HandleInterrupt[Ghi journal: task_interrupted --> Thoát Turn]
        CheckInterrupted -- NO --> CheckCompaction{Context Tokens > Threshold?}
        
        CheckCompaction -- YES --> DoCompaction[MemAct: Tóm tắt lịch sử & drop intermediate messages]
        CheckCompaction -- NO --> SanitizeHistory[Vệ sinh History 2 chiều: ensureOpenAICompatible / ensureClaudeCompatible]
        DoCompaction --> SanitizeHistory
        
        SanitizeHistory --> FilterTools[Lọc danh sách Tools phù hợp theo execution_mode]
        FilterTools --> JournalStart[Ghi Journal: act_started]
        JournalStart --> SendBackend[Gửi Request lên LLM Backend qua SSE Stream]
        
        SendBackend --> StreamUI[Stream Realtime: Thinking, Text, Tool Call Progress]
        StreamUI --> ClassifyResponse{Phân loại LLM Response}
        
        %% Nhánh Lỗi Backend
        ClassifyResponse -- "Lỗi 429 / 5xx" --> RetryBackoff[Exponential Backoff Retry & Record Error]
        RetryBackoff --> SendBackend
        ClassifyResponse -- "Lỗi Context Limit (400)" --> ForceCompact[MemAct Compaction khẩn cấp]
        ForceCompact --> SendBackend
        ClassifyResponse -- "Lỗi Auth / Terminal" --> AbortAct[Ghi journal: act_failed & CAS Rollback --> Dừng Turn]
        
        %% Nhánh Thực Thi Nghiệp Vụ
        ClassifyResponse -- "stop_reason = tool_use" --> ExecNativeTools[Thực thi Native Tool: bash, subagent, session_diagnostics...]
        ClassifyResponse -- "stop_reason = end_turn + có CodeAct JS" --> ExecCodeAct[Thực thi CodeAct JS trong QuickJS VM nhúng]
        ClassifyResponse -- "stop_reason = end_turn + KHÔNG gọi tool" --> TaskFinished[Hoàn thành toàn bộ nhiệm vụ: Ghi task_completed]
        
        ExecNativeTools --> AddToolResult[Thêm Tool Result vào History]
        ExecCodeAct --> AddCodeActResult[Thêm CodeAct stdout/result vào History]
        
        AddToolResult --> JournalActDone[Ghi Journal: act_completed & Log Act Replay]
        AddCodeActResult --> JournalActDone
        JournalActDone --> NextAct[Tiếp tục vòng lặp: act_id += 1]
        NextAct --> CheckInterrupted
    end
    
    TaskFinished --> CheckMode{Chế độ Chạy?}
    CheckMode -- "Interactive REPL (mini)" --> WaitStdin[Quay về dấu nhắc 'You > ' và gọi read(stdin) - State: idle_waiting_input]
    CheckMode -- "Single-shot / Subagent (mini -e)" --> ExitProcess([exit 0 - Kết thúc tiến trình])
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

    User->>REPL: Nhập prompt (vd: "Kiểm tra tiến trình và tối ưu mã")
    REPL->>Loop: processInput(user_text, text_cb, think_cb)
    Loop->>Hist: addUser(user_text)

    rect rgb(240, 248, 255)
        Note over Loop,Jour: VÒNG LẶP ACT 1 (Khảo sát & Phân tích)
        Loop->>Hist: ensureOpenAICompatible() (Vệ sinh orphan tool_use/tool_result)
        Loop->>Jour: recordEvent(act_id=1, "act_started")
        Loop->>Back: sendMessage(stream=true, system_prompt, history, tools)
        Back-->>REPL: SSE Chunks: reasoning/thinking
        Back-->>REPL: SSE Chunks: output_text hoặc tool_call.delta
        Back-->>Loop: Response { stop_reason: .tool_use, tool_calls: [session_diagnostics] }
        
        Loop->>Tool: executeTool("session_diagnostics", input_json)
        Tool-->>Loop: output: "[Bảng trạng thái sessions...]"
        Loop->>Hist: addToolResult(call_id, output)
        Loop->>Jour: recordEvent(act_id=1, "act_completed", snapshots)
    end

    rect rgb(255, 250, 240)
        Note over Loop,Jour: VÒNG LẶP ACT 2 (Thực thi Tool tiếp theo hoặc Viết mã)
        Loop->>Jour: recordEvent(act_id=2, "act_started")
        Loop->>Back: sendMessage(stream=true, history)
        Back-->>Loop: Response { stop_reason: .tool_use, tool_calls: [bash] }
        Loop->>Tool: executeTool("bash", "zig build test")
        Tool-->>Loop: output: "All tests passed"
        Loop->>Hist: addToolResult(call_id, output)
        Loop->>Jour: recordEvent(act_id=2, "act_completed")
    end

    rect rgb(240, 255, 240)
        Note over Loop,Jour: VÒNG LẶP ACT 3 (Tổng kết câu trả lời)
        Loop->>Jour: recordEvent(act_id=3, "act_started")
        Loop->>Back: sendMessage(stream=true, history)
        Back-->>REPL: SSE Stream Text: "Đã kiểm tra xong hệ thống..."
        Back-->>Loop: Response { stop_reason: .end_turn, content: [text] }
        Loop->>Hist: addAssistantResponse(text)
        Loop->>Jour: recordEvent(act_id=3, "act_completed")
        Loop->>Jour: recordEvent(act_id=3, "task_completed")
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
