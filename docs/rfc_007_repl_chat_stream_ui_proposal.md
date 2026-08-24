# RFC-007: REPL Chat Stream & Turn UI Optimization

- **Tác giả:** mini-agent team
- **Ngày:** 2026-08-24
- **Trạng thái:** Proposed & In Implementation
- **Phạm vi:** `src/ui/`, `src/core/agent.zig`, `src/ui/repl.zig`

---

## 1. Bối cảnh & Mục tiêu

Trong các AI Coding Agent CLI hiện đại (như Claude Code, Aider, Codex CLI), giao diện terminal không đơn thuần là dòng văn bản in thô (raw stream) hay log `stderr` lộn xộn. Trải nghiệm người dùng trong 1 luồng chat (Single Turn Lifecycle) đóng vai trò quyết định đến cảm giác mượt mà, trực quan và chuyên nghiệp của công cụ.

### Tình trạng trước RFC-007 trong `mini`:
1. **Xung đột luồng đầu ra (`stdout` vs `stderr`)**: Tool logs và agent status ghi vào `stderr`, câu trả lời AI ghi vào `stdout`. Khi flush không đồng bộ, text bị đè và giật.
2. **"Ô nhiễm" màn hình cuộn (Scrollback pollution)**: Khối reasoning `<think>` và log vòng lặp in thẳng ra màn hình hàng trăm dòng không có viền ngăn cách hay tóm tắt.
3. **Thiếu phản hồi thị giác khi chạy công cụ**: Khi gọi `file_edit` hoặc `mini.patch()`, user không thấy được Diff trực quan (`+`/`-`); khi chạy `bash` hoặc `codeact`, chỉ có 1 dòng `[ok]`.
4. **Không có chỉ số Telemetry & Context Window**: User không nắm được số token tiêu thụ, thời gian phản hồi, cũng như % context window còn lại (đặc biệt quan trọng với MemAct - RFC-003).

### Mục tiêu của RFC-007:
- Xây dựng hệ thống UI primitives 100% bằng Zig chuẩn (ANSI styling, Box drawing, non-blocking Braille spinner).
- Phân cấp thị giác rõ ràng cho 1 turn: **User Prompt Card → Reasoning Block → Action Cards & Diff View → Streaming Markdown & Code Highlight → Telemetry Footer**.
- Đảm bảo hiệu năng cao: Zero heap fragmentation, xử lý streaming mượt mà không nhấp nháy (flicker-free).

---

## 2. Thiết kế phân cấp thị giác (Visual Hierarchy)

```
╭─ ❯ You ────────────────────────────────────────────────────────────────────────╮
│  Refactor hàm readAll trong src/core/utils.zig và kiểm tra lại tests           │
╰────────────────────────────────────────────────────────────────────────────────╯

 💭 Thinking (1.8s)
 │  Model đang phân tích cấu trúc file utils.zig và tìm các test case liên quan...

 ⚡ Action [1/2]  mini.read("src/core/utils.zig")
    ✓ Read 184 lines (6.2 KB) • 12ms

 ⚡ Action [2/2]  mini.patch("src/core/utils.zig")
    ╭── src/core/utils.zig ──────────────────────────────────────────────────────╮
    │ @@ -45,7 +45,7 @@ pub fn readAll(...) !usize {                            │
    │ -    var total: usize = 0;                                                 │
    │ +    var total_read: usize = 0;                                            │
    ╰────────────────────────────────────────────────────────────────────────────╯
    ✓ Applied cleanly • CAS hash: a1f8...

 🤖 mini-agent
 Đã refactor lại hàm `readAll` để tối ưu bộ nhớ buffer:

 ```zig
 // src/core/utils.zig
 pub fn readAll(io: std.Io, file: std.Io.File, buf: []u8) !usize { ... }
 ```

 ─────────────────────────────────────────────────────────────────────────────────
 📊 1,248 tokens (480 reasoning) • 2.4s • Context: 18.5k/128k (14%) • 2 acts
```

---

## 3. Kiến trúc module UI

```
src/ui/
  ├── terminal.zig        — ANSI styling, 16/256 colors, UTF-8 box characters, cursor helpers
  ├── spinner.zig         — Live non-blocking Braille spinner + stopwatch timer
  ├── diff_renderer.zig   — Unified Diff visualizer (Red/Green syntax, line numbers, CAS hash)
  ├── markdown.zig        — Streaming lightweight Markdown & Syntax highlighter
  ├── chat_stream.zig     — TurnRenderer orchestrator điều phối toàn bộ lifecycle 1 turn
  ├── repl.zig            — Kết nối TurnRenderer vào REPL loop
  └── editor.zig          — Multiline composer & input parser
```

### 3.1. `terminal.zig`: ANSI Primitives & Box Characters
- Cung cấp hằng số ANSI escape codes chuẩn: Bold (`\x1b[1m`), Dim (`\x1b[2m`), Italic (`\x1b[3m`), Reset (`\x1b[0m`).
- Bảng màu 16 màu và các bộ ký tự UTF-8 box drawing (`╭`, `─`, `╮`, `│`, `╰`, `╯`, `⚡`, `✓`, `✗`, `💭`, `📊`, `🤖`, `❯`).
- Các hàm điều khiển con trỏ: `clearLine()`, `hideCursor()`, `showCursor()`.

### 3.2. `spinner.zig`: Non-blocking Braille Spinner
- Bảng ký tự Braille: `⠋`, `⠙`, `⠹`, `⠸`, `⠼`, `⠴`, `⠦`, `⠧`, `⠇`, `⠏`.
- Theo dõi thời gian thực hiện (`std.time.milliTimestamp`).
- Cập nhật dòng trạng thái tại chỗ bằng `\r\x1b[2K` để không làm rối luồng in.

### 3.3. `diff_renderer.zig`: Unified Diff Visualizer
- Phân tích nội dung patch / file edit:
  - Dòng thêm mới (`+`): Xanh lá (`\x1b[32m`).
  - Dòng bị xóa (`-`): Đỏ (`\x1b[31m`).
  - Dòng Hunk Header (`@@`): Cyan (`\x1b[36m`).
  - Tự động đóng khung viền và tóm tắt nếu diff vượt quá số dòng tối đa.

### 3.4. `markdown.zig`: Streaming Markdown & Code Highlighter
- Sử dụng state machine siêu nhẹ (Zero-allocation) xử lý từng chunk stream:
  - Header (`#`, `##`, `###`) → In đậm màu nổi bật.
  - Inline Code (`` `...` ``) → Màu vàng nền sẫm.
  - Code Block (````lang ... ````) → Khung viền code block và tô màu từ khóa cơ bản (Zig, JS, Rust, Python, Go, Shell).
  - Giữ lại bộ đệm nhỏ (lookahead buffer) để không làm vỡ các delimiter khi chunk bị cắt đôi giữa chừng (vd: một nửa `**` ở chunk 1, một nửa ở chunk 2).

### 3.5. `chat_stream.zig`: Turn Orchestrator
- Struct `TurnRenderer` theo dõi vòng đời hoàn chỉnh của 1 lượt xử lý:
  - `startTurn(prompt)`: Khởi tạo turn, in header.
  - `startThinking()` / `streamThinking(text)` / `endThinking()`: Stream suy nghĩ trong khối viền dọc mờ `│`.
  - `startTool(name, input_json)`: Hiện Action card với spinner.
  - `finishTool(name, result, is_error, duration_ms)`: In kết quả action và diff nếu có.
  - `streamResponse(text)`: Stream câu trả lời qua Markdown highlighter.
  - `finishTurn(stats)`: In thanh footer telemetry tổng kết tokens, latency, context usage.

---

## 4. Tương thích ngược & Chế độ không tương tác
- Khi chạy single-shot prompt (`mini -e "..."`) hoặc xuất ra pipe/file (`!isatty`), các hiệu ứng spinner động và màu sắc có thể tự động rút gọn hoặc tắt để tránh gây lỗi cho các script tự động hóa.
- Giữ vững nguyên tắc: Không thêm dependency ngoài, tuân thủ nghiêm ngặt Zig 0.16.0.
