---
name: session-diagnostics
description: Kiểm tra và chẩn đoán log phiên làm việc, journals, errors và audit telemetry của mini-agent. Use when cần phân tích lịch sử chạy, lỗi backend, rate-limit, context overflow hoặc sự cố trong các session gần nhất.
---

# Session Diagnostics Skill

Hướng dẫn tra cứu, trích xuất và chẩn đoán sự cố thông qua hệ thống Event Sourcing Journal (`~/.mini/sessions/journal_*.jsonl`).

---

## 1. Cấu trúc file Journal trong `~/.mini/sessions/`

Mỗi tiến trình `mini-agent` khi chạy sẽ tạo một file `journal_<pid>.jsonl` chứa các sự kiện dạng JSON Lines:

```json
{"act_id":1,"event_type":"act_started","timestamp":1787644166589,"description":"Bắt đầu Act","delta":null,"error_detail":null}
{"act_id":1,"event_type":"llm_provider_error","timestamp":1787644167000,"description":"Backend lỗi","delta":null,"error_detail":{"backend":"openai-compat","model":"gpt-4o","error_name":"LLMProviderUnavailable","http_code":529,"attempt":1,"raw_snippet":"...","server_error":"..."}}
{"act_id":1,"event_type":"act_completed","timestamp":1787644169637,"description":"Hoàn thành Act","delta":{"act_id":1,"file_snapshots":[]},"error_detail":null}
{"act_id":1,"event_type":"task_completed","timestamp":1787644172005,"description":"Nhiệm vụ hoàn thành","delta":null,"error_detail":null}
```

---

## 2. Công cụ tra cứu tích hợp sẵn (Khuyến nghị cho LLM)

Thay vì chạy lệnh bash thô hay tự đọc `/proc` (dễ nhầm lẫn trạng thái kernel `anon_pipe_read`), hãy dùng trực tiếp các API chuyên dụng sau:

### A. Dùng Tool `session_diagnostics` (JSON Tool Call)
1. **Liệt kê toàn bộ session và tiến trình**:
   ```json
   {"operation": "list"}
   ```
2. **Xem chi tiết 1 PID (kèm phân loại REPL vs Subagent & trạng thái nghiệp vụ)**:
   ```json
   {"operation": "detail", "pid": 340194}
   ```
3. **Dừng an toàn tiến trình bị treo**:
   ```json
   {"operation": "kill", "pid": 340194, "signal": "SIGTERM"}
   ```

### B. Dùng qua CodeAct JS VM (`mini.*`)
* `mini.sessions()`: Trả về bảng danh sách session.
* `mini.sessionDetail(pid)`: Trả về báo cáo chẩn đoán chi tiết theo PID.
* `mini.sessionKill(pid, signal?)`: Gửi tín hiệu dừng tiến trình.

---

## 3. Nguyên tắc vàng khi đọc trạng thái tiến trình

1. **Phân biệt REPL Interactive vs Subagent/Batch**:
   - **REPL Session (`mini`)**: Sau khi hoàn thành 1 task (`task_completed`), process vẫn **ALIVE** và ở trạng thái `idle_waiting_input` (chờ user gõ tại dấu nhắc `You > `). Trạng thái kernel `anon_pipe_read` / `n_tty_read` là **hoàn toàn bình thường**, KHÔNG PHẢI lỗi treo hay kẹt pipe!
   - **Subagent / Single-shot (`mini -e "..."`)**: Luôn tự động thoát (`exit 0`) khi hoàn thành task. Nếu một subagent vẫn ALIVE sau khi có `task_completed` hoặc kẹt ở `act_started` quá lâu thì mới là bất thường.

2. **Xác định trạng thái qua Journal Events**:
   - `task_completed` ở cuối $\to$ Task đã xong 100%.
   - `act_started` ở cuối (kèm PID vẫn sống) $\to$ Đang gọi LLM API hoặc đang thực thi Tool.
   - `act_completed` ở cuối $\to$ Đang chuyển tiếp giữa các Act.

---

## 4. Các lệnh tra cứu thủ công qua Shell (Quick CLI Commands)

---

## 3. Bảng mã sự kiện và cách chẩn đoán

| Event Type | Ý nghĩa | Vấn đề tiềm ẩn cần kiểm tra |
|---|---|---|
| `act_started` | Bắt đầu vòng lặp act mới | Nếu kết thúc file là `act_started` mà không có `act_completed` -> tiến trình bị crash, timeout hoặc kill |
| `llm_call_throttled` | HTTP 429 Rate Limit | Cần xem `backoff_s` và kiểm tra quota/tier của API key |
| `llm_provider_error` | HTTP 5xx / 529 Server Overload | Server AI upstream bị quá tải hoặc sập tạm thời |
| `llm_context_overflow` | Context vượt quá giới hạn | Kiểm tra cơ chế MemAct nén lịch sử và token estimator |
| `act_failed` | Act thất bại (lỗi terminal hoặc retry) | Xem `error_detail.error_name`, `error_detail.http_code`, `error_detail.raw_snippet` |
| `rollback_completed` | Đã rollback state và truncate history | Kiểm tra xem CAS snapshot có khôi phục đúng file cũ không |
