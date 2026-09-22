# RFC-020: Semantic Advisory Enforcement System

**Status**: Proposed  
**Date**: 2026-09-22  
**Related**: RFC-010 (Procedural Graph)

---

## Problem

Advisory has perfect semantic understanding but ZERO enforcement:
```
"You are NOT required to follow them"
→ Model compliance rate = 0%
→ Loops continue despite correct suggestions
```

## Solution

### Phase 1: Telemetry
```zig
// journal.zig
pub const ActEventType = enum {
    advisory_injected,
    tool_call_after_advisory,
};
```

### Phase 2: Weight-Based Severity
```zig
// Weight formula (frequency-based, no hardcoding)
weight = 1.0 + 0.5 * log10(1 + transition_count)

// Severity labels
weight < 2.0  → ⚠️ OPTIONAL
weight 2.0-4.0 → 📌 RECOMMENDED
weight >= 4.0 → 🔒 MANDATORY
```

### Phase 3: Semantic Enforcement
```
Context-aware escalation:
if (last_advisory_ignored && last_task_failed) {
    severity = .mandatory;
}
```

## Expected Output
```
[Procedural Advisory]
Severity: 🔒 MANDATORY (weight=3.2)

- bash → grep [TRIGGERS] (weight=4.1)
  Required: MUST search for error before editing
```

## Implementation
- `src/core/journal.zig`: +4 lines (telemetry events)
- `src/lib/graph/types.zig`: +2 lines (transition_count)
- `src/core/memact/graph_store.zig`: +30 lines (weight computation)
- `src/core/agent.zig`: +5 lines (telemetry recording)

**Total**: ~41 lines changed
