# Issue & Design Proposal: OpenAI Responses API Integration & Dual-Protocol Auto-Negotiation

| Thuộc tính | Giá trị |
|---|---|
| Mã Issue | **ISSUE-BACKEND-001** |
| Tên | Tự động đàm phán và chuyển đổi giữa Chat Completions API và Responses API (Dual-Protocol Auto-Negotiation & Adaptive Fallback) |
| Trạng thái | Proposed |
| Phạm vi | `src/backends/openai.zig`, `src/core/config.zig`, `src/core/protocol.zig` |
| Ngày | 26/08/2026 |

---

## 1. Tổng quan vấn đề (Problem Statement)

Hiện nay, `src/backends/openai.zig` giao tiếp với toàn bộ hệ sinh thái OpenAI-compatible thông qua endpoint truyền thống:
`POST {base_url}/chat/completions` (Chat Completions API).

Tuy nhiên, hệ sinh thái AI đang bước vào giai đoạn chuyển giao kiến trúc lớn:
1. **Dòng model thế hệ mới (OpenAI GPT-5.6 Sol / Terra / Luna, o3-pro)** ưu tiên hoặc bắt buộc sử dụng **Responses API** (`POST {base_url}/responses`) khi thực hiện các tác vụ kết hợp giữa **Reasoning (suy luận sâu)** và **Tool Calling (gọi công cụ)**.
2. Trên endpoint Chat Completions cũ, khi gửi request kèm `tools` và `reasoning_effort`, một số model GPT-5.6 trả về lỗi `HTTP 400 Bad Request` (từ chối kết hợp reasoning effort với function tools trên giao thức cũ).
3. **Trải nghiệm người dùng bị phân mảnh**: Người dùng thường chỉ cấu hình 1 biến môi trường duy nhất là `OPENAI_COMPAT_URL` (ví dụ `https://api.openai.com/v1` hoặc `https://api.openai.com/v1/chat/completions`). Người dùng không muốn phải cấu hình thủ công xem model nào dùng `/chat/completions`, model nào dùng `/responses`.

---

## 2. Mục tiêu kỹ thuật (Objectives)

1. **Đơn điểm cấu hình (Single Endpoint Configuration)**:
   - Người dùng chỉ cần cấu hình `OPENAI_COMPAT_URL` (hoặc `config.json`).
   - `mini` tự động trích xuất Base URL gốc và route đến đúng endpoint cần thiết (`/chat/completions` hoặc `/responses`).

2. **Tự động chuyển đổi giao thức 3 tầng (3-Tier Auto-Negotiation & Adaptive Fallback)**:
   - **Tier 1 (Model-Aware Pre-routing)**: Nhận diện tiền tố model (ví dụ `gpt-5.6*`, `o3-pro*`) để chủ động dùng Responses API.
   - **Tier 2 (Adaptive Error Fallback)**: Khi gặp HTTP 400 (báo lỗi không hỗ trợ trên Chat Completions), tự động dịch payload sang format Responses API và retry ngay lập tức. Ngược lại, nếu gặp HTTP 404 trên server proxy/local cũ, tự động fallback về Chat Completions.
   - **Tier 3 (Protocol Memory Caching)**: Ghi nhớ endpoint thành công cho từng model trong suốt phiên làm việc (session cache) để triệt tiêu độ trễ probe ở các turn tiếp theo.

3. **Adapter Transformer 2 chiều**:
   - Dịch chuyển trong suốt giữa `Message` / `ToolDefinition` (trong `core/protocol.zig`) sang định dạng request/response của cả 2 API mà không làm thay đổi Agent Loop.

---

## 3. Kiến trúc thiết kế chi tiết (Detailed Design)

### 3.1. Luồng thực thi & Auto-Negotiation

```
                   [ Agent Loop: sendMessage ]
                               │
                               ▼
            ┌──────────────────────────────────────┐
            │ 1. URL Normalization (Extract Base)  │
            │    "https://api.openai.com/v1"       │
            └──────────────────┬───────────────────┘
                               │
                               ▼
            ┌──────────────────────────────────────┐
            │ 2. Protocol Selection Strategy       │
            │    - Session Cached Protocol?        │
            │    - Model Heuristic (gpt-5.6/o3-pro)│
            │    - Default: Chat Completions       │
            └──────────┬────────────────┬──────────┘
                       │                │
          [ Chat Completions ]     [ Responses API ]
          POST /chat/completions   POST /responses
                       │                │
               Gặp HTTP 400?       Gặp HTTP 404?
          (unsupported/tools+cot)  (server chưa hỗ trợ)
                       │                │
                       ▼                ▼
            ┌──────────────────────────────────────┐
            │ 3. Adaptive Cross-Protocol Fallback  │
            │    - Convert Payload sang chuẩn kia  │
            │    - Retry Request & Cache Protocol  │
            └──────────────────────────────────────┘
```

### 3.2. Chuẩn hóa Base URL

```zig
fn getRootApiUrl(base_url: []const u8) []const u8 {
    var url = std.mem.trimEnd(u8, base_url, "/");
    if (std.mem.endsWith(u8, url, "/chat/completions")) {
        return url[0 .. url.len - "/chat/completions".len];
    }
    if (std.mem.endsWith(u8, url, "/responses")) {
        return url[0 .. url.len - "/responses".len];
    }
    return url;
}
```

### 3.3. So sánh Định dạng Payload & Streaming Events

| Hạng mục | Chat Completions API | Responses API |
|---|---|---|
| **Endpoint** | `POST {base}/chat/completions` | `POST {base}/responses` |
| **Input Payload** | `{"messages": [{"role":"user","content":"..."}]}` | `{"input": [{"role":"user","content":"..."}]}` |
| **Tools Payload** | `{"tools": [{"type":"function", "function":{...}}]}` | `{"tools": [{"type":"function", "name":..., "parameters":...}]}` |
| **Reasoning Param** | `{"reasoning_effort": "medium"}` | `{"reasoning": {"effort": "medium"}}` |
| **Stream Event** | `data: {"choices":[{"delta":{"content":"..."}}]}` | `event: response.output_text.delta`<br>`data: {"delta":"..."}` |
| **Reasoning Stream** | `data: {"choices":[{"delta":{"reasoning":"..."}}]}` | `event: response.reasoning_text.delta`<br>`data: {"delta":"..."}` |
| **Tool Stream** | `data: {"choices":[{"delta":{"tool_calls":[...]}}]}` | `event: response.tool_call.delta`<br>`data: {"delta":"..."}` |

---

## 4. Kế hoạch triển khai (Implementation Plan)

1. **Giai đoạn 1 (Protocol Struct & Enum)**:
   - Thêm `ProtocolMode` (`auto`, `chat_completions`, `responses`) vào `Config` và `Client`.
   - Bổ sung logic chuẩn hóa URL gốc `getRootApiUrl()`.

2. **Giai đoạn 2 (Responses API Streaming Parser)**:
   - Xây dựng parser SSE cho các event chuẩn của Responses API (`response.output_text.delta`, `response.reasoning_text.delta`, `response.tool_call.delta`).

3. **Giai đoạn 3 (Adaptive Fallback & Caching)**:
   - Tích hợp phát hiện lỗi 400/404 và tự động retry chéo giữa 2 protocol.
   - Cache protocol đã đàm phán thành công theo tên model.

4. **Giai đoạn 4 (Testing & Fixtures)**:
   - Viết unit tests giả lập SSE stream từ cả 2 chuẩn API trong `testcases/`.
