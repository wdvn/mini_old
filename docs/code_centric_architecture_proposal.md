# PROPOSAL: QUICKJS EMBEDDED CODE-CENTRIC AGENT ARCHITECTURE CHO MINI
> **Document**: RFC-001 (Revision 4 — QuickJS-ng Engine)  
> **Status**: Draft / In Review  
> **Target System**: `mini-agent` (`mini`)  
> **Core Interpreter**: **Embedded QuickJS-ng (ES2023 JavaScript Runtime)**  
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

### 1.2. Giải pháp: QuickJS Code-Centric Agent Architecture
Chuyển đổi cơ chế tương tác công cụ của `mini` sang mô hình **Hybrid: JavaScript CodeAct + JSON Tool Fallback**, trong đó JavaScript CodeAct là phương thức ưu tiên:
- **QuickJS-ng Engine được nhúng trực tiếp (In-Process VM)** vào binary của `mini` — zero external dependency, ~200-300KB static link.
- Toàn bộ công cụ của `mini` (`fs`, `grep`, `glob`, `http`, `sh`, `artifact`) được export thành **in-process C-ABI bindings** trong object toàn cục **`mini.*`**.
- Agent giải quyết bài toán bằng cách **viết 1 đoạn script JavaScript** có đầy đủ logic (vòng lặp, điều kiện, try/catch, async/await, array methods), thực thi trực tiếp trong tiến trình.
- Khi script lỗi, agent tự nhận error output (kèm stack trace) và **tự sửa lỗi qua vòng lặp Self-Correction** (tối đa 3 lần retry trước khi fallback về JSON tool-calling).

---

## 2. TẠI SAO CHỌN QUICKJS (JAVASCRIPT) CHO MINI?

### 2.1. Lý do lựa chọn cốt lõi

Quyết định chọn QuickJS thay vì LuaJIT dựa trên phân tích so sánh toàn diện 12 khía cạnh (xem chi tiết tại `docs/luajit_vs_quickjs_comparison.md`). Ba lý do then chốt:

#### A. LLM sinh mã JavaScript chính xác áp đảo so với mọi lựa chọn khác

Theo benchmark MultiPL-E và HumanEval-X (2024-2025):

| Ngôn ngữ | Pass@1 tương đối (GPT-4o) | Lý do |
|:---|:---|:---|
| Python | ~85-92% | Gold standard, training data khổng lồ |
| **JavaScript** | **~80-88%** | **Top-2, gần bằng Python** |
| Bash | ~55-70% | Lỗi quote/escape thường xuyên |
| Lua | ~45-60% | Ít training data, LLM hay nhầm cú pháp |

Trong kiến trúc CodeAct, **độ chính xác sinh mã là yếu tố sống còn**. Nếu agent sinh mã sai → cần thêm turn để debug → triệt tiêu lợi ích "1 Turn duy nhất". JavaScript có lượng training data lớn thứ 2 (sau Python) từ npm, GitHub, StackOverflow, MDN — đảm bảo LLM viết JS đúng và tự nhiên.

#### B. Sandbox là first-class feature của QuickJS — không cần workaround

```c
// 3 dòng code — sandbox hoàn chỉnh:
JS_SetMemoryLimit(rt, 128 * 1024 * 1024);              // Giới hạn bộ nhớ 128MB
JS_SetMaxStackSize(rt, 1024 * 1024);                     // Giới hạn stack 1MB
JS_SetInterruptHandler(rt, timeout_handler, &deadline);  // Wall-clock timeout
```

So sánh: LuaJIT yêu cầu tắt JIT (`jit.off()`) để `lua_sethook` hoạt động (mất toàn bộ lợi thế tốc độ JIT), phải tự viết custom allocator cho memory limit, và tự build OS-level thread kill cho timeout.

#### C. Portable tuyệt đối & Async/Await native

- **QuickJS là pure C interpreter**: Chạy mọi nơi Zig compiler hỗ trợ — x86, ARM, RISC-V, WASM. LuaJIT JIT chỉ support x86/ARM, không hỗ trợ RISC-V.
- **Native async/await + Promise**: Mở cánh cửa cho concurrent operations tương lai (gọi song song nhiều HTTP request, nhiều shell command).

### 2.2. Bảng so sánh kỹ thuật

| Tiêu chí | QuickJS-ng (JavaScript) | Subprocess Bash / Python |
| :--- | :--- | :--- |
| **Tốc độ khởi động** | **~0.01 ms** – Chạy trực tiếp trong tiến trình Zig | 10 – 100 ms (Spawn tiến trình OS mới) |
| **Dependencies** | **Zero** (Static link ~200-300KB vào binary `mini`) | Phụ thuộc Python/Node/Shell của host |
| **Giao tiếp dữ liệu** | **In-process C-ABI bindings**: Gọi hàm Zig qua QuickJS C API, dữ liệu marshalled qua JS value stack | Chuyển đổi qua lại JSON string / Stdio pipes |
| **Sandbox** | **Native API**: `JS_SetMemoryLimit`, `JS_SetInterruptHandler`, `JS_SetMaxStackSize` | Khó kiểm soát khi script gọi shell |
| **LLM Code Accuracy** | **Top-2** (gần bằng Python, ~80-88% Pass@1) | Bash: ~55-70% (hay lỗi escape) |

---

## 3. CHIẾN LƯỢC HYBRID: JS CODEACT + JSON TOOL FALLBACK

Proposal này **KHÔNG** xóa bỏ hệ thống JSON tool-calling hiện tại. Thay vào đó, áp dụng kiến trúc **Hybrid hai tầng**:

```
                         ┌──────────────────────────────────────┐
                         │       Agent Loop (agent_loop.zig)    │
                         └──────────────┬───────────────────────┘
                                        │
                    ┌───────────────────┴───────────────────┐
                    │                                       │
          [Ưu tiên: JS CodeAct]               [Fallback: JSON Tool-Calling]
          - Model mạnh (Claude 3.7,           - Model yếu/nhỏ (phi-3,
            GPT-4o, Gemini 2.0)                 llama-3, local Ollama)
          - System Prompt chứa                - Giữ nguyên JSON schema
            mini.* API + ví dụ JS               tools hiện tại
          - Code block extraction             - Không yêu cầu thay đổi
            từ markdown ```js```                model behavior
```

### Cơ chế chuyển đổi:
- **Cấu hình `execution_mode`** trong `config.zig`:
  - `"codeact"` (mặc định cho model mạnh): LLM sinh JavaScript, thực thi qua QuickJS VM.
  - `"tools"` (mặc định cho model yếu/local): Giữ nguyên JSON tool-calling.
  - `"auto"`: `mini` tự phát hiện model capability từ provider response để chọn mode.

---

## 4. THIẾT KẾ CẤU TRÚC CHI TIẾT (TARGET CODEBASE ARCHITECTURE)

```
src/
├── main.zig                # Composition root, CLI args parser & REPL loop
├── core/                   # Điều phối & Quản lý trạng thái
│   ├── agent_loop.zig      # Hybrid Loop (JS CodeAct ↔ JSON Tools, Self-Correction)
│   ├── permissions.zig     # Dynamic Security (Ask / Auto / Yolo)
│   ├── history.zig         # State compaction & History quản lý code executions
│   └── contracts.zig       # Interfaces, Event types & Token specs
├── runtime/                # Môi trường thực thi QuickJS
│   ├── quickjs_engine.zig  # Quản lý JSRuntime/JSContext, sandbox, timeout, memory limit
│   ├── js_bindings.zig     # C-ABI Export toàn bộ Zig tools sang object `mini.*`
│   └── shell_runner.zig    # Subprocess runner phục vụ `mini.sh(...)` & `mini.shStream(...)`
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

## 5. ĐẶC TẢ API OBJECT `mini.*` TRONG QUICKJS RUNTIME

Khi QuickJS VM khởi động cho mỗi lượt chạy, môi trường được nạp sẵn object toàn cục **`mini`** với các API sau:

```javascript
// ===========================================================================
// API OBJECT mini CUNG CẤP CHO AGENT (QuickJS Runtime v4)
// ===========================================================================

// 1. Tìm kiếm & Quét thư mục
mini.glob(pattern, basePath?)              // → string[] (danh sách đường dẫn)
mini.grep(pattern, path?, options?)        // → Array<{ path, line, text }>

// 2. Thao tác Tệp & Thư mục
mini.read(path, offsetLine?, limitLines?)  // → string (nội dung tệp)
mini.write(path, content)                  // → { ok: boolean, message: string }
mini.patch(path, oldStr, newStr, opts?)    // → { ok: boolean, message: string }
  // opts (object, optional):
  //   occurrence: number   (mặc định 1: thay thế lần thứ N, 0 = tất cả)
  //   regex: boolean       (nếu true, oldStr là regex pattern)
  //   lineStart: number    (giới hạn tìm kiếm từ dòng này)
  //   lineEnd: number      (giới hạn tìm kiếm đến dòng này)
mini.exists(path)                          // → boolean
mini.stat(path)                            // → { size, isDir, isFile, modified }

// 3. Thực thi Lệnh Hệ thống (Shell Bridge)
mini.sh(command, stdinStr?)                // → { exitCode, stdout, stderr, ok }
  // Dùng cho lệnh ngắn (< 10 giây). Output được buffer rồi trả về.
mini.shStream(command)                     // → number (exitCode)
  // Dùng cho lệnh dài (build, test). Stdout/Stderr stream real-time ra terminal.

// 4. HTTP & Mạng
mini.http(method, url, headers?, body?)    // → { status, headers, body }

// 5. Artifacts & Session Context
mini.artifact(name, content, metadata?)    // → string (đường dẫn artifact)
mini.env(varName)                          // → string (lấy biến môi trường)
mini.workspaceRoot                         // → string (thư mục làm việc)
mini.sessionId                             // → string (ID phiên làm việc)

// 6. Async Operations (Future — Giai đoạn 3+)
// await mini.httpAsync(method, url, headers?, body?)
// await Promise.all([mini.httpAsync(...), mini.httpAsync(...)])
```

---

## 6. VÒNG LẶP TỰ SỬA LỖI (ERROR RECOVERY & SELF-CORRECTION LOOP)

Đây là yếu tố then chốt của kiến trúc CodeAct (theo Wang et al., 2024 — *"Executable Code Actions Elicit Better LLM Agents"*). Agent không chỉ chạy code một chiều mà có khả năng **tự debug và sửa lỗi**:

```
┌──────────────────────────────────────────────────────────────────────┐
│                     AGENT LOOP (1 User Request)                      │
│                                                                      │
│  [1] LLM sinh JavaScript code block                                  │
│       │                                                              │
│  [2] Extract code từ markdown ```js ... ```                         │
│       │                                                              │
│  [3] Chạy trong QuickJS VM (sandbox, timeout 30s, mem 128MB)        │
│       │                                                              │
│       ├── SUCCESS (exit ok, có output)                               │
│       │     └── Output được format + truncate → Gửi về LLM          │
│       │         └── LLM phân tích kết quả → trả lời user HOẶC      │
│       │             sinh thêm JS code → quay lại [2]                │
│       │                                                              │
│       └── ERROR (syntax error / runtime error / timeout)             │
│             │                                                        │
│         [4] Format error message:                                    │
│             "[JS ERROR] TypeError: mini.grpe is not a function       │
│              at <eval>:12:15"                                        │
│             + Stack trace tự động từ Error object                    │
│             + Source code gốc đã sinh                                │
│             │                                                        │
│         [5] Gửi error context về LLM                                 │
│             │                                                        │
│         [6] LLM sinh JS code sửa lỗi → quay lại [2]                │
│             │                                                        │
│         [7] Nếu đã retry >= MAX_JS_RETRIES (3):                     │
│             └── FALLBACK: Chuyển sang JSON tool-calling mode         │
│                 cho phần còn lại của request này                     │
└──────────────────────────────────────────────────────────────────────┘
```

### Các tình huống lỗi cụ thể và cách xử lý:

| Loại lỗi | Ví dụ | Hành động |
|:---|:---|:---|
| **Syntax Error** | `SyntaxError: unexpected token ')'` | Gửi error + source code + stack trace về LLM |
| **Runtime Error** | `TypeError: mini.grpe is not a function` (typo) | Gửi error + gợi ý API đúng từ object `mini.*` |
| **Timeout** (> 30 giây) | Vòng lặp vô tận hoặc `mini.sh()` treo | Interrupt handler dừng VM, thông báo LLM |
| **Memory Exceeded** | Script tạo quá nhiều object | `JS_SetMemoryLimit` tự động reject allocation |
| **Permission Denied** | User từ chối `mini.write(...)` | Gửi "user denied write to X" về LLM |
| **Retry vượt ngưỡng** | 3 lần JS đều lỗi | Fallback về JSON tool-calling, log cảnh báo |

### Lợi thế JavaScript cho Error Recovery:
JavaScript `Error` object tự động kèm **stack trace** (`e.stack`) — giúp LLM xác định chính xác dòng lỗi mà không cần module `debug` đặc biệt. `try/catch` là pattern LLM viết cực kỳ chính xác (hàng tỷ dòng training data).

---

## 7. MÔ HÌNH BẢO MẬT & SANDBOX TRONG QUICKJS VM

### 7.1. Resource Limits (Native API)
QuickJS cung cấp API sandbox native, không cần workaround:

```c
// Trong quickjs_engine.zig — khởi tạo sandbox:
JSRuntime *rt = JS_NewRuntime();

// 1. Giới hạn bộ nhớ: 128MB
JS_SetMemoryLimit(rt, 128 * 1024 * 1024);

// 2. Giới hạn stack: 1MB (chống stack overflow / deep recursion)
JS_SetMaxStackSize(rt, 1024 * 1024);

// 3. Interrupt handler: wall-clock timeout 30 giây
JS_SetInterruptHandler(rt, timeout_check, &deadline);
// timeout_check(rt, opaque): return 1 khi wall-clock > 30s → VM dừng ngay
```

- **Hoạt động chính xác mọi lúc**: QuickJS là pure interpreter, không có vấn đề JIT bypass hook như LuaJIT.
- **Deterministic memory**: QuickJS dùng reference counting + cycle detection → bộ nhớ được giải phóng xác định.

### 7.2. Environment Isolation (Whitelist Approach)
- Tạo `JSContext` mới hoàn toàn trống, chỉ nạp vào:
  - **Allowed**: `console.log`, `JSON`, `Math`, `String`, `Array`, `Object`, `Number`, `Boolean`, `Date`, `RegExp`, `Map`, `Set`, `Promise`, `Error`, `parseInt`, `parseFloat`, `typeof`, `instanceof`.
  - **Cho phép thận trọng**: `setTimeout` (qua interrupt handler), `TextEncoder`/`TextDecoder`.
  - **Loại bỏ triệt để**: `eval()`, `Function()` constructor, `import()`, module system, `globalThis.Atomics`, `SharedArrayBuffer`, và bất kỳ API nào cho phép tạo code từ string.
- **QuickJS không có FFI module** → không có attack vector truy cập memory trực tiếp (khác LuaJIT `ffi`).

### 7.3. Output Buffer Limit
- `console.log(...)` được redirect vào buffer nội bộ có giới hạn `MAX_OUTPUT_BUFFER = 64KB`.
- Khi vượt giới hạn: tự động head truncation + cảnh báo `[OUTPUT TRUNCATED: showing last 64KB]`.

### 7.4. Phân quyền Tương tác (Permission Interceptor)
Mọi hàm trong object `mini.*` có khả năng thay đổi trạng thái máy (như `mini.write`, `mini.patch`, `mini.sh`) đều được kiểm tra qua `permissions.zig`:
- **`ask` (Mặc định)**: Tạm dừng thực thi JS (interrupt execution), bật prompt xác nhận trên Terminal.
- **`auto`**: Cho phép tự động các thao tác an toàn (đọc/tìm kiếm), chỉ hỏi khi chạy lệnh shell nguy hiểm.
- **`yolo`**: Cho phép toàn bộ tự động (dành cho CI/CD hoặc Container).

---

## 8. VÍ DỤ MINH HỌA: KỊCH BẢN AGENT DÙNG JS XỬ LÝ TRONG 1 TURN

### Tình huống: Quét codebase, tìm các hàm mở thư mục thiếu `.iterate = true`, sửa code và chạy test:

```javascript
// LLM sinh ra đoạn mã JavaScript sau trong 1 Turn duy nhất:
const files = mini.glob("**/*.zig", "src");
console.log(`Đang quét ${files.length} tệp Zig...`);

const modified = [];

for (const file of files) {
    const content = mini.read(file);
    if (content && content.includes("openDir(io, search_path, .{})")) {
        const { ok, message } = mini.patch(
            file,
            "openDir(io, search_path, .{})",
            "openDir(io, search_path, .{ .iterate = true })"
        );
        if (ok) {
            modified.push(file);
            console.log(`  ✓ Đã vá lỗi trong: ${file}`);
        } else {
            console.log(`  ✗ Lỗi khi patch ${file}: ${message}`);
        }
    }
}

console.log(`\nTổng cộng đã sửa: ${modified.length} tệp.`);

// Chạy test (streaming output ra terminal)
if (modified.length > 0) {
    console.log("\n--- Đang chạy zig build test ---");
    const exitCode = mini.shStream("zig build test");
    if (exitCode === 0) {
        console.log("✓ Toàn bộ Unit Tests đã PASS!");
    } else {
        console.log(`✗ Test thất bại với exit code: ${exitCode}`);
    }
}
```

### Tình huống nâng cao (Giai đoạn 3+): Gọi song song nhiều HTTP request:
```javascript
// Async/await native — pattern mà LLM viết cực kỳ chính xác:
const urls = ["https://api.github.com/repos/a", "https://api.github.com/repos/b"];

const results = await Promise.all(
    urls.map(url => mini.httpAsync("GET", url))
);

const summary = results
    .filter(r => r.status === 200)
    .map(r => JSON.parse(r.body).full_name);

console.log(`Tìm thấy ${summary.length} repos: ${summary.join(", ")}`);
```

---

## 9. ĐÁNH GIÁ HIỆU NĂNG & LỢI ÍCH (DỰ KIẾN)

> **Lưu ý**: Các con số dưới đây là **ước lượng lý thuyết** dựa trên phân tích cấu trúc tác vụ và tham chiếu kết quả từ paper CodeAct (Wang et al., 2024 — *"Executable Code Actions Elicit Better LLM Agents"*, benchmark trên M3ToolEval). **Cần benchmark thực tế A/B trên 10-20 tác vụ thực** sau khi triển khai Giai đoạn 1 để xác nhận.

| Tiêu chí | Mô hình JSON Tool-Calling (Cũ) | Mô hình QuickJS CodeAct (Mới) | Dự kiến cải thiện |
| :--- | :--- | :--- | :--- |
| **Số LLM Turns (Tác vụ 4 bước)** | 6 – 10 Turns | 2 – 3 Turns (bao gồm retry) | **Giảm ~55% – 70%** (*) |
| **Tỷ lệ sinh mã đúng ngay lần 1** | N/A (JSON schema) | ~80-88% (JS Pass@1) | Cao hơn Lua (~45-60%) |
| **Token tiêu tốn cho Context** | 15,000 – 30,000 tokens | 3,000 – 8,000 tokens | **Tiết kiệm ~60% – 70%** |
| **Độ linh hoạt giải thuật** | Không có | Đầy đủ (vòng lặp, try/catch, async, array methods) | **Không giới hạn** |

(*) Ước lượng cao hơn Lua (~50-60%) do tỷ lệ sinh mã JS đúng cao hơn → ít retry hơn → ít turn hơn. Paper CodeAct gốc báo cáo giảm 30-40% turn với Python; dự kiến JS đạt mức tương đương do cùng tier accuracy.

---

## 10. LỘ TRÌNH TRIỂN KHAI 4 GIAI ĐOẠN (IMPLEMENTATION ROADMAP)

### Giai đoạn 1: QuickJS Engine & C-ABI Bindings (Core Runtime)
- [ ] Tích hợp `quickjs-ng` vào `build.zig` sử dụng package `zig-quickjs-ng` (mitchellh).
- [ ] Xây dựng `src/runtime/quickjs_engine.zig`:
  - Khởi tạo `JSRuntime` + `JSContext`.
  - Sandbox: `JS_SetMemoryLimit(128MB)`, `JS_SetMaxStackSize(1MB)`, `JS_SetInterruptHandler(30s)`.
  - Whitelist `_G`: Chỉ nạp safe globals + `console.log` redirect vào output buffer.
  - Output buffer collector (64KB cap + head truncation).
- [ ] Xây dựng `src/runtime/js_bindings.zig`:
  - Export tất cả hàm `mini.*` (glob, grep, read, write, patch, sh, shStream, http, artifact, exists, stat, env).
  - Mỗi binding: pop args từ JS stack → gọi Zig native → push result lên JS stack.
  - Tích hợp permission check vào write/patch/sh bindings.
- [ ] **Benchmark A/B** (bắt buộc): So sánh 10 tác vụ thực giữa JSON tools và JS CodeAct.

### Giai đoạn 2: CodeAct Agent Loop & Hybrid Dispatcher
- [ ] Nâng cấp `src/core/agent_loop.zig`:
  - Thêm JS CodeBlock extractor (nhận diện ````js ... ```` / ````javascript ... ```` trong streaming response).
  - Thêm Self-Correction Loop (retry tối đa 3 lần, fallback JSON tools).
  - Config `execution_mode`: `"codeact"` | `"tools"` | `"auto"`.
- [ ] Cập nhật System Prompt: Bao gồm API reference `mini.*` + 3-5 ví dụ few-shot JavaScript hoàn chỉnh.
- [ ] **Giữ nguyên** toàn bộ JSON tool handlers hiện tại trong `src/tools/` cho fallback mode.

### Giai đoạn 3: Async Operations & Promise Support
- [ ] Implement `mini.httpAsync()` trả về Promise, tích hợp job queue (`JS_ExecutePendingJob`).
- [ ] Hỗ trợ `await Promise.all([...])` cho concurrent operations.
- [ ] Tích hợp `src/core/permissions.zig` vào C-ABI bindings (sử dụng interrupt mechanism để tạm dừng khi chờ user confirm).

### Giai đoạn 4: ACP (Agent Control Protocol) & Headless Embeddability
- [ ] Hỗ trợ giao thức JSON-RPC ACP để các IDE (VS Code, Cursor) hoặc Web UI có thể nhúng và điều khiển `mini` từ xa.
