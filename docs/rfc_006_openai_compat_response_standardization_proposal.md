# RFC-006: Chuẩn hóa parse response cho OpenAI/OpenAI-compat backend

| Thuộc tính | Giá trị |
|---|---|
| RFC | 006 |
| Tên | Chuẩn hóa parse response (SSE stream + usage) cho OpenAI/OpenAI-compat |
| Trạng thái | Draft — chờ review |
| Phiên bản | 0.1 |
| Phụ thuộc | Không (RFC-001 liên quan gián tiếp — cùng mô hình backend `core/protocol.zig`) |
| Tham chiếu | [OpenAI Chat Completions API — streaming](https://platform.openai.com/docs/api-reference/chat/streaming), [Chat Completions object](https://platform.openai.com/docs/api-reference/chat/object); các biến thể compat: [DeepSeek reasoning_content](https://api-docs.deepseek.com/api/create-chat-completion), vLLM, LM Studio, Ollama `/v1` |
| Tác giả | mini-agent |
| Ngày | 23/08/2026 |

---

## 1. Vấn đề (Motivation)

`src/backends/openai.zig` là backend duy nhất hướng tới hệ sinh thái "OpenAI-compatible" — một
backend, vô số provider (OpenAI thật, DeepSeek, vLLM, LM Studio, Ollama `/v1`, OpenRouter,
các API nội bộ...). Thực trạng parse response hiện tại có 4 lỗ hổng:

1. **Usage bị bỏ qua hoàn toàn.** Từ commit tối ưu cache-hit, request đã gửi
   `"stream_options":{"include_usage":true}` nhưng phía parse **không đọc chunk usage** —
   `Chunk` struct không có field `usage`, token đếm/xuất/giá không bao giờ được ghi nhận.
   `include_usage` đang là dead weight: provider trả về mà mini không tiêu thụ.

2. **Reasoning content chỉ nhận 1 biến thể.** DeepSeek và nhiều API compat trả reasoning qua
   field `delta.reasoning_content` (đã hỗ trợ), nhưng OpenAI chuẩn (o-series/gpt-5 skeleton)
   trả qua `delta.reasoning` — field này bị rơi (`ignore_unknown_fields = true` nuốt mất).
   Cùng một loại thông tin, hai cái tên, chỉ parse một.

3. **Stop reason thiếu `refusal` và `content_filter`.** OpenAI định nghĩa
   `finish_reason` gồm: `stop`, `length`, `tool_calls`, `content_filter`, `function`
   (legacy). Hiện chỉ map `stop`/`length`/`tool_calls` — mọi finish_reason lạ đều
   rơi vào `stop_reason == .unknown`, làm agent loop nhầm là lỗi transport.

4. **Không phân biệt lỗi HTTP với stream hợp lệ.** Khi `http_code >= 400`, body error
   (JSON không phải SSE) vẫn được đưa qua parser SSE → parse im lặng fail →
   `stop_reason = .unknown` + `raw_debug_info` chứa body lỗi (may mắn là có, nhờ
   `raw_accum`). Thiếu một đường xử lý error rõ ràng ngay từ response head.

Phạm vi RFC: **chỉ phía response** (SSE parse + usage + finish_reason + error path) của
`openai.zig`. Phía request (đã chuẩn hóa prefix tĩnh cho cache-hit ở commit `7203038`) và
các backend khác (claude.zig, ollama.zig native) không thuộc phạm vi.

## 2. Mục tiêu

1. Parse đầy đủ usage từ SSE chunk cuối (`stream_options.include_usage`) → lưu vào
   `proto.Response.usage`, wire ra journal/stats.
2. Nhận reasoning từ cả `delta.reasoning_content` (DeepSeek-style) lẫn `delta.reasoning`
   (OpenAI o-series-style), ưu tiên field nào có.
3. Map đủ 5 giá trị `finish_reason` của OpenAI; giá trị lạ giữ lại `.unknown` kèm
   raw string để debug.
4. Đường error tách bạch: `http_code >= 400` → không feed parser SSE, trả response
   error có cấu trúc.
5. Không đổi `proto.Response` API theo hướng breaking với agent loop hiện tại
   (chỉ **thêm** field, không đổi/đổi tên field cũ).
6. Unit test lock behavior cho từng biến thể provider.

## 3. Thiết kế chi tiết

### 3.1. Usage struct trong `proto.Response`

Thêm vào `src/core/protocol.zig`:

```zig
/// Thống kê token usage do backend trả về (OpenAI usage object format).
pub const Usage = struct {
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    total_tokens: u64 = 0,
    /// Prompt tokens tính giá cache-hit (prompt_tokens - cached_tokens).
    cached_tokens: u64 = 0,
    /// Chuỗi reasoning mà provider trả kèm usage (DeepSeek reasoner).
    reasoning_tokens: u64 = 0,
};
```

`Response` thêm field (mặc định zero — mọi constructor hiện tại không cần sửa):

```zig
pub const Response = struct {
    // ... existing fields ...
    usage: Usage = .{},
};
```

Bảng mapping field OpenAI → mini:

| OpenAI (usage object)      | mini `Usage`         | Ghi chú |
|---|---|---|
| `prompt_tokens`            | `prompt_tokens`      | |
| `completion_tokens`        | `completion_tokens`  | |
| `total_tokens`            | `total_tokens`       | |
| `prompt_tokens_details.cached_tokens` | `cached_tokens` | optional, có ở OpenAI; DeepSeek đặt `prompt_cache_hit_tokens` |
| `completion_tokens_details.reasoning_tokens` | `reasoning_tokens` | optional |

Compat aliases (chỉ ở tầng parse openai.zig, không đưa vào proto):
- DeepSeek: `prompt_cache_hit_tokens` → `cached_tokens`;
  `prompt_cache_miss_tokens` bỏ qua (suy ra được).
- Không thấy field nào → giữ 0, không error.

### 3.2. Parse chunk usage trong StreamCtx

SSE gửi usage ở **chunk cuối cùng**: `choices: []` (mảng rỗng) + `usage: {...}`. Sửa
`Chunk` struct trong `openai.zig`:

```zig
const UsageJson = struct {
    prompt_tokens: ?u64 = null,
    completion_tokens: ?u64 = null,
    total_tokens: ?u64 = null,
    prompt_tokens_details: ?struct {
        cached_tokens: ?u64 = null,
    } = null,
    completion_tokens_details: ?struct {
        reasoning_tokens: ?u64 = null,
    } = null,
    // DeepSeek aliases
    prompt_cache_hit_tokens: ?u64 = null,
};

const Chunk = struct {
    // ... existing fields ...
    usage: ?UsageJson = null,
};
```

Xử lý trong `processLine`:

```zig
if (chunk.usage) |u| {
    self.response.usage = .{
        .prompt_tokens = u.prompt_tokens orelse 0,
        .completion_tokens = u.completion_tokens orelse 0,
        .total_tokens = u.total_tokens orelse 0,
        .cached_tokens = u.prompt_tokens_details.?.cached_tokens orelse
            u.prompt_cache_hit_tokens orelse 0,
        .reasoning_tokens = ...,
    };
}
```

(Viết đầy đủ với null-check từng tầng — pseudo ở trên chỉ minh họa độ sâu nested.)

### 3.3. Reasoning: nhận cả hai biến thể

`ChoiceDelta` thêm `reasoning: ?[]const u8 = null` (song song `reasoning_content`).
Logic ghép:

```zig
const reasoning = delta.reasoning_content orelse delta.reasoning orelse {
    // không có reasoning trong chunk này
} ...
```

Ưu tiên `reasoning_content`; nếu null thì dùng `reasoning`. Cả hai cùng có (không xảy ra
trên thực tế) → lấy `reasoning_content` và ghi 1 dòng debug journal.

Đầu ra vẫn là `ThinkingBlock` như hiện tại (`signature = ""` — OpenAI-compat không có
concept signature của Anthropic).

### 3.3.1. Non-stream reasoning: `message.reasoning_content` 

Một số provider (DeepSeek non-stream, vài proxy) trả reasoning ở
`choices[0].message.reasoning_content` thay vì delta. Mini luôn stream nên **không hỗ
trợ** đường này trong RFC — ghi nhận ở §8 (Risks) để tránh scope creep.

### 3.4. Map finish_reason đầy đủ

Bảng chuẩn hóa trong `processLine`:

| OpenAI `finish_reason` | mini `StopReason`   |
|---|---|
| `stop`                | `.end_turn`         |
| `length`              | `.max_tokens`       |
| `tool_calls`          | `.tool_use`         |
| `content_filter`      | `.unknown` + set `raw_debug_info` |
| `function` (legacy)   | `.tool_use` (map như tool_calls) |
| khác / null           | giữ nguyên state hiện tại |

`content_filter` không map thẳng sang `.max_tokens` hay `.end_turn` — hai giá trị đó gây
agent loop tiếp tục iterate sai semantics. `.unknown` + debug info là an toàn nhất cho
đến khi `proto.StopReason` có thêm variant (xem §7 Future).

### 3.5. Error path tách bạch

Trong `sendMessage`, sau `postStream` trả `req_http_code`:

```zig
if (req_http_code >= 400) {
    // Không feed parser — response.error raw đã nằm trong ctx.raw_accum
    // (postStream đã stream body vào onChunk trước khi biết status?
    //  → cần kiểm tra: hiện postStream stream mọi body vào onChunk bất kể status)
}
```

**Khám phá khi viết RFC**: cần xác minh thứ tự "nhận status → stream body" của
`http_lib.postStream`. Nếu body đã vào `ctx.raw_accum` (hiện đúng là có, nhờ
`raw_accum` 4096 bytes đầu), thì chỉ cần skip phase "parse SSE" và trả về sớm với
`stop_reason = .unknown`, `http_code`, `raw_debug_info = raw_accum` — đúng như luồng
`unknown` hiện tại nhưng tường minh, không đi qua parse-SSE-vô-ích.

Kết quả: error path trở thành 1 nhánh `if` đầu hàm, đọc dễ hơn, test được.

### 3.6. Không gửi `include_usage` cho endpoint không hỗ trợ

Một số API compat cũ không nhận `stream_options` → 400. Hiện đã có cơ chế retry
400-adaptive (`use_completion_tokens`, `disable_reasoning_effort`); thêm 1 pattern:

```
400 + body chứa "stream_options" hoặc "include_usage"
→ rebuild request không có stream_options, retry (1 lần)
```

Flag `self.disable_stream_options: bool` same pattern như `disable_reasoning_effort`.
Usage sẽ bằng 0 với các endpoint này — chấp nhận được, fallback logic estimation của
MemAct (RFC-003 TokenEstimator) vẫn chạy độc lập.

## 4. Cấu trúc code thay đổi

| File | Thay đổi |
|---|---|
| `src/core/protocol.zig` | Thêm `Usage` struct + field `usage` vào `Response` (additive) |
| `src/backends/openai.zig` | `UsageJson` nested parse; `reasoning` alias; finish_reason map đầy đủ; error branch sớm; retry pattern `stream_options` |
| `src/core/agent.zig` | Wire usage ra journal (1 dòng `[usage] prompt=X completion=Y cache_hit=Z`), chỉ khi `usage.total_tokens > 0` |
| `testcases/test_openai_response_parse.zig` | Mới — table-driven SSE fixtures cho 4 biến thể provider |

Test fixtures (giả lập chunk SSE, feed vào `StreamCtx.onChunk`):
1. **OpenAI chuẩn + tools + usage** — verify tool_calls tích lũy, usage parse, `cached_tokens` từ `prompt_tokens_details`.
2. **DeepSeek reasoner** — `reasoning_content` deltas + `prompt_cache_hit_tokens` alias.
3. **OpenAI o-series** — `delta.reasoning` (không có `_content`).
4. **Error 429/500** — body JSON error, verify `stop_reason == .unknown`, `http_code` set, `raw_debug_info` chứa body.
5. **finish_reason content_filter** — verify `.unknown` + debug info, không phải `.end_turn`.

## 5. Milestones

| # | Nội dung | Đối tượng |
|---|---|---|
| M1 | `proto.Usage` + parse trong openai.zig + fixtures 1–2 | protocol.zig, openai.zig |
| M2 | `reasoning` alias + fixture 3 | openai.zig |
| M3 | finish_reason map + error branch + fixtures 4–5 | openai.zig |
| M4 | Retry `stream_options` adaptive | openai.zig |
| M5 | Journal usage line + (tùy chọn) hiển thị cache-hit% khi !quiet | agent.zig |

M1–M3 là lõi, M4–M5 nice-to-have. Mỗi milestone chạy `zig build test` phải pass.

## 6. Acceptance criteria

- [ ] Stream OpenAI thật (hoặc fixture) có usage: `response.usage.total_tokens > 0`.
- [ ] DeepSeek: reasoning land vào `ThinkingBlock`, `cached_tokens` > 0 khi provider báo.
- [ ] `delta.reasoning` (không suffix) được parse thành thinking.
- [ ] `finish_reason: "content_filter"` → `.unknown` + debug info, KHÔNG phải `.end_turn`.
- [ ] HTTP 400 stream_options-reject → auto-retry 1 lần không stream_options, request thành công.
- [ ] `zig build test` pass toàn bộ (kể cả 80 tests hiện tại).

## 7. Risks & mitigation

| Rủi ro | Khả năng | Mitigation |
|---|---|---|
| Provider trả usage format lạ ngoài documented aliases | Trung bình | `ignore_unknown_fields` + mọi field optional → worst case usage = 0, không crash |
| `prompt_tokens_details` xuất hiện với `cached_tokens: null` | Thực tế xảy ra | null-check từng tầng (orelse 0) |
| Retry stream_options vòng vô hạn | Thấp | Flag 1 chiều (`disable_stream_options` chỉ false→true), không đảo lại |
| Thêm field `usage` làm phình Response alloc | Thấp | `Usage` là plain struct ~40 bytes, zero-cost khi không set |
| Field `reasoning` trùng semantic tương lai của OpenAI đổi tên lần nữa | Trung bình | Parse ở 1 chỗ duy nhất (`ChoiceDelta`), đổi alias chỉ chạm 1 struct |

## 8. Alternatives considered

1. **Đưa `Usage` xuống từng backend tự định nghĩa** — rejected: claude.zig cũng sắp cần
   (`cache_read_input_tokens`, §validate-cache-hit), để chung ở proto tránh mỗi backend
   một struct. Anthropic fields map: `input_tokens`→`prompt_tokens`,
   `cache_read_input_tokens`→`cached_tokens`, `cache_creation_input_tokens` (bỏ).
2. **Parse non-stream response** — rejected: mini luôn stream, thêm đường code chết.
3. **Thêm `StopReason.refusal`/`.content_filter` vào proto** — deferred: additive enum
   variant bắt buộc sửa mọi switch exhaustiveness ở agent loop; chưa có hành vi riêng
   đáng kể. Ghi nhận §7 Future.
4. **Dùng OpenAI SDK chính thức** — rejected ngay: AGENTS.md cấm thêm dependency ngoài
   chưa qua proposal; nhu cầu parse nằm gọn trong ~100 dòng Zig.

## 9. Future work

- `proto.StopReason` thêm `.refusal`, `.content_filter` khi agent loop có hành vi riêng
  (hiện tại chỉ hiển thị lỗi).
- Claude backend parse `message_start` usage (`input_tokens`, `cache_read_input_tokens`,
  `cache_creation_input_tokens`) — cùng struct `proto.Usage`, đo được cache-hit thật của
  thay đổi breakpoint (bài toán mở từ validate cache-hit hôm 23/08).
- Aggregators (OpenRouter) trả `usage.cost` — cân nhắc field `cost_usd: f64` khi cần
  track chi phí.

## 10. Câu hỏi mở

1. Usage có đáng ghi vào journal luôn (mỗi LLM call 1 dòng) hay gom theo turn?
   — Nghiêng về: mỗi call, vì journal đang theo act/event granularity.
2. `cached_tokens` với DeepSeek tính từ `prompt_cache_hit_tokens` — có nên cộng dồn
   với OpenAI `cached_tokens` khi endpoint là proxy ghép cả hai? (Hiện: không, lấy field
   đầu tiên khác 0.)
