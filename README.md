# mini-agent overview

AI agent chạy terminal, code-centric: agent tự viết JavaScript chạy trong CodeAct nhúng để gọi tools, thay vì gọi từng tool rời rạc

mini-agent là một AI agent dòng lệnh viết bằng Zig: nó nhận prompt, tự lập kế hoạch các bước, và thực thi bằng cách chạy shell, đọc/sửa file, gọi HTTP, tìm kiếm web hoặc điều khiển trình duyệt. Kết quả mỗi vòng được gửi lại model cho đến khi hoàn thành tác vụ; mọi thao tác đều chạy gọn trong một binary không cần runtime bên ngoài.

## Bạn cần gì?

| If you... | Use | Why |
|---|---|---|
| Chạy agent tương tác trong terminal | [REPL](#repl-tương-tác) | Vòng hội thoại streaming, slash commands, đổi backend tại chỗ |
| Chạy một prompt rồi thoát (script, cron) | [Single-shot](#single-shot) | Cờ `-e`/positional argument, exit ngay sau khi xong |
| Dùng agent bên trong Zed hoặc JetBrains | [ACP server](#acp-agent-client-protocol) | JSON-RPC 2.0 qua stdin/stdout theo chuẩn Agent Client Protocol |
| Nạp/lưu ngữ cảnh hội thoại giữa các lần chạy | [Session](#session-lưu-hội-thoại) | Tự động persist history ra file JSON, khôi phục ở lượt sau |
| Mở rộng khả năng bằng tool ngoài | [MCP](#mcp-model-context-protocol) | Kết nối MCP servers bất kỳ qua JSON-RPC stdio |
| Giám sát/audit mọi hành động của agent | [Hooks](#hooks-giám-sát--observability) | Script hook chạy tại mọi sự kiện lifecycle, tool call, streaming |

## Capability map

| Capability | What it does | Learn more |
|---|---|---|
| Backends AI | OpenAI-compatible (Chat Completions & Responses API), Anthropic Claude, Ollama local | [Backends AI](#backends-ai) |
| Built-in tools | 15 tools: shell, file, glob, grep, HTTP, subagents, artifacts, session diagnostics, skills, codeact | [Tools](#tools) |
| CodeAct runtime | Agent viết JS trong khối ```js``` chạy trên CodeAct nhúng, gọi API `mini.*` (Per-Act VM isolation) | [Execution modes](#execution-modes) |
| MemAct | Tự động nén ngữ cảnh (Reactive Compaction) khi vượt giới hạn context window | [MemAct & Context](#memact--context-management) |
| Workspace `.agent/` | Thư mục cấu hình cục bộ: instructions (`AGENTS.md`), project skills, custom slash commands | [Workspace .agent](#agent-workspace-folder) |
| Session persistence | Lưu/khôi phục hội thoại và audit journal (`journal_*.jsonl`) theo ID | [Session](#session-lưu-hội-thoại) |
| Hooks & Sidecars | Script hook tại mọi sự kiện lifecycle, tool call; tích hợp proxy router tối ưu latency/tps | [Hooks](#hooks-giám-sát--observability) |
| MCP | Dùng tool từ MCP servers ngoài qua stdio JSON-RPC | [MCP](#mcp-model-context-protocol) |
| ACP | Tích hợp vào Zed AI, JetBrains như external agent | [ACP](#acp-agent-client-protocol) |
| Artifacts | Xuất kế hoạch, báo cáo, HTML/SVG ra thư mục session, kích hoạt preview hook | [Tools](#tools) |
| Tool policy | Allowlist/blocklist kiểm soát tool nào được chạy (áp dụng cả JSON tool và JS bindings) | [Tool policy](#tool-policy) |
| Cron | Cài cronjob chạy single-shot định kỳ | [Cron](#cron-chạy-định-kỳ) |

## Quickstart

```bash
git clone <repo-url> && cd mini
zig build
./scripts/setup_home_mini.sh    # Khởi tạo thư mục ~/.mini và sync skills/config
./zig-out/bin/mini --version
```

Yêu cầu Zig 0.16.0:

```bash
curl -LO https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz
tar -xf zig-x86_64-linux-0.16.0.tar.xz
export PATH="$PWD/zig-x86_64-linux-0.16.0:$PATH"
```

Cấu hình backend (chọn một trong ba):

```bash
export OPENAI_COMPAT_URL=https://api.openai.com/v1
export OPENAI_COMPAT_API_KEY=sk-...

# hoặc Claude
export ANTHROPIC_API_KEY=sk-ant-...

# hoặc Ollama local (không cần key)
export OLLAMA_HOST=http://localhost:11434
```

Chạy:

```bash
./zig-out/bin/mini -e "Tóm tắt README.md của project này"
```

Chi tiết build: [Build](#build).

## Backends AI

Agent chọn backend theo thứ tự ưu tiên:

1. **OpenAI-compatible** — khi có `OPENAI_COMPAT_URL` (hỗ trợ cả Chat Completions API & Responses API với auto-negotiation)
2. **Anthropic Claude** — khi có `ANTHROPIC_API_KEY`
3. **Ollama** — fallback local

| Biến môi trường | Mô tả | Mặc định |
|---|---|---|
| `OPENAI_COMPAT_URL` | URL base API OpenAI-compatible | — |
| `OPENAI_COMPAT_MODEL` | Tên model | `gpt-4o-mini` |
| `OPENAI_COMPAT_API_KEY` | API key | — |
| `OPENAI_COMPAT_API_HEADER` | Tên HTTP header chứa key | `Authorization` |
| `OPENAI_PROTOCOL` | Giao thức OpenAI: `auto`, `chat_completions`, `responses` | `auto` |
| `ANTHROPIC_API_KEY` | Claude API key | — |
| `CLAUDE_MODEL` | Claude model ID | `claude-opus-4-5` |
| `OLLAMA_HOST` | URL Ollama server | `http://localhost:11434` |
| `OLLAMA_MODEL` | Tên model Ollama | `llama3` |

Đổi backend trong REPL bằng lệnh `/model <backend> [model]`, với `backend` nhận một trong ba giá trị `openai` | `claude` | `ollama`.

#### Dual-Protocol Auto-Negotiation (OpenAI & Responses API)

Với các model reasoning thế hệ mới (ví dụ GPT-5.x, o3-pro) đòi hỏi giao thức Responses API khi kết hợp reasoning với function calling:
- Khi để `OPENAI_PROTOCOL=auto`, `mini` tự động nhận diện prefix model hoặc tự thích ứng (fallback) giữa `/chat/completions` và `/responses` khi gặp lỗi HTTP 400.
- Ghi nhớ giao thức thành công trong phiên (Session Cache) để triệt tiêu độ trễ dò tìm ở các turn sau.

Ví dụ endpoint khác nhau:

```bash
# OpenRouter (nhiều model)
export OPENAI_COMPAT_URL=https://openrouter.ai/api/v1
export OPENAI_COMPAT_MODEL=anthropic/claude-3-5-sonnet

# LM Studio local
export OPENAI_COMPAT_URL=http://localhost:1234/v1
```

## Cấu hình

mini-agent đọc cấu hình từ biến môi trường. File `.env` được tự động nạp theo thứ tự:

1. `$MINI_ENV_FILE` — đường dẫn tường minh
2. `./.env` — thư mục làm việc hiện tại (project-level)
3. `~/.mini/.env` — user-level

> Biến đã có sẵn trong shell environment **không bị ghi đè** bởi file `.env`.

Cú pháp `.env` hỗ trợ khai báo `KEY=value` (có hoặc không có ngoặc đơn/kép), tiền tố `export`, và comment bằng `#`.

### Biến môi trường chung

| Biến | Mô tả | Mặc định |
|---|---|---|
| `MINI_HOME` | Thư mục gốc lưu config, sessions, artifacts, skills | `~/.mini` |
| `MINI_MAX_TOKENS` | Số token tối đa mỗi response | `8192` |
| `MINI_SYSTEM_FILE` | Đường dẫn file system prompt (`.md`) | — |
| `MINI_NO_HISTORY` | `"1"` để tắt lưu lịch sử hội thoại | — |
| `MINI_EXECUTION_MODE` | Chế độ thực thi: `codeact`, `tools`, `auto` | `auto` |
| `MINI_TOOL_ALLOWLIST` | Chỉ cho phép các tool này (comma-separated) | — |
| `MINI_TOOL_BLOCKLIST` | Chặn các tool này (comma-separated) | — |
| `MINI_MCP_CONFIG` | Đường dẫn file `mcp.json` | `<MINI_HOME>/mcp.json` |
| `MINI_HOOK_COMMAND` | Lệnh hook giám sát | — |
| `MINI_HOOKS_CONFIG` | Đường dẫn file cấu hình hooks (`hooks.json`) | — |
| `MINI_SESSION` | Session ID (lưu tại `<MINI_HOME>/sessions/<id>.json`) | — |
| `MINI_SESSION_FILE` | Đường dẫn file session JSON trực tiếp | — |
| `MINI_ENV_FILE` | Đường dẫn `.env` tường minh | — |
| `MINI_BUDGET_MAX_TOKENS` | Giới hạn tổng token tiêu thụ tối đa cho một task (RFC-002) | `0` (không giới hạn) |

### MemAct & Context Management (RFC-003)

| Biến | Mô tả | Mặc định |
|---|---|---|
| `MINI_MEMACT_ENABLED` | `"0"` để tắt MemAct | `1` (bật) |
| `MINI_CONTEXT_WINDOW` | Kích thước context window của model (tokens) | Auto theo backend |
| `MINI_CTX_COMPACT_THRESHOLD` | Ngưỡng nén chủ động / dự phòng | `0.85` |
| `MINI_CTX_SAFETY_MARGIN` | Hệ số an toàn context | `0.15` |
| `MINI_MEMACT_TOP_K` | Số memory item tối đa inject vào prompt | `8` |
| `MINI_MEMACT_MEMORY_BUDGET` | Ngân sách token dành riêng cho memory block | `2000` |
| `MINI_MEMACT_EXTRACT` | Chế độ trích xuất bộ nhớ dài hạn: `async`, `sync`, `off` | `async` |
| `MINI_MEMORY_DIR` | Thư mục lưu memory | `~/.mini/memory` |

> **Cơ chế nén ngữ cảnh Reactive Compaction (v0.3)**: Khi LLM backend báo lỗi tràn ngữ cảnh (ví dụ HTTP 400 Context Length Exceeded), mini-agent tự động kích hoạt quá trình tóm tắt và nén lịch sử (drop-all các message trung gian, dồn bản tóm tắt có cấu trúc tại vị trí index 1, giữ nguyên prompt ban đầu ở index 0) rồi tự động gửi lại request.

### Tool policy

- Allowlist có ưu tiên cao hơn blocklist: khi set allowlist, chỉ tool trong list mới được chạy.
- **Bảo đảm đa tầng**: Policy được kiểm soát nghiêm ngặt ở cả **Native JSON Tool Calling** và **CodeAct JavaScript Bindings** (`mini.sh`, `mini.write`, `mini.patch`, `mini.read`, v.v.).

```bash
# Chỉ cho phép đọc file và tìm kiếm
MINI_TOOL_ALLOWLIST=file_read,glob,grep mini-agent

# Chặn lệnh shell ở cả JSON tool lẫn CodeAct VM
MINI_TOOL_BLOCKLIST=bash mini-agent
```


## Cách dùng

### REPL tương tác

```bash
# Khởi động REPL
mini-agent

# System prompt tùy chỉnh
mini-agent --system ./my_system.md

# Backend cụ thể
mini-agent --model claude

# Không kết nối MCP servers
mini-agent --no-mcp
```

Slash commands:

| Lệnh | Mô tả |
|---|---|
| `/help` | Xem danh sách lệnh và tools |
| `/clear` | Xóa lịch sử hội thoại, clear màn hình |
| `/model <backend> [model]` | Đổi backend (`openai`, `claude`, `ollama`) |
| `/quit`, `/exit`, `/q` | Thoát |

```
You > /model claude
[agent] Switched to claude (claude-opus-4-5)

You > /model openai gpt-4o
[agent] Switched to openai-compat (gpt-4o)
```

### Single-shot

```bash
# Cờ -e / --exec
mini-agent -e "Tóm tắt README.md của project này"

# Hoặc positional argument
mini-agent "Ngày hôm nay là mấy?"

# Dùng trong script
RESULT=$(mini-agent -e "Viết một unit test cho hàm fibonacci")
echo "$RESULT" > test_fibonacci.py
```

### Execution modes

Chế độ thực thi (cờ `-m`/`--mode` hoặc `MINI_EXECUTION_MODE`):

- **`auto`** (mặc định) — model tự chọn cách phản hồi.
- **`codeact`** — agent viết JavaScript trong khối ```js ... ``` chạy trên CodeAct nhúng (ES2023+), gọi tools qua object `mini.*`:
  - **Per-Act VM Isolation**: Mỗi turn tạo `JSContext` độc lập để bảo vệ scope biến giữa các act, không bị xung đột redeclaration.
  - File I/O: `mini.read`, `mini.write`, `mini.patch`, `mini.exists`, `mini.stat`.
  - Tìm kiếm: `mini.glob`, `mini.grep`.
  - Shell: `mini.sh`, `mini.shStream`, `mini.shBackground` + quản lý job (`mini.jobStatus`, `mini.jobLogs`, `mini.jobKill`).
  - Khác: `mini.http`, `mini.artifact`, `mini.env`.
  - An toàn: Tự động bắt lỗi XML giả định (`<file_read>`, `<bash>`) chuyển đổi sang JS block; kiểm soát allowlist/blocklist và hook dispatch tại C-bindings.
- **`tools`** — agent gọi từng tool qua JSON schema truyền thống.

Chạy codeact tường minh:

```bash
mini-agent -m codeact -e "Dùng mini.sh chạy 'date +%s' và báo kết quả"
```

### Nguyên tắc kiểm soát hành động (Execution & Stopping Rules)

Agent tuân thủ 4 nguyên tắc cốt lõi được nạp trực tiếp vào system prompt:
1. **Dừng lại khi đạt mục tiêu (Stop on Completion)**: Ngay khi thu thập đủ dữ liệu hoặc hoàn tất tác vụ, agent dừng gọi tool và trả lời ngay, không chạy dư thừa.
2. **Xác nhận trước khi thay đổi (Confirm Before Mutation)**: Khi đang khảo sát/chẩn đoán, không tự ý sửa đổi file hay cấu hình nếu người dùng chưa yêu cầu trực tiếp.
3. **Tránh bẫy thao tác lặp lại (Avoid Action Loops)**: Nếu một hướng tiếp cận thất bại sau 2–3 lần thử, agent dừng lại đổi giả thuyết thay vì lặp vô hạn.
4. **Báo cáo tiến độ theo chặng (Progress Checkpoint)**: Đối với bài toán lớn, agent định kỳ dừng lại tóm tắt tiến độ và xin định hướng tiếp theo.


### Session (lưu hội thoại)

```bash
# Nạp và tự động lưu phiên tại ~/.mini/sessions/my-project.json
mini-agent --session my-project -e "Tên tôi là An."

# Tiếp tục ngữ cảnh ở lệnh tiếp theo
mini-agent --session my-project -e "Tên tôi là gì?"
# -> AI trả lời: "An."

# Hoặc dùng file JSON tùy chỉnh
mini-agent --session-file ./history.json -e "Phân tích file main.zig"
```

### Cron (chạy định kỳ)

```bash
# Cài cronjob chạy single-shot mỗi 5 phút
mini-agent --install-cron "*/5 * * * *" -e "say hello"
```

`--install-cron` yêu cầu dùng chung với `-e`. Khi chạy, mini-agent:

1. Lấy đường dẫn tuyệt đối của chính nó.
2. Escape an toàn nội dung `-e`.
3. Ghi cronjob qua lệnh `crontab` (đã tồn tại thì bỏ qua).

### Hooks (giám sát & observability)

Cấu hình qua `MINI_HOOK_COMMAND` hoặc cờ `--hook-command`:

```bash
mini-agent --hook-command 'echo "[HOOK] $MINI_HOOK_EVENT tool=$MINI_TOOL_NAME" >> /tmp/mini_audit.log'
```

Nhóm sự kiện:

- **CLI lifecycle**: `pre-prompt`, `post-response`, `pre-tool-use`, `post-tool-use` (kèm cờ `is_error`).
- **API streaming**: `message_start`, `content_block_start`, `content_block_delta`, `content_block_stop`, `message_delta`, `message_stop`.
- **MCP**: `OnNotification`, `OnRequest`, `OnError`.
- **Artifact**: `artifact_saved` (kèm tên, đường dẫn, type).

Hook script nhận dữ liệu qua hai kênh:

1. Biến môi trường (theo loại sự kiện, không phải lúc nào cũng có đủ):
   - Sự kiện chung: `MINI_HOOK_EVENT`, `MINI_PID`, `MINI_TIMESTAMP`.
   - Tool events: `MINI_TOOL_NAME`, `MINI_TOOL_INPUT`, `MINI_TOOL_RESULT`.
   - Prompt events: `MINI_USER_PROMPT`.
   - MCP events: `MINI_MCP_SERVER`, `MINI_MCP_METHOD`, `MINI_ERROR_MESSAGE`.
2. stdin: JSON payload chứa toàn bộ thông tin sự kiện.

Ví dụ audit logger (`monitor.py`):

```python
import sys, json

payload_raw = sys.stdin.read()
if payload_raw:
    data = json.loads(payload_raw)
    print(f"[MONITOR PID {data.get('pid')}] Event: {data.get('event')} | Data: {data}")
```

```bash
MINI_HOOK_COMMAND='python3 monitor.py >> /tmp/agent_telemetry.log' mini-agent -e "Tạo file /tmp/hello.txt"
```

#### Sidecar Proxy Pattern (ví dụ: Định tuyến OpenRouter Low-Latency & High-TPS)

Nếu muốn định tuyến hoặc tối ưu hóa request (như tự động chọn provider có độ trễ thấp nhất hoặc TPS cao nhất trên OpenRouter) **mà không sửa mã nguồn của mini-agent**, bạn có thể sử dụng cơ chế Hook kết hợp Sidecar Proxy:

1. Đặt sidecar proxy script (ví dụ `openrouter_proxy.py`) và hook script tại thư mục `~/.mini/hook/`.
2. Sidecar proxy chạy nền trên `http://127.0.0.1:8787`, lắng nghe request, tự động thăm dò bảng metrics của OpenRouter (`/api/v1/endpoints/z-scores` hoặc provider latency) và chuyển tiếp request đến provider tối ưu nhất.
3. Trong `~/.mini/.env`, trỏ:
   ```bash
   OPENAI_COMPAT_URL=http://127.0.0.1:8787/v1
   MINI_HOOK_COMMAND=~/.mini/hook/pre_prompt_hook.sh
   ```
4. Hook script `pre_prompt_hook.sh` kiểm tra tiến trình proxy, tự khởi động proxy nếu chưa chạy và ghi nhận audit log trước mỗi lượt prompt.


## Tools

15 built-in tools. AI tự quyết định gọi tool nào; gọi tool `skills` để tự liệt kê.

### bash

Chạy lệnh shell, trả về stdout + stderr.

```json
{ "command": "git log --oneline -5" }
```

Các pattern nguy hiểm (`rm -rf /`, fork bomb, `mkfs`, `dd if=`, `> /dev/sda`...) bị chặn bởi safety blocklist.

### file_read

Đọc nội dung file, trả về dòng có đánh số.

```json
{ "path": "src/main.zig", "offset": 100, "limit": 50 }
```

Giới hạn: 2000 dòng mỗi lần, file tối đa 10MB.

### file_write

Tạo mới hoặc ghi đè file; tự tạo thư mục cha.

```json
{ "path": "output/report.md", "content": "# Báo cáo\n..." }
```

Giới hạn: không ghi vào `/etc`, `/sys`, `/proc`, `/dev`.

### file_edit

Tìm chuỗi cũ (phải duy nhất trong file) và thay bằng chuỗi mới.

```json
{
  "path": "src/main.zig",
  "old_string": "const VERSION = \"1.0.0\";",
  "new_string": "const VERSION = \"1.1.0\";"
}
```

### glob

Tìm file theo wildcard `*`, `**`, `?`.

```json
{ "pattern": "**/*.zig", "path": "./src" }
```

### grep

Tìm nội dung file/thư mục đệ quy. Trả về `path:dòng:nội_dòng`.

```json
{ "pattern": "fn main", "path": "./src", "case_insensitive": "true" }
```

Giới hạn: 200 kết quả, bỏ qua file binary và file > 1MB.

### http_request

Gửi HTTP request (GET/POST/PUT/DELETE/HEAD).

```json
{
  "url": "https://api.github.com/repos/ziglang/zig/releases/latest",
  "method": "GET",
  "headers": { "Accept": "application/json" }
}
```

Giới hạn: response tối đa 30KB, timeout 30 giây.

### invoke_subagent

Gọi một agent con thực hiện tác vụ phức tạp (phân tích thư mục, refactor nhiều file).

```json
{ "task": "Phân tích cấu trúc src/core và tóm tắt trách nhiệm từng module" }
```

### batch_invoke_subagents

Chạy nhiều agent con song song cho các tác vụ độc lập.

```json
{ "tasks": ["Task 1 chi tiết...", "Task 2 chi tiết..."] }
```

### skills

Liệt kê/xem chi tiết tool.

```json
{ "operation": "list" }
{ "operation": "detail", "name": "bash" }
```

### artifact_write / artifact_read / artifact_list

Quản lý artifacts — sản phẩm độc lập (kế hoạch, walkthrough, HTML/SVG preview) lưu tại `<MINI_HOME>/artifacts/<session_id>/`. Mỗi lần ghi kích hoạt sự kiện hook `artifact_saved` để UI ngoài live-preview.

```json
{ "name": "plan.md", "content": "# Kế hoạch...", "type": "markdown" }
{ "name": "plan.md" }
{}
```

### session_diagnostics

Chẩn đoán và phân tích sâu các phiên làm việc của agent:
- Đọc và phân tích `journal_*.jsonl` trong `~/.mini/sessions/`.
- Thống kê phân loại lỗi (error taxonomy): `rate_limit_exceeded`, `provider_error` (HTTP 500, 502, 503, Cloudflare 520, 522), `context_length_exceeded`, `timeout`.
- Đánh giá hiệu quả retry backoff và lịch sử file modification (CAS snapshots).

```json
{ "action": "analyze_recent", "limit": 5 }
{ "action": "inspect_session", "session_id": "session-1234" }
```

### codeact

Thực thi khối lệnh JavaScript trực tiếp trong QuickJS-ng engine nhúng. Kết quả stdout và return value được đưa vào conversation turn tiếp theo.

```json
{ "code": "const files = mini.glob('**/*.zig'); console.log('Found:', files.length);" }
```

## Agent Workspace Folder (`.agent/`)

Theo chuẩn **RFC-005**, mỗi project có thể chứa một thư mục `.agent/` ở thư mục gốc để quản lý tri thức và hành vi cục bộ của agent mà không làm ảnh hưởng đến cấu hình toàn cục:

```
.agent/
├── AGENTS.md               # Quy tắc và hướng dẫn chuyên sâu cho agent trong project này
├── config.json             # Cấu hình runtime riêng của project (model, tool allowlist, v.v.)
├── skills/                 # Skills theo chuẩn Agent Skills (agentskills.io)
│   ├── codebase-analysis/
│   │   └── SKILL.md
│   └── root-cause-analysis/
│       └── SKILL.md
└── commands/               # Custom Slash Commands cho REPL
    ├── review.md           # Kích hoạt qua lệnh /review
    └── deploy.md           # Kích hoạt qua lệnh /deploy
```

- **Skills Discovery**: Agent tự động phát hiện và nạp các skills từ `.agent/skills/` (workspace) bên cạnh `~/.mini/skills/` (toàn cục).
- **Custom Commands**: Bất kỳ file markdown nào trong `.agent/commands/<name>.md` sẽ trở thành lệnh `/<name>` trong chế độ REPL.

## MCP (Model Context Protocol)

Kết nối MCP servers ngoài qua JSON-RPC 2.0 trên stdio. Tool của server được gọi với tiền tố `<server>__<tool>`.

Tạo file `~/.mini/mcp.json` (hoặc chỉ định qua `MINI_MCP_CONFIG`):

```json
{
  "servers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home/user/projects"]
    },
    "database": {
      "command": "python3",
      "args": ["-m", "mcp_server_sqlite", "mydb.sqlite"]
    }
  }
}
```

Với cấu hình trên, agent có thể gọi `filesystem__read_file`, `database__query`... Tắt MCP bằng cờ `--no-mcp`.

## ACP (Agent Client Protocol)

Chạy như ACP server để tích hợp vào Zed AI, JetBrains hoặc client ACP khác:

```bash
mini-agent --acp
```

Cấu hình trong Zed AI (`settings.json`):

```json
{
  "agent": {
    "external_agents": {
      "mini": {
        "command": "mini-agent",
        "args": ["--acp"]
      }
    }
  }
}
```

Phương thức hỗ trợ:

- `initialize` — bắt tay, đàm phán protocolVersion (v1) và capabilities.
- `session/new` — khởi tạo session với `cwd` và danh sách MCP servers.
- `session/load` — khôi phục session từ file lịch sử.
- `session/prompt` — nhận prompt, stream `session/update` real-time:
  - `agent_message_chunk`: nội dung phản hồi văn bản.
  - `agent_thought_chunk`: luồng suy nghĩ/reasoning.
  - `tool_call` & `tool_call_update`: trạng thái gọi và thực thi tool.
- `session/cancel` — huỷ turn đang xử lý.
- `session/close` — đóng và lưu context.
- `ping` — kiểm tra liveness.

## Build & Test

```bash
zig build                 # Debug — binary tại zig-out/bin/mini
sudo cp zig-out/bin/mini /usr/local/bin/mini-agent   # cài vào PATH
zig build -Doptimize=ReleaseSafe   # Production
zig build -Dtarget=aarch64-linux-gnu  # Cross-compile
```

### Bộ kiểm thử All-In-One (Multi-Tier Testing)

Dự án sở hữu bộ test tích hợp All-In-One tự động chạy 13/13 steps (159 tests passed, 4 skipped):

```bash
# Chạy toàn bộ test suite (Unit + Security Integration + E2E Mock LLM)
zig build test --summary all

# Chỉ chạy unit tests và CodeAct integration tests (không cần Node.js)
zig build test-unit
# hoặc
zig build test -Dskip-e2e=true

# Chỉ chạy E2E tests với mock LLM server
zig build test-e2e

# Chỉ định port khác cho mock server nếu port mặc định (8399) bị chiếm
zig build test -Dtest-port=8400
```

1. **Tầng 1 (Unit Tests)**: 118 unit tests bao phủ toàn bộ core, protocol, JSON parser, ANSI tokenizer, history, config, và các tool handlers.
2. **Tầng 2 (Integration Testcases)**: 45 tests trong `testcases/test_codeact_security.zig` kiểm tra nghiêm ngặt cách ly môi trường VM (Per-Act VM isolation), kiểm soát tool policy allowlist/blocklist, hook dispatching, và CAS snapshot rollback.
3. **Tầng 3 (E2E Mock LLM)**: Khởi chạy mock server SSE nội bộ (`scripts/mock_llm_server.js`), thực hiện 3 luồng end-to-end hoàn chỉnh: single-turn text, long streaming text, và multi-turn tool call bash.

Release đa nền tảng (Linux/macOS/Windows, x86_64/aarch64): `scripts/build_release.sh`, đóng gói vào `releases/`. GitHub Actions build và phát hành tự động khi push tag `v*`.

## Kiến trúc

```
src/
  main.zig            — entry point: CLI parsing, wiring, mode dispatcher
  core/               — agent loop, config, history (MemAct compaction),
                        hooks, journal + CAS snapshot (rollback), artifacts,
                        protocol, JSON utils, cron
  runtime/            — CodeAct engine, JS bindings (mini.*), background jobs
  tools/              — bash, file, glob, grep, http,
                        subagent, batch_subagent, artifact
  tooling/            — MCP client, tool registry (definitions + policy)
  ui/                 — line editor (UTF-8), REPL, unicode
  backends/           — openai, claude, ollama, sse transport
  acp/                — ACP server (JSON-RPC 2.0 stdio)
```

Luồng agentic loop:

```
User input
    │
    ▼
history.addUser(text)
    │
    ▼
tools.getRelevantDefinitions(text)   ← lọc tool theo policy
    │
    ▼
┌────────────────────────────────────┐
│            Agentic Loop            │
│                                    │
│  backend.sendMessage()  (SSE/NDJSON streaming)
│        │                           │
│        ▼                           │
│  response.stop_reason?             │
│      ├── end_turn ────────────────►│ trả về
│      └── tool_use ──┐              │
│                     ▼              │
│           tools.executeTool() × N  │
│                     │              │
│                     ▼              │
│        history.addToolResults()    │
│                     └─── tiếp tục ─┘
└────────────────────────────────────┘
```

Design docs nội bộ: thư mục `docs/` (RFC đánh số — kiến trúc CodeAct, event sourcing, MemAct context memory, chuẩn AGENTS.md).

## Ví dụ

- [examples/arxiv/](examples/arxiv/README.md) — ArXiv Paper Aggregator: agent truy vấn, chắt lọc và tóm tắt papers Khoa học Máy Tính trên arXiv, xuất báo cáo Markdown.

## Đóng góp

### Thêm tool mới

1. Tạo file `src/tools/mytool.zig` với hàm `executeTool(alloc, io, input_json) ![]u8`.
2. Đăng ký trong `src/tooling/registry.zig`:
   - Dispatch: `if (std.mem.eql(u8, name, "mytool")) return mytool.executeTool(alloc, io, input_json);`
   - Definition: thêm vào mảng `definitions` (name, description, `input_schema_json`).
   - Core list: thêm `"mytool"` vào `core_tools`.
3. Chạy `zig build test` — phải pass hết.

### Thêm backend mới

1. Implement `Client` với `sendMessage(system_prompt, msgs, tools, text_cb) !proto.Response`.
2. Đăng ký trong `src/core/agent.zig` — `Backend` union và `AgentLoop.init()`.

## License

MIT — xem file [LICENSE](LICENSE).
