# Issues 23-27: Final Status Summary

Retrieved from GitHub API (repo: wdvn/mini, authenticated):

| # | Title | State | Status in codebase |
|---|-------|-------|--------------------|
| 23 | memory leak on exit: DebugAllocator leak errors with empty stack traces | open | ✅ DONE - Fixed circular ring buffer unroll bug in `LineEditor.deinit` (`src/ui/editor.zig`); wired `capabilities_mod.deinitGlobalCache()` into `main.zig` defer and `exitAfterProcessCleanup()`; verified with `test_leak_turn.zig` & `test_capabilities.zig` asserting `std.heap.Check.ok`; wired into `test-leak` step. |
| 24 | journal: lưu usage (input/output/reasoning_tokens) vào delta của act_completed | open | ✅ DONE - `journal.zig` has `DeltaUsage`/`StateDelta.usage`/`context_tokens`; `step.zig:1198` captures usage; `turn.zig:237/255` flushes to journal; unit & E2E tests pass. |
| 25 | agent: nudge + cap retry cho response thinking_only (missing_terminal_event) | open | ✅ DONE - `ResponseRecoveryBudget.thinking_only = 1` (1 retry cap); advisory printed to stderr/history; consecutive failure triggers `thinking_loop` stall + warning. E2E verified in `run_tests_with_mock.sh`. |
| 26 | ui: session_diagnostics thêm section "Thinking profile" từ journal hiện có | open | ✅ DONE - `session_diagnostics.zig`: `ThinkingProfile`, `computeThinkingProfile`, `formatThinkingProfile`, integrated in `detailSession`. Tests pass. |
| 27 | agent: thinking budget + cảnh báo latency cho turns generation > threshold | open | ✅ DONE - `slow_turn_threshold_secs` latency warning & `act_generation_slow` journal event; model capability cache (`/models`) with `clipEffort` respecting mandatory reasoning; `guardReasoningMaxTokens` (strict `<` for Claude, `<=` for OpenAI); wire serialization (`reasoning.max_tokens` omitting `effort`); `~` alias normalization. Fully tested in `test_capabilities.zig` and verified via 2 E2E test flows in `scripts/run_tests_with_mock.sh` (10/10 E2E tests pass). |
| 28 | backend: decision-model adapter | open | ⏭ DEFERRED (blocked on #27 per issue description) |

## Work plan (23, 25-E2E, 26-regression, 27)

### #23 Memory leak on exit
Reproduce with DebugAllocator binary + ^C. Root causes to investigate:
- QuickJS runtime/context teardown (C-side allocations → empty stack traces)
- Arena allocations from skills/sessions that are never freed before process exit
- Verify with GPA vs DebugAllocator

### #25 E2E test for thinking_only nudge + cap
Add to `scripts/mock_llm_server.js` a case returning thinking-only + usage chunk; extend `run_tests_with_mock.sh` to assert nudge advisory + recovery_class=thinking_loop on attempt 3.

### #26 regression test
Extend `test_session_diagnostics.zig` fixture to include `usage` in delta and assert percentiles still compute correctly with usage + context_tokens.

### #27 Thinking budget + slow-turn alert
- Config options: `reasoning_effort`, `reasoning_max_tokens`, slow threshold flag
- Journal event for slow turns (`act_generation_slow` or add to `act_completed` delta)
- Capability lookup per-model from `/models` cache; clip effort into `supported_efforts`; respect `mandatory`
- Guard `reasoning.max_tokens <= max_tokens`
- `~` alias normalization
- Tests

## Note
Issue #24 and #26 both depend on journal `usage` field - already implemented, so they are effectively unblocked.
