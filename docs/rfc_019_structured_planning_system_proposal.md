# RFC-019: Structured Planning System

## Summary

Thêm hệ thống lập kế hoạch có cấu trúc (structured planning) cho mini-agent, giải quyết các gaps được xác định qua phân tích execution logs thực tế và gap analysis chi tiết.

**Evidence thu thập từ execution logs:**
- Plan Watchdog directive bị truncate ở 160 bytes
- Progress Checkpoint chỉ liệt kê tools, không có plan context
- Procedural Advisory (RFC-010) hoạt động nhưng chỉ là heuristic suggestions
- Không có cross-turn plan persistence

---

## 1. Current State Analysis (Từ Execution Logs)

### 1.1 Plan Watchdog — Bị Truncate

**Evidence từ execution:**
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

**Vấn đề:**
- `plan_summary_buf: [160]u8` quá nhỏ
- Plan summary bị cắt giữa chừng (`// Retur'`)
- Không thể hiện được full plan structure

**Code reference:** `src/core/agent.zig:272`
```zig
plan_summary_buf: [160]u8 = undefined,
```

### 1.2 Progress Checkpoint — Quá Đơn Giản

**Evidence từ execution:**
```
[Progress Checkpoint]
The previous act (1) completed with the following progress:
Tool: read


Before proceeding, please assess: what has been accomplished, what remains, and whether you should continue or conclude.
```

**Thiếu:**
- ❌ Không biết đang ở **step nào** trong plan
- ❌ Không có **step status** (pending/active/completed)
- ❌ Không có **dependency info** — step tiếp theo phụ thuộc gì?
- ❌ Không có **directive cụ thể** — nên dùng tool gì next?
- ❌ Hỏi LLM "tự đánh giá" thay vì đưa **hướng dẫn có cấu trúc**

**Code reference:** `src/core/agent.zig:1113-1127`

### 1.3 Procedural Advisory — Hoạt Động Nhưng Hạn Chế

**Evidence từ execution:**
```
[Procedural Advisory (Optional Suggestions)]
Current Action: `bash`
Observed Pattern Suggestions (h=2-hop neighborhood):
- `bash` → `grep` (TRIGGERS)
  - Condition: compiler error or test failure
  - Suggestion: Search codebase for failing symbol...
⚠️ Advisory Note: These are heuristic suggestions... You are NOT required to follow them.
```

**Đánh giá:**
- ✅ Neighborhood traversal hoạt động đúng (RFC-010)
- ✅ Guidance injection hoạt động
- ⚠️ Nhưng chỉ là **advisory** — model có thể bỏ qua
- ⚠️ Không có **plan context** — không biết current step là gì

### 1.4 Plan Lifecycle — Turn-Scoped

**Code:** `src/core/agent.zig:1820-1825`
```zig
self.clearPlan();        // Xóa plan mỗi turn
self.clearProgress();    // Xóa progress mỗi turn
```

**Hệ quả:**
- Plan mất hoàn toàn sau mỗi turn
- Không restore được từ previous sessions
- Không resume được interrupted plans

---

## 2. Existing Planning-Adjacent Mechanisms (Gap Analysis)

### 2.1 Plan Detection & Enforcement (Reactive)

**File:** `src/core/agent.zig:588-621`

```zig
pub fn detectPlanInText(text: []const u8) ?[]const u8 {
    const markers = [_][]const u8{
        "tôi sẽ implement",
        "plan:",
        "step 1:",
        "i will implement",
        // ...
    };
    // Returns 160-byte truncated text summary
}
```

**Limitations:**
- Plan detection là **heuristic string matching**, không phải semantic understanding
- Plans được lưu thành **single 160-byte truncated summary** — không có step decomposition, không có ordering, không có dependency tracking
- Không validate được executed steps có follow plan hay không
- Procrastination cap = 2 quá thấp; research plan có thể cần nhiều exploration hơn

### 2.2 Action Loop Recovery with Plan Request

Khi action loops detected (identical tool repeats, macro-cycles, orbits):
```zig
const trip_msg = "[Action Loop Checkpoint & Trajectory Recap]...";
try self.history.addUser(trip_msg);
```

Đây là **reactive replanning** — triggered only after agent is stuck, không phải proactive planning trước khi execute.

### 2.3 Procedural Graph (RFC-010)

**File:** `src/core/memact/graph_store.zig`

PGraphStore maintains persistent event-sourced directed graph của tool transitions tại `~/.mini/memory/<project_hash>/pgraph.jsonl`.

**What it provides:**
- Node per tool action với descriptions
- Edge attributes: condition, guidance, pitfalls
- H-hop neighborhood traversal cho situational guidance
- Automatic learning: frequent transitions (≥3) auto-promote to edges
- Orbit detection trong 3D procedural space
- Trajectory recap advisories via `serializeGuidance()`

**Limitations for planning:**
- Graph mã hóa **tool-to-tool transitions**, không phải **task decomposition** hay **sub-goal hierarchies**
- Guidance là **optional advisory** text — LLM có thể bỏ qua
- Không có concept của "planned next step" vs "actual next step" comparison
- Seeded defaults hardcoded (grep→file_read, file_edit→bash, bash→grep)
- Không có temporal dimension

### 2.4 Progress Tracking & Checkpoints

`updateProgress()` lưu last act's file changes + tool summary trong `progress_summary_buf` (512 bytes).

**Injected format:**
```
"[Progress Checkpoint]\nThe previous act ({act_id}) completed with:\n{s}\n\nBefore proceeding, please assess..."
```

**Limitations:**
- Không có memory across turns (cleared at turn start)
- Không track planned vs completed steps
- "what remains" assessment để LLM tự infer

### 2.5 MemAct Compaction

Khi context overflow, agent hỏi LLM summarize thành JSON stencil với fields: `task_state`, `decisions`, `open_questions`, `files_touched`, `next_step`.

`next_step` là thứ gần nhất với explicit plan artifact, nhưng chỉ sống trong compaction summary text, không phải tracked data structure.

---

## 3. Gap Analysis Summary

| # | Gap | Evidence | Mức độ | Source |
|---|-----|----------|--------|--------|
| 1 | **Không có explicit planning phase** | LLM gọi tool trực tiếp, không decompose task | 🔴 Critical | Gap 1 |
| 2 | **Plan representation yếu** | `plan_summary_buf: [160]u8` bị truncate | 🔴 Critical | Evidence 1.1 |
| 3 | **Progress Checkpoint đơn giản** | Chỉ liệt kê tools, không có plan context | 🟡 High | Evidence 1.2 |
| 4 | **No cross-turn persistence** | `clearPlan()` mỗi turn | 🔴 Critical | Evidence 1.4 |
| 5 | **Plan watchdog thụ động** | Cap 2 retries, dễ give up | 🟡 Medium | Gap 1 |
| 6 | **Không có drift detection** | Không so sánh actual vs planned trajectory | 🟡 Medium | Gap 4 |
| 7 | **Tool selection không plan-aware** | `getRelevantDefinitions()` không filter theo step | 🟡 Medium | Gap 7 |
| 8 | **Weak loop recovery integration** | Advisory message không enforce plan | 🟢 Low | Gap 8 |

---

## 4. Proposed Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     Structured Planning System                          │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  User Input                                                             │
│       │                                                                 │
│       ▼                                                                 │
│  ┌──────────────────────┐    ┌──────────────────────┐                  │
│  │  Phase 1: Planning   │    │  Phase 2: Execution  │                  │
│  │  ┌────────────────┐  │    │  ┌────────────────┐  │                  │
│  │  │ Extract Plan   │  │    │  │ Execute Steps  │  │                  │
│  │  │ (JSON/Markdown)│  │    │  │ (dependency    │  │                  │
│  │  │                │  │    │  │  resolution)   │  │                  │
│  │  └────────────────┘  │    │  └────────────────┘  │                  │
│  │  ┌────────────────┐  │    │  ┌────────────────┐  │                  │
│  │  │ Validate DAG   │  │    │  │ Monitor Drift  │  │                  │
│  │  │ (no cycles)    │  │    │  │ (actual vs     │  │                  │
│  │  └────────────────┘  │    │  │  planned)      │  │                  │
│  └──────────────────────┘    │  └────────────────┘  │                  │
│           │                   └──────────┬───────────┘                  │
│           │                              │                              │
│           └──────────┬───────────────────┘                              │
│                      ▼                                                  │
│            ┌──────────────────┐                                        │
│            │  Plan Store (DAC)│                                        │
│            │  ~/.mini/plans/  │                                        │
│            └──────────────────┘                                        │
│                                                                         │
│  Enhanced Progress Checkpoint:                                          │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ [Plan Progress: Step 2/5 Completed]                             │   │
│  │ ✓ Step 1: Read config.yaml (completed, act 8)                   │   │
│  │ ✓ Step 2: Create migration script (completed, act 10)           │   │
│  │ → Step 3: Run migration (active, depends on step 2)             │   │
│  │   Preferred tool: bash                                          │   │
│  │                                                                  │   │
│  │ ⚠️ Drift detected: Expected 'bash', got 'file_write'            │   │
│  │    Please realign with planned step or update plan.             │   │
│  │                                                                  │   │
│  │ Next action: Execute Step 3 using 'bash' tool.                  │   │
│  │ Do not return explanatory text without tool execution.          │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 5. New Data Structures

```zig
// src/core/plan.zig

pub const StepStatus = enum {
    pending,
    active,
    completed,
    failed,
    skipped,
};

pub const PlanStep = struct {
    id: u64,
    description: []const u8,
    dependencies: []const u64,      // IDs of prerequisite steps
    status: StepStatus = .pending,
    tool_hint: ?[]const u8 = null,  // Preferred tool for this step
    estimated_acts: usize = 1,
    actual_acts: usize = 0,
    created_at: i64,
    completed_at: ?i64 = null,
};

pub const Plan = struct {
    id: u64,
    task_description: []const u8,
    steps: []PlanStep,
    created_at: i64,
    completed_at: ?i64 = null,
    parent_plan_id: ?u64 = null,
    request_hash: u64,              // For plan matching/restore
};

pub const PlanDrift = struct {
    step_id: u64,
    expected_tool: ?[]const u8,
    actual_tool: []const u8,
    drift_score: f64,               // 0.0 - 1.0
};
```

---

## 6. New Modules

| Module | Purpose | Complexity |
|--------|---------|------------|
| `src/core/plan.zig` | Plan data model, CRUD, serialization | Low |
| `src/core/plan_parser.zig` | Extract structured plans from LLM output (JSON/Markdown) | Medium |
| `src/core/plan_executor.zig` | Execute plan steps, manage state transitions | Medium |
| `src/core/plan_monitor.zig` | Verify execution vs plan, detect drift | Medium |
| `src/core/plan_store.zig` | Persist plans to `~/.mini/plans/` (DAC-based) | High |

---

## 7. AgentLoop Changes

### 7.1 Replace Plan Fields

**Current** (`src/core/agent.zig:270-279`):
```zig
plan_active: bool = false,
plan_summary_buf: [160]u8 = undefined,
plan_summary_len: usize = 0,
plan_procrastination_count: usize = 0,
plan_procrastination_cap: usize = 2,
```

**Proposed:**
```zig
/// Structured plan (replaces plan_active/plan_summary_buf)
current_plan: ?*Plan = null,
current_step_idx: usize = 0,
plan_drift_score: f64 = 0.0,
plan_verification_enabled: bool = true,

/// Plan execution metrics
plan_steps_completed: usize = 0,
plan_steps_total: usize = 0,
plan_estimated_acts: usize = 0,
plan_actual_acts: usize = 0,

/// Plan store for cross-turn persistence
plan_store: ?*plan_store.PlanStore = null,
```

### 7.2 Enhanced Progress Checkpoint

**Current format** (`src/core/agent.zig:1113-1127`):
```
[Progress Checkpoint]
The previous act (1) completed with the following progress:
Tool: read

Before proceeding, please assess: what has been accomplished, what remains, and whether you should continue or conclude.
```

**Proposed format:**
```
[Plan Progress: Step 2/5 Completed]
✓ Step 1: Read config.yaml (completed, act 8)
✓ Step 2: Create migration script (completed, act 10)
→ Step 3: Run migration (active, depends on step 2)
  Preferred tool: bash
  
⚠️ Drift detected: Expected 'bash', got 'file_write'
   Please realign with planned step or update plan.

Next action: Execute Step 3 using 'bash' tool.
Do not return explanatory text without tool execution.
```

### 7.3 When to Trigger Planning

```zig
fn shouldTriggerPlanning(user_text: []const u8) bool {
    // Trigger planning for:
    // 1. Explicit plan requests: "only plan", "lên kế hoạch"
    // 2. Complex tasks: multi-step operations detected
    // 3. Config override: config.enable_structured_planning = true
    // 4. Heuristic: task description > 50 chars with action verbs
}
```

---

## 8. Plan Parser (`plan_parser.zig`)

Extract structured plans from LLM output:

```zig
pub fn extractStructuredPlan(text: []const u8, alloc: Allocator) !?Plan {
    // 1. Try JSON extraction first
    // ```json
    // {
    //   "task": "...",
    //   "steps": [
    //     {"id": 1, "description": "...", "dependencies": [], "tool_hint": "file_read"}
    //   ]
    // }
    // ```
    
    // 2. Fallback: Markdown extraction
    // ## Plan
    // 1. Step one (file_read)
    // 2. Step two (depends on 1, file_edit)
}
```

---

## 9. Plan Executor (`plan_executor.zig`)

```zig
pub fn executePlanStep(self: *AgentLoop, step_idx: usize) !void {
    const step = &self.current_plan.?.steps[step_idx];
    
    // Check dependencies satisfied
    for (step.dependencies) |dep_id| {
        const dep = self.findStepById(dep_id) orelse continue;
        if (dep.status != .completed) {
            return error.DependenciesNotSatisfied;
        }
    }
    
    // Set step active
    step.status = .active;
    
    // Inject step-specific guidance
    const guidance = try std.fmt.allocPrint(
        self.alloc,
        "[Plan Step {d}/{d}]: {s}\nPreferred tool: {s}\nProceed to execution.",
        .{ step_idx + 1, self.current_plan.?.steps.len, 
           step.description, step.tool_hint orelse "any" },
    );
    try self.history.addUser(guidance);
    defer self.alloc.free(guidance);
}
```

---

## 10. Plan Monitor (`plan_monitor.zig`)

```zig
pub fn checkPlanDrift(self: *AgentLoop, executed_tool: []const u8) ?PlanDrift {
    const current_step = self.current_plan.?.steps[self.current_step_idx] orelse return null;
    
    if (current_step.tool_hint) |hint| {
        if (!std.mem.eql(u8, executed_tool, hint)) {
            return PlanDrift{
                .step_id = current_step.id,
                .expected_tool = hint,
                .actual_tool = executed_tool,
                .drift_score = 0.8,
            };
        }
    }
    return null;
}

fn injectDriftCorrection(self: *AgentLoop, drift: PlanDrift) void {
    const msg = std.fmt.allocPrint(
        self.alloc,
        "[Plan Drift Detected]: Expected tool '{s}' for current step, but executed '{s}'. " ++
        "Please realign with the planned step or update the plan if deviation is intentional.",
        .{ drift.expected_tool orelse "?", drift.actual_tool },
    );
    try self.history.addUser(msg);
    defer self.alloc.free(msg);
}
```

---

## 11. Cross-Turn Persistence (`plan_store.zig`)

```zig
pub const PlanStore = struct {
    cas: *cas_mod.CAS,
    plans_dir: []const u8,  // ~/.mini/plans/
    
    pub fn save(self: *PlanStore, plan: *const Plan) !void {
        const json = try planToJson(plan, self.alloc);
        const digest = self.cas.store(json);
        try self.writeMetadata(plan.request_hash, digest);
    }
    
    pub fn restore(self: *PlanStore, request_hash: u64) !?*Plan {
        // Find matching plan by hash
        // Restore from CAS + metadata
    }
};
```

**Turn Start:**
```zig
pub fn executeTurnWorker(self: *AgentLoop, user_text: []const u8, ...) !void {
    // Try to restore existing plan
    const req_hash = std.hash.Fnv1a_64.hash(user_text);
    if (self.plan_store) |ps| {
        if (try ps.restore(req_hash)) |restored_plan| {
            self.current_plan = restored_plan;
            self.current_step_idx = self.findActiveStepIndex();
            try self.history.addUser("[Plan Restored]: Resuming previous plan with {d} remaining steps.", .{self.remainingSteps()});
        }
    }
}
```

---

## 12. Plan-Driven Tool Selection

Modify `getRelevantDefinitions()` trong `src/tooling/registry.zig`:

```zig
pub fn getRelevantDefinitions(alloc: Allocator, user_text: []const u8) []const ToolDefinition {
    // ... existing logic ...
    
    // If plan is active, filter tools based on current step
    if (active_agent.current_plan) |plan| {
        const current_step = plan.steps[active_agent.current_step_idx] orelse return all_defs;
        
        // Keep exploration tools always available
        var filtered = std.ArrayListUnmanaged(ToolDefinition).empty;
        for (all_defs) |td| {
            if (isExplorationTool(td.name)) continue;  // grep, glob, file_read
            if (std.mem.eql(u8, td.name, current_step.tool_hint orelse "")) {
                filtered.append(alloc, td) catch {};
            }
        }
        return filtered.items;
    }
    
    return all_defs;
}
```

---

## 13. Implementation Phases

| Phase | Nội dung | Files | Thời gian |
|-------|----------|-------|-----------|
| **1** | Core data model | `plan.zig` | 1-2 ngày |
| **2** | Plan parser (JSON/Markdown) | `plan_parser.zig` | 2-3 ngày |
| **3** | Plan executor + dependency resolution | `plan_executor.zig` | 2-3 ngày |
| **4** | Drift detection | `plan_monitor.zig` | 1-2 ngày |
| **5** | Cross-turn persistence (DAC) | `plan_store.zig` | 2-3 ngày |
| **6** | Integration với AgentLoop | `agent.zig`, `registry.zig` | 2-3 ngày |
| **7** | Testing + benchmarking | `testcases/test_plan_*.zig` | 2-3 ngày |

**Tổng: ~12-19 ngày**

---

## 14. Configuration

```zig
pub const Config = struct {
    // ... existing fields ...
    
    /// Enable structured planning system (RFC-019)
    enable_structured_planning: bool = false,
    
    /// Minimum task complexity to trigger planning (char count)
    planning_min_task_length: usize = 50,
    
    /// Enable drift detection
    plan_drift_detection: bool = true,
    
    /// Max plan steps (prevent infinite planning)
    plan_max_steps: usize = 20,
    
    /// Plan persistence directory
    plans_dir: ?[]const u8 = null,  // defaults to ~/.mini/plans/
    
    /// Enhanced progress checkpoint format
    enhanced_progress_checkpoint: bool = true,
};
```

---

## 15. Backward Compatibility

- ✅ Existing `plan_active`/`plan_summary_buf` fields remain as fallback
- ✅ `detectPlanInText()` still works for simple text-based plans
- ✅ New structured planning is **opt-in** via `config.enable_structured_planning = true`
- ✅ Existing watchdog behavior preserved for non-structured plans
- ✅ Enhanced progress checkpoint can be toggled via config

---

## 16. Files Modified

| File | Changes |
|------|---------|
| `src/core/agent.zig` | Replace plan fields, integrate executor/monitor, enhanced progress checkpoint |
| `src/tooling/registry.zig` | Plan-aware tool filtering in `getRelevantDefinitions()` |
| `src/core/config.zig` | Add planning-related config fields |
| `src/core/protocol.zig` | Add `PlanBlock` content type (optional) |

## Files Created

| File | Purpose |
|------|---------|
| `src/core/plan.zig` | Plan data model, CRUD operations |
| `src/core/plan_parser.zig` | Extract structured plans from LLM output |
| `src/core/plan_executor.zig` | Step execution with dependency resolution |
| `src/core/plan_monitor.zig` | Drift detection and corrections |
| `src/core/plan_store.zig` | Persistent plan storage (DAC-based) |
| `testcases/test_plan_parser.zig` | Unit tests for plan parsing |
| `testcases/test_plan_executor.zig` | Unit tests for plan execution |
| `testcases/test_plan_drift.zig` | Unit tests for drift detection |

---

## 17. Example Plan JSON

```json
{
  "task": "Implement pagination in UserList component",
  "steps": [
    {
      "id": 1,
      "description": "Read UserList.tsx to understand current implementation",
      "dependencies": [],
      "tool_hint": "file_read",
      "estimated_acts": 1
    },
    {
      "id": 2,
      "description": "Add pagination state and handlers",
      "dependencies": [1],
      "tool_hint": "file_edit",
      "estimated_acts": 2
    },
    {
      "id": 3,
      "description": "Update API call to support page param",
      "dependencies": [1],
      "tool_hint": "file_edit",
      "estimated_acts": 1
    },
    {
      "id": 4,
      "description": "Run tests to verify pagination works",
      "dependencies": [2, 3],
      "tool_hint": "bash",
      "estimated_acts": 1
    }
  ]
}
```

---

## 18. Migration Path

1. **Phase 1-2**: Implement core data model + parser
2. **Phase 3-4**: Add executor + drift detection
3. **Phase 5-6**: Add persistence + integration
4. **Phase 7**: Testing + documentation
5. **Post-launch**: Deprecate legacy `plan_active` fields in next major version

---

## 19. Success Metrics

```zig
pub const PlanMetrics = struct {
    plans_created: usize,
    plans_completed: usize,
    plans_interrupted: usize,
    avg_steps_per_plan: f64,
    avg_drift_score: f64,
    plans_restored_from_storage: usize,
    plan_execution_accuracy: f64,  // % of steps executed as planned
};
```

---

## 20. References

- [Planning Capability Gap Analysis](../docs/planning_capability_gap_analysis.md)
- [RFC-010: Procedural Graph](./rfc_010_procedural_graph_proposal.md)
- [RFC-013: Act Queue System](./rfc_013_act_queue_system_proposal.md)
- [RFC-002: Event Sourcing & CAS](./rfc_002_long_horizon_event_sourcing_proposal.md)
- [RFC-015: Three Thread Runtime](./rfc_015_three_thread_runtime_and_watchdog_proposal.md)

---

## Appendix A: Comparison — Before vs After

### Before (Current)

```
[Progress Checkpoint]
The previous act (1) completed with the following progress:
Tool: read


Before proceeding, please assess: what has been accomplished, what remains, and whether you should continue or conclude.
```

### After (Proposed)

```
[Plan Progress: Step 2/5 Completed]
✓ Step 1: Read config.yaml (completed, act 8)
✓ Step 2: Create migration script (completed, act 10)
→ Step 3: Run migration (active, depends on step 2)
  Preferred tool: bash
  
⚠️ Drift detected: Expected 'bash', got 'file_write'
   Please realign with planned step or update plan.

Next action: Execute Step 3 using 'bash' tool.
Do not return explanatory text without tool execution.
```

---

## Appendix B: Key Design Decisions

1. **When to trigger planning**: Complex tasks only (threshold-based), không phải all tasks
2. **Plan format**: Hybrid — JSON preferred, Markdown fallback
3. **Plan ownership**: Model-generated (LLM outputs structured plan)
4. **Plan enforcement strength**: Configurable — soft advisory (default) hoặc hard constraints
5. **Parallel vs sequential**: Sequential first, parallel sub-tasks trong Phase 3+
6. **Rollback on failure**: Retry → Re-plan → Abort (configurable)

---

## Appendix C: Comparison with Claude Code Superpowers

### C.1 Feature Gap Analysis

| Feature | mini-agent | Claude Code | Gap Level |
|---------|-----------|-------------|-----------|
| **Explicit Planning Phase** | ❌ Không có | ✅ Có | 🔴 Critical |
| **Structured Plan (DAG)** | ❌ 160-byte text | ✅ JSON with dependencies | 🔴 Critical |
| **Cross-Turn Persistence** | ❌ `clearPlan()` mỗi turn | ✅ Plans survive sessions | 🔴 Critical |
| **Dependency Resolution** | ❌ Không có | ✅ Step 2 waits for Step 1 | 🔴 Critical |
| **Drift Detection** | ❌ Không có | ✅ Trajectory validation | 🟡 High |
| **Rich Progress Tracking** | ⚠️ Simple tool list | ✅ "Step 2/5 (40%)" | 🟡 High |
| **Auto-Recovery** | ⚠️ Basic retry | ✅ Multi-strategy fallback | 🟡 Medium |

### C.2 What mini-agent Does Better

| Aspect | mini-agent Advantage |
|--------|---------------------|
| **Procedural Graph** | 3D domain classification, orbit detection, condition-based edges |
| **Self-Learning** | Auto-populate transitions (N≥3), adaptive guidance |
| **Event Sourcing** | JSONL audit trail, CAS-based rollback |
| **Watchdog** | LLM consultation for WAIT/KILL decision |
| **Token Estimation** | CJK-aware heuristic estimator |

### C.3 Different Approaches: mini-agent vs Claude Code

#### Approach 1: Planning Strategy

**mini-agent (Reactive):**
```
User Input → LLM calls tool → Execute → LLM calls tool → ...
```
- No explicit planning phase
- Plan detected post-hoc via string matching
- Reactive recovery when loops detected

**Claude Code (Proactive):**
```
User Input → [Planning Phase] → Structured JSON plan → Execute steps → Monitor → Adjust
```
- Explicit planning phase before any tool call
- Plan includes dependencies, estimated acts, tool hints
- Proactive monitoring and adjustment

**Key Difference:** mini-agent reacts to situations, Claude plans ahead.

---

#### Approach 2: Progress Tracking

**mini-agent (Tool-Centric):**
```
[Progress Checkpoint]
The previous act (1) completed with:
Tool: read
Tool: bash

Before proceeding, please assess: what has been accomplished...
```
- Focus on **what tools were used**
- No step context
- Asks LLM to self-assess

**Claude Code (Step-Centric):**
```
[Progress: Step 2/5 Completed (40%)]
✓ Step 1: Read config.yaml (act 8)
✓ Step 2: Create migration script (act 10)
→ Step 3: Run migration (active, depends on step 2)
  Preferred tool: bash

Next action: Execute Step 3 using 'bash' tool.
```
- Focus on **which step is active**
- Clear dependency tracking
- Direct directive for next action

**Key Difference:** mini-agent tracks tools, Claude tracks steps.

---

#### Approach 3: Guidance Delivery

**mini-agent (Advisory):**
```
[Procedural Advisory (Optional Suggestions)]
Current Action: `bash`
- `bash` → `grep` (TRIGGERS)
  - Condition: compiler error or test failure
⚠️ Advisory Note: These are heuristic suggestions... 
   You are NOT required to follow them.
```
- Optional, can be ignored
- Based on historical patterns (PGraph)
- Advisory tone ("not required")

**Claude Code (Directive):**
```
[Plan Enforcement]
Current step: Step 3 - Run migration
Expected tool: bash
Detected deviation: Using file_write instead
Action required: Execute bash command now.
```
- Binding when plan is active
- Based on committed plan
- Directive tone ("required")

**Key Difference:** mini-agent suggests, Claude enforces.

---

#### Approach 4: Error Recovery

**mini-agent (Retry-Based):**
```
Act 3 failed. Rolling back (attempt 1/3)...
Act 3 failed. Rolling back (attempt 2/3)...
Act 3 failed after 3 attempts. Terminating.
```
- Fixed retry count (3 attempts)
- Rollback to previous state
- Terminate on exhaustion

**Claude Code (Strategy-Based):**
```
Step 3 failed. Trying alternative approach...
Strategy 1: Retry with different parameters
Strategy 2: Break into sub-steps
Strategy 3: Ask for user clarification
```
- Multiple fallback strategies
- Adaptive based on error type
- Can escalate to user

**Key Difference:** mini-agent retries same approach, Claude tries different strategies.

---

#### Approach 5: Memory Retrieval

**mini-agent (Keyword-Based):**
```
MemoryEntry {
  keywords: ["Zig", "build"],
  content: "Project uses Zig 0.16",
  confidence: 0.9
}
```
- ASCII case-insensitive keyword matching
- Manual keyword specification
- Simple string matching

**Claude Code (Semantic-Based):**
```
Context: "The project uses a modern build system"
Retrieved: "Build configuration uses Bun with Zig bindings"
Relevance score: 0.87
```
- Semantic similarity search
- Automatic relevance scoring
- Context-aware retrieval

**Key Difference:** mini-agent matches keywords, Claude understands meaning.

---

#### Approach 6: Concurrency Model

**mini-agent (Sequential):**
```
Act 1 → Act 2 → Act 3 → ... (one at a time)
```
- Single-threaded act execution
- No parallel tool calls
- Simple queue model

**Claude Code (Parallel + Sequential):**
```
Act 1 (sequential)
  ├── Act 2a (parallel)
  ├── Act 2b (parallel)
  └── Act 2c (parallel)
Act 3 (waits for 2a, 2b, 2c)
```
- Dependency-aware parallelism
- Fan-out/fan-in patterns
- Sophisticated scheduling

**Key Difference:** mini-agent is sequential, Claude supports parallel execution.

---

#### Approach 7: Context Management

**mini-agent (MemAct Compaction):**
```
Context overflow detected.
Asking LLM to summarize into stencil:
{
  task_state: "...",
  decisions: [...],
  next_step: "..."
}
```
- Emergency compaction on overflow
- LLM-generated summary
- Lossy compression

**Claude Code (Hierarchical Context):**
```
Short-term: Current task context (detailed)
Medium-term: Recent conversations (summarized)
Long-term: Project memory (semantic search)
```
- Multi-tier context storage
- Automatic tier management
- Selective recall

**Key Difference:** mini-agent compresses everything, Claude maintains hierarchy.

---

1. **PGraph + Planning**: Store plan sequences as reusable patterns
2. **MemAct + Plan Persistence**: Store plans as semantic memories
3. **Watchdog + Plan Monitoring**: Detect drift, trigger re-plan

### C.4 Evidence from Execution Logs

**Progress Checkpoint (act 3):**
```
[Progress Checkpoint]
The previous act (3) completed with the following progress:
Tool: read
Tool: bash

Before proceeding, please assess: what has been accomplished...
```

**Procedural Advisory (act 10):**
```
[Procedural Advisory (Optional Suggestions)]
Current Action: `bash`
- `bash` → `grep` (TRIGGERS)
  - Condition: compiler error or test failure
⚠️ Advisory Note: These are heuristic suggestions...
```

**Plan Watchdog (truncated):**
```
[Plan Watchdog Directive]: You formulated an active implementation plan 
('Step 1: Read config.yaml (completed, act 8)
✓ Step 2: Create migration script (completed, act 10)
→ Step 3: Run migr')
```

---

## 21. Flow Comparison: Current vs Proposed

### 21.1 Overall Flow Diagram

#### Current Flow (Before RFC-019)

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        Current Agent Loop                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  User Input                                                             │
│       │                                                                 │
│       ▼                                                                 │
│  ┌──────────────────┐                                                   │
│  │ executeStep()    │                                                   │
│  │  • Sanitize history                                                      │
│  │  • Inject PGraph advisory (optional)                                 │
│  │  • Inject Progress Checkpoint (simple)                               │
│  │  • Send to LLM backend                                                 │
│  └────────┬─────────┘                                                   │
│           │                                                             │
│           ▼                                                             │
│  ┌──────────────────┐                                                   │
│  │ LLM Response     │                                                   │
│  │  • text/thinking │                                                   │
│  │  • tool_use      │                                                   │
│  │  • stop_reason   │                                                   │
│  └────────┬─────────┘                                                   │
│           │                                                             │
│           ▼                                                             │
│  ┌──────────────────┐                                                   │
│  │ Decision Point   │                                                   │
│  │                  │                                                   │
│  │ • has_tool_use?  │──YES──→ executeTools()                           │
│  │ • plan_active?   │──YES──→ inject watchdog directive                 │
│  │ • loop detect?   │──YES──→ inject checkpoint                         │
│  │ • max_tokens?    │──YES──→ request continue                          │
│  │ • end_turn?      │──YES──→ exit_loop                                 │
│  └──────────────────┘                                                   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

#### Proposed Flow (After RFC-019)

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     Proposed Agent Loop (RFC-019)                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  User Input                                                             │
│       │                                                                 │
│       ▼                                                                 │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ Phase 0: Turn Initialization                                     │   │
│  │  • clearPlan() (existing)                                        │   │
│  │  • Try restore plan from store (NEW)                             │   │
│  │  • Check if planning needed (NEW)                                │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│       │                                                                 │
│       ▼                                                                 │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ Phase 1: Planning (NEW - conditional)                            │   │
│  │  • Detect complex task (length > 50, action verbs)               │   │
│  │  • Inject planning prompt → LLM outputs structured plan          │   │
│  │  • Parse JSON/Markdown plan                                      │   │
│  │  • Validate DAG (no cycles)                                      │   │
│  │  • Store in current_plan                                         │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│       │                                                                 │
│       ▼                                                                 │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ executeStep()                                                    │   │
│  │  • Sanitize history                                              │   │
│  │  • Inject PGraph advisory (existing, optional)                   │   │
│  │  • Inject Enhanced Progress Checkpoint (NEW)                     │   │
│  │  • Inject step-specific guidance (NEW)                           │   │
│  │  • Send to LLM backend                                           │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│       │                                                                 │
│       ▼                                                                 │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ LLM Response Processing                                          │   │
│  │  • Parse tool calls                                              │   │
│  │  • Check drift (NEW)                                             │   │
│  │  • Update plan step status (NEW)                                 │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│       │                                                                 │
│       ▼                                                                 │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ Decision Point (Enhanced)                                        │   │
│  │                                                                  │   │
│  │ • has_tool_use?     → executeTools() + checkDrift() (NEW)       │   │
│  │ • plan_active?      → enforce step execution (NEW)               │   │
│  │ • loop detect?      → inject checkpoint + re-plan (NEW)          │   │
│  │ • max_tokens?       → request continue                           │   │
│  │ • end_turn?         → check plan completion (NEW) → exit         │   │
│  │ • drift detected?   → inject correction (NEW)                    │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│       │                                                                 │
│       ▼                                                                 │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ Turn Completion (NEW)                                            │   │
│  │  • Save incomplete plan to store                                 │   │
│  │  • Log plan metrics to journal                                   │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

### 21.2 Case Classification: LLM-First Approach

**Principle:** Thay vì hard-code rules để phân loại case, hệ thống hỏi LLM để tự quyết định.

#### Why Not Hard-Code?

Current RFC approach (rejected):
```zig
// ❌ BAD: Hard-coded thresholds
if (user_text.len < 50) return .simple;
if (hasActionVerbs(user_text)) return .complex;
```

Problems:
- Misses edge cases (short but complex: "fix auth bug")
- False positives (long but simple: "read this 500-line config file")
- Language dependent (Vietnamese vs English verbs)
- Doesn't consider context (conversation history, recent actions)

#### LLM-First Decision Making

**Approach:** Ask LLM to self-assess complexity and planning need.

```zig
// ✅ GOOD: LLM-driven classification
fn shouldTriggerPlanning(self: *AgentLoop, user_text: []const u8) bool {
    // Check if plan already exists (from previous acts)
    if (self.current_plan != null) return false;
    
    // Check if explicit plan requested
    if (isPlanOnlyRequest(user_text)) return true;
    
    // Ask LLM to assess during first turn
    // System prompt includes: 
    // "If the task requires multiple steps, output a structured plan first.
    //  If it's a simple single-action task, proceed directly to tools."
}
```

**System Prompt Enhancement:**
```
You are mini-agent. For complex tasks, follow this workflow:

1. ANALYZE: Is this task simple (single action) or complex (multi-step)?
   - Simple: "read file.txt", "what's the date?"
   - Complex: "implement feature X", "refactor module Y"

2. IF Complex:
   a. Output a structured plan in JSON format BEFORE any tool calls
   b. Include: task description, steps with dependencies, tool hints
   c. Wait for system validation
   
3. IF Simple:
   a. Proceed directly to tool execution
   b. No planning overhead

4. DURING Execution:
   - Track progress against your plan
   - Adjust plan if context changes
   - Report drift if deviating from plan
```

#### When Does LLM Decide?

| Scenario | Decision Maker | Rationale |
|----------|---------------|-----------|
| First turn, new task | **LLM** (via system prompt) | LLM understands task complexity best |
| Continuing interrupted task | **System** (restore from store) | Plan already exists, just resume |
| Explicit "only plan" request | **System** (keyword detection) | User explicitly wants planning |
| Task too simple (1 tool call) | **LLM** (self-corrects) | LLM can skip planning if obvious |

---

### 21.3 Adaptive Guidance (No Fixed Templates)

#### Current Approach (Rejected)
```
[Plan Progress: Step 2/5 Completed]  // fixed format
✓ Step 1: ... (completed, act 8)     // fixed format
→ Step 2: ... (active)               // fixed format
```

#### LLM-Adaptive Approach (Proposed)
```zig
fn generateProgressMessage(self: *AgentLoop) []const u8 {
    // Ask LLM to generate context-aware message
    // Based on: current step, recent actions, drift status, errors
    
    const context = BuildContext(self);
    return self.llm.GenerateProgressMessage(context);
}
```

**Example outputs (LLM-generated, not templated):**

*Normal progress:*
```
Step 2/5 in progress: Adding pagination state to UserList.tsx
Previous: Read component structure (act 8)
Next: Update API integration (act 10)
```

*Drift detected:*
```
⚠️ Deviation from plan detected.
Planned: Use bash to run tests
Actual: Used file_edit 3 times
Suggestion: Execute the test command now to verify changes.
```

*Stuck/looping:*
```
You've executed read → bash → read → bash without progress.
Consider: 
1. Summarizing findings so far
2. Deciding on next concrete action
3. Or concluding if task is complete
```

---

### 21.4 Soft Enforcement (Not Hard Constraints)

#### Current Approach (Rejected)
```
"You MUST execute Step 1 now!"  //硬 constraint
"Do not return explanatory text"  // hard rule
```

#### LLM-Respectful Approach (Proposed)
```
"[Plan Guidance] Current step: Read config.yaml. 
Consider using file_read tool to proceed.
Your plan emphasizes understanding configuration before implementation."
```

**Key Differences:**

| Aspect | Hard Enforcement (Rejected) | Soft Guidance (Proposed) |
|--------|---------------------------|-------------------------|
| Tone | Command ("MUST") | Suggestion ("Consider") |
| Flexibility | None | LLM can override with rationale |
| Trust | Low (assumes LLM will disobey) | High (trusts LLM reasoning) |
| User experience | Aggressive | Collaborative |

---

### 21.5 Context-Aware Case Detection

Instead of classifying by input alone, consider full context:

```zig
pub const CaseContext = struct {
    user_text: []const u8,
    conversation_history: []const proto.Message,
    recent_actions: []const []const u8,
    current_plan: ?*Plan,
    last_error: ?[]const u8,
    act_count: usize,
    token_usage: usize,
};

fn classifyCase(ctx: *CaseContext) CaseType {
    // 1. Check if plan exists (from previous acts)
    if (ctx.current_plan != null) {
        // Resume existing plan
        return .plan_continuation;
    }
    
    // 2. Check for errors requiring recovery
    if (ctx.last_error != null) {
        return .error_recovery;
    }
    
    // 3. Check for looping patterns
    if (detectLoop(ctx.recent_actions)) {
        return .loop_detection;
    }
    
    // 4. Ask LLM to assess complexity
    // (via system prompt, not code rules)
    return .unknown;  // LLM decides in next turn
}
```

**Examples:**

| Context | Detected Case | System Response |
|---------|--------------|-----------------|
| Short text, no history | Simple | Direct execution |
| Long text, action verbs | Complex | Request structured plan |
| Same file read 5x | Loop detected | Inject recap + suggest new approach |
| Compiler error | Error recovery | Suggest debug steps |
| Plan exists, step 2 active | Plan continuation | Show progress, await next tool |

---

## 21.2 Case-by-Case Flow Analysis

#### Case 1: Simple Task (No Planning Needed)

**Current Flow:**
```
User: "read file.txt"
  → executeStep()
  → LLM returns tool_call: file_read("file.txt")
  → executeTools()
  → exit_loop
```

**Proposed Flow (after RFC-019):**
```
User: "read file.txt"
  → Turn Init: no plan to restore, skip planning phase
  → executeStep():
      • PGraph advisory: null (no previous actions)
      • Progress Checkpoint: null (act 1)
      • Send to LLM
  → LLM returns tool_call: file_read("file.txt")
  → executeTools()
  → checkDrift(): skip (no active plan)
  → exit_loop
```

**Change:** No change for simple tasks — backward compatible.

---

#### Case 2: Complex Task with Plan Detection

**Current Flow:**
```
User: "Implement pagination in UserList component"
  → executeStep()
  → LLM returns text: "plan: 1. Read UserList.tsx, 2. Add state..."
  → detectPlanInText() → setPlan("plan: 1. Read...")
  → LLM returns tool_call: file_read("UserList.tsx")
  → executeTools()
  → Plan cleared on mutating tool
  → ... (continue reactively)
```

**Proposed Flow (after RFC-019):**
```
User: "Implement pagination in UserList component"
  → Turn Init:
      • Task length > 50 chars → trigger planning
      • Inject: "Output a structured JSON plan with steps and dependencies"
  → executeStep() (Planning Phase)
      • LLM returns:
        ```json
        {
          "task": "Implement pagination...",
          "steps": [
            {"id": 1, "description": "Read UserList.tsx", "tool_hint": "file_read"},
            {"id": 2, "description": "Add pagination state", "tool_hint": "file_edit"}
          ]
        }
        ```
      • parsePlan() → create Plan object
      • validateDAG() → success
      • Store in current_plan
  → executeStep() (Execution Phase)
      • Progress Checkpoint (enhanced):
        ```
        [Plan Progress: Step 1/2 Active]
        → Step 1: Read UserList.tsx (active)
          Preferred tool: file_read
        ```
      • LLM returns tool_call: file_read("UserList.tsx")
      • executeTools()
      • completeStep(1) → step status = .completed
      • current_step_idx = 2
  → executeStep()
      • Progress Checkpoint:
        ```
        [Plan Progress: Step 2/2 Active]
        ✓ Step 1: Read UserList.tsx (completed, act 2)
        → Step 2: Add pagination state (active, depends on step 1)
          Preferred tool: file_edit
        ```
      • LLM returns tool_call: file_edit(...)
      • executeTools()
      • completeStep(2) → step status = .completed
      • plan_steps_completed = 2 = plan_steps_total
  → exit_loop (plan completed)
```

**Key Changes:**
- Explicit planning phase before execution
- Structured plan with dependencies
- Step-by-step progress tracking
- Automatic plan completion detection

---

#### Case 3: Action Loop Detection

**Current Flow:**
```
User: "Fix the bug in auth module"
  → ... (multiple acts)
  → checkActionLoop() → detected identical_repeat
  → trip_msg = "[Action Loop Checkpoint & Trajectory Recap]..."
  → history.addUser(trip_msg)
  → loop_plan_retries += 1
  → if loop_plan_retries >= 2:
        trip_msg = "[CodeAct System Intervention]..."
        history.addUser(trip_msg)
        exit_loop
```

**Proposed Flow (after RFC-019):**
```
User: "Fix the bug in auth module"
  → ... (plan created in Planning Phase)
  → executeStep()
      • PGraph advisory detects orbit
      • LLM continues executing
  → checkActionLoop() → detected orbit_cycle
  → Drift Detection:
      • Current step: Step 3 "Debug auth issue"
      • Expected tool: bash (to run tests)
      • Actual tool: read (repeatedly reading same file)
      • drift_score = 0.8
  → injectDriftCorrection():
      ```
      [Plan Drift Detected]
      Step: Debug auth issue
      Expected: bash (run test)
      Actual: read (re-reading same file)
      Action: Execute bash command now to verify fix
      ```
  → If drift persists:
      • Suggest re-plan: "Current approach not working. Re-plan Step 3."
      • Clear current_plan, trigger Planning Phase again
  → If resolved:
      • Continue with corrected execution
```

**Key Changes:**
- Drift detection during loop
- Specific corrective actions (not generic advisory)
- Automatic re-plan trigger on excessive drift

---

#### Case 4: Plan Watchdog (Procrastination)

**Current Flow:**
```
User: "Implement feature X"
  → LLM returns text with plan markers
  → setPlan("plan: 1. Read config, 2. Write code...")
  → LLM returns text only (no tool call)
  → plan_watchdog_retries += 1
  → if plan_watchdog_retries < 2:
        inject directive: "execute Step 1 now"
  → else:
        clearPlan()
        exit_loop
```

**Proposed Flow (after RFC-019):**
```
User: "Implement feature X"
  → Planning Phase creates structured plan
  → LLM returns text explaining approach
  → Plan Monitor checks:
      • current_step = Step 1 (active)
      • Expected action: tool call
      • Actual action: text only
  → injectStepDirective():
      ```
      [Plan Enforcement]
      Step 1: Read config.yaml
      Status: Active (waiting for execution)
      Required: Call file_read tool NOW
      Do not return explanatory text without tool execution.
      ```
  → If still no tool call after 2 retries:
      • Escalate: "Re-plan required - unable to execute Step 1"
      • Trigger re-plan with different approach
  → If tool called:
      • Execute tool
      • Mark step completed
      • Advance to next step
```

**Key Changes:**
- Step-specific enforcement (not generic "execute Step 1")
- Escalation to re-plan instead of just clearing plan
- Clearer directive format

---

#### Case 5: Context Overflow (MemAct Compaction)

**Current Flow:**
```
User: "Large refactoring task..."
  → ... (many acts)
  → LLM returns context_length_exceeded error
  → compactContext():
      • Ask LLM to summarize into stencil:
        {
          task_state: "...",
          decisions: [...],
          next_step: "..."
        }
      • Replace history with summary
  → Retry with compacted context
```

**Proposed Flow (after RFC-019):**
```
User: "Large refactoring task..."
  → Planning Phase: create plan with estimated_acts per step
  → ... (execution)
  → LLM returns context_length_exceeded error
  → compactContext():
      • Ask LLM to summarize into stencil:
        {
          task_state: "...",
          decisions: [...],
          next_step: "Step 3: Update API calls",
          plan_remaining: [
            {"id": 3, "description": "Update API calls"},
            {"id": 4, "description": "Run tests"}
          ]
        }
      • Restore plan state from stencil
      • Replace history with summary + plan context
  → Retry with compacted context + restored plan
  → Continue from Step 3
```

**Key Changes:**
- Plan state preserved during compaction
- Resume from specific step (not start over)
- Structured plan in compaction summary

---

#### Case 6: Max Tokens Truncation

**Current Flow:**
```
User: "Complex task..."
  → LLM returns max_tokens stop_reason
  → closeOrphanedToolUses()
  → inject: "continue EXACTLY from where it stopped"
  → Retry
```

**Proposed Flow (after RFC-019):**
```
User: "Complex task..."
  → LLM returns max_tokens stop_reason
  → Check current step status
  → If step was active when truncated:
      • Note: "Step N was in progress when truncated"
      • inject: "Continue Step N from where it stopped"
  → If step completed before truncation:
      • Note: "Step N completed, proceed to Step N+1"
      • inject: "Execute Step N+1: {description}"
  → closeOrphanedToolUses()
  → Retry
```

**Key Changes:**
- Step-aware continuation (not generic "continue")
- Clear indication of which step to resume

---

#### Case 7: Rate Limit Retry

**Current Flow:**
```
User: "Task..."
  → LLM returns 429 rate limit
  → rate_limit_retries += 1
  → waitWithInplaceCountdown(backoff_s, attempt, MAX_RATE_LIMIT_RETRIES)
  → Retry
```

**Proposed Flow (after RFC-019):**
```
User: "Task..."
  → LLM returns 429 rate limit
  → rate_limit_retries += 1
  → Save plan state to store (crash-safe)
  → waitWithInplaceCountdown(...)
  → Retry
  → On success: restore plan state
```

**Key Changes:**
- Plan persistence before retry (crash-safe)
- State restoration after retry

---

### 21.3 Backward Compatibility Matrix

| Current Feature | RFC-019 Status | Behavior Change |
|----------------|----------------|-----------------|
| Plan detection (heuristic) | ✅ Kept as fallback | No change if structured plan not detected |
| Progress checkpoint | ✅ Enhanced | New format when plan active, old format otherwise |
| PGraph advisory | ✅ Unchanged | Still optional, still heuristic |
| Action loop detection | ✅ Enhanced | Added drift detection on top |
| Watchdog timeout | ✅ Unchanged | LLM consultation still works |
| MemAct compaction | ✅ Enhanced | Plan state preserved in stencil |
| Rate limit retry | ✅ Unchanged | Added plan save/restore |
| Max tokens handling | ✅ Enhanced | Step-aware continuation |

---

### 21.4 Configuration Toggle

All new features are opt-in via config:

```zig
pub const Config = struct {
    // ... existing fields ...
    
    /// Enable structured planning system (RFC-019)
    enable_structured_planning: bool = false,
    
    /// Minimum task length to trigger planning (chars)
    planning_min_task_length: usize = 50,
    
    /// Enable drift detection
    plan_drift_detection: bool = true,
    
    /// Max plan steps (prevent infinite planning)
    plan_max_steps: usize = 20,
    
    /// Use enhanced progress checkpoint format
    enhanced_progress_checkpoint: bool = true,
};
```

**Default behavior (enable_structured_planning = false):**
- All existing flows remain unchanged
- New features only activate when explicitly enabled

---

## Appendix D: Implementation Roadmap Summary

| Phase | Timeline | Key Deliverables |
|-------|----------|------------------|
| **1-2** | ~3-5 ngày | Core model, parser, enhanced checkpoint |
| **3-4** | ~5-7 ngày | Executor, drift detection, persistence |
| **5-6** | ~5-7 ngày | Tool selection, PGraph integration |
| **7** | ~3-5 ngày | Testing, benchmarks, documentation |
| **Total** | **~16-24 ngày** | Full structured planning system |

---

*RFC authored: 2025-07-18*  
*Status: Draft — Merged from RFC-017, RFC-018, Gap Analysis, and Claude Code comparison*  
*Reviewers: @can1357*  
*Evidence sources: execution logs, agent.zig, graph_store.zig, store.zig, planning_capability_gap_analysis.md*
