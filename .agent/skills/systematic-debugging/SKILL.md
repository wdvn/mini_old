---
name: systematic-debugging
description: "Systematic debugging discipline. Use when encountering any bug, test failure, or unexpected behavior, before proposing fixes. Root cause first, hypothesis-driven, minimal targeted fixes."
---

# Systematic Debugging Skill

General debugging discipline: ALWAYS find the root cause before attempting fixes. Symptom fixes are failure.

## The Iron Law

```
NO FIXES WITHOUT ROOT CAUSE INVESTIGATION FIRST
```

If Phase 1 is not complete, no fix may be proposed. This holds under time pressure, and for bugs that "look obvious". Systematic debugging is faster than guess-and-check thrashing.

---

## 1. When to Activate This Skill?

- Test failures, build failures, panics, crashes.
- Unexpected behavior in the agent, tools, backends, or UI.
- Performance problems, flaky tests, lingering background jobs.
- ESPECIALLY when: a "quick fix" seems tempting, a previous fix did not work, or you have already tried 2+ changes.
- Don't skip for simple bugs: simple bugs have root causes too.

Related skills: use `root-cause-analysis` for deep RCA methodology (5-Whys, bias countermeasures, falsification) and `session-diagnostics` for inspecting agent session logs.

---

## 2. Phase 1: Root Cause Investigation

Complete every step before proposing any fix.

### 2.1 Read Error Messages Carefully
- Read Zig `error` names and stack traces completely; note file, line, error code.
- For backend errors: inspect HTTP status and the raw response snippet.
- Don't skip warnings — they often contain the answer.

### 2.2 Reproduce Consistently
- Can you trigger it reliably? What are the exact steps?
- Write the repro as `testcases/test_<issue>.zig` (preferred) or a minimal shell one-liner via `mini.sh`.
- Not reproducible → gather more data first; never guess.
- Flaky under load/timing → suspect race or state dependence, see §6.

### 2.3 Check Recent Changes
```bash
git diff HEAD~5 -- src/
git log --oneline -10
```
New code, config edits, or environment differences are the most likely trigger.

### 2.4 Gather Evidence at Component Boundaries
For multi-component flows (agent loop → backend → CodeAct VM → tools), instrument each boundary before fixing:
- Log what data enters and exits each component (`std.debug.print` or `console.log` inside the JS block).
- Verify environment/config propagation at each layer.
- Run once, find WHERE it breaks, then investigate that specific component.

### 2.5 Agent-Behavior Bugs → Session Journal
When the agent misbehaves (wrong tool call, context overflow, bad loop), inspect the evidence:
```bash
tail -n 50 ~/.mini/sessions/journal_*.jsonl
```
Cross-check acts, observations, and errors in the journal against your hypothesis before touching code.

### 2.6 Trace Backward to the Original Trigger
Bugs often surface deep in the call chain; the error location is usually the symptom, not the source.

```
1. Observe symptom            → "git init ran in the source tree"
2. Immediate cause           → which code executed it?
3. What called this?         → trace one level up; what value was passed?
4. Keep going up             → until you reach the value's origin
5. Fix at the SOURCE         → then add guards at each layer (§5)
```
- If manual tracing fails, add instrumentation just before the dangerous operation: log the value, the cwd, and the call stack, run, read it.
- NEVER fix only where the error appears.

---

## 3. Phase 2: Pattern Analysis

Find the pattern before fixing:
1. **Find working examples** — locate similar code in the same codebase that works.
2. **Compare against references** — read the reference implementation completely, not skimmed.
3. **List every difference** between working and broken, however small. Don't assume "that can't matter".
4. **Map dependencies** — what config, state, or environment does the broken path assume?

---

## 4. Phase 3: Hypothesis and Testing

Scientific method, one variable at a time:
1. **Form a single hypothesis** — "I think X is the root cause because Y". Write it down, make it specific.
2. **Test minimally** — make the SMALLEST change that distinguishes the hypothesis; don't bundle fixes.
3. **Verify** — worked → Phase 4. Didn't work → form a NEW hypothesis; don't stack another patch on top.
4. **When you don't know** — say so explicitly; ask the user for more context or research. Never pretend.

---

## 5. Phase 4: Implementation

1. **Create a failing test first** — `testcases/test_<issue>.zig` (or minimal shell repro). Must fail before the fix.
2. **Implement ONE fix** addressing the root cause. No "while I'm here" refactors, no bundled changes.
3. **Verify**:
   ```bash
   zig build test -Dskip-e2e=true          # fast iteration (Tier 1+2)
   zig build test --summary all             # full 13/13 when touching core/ or tools/
   ```
   Failing test now passes AND no other tests broke.
4. **If the fix doesn't work — STOP and count:**
   - < 3 attempts → back to Phase 1 with the new information.
   - ≥ 3 attempts → this is likely an architectural problem, not a failed hypothesis. Each fix revealing a new problem in a different place is the signature. STOP and discuss with the user: refactor the architecture vs. keep patching symptoms.

---

## 6. Defense in Depth (After Finding the Root Cause)

Fixing at one point can be bypassed by other code paths, refactors, or mocks. Validate at EVERY layer data passes through:

```zig
// Layer 1: entry point — reject obviously invalid input
pub fn createProject(name: []const u8, dir: []const u8) !void {
    if (dir.len == 0) return error.InvalidDir;      // e.g. empty string
}

// Layer 2: business logic — data makes sense for this operation
// Layer 3: environment guard — refuse dangerous op in test context
// Layer 4: debug instrumentation — log value + call site before the op
```
- Entry validation catches most bugs; environment guards catch context-specific danger; instrumentation catches what all others miss.
- Single check: "we fixed the bug". Multiple layers: "the bug is structurally impossible".
- For flaky tests: replace arbitrary `sleep`/`setTimeout` guesses with condition polling (wait until the actual state you care about, with a bounded timeout and a clear error). For long-running commands in the agent, use `mini.shBackground` + poll `mini.jobStatus`/`mini.jobLogs` instead of guessed delays.

---

## 7. Red Flags — STOP and Return to Phase 1

If you catch yourself thinking:
- "Quick fix for now, investigate later"
- "Just try changing X and see if it works"
- "Bundle a few changes, run the tests"
- "Skip the test, I'll verify manually"
- "It's probably X, let me fix that"
- "One more fix attempt" (after 2+ already failed)
- "Each fix keeps revealing a new problem elsewhere"

All of these mean: STOP. Return to Phase 1. If 3+ fixes failed, question the architecture (§5.4) instead of attempting fix #4.

## 8. When Investigation Reveals No Root Cause

If the issue is genuinely environmental or external (timing, network, quota):
1. Document what was investigated and what was ruled out.
2. Implement proper handling (retry, timeout, clear error message).
3. Add logging so the next occurrence is diagnosable.

Most "no root cause" conclusions are incomplete investigation — recheck Phase 1 before accepting it.
