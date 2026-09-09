# RFC-004: Áp dụng chuẩn AGENTS.md cho mini-agent

| Thuộc tính | Giá trị |
|---|---|
| RFC | 004 |
| Tên | Áp dụng chuẩn AGENTS.md (open format cho coding agents) |
| Trạng thái | **Implemented / Production** |
| Phiên bản | 0.1 |
| Phụ thuộc | Không phụ thuộc RFC khác (độc lập) |
| Tham chiếu | [agents.md](https://agents.md) — open format, 60k+ OSS projects |
| Tác giả | mini-agent |
| Ngày | 22/08/2026 |

---

## 1. Vấn đề (Motivation)

### 1.1. Hiện trạng

- Repo `mini` có `README.md` hướng dẫn cho **con người**: cài đặt, tính năng, ví dụ.
- Không có nguồn hướng dẫn **dành riêng cho coding agents** (mini-agent tự chạy trên chính nó, Codex, Jules, Cursor, Claude Code...): lệnh build/test, quy ước code, lưu ý kiến trúc.
- Agents phải tự đoán hoặc đọc toàn bộ README → tốn context window, dễ bỏ sót quy ước (ví dụ: comment tiếng Việt, không thêm dependency ngoài proposal, file test phải đặt trong `testcases/test_*.zig`).

### 1.2. Tại sao chọn AGENTS.md

| Tiêu chí | AGENTS.md | README.md | `.cursorrules` / CLAUDE.md |
|---|---|---|---|
| Được nhiều agent hiểu | ✅ Codex, Jules, Cursor, Zed, Warp, VS Code, Devin, Aider, goose... | ⚠️ Agent phải tự đọc | ❌ Chỉ 1 agent |
| Open format, không proprietary | ✅ | ✅ | ❌ |
| Tách hướng dẫn agent / người | ✅ "README for agents" | ❌ Trộn lẫn | ✅ |
| Hỗ trợ nested theo thư mục | ✅ root + subfolder | ✅ | ⚠️ |
| Không yêu cầu schema | ✅ Markdown tự do | — | — |

Chuẩn: đặt file `AGENTS.md` ở root repo. Agent khi làm việc trong thư mục nào sẽ đọc `AGENTS.md` gần nhất (root cho toàn repo, có thể override bằng file trong subfolder). Nội dung nên gồm: **setup commands**, **code style**, **conventions**, **lưu ý kiến trúc**, **testing** — chính xác những gì agent cần và không có trong README.

## 2. Thiết kế

### 2.1. File đã tạo

`AGENTS.md` ở root (59 dòng), cấu trúc theo khuyến nghị của agents.md:

```markdown
# mini — Hướng dẫn cho coding agents
## Tổng quan          → 2 dòng: Zig 0.16 + CodeAct, kiến trúc Code-Centric
## Layout src/        → core, runtime, tools, tooling, ui, backends, acp
## Build & Run        → zig build / zig build test / zig build run / scripts/build_release.sh
## Quy ước code       → comment tiếng Việt, doc-comment //!, không thêm dependency ngoài proposal
## Lưu ý kiến trúc    → JS VM path, protocol conformance, editor upgrade, SQLite reserve
## Testing            → zig build test, test UTF-8 thủ công, không gọi API thật
## PR / Commit        → format `module: mô tả`, không commit scratch/zig-cache/zig-out
```

### 2.2. Quy tắc nội dung

- **Ngắn, chính xác, có thể thực thi**: mỗi mục là lệnh chạy được hoặc quy tắc check được. Không lan man marketing (đó là việc của README).
- **Không trùng lặp README**: chỉ những gì agent cần — README không nhắc (quy ước comment, file scratch `test*.zig`, đường dẫn proposals).
- **Tham chiếu chéo docs/**: quy tắc "mở proposal trước khi thêm dependency" trỏ về `docs/*_proposal.md`; mục editor trỏ về `docs/editor_upgrade_proposal.md`.
- **Ngôn ngữ**: tiếng Việt (đồng nhất toàn repo), tên lệnh/đường dẫn giữ nguyên tiếng Anh.

### 2.3. Đồng bộ với hệ thống proposal của repo

Quy ước mới được ghi vào AGENTS.md: *"Proposals/design docs đặt ở `docs/`, tên file snake_case: `*_proposal.md`"* — RFC-004 này tuân theo chính quy tắc đó.

## 3. Lộ trình

- [x] **Phase 0** — Tạo `AGENTS.md` root (done).
- [ ] **Phase 1** — Review nội dung bởi maintainer, chốt v0.1.
- [ ] **Phase 2** (optional) — Nested `AGENTS.md` cho subfolder phức tạp khi chúng to lên (ví dụ `src/runtime/AGENTS.md` mô tả chi tiết JS bindings), chỉ làm khi độ phức tạp thực sự cần.
- [x] **Phase 3** (optional) — mini-agent tự động đọc `AGENTS.md` của project đích khi chạy trong workspace người dùng (tích hợp vào system prompt / context bootstrapping). Đây là điểm nâng giá trị lớn nhất: mini vừa **tuân thủ** chuẩn (có AGENTS.md riêng), vừa **tiêu thụ** chuẩn khi làm việc trên repo khác. *Ghi chú: nội dung AGENTS.md khi nạp vào system prompt thuộc tier **PINNED** theo mô hình context của RFC-003 (như future work `MINI.md` của RFC-003 đã dự kiến).*

## 4. Rủi ro & lưu ý

| Rủi ro | Giảm thiểu |
|---|---|
| AGENTS.md lỗi thời khi kiến trúc đổi (ví dụ sau editor upgrade Phase 1–3) | Ghi vào checklist mỗi RFC mới: cập nhật AGENTS.md nếu thay đổi build/quy ước |
| Trùng lặp nội dung với README gây phân kỳ | Nguyên tắc: AGENTS.md không copy README; nếu thấy trùng, rút gọn còn 1 dòng trỏ tham chiếu |
| File quá dài làm tốn context | Giữ < 100 dòng; chi tiết đẩy về docs/*.md và link |
| Chuẩn agents.md còn non-formal (Markdown tự do, không schema) | Đây là chủ ý của chuẩn — không cần validate, giữ Markdown đơn giản |

## 5. Out of scope

- Định nghĩa schema/validator cho AGENTS.md — chuẩn cố ý không có.
- Tích hợp nhiều file config theo agent (.cursorrules, CLAUDE.md...) — chỉ giữ 1 nguồn sự thật là AGENTS.md.
- Đa ngôn ngữ (EN bản sao) — không cần ở giai đoạn này.
