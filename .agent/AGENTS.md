# .agent/AGENTS.md — Quy tắc và hướng dẫn chuyên sâu cho mini-agent

Tài liệu này bổ sung cho `AGENTS.md` ở root, tập trung vào phương pháp **phân tích, điều tra nguyên nhân gốc rễ (RCA) và tìm hiểu vấn đề** trong project **mini**.

---

## 1. Nguyên tắc cốt lõi khi phân tích vấn đề

1. **Hiểu rõ trước khi sửa (Investigate Before Mutating)**:
   - Luôn định vị chính xác vị trí phát sinh lỗi và luồng dữ liệu (data flow) trước khi thay đổi bất kỳ dòng code nào.
   - Sử dụng các skill phân tích (`codebase-analysis`, `root-cause-analysis`, `session-diagnostics`) để xây dựng bức tranh toàn cảnh.

2. **Dựa trên dữ liệu thực tế (Evidence-Based Diagnostics)**:
   - Khi điều tra lỗi chạy thực tế của mini, kiểm tra session logs trong `~/.mini/sessions/journal_*.jsonl`.
   - Đọc kỹ mã lỗi HTTP, `error_name` của Zig, `raw_snippet` từ server backend để tránh chẩn đoán cảm tính.

3. **Đối chiếu với RFC & Design Docs**:
   - Trước khi nhận định một hành vi là "lỗi" hay "tính năng", kiểm tra các tài liệu đề xuất tương ứng trong `docs/` (`rfc_001` đến `rfc_007`).
   - Đảm bảo các giải pháp đề xuất tuân thủ đúng định hướng kiến trúc Code-Centric (CodeAct VM) và Event Sourcing của dự án.

4. **Kiểm chứng đa tầng (Multi-tier Verification)**:
   - Tái hiện lỗi qua unit test nhỏ gọn trong `testcases/test_*.zig` nếu khả thi.
   - Sau khi sửa chữa, chạy toàn bộ bộ kiểm thử: `zig build test --summary all`.

---

## 2. Quy trình phân tích vấn đề chuẩn (Standard RCA Workflow)

```
[1. Tiếp nhận & Định nghĩa]
       │
       ▼
[2. Khảo sát & Thu thập dữ liệu]
   ├── Đọc log session: ~/.mini/sessions/journal_*.jsonl
   ├── Grep tìm kiếm vị trí liên quan trong src/
   └── Đọc RFC / Specs trong docs/
       │
       ▼
[3. Xây dựng giả thuyết & Tracing luồng]
   ├── Mapping call-stack từ Entry Point -> Core -> Runtime -> Backends
   └── Xác định điểm gãy (Breaking Point / Race Condition / Memory Leak)
       │
       ▼
[4. Kiểm chứng giả thuyết]
   ├── Tạo testcase tái hiện hoặc trace mã nguồn chi tiết
   └── Đối chiếu ràng buộc Zig 0.16.0 (memory, threading, I/O)
       │
       ▼
[5. Đề xuất giải pháp & Thực thi]
   └── Sửa chữa tối thiểu, bảo toàn comments/quy ước hiện hữu
```

---

## 3. Bản đồ thành phần kỹ thuật cần chú ý khi debug

- **Agent Core Loop**: `src/core/agent.zig` (vòng lặp act, phân loại lỗi HTTP, journaling, compaction).
- **CodeAct VM & JS Bindings**: `src/runtime/quickjs_engine.zig`, `src/runtime/js_bindings.zig`.
- **Backends & Adapters**: `src/backends/openai.zig`, `src/backends/claude.zig`, `src/backends/ollama.zig`.
- **UI & Terminal Stream**: `src/ui/chat_stream.zig`, `src/ui/repl.zig`, `src/ui/editor.zig`.
- **Memory & History**: `src/core/history.zig`, `src/core/memact/`.
