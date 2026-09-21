# RFC-014: Dead Code Audit & Removal Proposal

| Attribute | Value |
|---|---|
| RFC | 014 |
| Title | Dead Code Audit — Struct Fields & Options Never Read at Runtime |
| Status | **In Progress** |
| Version | 0.4 (execution-summary) |
| Dependencies | RFC-009 (idle watchdog), RFC-011 (media I/O), RFC-012 (provider abstraction), RFC-013 (act queue) |
| References | [Session hang RCA (PID 35537)](../sessions/journal_35537.jsonl) |
| Author | mini-agent |
| Date | 2026-09-19 |

---

## CONFLICT CORRECTIONS SUMMARY (v0.1 → v0.4)

| # | RFC-014 v0.1 Claim | Verified State | Resolution |
|---|---|---|---|
| C1 | `timeout_secs` "never read" | ✅ Deadline check exists (line 738) + abs_max cap (line 725) | **✅ DONE** |
| C2 | Remove `TurnStats.reasoning_tokens` | 🔴 Đã tồn tại → **ĐÃ XÓA** (Phase 2) | **✅ DONE** |
| C3 | Remove `TurnStats.files_modified` | 🔴 Đã tồn tại → **ĐÃ XÓA** (Phase 2) | **✅ DONE** |
| C4 | `QueueMetrics.total_*` "không tồn tại" | 🔴 Tồn tại + avg methods (dead) → **ĐÃ XÓA** (Phase 3) | **✅ DONE** |
| C5 | ActExecutionInfo cleanup | Postpone — RFC-012 dependency | **⏸️ POSTPONED** |
| C6 | ImageBlock audit | Postpone — RFC-011 dependency | **⏸️ POSTPONED** |
| C7 | Context overflow | Missing proactive warning | **⏳ TODO (Phase 4)** |

---

## EXECUTION VERIFICATION

### Phase 1: timeout_secs deadline enforcement — ✅ DONE
**Status:** Đã implement từ trước trong codebase.

```zig
// src/lib/http_request.zig:718-743
const deadline_ms: i64 = blk: {
    ...
    const abs_max: u32 = @min(opts.timeout_secs, @max(opts.idle_timeout_secs, 1) * 6);
    break :blk start_ms + @as(i64, @intCast(abs_max)) * 1000;
};
// Wall-clock check (line 738):
if (now_ms >= deadline_ms) {
    if (!got_any) return error.StreamIdleTimeout;
    break :blk error.StreamIdleTimeout;
}
```

**Evaluation:** ✅ Phase 1 đã hoàn thành trước khi RFC-014 được viết. Không cần sửa gì thêm.

---

### Phase 2: Remove TurnStats.dead fields — ✅ DONE

**File:** `src/ui/chat_stream.zig`

```diff
  pub const TurnStats = struct {
      prompt_tokens: usize = 0,
      completion_tokens: usize = 0,
-     reasoning_tokens: usize = 0,    // ❌ DEAD — never assigned, never read
      context_tokens: usize = 0,
      max_context_tokens: usize = 128 * 1024,
      duration_ms: u64 = 0,
      acts_count: usize = 1,
-     files_modified: usize = 0,       // ❌ DEAD — never assigned, never read
  };
```

**Evidence (post-cleanup):**
```bash
$ grep -rn "reasoning_tokens\|files_modified" src/ui/chat_stream.zig
# → 0 matches (fields removed)
```

**Evaluation Step 2:** ✅ **ĐÃ LÀM** — 2 dead fields đã xóa thành công.

---

### Phase 3: Remove QueueMetrics.dead fields + avg methods — ✅ DONE

**File:** `src/core/act_queue.zig`

```diff
  pub const QueueMetrics = struct {
      enqueued: usize = 0,
      dequeued: usize = 0,
      completed: usize = 0,
      failed: usize = 0,
      cancelled: usize = 0,
-     total_wait_time_ms: u64 = 0,     // ❌ DEAD — never assigned, avg always 0
-     total_execution_time_ms: u64 = 0, // ❌ DEAD — never assigned, avg always 0
      current_queue_size: usize = 0,
      current_running_count: usize = 0,
-
-     pub fn avgWaitTime(self: *const QueueMetrics) u64 { ... }   // ❌ DEAD — no callers
-
-     pub fn avgExecutionTime(self: *const QueueMetrics) u64 { ... } // ❌ DEAD — no callers
  };
```

**Evidence (post-cleanup):**
```bash
$ grep -rn "total_wait_time_ms\|total_execution_time_ms\|avgWaitTime\|avgExecutionTime" src/core/act_queue.zig
# → 0 matches (fields + methods removed)
```

**Additional fix:** Removed duplicate `lessThan` function (was defined twice in file).

**Evaluation Step 3:** ✅ **ĐÃ LÀM** — dead fields + avg methods đã xóa thành công.

---

### Phase 4: Proactive Context Overflow Prevention — ⏳ TODO

**Problem:** Hệ thống không có cảnh báo sớm khi context đạt ngưỡng nguy hiểm.

**Current state:**
- `TurnStats.context_tokens` và `max_context_tokens` đã có
- Không có proactive warning threshold
- Chỉ detect sau khi API trả HTTP 400 "context_window exceeded"

**Proposed implementation:**
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

**Evaluation Step 4:** ⏳ **CHƯA LÀM** — cần implement trong agent.zig.

---

### Phase 5: ActExecutionInfo cleanup — ⏸️ POSTPONED

**Reason:** RFC-012 Provider Abstraction Layer sẽ cần các field này cho observability.

**Fields affected:**
- `exec_type` — provider-specific execution metadata
- `stdout` — tool output capture
- `duration_ms` — timing metrics
- `error_message` — error reporting

**Decision:** Giữ nguyên đến khi RFC-012 integration hoàn tất.

---

### Phase 6: ImageBlock audit — ⏸️ POSTPONED

**Reason:** RFC-011 Media I/O đang trong quá trình wire `ImageBlock` end-to-end.

**Status:** Chờ RFC-011 Phase 0 hoàn tất, sau đó audit lại `ImageBlock` fields.

---

## IMPLEMENTATION STATUS SUMMARY

| Phase | Task | Status | Evidence |
|---|---|---|---|
| P1 | timeout_secs deadline | ✅ DONE | `http_request.zig:738` — deadline check exists |
| P2 | Remove TurnStats dead fields | ✅ DONE | Grep: 0 matches post-cleanup |
| P3 | Remove QueueMetrics dead fields | ✅ DONE | Grep: 0 matches post-cleanup |
| P4 | Context overflow warning | ⏳ TODO | Cần implement trong agent.zig |
| P5 | ActExecutionInfo journal wire | ⏸️ POSTPONED | RFC-012 dependency |
| P6 | ImageBlock audit | ⏸️ POSTPONED | RFC-011 dependency |

---

## CONFLICT ANALYSIS METHODOLOGY

Mỗi bước thực hiện đều có evaluation:

1. **Verification trước khi làm:** Grep codebase để xác nhận field có tồn tại, có gán, có đọc không
2. **Thực hiện cleanup:** Sửa file bằng file_edit
3. **Verification sau khi làm:** Grep lại để xác nhận field đã biến mất
4. **Build check:** Chạy `zig build test` để đảm bảo không break compilation

---

## REFERENCES

- Session hang RCA: PID 35537, Act 132, 178 phút idle
- Journal: `~/.mini/sessions/journal_35537.jsonl`
- RFC-009: Stream idle watchdog design
- RFC-011: Media I/O (ImageBlock ingestion/generation)
- RFC-012: Provider Abstraction Layer
- RFC-013: Act Queue System
- Context overflow case: 150,359 tokens / 128,000 limit (117%)
