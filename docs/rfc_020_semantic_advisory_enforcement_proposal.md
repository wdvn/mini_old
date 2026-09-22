# RFC-020: Semantic Advisory Enforcement System

**Status**: Proposed  
**Date**: 2026-09-22  
**Author**: mini-agent team  
**Supersedes**: RFC-010 (Procedural Graph)

---

## 1. EXECUTIVE SUMMARY

Current procedural advisory system has **perfect infrastructure** (semantic understanding, context awareness, pattern recognition) but **zero enforcement** — model ignores 100% of suggestions because advisory is marked as "optional".

This RFC proposes adding:
1. **Telemetry** — measure compliance rate
2. **Weight-based severity** — differentiate critical vs trivial suggestions
3. **Semantic enforcement** — escalate based on context

**Goal**: Transform advisory from "suggestion engine" to "guidance system" with measurable behavioral impact.

---

## 2. CURRENT STATE ANALYSIS

### 2.1 Evidence from Output

```
[Procedural Advisory (Optional Suggestions)]
Current Action: `bash`
- bash → grep (TRIGGERS)
  - Condition: compiler error or test failure
  - Suggestion: Search codebase for failing symbol...
  - Pitfalls: Do not mutate code before understanding exact error cause.
⚠️ Advisory Note: You are NOT required to follow them.
🎯 Current task reminder: "..."
```

### 2.2 Effectiveness Score

| Component | Score | Status |
|-----------|-------|--------|
| Infrastructure | 10/10 | ✅ Hoàn thiện |
| Semantic Understanding | 10/10 | ✅ TRIGGERS vs LEADS_TO chính xác |
| Task Anchoring | 10/10 | ✅ Nhớ user request |
| **Enforcement** | **0/10** | ❌ Optional only |
| **Telemetry** | **0/10** | ❌ Không đo được |
| **TOTAL** | **6/10** | Infrastructure perfect, zero impact |

### 2.3 Root Cause of Loops

```
Advisory format: "NOT required to follow them"
    ↓
Model interpretation: "Optional suggestion"
    ↓
Model behavior: Ignore 100%
    ↓
Result: Loop continues despite correct advisory
```

---

## 3. PROPOSED SOLUTION

### 3.1 Phase 1: Telemetry (REQUIRED)

Add events to `journal.zig`:
```zig
pub const ActEventType = enum {
    // ... existing ...
    advisory_injected,           // NEW: When advisory is shown
    tool_call_after_advisory,    // NEW: What tool was called next
};
```

**Metrics to track:**
- Advisory injection rate
- Compliance rate = (tools matching advisory) / (total advisories)
- Task outcome correlation

### 3.2 Phase 2: Weight-Based Severity

**Formula** (frequency-based, no hardcoding):
```zig
weight = 1.0 + 0.5 * log10(1 + transition_count)
```

**Severity labels:**
```
weight < 2.0  → ⚠️ OPTIONAL
weight 2.0-4.0 → 📌 RECOMMENDED  
weight >= 4.0 → 🔒 MANDATORY
```

### 3.3 Phase 3: Semantic Enforcement

**Context-aware escalation:**
```zig
if (last_advisory_ignored && last_task_failed) {
    severity = .mandatory;
}
```

**Output format:**
```
[Procedural Advisory]
Current Action: `bash`
Severity: 🔒 MANDATORY (weight=3.2, confidence=0.89)

- bash → grep [TRIGGERS] (weight=4.1)
  Condition: exit_code > 0 detected
  Required: MUST search for error before editing
```

---

## 4. IMPLEMENTATION PLAN

### 4.1 File Changes

| File | Change | Lines |
|------|--------|-------|
| `src/core/journal.zig` | Add telemetry events | +4 |
| `src/lib/graph/types.zig` | Add `transition_count` field | +2 |
| `src/core/memact/graph_store.zig` | Add weight computation | +30 |
| `src/core/agent.zig` | Record telemetry | +5 |

### 4.2 Timeline

| Week | Task | Deliverable |
|------|------|-------------|
| 1 | Add telemetry events | Journal records |
| 2 | Collect baseline data | 100+ sessions |
| 3 | Implement weight learning | Dynamic weights |
| 4 | A/B test | Compliance comparison |

---

## 5. EVALUATION METHODOLOGY

### 5.1 LLM-as-Judge (Primary)

```python
def evaluate_advisory(trajectory, advisory, next_action):
    prompt = f"""
    Given trajectory and advisory, did model follow suggestion?
    Score 0-10 for compliance quality.
    """
    return llm_score(prompt)
```

### 5.2 Behavioral Telemetry

```sql
SELECT 
  advisory_content,
  next_tool_name,
  task_success
FROM journals
WHERE advisory_injected IS NOT NULL
GROUP BY advisory_content
```

### 5.3 Success Metrics

| Metric | Baseline | Target |
|--------|----------|--------|
| Compliance rate | ~0% | >70% |
| Task completion time | T | T × 0.85 |
| Loop reduction | N/A | -50% |

---

## 6. RISK ASSESSMENT

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Over-enforcement | Medium | High | Start weight threshold 4.0 |
| Weight saturation | Low | Medium | Cap max weight at 5.0 |
| Biased learning | Medium | High | Regular audit |

---

## 7. CONCLUSION

**Current state**: Advisory is "suggestion engine" (infrastructure perfect, zero enforcement).  
**Target state**: Advisory is "guidance system" (semantic understanding + measured compliance + adaptive severity).

**Recommendation**: Implement Phase 1 (telemetry) FIRST — cannot improve what cannot be measured.

---

**References:**
- RFC-010: Procedural Graph
- RFC-015: Three Thread Runtime and Watchdog
