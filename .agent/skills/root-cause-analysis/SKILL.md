---
name: root-cause-analysis
description: Phân tích nguyên nhân gốc rễ (Root Cause Analysis - RCA), debug lỗi phức tạp, tái hiện sự cố và kiểm chứng giả thuyết. Use when cần điều tra bug, unhandled error, crash, timeout hoặc hành vi sai lệch trong codebase.
---

# Root Cause Analysis (RCA) Skill

Hướng dẫn phương pháp luận chuẩn để điều tra, cô lập và tìm ra nguyên nhân gốc rễ của các lỗi kỹ thuật trong hệ thống `mini`.

---

## 1. Khi nào kích hoạt Skill này?

- Khi có thông báo lỗi từ runtime (`UnknownStopReason`, `LLMProviderUnavailable`, panic, crash).
- Khi kết quả đầu ra không đúng kỳ vọng (logic bug, hiển thị sai số liệu, đếm trùng lặp event).
- Khi phát hiện deadlock, timeout, luồng chạy ngầm không thoát hoặc leak tài nguyên.

---

## 2. Phương pháp luận 5 bước (5-Step Investigation)

```
[1. Thu thập triệu chứng (Symptom Collection)]
       │
       ▼
[2. Tách biệt & Tái hiện (Isolation & Reproduction)]
       │
       ▼
[3. Phân tích 5-Whys & Formulate Hypotheses]
       │
       ▼
[4. Kiểm chứng giả thuyết bằng Dữ liệu (Validation)]
       │
       ▼
[5. Đề xuất & Xác thực bản vá (Fix & Verify)]
```

### Bước 1: Thu thập triệu chứng chính xác
- **Error name & Error trace**: Tìm chính xác tên error Zig (`error.Name`) và stack trace.
- **HTTP status & Raw Response**: Đối với lỗi backend AI, kiểm tra HTTP code (400, 401, 403, 429, 500, 529...) và JSON snippet trả về từ server.
- **Logs & Journal**: Đọc file journal tương ứng tại `~/.mini/sessions/journal_<pid>.jsonl`.

### Bước 2: Tách biệt phạm vi & Tái hiện
- Cô lập phạm vi: Lỗi nằm ở đâu?
  - *Network / AI Provider*: Do server upstream từ chối, rate limit, quota?
  - *Data Parsing / Protocol*: Do SSE chunking, JSON escape, header format?
  - *Runtime / Concurrency*: Do race condition giữa main thread và worker thread?
  - *State Management*: Do history compaction, context overflow, rollback?
- Viết testcase độc lập trong `testcases/test_<vấn_đề>.zig` để tái hiện hành vi nếu có thể.

### Bước 3: Áp dụng kỹ thuật 5-Whys
Đặt câu hỏi "Tại sao?" lặp lại để không dừng lại ở triệu chứng bề mặt:
*Ví dụ*:
1. *Tại sao agent báo UnknownStopReason?* -> Vì `response.stop_reason` trả về `.unknown`.
2. *Tại sao stop_reason là unknown?* -> Vì backend trả về HTTP 403 với nội dung "customer_verification_required".
3. *Tại sao agent lại retry 4 lần?* -> Vì switch error rơi vào nhánh `else` (mặc định cho lỗi bất thường) thay vì phân loại auth error.
4. *Nguyên nhân gốc rễ (Root Cause)*: Thiếu phân loại `LLMAuthenticationError` cho HTTP 401/403 để fail-fast ngay từ đầu.

### Bước 4: Kiểm chứng giả thuyết
- Đặt câu hỏi phản biện: "Nếu giả thuyết này đúng, điều gì sẽ xảy ra? Nếu sai, tại sao?"
- Kiểm tra các corner-case: empty body, partial chunk, unicode characters, zero length string, EOF đột ngột.

### Bước 5: Thực thi & Kiểm thử hồi quy
- Sửa đổi tối thiểu (minimal blast radius).
- Chạy `zig build test --summary all` để bảo đảm không gây regression.
