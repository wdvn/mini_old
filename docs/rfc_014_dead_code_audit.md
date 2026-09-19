# RFC-014: Dead Code Audit & Removal Proposal

| Attribute | Value |
|---|---|
| RFC | 014 |
| Title | Dead Code Audit — Struct Fields & Options Never Read at Runtime |
| Status | **Proposed** |
| Version | 0.3 (verification-corrected) |
| Dependencies | RFC-009 (idle watchdog), RFC-011 (media I/O), RFC-012 (provider abstraction), RFC-013 (act queue) |
| References | [Session hang RCA (PID 35537)](../sessions/journal_35537.jsonl) — Act 132 treo 178 phút do stream timeout |
| Author | mini-agent |
| Date | 2026-09-19 |

---

## CONFLICT CORRECTIONS (v0.1 → v0.3)

| # | RFC-014 v0.1 Claim | Verified State (2026-09-19) | Resolution |
|---|---|---|---|
| C1 | `timeout_secs` "never read" | ✅ **ĐÃ FIX** — deadline check tồn tại tại `http_request.zig:733-743` + `abs_max` cap (line 725) | Phase 1 **✅ DONE** |
| C2 | Remove `TurnStats.reasoning_tokens` | 🔴 **Vẫn tồn tại** (line 101) — không gán, không đọc → **DEAD** | Phase 2 **TODO** — xóa |
| C3 | Remove `TurnStats.files_modified` | 🔴 **Vẫn tồn tại** (line 106) — không gán, không đọc → **DEAD** | Phase 2 **TODO** — xóa |
| C4 | `QueueMetrics.total_*` "không tồn tại" | 🔴 **Tồn tại** (line 137-138) + dùng trong avg methods — nhưng **KHÔNG CÓ GÁN GIÁ TRỊ** → avg luôn = 0 | Phase 3 **TODO** — xóa fields + avg methods |
| C5 | ActExecutionInfo cleanup | 🟡 Postpone — RFC-012 providers cần cho observability | **POSTPONED** |
| C6 | ImageBlock không đề cập | ➕ Postpone — RFC-011 đang wire | **POSTPONED** |

---

## 1. Motivation

### 1.1. Problem: timeout_secs đã được fix (Phase 1 ✅ DONE)

**Evidence (verified):**
```bash
# Deadline check exists at http_request.zig:733-743:
$ grep -n "deadline_ms\|StreamIdleTimeout" src/lib/http_request.zig
718:    const deadline_ms: i64 = blk: {
733:            // Wall-clock check: abort if total stream duration exceeded.
737:                if (now_ms >= deadline_ms) {
741:                    break :blk error.StreamIdleTimeout;
772:    if (read_result) |_| {} else |e| {
774:        if (e == error.StreamIdleTimeout) return error.StreamIdleTimeout;
```

**Evaluation Step 1:** ✅ **ĐÃ LÀM** — Phase 1 hoàn tất. Không cần sửa gì thêm.

---

### 1.2. Dead Fields Analysis

#### 1.2.1. TurnStats.reasoning_tokens & files_modified — DEAD, CẦN XÓA

**File:** `src/ui/chat_stream.zig:98-107`

```zig
pub const TurnStats = struct {
    prompt_tokens: usize = 0,
    completion_tokens: usize = 0,
    reasoning_tokens: usize = 0,    // ❌ DEAD: never assigned, never read
    context_tokens: usize = 0,
    max_context_tokens: usize = 128 * 1024,
    duration_ms: u64 = 0,
    acts_count: usize = 1,
    files_modified: usize = 0,       // ❌ DEAD: never assigned, never read
};
```

**Evidence (grep verified):**
```bash
# Assignment check:
$ grep -rn "reasoning_tokens\s*=" src/ui/chat_stream.zig
# → 0 matches (never assigned)

$ grep -rn "files_modified\s*=" src/
# → 0 matches (never assigned)

# Read check:
$ grep -rn "\.reasoning_tokens\|\.files_modified" src/
# → 0 matches in chat_stream.zig or external files
```

**Impact:** Low — ~16 bytes memory per TurnStats instance. Không ảnh hưởng runtime.

**Evaluation Step 2:** ⏳ **CHƯA LÀM** — cần xóa 2 fields này.

---

#### 1.2.2. QueueMetrics.total_wait_time_ms & total_execution_time_ms — DEAD ACCUMULATORS

**File:** `src/core/act_queue.zig:131-152`

```zig
pub const QueueMetrics = struct {
    enqueued: usize = 0,
    dequeued: usize = 0,
    completed: usize = 0,
    failed: usize = 0,
    cancelled: usize = 0,
    total_wait_time_ms: u64 = 0,     // ⚠️ DECLARED but NEVER ASSIGNED
    total_execution_time_ms: u64 = 0, // ⚠️ DECLARED but NEVER ASSIGNED
    current_queue_size: usize = 0,
    current_running_count: usize = 0,

    pub fn avgWaitTime(self: *const QueueMetrics) u64 {
        if (self.enqueued == 0) return 0;
        return self.total_wait_time_ms / @as(u64, @intCast(self.enqueued));  // ← ALWAYS 0
    }

    pub fn avgExecutionTime(self: *const QueueMetrics) u64 {
        const done = self.completed + self.failed;
        if (done == 0) return 0;
        return self.total_execution_time_ms / @as(u64, @intCast(done));      // ← ALWAYS 0
    }
};
```

**Evidence (grep verified):**
```bash
# Declaration:
$ grep -n "total_wait_time_ms\|total_execution_time_ms" src/core/act_queue.zig
137:    total_wait_time_ms: u64 = 0,
138:    total_execution_time_ms: u64 = 0,

# Assignment:
$ grep -rn "total_wait_time_ms\s*=\|total_execution_time_ms\s*=" src/
# → 0 matches (NEVER assigned anywhere!)

# Usage in avg methods only:
$ grep -n "avgWaitTime\|avgExecutionTime" src/
# → Only method definitions, no callers found
```

**Conflict note:** RFC-013 design định nghĩa `avg_wait_time_ms`/`avg_execution_time_ms` trực tiếp, nhưng implementation thêm `total_*` accumulators + computed avg methods. Tuy nhiên **không có code nào gọi** `avgWaitTime()`/`avgExecutionTime()` và **không có code nào gán** `total_*` fields → **dead code**.

**Impact:** 
- Fields chiếm ~16 bytes memory
- avg methods luôn trả về 0 (divide by zero protected)
- Không có caller nào sử dụng

**Evaluation Step 3:** ⏳ **CHƯA LÀM** — cần xóa 2 fields + 2 avg methods.

---

### 1.3. Context Overflow Monitoring — Hidden Bug

**File:** `src/ui/chat_stream.zig` (TurnStats), `src/core/agent.zig:1351` (detection)

**Problem:** Hệ thống phát hiện context overflow nhưng xử lý không đúng cách:
1. Token estimator dùng heuristic → sai lệch ~10-20% so với API real usage
2. Không có proactive warning — chỉ detect sau HTTP 400 "context_window exceeded"
3. Emergency compaction không guaranteed — có thể fail → process terminate

**Real example:** Session đạt 117% context limit (150,359 / 128,000 tokens).

**Impact:** Medium — gây session hang hoặc terminate đột ngột.

**Evaluation Step:** ⏳ **CHƯA LÀM** — cần implement proactive overflow prevention.

---

### 1.4. ActExecutionInfo Fields — Postpone (RFC-012 Dependency)

**File:** `src/core/act_logger.zig:20-27`

```zig
pub const ActExecutionInfo = struct {
    exec_type: []const u8 = "none",      // ⚠️ RFC-012 providers may need for observability
    stdout: ?[]const u8 = null,          // ⚠️ Useful for debugging
    return_value_json: ?[]const u8 = null, // ⚠️ Useful for act replay
    is_error: bool = false,              // ✅ Used in agent.zig
    duration_ms: u64 = 0,                // ⚠️ RFC-012 provider timing metadata
    error_message: ?[]const u8 = null,   // ⚠️ Useful for error reporting
};
```

**Decision:** 🟡 **POSTPONE** cleanup until RFC-012 (Provider Abstraction Layer) fully integrated.

---

### 1.5. ImageBlock Audit — Postpone (RFC-011 Dependency)

**File:** `src/core/protocol.zig:60-65, 189-192`

```zig
pub const ImageBlock = struct {
    data: []const u8,           // base64 without prefix
    media_type: []const u8,     // MIME type
};
// ContentBlock.image variant + deinit handler already exists
```

**Status:** ⏳ **BLOCKED** by RFC-011 Phase 0 implementation.

---

## 2. Implementation Plan (Corrected)

| Phase | Task | Status | Depends On |
|---|---|---|---|
| **P1** (Critical) | Fix `timeout_secs` deadline enforcement | ✅ **DONE** | None |
| **P2** (Cleanup) | Remove `TurnStats.reasoning_tokens` & `files_modified` | 🔴 **TODO** | None |
| **P3** (Cleanup) | Remove `QueueMetrics.total_*` fields + avg methods | 🔴 **TODO** | None |
| **P4** (Fix) | Proactive context overflow warning at 90%/95% | 🔴 **TODO** | None |
| **P5** (Deferred) | Wire `ActExecutionInfo` fields to journal | ⏸️ POSTPONED | RFC-012 integration |
| **P6** (Deferred) | Audit `ImageBlock` fields | ⏸️ POSTPONED | RFC-011 Phase 0 |

---

## 3. Proposed Actions Detail

### 3.1. Phase 2: Remove Dead TurnStats Fields

**File:** `src/ui/chat_stream.zig`

```diff
  pub const TurnStats = struct {
      prompt_tokens: usize = 0,
      completion_tokens: usize = 0,
-     reasoning_tokens: usize = 0,
      context_tokens: usize = 0,
      max_context_tokens: usize = 128 * 1024,
      duration_ms: u64 = 0,
      acts_count: usize = 1,
-     files_modified: usize = 0,
  };
```

**Risk:** None — không có caller nào đọc 2 fields này.

---

### 3.2. Phase 3: Remove Dead QueueMetrics Fields + Avg Methods

**File:** `src/core/act_queue.zig`

```diff
  pub const QueueMetrics = struct {
      enqueued: usize = 0,
      dequeued: usize = 0,
      completed: usize = 0,
      failed: usize = 0,
      cancelled: usize = 0,
-     total_wait_time_ms: u64 = 0,
-     total_execution_time_ms: u64 = 0,
      current_queue_size: usize = 0,
      current_running_count: usize = 0,

-     pub fn avgWaitTime(self: *const QueueMetrics) u64 {
-         if (self.enqueued == 0) return 0;
-         return self.total_wait_time_ms / @as(u64, @intCast(self.enqueued));
-     }
-
-     pub fn avgExecutionTime(self: *const QueueMetrics) u64 {
-         const done = self.completed + self.failed;
-         if (done == 0) return 0;
-         return self.total_execution_time_ms / @as(u64, @intCast(done));
-     }
  };
```

**Risk:** Low — không có caller nào gọi 2 avg methods.

---

### 3.3. Phase 4: Proactive Context Overflow Prevention

**Files:** `src/core/agent.zig`, `src/ui/chat_stream.zig`

```zig
// Trong agent.zig — trước mỗi LLM call:
const ctx_pct = @as(f64, @floatFromInt(ctx_tokens)) / @as(f64, @floatFromInt(context_window));
if (ctx_pct >= 0.9) {
    main.stderrPrint("\n\x1b[33m[agent] ⚠️ Context usage at {:.0}% — triggering proactive compaction\x1b[0m\n", .{ctx_pct * 100.0});
    self.compactContext(act_id) catch {};
}
if (ctx_pct >= 0.95) {
    try self.compactContext(act_id);
}
```

**Risk:** Low — only triggers compaction, doesn't change error handling.

---

## 4. Risk Assessment

| Change | Risk | Mitigation |
|---|---|---|
| Remove `TurnStats` fields | None | Không có caller nào đọc |
| Remove `QueueMetrics` totals + avg methods | Low | Kiểm tra không có caller trước khi xóa |
| Proactive context overflow | Low | Only triggers compaction |
| Postpone ActExecutionInfo/ImageBlock | None | Không làm gì cả |

---

## 5. References

- Session hang RCA: PID 35537, Act 132, 178 phút idle
- Journal: `~/.mini/sessions/journal_35537.jsonl`
- RFC-009: Stream idle watchdog design
- RFC-011: Media I/O (ImageBlock ingestion/generation)
- RFC-012: Provider Abstraction Layer (needs ActExecutionInfo fields)
- RFC-013: Act Queue System (QueueMetrics design divergence noted)
- Context overflow case: 150,359 tokens / 128,000 limit (117%)
