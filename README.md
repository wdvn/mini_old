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
| Backends AI | OpenAI-compatible, Anthropic Claude, Ollama local | [Backends AI](#backends-ai) |
| Built-in tools | 15 tools: shell, file, glob, grep, HTTP, web search, browser, subagent, artifact | [Tools](#tools) |
| CodeAct runtime | Agent viết JS trong khối ```js``` chạy trên CodeAct nhúng, gọi API `mini.*` | [Execution modes](#execution-modes) |
| Session persistence | Lưu/khôi phục hội thoại theo ID hoặc file JSON | [Session](#session-lưu-hội-thoại) |
| Hooks | Audit logging, telemetry qua script ngoài tại mọi sự kiện | [Hooks](#hooks-giám-sát--observability) |
| MCP | Dùng tool từ MCP servers ngoài qua stdio JSON-RPC | [MCP](#mcp-model-context-protocol) |
| ACP | Tích hợp vào Zed AI, JetBrains như external agent | [ACP](#acp-agent-client-protocol) |
| Artifacts | Xuất kế hoạch, báo cáo, HTML/SVG ra thư mục session, kích hoạt preview hook | [Tools](#tools) |
| Tool policy | Allowlist/blocklist kiểm soát tool nào được chạy | [Tool policy](#tool-policy) |
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

1. **OpenAI-compatible** — khi có `OPENAI_COMPAT_URL`
2. **Anthropic Claude** — khi có `ANTHROPIC_API_KEY`
3. **Ollama** — fallback local

| Biến môi trường | Mô tả | Mặc định |
|---|---|---|
| `OPENAI_COMPAT_URL` | URL base API OpenAI-compatible | — |
| `OPENAI_COMPAT_MODEL` | Tên model | `gpt-4o-mini` |
| `OPENAI_COMPAT_API_KEY` | API key | — |
| `OPENAI_COMPAT_API_HEADER` | Tên HTTP header chứa key | `Authorization` |
| `ANTHROPIC_API_KEY` | Claude API key | — |
| `CLAUDE_MODEL` | Claude model ID | `claude-opus-4-5` |
| `OLLAMA_HOST` | URL Ollama server | `http://localhost:11434` |
| `OLLAMA_MODEL` | Tên model Ollama | `llama3` |

Đổi backend trong REPL bằng lệnh `/model <backend> [model]`, với `backend` nhận một trong ba giá trị `openai` | `claude` | `ollama`.

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
2. `./.env` — thư mục làm việc hiện tại
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
| `MINI_SESSION` | Session ID (lưu tại `<MINI_HOME>/sessions/<id>.json`) | — |
| `MINI_SESSION_FILE` | Đường dẫn file session JSON trực tiếp | — |
| `MINI_ENV_FILE` | Đường dẫn `.env` tường minh | — |

### Tool policy

- Allowlist có ưu tiên cao hơn blocklist: khi set allowlist, chỉ tool trong list mới chạy.
- Policy áp dụng cho tool gọi trực tiếp qua registry. Khi chạy ở chế độ `codeact`, lệnh shell đi qua API `mini.sh` trong CodeAct và không đi qua check này.

```bash
# Chỉ cho phép đọc file và tìm kiếm
MINI_TOOL_ALLOWLIST=file_read,glob,grep mini-agent

# Chặn bash ở chế độ tools
MINI_TOOL_BLOCKLIST=bash mini-agent -m tools
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
  - File I/O: `mini.read`, `mini.write`, `mini.patch`, `mini.exists`, `mini.stat`.
  - Tìm kiếm: `mini.glob`, `mini.grep`.
  - Shell: `mini.sh`, `mini.shStream`, `mini.shBackground` + quản lý job (`mini.jobStatus`, `mini.jobLogs`, `mini.jobKill`).
  - Khác: `mini.http`, `mini.artifact`, `mini.env`.
- **`tools`** — agent gọi từng tool qua JSON schema truyền thống.

Chạy codeact tường minh:

```bash
mini-agent -m codeact -e "Dùng mini.sh chạy 'date +%s' và báo kết quả"
```

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

### web_search

Tìm kiếm web qua DuckDuckGo Lite, không cần API key. Trả về tiêu đề + URL + snippet.

```json
{ "query": "Zig 0.16 release notes", "num_results": 10 }
```

### browser

Điều khiển trình duyệt qua Playwright (yêu cầu `python3` + `pip install playwright`).

```json
{ "action": "goto", "url": "https://example.com" }
{ "action": "click", "selector": "#login-btn" }
{ "action": "type", "selector": "input[name='q']", "text": "Zig programming" }
{ "action": "screenshot", "path": "output.png" }
{ "action": "exec", "script": "return document.title;" }
```

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

## Build

```bash
zig build                 # Debug — binary tại zig-out/bin/mini
sudo cp zig-out/bin/mini /usr/local/bin/mini-agent   # cài vào PATH
zig build test            # Unit tests
zig build -Doptimize=ReleaseSafe   # Production
zig build -Dtarget=aarch64-linux-gnu  # Cross-compile
```

Release đa nền tảng (Linux/macOS/Windows, x86_64/aarch64): `scripts/build_release.sh`, đóng gói vào `releases/`. GitHub Actions build và phát hành tự động khi push tag `v*`.

## Kiến trúc

```
src/
  main.zig            — entry point: CLI parsing, wiring, mode dispatcher
  core/               — agent loop, config, history (MemAct compaction),
                        hooks, journal + CAS snapshot (rollback), artifacts,
                        protocol, JSON utils, cron
  runtime/            — CodeAct engine, JS bindings (mini.*), background jobs
  tools/              — bash, file, glob, grep, http, search, browser,
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
