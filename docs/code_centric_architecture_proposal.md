# PROPOSAL: EXECUTABLE CODE-CENTRIC AGENT ARCHITECTURE (CODEACT) CHO MINI
> **Document**: RFC-001  
> **Status**: Draft / In Review  
> **Target System**: `mini-agent` (`mini`)  
> **Author**: Core Team & AI Pair Programmer  
> **Date**: 19/08/2026  

---

## 1. TỔNG QUAN & BỐI CẢNH (EXECUTIVE SUMMARY)

### 1.1. Hiện trạng: Hạn chế của JSON Tool-Calling (RPC-style)
Kiến trúc ban đầu của `mini` dựa trên chuẩn **JSON Tool-Calling** truyền thống (Function Calling / RPC):
1. Agent nhận yêu cầu của người dùng, phân tích và sinh ra cấu trúc JSON (`tool_use`).
2. Tiến trình `mini` parse JSON, dispatch đến handler tương ứng (ví dụ: `grep`, `file_read`, `file_edit`), rồi gửi kết quả (`tool_result`) ngược lại cho LLM.
3. LLM phân tích kết quả và tiếp tục vòng lặp.

#### Các điểm nghẽn nghiêm trọng trong thực tế:
- **Độ trễ cao (High Turn Latency)**: Mỗi thao tác đơn lẻ tốn 1 roundtrip mạng đến AI Provider. Một tác vụ thông thường (tìm file $\rightarrow$ đọc file $\rightarrow$ sửa lỗi $\rightarrow$ chạy test) đòi hỏi từ **5 đến 10 LLM turns** (mỗi turn mất 3-8 giây).
- **Ô nhiễm cửa sổ ngữ cảnh (Context Bloating)**: Các kết quả trung gian chưa qua chọn lọc (như output 200 dòng của `grep` hay toàn bộ nội dung file 1,000 dòng) bị đẩy trực tiếp vào context window, làm cạn kiệt token và tăng chi phí.
- **Không có cấu trúc điều khiển (No Control Flow)**: LLM không thể viết vòng lặp `for`, rẽ nhánh `if/else`, pipe `|` dữ liệu giữa các công cụ trong cùng một bước mà phải chờ LLM turn tiếp theo.

---

### 1.2. Giải pháp: Executable Code-Centric Agent Architecture (CodeAct)
Chuyển đổi toàn bộ cơ chế tương tác công cụ của `mini` sang mô hình **Thực thi Mã nguồn Trực tiếp (Executable Code / Scripting)**:
- Agent không gọi các JSON tools riêng lẻ mà **viết các đoạn mã/script phức hợp (Bash, Shell, CLI subcommands)** có đầy đủ logic (vòng lặp, điều kiện rẽ nhánh, biểu thức chính quy, lọc dữ liệu) để giải quyết trọn vẹn chuỗi tác vụ **trong duy nhất 1 Turn**.
- **Tiết kiệm 70% - 90% Token**: Dữ liệu trung gian được lọc và xử lý trực tiếp tại máy cục bộ qua pipe (`grep`, `jq`, `head`, `awk`), chỉ có kết quả chắt lọc cuối cùng mới được nạp vào ngữ cảnh của LLM.
- **Zero-copy Realtime Feedback**: Output của lệnh (stdout/stderr) được stream trực tiếp lên terminal người dùng trong quá trình thực thi.

---

## 2. SO SÁNH KIẾN TRÚC: CŨ VS MỚI

```
[MÔ HÌNH CŨ: JSON RPC Tool-Calling]
User ──► LLM ──(tool: grep)──► Mini ──► Raw 200 lines ──► LLM ──(tool: read)──► Mini ...
         ▲                                                                         │
         └────────(tool: edit_file)◄── Mini ◄──(result: 500 lines)─────────────────┘
         (Tiêu tốn 6-10 turns qua lại, nhét hàng chục ngàn tokens rác vào context)

─────────────────────────────────────────────────────────────────────────────

[MÔ HÌNH MỚI: Executable Code-Centric Architecture (CodeAct)]
User ──► LLM ──► [Sinh 1 Script thực thi tổng hợp] ──► [Sandboxed Runtime Engine]
                                                              │
                                                      ┌───────┴───────┐
                                                      │ Loop qua file │
                                                      │ Grep + Filter │
                                                      │ Patch + Test  │
                                                      └───────┬───────┘
                                                              │
User ◄── LLM ◄─────── Kết quả cô đọng (10-20 dòng) ───────────┘
         (Chỉ mất 1 Turn duy nhất, toàn bộ logic trung gian chạy ở máy local)
```

---

## 3. THIẾT KẾ CẤU TRÚC CHI TIẾT (TARGET CODEBASE ARCHITECTURE)

Hệ thống được tái cấu trúc thành các module phân tầng độc lập:

```
src/
├── main.zig                # Composition root, CLI args parser & REPL loop
├── core/                   # Điều phối & Quản lý trạng thái
│   ├── agent_loop.zig      # CodeAct Loop (Stream -> Extract Code -> Exec -> Feedback)
│   ├── permissions.zig     # Dynamic Security (Ask / Auto / Yolo)
│   ├── history.zig         # State compaction & History quản lý code executions
│   └── contracts.zig       # Interfaces, Event types & Token specs
├── runtime/                # Môi trường thực thi mã nguồn
│   ├── engine.zig          # Interface trừu tượng điều phối thực thi
│   ├── shell_runner.zig    # High-performance Bash/Sh Runner với streaming I/O
│   └── sandbox.zig         # Resource limits (Timeout, Process kill, Directory jail)
├── stdlib/                 # Bộ công cụ Agent Standard Library & CLI Helpers
│   ├── fs_tools.zig        # mini-tools read, write, patch (diff/regex)
│   ├── search_tools.zig    # mini-tools grep, glob tối ưu tốc độ cao
│   ├── http_tools.zig      # mini-tools http request
│   └── browser_tools.zig   # mini-tools browser automation
├── backend/                # Multi-provider LLM transport (OpenAI, Claude, Ollama)
└── ui/                     # Terminal rendering & Streaming think/code parser
```

---

## 4. CÁC TRỤ CỘT KỸ THUẬT CỐT LÕI

### 4.1. CodeAct Agent Loop ([`src/core/agent_loop.zig`](file:///mnt/hdd/projects/persional/mini/src/agent.zig))
- **System Prompt**: Hướng dẫn LLM tư duy theo giải thuật (sử dụng shell scripts, pipes và các tool subcommands để giải quyết vấn đề).
- **Code Extraction Pipeline**: Trích xuất code blocks (```bash ... ``` hoặc ```sh ... ```) ngay khi đang streaming response từ AI.
- **Execution & Real-time Multiplexing**:
  - Thực thi qua `runtime/shell_runner.zig`.
  - Stdout và Stderr được stream đồng thời ra terminal giúp người dùng quan sát tiến trình (ví dụ: `zig build`, `npm install`, `test suite`).
- **Context Output Ingestion**:
  - Output thực thi được định dạng kèm mã `exit_code` và thời gian chạy.
  - Tự động cắt gọt (Head/Tail Truncation nếu vượt quá 32KB) để bảo tồn Context Window.

### 4.2. Tool Standard Library & CLI Subcommands (`src/stdlib/`)
Thay vì định nghĩa 10 JSON tool schemas cồng kềnh gửi lên mỗi request LLM, các công cụ được đóng gói thành **Agent CLI Subcommands** (`mini-tools <subcommand>`):
- `mini-tools glob <pattern> [path]`
- `mini-tools grep <pattern> [path]`
- `mini-tools read <path> [--offset N] [--limit N]`
- `mini-tools patch <path> --find <old> --replace <new>`
- `mini-tools http <GET|POST> <url> [--data ...]`

#### Ví dụ Agent Script thực thi liên hoàn trong 1 Turn:
```bash
# Agent tự viết script kiểm tra và sửa lỗi hàng loạt:
for f in $(mini-tools glob "**/*.zig"); do
    if mini-tools grep "openDir(io, path, .{})" "$f" > /dev/null; then
        echo "Fixing $f..."
        mini-tools patch "$f" \
            --find "openDir(io, path, .{})" \
            --replace "openDir(io, path, .{ .iterate = true })"
    fi
done

# Chạy test kiểm tra ngay lập tức
zig build test
```

### 4.3. Mô hình Phân quyền Động 3 Cấp độ (`src/core/permissions.zig`)
Học hỏi từ chuẩn bảo mật của `vercel-labs/fx`:
- **`ask` (Mặc định)**: Tạm dừng và yêu cầu người dùng xác nhận (`[Allow once] / [Deny] / [Always Allow]`) trước khi chạy các lệnh ghi file hoặc lệnh shell nguy hiểm.
- **`auto`**: Cho phép tự động các lệnh an toàn (đọc file, tìm kiếm, stat) và chỉ hỏi khi có can thiệp sửa đổi hệ thống.
- **`yolo`**: Cho phép toàn bộ không cần hỏi (dành cho môi trường CI/CD hoặc Container).

---

## 5. ĐÁNH GIÁ HIỆU NĂNG & LỢI ÍCH

| Tiêu chí | Mô hình JSON Tool-Calling (Cũ) | Mô hình CodeAct (Mới) | Mức cải thiện |
| :--- | :--- | :--- | :--- |
| **Số LLM Turns (Tác vụ 4 bước)** | 6 – 10 Turns | 1 – 2 Turns | **Giảm 70% – 80%** |
| **Tổng thời gian hoàn thành** | 30 – 60 giây | 5 – 10 giây | **Nhanh hơn 4x – 6x** |
| **Token tiêu tốn cho Context** | 15,000 – 30,000 tokens | 2,000 – 4,000 tokens | **Tiết kiệm 80%** |
| **Độ linh hoạt logic** | Bị giới hạn bởi schema | Đầy đủ (vòng lặp, điều kiện, pipes) | **Không giới hạn** |

---

## 6. LỘ TRÌNH TRIỂN KHAI 4 GIAI ĐOẠN (IMPLEMENTATION ROADMAP)

### Giai đoạn 1: CodeAct Kernel & Shell Execution Pipeline
- [ ] Xây dựng `src/runtime/shell_runner.zig` (Streaming execution + timeout + pipe deadlock prevention).
- [ ] Xây dựng `src/runtime/engine.zig` (Code block extraction + context output formatting).
- [ ] Nâng cấp `AgentLoop` nhận diện và thực thi code blocks song song với JSON tools hiện có.

### Giai đoạn 2: Built-in Tool Unification & CLI Helpers
- [ ] Đóng gói bộ công cụ `mini-tools` subcommands trong `src/stdlib/`.
- [ ] Cập nhật System Prompt sang mô hình Code-First Action.

### Giai đoạn 3: Dynamic Permissions & Context Auto-Optimizer
- [ ] Triển khai `src/core/permissions.zig` với các chế độ `ask`, `auto`, `yolo` và `/permissions remember`.
- [ ] Thêm cơ chế tự động truncate thông minh và nén ngữ cảnh khi script sinh output lớn.

### Giai đoạn 4: ACP (Agent Control Protocol) & Headless Embeddability
- [ ] Hỗ trợ giao thức JSON-RPC ACP để các IDE (VS Code, Cursor) hoặc Web UI có thể nhúng và điều khiển `mini` từ xa.
