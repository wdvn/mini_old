# PROPOSAL: LUA / LUAJIT EMBEDDED CODE-CENTRIC AGENT ARCHITECTURE CHO MINI
> **Document**: RFC-001 (Revision 2 - LuaJIT Interpreter Core)  
> **Status**: Draft / In Review  
> **Target System**: `mini-agent` (`mini`)  
> **Core Interpreter**: **Embedded Lua 5.1 / LuaJIT Runtime**  
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

### 1.2. Giải pháp: Lua / LuaJIT Code-Centric Agent Architecture
Chuyển đổi toàn bộ cơ chế tương tác công cụ của `mini` sang mô hình **Thực thi Mã Lua thông qua Embedded Lua / LuaJIT Interpreter**:
- **Lua / LuaJIT Engine được nhúng trực tiếp (In-Process VM)** vào binary của `mini`.
- Toàn bộ công cụ của `mini` (`fs`, `grep`, `glob`, `http`, `sh`, `artifact`, `subagent`) được export trực tiếp thành native C/Zig bindings trong bảng toàn cục **`mini.*`**.
- Agent giải quyết các bài toán bằng cách **viết 1 đoạn script Lua duy nhất** có đầy đủ logic (vòng lặp, điều kiện rẽ nhánh, chuỗi, bảng dữ liệu, xử lý lỗi), thực thi trực tiếp trong tiến trình với tốc độ microsecond.
- **Tiết kiệm 80% - 90% Token**: Dữ liệu trung gian được lọc, biến đổi và tổng hợp ngay bên trong Lua VM, chỉ có kết quả chắt lọc cuối cùng (`print(...)`) mới được gửi về cho LLM.

---

## 2. TẠI SAO CHỌN LUA & LUAJIT CHO MINI?

| Tiêu chí | Lua / LuaJIT Embedded Engine | Subprocess Bash / Python |
| :--- | :--- | :--- |
| **Tốc độ khởi động (Cold Start)** | **0.001 ms (Tức thì)** – Chạy trực tiếp trong tiến trình Zig | 10 – 100 ms (Phải spawn tiến trình OS mới) |
| **Mức độ phụ thuộc (Dependencies)** | **Zero external dependency** (Liên kết tĩnh `libluajit` vào binary `mini`) | Phụ thuộc vào Python/Node/Shell của máy host |
| **Giao tiếp Dữ liệu (Interoperability)** | **In-memory Zero-Copy C/Zig FFI**: Gọi trực tiếp hàm Zig qua C API | Chuyển đổi qua lại JSON string / Stdio pipes |
| **Khả năng Sandbox & Bảo mật** | **Kiểm soát tuyệt đối**: Tự định nghĩa bảng `_G`, giới hạn bộ nhớ, cài đặt execution instruction count hook | Khó kiểm soát khi script gọi shell bên ngoài |
| **Độ chính xác sinh mã của LLM** | **Cực kỳ xuất sắc**: Cú pháp Lua ngắn gọn, bảng (table) linh hoạt, LLMs ít khi bị lỗi cú pháp | Bash dễ bị lỗi escape quote hoặc khác biệt cú pháp OS |

---

## 3. THIẾT KẾ CẤU TRÚC CHI TIẾT (TARGET CODEBASE ARCHITECTURE)

```
src/
├── main.zig                # Composition root, CLI args parser & REPL loop
├── core/                   # Điều phối & Quản lý trạng thái
│   ├── agent_loop.zig      # CodeAct Loop (Stream -> Extract Lua -> Run VM -> Feedback)
│   ├── permissions.zig     # Dynamic Security (Ask / Auto / Yolo)
│   ├── history.zig         # State compaction & History quản lý code executions
│   └── contracts.zig       # Interfaces, Event types & Token specs
├── runtime/                # Môi trường thực thi LuaJIT
│   ├── luajit_engine.zig   # Quản lý lua_State, khởi tạo VM, sandbox, timeout hook
│   ├── lua_bindings.zig    # C-FFI Export toàn bộ Zig tools sang table `mini.*`
│   └── shell_runner.zig    # Subprocess runner phục vụ `mini.sh(...)`
├── stdlib/                 # Core Tool Implementations (Native Zig)
│   ├── fs_tools.zig        # read, write, patch (diff/exact)
│   ├── search_tools.zig    # ripgrep, glob engine
│   ├── http_tools.zig      # HTTP client
│   └── artifact_tools.zig  # Artifact management
├── backend/                # Multi-provider LLM transport (OpenAI, Claude, Ollama)
└── ui/                     # Terminal rendering & Streaming think/code parser
```

---

## 4. ĐẶC TẢ API BẢNG `mini.*` TRONG LUA RUNTIME

Khi Lua VM khởi động cho mỗi lượt chạy, môi trường được nạp sẵn bảng **`mini`** với các API sau:

```lua
-- ===========================================================================
-- BẢNG API mini CUNG CẤP CHO AGENT
-- ===========================================================================

-- 1. Tìm kiếm & Quét thư mục
mini.glob(pattern, [base_path])              --> table of string (danh sách đường dẫn)
mini.grep(pattern, [path], [options])        --> table of { path, line, text }

-- 2. Thao tác Tệp & Thư mục
mini.read(path, [offset_line], [limit_lines])--> string (nội dung tệp)
mini.write(path, content)                    --> boolean, string (thành công, thông điệp)
mini.patch(path, old_str, new_str)           --> boolean, string (thay thế chuỗi duy nhất)
mini.exists(path)                            --> boolean
mini.stat(path)                              --> table { size, is_dir, is_file, modified }

-- 3. Thực thi Lệnh Hệ thống (Shell Bridge)
mini.sh(command, [stdin_str])                --> table { exit_code, stdout, stderr, ok }

-- 4. HTTP & Mạng
mini.http(method, url, [headers], [body])    --> table { status, headers, body }

-- 5. Artifacts & Session Context
mini.artifact(name, content, [metadata])     --> string (đường dẫn artifact)
mini.env(var_name)                           --> string (lấy biến môi trường)
mini.workspace_root                          --> string (thư mục làm việc hiện tại)
mini.session_id                              --> string (ID phiên làm việc)
```

---

## 5. VÍ DỤ MINH HỌA: KỊCH BẢN AGENT DÙNG LUA XỬ LÝ TRONG 1 TURN

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
    if content and content:find("openDir%(io, [^,]+, %{}%)") then
        local ok, msg = mini.patch(file, "openDir(io, search_path, .{})", "openDir(io, search_path, .{ .iterate = true })")
        if ok then
            table.insert(modified_files, file)
            print("  ✓ Đã vá lỗi trong: " .. file)
        end
    end
end

print(string.format("Tổng cộng đã sửa: %d tệp.", #modified_files))

-- 3. Chạy test kiểm tra kết quả ngay lập tức
if #modified_files > 0 then
    print("\n--- Đang chạy zig build test ---")
    local res = mini.sh("zig build test")
    if res.exit_code == 0 then
        print("✓ Toàn bộ Unit Tests đã PASS thành công!")
    else
        print("✗ Test thất bại:\n" .. res.stderr)
    end
end
```

**Kết quả trả về cho LLM**:
```text
Đang quét 12 tệp Zig...
  ✓ Đã vá lỗi trong: src/tools/grep.zig
Tổng cộng đã sửa: 1 tệp.

--- Đang chạy zig build test ---
✓ Toàn bộ Unit Tests đã PASS thành công!
```
$\rightarrow$ **Chỉ mất đúng 1 Turn mạng**, toàn bộ quá trình duyệt file, đọc file, regex, sửa code, và compile test được thực thi cục bộ trong chưa đầy **0.3 giây**.

---

## 6. MÔ HÌNH BẢO MẬT & SANDBOX TRONG LUA VM

### 6.1. Cô lập Môi trường Bytecode (`_G` Isolation)
- Gỡ bỏ các hàm nguy hiểm mặc định của Lua: `os.remove`, `os.rename`, `os.tmpname`, module `debug`.
- Redirect toàn bộ hàm `print(...)` và `io.write(...)` vào buffer nội bộ có giới hạn dung lượng (`MAX_OUTPUT_BUFFER = 64KB`).
- Cài đặt **Lua Debug Hook (`lua_sethook`)** đếm số instruction bytecode đã thực thi để ngăn chặn vòng lặp vô tận (`while true do end`) với timeout mặc định 30 giây.

### 6.2. Phân quyền Tương tác (Permission Interceptor)
Mọi hàm trong bảng `mini.*` có khả năng thay đổi trạng thái máy (như `mini.write`, `mini.patch`, `mini.sh`) đều được kiểm tra qua `permissions.zig`:
- **`ask`**: Tạm dừng luồng thực thi Lua và bật prompt xác nhận với người dùng trên Terminal.
- **`auto`**: Cho phép tự động các thao tác an toàn (đọc/tìm kiếm), chỉ hỏi khi chạy lệnh shell nguy hiểm.
- **`yolo`**: Cho phép toàn bộ tự động.

---

## 7. ĐÁNH GIÁ HIỆU NĂNG & LỢI ÍCH

| Tiêu chí | Mô hình JSON Tool-Calling (Cũ) | Mô hình LuaJIT CodeAct (Mới) | Mức cải thiện |
| :--- | :--- | :--- | :--- |
| **Số LLM Turns (Tác vụ 4 bước)** | 6 – 10 Turns | **1 Turn duy nhất** | **Giảm 80% – 90%** |
| **Thời gian thực thi trung gian** | 20 – 40 giây (Chờ roundtrip API) | **< 0.5 giây (Native LuaJIT)** | **Nhanh hơn 50x** |
| **Token tiêu tốn cho Context** | 15,000 – 30,000 tokens | **1,500 – 3,000 tokens** | **Tiết kiệm 90%** |
| **Độ linh hoạt giải thuật** | Không có (Phụ thuộc từng bước JSON) | **Đầy đủ cấu trúc dữ liệu & logic Lua** | **Không giới hạn** |

---

## 8. LỘ TRÌNH TRIỂN KHAI 4 GIAI ĐOẠN (IMPLEMENTATION ROADMAP)

### Giai đoạn 1: LuaJIT Engine & C-FFI Bindings (Core Runtime)
- [ ] Tích hợp `luajit` / `lua5.1` vào build system (`build.zig`).
- [ ] Xây dựng `src/runtime/luajit_engine.zig` (Khởi tạo `lua_State`, Sandbox `_G`, Output collector, Timeout hook).
- [ ] Xây dựng `src/runtime/lua_bindings.zig` (Export các hàm `mini.glob`, `mini.grep`, `mini.read`, `mini.write`, `mini.patch`, `mini.sh`).

### Giai đoạn 2: CodeAct Agent Loop & System Prompt Update
- [ ] Nâng cấp `src/core/agent_loop.zig`: Thay thế JSON tool dispatcher bằng Lua CodeBlock extractor và LuaJIT executor.
- [ ] Cập nhật System Prompt hướng dẫn LLM cách sử dụng bảng `mini.*` trong Lua.

### Giai đoạn 3: Dynamic Permissions & Sandbox Safety
- [ ] Tích hợp `src/core/permissions.zig` vào các C-FFI bindings (`mini.write`, `mini.patch`, `mini.sh`).
- [ ] Thiết lập cơ chế head/tail truncation cho output trả về context LLM.

### Giai đoạn 4: ACP (Agent Control Protocol) & Headless Embeddability
- [ ] Hỗ trợ giao thức JSON-RPC ACP để các IDE (VS Code, Cursor) hoặc Web UI có thể nhúng và điều khiển `mini` từ xa.
