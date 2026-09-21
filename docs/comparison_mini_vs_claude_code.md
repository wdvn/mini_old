# So Sánh: mini-agent (MemAct + PGraph) vs Claude Code Superpowers

## Executive Summary

 mini-agent có **foundations mạnh** (Event Sourcing, MemAct, Procedural Graph) nhưng **thiếu structured planning subsystem** để xử lý complex multi-step tasks hiệu quả như Claude Code.

---

## 1. Current State Evidence (Từ Execution Logs)

### 1.1 Plan Watchdog — Bị Truncate

**Evidence:**
```
[Plan Watchdog Directive]: You formulated an active implementation plan 
('tôi sẽ implement",
        "plan:",
        "step 1:",
        "i will implement",
        // ...
    };
    // Retur')
```

**Vấn đề:** `plan_summary_buf: [160]u8` quá nhỏ → plan bị cắt ngang.

### 1.2 Progress Checkpoint — Quá Đơn Giản

**Evidence (act 3):**
```
[Progress Checkpoint]
The previous act (3) completed with the following progress:
Tool: read
Tool: bash


Before proceeding, please assess: what has been accomplished, what remains, and whether you should continue or conclude.
```

**Thiếu:**
- ❌ Không biết đang ở **step nào** trong plan
- ❌ Không có **step status** (pending/active/completed)
- ❌ Không có **dependency info**
- ❌ Không có **directive cụ thể** — nên dùng tool gì next?

**Evidence (act 7):**
```
[Progress Checkpoint]
The previous act (7) completed with the following progress:
Tool: read
Tool: bash
Tool: file_write

Before proceeding, please assess: what has been accomplished, what remains...
```

**Evidence (act 15):**
```
[Progress Checkpoint]
The previous act (15) completed with:
Tool: file_write
Tool: read
Tool: bash

Before proceeding, please assess...
```

### 1.3 Procedural Advisory — Hoạt Động Nhưng Hạn Chế

**Evidence:**
```
[Procedural Advisory (Optional Suggestions)]
Current Action: `bash`
Observed Pattern Suggestions (h=2-hop neighborhood):
- `bash` → `grep` (TRIGGERS)
  - Condition: compiler error or test failure
  - Suggestion: Search codebase for failing symbol...
  - Pitfalls: Do not mutate code before understanding exact error cause.
- `bash` → `session_diagnostics` (TRIGGERS)
  - Condition: crash, timeout, or unexpected failure
⚠️ Advisory Note: These are heuristic suggestions... You are NOT required to follow them.
🎯 Current task reminder: "đối chiếu với memact..."
```

**Đánh giá:**
- ✅ Neighborhood traversal hoạt động đúng (RFC-010)
- ✅ Guidance injection hoạt động
- ⚠️ Nhưng chỉ là **advisory** — model có thể bỏ qua
- ⚠️ Không có **plan context** — không biết current step là gì

### 1.4 Action Loop Detection

**Evidence:**
```
[Action Loop Checkpoint & Trajectory Recap]
📍 Waypoint: Action loop detected (closed orbit in 3D procedural map repeated).
🗺️ Trajectory Scouted: `read` → `read` → `read` → `read` → `read` → `bash` → `bash` → `read` → `read` → `read` → `read` → `read` → `read` → `file_write` → `read` → `read` → `read` → `bash` → `file_edit` → `file_edit` → `file_edit` → `bash` → `read` → `file_edit` → `bash` → `read` → `bash` → `file_edit` → `bash` → `read` → `bash` → `read`
⚠️ Exploration has circled in place without forward progress (ΔZ = 0).
Consider a different approach for the next step if appropriate.
```

**Đánh giá:**
- ✅ Orbit detection hoạt động tốt
- ⚠️ Nhưng chỉ là **warning**, không có ** corrective action**

---

## 2. So Sánh Tính Năng

### 2.1 Planning Capability

| Feature | mini-agent | Claude Code | Gap |
|---------|-----------|-------------|-----|
| **Explicit Planning Phase** | ❌ Không có | ✅ Có — decompose task trước khi execute | 🔴 Critical |
| **Structured Plan Representation** | ❌ 160-byte text summary | ✅ DAG-based steps với dependencies | 🔴 Critical |
| **Cross-Turn Persistence** | ❌ `clearPlan()` mỗi turn | ✅ Plans survive sessions | 🔴 Critical |
| **Dependency Tracking** | ❌ Không có | ✅ Step 2 waits for Step 1 | 🔴 Critical |
| **Drift Detection** | ❌ Không có | ✅ Compare actual vs planned | 🟡 High |
| **Progress Tracking** | ⚠️ Simple tool list | ✅ "Step 2/5 completed (40%)" | 🟡 High |
| **Auto-Recovery** | ⚠️ Basic retry (3 attempts) | ✅ Multi-strategy fallback | 🟡 Medium |

### 2.2 Memory System

| Feature | mini-agent | Claude Code | Notes |
|---------|-----------|-------------|-------|
| **Memory Types** | ✅ Semantic, Episodic, Project State | ✅ Rich memory types | mini-agent có hierarchical memory |
| **Persistence** | ✅ JSONL event log | ✅ File-based | Cả hai đều event-sourced |
| **Keyword Matching** | ✅ ASCII case-insensitive | ✅ Semantic search | mini-agent đơn giản hơn |
| **Supersedes** | ✅ Old entries replaced | ✅ Versioned memories | Tương đương |
| **Access Tracking** | ✅ access_count + last_access | ✅ Retrieval-aware | mini-agent có touch() |

### 2.3 Procedural Guidance

| Feature | mini-agent | Claude Code | Notes |
|---------|-----------|-------------|-------|
| **Graph Structure** | ✅ Directed graph (PGraph) | ⚠️ Different approach | mini-agent unique |
| **H-hop Traversal** | ✅ Configurable (default h=2) | ⚠️ Not available | mini-agent advantage |
| **Orbit Detection** | ✅ 3D procedural space | ❌ Not available | **mini-agent unique** |
| **Guidance Injection** | ✅ Advisory text | ⚠️ Different style | Cả hai đều advisory |
| **Self-Learning** | ✅ Auto-populate edges (N≥3) | ❌ Not available | **mini-agent advantage** |
| **Condition-Based** | ✅ Edge conditions | ⚠️ Not available | mini-agent advantage |

### 2.4 Error Handling & Recovery

| Feature | mini-agent | Claude Code | Notes |
|---------|-----------|-------------|-------|
| **Rate Limit Retry** | ✅ Exponential backoff (12 retries) | ✅ Similar | Tương đương |
| **Context Overflow** | ✅ MemAct compaction | ✅ Summarization | mini-agent có structured compaction |
| **JS Error Recovery** | ✅ 3 retries với error messages | ⚠️ Different approach | mini-agent có CodeAct VM |
| **Watchdog Timeout** | ✅ LLM consultation (WAIT/KILL) | ⚠️ Different approach | **mini-agent unique** |
| **Plan Recovery** | ❌ Không có | ✅ Re-plan on failure | **Claude advantage** |

---

## 3. What mini-agent Does Better

### 3.1 Procedural Graph (PGraph)

**Unique Features:**
1. **3D Domain Classification** — explore/mutate/verify/meta
2. **Orbit Detection** — phát hiện circular patterns trong trajectory
3. **Condition-Based Edges** — edges có conditional guidance
4. **Self-Learning** — auto-populate frequent transitions (N≥3)
5. **H-hop Neighborhood** — configurable guidance radius

**Evidence từ code:**
```zig
// graph_store.zig:347
pub fn detectTrajectoryOrbit(trajectory: []const []const u8, current_tool: ?[]const u8) ?OrbitInfo
```

### 3.2 Event Sourcing & CAS

**Unique Features:**
1. **JSONL Audit Trail** — append-only event log
2. **CAS Integration** — content-addressable storage for rollback
3. **Supersedes Pattern** — old memories replaced by new ones
4. **Access Counting** — LRU-like eviction based on usage

**Evidence từ code:**
```zig
// store.zig:176
fn applySupersedes(self: *MemoryStore, entries: *std.ArrayList(MemoryEntry), entry: MemoryEntry) !void
```

### 3.3 Watchdog with LLM Consultation

**Unique Features:**
1. **Timeout Detection** — Thread 2 monitors execution
2. **LLM Decision** — Query model để decide WAIT vs KILL
3. **Graceful Cleanup** — Interrupt handler cleanup resources

**Evidence từ code:**
```zig
// agent.zig:101
fn watchdogDecisionHandler(ctx: watchdog_mod.DecisionContext) watchdog_mod.TimeoutDecision
```

### 3.4 Token Estimation

**Unique Features:**
1. **CJK-Aware** — Separate heuristic for CJK characters
2. **Message-Level** — Estimate per message including tool overhead
3. **Caching** — StringHashMap cache for repeated estimates

**Evidence từ code:**
```zig
// tokens.zig:46
pub fn estimate(self: *TokenEstimator, text: []const u8) u32
```

---

## 4. What mini-agent Missing (So với Claude Code)

### 4.1 Structured Planning Subsystem

**Claude Approach:**
```
User Request → [Planning Phase] → JSON Plan with Dependencies → Execute → Monitor → Adjust
```

**mini-agent Current:**
```
User Request → Tool Calls (no planning) → Execute → Hope for the best
```

**Missing:**
1. Explicit planning phase
2. DAG-based step decomposition
3. Dependency resolution
4. Parallel execution support

### 4.2 Cross-Turn Plan Persistence

**Claude:**
- Plans stored in workspace memory
- Can resume interrupted tasks
- Plans survive process restart

**mini-agent:**
```zig
// agent.zig:1824
self.clearPlan();  // Plan mất hoàn toàn sau mỗi turn
```

**Missing:**
1. Plan serialization to disk
2. Plan restoration at turn start
3. Interrupted plan recovery

### 4.3 Drift Detection & Correction

**Claude:**
- Compare executed tools vs planned tools
- Auto-inject correction advisories
- Escalate when drift > threshold

**mini-agent:**
- No comparison mechanism
- No drift scoring
- No corrective actions

**Missing:**
1. Actual vs planned trajectory comparison
2. Drift score calculation
3. Automatic correction injection

### 4.4 Rich Progress Tracking

**Claude:**
```
[Progress] Step 2/5 completed (40%)
✓ Step 1: Read config.yaml
✓ Step 2: Create migration script
→ Step 3: Run migration (active)
  Estimated: 2 more acts
```

**mini-agent Current:**
```
[Progress Checkpoint]
The previous act (7) completed with:
Tool: read
Tool: bash
Tool: file_write
```

**Missing:**
1. Step-level progress tracking
2. Percentage completion
3. Estimated remaining acts
4. Dependency status

---

## 5. Integration Opportunities

### 5.1 PGraph + Planning

**Current PGraph:**
- Stores tool-to-tool transitions
- Provides neighborhood guidance

**Opportunity:**
- Store **plan sequences** as reusable patterns
- Learn common planning strategies
- Suggest plan templates based on task type

### 5.2 MemAct + Plan Persistence

**Current MemAct:**
- Semantic/Episodic/Project State memory
- Keyword-based retrieval

**Opportunity:**
- Store plans as **semantic memories**
- Retrieve relevant plans by task similarity
- Link plans to project state

### 5.3 Watchdog + Plan Monitoring

**Current Watchdog:**
- Monitors execution timeout
- LLM consultation for WAIT/KILL

**Opportunity:**
- Add **plan drift detection** to watchdog
- Escalate when plan deviation > threshold
- Trigger re-plan on excessive drift

---

## 6. Recommendations

### Immediate (Phase 1-2, ~3-5 ngày)

1. **Tăng plan_summary_buf** từ 160 → 1024 bytes
2. **Enhanced Progress Checkpoint** — thêm plan context
3. **Basic Plan Parsing** — extract JSON/Markdown plans

### Short Term (Phase 3-4, ~5-7 ngày)

4. **Dependency Resolution** — execute steps theo DAG order
5. **Drift Detection** — compare actual vs planned tools
6. **Plan Persistence** — save/restore plans to `~/.mini/plans/`

### Medium Term (Phase 5-6, ~5-7 ngày)

7. **Plan-Driven Tool Selection** — filter tools theo current step
8. **PGraph Integration** — store plan patterns
9. **Auto-Recovery** — retry/re-plan/abort strategies

### Long Term (Phase 7, ~3-5 ngày)

10. **Parallel Execution** — RFC-013 Act Queue integration
11. **Plan Templates** — learned patterns from PGraph
12. **Performance Optimization** — benchmark & tune

**Total Timeline:** ~16-24 ngày

---

## 7. Conclusion

### Strengths to Preserve
- ✅ Procedural Graph (unique 3D orbit detection)
- ✅ Event Sourcing + CAS (robust audit trail)
- ✅ Watchdog with LLM consultation
- ✅ CJK-aware token estimation

### Gaps to Fill
- 🔴 Structured Planning Subsystem
- 🔴 Cross-Turn Plan Persistence
- 🟡 Drift Detection & Correction
- 🟡 Rich Progress Tracking

### RFC-019 Addresses These Gaps
- Provides structured plan data model
- Implements cross-turn persistence
- Adds drift detection
- Enhances progress tracking

---

*Analysis Date: 2025-07-18*  
*Evidence Sources: execution logs, agent.zig, graph_store.zig, store.zig*  
*Comparison Target: Claude Code documentation*
