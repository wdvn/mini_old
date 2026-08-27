# AGENTS.md

Hướng dẫn cho AI coding agents làm việc trên repo **mini-agent**. Đọc file này trước khi sửa code.

## Tổng quan project

- **Ngôn ngữ**: Zig 0.16.0, thư viện chuẩn only (ngoại lệ: libcurl dynamic link, CodeAct static link).
- **Loại**: AI agent chạy terminal, kiến trúc Code-Centric (agent viết JS chạy trong CodeAct VM nhúng, gọi tool qua object `mini.*`).
- **Layout**:

```
src/
  main.zig            — entry point, REPL wiring
  core/               — agent loop, config, history, hooks, protocol, JSON utils
  runtime/            — CodeAct engine, JS bindings (mini.*), process manager (background jobs)
  tools/              — tool implementations (bash, file, glob, grep, http, search, subagent, ...)
  tooling/            — MCP client, tool registry
  ui/                 — terminal UI: editor.zig (line editor), repl.zig
  backends/           — AI providers: openai.zig, claude.zig, ollama.zig, sse.zig
  acp/                — ACP server
docs/                 — proposals, technical docs (tiếng Việt)
scripts/build_release.sh
scripts/setup_home_mini.sh — Khởi tạo & sync skills/config cho ~/.mini
testcases/            — tất cả các file test (standalone, integration, benchmarks, ...)
```

## Build & Run

- `zig build` → binary `zig-out/bin/mini`.
- `zig build run` → build + chạy interactive REPL.
- `zig build run -- -e "..."` → single-shot mode.
- `zig build test` → unit tests (root `src/main.zig`, link CodeAct).
- Setup môi trường user: `scripts/setup_home_mini.sh` (tạo/sync `~/.mini/`).
- Release: `scripts/build_release.sh`.
- Cross-compile: `zig build -Dtarget=x86_64-linux-gnu` (hoặc `aarch64-linux-gnu`).

## Quy ước code

- Comment tiếng Việt, giữ style hiện có trong file đang sửa.
- Mỗi module `.zig` có doc-comment `//!` mô tả trách nhiệm ở đầu file.
- Không thêm dependency ngoài nếu chưa được thảo luận trong proposal — nếu cần, mở proposal trước.
- Tất cả các file test (scratch experiments, standalone test, benchmarks...) đều được đặt trong thư mục `testcases/` và phải có tên dạng `test_*.zig` (không để file test ở thư mục root).
- Proposals/design docs đặt ở `docs/`, format: `rfc_NNN_<tên>_proposal.md` (RFC đánh số tăng dần, snake_case; ví dụ `rfc_005_agent_folder_proposal.md`). Doc tham khảo/thuần kiến thức (không phải proposal) giữ tên snake_case thường.

## Lưu ý kiến trúc

- Tool calls ưu tiên đi qua JS VM (`runtime/js_bindings.zig`) thay vì thêm path JSON tool-calling mới.
- Backends đều conform `core/protocol.zig`; không gọi HTTP trực tiếp trong agent loop.
- Editor (`ui/editor.zig`) hiện là single-line byte-based — nâng cấp theo lộ trình trong `docs/editor_upgrade_proposal.md` (composer multiline, UTF-8 width, persistent history...).
- History persistence dự kiến dùng SQLite (libsqlite3 đã reserve trong build.zig).

## Testing

- Sau khi sửa core/tools/runtime: chạy `zig build test`, phải pass hết trước khi commit.
- Với UI/editor: test thủ công qua `zig build run`, kiểm tra gõ UTF-8 (tiếng Việt), Ctrl+A/E/U, ↑/↓ history.
- Với backends: không gọi API thật khi test; kiểm tra logic parse SSE bằng unit test.

## PR / Commit

- Commit message tiếng Anh hoặc tiếng Việt, format: `module: mô tả ngắn` (ví dụ `editor: add word motion keybindings`).
- Không commit file scratch test ngoài các file test trong `testcases/` đã có, không commit `zig-cache/`, `zig-out/`.
