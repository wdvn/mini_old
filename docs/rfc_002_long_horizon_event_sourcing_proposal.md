# PROPOSAL: THIẾT KẾ EVENT-DRIVEN ACT ARCHITECTURE CHO MINI
### Loại Bỏ `MaxIterationsReached`, Hỗ Trợ Long-Lived Tasks, Rollback State & Xử Lý Toàn Diện Lỗi LLM / Hạ Tầng
> **Document**: RFC-002 (Revision 4 — Full Failure Spectrum & LLM Fault-Tolerance)  
> **Status**: Implemented / Production  
> **Target System**: `mini-agent` (`mini`)  
> **Reference**: `event_sourcing_long_horizon_agentic_ai.md`  
> **Author**: Core Team & AI Pair Programmer  
> **Date**: 21/08/2026  

---

## 1. TỔNG QUAN (EXECUTIVE SUMMARY)

### 1.1. Vấn đề cốt lõi hiện tại
Trong `src/core/agent.zig`, agent loop bị giới hạn bởi:
```zig
const MAX_ITERATIONS = 30;
// ...
while (iteration < MAX_ITERATIONS) : (iteration += 1) {
    // 1. Ghi toàn bộ history ra file backup tạm /tmp/mini_agent_backup_*.json
    // 2. Chạy executeStep
    // 3. Nếu lỗi: restore lại từ file backup
}
return error.MaxIterationsReached;
```

#### Hạn chế thực tế:
1. **Không chạy được tác vụ dài (Long-lived tasks)**: Task thực tế (refactor dự án, sửa lỗi hàng loạt, migration, batch subagents) đòi hỏi hàng trăm hoặc hàng nghìn loops nhưng bị chặn đứng ở loop thứ 30 (`MaxIterationsReached`).
2. **Cơ chế Rollback thô sơ**: Mỗi step phải dump toàn bộ JSON ra disk `/tmp/mini_agent_backup.json`. Chỉ rollback được 1 step ngay trước đó khi có exception, không thể rollback về một trạng thái bất kỳ (Act $N$) trong quá khứ hoặc hoàn tác các thay đổi file (state deltas).
3. **Bỏ qua các kịch bản lỗi thực tế của LLM Model**: LLM không bao giờ hoàn hảo — trong thực tế thường xuyên gặp lỗi 429 Rate Limit, 503 Server Overloaded, đứt kết nối SSE, sinh JSON Tool Call sai cú pháp, bị ngắt cụt output (max_tokens truncation), hoặc tràn Context Window.

---

### 1.2. Giải pháp: Mô hình Event-Driven Act Toàn Diện
Đơn giản hóa toàn bộ kiến trúc xung quanh một nguyên lý trực diện:

> **1 Loop = 1 Act**  
> Mỗi vòng lặp của agent là một **Act** (Hành động). Toàn bộ chu kỳ sống của một Act được vận hành theo mô hình **Event-Driven** nhằm phục vụ **2 mục đích chính duy nhất**:
> 1. **Hỗ trợ chạy Long-Lived Tasks** (Bỏ hoàn toàn giới hạn `MAX_ITERATIONS`).
> 2. **Hỗ trợ Rollback State** (Quay lui trạng thái về bất kỳ Act nào trong quá khứ một cách chính xác, xử lý toàn diện mọi sự cố từ Tool, Hệ thống, cho tới LLM Model).

```
                            TASK STREAM
                                 │
                                 ▼
 ┌──────────────────────────────────────────────────────────────┐
 │                         ACT (Loop i)                         │
 │                                                              │
 │  1. ActStarted Event                                         │
 │       ↓                                                      │
 │  2. LLM Call (Kèm cơ chế phòng thủ lỗi 429/503/JSON parse)   │
 │       ↓                                                      │
 │  3. Tool / JS Execution (Kèm thu thập File/History Delta)     │
 │       ↓                                                      │
 │  4. Observation / State Delta Captured                       │
 │       ↓                                                      │
 │  5. ActCompleted Event (hoặc ActFailed/Rollback Event)       │
 └──────────────────────────────┬───────────────────────────────┘
                                │
          ┌─────────────────────┴─────────────────────┐
          ▼                                           ▼
   [Mục đích 1]                                [Mục đích 2]
 LONG-LIVED EXECUTION                        STATE ROLLBACK
 - Không giới hạn số Act                     - Rollback về Act N bất kỳ
 - Chạy liên tục đến khi xong                - Revert History & File Deltas
 - Append-only Event Stream                  - Xử lý triệt để lỗi LLM & Crash
```

---

## 2. QUẢN TRỊ TOÀN DIỆN MỌI LOẠI LỖI (THE FULL FAILURE SPECTRUM)

Không có hệ thống nào không lỗi. Trong một task chạy dài (Long-Horizon) với hàng trăm Acts, lỗi sẽ xảy ra ở 3 tầng khác nhau:

```
                            CÁC TẦNG LỖI TRONG THỰC TẾ
                                        │
     ┌──────────────────────────────────┼──────────────────────────────────┐
     ▼                                  ▼                                  ▼
[TẦNG 1: LỖI LLM MODEL]        [TẦNG 2: LỖI CÔNG CỤ/MÔI TRƯỜNG]  [TẦNG 3: LỖI RUNTIME/SYSTEM]
- 429 Rate Limit / Quota       - Bash exit code != 0              - CodeAct Panic
- 503 Provider Overloaded      - Test failure / Compile error     - Disk I/O Snapshot fail
- Truncated / Malformed JSON   - File not found                   - Tiến trình bị kill
- Context Window Exceeded      - Patch conflict                   - Memory Corruption
```

---

### 2.1. Tầng 1: Xử lý các lỗi từ LLM Model / Provider

| Loại lỗi LLM | Nguyên nhân thực tế | Cơ chế Event-Driven & Chiến lược phục hồi |
|:---|:---|:---|
| **Rate Limit (429) & Quota** | Gọi API quá dày hoặc chạm rate limit của OpenAI / Claude / Ollama | - Ghi Event `LLMCallThrottled`.<br>- **Exponential Backoff + Jitter** (thử lại sau 2s, 4s, 8s... tối đa 5 lần).<br>- Giữ nguyên State hiện tại, không làm hỏng History. |
| **Provider Overloaded (500/502/503)** | Server AI gặp sự cố hoặc timeout kết nối mạng | - Ghi Event `LLMProviderError`.<br>- Thử lại với cơ chế retry có timeout.<br>- Nếu sau $N$ lần vẫn sập $\rightarrow$ Kích hoạt Fallback sang Backup Model (ví dụ OpenAI $\to$ Claude hoặc local Ollama) hoặc `Yield` chờ mạng. |
| **Malformed Tool Call / Invalid JSON** | LLM sinh JSON thiếu dấu ngoặc, sai schema, hoặc tên tool không tồn tại | - Ghi Event `LLMOutputMalformed`.<br>- **Self-Correction Feedback**: Inject ngay vào context: `"[System Error: Invalid Tool Call JSON: {err}. Please output valid JSON format.]"`.<br>- LLM tự động sửa lại cú pháp ở lượt thử tiếp theo (tối đa 3 lần). |
| **Output bị ngắt cụt (Max Tokens Truncation)** | LLM sinh phản hồi quá dài vượt `max_tokens` dẫn đến JSON bị cắt ngang | - Ghi Event `LLMOutputTruncated`.<br>- Yêu cầu LLM chia nhỏ nội dung hoặc tiếp tục sinh phần còn lại. |
| **Context Window Exceeded (400 Context Overflow)** | Trajectory quá dài vượt quá context window của model | - Ghi Event `ContextOverflowDetected`.<br>- **Emergency Context Compaction**: gọi `window.compactWith()` của **RFC-003** (đã chạy proactive ở ngưỡng 85% nên nhánh này chỉ là fallback); guard: nếu compaction không giảm đủ budget → abort act, không retry vô hạn. |

---

### 2.2. Tầng 2: Lỗi Công cụ & Môi trường (Tool / Environment Error)
- **Bản chất**: Lệnh bash exit code 1, test fail, patch sai dòng.
- **Xử lý**: **KHÔNG rollback state**. Đây là Observation hợp lệ.
  - Ghi nhận Event `ActCompleted { status: .tool_error }`.
  - Đưa output lỗi vào History để LLM ở Act tiếp theo đọc và tự sửa (Forward Progress / Self-Correction).

---

### 2.3. Tầng 3: Lỗi Runtime & Hạ tầng (System Crash)
- **Bản chất**: Panic, hỏng file đĩa, crash tiến trình.
- **Xử lý**: 
  - **Bounded Rollback (`MAX_RETRIES_PER_ACT = 3`)**: Rollback State về Act $i - 1$, ghi Event `ActRollbacked`, inject feedback cảnh báo lỗi.
  - Nếu đã thử 3 lần vẫn lỗi $\rightarrow$ Dừng ngay lập tức (Chống đệ quy vô hạn) và ném `ActAborted`.

---

## 3. HAI MỤC ĐÍCH CHÍNH

### Mục đích 1: Hỗ trợ Chạy Long-Lived Tasks (Bỏ `MaxIterationsReached`)

#### A. Loại bỏ giới hạn cứng
- Xóa bỏ hoàn toàn hằng số `const MAX_ITERATIONS = 30;` và `AgentError.MaxIterationsReached`.
- Vòng lặp thực thi hoạt động theo mô hình Event-Driven Stream:
  - Agent thực hiện liên tục các Acts ($1, 2, 3, \dots, 500, \dots, 1000+$).
  - Điều kiện dừng: Khi LLM phát tín hiệu hoàn thành mục tiêu (không còn tool call nào) hoặc nhận lệnh hủy (`is_cancelled`) từ người dùng / ACP client.

#### B. Khả năng chống chịu lỗi LLM trong suốt vòng đời dài
- Nhờ có cơ chế tự phục hồi lỗi 429/503 và tự sửa JSON malformed, agent không bị "chết yểu" giữa chừng khi model gặp trục trặc tạm thời.

---

### Mục đích 2: Hỗ trợ Rollback State (Quay lui trạng thái chính xác)

#### A. Cơ chế Event-Driven State Rollback
Mỗi Act khi thực thi thành công sẽ đính kèm một **`StateDelta`**:
```zig
pub const StateDelta = struct {
    act_id: usize,
    history_messages_added: usize,         // Số lượng message được thêm vào ở Act này
    file_snapshots: []const FileSnapshot,   // Snapshot nội dung file trước khi Act này chỉnh sửa
};

pub const FileSnapshot = struct {
    path: []const u8,
    previous_content: ?[]const u8,         // null nếu là file mới tạo
};
```

Khi cần Rollback về một Act mục tiêu (ví dụ từ Act 45 quay về Act 30 do phát hiện rẽ sai hướng hoặc sau sự cố):
1. **Rollback File State**: Duyệt ngược từ Act 45 về Act 31 và khôi phục lại nội dung file từ `FileSnapshot`.
2. **Rollback History State**: Cắt tỉa (truncate) danh sách message trong `History` về đúng mốc của Act 30.
3. **Record Event**: Ghi nhận event `StateRollbacked { from_act: 45, to_act: 30 }`.
4. **Tiếp tục thực thi**: Agent tiếp tục vòng lặp từ trạng thái sạch của Act 30 với hướng đi mới.

---

## 4. THIẾT KẾ CẤU TRÚC CODE TRONG `MINI`

### 4.1. Cấu trúc Event Schema Toàn Diện (`src/core/events.zig`)

```zig
const std = @import("std");

pub const ActEventType = enum {
    act_started,
    act_completed,
    act_failed,
    
    // Sự kiện LLM Model
    llm_call_started,
    llm_call_throttled,       // 429 Rate limit
    llm_provider_error,       // 500/502/503
    llm_output_malformed,     // JSON parse error / invalid tool schema
    llm_context_overflow,     // Tràn context window
    
    // Sự kiện Rollback
    rollback_requested,
    rollback_completed,
    task_completed,
};

pub const ActEvent = struct {
    act_id: usize,
    event_type: ActEventType,
    timestamp: i64,
    description: []const u8,
    delta: ?StateDelta = null,
};

pub const EventStore = struct {
    alloc: std.mem.Allocator,
    events: std.ArrayList(ActEvent),
    deltas: std.ArrayList(StateDelta),

    pub fn init(alloc: std.mem.Allocator) EventStore {
        return .{
            .alloc = alloc,
            .events = std.ArrayList(ActEvent).init(alloc),
            .deltas = std.ArrayList(StateDelta).init(alloc),
        };
    }

    pub fn recordEvent(self: *EventStore, act_id: usize, event_type: ActEventType, desc: []const u8) !void {
        try self.events.append(.{
            .act_id = act_id,
            .event_type = event_type,
            .timestamp = std.time.milliTimestamp(),
            .description = desc,
        });
    }

    pub fn recordActComplete(self: *EventStore, act_id: usize, delta: StateDelta) !void {
        try self.deltas.append(delta);
        try self.events.append(.{
            .act_id = act_id,
            .event_type = .act_completed,
            .timestamp = std.time.milliTimestamp(),
            .description = "Hoàn thành Act",
            .delta = delta,
        });
    }

    /// Rollback toàn bộ trạng thái về mốc kết thúc của target_act_id
    pub fn rollbackToAct(self: *EventStore, target_act_id: usize, history: *anyopaque) !void {
        while (self.deltas.items.len > 0) {
            const last_delta = self.deltas.items[self.deltas.items.len - 1];
            if (last_delta.act_id <= target_act_id) break;

            // Revert các file đã sửa trong delta này
            for (last_delta.file_snapshots) |snap| {
                if (snap.previous_content) |content| {
                    try std.fs.cwd().writeFile(.{ .sub_path = snap.path, .data = content });
                } else {
                    std.fs.cwd().deleteFile(snap.path) catch {};
                }
            }

            _ = self.deltas.pop();
        }

        try self.events.append(.{
            .act_id = target_act_id,
            .event_type = .rollback_completed,
            .timestamp = std.time.milliTimestamp(),
            .description = "Đã rollback trạng thái về mốc Act chỉ định",
        });
    }

    pub fn deinit(self: *EventStore) void {
        self.events.deinit();
        self.deltas.deinit();
    }
};
```

---

### 4.2. Cải tiến Vòng lặp Agent Xử lý Toàn diện Lỗi LLM & Crash (`src/core/agent.zig`)

```zig
pub fn processInput(
    self: *AgentLoop,
    user_text: []const u8,
    text_cb: ?TextCallback,
    think_cb: ?ThinkCallback,
) !void {
    try self.history.addUser(user_text);
    const tool_defs = tools_mod.getRelevantDefinitions(self.alloc, user_text);

    var act_id: usize = 0;
    const MAX_SYSTEM_RETRIES_PER_ACT = 3;

    // VÒNG LẶP EVENT-DRIVEN KHÔNG GIỚI HẠN TỔNG SỐ ACTS (LONG-LIVED TASK)
    while (true) : (act_id += 1) {
        var act_try_count: usize = 0;

        // VÒNG LẶP PHÒNG VỆ CỤC BỘ (BOUNDED RETRY CHO 1 ACT)
        while (act_try_count <= MAX_SYSTEM_RETRIES_PER_ACT) : (act_try_count += 1) {
            try self.events.recordEvent(act_id, .act_started, "Bắt đầu Act");

            var act_delta = StateDelta{
                .act_id = act_id,
                .history_messages_added = 0,
                .file_snapshots = &.{},
            };

            // Thực thi Act (Đã tích hợp xử lý lỗi LLM 429/503/JSON bên trong executeAct)
            const step_result = self.executeAct(
                act_id, 
                tool_defs, 
                text_cb, 
                think_cb, 
                &act_delta
            ) catch |err| {
                switch (err) {
                    // TRƯỜNG HỢP 1: Lỗi LLM Malformed JSON -> Inject feedback cho LLM tự sửa ngay lập tức
                    error.LLMMalformedJsonOutput, error.LLMInvalidToolArguments => {
                        try self.events.recordEvent(act_id, .llm_output_malformed, "LLM sinh sai cú pháp JSON");
                        try self.history.addSystemErrorObservation("Định dạng JSON tool call không hợp lệ. Vui lòng xuất đúng cú pháp JSON.");
                        continue;
                    },

                    // TRƯỜNG HỢP 2: Lỗi LLM Rate Limit hoặc Server Overloaded -> Exponential Backoff
                    error.LLMRateLimitExceeded, error.LLMProviderUnavailable => {
                        try self.events.recordEvent(act_id, .llm_call_throttled, "LLM gặp rate limit hoặc 503");
                        const backoff_ms: u64 = @as(u64, 1) << @intCast(act_try_count) * 1000;
                        std.time.sleep(backoff_ms * std.time.ns_per_ms);
                        continue;
                    },

                    // TRƯỜNG HỢP 3: Lỗi Tràn Context Window -> Emergency Context Compaction
                    error.LLMContextWindowExceeded => {
                        try self.events.recordEvent(act_id, .llm_context_overflow, "Context window bị tràn");
                        try self.performEmergencyCompaction();
                        continue;
                    },

                    // TRƯỜNG HỢP 4: Lỗi Runtime Crash / I/O Panic
                    else => {
                        if (act_try_count >= MAX_SYSTEM_RETRIES_PER_ACT) {
                            main.stderrPrint("\n[agent] Act {d} lỗi liên tiếp {d} lần. Ngắt tiến trình: {s}\n", .{ act_id, MAX_SYSTEM_RETRIES_PER_ACT + 1, @errorName(err) });
                            if (act_id > 0) {
                                self.events.rollbackToAct(act_id - 1, &self.history) catch {};
                            }
                            return err;
                        }

                        main.stderrPrint("\n[agent] Act {d} gặp sự cố ({s}). Rollback và thử lại (lần {d}/{d})...\n", .{ act_id, @errorName(err), act_try_count + 1, MAX_SYSTEM_RETRIES_PER_ACT });
                        if (act_id > 0) {
                            try self.events.rollbackToAct(act_id - 1, &self.history);
                        }
                        try self.history.addSystemErrorObservation(@errorName(err));
                        continue;
                    },
                }
            };

            // Ghi nhận Act hoàn thành thành công
            try self.events.recordActComplete(act_id, act_delta);

            // Kiểm tra hoàn thành mục tiêu task
            if (step_result == .exit_loop) {
                return;
            }

            break; // Thoát vòng lặp retry cục bộ, tiến sang Act tiếp theo
        }
    }
}
```

---

## 5. TỔNG KẾT SO SÁNH

| Tiêu chí | Trước đây (`MAX_ITERATIONS = 30`) | Thiết kế mới (Event-Driven Act Toàn Diện) |
|:---|:---|:---|
| **Mô hình vòng lặp** | Đếm số loop cứng ($0 \to 30$) | **1 Loop = 1 Act**, vận hành theo luồng Event Stream |
| **Hỗ trợ Long-lived Tasks** | ❌ Chết ở loop 30 (`MaxIterationsReached`) | ✅ **Không giới hạn**, chạy bền vững đến khi xong mục tiêu |
| **Cơ chế Rollback State** | ❌ Ghi đè file JSON tạm, chỉ phục hồi 1 bước lỗi | ✅ **Rollback chính xác** cả History và File Deltas về bất kỳ Act $N$ |
| **Khả năng chịu lỗi LLM Model** | ❌ 429/503/Malformed JSON làm sập toàn bộ agent | ✅ **Tự phục hồi**: Backoff 429/503, Self-Correction JSON, Emergency Compaction |
| **An toàn khi lỗi (Safety)** | Dễ lặp vô hạn hoặc crash mất dữ liệu | ✅ **Chống đệ quy vô hạn**: Phân loại lỗi, `MAX_RETRIES_PER_ACT = 3`, Inject feedback |
| **Độ tin cậy & Kiểm toán** | Thấp, mất dấu vết sau khi crash | Cao, toàn bộ trajectory được lưu qua chuỗi Events |

---

## 6. KẾ HOẠCH THỰC HIỆN (ACTION PLAN)

1. **Bước 1**: Xóa bỏ `const MAX_ITERATIONS = 30;` và `AgentError.MaxIterationsReached` trong [`src/core/agent.zig`](file:///mnt/hdd/projects/persional/mini/src/core/agent.zig).
2. **Bước 2**: Tạo [`src/core/events.zig`](file:///mnt/hdd/projects/persional/mini/src/core/events.zig) hiện thực `ActEvent`, `StateDelta`, `FileSnapshot`, `EventStore` cùng các sự kiện lỗi LLM.
3. **Bước 3**: Tích hợp thu thập `FileSnapshot` khi công cụ ghi file (`file_edit`, `file_write`, `patch`) được gọi trong Act.
4. **Bước 4**: Hiện thực cơ chế phòng vệ lỗi LLM Model (Exponential Backoff cho 429/503, Self-Correction cho Malformed JSON, Emergency Compaction cho Context Overflow).
5. **Bước 5**: Hiện thực cơ chế Rollback State an toàn và chống đệ quy vô hạn (`MAX_SYSTEM_RETRIES_PER_ACT = 3`).
6. **Bước 6**: Cập nhật [`src/acp/server.zig`](file:///mnt/hdd/projects/persional/mini/src/acp/server.zig) đồng bộ theo trạng thái hoàn thành chuẩn.

---

## 7. PHẢN BIỆN KỸ THUẬT (TECHNICAL REVIEW — COUNTER ARGUMENTS)

> Đối chiếu proposal với code thực tế `src/core/agent.zig`, `src/core/history.zig`.
> **Kết luận trước: Ý tưởng đúng hướng, thiết kế sai tầng.** Phân loại 3 lớp lỗi và "tool error = observation" là điểm mạnh. Nhưng 3 claims cốt lõi của proposal — (1) audit/durable, (2) rollback chính xác, (3) an toàn khi bỏ MAX_ITERATIONS — **đều không được thiết kế hiện tại đáp ứng**, và pseudocode chứa nhiều bug thực tế.

### 7.1. "Event Sourcing" là tên gọi sai — không có persistence (mâu thuẫn cốt lõi)

`EventStore` là `std.ArrayList` **in-memory**. Process crash → toàn bộ events + deltas mất.

- Bảng so sánh (mục 5) claim: *"Cao, toàn bộ trajectory được lưu qua chuỗi Events"* — **sai**. Mất tiến trình = mất trajectory.
- Cơ chế `/tmp/mini_agent_backup_*.json` hiện tại (đủ tồi) ít nhất còn sống sót qua crash. Proposal thay nó bằng thứ chết cùng process → **giảm** độ bền, không tăng.
- Event sourcing thật cần: append-only log trên đĩa, fsync mỗi act, replay để rebuild state. Proposal không có projection, không replay, không WAL, không schema versioning. Thực chất đây là **structured in-memory log + undo journal**. Đặt tên đúng trước khi thiết kế sai theo tên.

**Yêu cầu sửa**: Event log phải là WAL ghi ra đĩa (JSONL append + fsync mỗi Act), replay được khi restart. Đây là điều kiện cần của long-horizon — task 1000 acts mà không sống sót qua crash thì "long-lived" chỉ là long cho đến lần ngắt kết nối đầu tiên.

### 7.2. Rollback History được quảng cáo nhưng KHÔNG được hiện thực

```zig
pub fn rollbackToAct(self: *EventStore, target_act_id: usize, history: *anyopaque) !void
```

- Tham số `history: *anyopaque` — **không bao giờ được dùng** trong thân hàm. Hàm chỉ revert file snapshots + pop deltas.
- `StateDelta.history_messages_added` được ghi nhưng không có code nào truncate History theo nó.
- `*anyopaque` là dấu hiệu của circular dependency (`events.zig` ↔ `history.zig`) bị vá bằng type erasure — thay vì giải quyết, proposal giấu nó.

Mục đích 2 của proposal ("Rollback chính xác cả History") — **chưa tồn tại trong thiết kế**.

### 7.3. Mâu thuẫn chưa xử lý: Rollback vs Compaction

`History.compactWithSummary()` **xóa vĩnh viễn** messages cũ và thay bằng summary (history.zig:251–267). Trong task dài, compaction chắc chắn xảy ra trước khi rollback.

> **Cập nhật**: RFC-003 giải quyết mâu thuẫn này — messages bị compact chuyển sang tier **ARCHIVED** ghi ra disk (JSONL append-only), không bị xóa. Archived JSONL chính là undo log cho rollback: kèm checkpoint đánh dấu "last compactable point", rollback giới hạn về mốc checkpoint gần nhất (điều kiện #4 của mục 7.9 đã thỏa). `window.compactWith()` của RFC-003 thay thế `performEmergencyCompaction()` tự chế.

Hệ quả:
- Sau compaction, "mốc Act 30" không còn tồn tại trong History → rollback về Act 30 bất khả thi.
- `history_messages_added` đếm message của act, nhưng compaction làm mất correspondence giữa act_id ↔ message index.
- Ngay cả mục 2.1 (Emergency Context Compaction cho ContextOverflow) còn **đụng trực tiếp** mục đích rollback: nén context chính là phá hủy dữ liệu rollback.

Proposal không có một dòng nào xử lý tương tác này. Đây là lỗ hổng thiết kế nghiêm trọng nhất của Mục đích 2.

### 7.4. FileSnapshot: memory blow-up + unsafe write-back + phạm vi phủ không đủ

**7.4a. RAM cost O(N_acts × file_size).** `previous_content` giữ nguyên nội dung đầy đủ trong RAM. Task refactor 500 acts chạm file lớn lặp lại → hàng GB. Không có dedup, content-addressing, hay spill-to-disk. Cho long-horizon thì đây là nghịch lý tự hủy.

**7.4b. Phạm vi phủ không đủ.** Snapshot chỉ cover `file_edit/file_write/patch` (Bước 3 của Action Plan). Nhưng agent này còn:
- CodeAct: `mini.write()` / `mini.patch()` qua CodeAct — ghi file ngoài tool registry.
- `bash`: `sed -i`, `git checkout`, `npm install`, `echo >` — không thể snapshot.
- Subagents song song (`batch_invoke_subagents`) ghi file đồng thời.

Rollback về Act N sẽ **ghi đè lên thay đổi của tiến trình ngoài agent** — phá work bên ngoài thay vì khôi phục. Tệ hơn không rollback.

**7.4c. Write-back không atomic.** `std.fs.cwd().writeFile` giữa chừng crash → filesystem ở trạng thái lai, event log (in-memory) cũng mất → không có đường phục hồi.

**Khuyến nghị**: bỏ JSON snapshot trong RAM, dùng git (worktree/stash) hoặc content-addressed store trên đĩa. Rẻ hơn, đúng hơn, và xử lý được rename/permission.

### 7.5. Bỏ MAX_ITERATIONS mà không thay bằng budget = bỏ safety net duy nhất

Điều kiện dừng mới (mục 3.A): *"LLM phát tín hiệu hoàn thành"* hoặc user cancel. Nhưng:

- **LLM loop hành vi có thật**: ping-pong giữa 2 tools, gọi `bash` kiểm tra vô hạn, goal drift. Mỗi act "thành công" → act mới, vô hạn, không lỗi nào được ghi, `MAX_RETRIES_PER_ACT` không bao giờ kích hoạt. Claim "✅ Chống đệ quy vô hạn" (bảng mục 5) chỉ đúng cho error-retry, sai cho happy-path loop.
- **Chi phí không kiểm soát**: không có ceiling token/chi phí/thời gian. Task 1000 acts trên model đắt = tiền thật.

`MAX_ITERATIONS = 30` là thô, nhưng nó là guardrail. Thay bằng:
- Wall-clock deadline + cumulative token/cost budget → dừng có checkpoint.
- Soft act-limit (vd 100) kèm tóm tắt tiến độ và xác nhận user (interactive) hoặc auto-decision.
- Loop detector: hash (tool_name + normalized args) các act gần nhau → phát hiện lặp.

### 7.6. Pseudocode có bug cụ thể (không phải "pseudocode được" — là bug logic)

**7.6a. Backoff shift overflow.**
```zig
const backoff_ms: u64 = @as(u64, 1) << @intCast(act_try_count) * 1000;
```
Trong Zig, `*` binds tighter hơn `<<` → thực thi là `1 << (act_try_count * 1000)`. Shift ≥ 64 → **panic ngay lần retry đầu**. Ý định là `(1 << n) * 1000`. Ngoài ra mục 2.1 nói "2s, 4s, 8s... tối đa 5 lần" nhưng budget chỉ có 3.

**7.6b. Infinite loop thực sự trong case ContextOverflow.** Branch `error.LLMContextWindowExceeded` → `performEmergencyCompaction()` → `continue` **không kiểm tra `act_try_count`**. Nếu 1 message duy nhất đã lớn hơn context window (tool result hiện tại cho phép tới 64KB), compaction không giảm được gì → lặp vô hạn. Trớ trêu: đây chính là "đệ quy vô hạn" mà bảng mục 5 claim đã chống.

**7.6c. Hỗn hợp lỗi chia chung budget retry.** 1×429 + 1×malformed JSON + 1×disk error = thoát vòng. Code **hiện tại** đã tách `rate_limit_retries` riêng (agent.zig:48, `MAX_RATE_LIMIT_RETRIES = 5`) — proposal làm phần này tệ đi.

**7.6d. Tool_use mồ côi sau retry crash.** Trong flow hiện tại, `addAssistantResponse` chạy **trước** `executeTools`. Act crash giữa chừng → history chứa assistant message với `tool_use` nhưng thiếu `tool_result`. Claude API **từ chối request** tiếp theo (invalid message sequence). Proposal inject `addSystemErrorObservation` — method không tồn tại trong `History` — mà không xử lý orphan pairing. Lỗi tương thích API nghiêm trọng chưa được nhìn thấy.

**7.6e. Off-by-one + memory leak.** `while (act_try_count <= MAX)` = 4 lần thử, thông điệp hiển thị lại nói 3. `deltas.pop()` bỏ delta mà không free `previous_content` → leak mỗi rollback; `deinit` cũng không free snapshots.

### 7.7. Bảng so sánh mục 5 = strawman

- "❌ 429/503/Malformed JSON làm sập toàn bộ agent" — **sai**. `agent.zig` đã có: rate-limit retry 5 lần với exponential backoff (dòng 340–347), Ollama fallback backend (`sendToBackend`, dòng 499–516), self-correction loop cho JS error (`js_retry_count`). Proposal trình bày hiện trạng tệ hơn thực tế để kết luận của mình sáng hơn.
- "Rollback file deltas" được đánh ✅ trong khi (như 7.1–7.4) chưa hiện thực, chưa an toàn, và chưa cover bash/CodeAct.
- Không có cột "chi phí/đánh đổi" — mọi thứ ✅ không có price tag là dấu hiệu proposal chưa được stress-test.

### 7.8. Những điểm ĐỒNG Ý (giữ lại)

1. Phân loại 3 tầng lỗi (LLM / Tool / System) và xử lý khác nhau — đúng.
2. Tool error = observation, không rollback — đúng triết lý (code hiện tại đã làm thế).
3. Self-correction feedback cho malformed JSON — pattern đúng (đã chứng minh với `js_retry_count`).
4. Bỏ hard iteration limit cho long-horizon — nhu cầu thật; chỉ cần thay bằng budget (mục 7.5).

### 7.9. Điều kiện để proposal được chấp nhận (rev 5)

| # | Bắt buộc | Lý do |
|---|---|---|
| 1 | Event log = WAL trên đĩa, fsync/act, replay được | Không có nó thì "long-lived" và "audit" là claim rỗng |
| 2 | Snapshot file bằng git/content-addressed store, không RAM | O(N×size) không chấp nhận được |
| 3 | Định nghĩa snapshot boundary: trước MỖI tool call, xử lý multi-tool + CodeAct + bash scope | Rollback nửa vời nguy hiểm hơn không rollback |
| 4 | Giải quyết tương tác Rollback × Compaction (checkpoint chặn compaction qua mốc rollbackable, hoặc chấp nhận rollback-limit = last compaction point và nói rõ) | Mâu thuẫn cấu trúc hiện tại |
| 5 | Budget thay MAX_ITERATIONS: wall-clock + token/cost + loop-detector | Guardrail bị bỏ phải được thay |
| 6 | Tách retry budget theo loại lỗi; fix shift-overflow; guard compaction-failed → abort | Bug trong pseudocode |
| 7 | Xử lý orphan tool_use/tool_result khi retry | Tương thích Claude API |
| 8 | Đổi tên hoặc hiện thực đúng: durable act journal + checkpointing | "Event sourcing" hiện là tên mượn |

**Đánh giá tổng thể**: **REVISE** — không REJECT. Hướng đi đúng, rev 4 chưa sẵn sàng implement.
