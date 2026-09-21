# Root Cause Analysis: Mini Agent Unexpectedly Stops

## Problem Statement
Mini-agent đôi khi bị stop không rõ lý do — quá trình kết thúc đột ngột giữa chừng trong khi đang thực thi act, không có `task_completed` hoặc `task_interrupted` trong journal.

## Evidence from Journals

### Dangling Journals (Process Died During Act)
| Journal | Acts Completed | Last Event | Diagnosis |
|---------|---------------|------------|-----------|
| `journal_1221198.jsonl` | 21 acts | `act_started` (act 22) | **DANGLING** — died mid-act |
| `journal_1219643.jsonl` | 30 acts | `act_started` (act 31) | **DANGLING** — died mid-act |

All other 25 sessions ended cleanly with `task_completed` or `task_interrupted`.

### Clean Interrupts (Ctrl+C — Expected)
- `journal_1212245.jsonl`: act 26 interrupted after 1923ms — user pressed Ctrl+C
- `journal_1214738.jsonl`: 2 quick Ctrl+C interrupts during fast new-session testing

---

## Root Causes Identified

### Cause 1: Watchdog Timeout Triggered by LLM Decision (PRIMARY CAUSE)

**Flow:**
1. Act runs for 120s (default `act_timeout_secs`)
2. Watchdog Thread 2 fires `consultLlmOnTimeout()` — sends a 1-call LLM request asking whether to WAIT or KILL
3. If LLM returns `DECISION: KILL` (or parse fails → defaults to KILL):
   - `signals.setInterrupted(true)` ← flag set
   - `coordinator.setTimedOut(true)` ← flag set
   - `interrupt_fn()` called → SIGTERM to bash process group
4. Main act loop catches `error.Interrupted` at `executeStep()` line 1037:
   ```zig
   if (signals.isInterrupted() or self.coordinator.isTimedOut()) return error.Interrupted;
   ```
5. In the catch block, detects `isTimedOut() == true`, enters watchdog timeout recovery path
6. **Critical**: If `finishAct(act_id, false)` succeeds but the act loop then `break`s out, the journal only has `act_started` — no `act_completed`, no `task_completed`, no `task_interrupted`

**Why journal shows only `act_started`:**
- `act_started` is recorded at top of the inner while loop (line 1827)
- `executeStep` returns `error.Interrupted` BEFORE any `act_completed` can be written
- The watchdog timeout handler does NOT call `j.recordEvent(.act_completed, ...)` — it calls `finishAct(act_id, false)` which updates the coordinator but doesn't journal a completion event
- The `task_completed` is only written when `result == .exit_loop` (normal completion), NOT on interrupt

**This explains the "stop without reason" behavior**: The user sees the agent halt mid-task with no visible error message if `verbose_stderr` is false or if the stderr output was scrolled away.

### Cause 2: Missing `act_completed` / `task_completed` Journaling on Watchdog Timeout Recovery

**Bug in `agent.zig` catch block (lines 1832–1855):**
```zig
if (self.coordinator.isTimedOut()) {
    // ... UI messages ...
    signals.setInterrupted(false);
    self.coordinator.setTimedOut(false);
    self.last_act_failed = true;
    // ... injects error message into history ...
    self.coordinator.finishAct(act_id, false);
    break;  // <-- breaks out of try loop, then outer act loop continues
}
```

After `break`, execution goes to line ~2100:
```zig
if (result == .exit_loop) {
    j.recordEvent(.task_completed, ...)  // ← NEVER REACHED on break
    return;
}
self.coordinator.finishAct(act_id, !self.last_act_failed);
break;  // breaks try loop, act_id += 1, next iteration
```

The `break` from the watchdog path causes the act loop to continue to the NEXT act without ever writing `task_completed` for the timed-out act. The process stays alive but the previous act's journal entry is incomplete.

If the NEXT act also gets interrupted (rapid-fire timeout), the journal can end with a dangling `act_started`.

### Cause 3: LLM Timeout Decision Unreliability

**In `consultLlmOnTimeout()`:**
- The LLM is asked to decide WAIT vs KILL on a single call
- If the LLM call itself fails (network error, rate limit, timeout), the fallback is:
  ```zig
  var fallback = watchdog_mod.TimeoutDecision{
      .should_kill = false,
      .extend_seconds = 30,
  };
  ```
- But `parseTimeoutDecision()` defaults to `should_kill = false` only if NO decision line is found
- If the LLM responds with unexpected format, parsing may yield `should_kill = true` (the default in the struct initialization at line 2931)

This means **random LLM output format issues can cause unexpected KILL decisions**.

### Cause 4: `beginAct()` Resets Parser State Without Guard

**In `repl.zig` (new code from recent commits):**
```zig
pub fn beginAct(act_id: usize) void {
    while (!g_renderer_mutex.tryLock()) {}
    const r = current_renderer;
    g_renderer_mutex.unlock();
    if (r) |renderer| {
        if (act_id > 1) {
            renderer.parser.resetAct();   // resets stream parser state
            renderer.startWaiting();      // starts waiting indicator
        }
    }
}
```

If a SIGTERM arrives during pipe draining (bash tool), the `drainPipe` function checks `signals.isInterrupted()` and breaks. But if the act loop then re-enters with `beginAct()` resetting state, the UI can show inconsistent state (waiting indicator restarts mid-stream).

---

## Contributing Factors

| Factor | Impact |
|--------|--------|
| Default `act_timeout_secs = 120` | Any act > 2 min triggers LLM consultation |
| `watchdog_interval_ms = 200` | Check frequency is fast enough to catch timeout but also creates race conditions |
| LLM-based decision (1-call) | Non-deterministic — depends on model output quality |
| No journal event on timeout recovery | Makes debugging impossible from journal alone |
| `signals.isInterrupted()` not cleared between acts | A stale flag from a previous Ctrl+C could trigger early interrupt |

---

## Reproduction Steps

1. Run mini on a long-running multi-act task (10+ acts)
2. Ensure some acts take > 120s (e.g., `find /home`, `grep -r`, compiling)
3. Watchdog will trigger LLM consultation at 120s
4. If LLM decides KILL (or fails to parse), act is interrupted silently
5. Journal shows `act_started` → next `act_started` (no `act_completed` in between)

---

## Proposed Fixes

### Fix 1: Journal the timeout event
In the watchdog timeout recovery path (agent.zig ~line 1848), add:
```zig
if (self.journal) |*j| {
    j.recordEvent(self.io, act_id, .task_interrupted, "Watchdog timeout — action terminated by LLM decision") catch {};
}
```

### Fix 2: Make timeout decision more robust
- Increase `act_timeout_secs` default or make it configurable per-act
- Add a minimum threshold before first LLM consultation (e.g., 180s instead of 120s)
- Cache the last decision and don't re-consult for the same act

### Fix 3: Clear interrupt flag more aggressively
After handling a watchdog timeout, ensure `signals.setInterrupted(false)` is called BEFORE the next `executeStep` check, to prevent the flag from being read as a user Ctrl+C.

### Fix 4: Add stderr logging on silent interrupt
When the watchdog kills an act, always print to stderr regardless of `verbose_stderr` setting, so the user knows WHY the act stopped.

---

## Conclusion

The "stop without reason" behavior is caused by the **Watchdog's LLM-based timeout decision system** killing acts that exceed 120 seconds, combined with **incomplete journal logging** that makes these events invisible in the session records. The process itself doesn't crash — it continues running but the current act is silently terminated.

The two dangling journals (`1221198` and `1219643`) are consistent with this: the agent was in the middle of a long bash command when the watchdog decided to KILL, and the resulting `error.Interrupted` propagated up without a proper `act_completed` journal entry.
