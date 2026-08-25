---
name: codebase-analysis
description: Phân tích cấu trúc codebase, kiến trúc modules, tracing luồng thực thi (execution flow) và phụ thuộc giữa các thành phần. Use when cần tìm hiểu kiến trúc, map luồng xử lý hoặc định vị các thành phần liên quan trong project.
---

# Codebase Analysis Skill

Hướng dẫn phân tích toàn diện cấu trúc mã nguồn, định vị trách nhiệm module và trace luồng dữ liệu trong dự án `mini`.

---

## 1. Khi nào kích hoạt Skill này?

- Khi tiếp nhận yêu cầu phân tích tính năng mới hoặc hiểu cách một module hoạt động.
- Khi cần tìm nơi xử lý một logic cụ thể (vd: "đoạn code xử lý slash command ở đâu?", "cách SSE parse response ra sao?").
- Khi cần vẽ bản đồ luồng gọi hàm từ REPL -> Core Agent Loop -> Backends -> QuickJS VM.

---

## 2. Quy trình phân tích Codebase 4 bước

### Bước 1: Khảo sát cấu trúc thư mục & trách nhiệm module
Tra cứu nhanh sơ đồ phân lớp:
```
src/
├── main.zig             # Entrypoint CLI & REPL wiring
├── core/                # Agent loop, config, history, protocol, journaling, MemAct
│   ├── agent.zig        # Vòng lặp Act, error handling, compaction, state rollback
│   ├── config.zig       # Đọc .env, config.json, biến môi trường
│   ├── history.zig      # Quản lý mảng messages, MemAct compaction
│   └── journal.zig      # Event sourcing logger (JSONL format)
├── runtime/             # QuickJS-ng engine, JS bindings (mini.*), process manager
│   ├── js_bindings.zig  # Cài đặt toàn bộ hàm mini.read/write/sh/http...
│   └── quickjs_engine.zig
├── backends/            # AI Client adapters (OpenAI-compat, Claude, Ollama, SSE)
├── tools/               # Built-in tool implementations (bash, file, glob, search...)
├── tooling/             # MCP client, tool registry
└── ui/                  # REPL, Terminal UI, chat_stream, line editor
```

### Bước 2: Định vị điểm khởi đầu (Entrypoint & Data Flow)
- **Interactive REPL Flow**: `main.zig` -> `ui/repl.zig` -> `core/agent.zig:processInput` -> `core/agent.zig:executeStep`.
- **Single-shot Flow**: `main.zig:runSingleShot` -> `core/agent.zig:processInput`.
- **Backend Flow**: `core/agent.zig:sendToBackend` -> `backends/<backend>.zig:sendMessage` -> `lib/http_request.zig:postStream`.
- **CodeAct Execution Flow**: `core/agent.zig:findJsCodeInResponse` -> `runtime/quickjs_engine.zig:eval` -> `runtime/js_bindings.zig` -> `core/snapshot.zig`.

### Bước 3: Tìm kiếm mẫu hình (Pattern Matching & Grep)
- Tìm định nghĩa hàm/struct: `grep_search` với từ khóa `fn <tên_hàm>` hoặc `pub const <Tên_Struct>`.
- Tìm references: `grep_search` trên toàn bộ thư mục `src/`.
- Chú ý doc-comments `//!` ở đầu mỗi file `.zig` để nắm nhanh trách nhiệm module.

### Bước 4: Tổng hợp bản đồ phân tích
Khi trả lời hoặc tạo tài liệu phân tích, cấu trúc theo:
1. **Mục đích module**: Chức năng chính và các ràng buộc.
2. **Luồng dữ liệu (Input -> Transform -> Output)**.
3. **Các điểm tích hợp (Interfaces / Structs)**.
4. **Lưu ý bộ nhớ & concurrency (Allocator, Threading, I/O)**.
