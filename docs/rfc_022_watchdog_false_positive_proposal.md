# RFC-022: Watchdog False-Positive Elimination

## Summary

Sửa lỗi Plan Watchdog (RFC-019) trigger sai khi model đưa ra **Final Answer hợp lệ**: watchdog extract keyword kiểu "implementation plan", "step 1", "implement week 1" từ chính assistant text và coi text-only turn là vi phạm, ép thực hiện step không tồn tại. Đây là mặt trái (over-enforcement) của đúng vấn đề RFC-020 đang giải (under-enforcement).

**Related**: RFC-019 (Structured Planning — plan_monitor.zig), RFC-020 (Semantic Advisory Enforcement), RFC-021 (Local Small-LLM Judge — candidate cho semantic gate).

---

## 1. Evidence (Session thực tế, 2026-09-22)

### Incident 1
- User task: "sửa luôn vào rfc_021" → file `docs/rfc_021_local_small_llm_proposal.md` được ghi + verify (8419 bytes, 15 sections).
- Model trả Final Answer tóm tắt, có câu: *"Bước tiếp theo nếu bạn muốn: implement Week 1 (llama.cpp dependency...)"*.
- Watchdog extract: `'6. Implementation plan 4 tuần + success metrics...'` → coi là active plan → ép "execute Step 1".
- Model bị ép turn thêm 2 act, user phải Ctrl+C.

### Incident 2
- Model phân tích root cause của chính Incident 1, viết: *"3. Watchdog lại hiểu sai: nó thấy chữ 'Implementation plan 4 tuần' và 'implement Week 1' trong text"*.
- Watchdog extract **chính câu mô tả lỗi false-positive** làm plan → ép thực hiện lại lần 3.

### Code evidence

`src/core/plan_monitor.zig`:
- `generateStepEnforcement()` (dòng 180–202) fire khi "model returns text without tool call" — **không có khái niệm task completion**.
- Plan state được kích hoạt bởi **keyword extraction từ assistant text** (cùng pattern false-positive mà RFC-019 mục 1.1 tự mô tả: keyword "plan:", "step 1:", "i will implement" xuất hiện trong code snippet/log).
- Không phân biệt: text-only turn khi task đã hoàn thành (Final Answer hợp lệ) vs. text-only turn khi đang né việc (stalling).

---

## 2. Root Cause

```
Assistant text chứa keyword trông giống plan (kể cả khi đang DESCRIBE plan/lỗi)
    ↓
Keyword extractor tạo "active plan state" (không qua plan_parser/plan_store pipeline)
    ↓
Watchdog: text-only turn + active plan = drift → ép execute Step 1
    ↓
False-positive: Final Answer bị cấm, agent loop lãng phí, user phải can thiệp
```

**Phân loại lỗi**: Over-enforcement — đối xứng với under-enforcement của RFC-020 (advisory bị ignore 100%).

---

## 3. Proposed Solution

### 3.1 Gate 1 — Plan provenance (deterministic)

Chỉ coi plan là "active" nếu được tạo qua **pipeline chuẩn RFC-019** (plan_parser → plan_store → plan_executor, có CAS persistence). Bỏ hoàn toàn việc tạo plan state từ keyword matching trên assistant text.

```zig
// PSEUDOCODE:
// if (plan.origin != .parser_pipeline) return null; // không enforce
```

### 3.2 Gate 2 — Completion check (deterministic)

Trước khi enforce, kiểm tra: tool mutation cuối cùng đã được verify thành công chưa (file tồn tại, test pass...). Nếu goal của user request đã verify → text-only turn là Final Answer hợp lệ, cho qua.

```zig
// PSEUDOCODE:
// if (last_act_was_verified_mutation && user_goal_satisfied) allow_final_answer;
```

### 3.3 Gate 3 — Semantic classification (optional, dùng RFC-021)

Nếu `MINI_LOCAL_LLM_ENABLED=1`: dùng local judge (SmolLM2-135M, async watchdog thread) phân loại turn cuối: `final_answer | stalling | mid_plan`. Chỉ dùng để điều chỉnh — severity/enforcement vẫn do Gate 1–2 deterministic quyết định (cùng triết lý RFC-021).

### 3.4 Output khi enforce (sau khi qua cả 2 gate)

Giữ format `[Plan Enforcement]` hiện tại của `generateStepEnforcement()` — không đổi.

---

## 4. File Changes

| File | Change | Ước lượng |
|------|--------|-----------|
| `src/core/plan_monitor.zig` | Thêm Gate 1 (provenance check) + Gate 2 (completion check) trước `generateStepEnforcement()` | +25 dòng |
| `src/core/agent.zig` | Truyền plan provenance + last-verification status vào monitor | +8 dòng |
| `src/runtime/local_llm.zig` (RFC-021, optional) | Judge classification endpoint | +15 dòng |
| `testcases/test_plan_monitor.zig` | Regression: final-answer turn không bị enforce | +40 dòng |

## 5. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Miss stalling thật (false-negative) | Medium | Medium | Gate 2 yêu cầu verification evidence, không chỉ text; telemetry đo miss rate |
| Provenance tracking bỏ sót plan hợp lệ | Low | Medium | Fallback: plan có tool_hint + user phê duyệt vẫn enforce |
| Judge Gate 3 sai | Medium | Low | Chỉ advisory, không quyết định enforcement |

## 6. Success Metrics

| Metric | Baseline | Target |
|--------|----------|--------|
| False-positive enforcement trên Final Answer | 2/2 turns trong session test | 0 |
| Miss rate (stalling không bị phát hiện) | N/A | ≤ 5% |
| Lãng phí act do watchdog sai | ~2–3 acts/incident | ~0 |

## 7. Conclusion

Watchdog hiện tại là rule cứng thiếu ngữ cảnh completion/provenance. Hai gate deterministic (3.1, 3.2) giải quyết false-positive mà không cần LLM; Gate 3 (local judge từ RFC-021) là nâng cấp optional khi model nhỏ được embed.

**Recommendation**: Implement Gate 1–2 trước (deterministic, ~35 dòng), Gate 3 sau khi RFC-021 có runtime.

**References:**
- RFC-019: Structured Planning System
- RFC-020: Semantic Advisory Enforcement System
- RFC-021: Embedded Local Small-LLM (Edge Judge)