---
name: technical-rfc-review
description: Nghiên cứu tài liệu thiết kế (RFC, proposals), đối chiếu giữa spec kỹ thuật và code hiện tại để tìm khoảng trống (gap analysis) hoặc bất cập kiến trúc. Use when cần đánh giá proposal, kiểm tra độ tương thích thiết kế hoặc chuẩn bị RFC mới.
---

# Technical RFC & Architecture Review Skill

Hướng dẫn quy trình đối chiếu, đánh giá và xây dựng các đề xuất kiến trúc (RFC) trong thư mục `docs/`.

---

## 1. Khi nào kích hoạt Skill này?

- Khi chuẩn bị phát triển tính năng lớn cần mở Proposal trước theo quy ước trong `AGENTS.md`.
- Khi cần đối chiếu code hiện tại xem đã bám sát đúng thiết kế RFC gốc chưa.
- Khi cần làm rõ các quyết định kiến trúc (Arch Decisions: CodeAct vs Tool Calling, Event Sourcing, MemAct, ACP...).

---

## 2. Danh mục RFC hiện hữu trong `docs/`

| File | Tên đề xuất | Trọng tâm kỹ thuật |
|---|---|---|
| `rfc_000_editor_upgrade_proposal.md` | Line Editor Upgrade | Terminal input, multiline composer, UTF-8, ANSI escape |
| `rfc_001_code_centric_architecture_proposal.md` | Code-Centric Architecture | Nhúng QuickJS VM, API `mini.*`, eval loop |
| `rfc_002_long_horizon_event_sourcing_proposal.md` | Event Sourcing & CAS | Act Journal (`journal_*.jsonl`), CAS snapshot rollback |
| `rfc_003_memact_context_memory_proposal.md` | MemAct Context Memory | Token estimator, hierarchical memory, context compact |
| `rfc_004_agents_md_standard_proposal.md` | AGENTS.md Standard | Quy ước hướng dẫn cho AI agent trong repo |
| `rfc_005_agent_folder_proposal.md` | `.agent/` Folder Standard | Quản lý config, skills (`agentskills.io`), commands |
| `rfc_006_openai_compat_response_standardization_proposal.md` | OpenAI-Compat Response Std | Chuẩn hóa SSE streaming parser, tool call delta merge |
| `rfc_007_repl_chat_stream_ui_proposal.md` | REPL Chat Stream UI | TurnRenderer, live spinner TTFT, Markdown stream |

---

## 3. Khung đánh giá Gap Analysis (Spec vs Implementation)

Khi kiểm tra một tính năng:
1. **Kiểm tra Spec**: Đọc phần "Thiết kế chi tiết" trong file RFC tương ứng.
2. **Kiểm tra Code**: Tìm file implementation trong `src/`.
3. **Đối chiếu sai lệch**:
   - Có thiếu API nào được mô tả trong RFC không?
   - Định dạng dữ liệu (JSON/JSONL) có khớp schema spec không?
   - Quản lý bộ nhớ (Alloc/Free, Arena) có đúng phạm vi lifecycle không?
   - Concurrency & Thread safety: các thao tác đa luồng có vi phạm nguyên tắc Zig 0.16 không?
