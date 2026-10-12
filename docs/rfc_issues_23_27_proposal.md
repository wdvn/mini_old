# RFC: Issues 23-27 fixes (backlog batch)

Status: investigation complete. Issues 24/25/26 are already resolved in codebase.

## Issue #23 — memory leak on exit (DebugAllocator empty stack traces)
- **Status**: PARTIALLY ADDRESSED
- Existing leak tests: `test_leak.zig`, `test_leak_turn.zig`, `test_leak_exit.zig`, `test_leak_exit2.zig`
- Root cause hypothesis: QuickJS engine teardown leaves page-aligned arenas; DebugAllocator reports empty stack traces because allocations happen in C layer / before Zig allocator tracking.
- Action: reproduce with `zig build` Debug binary + ^C in TTY; if reproducible, add explicit QuickJS/arena cleanup and/or mark intentional arena pages as freed via allocator debug config.

## Issue #24 — journal: lưu usage (input/output/reasoning_tokens) vào delta của act_completed
- **Status**: ✅ DONE
- `journal.zig` has `DeltaUsage` struct, `recordActComplete` stores `usage` + `context_tokens`, unit test exists (`recordActComplete records usage and context_tokens in delta`).
- `turn.zig` flushes `last_act_usage`/`last_act_context_tokens` to journal.
- Acceptance criteria met.

## Issue #25 — agent: nudge + cap retry cho response thinking_only (missing_terminal_event)
- **Status**: ✅ DONE
- `ResponseRecoveryBudget.thinking_only: u8 = 1` → capped at 1 retry attempt.
- Recovery advisory appended: "The model response contained internal reasoning/thinking only, without any actionable output..."
- 2nd consecutive thinking_only → `thinking_loop` recovery class → stall + user-visible warning in UI/stderr.
- Unit test: `Act 52 provider failure recovers then stalls on thinking loop`.
- TODO: E2E test with mock server returning thinking_only stream (adds test for nudge + cap).

## Issue #26 — ui: session_diagnostics thêm section "Thinking profile"
- **Status**: ✅ DONE
- `src/tools/session_diagnostics.zig`: `ThinkingProfile` struct, `computeThinkingProfile`, `formatThinkingProfile`, integrated into `detailSession`.
- Tests: `computeThinkingProfile computes percentiles, retries, and slowest acts correctly`; `detailSession formats a hermetic session cleanly` (asserts "Thinking Profile" present).

## Issue #27 — agent: thinking budget + cảnh báo latency cho turns generation > threshold
- **Status**: ❌ NOT DONE — needs implementation
- Requirements:
  1. Journal event `act_generation_slow` (or use `act_completed` + slow threshold) when generation > threshold (configurable, default 120s).
  2. Capability lookup per-model from `/models` (cache); clip `reasoning.effort` into `supported_efforts`; respect `mandatory` (don't force `none`); guard `reasoning.max_tokens <= max_tokens`.
  3. `reasoning.max_tokens` support (Anthropic-style) passed as `reasoning.max_tokens`.
  4. `~` alias normalization for model capability lookup.
  5. Config: `reasoning_effort`, `reasoning_max_tokens`, slow threshold flag — default off.
- Acceptance:
  - [ ] Config `reasoning.effort` pass into `reasoning.effort`
  - [ ] Config `reasoning.max_tokens` pass into `reasoning.max_tokens`; don't send both at once
  - [ ] Capability lookup per-model from `/models` (cache); clip effort into `supported_efforts`; respect `mandatory`
  - [ ] Guard `max_tokens` × `reasoning.max_tokens` (Anthropic: strict <)
  - [ ] `~` alias normalization
  - [ ] Event journal slow-turn alert when > threshold
  - [ ] Test: mock /models returns capability → assert clip/validate; mock SSE slow → assert alert

## Issue #28 — backend: decision-model adapter (OpenRouter /api/alpha/decisions)
- **Status**: ❌ NOT DONE — deferred per issue #28 itself ("nên làm sau #27")
- Scope: decision backend calling `/api/alpha/decisions`, 3 decision points (watchdog timeout, retry classifier, adaptive thinking tier), fallback to main LLM.
- Not required for issues 23->26 batch; can be left for a later iteration.

## Decision
Proceed with: #23 investigation + fix, #25 E2E test, #26 regression test (already done), #27 implementation. Issue #28 deferred.
