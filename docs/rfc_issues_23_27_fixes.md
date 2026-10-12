# Fixes for Issues 23-26 (batch), with Issue 27

## Status

| Issue | Title | Status |
|-------|-------|--------|
| #23 | memory leak on exit: DebugAllocator leak errors with empty stack traces | ✅ Done (LineEditor.deinit kill_ring circular unroll fixed; tests pass with Check.ok) |
| #24 | journal: lưu usage (input/output/reasoning_tokens) vào delta của act_completed | ✅ Done |
| #25 | agent: nudge + cap retry cho response thinking_only (missing_terminal_event) | ✅ Done |
| #26 | ui: session_diagnostics thêm section "Thinking profile" từ journal hiện có | ✅ Done |
| #27 | agent: thinking budget + cảnh báo latency cho turns generation > threshold | ✅ Done (latency warning, capabilities cache, effort clipping, max_tokens guard, alias normalization) |
| #28 | backend: decision-model adapter | ⏭ Deferred (blocked on #27 per issue description) |

## Evidence for #24/#25/#26 being done

### #24 journal usage delta
- `src/core/journal.zig`: `DeltaUsage` struct (input_tokens, output_tokens, reasoning_tokens), `StateDelta.usage` field
- `src/core/agent/step.zig:1198`: captures `response.usage` into `loop.last_act_usage`
- `src/core/agent/turn.zig:237/255`: flushes `usage` + `context_tokens` into journal delta
- Test: `test "recordActComplete records usage and context_tokens in delta"`

### #25 nudge + cap retry thinking_only
- `src/core/protocol/decision.zig:113`: `ResponseRecoveryBudget.thinking_only: u8 = 1` (capped 1 retry)
- `src/core/agent/step.zig:729`: recovery advisory "The model response contained internal reasoning/thinking only..."
- `src/core/agent/step.zig:772`: 2nd consecutive thinking_only → `recovery_class = .thinking_loop`, stall + user warning
- Test: `test "Act 52 provider failure recovers then stalls on thinking loop"`

### #26 Thinking profile section
- `src/tools/session_diagnostics.zig`: `ThinkingProfile`, `computeThinkingProfile`, `formatThinkingProfile`, integrated in `detailSession`
- Tests: `computeThinkingProfile computes percentiles...`, `detailSession formats a hermetic session cleanly` (asserts "Thinking Profile")

## Work plan

### Issue #23 - Memory leak on exit
1. Reproduce: build Debug binary, run with ^C twice in TTY, observe leak messages
2. Check quickjs_engine.zig teardown - C-side allocations (JS_NewRuntime, JS_FreeValue) leave no Zig stack traces
3. Determine if leaks are page-aligned arenas (intentional, per process exit) or true leaks
4. Fix: if true leaks, add cleanup; if intentional, either (a) ensure they're freed on exit or (b) verify with GPA rather than DebugAllocator

### Issue #25 - E2E regression test (adds to existing Act 52 test)
- The Act 52 regression already exists in `scripts/run_tests_with_mock.sh` and checks thinking_loop + recovery_class + attempts 1-3
- Add a test for nudge advisory in journal when 1st thinking_only retry happens

### Issue #27 - Thinking budget + slow turn alert
1. Add journal event `act_generation_slow` / slow-turn warning when generation exceeds threshold
2. Config: `reasoning_effort`, `reasoning_max_tokens`, slow threshold flag (default off/120s)
3. `/models` capability lookup per-model (cache), clip effort into supported_efforts, respect mandatory
4. Guard reasoning.max_tokens <= max_tokens
5. `~` alias normalization
6. Tests: mock /models capability, mock SSE slow → alert

### Issue #28 - Decision model adapter
- Deferred per issue #28 ("nên làm sau #27")
