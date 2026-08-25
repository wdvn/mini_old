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

## 2. Các lệnh tra cứu nhanh (Quick Commands)

### 1. Liệt kê 5 session mới nhất:
```bash
ls -lt ~/.mini/sessions/journal_*.jsonl | head -n 5
```

### 2. Quét nhanh tất cả các lỗi trong các session:
```bash
grep -v '"error_detail":null' ~/.mini/sessions/journal_*.jsonl
```

### 3. Tìm các act bị treo / không hoàn thành (không có `act_completed` sau `act_started`):
```bash
tail -n 10 $(ls -t ~/.mini/sessions/journal_*.jsonl | head -n 1)
```

### 4. Chạy script chẩn đoán tự động:
```bash
bash .agent/skills/session-diagnostics/scripts/diagnose_sessions.sh
```

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
