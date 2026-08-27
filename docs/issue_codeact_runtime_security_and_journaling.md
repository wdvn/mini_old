# Issue & Design Proposal: Standardizing Security Policy, Hooks Dispatch & Journaling for CodeAct Runtime

| Thuộc tính | Giá trị |
|---|---|
| Mã Issue | ISSUE-CODEACT-001 |
| Tên | Chuẩn hóa Security Policy, Hooks Dispatch & ActJournaling cho CodeAct Runtime |
| Trạng thái | Proposed |
| Phạm vi | `src/runtime/js_bindings.zig`, `src/runtime/quickjs_engine.zig`, `src/core/agent.zig` |
| Ngày | 23/08/2026 |

---

## 1. Tổng quan vấn đề (Problem Statement)

Kiến trúc Code-Centric Agent (CodeAct) của `mini-agent` cho phép LLM sinh mã JavaScript thực thi trực tiếp trong CodeAct VM nhúng thông qua đối tượng toàn cục `mini.*` (`mini.sh`, `mini.read`, `mini.write`, `mini.patch`, `mini.http`, v.v.).

Qua phân tích các session chạy thực tế gần đây, việc thực thi tool qua JS CodeAct đang **tách biệt khỏi các cơ chế kiểm soát chính của Agent Loop**, tạo ra 4 lỗ hổng nghiêm trọng:

### 1.1. Bypass Tool Allowlist / Blocklist Policy
- Biến cấu hình `MINI_TOOL_ALLOWLIST` và `MINI_TOOL_BLOCKLIST` (hoặc cài đặt trong `config.json`) hiện chỉ được kiểm tra ở tầng JSON Tool-Calling (`src/core/agent.zig` -> `executeToolCall`).
- Các C-bindings trong `src/runtime/js_bindings.zig` (`jsMiniSh`, `jsMiniWrite`, `jsMiniPatch`, v.v.) gọi trực tiếp hàm thực thi của tool mà KHÔNG kiểm tra chính sách an toàn.
- **Hậu quả**: Nếu người dùng cấu hình `MINI_TOOL_BLOCKLIST=bash`, Agent bị chặn khi dùng JSON tool-calling nhưng vẫn có thể dùng `mini.sh("rm -rf ...")` trong CodeAct để thực thi lệnh shell bình thường.

### 1.2. Bypass Hệ thống Hook Giám sát (`MINI_HOOK_COMMAND`)
- Lệnh Prehook / Posthook (`MINI_HOOK_COMMAND`) chỉ được kích hoạt tại `AgentLoop.executeStep` khi Agent dùng JSON Tool-Calling.
- Các thao tác hệ thống do JS CodeAct thực thi (`mini.sh`, `mini.write`, `mini.http`) hoàn toàn không phát sự kiện hook (`pre-tool-use`, `post-tool-use`), làm vô hiệu hóa hệ thống giám sát / auditing ngầm của người dùng.

### 1.3. Thiếu File Snapshot Tracking cho Event-Sourcing (ActJournal)
- Các thao tác ghi/sửa file qua `mini.write()` và `mini.patch()` thực hiện trực tiếp lên hệ thống tệp mà không lưu lại `FileSnapshot` (before/after hash + content backup) trong `ActJournal` (tuân thủ RFC-002).
- **Hậu quả**: Không thể audit lịch sử biến đổi file do CodeAct gây ra và không thể khôi phục (rollback) các thao tác hỏng khi task thất bại.

### 1.4. Phản hồi Lỗi Self-Correction Chưa Tường Minh
- Khi JS script ném ngoại lệ hoặc lệnh `mini.sh` thất bại trong CodeAct, thông báo lỗi trả về cho LLM đôi khi bị thiếu thông tin ngữ cảnh hoặc bị cắt vụn, làm giảm khả năng tự sửa lỗi (Self-Correction) của Agent trong lượt tiếp theo.

### 1.5. Trùng lặp Scope Biến giữa các Turn (Global Variable Scope Pollution across Acts)
- CodeAct engine trước đây thực thi các khối mã JS từ LLM bằng `c.JS_Eval(ctx, ..., c.JS_EVAL_TYPE_GLOBAL)`. Mọi khối mã JS trong cùng một session đều dùng chung 1 `JSContext` toàn cục.
- **Hậu quả trực tiếp**: Nếu ở Turn 1 Agent khai báo `const data = mini.read(...)` hoặc `const lines = ...` ở top-level, sang Turn 2 nếu Agent tiếp tục dùng `const data = ...` ở top-level, CodeAct lập tức ném lỗi `SyntaxError: Identifier 'data' has already been declared`. *(Đã được khắc phục triệt để bằng Per-Act VM Isolation)*.

### 1.7. LLM Xuất Thẻ XML Giả Định (`<file_read>`, `<glob>`, `<bash>`) Thay vì Mã JavaScript ````js ... ```` khi ở Chế độ CodeAct
- Khi bật chế độ CodeAct (`MINI_EXECUTION_MODE=codeact`), mảng native `tools` ở API payload bị ẩn để triệt tiêu Native Function Calling. Tuy nhiên, một số LLM (như DeepSeek, Claude, Ollama) khi không có mảng `tools` ở API payload lại xuất hiện khuynh hướng tưởng tượng các thẻ XML giả lập (ví dụ `<file_read file="..." />`, `<glob pattern="..." />`, `<bash command="..." />`) trong text phản hồi thay vì sinh khối mã ````js ... ````.
- **Hậu quả trực tiếp**: `findJsCodeInResponse` trước đây không quét các thẻ XML giả định nên trả về `null`. Đồng thời HTTP response stream kết thúc (`stop_reason = .end_turn`), khiến `AgentLoop` lầm tưởng lượt xử lý đã xong và **ngắt tiến trình sớm (`✓ Hoàn thành sau 1 vòng lặp`)** mà không thực thi bất kỳ thao tác nào.

### 1.8. Lỗi HTTP 520 / 522 Cloudflare Từ LLM Provider Bị Nhận Nhầm Thành `UnknownStopReason`
- Khi giao tiếp với các LLM Provider qua Cloudflare Gateway (ví dụ DeepSeek V4 Pro API), gateway trả về các mã lỗi HTTP `520` (Web Server Unknown Error) và `522` (Connection Timed Out).
- **Hậu quả trực tiếp**: Logic kiểm tra HTTP lỗi cũ trong `AgentLoop` chỉ check cứng `500`, `502`, `503`. Các mã `520`, `522` bị rơi xuống nhánh mặc định `.unknown` và ném ra `UnknownStopReason`. Điều này làm sai lệch journal log (`error_name: "UnknownStopReason"`) và bỏ qua quy trình retry provider error / fallback Ollama.

### 1.9. Nén Ngữ Cảnh Chủ Động 85% Gây Đốt Token & Mất Ngữ Cảnh Chi Tiết Sớm
- Trước đây `AgentLoop` tự ước tính số token và chủ động kích hoạt MemAct Compaction (tóm tắt lại history qua LLM) ngay khi lịch sử đạt 85% dung lượng context window trước khi gửi request.
- **Hậu quả trực tiếp**: Tốn kém API call tóm tắt không cần thiết ngay cả khi mô hình hoàn toàn xử lý được, đồng thời làm tiêu giảm thông tin chi tiết của các lượt chạy trước quá sớm.

---


## 2. Giải pháp đề xuất (Proposed Architecture)

```
[Agent Context / Config / Journal]
               │
               ▼
   ┌──────────────────────┐
   │    CodeAct Engine    │
   └──────────┬───────────┘
              │ Calls mini.sh() / mini.write()
              ▼
   ┌────────────────────────────────────────────────────────┐
   │ C-Bindings (`src/runtime/js_bindings.zig`)             │
   │                                                        │
   │ 1. Check Config.isToolAllowed(tool_name) ──► Block? ──┐ │
   │ 2. Dispatch Pre-Hook (MINI_HOOK_COMMAND)              │ │ (Throw JS Exception)
   │ 3. Snapshot File (ActJournal)                         │ │
   │ 4. Execute Native Tool                                │ │
   │ 5. Dispatch Post-Hook                                 │ │
   └────────────────────────┬───────────────────────────────┘
                            │ Success / Clean Output
                            ▼
                    [JS Result Return]
```

### 2.1. Ủy quyền Kiểm tra Security Policy vào `js_bindings.zig`
- Mọi hàm binding `jsMini*` trước khi thực thi tool phải kiểm tra danh sách `allowlist` / `blocklist` từ `Config`.
- Nếu bị cấm, trả về `c.JS_ThrowTypeError(ctx, "Security Policy Error: Tool '%s' is blocked by configuration", tool_name)`.

### 2.2. Tích hợp Hook Dispatcher vào JS Runtime
- Truyền callback/reference của `HookCommand` vào `Engine` / `JSContext`.
- Trước mỗi thao tác `mini.*` quan trọng (`sh`, `write`, `patch`, `http`), gọi `hooks_mod.dispatchPreToolUse()`.
- Sau khi thao tác hoàn tất, gọi `hooks_mod.dispatchPostToolUse()`.

### 2.3. Đăng ký File Snapshot vào ActJournal
- Khi `mini.write(path, content)` hoặc `mini.patch(path, old, new)` được gọi:
  1. Thực hiện snapshot file hiện tại vào `ActJournal` (nếu file đã tồn tại).
  2. Thực hiện ghi/sửa file.
  3. Ghi sự kiện `file_snapshot` bổ sung vào journal.

### 2.4. Chuẩn hóa Định dạng Lỗi Self-Correction
- Đóng gói lỗi trong CodeAct theo định dạng chuẩn:
  ```
  [CodeAct JavaScript Execution Failed]
  Error Type: <TypeError / ReferenceError / RuntimeError>
  Message: <Error Message>
  Stack Trace:
    at <function> (<file>:<line>)
  ```
- Định dạng rõ ràng giúp LLM nhận biết ngay lập tức nguyên nhân lỗi để sinh mã sửa đổi (Self-Correction) chính xác ở turn tiếp theo.

### 2.5. Cô lập Tuyệt đối bằng Fresh JSContext cho mỗi Act Execution (Per-Act VM Isolation)
- Thay vì tái sử dụng một `JSContext` toàn cục duy nhất xuyên suốt session hay dùng kĩ thuật Anonymous Block Wrapping `{ ... }` (vốn vẫn tiềm ẩn rủi ro ô nhiễm `globalThis` hoặc prototype pollution), `quickjs_engine.zig` sẽ thực hiện **tạo mới một `JSContext` sạch 100% cho mỗi lượt thực thi Act**.
- Quy trình cô lập tuyệt đối cho mỗi lượt chạy (`eval`):
  1. Khởi tạo `JSContext` mới tinh (`c.JS_NewContext(rt)`) từ `JSRuntime`.
  2. Đăng ký lại hệ thống đối tượng built-in (`console.log`, `mini.*` C-bindings).
  3. Thực thi khối mã JavaScript của LLM trong môi trường vô trùng hoàn toàn.
  4. Giải phóng `JSContext` ngay sau khi lượt chạy hoàn tất (`c.JS_FreeContext(ctx)`).
- **Lợi ích**: Triệt tiêu hoàn toàn 100% khả năng ô nhiễm scope biến (`const`/`let`/`var`), xung đột trùng tên hàm, rò rỉ bộ nhớ hay bất kỳ hành vi ẩn (hidden behaviors/side effects) nào giữa các turn trong cùng một session.

### 2.6. Tự động Ẩn mảng `tools` trong API Request khi ở chế độ CodeAct / Auto-Prompt Tuning
- Để giải quyết triệt để rào cản RLHF Bias của LLM với Native Tool Calls:
  1. **Ẩn mảng `tools` ở API Payload**: Khi `execution_mode == .codeact` (hoặc khi bật ưu tiên CodeAct), `AgentLoop` sẽ truyền một mảng rỗng `&[_]proto.ToolDefinition{}` lên backend. Khi không thấy tham số `tools` ở API payload, LLM lập tức tắt chế độ native function calling và chuyển sang viết mã JS CodeAct.
  2. **Thắt chặt System Prompt Framing**: Điều chỉnh câu System Prompt trong `config.zig` từ lời khuyên tùy chọn sang chỉ thị tường minh: `"Đối với mọi công cụ và tự động hóa, bạn BẮT BUỘC phải viết mã JavaScript trong khối ```js ... ``` sử dụng đối tượng toàn cục mini.*"`.

### 2.8. Tự động Chuyển Đổi Thẻ XML Giả Định sang Mã JavaScript `mini.*`
- Bổ sung bộ bóc tách và quy đổi tự động `convertXmlToolTagsToJs` trong `src/core/agent.zig`:
  1. Khi `findJsCodeInResponse` không thấy khối mã markdown ````js ... ````, tự động quét văn bản phản hồi tìm các thẻ XML giả lập như `<file_read>`, `<glob>`, `<grep>`, `<bash>`, `<file_write>`.
  2. Bóc tách thuộc tính và tự động tạo đoạn mã JS thực thi tương đương (ví dụ `mini.read(path)`, `mini.glob(pattern, path)`, `mini.sh(cmd)`).
  3. Thực thi đoạn mã JS trong CodeAct VM, ghi log stdout và quay lại tiếp tục vòng lặp (`.continue_loop`) thay vì thoát lượt chạy (`✓ Hoàn thành sau 1 vòng lặp`).

### 2.9. Mở Rộng Nhận Diện Lỗi HTTP 5xx & Tự Động Retry Backoff
- Cập nhật phân loại lỗi HTTP status code trong `AgentLoop.executeStep`:
  - Quy đổi tất cả các mã `response.http_code >= 500 and response.http_code < 600` (bao gồm Cloudflare 520, 521, 522, 524) thành `error.LLMProviderUnavailable`.
  - Giúp `AgentLoop` phân loại chính xác event `.llm_provider_error` trong journal log, kích hoạt backoff exponential retry và tự động fallback sang Ollama local khi backend chính không khả dụng.

### 2.10. Cơ Chế Nén Ngữ Cảnh Phản Ứng (Reactive Emergency Compaction)
- Bỏ hoàn toàn việc nén ngữ cảnh chủ động dựa trên 85% ngưỡng ước tính token.
- Chuyển sang nén phản ứng khi model thực sự trả về lỗi tràn ngữ cảnh (`error.LLMContextWindowExceeded` / HTTP 400 `context_length_exceeded`):
  1. Ghi log sự kiện `.llm_context_overflow` vào journal.
  2. Thực hiện `compactContext(act_id)` (MemAct compaction hoặc fallback simple compact).
  3. Thử lại (`continue`) lượt chạy với context đã được nén.

---

## 3. Cấu trúc Code cần Thay đổi

| File | Nội dung thay đổi |
|---|---|
| `src/runtime/quickjs_engine.zig` | Thêm pointer/reference tới `Config`, `ActJournal` trong `Engine` struct; Chuyển sang tạo mới & hủy `JSContext` sạch cho mỗi lần `eval` để cô lập 100% môi trường thực thi |
| `src/runtime/js_bindings.zig` | Kiểm tra allowlist/blocklist, dispatch hooks, và chụp file snapshot trước khi thực thi `mini.sh`, `mini.write`, `mini.patch` |
| `src/core/agent.zig` | Truyền `Config` và `ActJournal` instance vào `Engine` khi khởi tạo; Không gửi mảng `tool_defs` lên backend khi `execution_mode == .codeact`; Bổ sung `convertXmlToolTagsToJs`, phân loại HTTP 5xx, và `compactContext` phản ứng khi tràn window |
| `src/core/config.zig` | Tăng trọng số chỉ thị CodeAct tường minh trong System Prompt mặc định, cấm dùng thẻ XML giả định |
| `src/tooling/registry.zig` | Đăng ký `codeact` làm Native Tool Definition chuẩn hóa |
| `testcases/test_codeact_as_tool.zig` | Integration test kiểm tra `codeact` native tool execution |
| `testcases/test_codeact_security.zig` | [NEW] Integration test kiểm tra `MINI_TOOL_BLOCKLIST`, Hook Dispatcher, và Per-Act VM Isolation trong CodeAct |

---

## 4. Kế hoạch Thực hiện (Milestones)

- [x] **M1: Per-Act VM Isolation**: Chuyển `quickjs_engine.zig` sang khởi tạo `JSContext` mới tinh cho mỗi đợt `eval` và deinit ngay sau đó, đảm bảo 100% cô lập.
- [x] **M2: Security Enforcement**: Tích hợp check allowlist/blocklist vào `js_bindings.zig`.
- [x] **M3: Hook Integration**: Bổ sung pre-hook và post-hook dispatch cho các hàm `mini.*`.
- [x] **M4: Journal Snapshot Integration**: Tích hợp `ActJournal` snapshot vào `mini.write` và `mini.patch`.
- [x] **M5: Tool-Calling Suppression**: Ẩn mảng `tools` khi `execution_mode == .codeact` và thắt chặt prompt framing.
- [x] **M6: Native Tool Standardization**: Đăng ký `codeact` thành native tool trong registry và CodeAct runtime handler.
- [x] **M7: XML Tool Tag Auto-Conversion**: Tự động chuyển đổi thẻ XML giả lập (`<file_read>`, `<glob>`, `<bash>...`) thành mã JS CodeAct và tiếp tục Act loop.
- [x] **M8: HTTP 5xx Cloudflare Error Standardization**: Mở rộng nhận diện HTTP 5xx (520, 522...) thành `LLMProviderUnavailable` cho backoff retry.
- [x] **M9: Reactive Emergency Context Compaction**: Bỏ nén chủ động 85%, nén ngữ cảnh phản ứng khi nhận được lỗi `LLMContextWindowExceeded`.
- [x] **M10: Testing & Verification**: Viet testcases gia lap trong testcases/test_codeact_security.zig va dam bao zig build test pass 100%.

