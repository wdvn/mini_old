# RFC-005: Chuẩn thư mục `.agent/` trong workspace cho mini-agent

| Thuộc tính | Giá trị |
|---|---|
| RFC | 005 |
| Tên | Chuẩn thư mục `.agent/` — vùng chứa cấu hình, skills, state của agent trong workspace |
| Trạng thái | Draft — chờ review |
| Phiên bản | 0.1 |
| Phụ thuộc | RFC-004 (Áp dụng chuẩn AGENTS.md) |
| Tham chiếu | Không có chuẩn công khai `.agent` (xác minh 22/08/2026: agents.md spec, opencode, fx đều không định nghĩa thư mục này). RFC này tự định nghĩa convention cho mini. Tham khảo cấu trúc `~/.fx/sessions/<session-id>/` của [vercel-labs/fx](https://github.com/vercel-labs/fx) cho phần state portable. |
| Tác giả | mini-agent |
| Ngày | 22/08/2026 |

---

## 1. Vấn đề (Motivation)

### 1.1. Hiện trạng

Mini hiện rải state và cấu hình của agent ở nhiều nơi không thống nhất:

- **AGENTS.md** (RFC-004): hướng dẫn cho agent nằm ở root, file lẻ.
- **Skills**: tool `skills` (src/tooling/registry.zig) chỉ liệt kê tool registry built-in — không có cơ chế user-defined skills (kịch bản/tool mở rộng do người dùng viết).
- **Slash commands**: hardcode trong `handleSlashCommand()` (src/ui/repl.zig:56) — người dùng không định nghĩa lệnh riêng cho project được.
- **Artifacts**: `src/core/artifacts.zig` chỉ in-session — mất khi thoát, không có nơi lưu bền vững theo project.
- **History/logs session**: không có quy ước lưu trữ theo workspace.

### 1.2. Vì sao cần thư mục `.agent/`

- **Tập trung**: một nơi duy nhất cho mọi thứ agent tạo/đọc trong workspace: cấu hình, skills, output, state.
- **Khác biệt với AGENTS.md**: AGENTS.md chỉ là *instructions* (văn bản hướng dẫn, chuẩn mở cho mọi agent). `.agent/` là *runtime data* — cấu hình và state cụ thể của mini. Hai thứ bổ sung nhau, không thay thế nhau.
- **Git-friendly**: `.agent/` chứa cả phần commit (skills, cấu hình dùng chung cho team) và phần ignore (state, output runtime). Phân tách rõ qua `.agent/.gitignore` mặc định.
- **Nhất quán với hệ sinh thái**: cùng triết lý `.git/`, `.vscode/`, `.idea/` — thư mục dot ở root do tool sở hữu và quản lý.

### 1.3. Lưu ý về tính chuẩn hóa

**Không tồn tại chuẩn công khai `.agent`** (đã kiểm tra: agents.md chỉ định nghĩa file `AGENTS.md`; opencode dùng `.opencode/` riêng; fx không dùng thư mục `.agent`). Đây là **convention riêng của mini**, đặt tên `.agent` vì:
- Ngắn, chung chung, không dính thương hiệu → dễ cho agent khác adopt nếu muốn.
- Thống nhất với AGENTS.md (file instructions) → agent tìm `.agent/` ngay cạnh AGENTS.md.

Nếu tương lai có chuẩn cộng đồng trùng tên, mini sẽ review lại tên gọi.

---

## 2. Thiết kế (Design)

### 2.1. Cấu trúc thư mục

```
.agent/
├── AGENTS.md          # Instructions riêng cho mini (RFC-004, open format) — commit
├── .gitignore         # Mặc định: ignore state/ và output/ — commit
├── config.toml        # Cấu hình project-level: model, backends, permissions — commit (không chứa secrets)
├── skills/            # User-defined skills — commit
│   ├── deploy.md      #   Mỗi skill = 1 file markdown (name, description, body)
│   └── review.md
├── commands/          # User-defined slash commands — commit
│   └── commit.md      #   Mỗi command = 1 file markdown → /commit
├── state/             # Runtime state — KHÔNG commit (gitignore mặc định)
│   ├── session.json   #   Session hiện tại: model, context window, metadata
│   ├── history.jsonl  #   Lịch sử hội thoại (append-only)
│   └── jobs/          #   Background jobs: pid, log path, status
└── output/            #   Artifacts bền vững — KHÔNG commit (tuỳ chọn)
    └── walkthrough.md
```

### 2.2. Quy ước chi tiết

#### AGENTS.md lồng nhau (nested)

- `.agent/AGENTS.md`: instructions mức agent-runtime (cách mini hành xử trong project này: tool preferences, escalation rules).
- AGENTS.md ở root vẫn được ưu tiên đọc theo RFC-004 — không thay đổi.
- Agent đọc cả hai: root trước (project-wide), `.agent/` sau (mini-specific).

#### Skills (markdown-driven)

Mỗi file `.agent/skills/<name>.md` có front-matter tối giản:

```markdown
---
name: deploy
description: Triển khai mini lên server staging
---
Nội dung: các bước agent cần làm khi được yêu cầu deploy...
```

- Tool `skills` mở rộng: liệt kê cả built-in tools lẫn user skills.
- Agent match skill theo description khi user yêu cầu ("deploy giùm" → skill `deploy`).
- Không tách parser front-matter phức tạp: chỉ cần `name:`, `description:` ở 2 dòng đầu sau `---`.

#### Slash commands mở rộng

- `.agent/commands/<name>.md` → đăng ký `/name` động trong REPL, ưu tiên sau built-in.
- Body là prompt template, hỗ trợ placeholder `$ARGUMENTS`, `$1`...`$9`.

#### State portable (tham khảo fx)

fx lưu session theo `~/.fx/sessions/<session-id>/` với workspace_root tham chiếu — session portable giữa máy. Mini chọn hướng **ngược lại**: state nằm **trong workspace** (`.agent/state/`) vì:
- Dùng mini trên nhiều máy qua git → lịch sử hội thoại đi theo repo (nếu user chủ động bỏ gitignore).
- Đơn giản hoá discovery: không cần mapping workspace ↔ session global.
- Trade-off: state không commit theo mặc định; ai muốn portable thì remove dòng ignore.

> **Phân công với RFC-003**: `.agent/state/history.jsonl` là **raw conversation history** (append-only, phục vụ resume/audit session). **Memory** (semantic/episodic/project_state đã extract) vẫn theo RFC-003: `MINI_MEMACT_MEMORY_DIR` (default `~/.mini/memory/<project_hash>/`). Không gộp hai thứ này — history là log thô, memory là kiến thức đã chưng cất. `.agent/state/session.json` lưu `context_window` snapshot của backend đang dùng (nguồn auto-detect theo RFC-003 §5).

#### Phân tách commit/ignore

`.agent/.gitignore` mặc định (mini tự tạo lần đầu chạy):

```gitignore
state/
output/
```

→ Team commit AGENTS.md, config.toml, skills/, commands/; state cá nhân không đẩy lên.

### 2.3. Discovery & fallback

1. Tìm `.agent/` từ cwd đi lên đến root thư mục (giống cách git tìm `.git/`).
2. Không tìm thấy → tạo ngầm + seed `.gitignore` mặc định (không tạo AGENTS.md — RFC-004 khuyến khích user tự viết).
3. Cấu hình merge order: built-in defaults → `~/.config/mini/` (global) → `.agent/config.toml` (project) → flags CLI.

---

## 3. Lộ trình (Roadmap)

| Phase | Nội dung | Độ phức tạp |
|---|---|---|
| 1 | Discovery `.agent/` + tạo seed `.gitignore` + đọc `.agent/AGENTS.md` vào system prompt | Thấp |
| 2 | `config.toml` project-level, merge vào Config hiện có | Trung bình |
| 3 | Skills markdown: parser front-matter, mở rộng tool `skills`, match description | Trung bình |
| 4 | Slash commands động từ `.agent/commands/` | Trung bình |
| 5 | State bền vững: session.json, history.jsonl trong `.agent/state/` (thay artifact in-session) | Cao |

Phase 1-2 không phá vỡ gì; Phase 3-5 thay đổi hành vi tool `skills`, REPL, artifacts — cần test retro.

---

## 4. Rủi ro & đáp ứng

| Rủi ro | Đáp ứng |
|---|---|
| Trùng tên chuẩn tương lai | Ghi rõ đây là convention riêng; sẵn sàng rename qua migration script |
| User không muốn thư mục mới trong repo | Opt-out qua config `agent_folder = false`; chỉ tạo khi cần ghi state |
| State trong workspace làm bẩn git | `.gitignore` seed mặc định bỏ qua state/, output/ |
| Skills markdown tăng surface attack (prompt injection qua skill file) | Skills chỉ được nạp từ workspace hiện tại; cảnh báo khi skill yêu cầu chạy tool nguy hiểm |
| Front-matter parser tự chế không tương thích | Giữ tối giản (2 field), không hug chuẩn YAML đầy đủ |

---

## 5. Câu hỏi mở

1. State nên nằm trong workspace (`.agent/state/`) hay global (`~/.local/state/mini/<workspace-hash>/`) như fx? Hiện đề xuất in-workspace — cần thảo luận.
2. `.agent/config.toml` có nên hỗ trợ secrets (API keys) hay bắt buộc env vars? Hiện đề xuất cấm secrets trong config commit.
3. Có nên đặt tên `.mini/` thay vì `.agent/` để tránh nhầm là chuẩn công khai? Câu hỏi đặt ra cho review.
