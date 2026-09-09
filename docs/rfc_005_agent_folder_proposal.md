# RFC-005: Chuẩn thư mục `.agent/` trong workspace cho mini-agent

| Thuộc tính | Giá trị |
|---|---|
| RFC | 005 |
| Tên | Chuẩn thư mục `.agent/` — vùng chứa cấu hình, skills của agent trong workspace |
| Trạng thái | **Implemented / Production** — Thư mục `.agent/` (`AGENTS.md`, `skills/`, `commands/`) và skills discovery loader đã hoạt động chính thức |
| Phiên bản | 0.3 — bỏ format skill tự chế, chuyển sang chuẩn Agent Skills (agentskills.io); tách state ra khỏi phạm vi |
| Phụ thuộc | RFC-004 (Áp dụng chuẩn AGENTS.md) |
| Tham chiếu | Không có chuẩn công khai `.agent` (xác minh 22/08/2026: agents.md spec, opencode, fx đều không định nghĩa thư mục này). RFC này tự định nghĩa convention cho mini. Skills tuân theo chuẩn mở [Agent Skills](https://agentskills.io/specification) (agentskills.io) — xem §2.2. Tham khảo cấu trúc thư mục dot của [vercel-labs/fx](https://github.com/vercel-labs/fx) về cách tổ chức folder theo tool. |
| Tác giả | mini-agent |
| Ngày | 22/08/2026 |

---

## 1. Vấn đề (Motivation)

### 1.1. Hiện trạng

Mini hiện rải cấu hình của agent ở nhiều nơi không thống nhất:

- **AGENTS.md** (RFC-004): hướng dẫn cho agent nằm ở root, file lẻ.
- **Skills**: `src/core/skills.zig` đã nạp skills theo chuẩn Agent Skills (agentskills.io) nhưng chỉ từ `~/.mini/skills/` (global) — project không có chỗ đặt skill dùng chung cho team.
- **Slash commands**: hardcode trong `handleSlashCommand()` (src/ui/repl.zig:56) — người dùng không định nghĩa lệnh riêng cho project được.
- **Artifacts**: `src/core/artifacts.zig` chỉ in-session — mất khi thoát, không có nơi lưu bền vững theo project.

State runtime (session, history, background jobs) **không thuộc phạm vi RFC này** — xem phân công ở §2.2.

### 1.2. Vì sao cần thư mục `.agent/`

- **Tập trung**: một nơi duy nhất cho cấu hình và skills của agent trong workspace.
- **Khác biệt với AGENTS.md**: AGENTS.md chỉ là *instructions* (văn bản hướng dẫn, chuẩn mở cho mọi agent). `.agent/` là *cấu hình runtime* — cấu hình cụ thể của mini. Hai thứ bổ sung nhau, không thay thế nhau.
- **Git-friendly**: `.agent/` chứa phần commit (skills, cấu hình dùng chung cho team) và phần output runtime (tuỳ chọn ignore). Phân tách rõ qua `.agent/.gitignore` mặc định.
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
├── .gitignore         # Mặc định: ignore output/ — commit
├── config.json        # Cấu hình project-level: model, backends, permissions — commit (không chứa secrets)
├── skills/            # User-defined skills — commit (chuẩn agentskills.io)
│   ├── deploy/        #   Mỗi skill = 1 thư mục con, tối thiểu chứa SKILL.md
│   │   ├── SKILL.md   #     Required: frontmatter YAML (name, description) + instructions
│   │   └── scripts/   #     Optional: script thực thi
│   └── review/
│       └── SKILL.md
├── commands/          # User-defined slash commands — commit
│   └── commit.md      #   Mỗi command = 1 file markdown → /commit
└── output/            #   Artifacts bền vững — KHÔNG commit (tuỳ chọn)
    └── walkthrough.md
```

### 2.2. Quy ước chi tiết

#### AGENTS.md lồng nhau (nested)

- `.agent/AGENTS.md`: instructions mức agent-runtime (cách mini hành xử trong project này: tool preferences, escalation rules).
- AGENTS.md ở root vẫn được ưu tiên đọc theo RFC-004 — không thay đổi.
- Agent đọc cả hai: root trước (project-wide), `.agent/` sau (mini-specific).

#### Skills (chuẩn Agent Skills — agentskills.io)

Skill trong `.agent/skills/` tuân theo **đúng chuẩn mở Agent Skills** (xác minh 22/08/2026, [specification](https://agentskills.io/specification)) — cùng chuẩn mà layer global `~/.mini/skills/` (`src/core/skills.zig`) đang dùng. Mini không tự chế format skill riêng.

Một skill = **một thư mục con** chứa tối thiểu `SKILL.md`:

```
.agent/skills/deploy/
├── SKILL.md          # Required: YAML frontmatter + markdown instructions
├── scripts/          # Optional: code thực thi (bash, python, js...)
├── references/       # Optional: tài liệu tham khảo (agent đọc khi cần)
└── assets/           # Optional: template, tài nguyên tĩnh
```

`SKILL.md` bắt buộc có YAML frontmatter:

```markdown
---
name: deploy
description: Triển khai mini lên server staging. Use when user yêu cầu deploy, push bản build lên staging.
---
Nội dung: các bước agent cần làm khi được yêu cầu deploy...
```

Ràng buộc theo spec (mini validate khi nạp):

| Field | Bắt buộc | Ràng buộc |
|---|---|---|
| `name` | Yes | 1–64 ký tự, lowercase `a-z 0-9` + hyphen, không hyphen đầu/cuối/liên tiếp, **phải trùng tên thư mục cha** |
| `description` | Yes | 1–1024 ký tự, mô tả cả *what* lẫn *when to use* |
| `license` | No | Tên license hoặc file license bundled |
| `compatibility` | No | ≤500 ký tự, yêu cầu môi trường (product, packages, network) |
| `metadata` | No | Map string→string tuỳ ý |
| `allowed-tools` | No | Space-separated tools được pre-approve (experimental) |

Điểm khác so với thiết kế v0.1 (file lẻ `skills/<name>.md` tự chế):
- Skill là **thư mục** bundle (SKILL.md + scripts + references + assets), không phải 1 file markdown — cho phép skill kèm code và tài nguyên.
- Tên skill lấy từ frontmatter và **phải khớp tên thư mục** — spec check.
- Tái dùng nguyên `parseSkillFile()` của `src/core/skills.zig` (parse `name`/`description`, fallback tên thư mục) — chỉ thêm nguồn quét `.agent/skills/` cạnh `~/.mini/skills/`.

**Progressive disclosure** (theo spec): prompt chỉ nạp `name` + `description` (~50 token/skill, tối đa 32 skills, description ≤512 bytes — giới hạn hiện có của mini); body SKILL.md (<500 dòng khuyến nghị) chỉ nạp khi skill được kích hoạt; `scripts/`/`references/` chỉ đọc khi task cần.

#### Slash commands mở rộng

- `.agent/commands/<name>.md` → đăng ký `/name` động trong REPL, ưu tiên sau built-in.
- Body là prompt template, hỗ trợ placeholder `$ARGUMENTS`, `$1`...`$9`.

#### Phân công scope với RFC-002 & RFC-003 (state & memory)

State runtime của mini **không nằm trong `.agent/`**. Phân công:

| Loại state | Nơi lưu | RFC chủ quản |
|---|---|---|
| Raw conversation history (append-only, resume/audit session) | `~/.mini/sessions/` (hiện trạng, giữ nguyên) | RFC-002 |
| Memory đã extract (semantic/episodic/project_state) | `MINI_MEMACT_MEMORY_DIR` (default `~/.mini/memory/<project_hash>/`) | RFC-003 |
| Background jobs (pid, log path, status) | `~/.mini/` (hiện trạng, giữ nguyên) | — |
| Artifacts bền vững theo project | `.agent/output/` | RFC-005 (thư mục này) |

Lý do tách state khỏi `.agent/`:
- Session/history gắn với máy và user, không gắn với repo — commit theo workspace vô ích và dễ lộ nội dung nhạy cảm (log hội thoại chứa cả nội dung file đã đọc).
- RFC-003 đã định nghĩa memory layout theo `project_hash` global; thêm nơi lưu state thứ hai trong workspace gây trùng lặp cơ chế discovery.
- `.agent/` giữ đúng một trách nhiệm: **cấu hình + skills + output dùng chung theo project**.
- Tham khảo fx: fx lưu session portable trong `~/.fx/sessions/<session-id>/` — mini cũng chọn hướng global (qua `~/.mini/`), không in-workspace.

#### Phân tách commit/ignore

`.agent/.gitignore` mặc định (mini tự tạo lần đầu chạy):

```gitignore
output/
```

→ Team commit AGENTS.md, config.json, skills/, commands/; output runtime không đẩy lên.

### 2.3. Discovery & fallback

1. Tìm `.agent/` từ cwd đi lên đến root thư mục (giống cách git tìm `.git/`).
2. Không tìm thấy → tạo ngầm + seed `.gitignore` mặc định (không tạo AGENTS.md — RFC-004 khuyến khích user tự viết).
3. Cấu hình merge order: built-in defaults → `~/.config/mini/` (global) → `.agent/config.json` (project) → flags CLI.
4. Skills discovery order: `~/.mini/skills/` (global, user cá nhân) → `.agent/skills/` (project, team dùng chung). Trùng `name` → project override global.

---

## 3. Lộ trình (Roadmap)

| Phase | Nội dung | Độ phức tạp |
|---|---|---|
| 1 | Discovery `.agent/` + tạo seed `.gitignore` + đọc `.agent/AGENTS.md` vào system prompt | Thấp |
| 2 | `config.json` project-level, merge vào Config hiện có | Trung bình |
| 3 | Skills theo chuẩn agentskills.io: mở rộng `loadSkills()` quét thêm `.agent/skills/*/SKILL.md`, validate spec (name khớp thư mục, giới hạn độ dài) | Trung bình |
| 4 | Slash commands động từ `.agent/commands/` | Trung bình |

Phase 1-2 không phá vỡ gì; Phase 3-4 thay đổi hành vi tool `skills`, REPL — cần test retro. Artifacts bền vững vào `.agent/output/` làm sau, không chặn phase nào.

---

## 4. Rủi ro & đáp ứng

| Rủi ro | Đáp ứng |
|---|---|
| Trùng tên chuẩn tương lai | Ghi rõ đây là convention riêng; sẵn sàng rename qua migration script |
| User không muốn thư mục mới trong repo | Opt-out qua config `agent_folder = false`; chỉ tạo khi cần ghi output |
| User nhầm `.agent/` chứa state/session | Đã tách state ra khỏi `.agent/` (xem §2.2); docs + tên thư mục con rõ ràng |
| Skills markdown tăng surface attack (prompt injection qua skill file) | Skills chỉ được nạp từ workspace hiện tại; cảnh báo khi skill yêu cầu chạy tool nguy hiểm |
| Skill không conform spec agentskills.io (name lệch thư mục, description quá dài) | Validate khi nạp: bỏ qua + cảnh báo, không crash; schema đơn giản (flat YAML) không cần thư viện YAML đầy đủ |

---

## 5. Câu hỏi mở

1. `.agent/config.json` có nên hỗ trợ secrets (API keys) hay bắt buộc env vars? Hiện đề xuất cấm secrets trong config commit.
2. **Quyết định định dạng file config**: Sử dụng `config.json` thay vì `config.toml` để sử dụng `std.json` có sẵn trong Zig 0.16.0 standard library, tránh kéo thêm external TOML dependency (tuân thủ quy ước thiết kế trong `AGENTS.md`).
2. Có nên đặt tên `.mini/` thay vì `.agent/` để tránh nhầm là chuẩn công khai? Câu hỏi đặt ra cho review.
