# RFC-011: Media I/O Proposal — Tích hợp đọc và sinh ảnh/video làm năng lực của Agent

> **Ngày:** 2026-10-24 (bản sửa 2: khắc phục 6 sai lệch thực chứng từ báo cáo phản biện — env mapping, hook payload, hàm Ollama, session file, pattern jsMiniWrite, công thức token estimator)
> **Trạng thái:** Proposed
> **Tác giả:** mini-agent team
> **Mục tiêu:** Hoàn thiện luồng media **hai chiều**:
> 1. **Đọc media (ingestion)** — wire `ImageBlock` (đã định nghĩa trong `src/core/protocol.zig` nhưng chưa được sử dụng) end-to-end: parser `@image:<path>` trong input → helper `readImageFile` → serialization trong cả 3 backend adapters (Anthropic/OpenAI/Ollama).
> 2. **Sinh media (generation)** — 2 tool mới `generate_image` / `generate_video` + binding CodeAct `mini.media()`.
>
> Tái dùng toàn bộ hạ tầng sẵn có (config, http lib, tool registry policy, hooks). *Lưu ý lịch sử: bản đầu của RFC này tham chiếu nhầm "RFC-010 (Vision)" — RFC-010 thực tế là Procedural Graph; phần thiết kế vision chưa từng có RFC riêng nên được nhập vào đây (§3.0).*

---

## 1. Vấn đề hiện trạng (Problem Statement)

### 1.0. Luồng đọc media (ingestion) chưa được wire

`src/core/protocol.zig` đã định nghĩa `ImageBlock{data, media_type}` và `ContentBlock.image`, nhưng **chưa có đường dẫn nào tạo ra block này**:

- **Parser input**: không có cú pháp `@image:<path>` — REPL (`src/ui/repl.zig`) và input FSM (`src/ui/paste.zig`) không nhận diện media trong prompt người dùng.
- **Helper đọc file**: chưa có hàm `readImageFile` (đọc binary, sniff MIME qua magic bytes `89 50 4E 47` / `FF D8 FF` / `52 49 46 46`, base64-encode, chặn nếu > 10MB).
- **Backend serialization**: cả 3 adapter (`backends/claude.zig`, `backends/openai.zig`, `backends/ollama.zig`) **không handle `ContentBlock.image`** — nếu history chứa block này sẽ bị bỏ qua hoặc serialize sai. Anthropic cần `source.type="base64"` trong content array; OpenAI Responses API cần `input_image` (image_url/data URL); Ollama cần trường `images:[base64]` top-level của message.
- **History**: `core/history.zig` serialize/restore message chưa round-trip được `ContentBlock.image` qua session file JSON (RFC-002 — message lưu ở `~/.mini/sessions/<id>.json`, không phải journal).

### 1.1. Luồng sinh media (generation) chưa tồn tại

Agent không có cách nào tạo media **đầu ra**:

- Không có tool nào trong `src/tooling/registry.zig` gọi image/video generation API.
- Khi user yêu cầu "vẽ cho tôi..." hay "tạo video quảng cáo...", agent phải `mini.sh("curl ...")` — vừa phá vỡ convention *"Backends đều conform core/protocol.zig"*, vừa lộ API key qua journal/log của bash, vừa không parse được kết quả binary.

### 1.2. Hạ tầng đã sẵn sàng

- `src/lib/http_request.zig` — HTTP client tập trung (timeout, TLS, redirect), không cần lib mới.
- `src/core/config.zig` — nhóm config + env mapping (`openai_compat_api_key` → `OPENAI_COMPAT_API_KEY`, `openai_compat_url` → `OPENAI_COMPAT_URL`) đã có pattern chuẩn (`config.zig:235-236`).
- `src/tooling/registry.zig` — `executeTool` + `isPermitted` (allowlist/blocklist) áp dụng cho mọi tool.
- `src/core/hooks.zig` — `HookPayload` có sẵn trường `artifact_path`/`artifact_type`, có thể dùng cho event `media_saved` mà không cần thêm field.
- `src/core/protocol.zig` — `ImageBlock{data, media_type}` (chỉ định nghĩa, chưa wire — xem §1.0) dùng làm carrier chung cho cả hai chiều.
- Base64 codec có sẵn trong std.

### 1.3. Video API là job bất đồng bộ

Khác image (request/response đồng bộ), video generation (Sora, Veo, Runway...) là **job-based**: POST tạo job → poll status → download content khi completed. Cần pattern polling có trần thời gian, không treo agent loop.

---

## 2. Mục tiêu & Phi mục tiêu

### Mục tiêu
0. **Wire đọc media end-to-end (Phase 0)**: cú pháp `@image:<path>` trong prompt → `readImageFile` → `ContentBlock.image` trong history → 3 backend adapter serialize đúng wire-format riêng.
1. **2 tool mới** trong registry: `generate_image` (đồng bộ) và `generate_video` (bất đồng bộ job-based), tuân thủ tool protocol hiện có.
2. **Binding CodeAct** `mini.media(kind, prompt, opts)` → map sang 2 tool trên, đi qua `guardPolicy` như `mini.write` → `file_write`.
3. **Đơn điểm cấu hình**: provider/model/size cấu hình 1 lần trong `config.json`, backend adapter tự dịch wire-format.
4. **Media trả về dưới dạng file + path**, KHÔNG base64 trong tool result (bảo vệ context budget — 1 ảnh 1024px ~1-2MB base64 đủ nổ context).
5. **Loop-back vision (Phase 3)**: ảnh vừa gen có thể attach lại vào history dưới dạng `ContentBlock.image` (tái dùng đúng hạ tầng ingestion của Phase 0) để agent tự review/sửa ở turn sau (multi-turn editing).
6. **Live preview**: bắn hook `media_saved` để external UI (Level D) hiển thị ảnh ngay khi xong.

### Phi mục tiêu
- Không thêm SDK/dependency ngoài — chỉ std + libcurl hiện có.
- Không hỗ trợ inpainting/outpainting/upscale (API v1 chỉ làm text-to-image/video).
- Không stream chunk video về terminal (terminal không render được — chỉ lưu file).
- Không sinh ảnh inline trong markdown response (CLI limitation).
- Phase 0 chỉ hỗ trợ **ảnh** đầu vào (png/jpeg/webp/gif); audio/video đầu vào để dành RFC sau.

---

## 3. Thiết kế chi tiết (Detailed Design)

### 3.0. Đọc media — ingestion pipeline (Phase 0)

Mục tiêu: từ input người dùng đến wire-format của từng backend, tất cả đi qua `ContentBlock.image` đã có trong protocol.

#### 3.0.1. Parser input — `@image:<path>` (src/ui/repl.zig + src/ui/paste.zig)

- Trong input state machine (RFC-008), khi submit prompt: scan token `@image:<relative-or-absolute-path>` (tách theo whitespace, hỗ trợ escape `\ ` cho path có space, hỗ trợ nhiều ảnh trong 1 prompt).
- Text còn lại (sau khi tách token) → `ContentBlock.text`; mỗi ảnh → `ContentBlock.image` (data + media_type sniffed, không giữ path trong history để tránh lộ fs layout — user thấy `@image:1` trong echo).
- Prompt chỉ có ảnh không có text → sinh text placeholder rỗng `""` (Anthropic/OpenAI không chấp nhận content rỗng).
- Ảnh không tồn tại / MIME không hỗ trợ → trả lỗi ngay trong REPL, không submit turn.

#### 3.0.2. Helper `readImageFile` (src/core/utils.zig hoặc src/lib/media.zig mới)

```zig
pub const ImageLimits = struct { max_bytes: usize = 10 * 1024 * 1024 };
/// Đọc file ảnh, sniff MIME bằng magic bytes (KHÔNG tin extension):
///   89 50 4E 47 → image/png; FF D8 FF → image/jpeg;
///   52 49 46 46 + WEBP tại offset 8 → image/webp; 47 49 46 38 → image/gif
pub fn readImageFile(alloc: Allocator, path: []const u8, limits: ImageLimits) !struct {
    data: []const u8,          // base64 (không prefix data:)
    media_type: []const u8,
    bytes: usize,              // kích thước binary gốc
};
```

- Từ chối file > 10MB, file 0 byte, MIME không nằm trong 4 loại trên.
- Dùng arena của turn — base64 data được free khi history compact/turn kết thúc (history quản lý ownership như `Message.content` hiện có).

#### 3.0.3. Serialization per-backend

| Backend | Wire format | Vị trí sửa |
|---|---|---|
| **Anthropic** (`backends/claude.zig`) | Trong content array của message: `{"type":"image","source":{"type":"base64","media_type":"image/png","data":"<b64>"}}` — ảnh chỉ hợp lệ ở role `user` | `buildRequest`/serialize history |
| **OpenAI** (`backends/openai.zig`) | Responses API: `{"type":"input_image","image_url":"data:<mime>;base64,<b64>"}` trong content của input message | hàm build input items |
| **Ollama** (`backends/ollama.zig`) | Trường top-level `images: ["<b64>"]` của message object (KHÔNG nằm trong content) | `buildRequestBody` — lưu ý serializer hiện gộp mọi block thành **1 chuỗi content duy nhất** (`ollama.zig:158-173`), nên `images` phải là field song song với `content` trong cùng message object, không phải case trong switch content |

- **Token budget (RFC-003)**: estimator cộng chi phí ảnh theo công thức pixel-tile chuẩn của vision model: `(width × height) / 750` token (cần lưu `width`/`height` khi sniff ảnh — đọc từ header PNG/JPEG/GIF/WEBP; fallback heuristic `data.len / 1000` khi không parse được kích thước). Lưu ý implement: **không gọi `self.estimate(img.data)`** trong `TokenEstimator.estimateMessage` (`memact/tokens.zig:70-87`) vì StringHashMap cache key là text — base64 10MB sẽ phình cache; dùng phép tính trực tiếp không qua cache. Trần mỗi turn 5 ảnh — vượt thì block ở REPL trước khi gửi.
- **Session round-trip (RFC-002)**: message lưu trong **session file JSON riêng** (`~/.mini/sessions/<id>.json` qua `History.backupToFile`/`restoreFromFile` — `history.zig:82-143`), KHÔNG nằm trong journal JSONL (journal chỉ chứa `ActEvent` metadata). `ContentBlock.image` serialize thành `{"type":"image","media_type":...,"data":...}` trong session file; khi restore session, reparse đúng schema. Nếu session quá nặng, compaction được phép thay block image bằng text placeholder `"[image: <media_type>, N KB — đã lược bỏ]"`.

#### 3.0.4. Bảo mật ingestion

- Path resolve về tuyệt đối; chỉ đọc file mà user tự tham chiếu trong prompt (không có tool nào đọc ảnh hộ LLM ở Phase 0 — LLM không thể tự trigger đọc file tùy ý để exfiltrate).
- Chặn symlink trỏ ra ngoài workspace? **Không chặn** — input là của user, quyền đọc = quyền user; nhưng log path (đã sanitize) vào journal để audit.
- MIME sniff bằng magic bytes, không tin extension → chặn polyglot file giả danh `.png`.

### 3.1. Config layer (`src/core/config.zig`)

```zig
// --- RFC-011: Media I/O ---
/// Bật parser @image:<path> trong prompt (ingestion, Phase 0). Mặc định bật.
image_input_enabled: bool = true,
/// Trần số ảnh attach mỗi turn (cả user-initiated lẫn image_attach).
image_input_max_per_turn: u8 = 5,
/// Giới hạn dung lượng 1 ảnh đầu vào (bytes).
image_input_max_bytes: usize = 10 * 1024 * 1024,
/// Bật tool generate_image. Mặc định tắt (không hiện tool definition cho LLM).
image_gen_enabled: bool = false,
/// Provider: "openai" (api.openai.com cố định) | "openai_compat" (dùng base_url/key của openai-compat provider).
image_gen_provider: []const u8 = "openai",
/// Model gen ảnh: "gpt-image-1", "dall-e-3", "flux-1" (qua compat)...
image_gen_model: []const u8 = "gpt-image-1",
/// Kích thước mặc định: "1024x1024" | "1536x1024" | "1024x1536" | "auto".
image_gen_size: []const u8 = "1024x1024",
/// Bật tool generate_video.
video_gen_enabled: bool = false,
/// Model video: "sora-2", "sora-2-pro"...
video_gen_model: []const u8 = "sora-2",
/// Thư mục lưu media output. Null = "<workspace>/media".
media_output_dir: ?[]const u8 = null,
/// Trần thời gian poll video job (giây).
video_poll_timeout_secs: u32 = 600,
```

Env mapping tái dùng: `OPENAI_COMPAT_API_KEY` + `OPENAI_COMPAT_URL` hiện có (`config.zig:235-236`, có thể set từ env hoặc `config.json` qua `JsonConfig` + `setEnvDefault` — `config.zig:605-750`). Anthropic không có gen API — provider `anthropic` sẽ trả lỗi rõ ràng "provider không hỗ trợ media generation". Ingestion (Phase 0) không cần config theo backend — model không hỗ trợ vision sẽ trả lỗi từ provider, mini hiển thị nguyên văn.

### 3.2. Tool `generate_image` (`src/tools/media_gen.zig`)

Input JSON:
```json
{"prompt":"mèo phi hành gia, phong cách pixel art", "size":"1024x1024", "filename":"meo_space.png"}
```

Luồng:
1. Validate prompt (1..4000 chars), sanitize filename (chặn `..`, `/`, giới hạn 64 chars).
2. Gọi `http_lib.fetch` → `POST {base}/v1/images/generations` body `{"model","prompt","size","n":1}` với `Authorization: Bearer <key>`.
3. Parse response: `{data:[{b64_json}]}` (gpt-image-1) hoặc `{data:[{url}]}` (dall-e-3) — với `url` thì fetch lần 2 để download binary (không đẩy URL vào context cho LLM tự curl).
4. Base64 decode → ghi file `<media_output_dir>/<timestamp>_<filename>`.
5. Trả về text ngắn cho LLM:
   ```
   Đã tạo ảnh: media/20261024_143022_meo_space.png (PNG, 1024x1024, 1.2MB)
   ```
6. `hooks.dispatch(alloc, io, .{ .event = "media_saved", .artifact_path = "<path>", .artifact_type = "image/png" })` — `HookPayload` có sẵn `artifact_path`/`artifact_type` (`hooks.zig:75-76`), event là string tự do (precedent: `artifact_saved` tại `src/tools/artifact.zig:38-44`).

Giới hạn: response binary ≤ 20MB, timeout 120s, tự tạo thư mục output nếu thiếu.

### 3.3. Tool `generate_video` — job polling

Input: `{"prompt":"...", "seconds":4, "filename":"promo.mp4"}`.

Luồng Sora API làm chuẩn (openai-compat khác tương tự):
1. `POST /v1/videos` → `{id, status:"queued"}`.
2. Poll `GET /v1/videos/{id}` mỗi 5s (`std.time.sleep` trong thread riêng hoặc loop trong tool — tool protocol hiện synchronous, giữ loop đơn giản + cap `video_poll_timeout_secs`).
3. `status == "completed"` → `GET /v1/videos/{id}/content` (binary mp4, ≤ 200MB, stream-write ra file theo chunk 64KB, không load full vào RAM).
4. Trả path + metadata như image tool. Status `failed` → trả message lỗi của job cho LLM.

### 3.4. Binding CodeAct (`src/runtime/js_bindings.zig`)

```js
// Agent gọi từ JS block:
const r = mini.media("image", "logo tối giản màu xanh", { size: "1024x1024" });
// → r.path, r.media_type, r.bytes
```

Implement theo **đúng pattern `jsMiniWrite`** (`js_bindings.zig:226-275`): `getEngine` + `renewActivity` → validate args → `guardPolicy(engine, "generate_image"/"generate_video")` (deny → `JS_ThrowTypeError` + hook `is_error`) → hook `pre-tool-use` → **gọi tool handler trực tiếp** (như `jsMiniWrite` gọi `file_tool.writeFile` tại `:253`, KHÔNG qua `registry.executeTool` — vì `executeTool` tự làm policy + pre/post hook, đi qua nó sẽ gây double-hooking) → hook `post-tool-use`. Parse opts object (vd `opts.size`) theo pattern `jsMiniHttp` với helper có sẵn `jsOptString`/`jsOptInt` (`js_bindings.zig:585-645`). **Không** thêm path JSON tool-calling mới — đúng nguyên tắc "Tool calls ưu tiên đi qua JS VM".

### 3.5. Loop-back vision (Phase 3)

Tool mới `image_attach`: `{"path":"media/meo.png"}` → gọi đúng `readImageFile` của §3.0.2, append `ContentBlock{.image = ...}` vào message tool_result của turn hiện tại. Backend adapters **đã serialize sẵn** `.image` từ Phase 0 (§3.0.3) — Phase 3 chỉ thêm tool entry + kiểm tra trần `image_input_max_per_turn`. Từ đó chain tự nhiên:

```
User: vẽ mèo → generate_image → image_attach → [model tự nhìn ảnh] → "đổi nền sang hoàng hôn" → generate_image lần 2
```

- `image_attach` tách blocklist riêng với `image_input_enabled` (LLM-initiated attach cần opt-in rõ hơn user-initiated `@image:`).
- Kết hợp pre-tool-use hook để audit mọi path LLM attach.

### 3.6. Bảo mật

- Tool bị blocklist/allowlist kiểm soát như mọi tool (`registry.isPermitted`) — mặc định `generate_*` thuộc nhóm cần opt-in qua config `image_gen_enabled`.
- API key không bao giờ xuất hiện trong tool result, journal, hay bash (không route qua `mini.sh`).
- Download có size cap + content-type check (`image/png|jpeg|webp`, `video/mp4`) chống zip-bomb / binary giả mạo.
- Video polling có hard timeout, thoát với error rõ ràng thay vì treo agent loop.

---

## 4. Phân pha triển khai

| Pha | Nội dung | LOC ước tính | Phụ thuộc |
|-----|----------|--------------|-----------|
| **0** | **Đọc media (ingestion)**: parser `@image:<path>`, helper `readImageFile` (MIME sniff + base64), serialize `.image` trong 3 backend adapters, journal round-trip cho `ContentBlock.image`, token budget cho ảnh | ~450 | Không |
| **1** | `tools/media_gen.zig` (generate_image), config fields, registry wiring, JS binding, unit + mock E2E tests | ~350 | Không |
| **2** | `generate_video` (job polling + stream download), hook `media_saved` | ~400 | Pha 1 |
| **3** | `image_attach` loop-back (tái dùng hạ tầng Pha 0), provider `openai_compat` đầy đủ | ~200 | Pha 0 + Pha 1 |
| **4** (tùy chọn) | MCP gen servers (Runway/Luma/Replicate qua `tooling/mcp.zig`) | nhỏ | Pha 2 |

Pha 0 và Pha 1 **độc lập, chạy song song được** (chạm khác vùng file: Pha 0 = ui/ + backends/ + history; Pha 1 = tools/ + registry + js_bindings).

---

## 5. Rủi ro & Mitigation

| Rủi ro | Mitigation |
|--------|-----------|
| Context nổ vì base64 ảnh/video trong tool result | Chỉ trả path + metadata; binary luôn ra file |
| Context nổ vì ảnh ingestion (Phase 0) | Trần `image_input_max_per_turn` + 10MB/ảnh + token estimator trừ trước khi gửi; compaction thay ảnh cũ bằng placeholder |
| Treo agent loop khi poll video | Hard timeout + status `failed` trả error message |
| Chi phí API cao khi LLM lặp generate | Hook pre-tool-use ghi journal để audit; config cho phép blocklist |
| Provider đổi wire-format | Parse cả `b64_json` lẫn `url`; compat provider tách base_url riêng |
| Polyglot file / MIME giả mạo khi ingestion | Sniff magic bytes, không tin extension; không có tool LLM-initiated đọc ảnh tùy ý ở Pha 0 |

---

## 6. Testing

- **Unit** (`testcases/test_media_gen.zig`): parse response `b64_json`/`url`, base64 decode, filename sanitize, MIME detect, size-cap từ chối.
- **Unit** (`testcases/test_media_ingest.zig` — Pha 0): parser `@image:` tách token đúng (multi-ảnh, escape space, path lỗi), `readImageFile` sniff MIME từ PNG/JPEG/WEBP/GIF fixture, serializer Anthropic/OpenAI/Ollama tạo đúng wire-format, journal round-trip `ContentBlock.image` (serialize → restore → so sánh), token budget trừ đúng, compaction thay ảnh bằng placeholder.
- **Mock E2E**: mở rộng `scripts/mock_llm_server.js` thêm `POST /v1/images/generations` (trả b64 của PNG 1x1 thật) + flow `/v1/videos` job giả lập (queued → completed sau 2 poll) — tuân thủ quy tắc *"không gọi API thật khi test"*.
- **Thủ công**: `zig build run` với `image_gen_enabled=true` + key thật, kiểm tra file output mở được, hook `media_saved` bắn đúng; prompt `@image:photo.png ảnh này ch gì?` với model vision thật (claude/gpt-4o) xác nhận model mô tả đúng nội dung ảnh.
