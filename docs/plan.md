# Mini Agent bằng Zig — dựa trên Wintermolt Core

## Mô tả

Xây dựng một **mini agent độc lập** tại `examples/mini-agent/`, sử dụng lại hoàn toàn
các module core của Wintermolt (`config`, `loop`, `tools`, `mcp/client`) mà không chạm
vào `src/main.zig` hay bất kỳ file gốc nào.

Agent này nhỏ gọn, dễ đọc — điểm khởi đầu tốt để hiểu cách Wintermolt hoạt động hoặc
để fork ra một agent chuyên biệt.

---

## Phạm vi & Mục tiêu

| Tính năng | Chi tiết |
|-----------|---------|
| Load `.env` tự động | `config.loadDotEnv()` — CWD → `~/.wintermolt/.env` → `$WINTERMOLT_ENV_FILE` |
| Backend đa dạng | OpenAI-compat / Claude / Ollama, fallback tự động |
| Chế độ `-e "prompt"` | Single-shot không interactive |
| Chế độ REPL | Loop đọc stdin; `/quit` `/clear` `/help` `/model` |
| System prompt tùy chỉnh | `--system <file>` hoặc `MINI_SYSTEM_FILE` env |
| **MCP Client** | Load `~/.wintermolt/mcp.json` hoặc `$WINTERMOLT_MCP_CONFIG` |
| **Tools đầy đủ** | 18 tools core + MCP tools động |
| Tool policy | `WINTERMOLT_TOOL_ALLOWLIST` / `WINTERMOLT_TOOL_BLOCKLIST` |
| Build target riêng | `zig build mini-agent` → `zig-out/bin/mini-agent` |

---

## Tools được enable trong Mini Agent

### Core tools (luôn gửi lên API)

| Tool | Mô tả |
|------|-------|
| `bash` | Chạy lệnh shell, trả về stdout/stderr |
| `file_read` | Đọc file (hỗ trợ offset/limit) |
| `file_write` | Ghi/tạo file |
| `file_edit` | Sửa file (tìm old_string → thay new_string) |
| `glob` | Tìm file theo wildcard pattern |
| `grep` | Tìm kiếm nội dung trong file |
| `http_request` | HTTP GET/POST/PUT/DELETE tới bất kỳ URL |
| `web_search` | Tìm kiếm web qua DuckDuckGo |
| `skills` | Liệt kê / xem chi tiết tool đang có |

### Extended tools (gửi lên khi user message match keyword)

| Tool | Keywords kích hoạt |
|------|--------------------|
| `memory_search` | remember, recall, history, past... |
| `schedule` | schedule, cron, timer, every day... |
| `browser_control` | browser, navigate, click, scrape... |
| `image_process` | image, photo, resize, convert... |
| `camera_capture` | camera, webcam, take a photo... |
| `text_to_speech` | speak, voice, tts, audio... |
| `image_generate` | draw, generate image, dall-e... |
| `tailscale` | tailscale, vpn, network, peers... |
| `google_workspace` | gmail, calendar, drive, email... |

### MCP tools (dynamic — từ external MCP servers)

Prefix `<servername>__<toolname>` — ví dụ `filesystem__read_file`.

Cấu hình qua `~/.wintermolt/mcp.json`:

```json
{
  "servers": {
    "filesystem": {
      "command": "npx",
      "args": ["@modelcontextprotocol/server-filesystem", "/home/user"]
    }
  }
}
```

---

## Các file cần tạo / sửa

### `build.zig` — MODIFY

Thêm build target `mini-agent`:

```zig
// zig build mini-agent  →  zig-out/bin/mini-agent
const mini_mod = b.createModule(.{
    .root_source_file = b.path("examples/mini-agent/main.zig"),
    .target = target,  .optimize = optimize,  .link_libc = true,
});
mini_mod.linkSystemLibrary("curl", .{});
mini_mod.linkSystemLibrary("sqlite3", .{});
const mini_exe = b.addExecutable(.{ .name = "mini-agent", .root_module = mini_mod });
b.installArtifact(mini_exe);
const mini_step = b.step("mini-agent", "Build examples/mini-agent");
mini_step.dependOn(&b.addInstallArtifact(mini_exe, .{}).step);
```

### `examples/mini-agent/` — NEW

| File | Mô tả |
|------|-------|
| `main.zig` | Entry point: args → loadDotEnv → Config → MCP → AgentLoop → REPL/exec |
| `.env.example` | Mẫu cấu hình (copy → `.env` rồi điền key) |
| `system_prompt.md` | System prompt mặc định tiếng Việt |
| `run.sh` | Wrapper: build nếu cần, load `.env`, chạy binary |
| `README.md` | Tài liệu tiếng Việt + ví dụ sử dụng |

---

## Kiến trúc `main.zig`

```
main()
 ├─ parse args (-e, --system, --help, --no-mcp)
 ├─ config.loadDotEnv()          ← .env tự động
 ├─ Config.load()                ← env vars → struct Config
 ├─ McpClientManager.init()
 │   └─ loadFromConfig()         ← ~/.wintermolt/mcp.json
 │       └─ spawnServer() × N    ← handshake + discoverTools()
 ├─ tools.setMcpManager(&mcp)    ← đăng ký MCP vào tool dispatcher
 ├─ AgentLoop.init(&config)      ← backend + history + tool policy
 │
 ├─ [single-shot]  agent.processInput(prompt)
 └─ [REPL]         loop stdin → agent.processInput(line)
```

Import path (relative từ `examples/mini-agent/main.zig`):

```zig
const config_mod = @import("../../src/agent/config.zig");
const loop_mod   = @import("../../src/agent/loop.zig");
const tools      = @import("../../src/agent/tools.zig");
const mcp_client = @import("../../src/mcp/client.zig");
```

---

## Tool Policy

```bash
# Chỉ cho phép http + file + bash
WINTERMOLT_TOOL_ALLOWLIST=http_request,file_read,file_write,bash ./run.sh

# Block bash (an toàn hơn cho môi trường shared)
WINTERMOLT_TOOL_BLOCKLIST=bash ./run.sh
```

---

## Cách sử dụng (sau khi build)

```bash
# Build
zig build mini-agent

# Single-shot
cd examples/mini-agent && ./run.sh -e "Tóm tắt file README.md"

# REPL tương tác
./run.sh

# Custom system prompt
./run.sh --system my_prompt.md

# Không dùng MCP
./run.sh --no-mcp -e "Hello"
```

---

## Verification Checklist

- [ ] `zig build mini-agent` — biên dịch thành công
- [ ] `./run.sh -e "Xin chào"` — single-shot hoạt động
- [ ] `./run.sh` — REPL mở, nhận trả lời, `/quit` thoát
- [ ] `.env` ở CWD được load tự động (không cần export thủ công)
- [ ] MCP: thêm `~/.wintermolt/mcp.json` → tools MCP xuất hiện
- [ ] `WINTERMOLT_TOOL_BLOCKLIST=bash ./run.sh` → bash bị từ chối
