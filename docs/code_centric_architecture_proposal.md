# PROPOSAL: LUA / LUAJIT EMBEDDED CODE-CENTRIC AGENT ARCHITECTURE CHO MINI
> **Document**: RFC-001 (Revision 3 — Validated & Hardened)  
> **Status**: Draft / In Review  
> **Target System**: `mini-agent` (`mini`)  
> **Core Interpreter**: **Embedded Lua 5.1 / LuaJIT Runtime (Interpreter Mode)**  
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
- **Độ trễ cao (High Turn Latency)**: Mỗi thao tác đơn lẻ tốn 1 roundtrip mạng đến AI Provider. Một tác vụ thông thường (tìm file → đọc file → sửa lỗi → chạy test) đòi hỏi từ **5 đến 10 LLM turns** (mỗi turn mất 3-8 giây).
- **Ô nhiễm cửa sổ ngữ cảnh (Context Bloating)**: Các kết quả trung gian chưa qua chọn lọc (như output 200 dòng của `grep` hay toàn bộ nội dung file 1,000 dòng) bị đẩy trực tiếp vào context window, làm cạn kiệt token và tăng chi phí.
- **Không có cấu trúc điều khiển (No Control Flow)**: LLM không thể viết vòng lặp `for`, rẽ nhánh `if/else`, pipe `|` dữ liệu giữa các công cụ trong cùng một bước mà phải chờ LLM turn tiếp theo.

---

### 1.2. Giải pháp: Lua / LuaJIT Code-Centric Agent Architecture
Chuyển đổi cơ chế tương tác công cụ của `mini` sang mô hình **Hybrid: Lua CodeAct + JSON Tool Fallback**, trong đó Lua CodeAct là phương thức ưu tiên:
- **Lua / LuaJIT Engine được nhúng trực tiếp (In-Process VM)** vào binary của `mini`.
- Toàn bộ công cụ của `mini` (`fs`, `grep`, `glob`, `http`, `sh`, `artifact`) được export thành **in-process C-ABI bindings** trong bảng toàn cục **`mini.*`**.
- Agent giải quyết các bài toán bằng cách **viết 1 đoạn script Lua** có đầy đủ logic (vòng lặp, điều kiện rẽ nhánh, chuỗi, bảng dữ liệu, xử lý lỗi), thực thi trực tiếp trong tiến trình.
- Khi script lỗi, agent tự nhận error output và **tự sửa lỗi qua vòng lặp Self-Correction** (tối đa 3 lần retry trước khi fallback về JSON tool-calling).

---

## 2. TẠI SAO CHỌN LUA & LUAJIT CHO MINI?

### 2.1. Bảng so sánh kỹ thuật

| Tiêu chí | Lua / LuaJIT Embedded Engine | Subprocess Bash / Python |
| :--- | :--- | :--- |
| **Tốc độ khởi động (Cold Start)** | **~0.01 ms** – Chạy trực tiếp trong tiến trình Zig, không cần spawn process | 10 – 100 ms (Spawn tiến trình OS mới) |
| **Mức độ phụ thuộc (Dependencies)** | **Zero external dependency** (Liên kết tĩnh `libluajit` vào binary `mini`) | Phụ thuộc vào Python/Node/Shell của máy host |
| **Giao tiếp Dữ liệu (Interoperability)** | **In-process C-ABI bindings**: Gọi hàm Zig qua Lua C API, dữ liệu được marshalled qua Lua stack (nhanh hơn IPC nhiều lần, nhưng có chi phí copy string giữa Zig allocator và Lua GC) | Chuyển đổi qua lại JSON string / Stdio pipes |
| **Khả năng Sandbox & Bảo mật** | **Kiểm soát tuyệt đối**: Tự định nghĩa bảng `_G` (whitelist), giới hạn bộ nhớ qua custom allocator, timeout qua OS-level thread kill | Khó kiểm soát khi script gọi shell bên ngoài |

### 2.2. Thẳng thắn về độ chính xác sinh mã Lua của LLM

Theo các benchmark đa ngôn ngữ (MultiPL-E, HumanEval multilingual), khả năng sinh mã Lua của LLM hiện tại **thấp hơn đáng kể** so với Python và JavaScript:

| Ngôn ngữ | Độ chính xác tương đối | Lý do |
|:---|:---|:---|
| Python | **Cao nhất** | Ngôn ngữ chính trong training data |
| JavaScript | Cao | Lượng training data khổng lồ từ web ecosystem |
| Bash | Trung bình / Thấp | Thiếu typing, cú pháp escape phức tạp |
| Lua | **Thấp hơn trung bình** | Hệ sinh thái nhỏ, ít training data |

**Tuy nhiên, điều này KHÔNG phủ nhận lựa chọn Lua cho `mini`** vì lý do sau:

1. **Constrained API Surface**: Agent không sinh mã Lua tổng quát (general-purpose). Agent chỉ sử dụng **đúng 12 hàm** trong bảng `mini.*` cố định. Đây là bài toán **constrained code generation** — LLM chỉ cần học 1 API surface nhỏ thay vì cả hệ sinh thái ngôn ngữ. Tương tự cách Neovim plugin sinh Lua gọi `vim.api.*` — API hẹp nhưng đủ mạnh.

2. **Few-Shot Prompting trong System Prompt**: System prompt sẽ bao gồm 3-5 ví dụ hoàn chỉnh mô tả cách sử dụng `mini.*` API, giúp LLM nắm chắc pattern trước khi sinh mã.

3. **Self-Correction Loop**: Khi Lua VM trả lỗi syntax hoặc runtime error, error message được gửi ngược về LLM để tự sửa. Vòng lặp retry (tối đa 3 lần) + fallback JSON tools đảm bảo agent luôn hoàn thành tác vụ.

---

## 3. CHIẾN LƯỢC HYBRID: LUA CODEACT + JSON TOOL FALLBACK

Proposal này **KHÔNG** xóa bỏ hệ thống JSON tool-calling hiện tại. Thay vào đó, áp dụng kiến trúc **Hybrid hai tầng**:

```
                         ┌──────────────────────────────────────┐
                         │       Agent Loop (agent_loop.zig)    │
                         └──────────────┬───────────────────────┘
                                        │
                    ┌───────────────────┴───────────────────┐
                    │                                       │
          [Ưu tiên: Lua CodeAct]              [Fallback: JSON Tool-Calling]
          - Model mạnh (Claude 3.7,           - Model yếu/nhỏ (phi-3,
            GPT-4o, Gemini 2.0)                 llama-3, local Ollama)
          - System Prompt chứa                - Giữ nguyên JSON schema
            mini.* API + ví dụ Lua              tools hiện tại
          - Code block extraction             - Không yêu cầu thay đổi
            từ markdown ```lua```               model behavior
```

### Cơ chế chuyển đổi:
- **Cấu hình `execution_mode`** trong `config.zig`:
  - `"codeact"` (mặc định cho model mạnh): LLM sinh Lua, thực thi qua VM.
  - `"tools"` (mặc định cho model yếu/local): Giữ nguyên JSON tool-calling.
  - `"auto"`: `mini` tự phát hiện model capability từ provider response để chọn mode.

---

## 4. THIẾT KẾ CẤU TRÚC CHI TIẾT (TARGET CODEBASE ARCHITECTURE)

```
src/
├── main.zig                # Composition root, CLI args parser & REPL loop
├── core/                   # Điều phối & Quản lý trạng thái
│   ├── agent_loop.zig      # Hybrid Loop (Lua CodeAct ↔ JSON Tools, Self-Correction)
│   ├── permissions.zig     # Dynamic Security (Ask / Auto / Yolo)
│   ├── history.zig         # State compaction & History quản lý code executions
│   └── contracts.zig       # Interfaces, Event types & Token specs
├── runtime/                # Môi trường thực thi LuaJIT
│   ├── luajit_engine.zig   # Quản lý lua_State, khởi tạo VM, sandbox _G, timeout
│   ├── lua_bindings.zig    # C-ABI Export toàn bộ Zig tools sang table `mini.*`
│   └── shell_runner.zig    # Subprocess runner phục vụ `mini.sh(...)` & `mini.sh_stream(...)`
├── stdlib/                 # Core Tool Implementations (Native Zig)
│   ├── fs_tools.zig        # read, write, patch (diff/exact/regex)
│   ├── search_tools.zig    # ripgrep, glob engine
│   ├── http_tools.zig      # HTTP client
│   └── artifact_tools.zig  # Artifact management
├── backend/                # Multi-provider LLM transport (OpenAI, Claude, Ollama)
├── tools/                  # [GIỮ NGUYÊN] JSON Tool handlers cho fallback mode
└── ui/                     # Terminal rendering & Streaming think/code parser
```

---

## 5. ĐẶC TẢ API BẢNG `mini.*` TRONG LUA RUNTIME

Khi Lua VM khởi động cho mỗi lượt chạy, môi trường được nạp sẵn bảng **`mini`** với các API sau:

```lua
-- ===========================================================================
-- BẢNG API mini CUNG CẤP CHO AGENT (v3 — Hardened)
-- ===========================================================================

-- 1. Tìm kiếm & Quét thư mục
mini.glob(pattern, [base_path])              --> table of string (danh sách đường dẫn)
mini.grep(pattern, [path], [options])        --> table of { path, line, text }

-- 2. Thao tác Tệp & Thư mục
mini.read(path, [offset_line], [limit_lines])--> string (nội dung tệp)
mini.write(path, content)                    --> boolean, string (thành công, thông điệp)
mini.patch(path, old_str, new_str, [opts])   --> boolean, string
  -- opts (table, optional):
  --   occurrence = N      (int, mặc định 1: thay thế lần xuất hiện thứ N, 0 = tất cả)
  --   regex      = false  (boolean: nếu true, old_str là Lua pattern)
  --   line_start = nil    (int: giới hạn tìm kiếm từ dòng này)
  --   line_end   = nil    (int: giới hạn tìm kiếm đến dòng này)
mini.exists(path)                            --> boolean
mini.stat(path)                              --> table { size, is_dir, is_file, modified }

-- 3. Thực thi Lệnh Hệ thống (Shell Bridge)
mini.sh(command, [stdin_str])                --> table { exit_code, stdout, stderr, ok }
  -- Dùng cho lệnh ngắn (< 10 giây). Output được buffer rồi trả về.
mini.sh_stream(command)                      --> int (exit_code)
  -- Dùng cho lệnh dài (build, test). Stdout/Stderr stream real-time ra terminal.
  -- Chỉ trả về exit_code khi lệnh kết thúc.

-- 4. HTTP & Mạng
mini.http(method, url, [headers], [body])    --> table { status, headers, body }

-- 5. Artifacts & Session Context
mini.artifact(name, content, [metadata])     --> string (đường dẫn artifact)
mini.env(var_name)                           --> string (lấy biến môi trường)
mini.workspace_root                          --> string (thư mục làm việc hiện tại)
mini.session_id                              --> string (ID phiên làm việc)
```

---

## 6. VÒNG LẶP TỰ SỬA LỖI (ERROR RECOVERY & SELF-CORRECTION LOOP)

Đây là yếu tố then chốt của kiến trúc CodeAct (theo Wang et al., 2024 — *"Executable Code Actions Elicit Better LLM Agents"*). Agent không chỉ chạy code một chiều mà có khả năng **tự debug và sửa lỗi**:

```
┌──────────────────────────────────────────────────────────────────────┐
│                     AGENT LOOP (1 User Request)                      │
│                                                                      │
│  [1] LLM sinh Lua code block                                        │
│       │                                                              │
│  [2] Extract code từ markdown ```lua ... ```                        │
│       │                                                              │
│  [3] Chạy trong LuaJIT VM (sandbox, timeout 30s)                    │
│       │                                                              │
│       ├── SUCCESS (exit ok, có output)                               │
│       │     └── Output được format + truncate → Gửi về LLM          │
│       │         └── LLM phân tích kết quả → trả lời user HOẶC      │
│       │             sinh thêm Lua code → quay lại [2]               │
│       │                                                              │
│       └── ERROR (syntax error / runtime error / timeout)             │
│             │                                                        │
│         [4] Format error message:                                    │
│             "[LUA ERROR] line 12: attempt to index nil value 'res'"  │
│             + Kèm source code gốc đã sinh                           │
│             │                                                        │
│         [5] Gửi error context về LLM                                 │
│             │                                                        │
│         [6] LLM sinh Lua code sửa lỗi → quay lại [2]               │
│             │                                                        │
│         [7] Nếu đã retry >= MAX_LUA_RETRIES (3):                    │
│             └── FALLBACK: Chuyển sang JSON tool-calling mode         │
│                 cho phần còn lại của request này                     │
└──────────────────────────────────────────────────────────────────────┘
```

### Các tình huống lỗi cụ thể và cách xử lý:

| Loại lỗi | Ví dụ | Hành động |
|:---|:---|:---|
| **Lua Syntax Error** | `unexpected symbol near ')'` | Gửi full error + source code về LLM, yêu cầu sửa |
| **Runtime Error** | `attempt to call nil value 'mini.grpe'` (typo) | Gửi error + gợi ý API đúng từ bảng `mini.*` |
| **Timeout** (> 30 giây) | Vòng lặp vô tận hoặc `mini.sh()` treo | Kill VM, thông báo LLM "script exceeded 30s timeout" |
| **Permission Denied** | User từ chối `mini.write(...)` | Gửi "user denied write to X" về LLM, LLM tự điều chỉnh kế hoạch |
| **Retry vượt ngưỡng** | 3 lần Lua đều lỗi | Fallback về JSON tool-calling, log cảnh báo cho developer |

---

## 7. MÔ HÌNH BẢO MẬT & SANDBOX TRONG LUA VM

### 7.1. Cô lập Môi trường (`_G` Whitelist Isolation)
- **Whitelist approach** (KHÔNG dùng blacklist): Tạo bảng `_G` mới hoàn toàn trống, chỉ nạp vào các module an toàn: `string`, `table`, `math`, `tonumber`, `tostring`, `type`, `pairs`, `ipairs`, `select`, `unpack`, `pcall`, `xpcall`.
- **Loại bỏ triệt để**: `os.*` (trừ `os.clock`), `io.*`, `debug.*`, `loadfile`, `dofile`, `require`, và đặc biệt **KHÔNG expose `ffi`** (ffi cho phép truy cập bộ nhớ trực tiếp, phá vỡ hoàn toàn sandbox).
- Redirect `print(...)` vào buffer nội bộ có giới hạn dung lượng (`MAX_OUTPUT_BUFFER = 64KB`). Khi vượt giới hạn, tự động cắt đầu (head truncation) và thêm cảnh báo `[OUTPUT TRUNCATED: showing last 64KB]`.

### 7.2. Cơ chế Timeout (OS-Level, không phụ thuộc Debug Hook)
- **Lý do không dùng `lua_sethook`**: `lua_sethook` instruction count hook **bị bỏ qua hoàn toàn** khi LuaJIT compile code sang native machine code (JIT mode). Ngay cả khi chạy interpreter mode, hook có chi phí hiệu suất đáng kể.
- **Giải pháp: OS-Level Thread Timeout**:
  1. Lua script được chạy trên một **thread riêng biệt** (`std.Thread` trong Zig).
  2. Thread chính đặt **wall-clock timer** (mặc định 30 giây).
  3. Nếu timer hết hạn: gọi `lua_sethook` với hook báo lỗi (dùng như tín hiệu interrupt) để dừng script gracefully. Nếu vẫn không dừng trong 1 giây tiếp theo: kill thread (abort).
  4. Bonus: LuaJIT chạy ở **interpreter mode** (`jit.off()`) cho sandboxed agent code. Mặc dù chậm hơn JIT ~5-10x, tốc độ Lua interpreter vẫn nhanh hơn subprocess rất nhiều, và đảm bảo debug hook hoạt động như cơ chế backup.

### 7.3. Giới hạn Bộ nhớ (Custom Allocator)
- Sử dụng **custom allocator** khi khởi tạo Lua state (`lua_newstate(alloc_fn, ud)`).
- Allocator theo dõi tổng bộ nhớ hiện đang sử dụng, từ chối cấp phát khi vượt ngưỡng (mặc định `MAX_LUA_MEMORY = 128MB`).
- Lưu ý: Allocator chỉ kiểm soát bộ nhớ cấp phát qua Lua API, không kiểm soát bộ nhớ từ các C library bên ngoài (nhưng trong thiết kế của `mini`, tất cả logic nặng đều chạy ở phía Zig native, Lua chỉ là lớp điều phối).

### 7.4. Phân quyền Tương tác (Permission Interceptor)
Mọi hàm trong bảng `mini.*` có khả năng thay đổi trạng thái máy (như `mini.write`, `mini.patch`, `mini.sh`) đều được kiểm tra qua `permissions.zig`:
- **`ask` (Mặc định)**: Tạm dừng luồng thực thi Lua (yield coroutine), bật prompt xác nhận với người dùng trên Terminal.
- **`auto`**: Cho phép tự động các thao tác an toàn (đọc/tìm kiếm), chỉ hỏi khi chạy lệnh shell nguy hiểm.
- **`yolo`**: Cho phép toàn bộ tự động (dành cho CI/CD hoặc Container).

---

## 8. VÍ DỤ MINH HỌA: KỊCH BẢN AGENT DÙNG LUA XỬ LÝ TRONG 1 TURN

### Tình huống: Quét toàn bộ codebase, tìm các hàm mở thư mục thiếu `.iterate = true`, sửa code và chạy test xác nhận:

```lua
-- LLM sinh ra đoạn mã Lua sau trong 1 Turn duy nhất:
local modified_files = {}

-- 1. Tìm toàn bộ file .zig trong src
local files = mini.glob("**/*.zig", "src")
print(string.format("Đang quét %d tệp Zig...", #files))

-- 2. Duyệt và sửa các file có lỗi logic
for _, file in ipairs(files) do
    local content = mini.read(file)
    if content and content:find("openDir%(io, [^,]+, %.{}%)") then
        local ok, msg = mini.patch(file,
            "openDir(io, search_path, .{})",
            "openDir(io, search_path, .{ .iterate = true })")
        if ok then
            table.insert(modified_files, file)
            print("  ✓ Đã vá lỗi trong: " .. file)
        else
            print("  ✗ Lỗi khi patch " .. file .. ": " .. (msg or "unknown"))
        end
    end
end

print(string.format("\nTổng cộng đã sửa: %d tệp.", #modified_files))

-- 3. Chạy test kiểm tra kết quả (streaming output ra terminal)
if #modified_files > 0 then
    print("\n--- Đang chạy zig build test ---")
    local exit_code = mini.sh_stream("zig build test")
    if exit_code == 0 then
        print("✓ Toàn bộ Unit Tests đã PASS!")
    else
        print("✗ Test thất bại với exit code: " .. exit_code)
    end
end
```

---

## 9. ĐÁNH GIÁ HIỆU NĂNG & LỢI ÍCH (DỰ KIẾN)

> **Lưu ý**: Các con số dưới đây là **ước lượng lý thuyết** dựa trên phân tích cấu trúc tác vụ và tham chiếu kết quả từ paper CodeAct (Wang et al., 2024 — *"Executable Code Actions Elicit Better LLM Agents"*, benchmark trên M3ToolEval). **Cần benchmark thực tế A/B trên 10-20 tác vụ thực** sau khi triển khai Giai đoạn 1 để xác nhận.

| Tiêu chí | Mô hình JSON Tool-Calling (Cũ) | Mô hình LuaJIT CodeAct (Mới) | Dự kiến cải thiện |
| :--- | :--- | :--- | :--- |
| **Số LLM Turns (Tác vụ 4 bước)** | 6 – 10 Turns | 2 – 4 Turns (bao gồm retry) | **Giảm ~50% – 60%** (*) |
| **Thời gian thực thi local** | ~0 (tool xử lý in-process) | ~0 (Lua VM in-process) | Tương đương |
| **Token tiêu tốn cho Context** | 15,000 – 30,000 tokens (raw output) | 3,000 – 8,000 tokens (filtered output) | **Tiết kiệm ~60% – 70%** |
| **Độ linh hoạt giải thuật** | Không có (Phụ thuộc từng bước JSON) | Đầy đủ (vòng lặp, điều kiện, tables) | **Không giới hạn** |

(*) Paper CodeAct gốc báo cáo giảm 30-40% turn trên M3ToolEval (Python). Con số có thể cao hơn hoặc thấp hơn cho Lua do bài toán constrained API khác với general-purpose coding.

---

## 10. LỘ TRÌNH TRIỂN KHAI 4 GIAI ĐOẠN (IMPLEMENTATION ROADMAP)

### Giai đoạn 1: LuaJIT Engine & C-ABI Bindings (Core Runtime)
- [ ] Tích hợp `luajit` vào build system (`build.zig`) sử dụng package `zig-luajit-build`.
- [ ] Xây dựng `src/runtime/luajit_engine.zig`:
  - Khởi tạo `lua_State` với custom memory allocator (giới hạn 128MB).
  - Sandbox `_G` (whitelist approach).
  - OS-level thread timeout (30s wall-clock).
  - Output buffer collector (64KB cap + head truncation).
- [ ] Xây dựng `src/runtime/lua_bindings.zig`:
  - Export tất cả hàm `mini.*` (glob, grep, read, write, patch, sh, sh_stream, http, artifact, exists, stat, env).
  - Mỗi binding: pop args từ Lua stack → gọi Zig native → push result lên Lua stack.
  - Tích hợp permission check vào write/patch/sh bindings.
- [ ] **Benchmark A/B** (bắt buộc): So sánh 10 tác vụ thực giữa JSON tools và Lua CodeAct, đo: số turn, tổng token, wall-clock time, tỷ lệ lỗi cú pháp.

### Giai đoạn 2: CodeAct Agent Loop & Hybrid Dispatcher
- [ ] Nâng cấp `src/core/agent_loop.zig`:
  - Thêm Lua CodeBlock extractor (nhận diện ````lua ... ```` trong streaming response).
  - Thêm Self-Correction Loop (retry tối đa 3 lần, fallback JSON tools).
  - Config `execution_mode`: `"codeact"` | `"tools"` | `"auto"`.
- [ ] Cập nhật System Prompt: Bao gồm API reference `mini.*` + 3-5 ví dụ few-shot hoàn chỉnh.
- [ ] **Giữ nguyên** toàn bộ JSON tool handlers hiện tại trong `src/tools/` cho fallback mode.

### Giai đoạn 3: Dynamic Permissions & Output Optimization
- [ ] Tích hợp `src/core/permissions.zig` vào C-ABI bindings (sử dụng Lua coroutine yield để tạm dừng execution khi chờ user confirm).
- [ ] Thiết lập cơ chế smart truncation: head/tail truncation cho output > 64KB trước khi nạp vào LLM context.

### Giai đoạn 4: ACP (Agent Control Protocol) & Headless Embeddability
- [ ] Hỗ trợ giao thức JSON-RPC ACP để các IDE (VS Code, Cursor) hoặc Web UI có thể nhúng và điều khiển `mini` từ xa.
