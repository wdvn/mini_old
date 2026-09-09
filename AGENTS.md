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
- `zig build test` → All-In-One test suite (Unit tests + Testcases + Mock LLM E2E).
- `zig build test-unit` → Chạy riêng unit tests & testcases (không cần Node.js/mock server).
- `zig build test-e2e` → Chạy riêng E2E tests với mock LLM server.
- `zig build test -Dskip-e2e=true` → Chạy test bỏ qua tầng E2E mock.
- `zig build test -Dtest-port=<port>` → Đổi port cho mock server (mặc định: 8399).
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
- **Per-Act VM Isolation**: Mỗi Act khởi tạo một `JSContext` độc lập để triệt tiêu ô nhiễm scope biến toàn cục (`const`/`let`) giữa các turns.
- **MemAct Reactive Compaction**: Nén ngữ cảnh dạng reactive-only (chỉ kích hoạt khi backend trả lỗi vượt context limit, drop-all + dồn summary tại index 1, bảo tồn prompt gốc index 0).
- **Dual-Protocol Auto-Negotiation**: Tự động chuyển đổi và nhớ protocol giữa Chat Completions API và Responses API cho OpenAI-compatible endpoints.
- **Execution & Stopping Rules**: Agent tuân thủ 4 quy tắc dừng (Stop on Completion, Confirm Before Mutation, Avoid Action Loops, Progress Checkpoint).
- Backends đều conform `core/protocol.zig`; không gọi HTTP trực tiếp trong agent loop.
- Editor (`ui/editor.zig`) hỗ trợ incremental bracketed paste parser (`ui/paste.zig`), UTF-8 width, single-line byte-based (lộ trình FSM multiline composer tại `docs/rfc_008_user_input_state_machine_proposal.md`).
- History persistence dự kiến dùng SQLite (libsqlite3 đã reserve trong build.zig).

## Testing

- **Lệnh chuẩn trước khi commit**: Chạy `zig build test` (hoặc `zig build test --summary all`), phải pass toàn bộ 13/13 steps (159 tests passed, 4 skipped).
- **Cơ chế All-In-One**:
  1. *Tầng 1 (Unit tests)*: Test toàn bộ module trong `src/main.zig` (118 tests: 114 passed, 4 skipped).
  2. *Tầng 2 (Integration testcases)*: Test CodeAct VM isolation, security blocklist/allowlist, hooks, CAS file snapshot (`testcases/test_codeact_security.zig` — 45 tests).
  3. *Tầng 3 (E2E Mock LLM)*: Tự build binary `mini`, khởi chạy `node scripts/mock_llm_server.js` độc lập trên port 8399 và test 3 flow hoàn chỉnh (`simple text`, `long text streaming`, `tool call bash multi-turn`).
- **Tùy chọn linh hoạt**:
  - Khi môi trường thiếu Node.js hoặc chỉ muốn test nhanh: `zig build test-unit` hoặc `zig build test -Dskip-e2e=true`.
  - Khi chỉ muốn test riêng E2E: `zig build test-e2e`.
  - Đổi port mock server khi xung đột: `zig build test -Dtest-port=8400`.
- **UI/editor**: Test thủ công qua `zig build run`, kiểm tra gõ UTF-8 (tiếng Việt), bracketed paste, Ctrl+A/E/U, ↑/↓ history.
- **Backends**: Không gọi API thật khi test; kiểm tra logic parse SSE bằng unit test và mock server nội bộ.

## PR / Commit

- Commit message tiếng Anh hoặc tiếng Việt, format: `module: mô tả ngắn` (ví dụ `editor: add word motion keybindings`).
- Không commit file scratch test ngoài các file test trong `testcases/` đã có, không commit `zig-cache/`, `zig-out/`.
