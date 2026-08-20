# SO SÁNH TOÀN DIỆN: LUA/LUAJIT vs JAVASCRIPT/QUICKJS LÀM EMBEDDED INTERPRETER CHO MINI

> Đánh giá chi tiết mọi khía cạnh kỹ thuật, thực tiễn, và chiến lược.

---

## BẢNG TỔNG QUAN NHANH

| # | Khía cạnh | Lua / LuaJIT | JavaScript / QuickJS | Thắng |
|:---|:---|:---|:---|:---|
| 1 | Hiệu năng runtime thuần | 🟢 JIT: 20-100x nhanh hơn interpreter | 🟡 Interpreter thuần, chậm hơn LuaJIT JIT | **LuaJIT** |
| 2 | LLM sinh mã chính xác | 🔴 Thấp nhất trong nhóm chính | 🟢 Top-2, gần bằng Python | **QuickJS** ⭐ |
| 3 | Sandbox & Bảo mật | 🟡 Cần disable JIT + custom workaround | 🟢 Native API: `JS_SetMemoryLimit`, `JS_SetInterruptHandler` | **QuickJS** |
| 4 | Binary size (static link) | 🟡 ~400-500 KB (libluajit) | 🟢 ~200-300 KB (libquickjs, stripped) | **QuickJS** |
| 5 | Async / Promise | 🔴 Không có native. Coroutine thủ công | 🟢 Native async/await, Promise, job queue | **QuickJS** |
| 6 | Cross-platform | 🔴 JIT chỉ x86/ARM. Không có RISC-V | 🟢 Pure interpreter, chạy mọi nơi Zig chạy | **QuickJS** |
| 7 | Zig build integration | 🟡 `zig-luajit-build` — build phức tạp | 🟢 `zig-quickjs-ng` (mitchellh) — mature | **QuickJS** |
| 8 | Ngôn ngữ ecosystem | 🔴 Nhỏ, niche (game scripting) | 🟢 Khổng lồ (npm, web, TypeScript) | **QuickJS** |
| 9 | Cú pháp cho agent scripting | 🟢 Đơn giản, ít boilerplate | 🟡 Verbose hơn nhưng quen thuộc hơn | **Hòa** |
| 10 | Error handling | 🟡 pcall/xpcall, error string | 🟢 try/catch, Error objects, stack trace | **QuickJS** |
| 11 | Thiết kế API (`mini.*`) | 🟢 Table-based, tự nhiên | 🟢 Object-based, tự nhiên | **Hòa** |
| 12 | Chi phí migration từ codebase hiện tại | 🟢 Tương đương | 🟢 Tương đương | **Hòa** |

**Tổng: QuickJS thắng 8/12, LuaJIT thắng 1/12, Hòa 3/12.**

---

## CHI TIẾT TỪNG KHÍA CẠNH

---

### 1. HIỆU NĂNG RUNTIME THUẦN

#### LuaJIT
- **JIT mode**: 20-100x nhanh hơn interpreter thuần cho CPU-intensive loops (số học, string processing lặp đi lặp lại).
- **Interpreter mode** (khi tắt JIT để sandbox): Vẫn nhanh hơn Lua 5.3 ~2-5x, nhưng mất lợi thế JIT.
- **Vấn đề**: Trong proposal hiện tại, chúng ta **bắt buộc tắt JIT** (`jit.off()`) để sandbox hoạt động đúng → mất toàn bộ lợi thế tốc độ JIT. LuaJIT interpreter mode ≈ ngang QuickJS.

#### QuickJS
- **Pure interpreter**: Không có JIT, hiệu năng ổn định và dự đoán được trên mọi nền tảng.
- Nhanh hơn nhiều interpreter khác (standard Lua 5.3, Python), nhưng chậm hơn LuaJIT JIT mode ~5-10x.

#### Đánh giá thực tế cho `mini`:
> **Hiệu năng runtime KHÔNG phải bottleneck** trong use case của `mini`. Agent script chỉ làm 3 việc:
> 1. Gọi `mini.glob/grep/read` → Thời gian chủ yếu là I/O disk (milliseconds), không phải CPU.
> 2. Gọi `mini.sh("zig build test")` → Thời gian là subprocess execution (seconds).
> 3. Xử lý string/table nhẹ → Microseconds cho cả hai engine.
>
> **Kết luận**: Sự khác biệt tốc độ giữa LuaJIT (interpreter mode) và QuickJS là **không đáng kể** (<1ms) cho workload thực tế của agent. Lợi thế JIT của LuaJIT bị vô hiệu hóa bởi chính yêu cầu sandbox.

**Thắng: LuaJIT** (về lý thuyết thuần, nhưng lợi thế bị triệt tiêu trong thực tế).

---

### 2. ĐỘ CHÍNH XÁC SINH MÃ CỦA LLM ⭐ (QUAN TRỌNG NHẤT)

Đây là khía cạnh **quyết định sống còn** của kiến trúc CodeAct. Nếu LLM sinh mã sai → cần retry → mất turn → triệt tiêu toàn bộ lợi ích kiến trúc.

#### Dữ liệu từ benchmark (MultiPL-E, HumanEval-X, 2024-2025):

| Ngôn ngữ | Pass@1 tương đối (GPT-4o) | Volume training data | Ghi chú |
|:---|:---|:---|:---|
| **Python** | ~85-92% | Hàng tỷ dòng | Gold standard |
| **JavaScript** | ~80-88% | Hàng tỷ dòng | Gần bằng Python |
| **TypeScript** | ~78-85% | Rất lớn | Có type system giúp LLM |
| **Bash** | ~55-70% | Trung bình | Lỗi quote/escape thường xuyên |
| **Lua** | ~45-60% | Nhỏ | Ít training data, LLM hay nhầm cú pháp |

#### Phân tích chuyên sâu:

**JavaScript (QuickJS):**
- LLM được train trên **hàng tỷ dòng JavaScript** từ npm, GitHub, StackOverflow, MDN docs.
- Cú pháp quen thuộc: `for...of`, `if/else`, `const/let`, `try/catch`, template literals, destructuring.
- LLM hiểu rất sâu các pattern JavaScript: array methods (`.map`, `.filter`, `.find`), object manipulation, async/await.
- **Ngay cả với constrained API surface (`mini.*`)**, JavaScript syntax vẫn quen thuộc hơn Lua syntax rất nhiều lần.

**Lua (LuaJIT):**
- LLM được train trên **lượng Lua rất hạn chế** (chủ yếu từ game scripting: Roblox, WoW addons, Neovim config).
- Các lỗi LLM **hay mắc** khi sinh Lua:
  - Nhầm lẫn `~=` (Lua) với `!=` (hầu hết ngôn ngữ khác).
  - Quên array 1-indexed (Lua) thay vì 0-indexed.
  - Dùng `#` operator sai context (chỉ hoạt động cho sequence tables).
  - Nhầm `string.find` pattern syntax với regex.
  - Thiếu `local` keyword → biến thành global.

> [!CAUTION]
> **Đây là điểm chênh lệch lớn nhất giữa hai phương án.** Với constrained API (~12 hàm `mini.*`), khoảng cách thu hẹp lại, nhưng toàn bộ **control flow syntax** (vòng lặp, điều kiện, string processing, error handling) vẫn phải dùng cú pháp của ngôn ngữ nền. LLM sinh JavaScript control flow chính xác hơn Lua control flow rất nhiều.

**Thắng: QuickJS ⭐⭐⭐** (lợi thế áp đảo, quyết định kiến trúc).

---

### 3. SANDBOX & BẢO MẬT

#### LuaJIT
- **`_G` whitelist**: Phải tự build environment mới, loại bỏ thủ công `os`, `io`, `debug`, `ffi`.
- **Memory limit**: Phải viết custom allocator cho `lua_newstate`.
- **Timeout**: `lua_sethook` **KHÔNG hoạt động** khi JIT bật. Phải tắt JIT hoặc dùng OS-level timeout.
- **FFI**: Nếu vô tình expose `ffi` module → sandbox bị phá vỡ hoàn toàn (truy cập memory trực tiếp).
- **Tổng kết**: Sandbox **khả thi nhưng phải tự xây dựng thủ công** và dễ mắc lỗi bảo mật.

#### QuickJS
- **`JS_SetMemoryLimit(rt, max_bytes)`**: API native, 1 dòng code.
- **`JS_SetMaxStackSize(rt, max_size)`**: API native, 1 dòng code.
- **`JS_SetInterruptHandler(rt, handler, opaque)`**: API native. Handler được gọi định kỳ trong quá trình thực thi. Kiểm tra wall-clock time và trả về non-zero để dừng script. **Hoạt động chính xác mọi lúc** (không có vấn đề JIT bypass).
- **Không có FFI**: QuickJS không có FFI module → không có attack vector đó.
- **Reference counting**: Memory được giải phóng xác định (deterministic), không có vấn đề "pseudo memory leak" như LuaJIT.
- **Tổng kết**: Sandbox là **first-class feature** của QuickJS, được thiết kế từ đầu cho use case chạy untrusted code.

**Thắng: QuickJS** (sandbox API native, không cần workaround).

---

### 4. BINARY SIZE (STATIC LINKING)

| Engine | Library size (stripped) | Hello World binary | Ghi chú |
|:---|:---|:---|:---|
| **QuickJS-ng** | ~200-300 KB | ~210 KB | Có thể giảm thêm bằng MicroQuickJS (~100 KB ROM) |
| **LuaJIT** | ~400-500 KB | ~500 KB | Kèm JIT compiler code dù tắt JIT |
| **Lua 5.1** | ~150-200 KB | ~200 KB | Nhẹ nhất nhưng chậm nhất |

**Thắng: QuickJS** (nhỏ hơn ~40-50% so với LuaJIT).

---

### 5. ASYNC / PROMISE SUPPORT

#### LuaJIT
- **Không có native async/await**. Lua có coroutine (`coroutine.create/resume/yield`) nhưng:
  - Phải quản lý scheduler thủ công.
  - Không tích hợp với I/O event loop.
  - LLM không quen viết coroutine Lua (rất ít training data).
- **Ảnh hưởng**: Nếu tương lai `mini` cần hỗ trợ tác vụ async (ví dụ: gọi 3 HTTP request song song), Lua coroutine sẽ cực kỳ phức tạp.

#### QuickJS
- **Native async/await, Promise**: ES2023 compliant.
  ```javascript
  // Agent có thể sinh code async tự nhiên:
  const [a, b, c] = await Promise.all([
    mini.http("GET", url1),
    mini.http("GET", url2),
    mini.http("GET", url3),
  ]);
  ```
- **Job queue**: Host gọi `JS_ExecutePendingJob()` để xử lý pending promises.
- **LLM rất giỏi viết async JS**: Hàng tỷ dòng async/await JavaScript trong training data.

**Thắng: QuickJS** (native async/await mở ra khả năng concurrent operations trong tương lai).

---

### 6. CROSS-PLATFORM & ARCHITECTURE SUPPORT

#### LuaJIT
- **JIT compiler**: Chỉ hỗ trợ x86, x86_64, ARM, ARM64.
- **RISC-V**: **KHÔNG có support chính thức**. Chỉ có community forks không được maintain.
- **Cross-compilation**: Yêu cầu host và target cùng pointer size. Phức tạp hơn rất nhiều so với pure C library.

#### QuickJS
- **Pure C interpreter**: Không có JIT, không có assembly, không phụ thuộc kiến trúc CPU.
- **Chạy mọi nơi mà Zig C compiler chạy**: x86, ARM, RISC-V, MIPS, WASM,...
- **Cross-compilation trivial**: Chỉ cần `zig cc` target.

**Thắng: QuickJS** (portable tuyệt đối).

---

### 7. ZIG BUILD SYSTEM INTEGRATION

#### LuaJIT
- Package: `zig-luajit-build` (sackosoft).
- **Build phức tạp**: LuaJIT build process cần chạy `minilua` và `buildvm` trên host để generate headers. Cross-compilation yêu cầu HOST_CC riêng.
- Có khả năng xung đột với Zig build graph ở một số edge case.

#### QuickJS
- Package: `zig-quickjs-ng` (mitchellh — founder của HashiCorp, maintainer uy tín).
- **Build đơn giản**: QuickJS là pure C, compile thẳng bằng `zig cc`. Không cần tool trung gian.
- ~95% C API đã có Zig bindings sẵn, hiếm khi cần viết `extern` thủ công.

**Thắng: QuickJS** (build đơn giản hơn, maintainer uy tín hơn).

---

### 8. HỆ SINH THÁI NGÔN NGỮ

#### LuaJIT
- Ecosystem nhỏ, tập trung vào: game scripting (Roblox, LÖVE2D, WoW), Neovim plugins, OpenResty/nginx.
- Ít thư viện xử lý dữ liệu phức tạp.
- Documentation hạn chế so với JavaScript.

#### QuickJS (JavaScript)
- **Hệ sinh thái lớn nhất thế giới**: npm, MDN, StackOverflow, hàng triệu tutorial.
- LLM được train rất sâu trên hệ sinh thái này.
- Nếu agent cần tham khảo pattern xử lý JSON, regex, string → JavaScript có sẵn rất nhiều idiom quen thuộc.

> **Lưu ý**: Trong context `mini`, agent không `require()` thư viện ngoài. Nhưng LLM biết cách viết JavaScript **tốt hơn** nhờ volume training data áp đảo.

**Thắng: QuickJS**.

---

### 9. CÚ PHÁP CHO AGENT SCRIPTING

#### Lua
```lua
local files = mini.glob("**/*.zig", "src")
for _, f in ipairs(files) do
    local content = mini.read(f)
    if content and content:find("pattern") then
        mini.patch(f, "old", "new")
    end
end
```
- **Ưu**: Ngắn gọn, ít boilerplate.
- **Nhược**: `ipairs`, `#table`, 1-indexed, `~=` thay `!=` — LLM hay nhầm.

#### JavaScript (QuickJS)
```javascript
const files = mini.glob("**/*.zig", "src");
for (const f of files) {
    const content = mini.read(f);
    if (content && content.includes("pattern")) {
        mini.patch(f, "old", "new");
    }
}
```
- **Ưu**: Cú pháp quen thuộc toàn cầu, `for...of`, `.includes()`, 0-indexed.
- **Nhược**: Verbose hơn chút (const/let, `{}`, `;`).

**Thắng: Hòa** — Cả hai đều đủ đơn giản cho agent scripting. Lua ngắn hơn, JS quen thuộc hơn.

---

### 10. ERROR HANDLING

#### Lua
```lua
local ok, err = pcall(function()
    mini.write("/path", content)
end)
if not ok then print("Error: " .. err) end
```
- `pcall` / `xpcall` trả về boolean + error string.
- Không có structured error objects.
- Stack trace phải dùng `debug.traceback` (mà sandbox đã gỡ bỏ `debug`).

#### JavaScript (QuickJS)
```javascript
try {
    mini.write("/path", content);
} catch (e) {
    console.log(`Error: ${e.message}`);
    console.log(e.stack);  // Stack trace tự động
}
```
- `try/catch` native, `Error` object có `message`, `stack`, `name`.
- LLM rất quen viết try/catch JS.
- Stack trace có sẵn, không cần module `debug`.

**Thắng: QuickJS** (error handling mạnh hơn và LLM viết đúng hơn).

---

### 11. THIẾT KẾ API (`mini.*`)

#### Lua version:
```lua
mini.glob("**/*.zig")              --> table of string
mini.read("path")                   --> string
mini.sh("cmd")                      --> table { exit_code, stdout, stderr }
```

#### JavaScript version:
```javascript
mini.glob("**/*.zig")              // → string[]
mini.read("path")                   // → string
mini.sh("cmd")                      // → { exitCode, stdout, stderr }
```

Cả hai đều tự nhiên và dễ hiểu. JavaScript có lợi thế nhỏ:
- Destructuring: `const { exitCode, stdout } = mini.sh("cmd");`
- Template literals: `` `Found ${files.length} files` ``
- Array methods: `files.filter(f => f.endsWith(".zig")).map(f => mini.read(f))`

**Thắng: Hòa** (cả hai đều OK, JS có syntactic sugar hơn).

---

### 12. CHI PHÍ MIGRATION TỪ CODEBASE HIỆN TẠI

Cả hai phương án đều yêu cầu cùng khối lượng công việc:
1. Tích hợp C library vào `build.zig`.
2. Viết C-ABI bindings cho ~12 hàm `mini.*`.
3. Viết sandbox/timeout/memory limit wrapper.
4. Viết code block extractor trong agent loop.
5. Viết self-correction loop.
6. Cập nhật system prompt.

Không phương án nào có lợi thế rõ ràng về effort.

**Thắng: Hòa**.

---

## PHÂN TÍCH SWOT

### QuickJS (JavaScript)
| | Tích cực | Tiêu cực |
|:---|:---|:---|
| **Nội tại** | ✅ LLM sinh JS chính xác áp đảo | ❌ Không có JIT (chậm hơn cho CPU-heavy) |
| | ✅ Sandbox API native, mature | ❌ Cần event loop cho async (phức tạp hơn nếu dùng) |
| | ✅ async/await native | |
| | ✅ Binary nhỏ, portable mọi kiến trúc | |
| **Ngoại tại** | ✅ Hệ sinh thái JS khổng lồ → LLM training data phong phú | ❌ QuickJS-ng vẫn là community-maintained (không phải corporate) |
| | ✅ mitchellh Zig bindings mature | ❌ ES2023 spec lớn → attack surface lý thuyết rộng hơn |

### LuaJIT
| | Tích cực | Tiêu cực |
|:---|:---|:---|
| **Nội tại** | ✅ JIT performance vượt trội (nếu bật) | ❌ Phải tắt JIT cho sandbox → mất lợi thế chính |
| | ✅ Cú pháp tối giản | ❌ LLM sinh Lua kém chính xác nhất |
| | | ❌ Không có async/await native |
| | | ❌ Sandbox phải tự xây hoàn toàn |
| **Ngoại tại** | ✅ Battle-tested trong gaming (Roblox, WoW) | ❌ Không support RISC-V |
| | | ❌ Cross-compilation phức tạp |
| | | ❌ Maintainer đơn lẻ (Mike Pall), chậm merge PR |

---

## KẾT LUẬN & KHUYẾN NGHỊ

### Phán quyết: **QuickJS (JavaScript) là lựa chọn tối ưu hơn cho `mini`**

#### Lý do cốt lõi:
1. **LLM code generation accuracy là yếu tố quan trọng nhất** trong kiến trúc CodeAct. Mọi lợi ích của CodeAct (giảm turn, tiết kiệm token, tăng tốc) đều **phụ thuộc vào việc LLM sinh mã đúng ngay lần đầu**. JavaScript có lợi thế áp đảo ở khía cạnh này.

2. **Lợi thế JIT của LuaJIT bị triệt tiêu** trong thực tế: sandbox yêu cầu tắt JIT → LuaJIT interpreter mode ≈ QuickJS performance → mất toàn bộ lý do kỹ thuật chọn LuaJIT.

3. **Sandbox QuickJS mature hơn**: `JS_SetMemoryLimit`, `JS_SetInterruptHandler`, `JS_SetMaxStackSize` — 3 dòng code thay vì phải tự build cả hệ thống timeout/allocator.

4. **Async/await mở cánh cửa tương lai**: Agent có thể gọi nhiều HTTP request song song, chạy nhiều `mini.sh()` đồng thời — pattern mà Lua coroutine rất khó implement và LLM rất ít biết.

5. **Portable tuyệt đối**: Mini có thể chạy trên RISC-V, WASM, bất kỳ kiến trúc nào mà Zig hỗ trợ.

#### Rủi ro cần lưu ý:
- QuickJS chậm hơn LuaJIT JIT mode cho heavy computation — nhưng agent script không heavy computation.
- ES2023 spec rộng → cần whitelist cẩn thận những gì expose vào sandbox (nhưng đây cũng là vấn đề của Lua với `ffi`).

#### Hành động đề xuất:
Nếu đồng ý, sửa proposal chuyển từ LuaJIT sang QuickJS-ng. Hầu hết cấu trúc proposal (hybrid strategy, self-correction loop, permissions, API design) **giữ nguyên** — chỉ thay engine layer và cú pháp ví dụ.
