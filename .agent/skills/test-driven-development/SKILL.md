---
name: test-driven-development
description: Use when implementing any feature, bugfix, or behavior change before writing production code. Failing test first, watch it fail, minimal code to pass, refactor.
---

# Test-Driven Development (TDD)

Write the test first. Watch it fail. Write minimal code to pass.

**Core principle:** If you did not watch the test fail, it tests nothing.

## 1. When to Activate This Skill?

- Implementing a new feature, before touching production code.
- Fixing a bug (the bug gets a failing test that reproduces it first).
- Refactoring or changing behavior of existing code.

## 2. The Iron Law

```
NO PRODUCTION CODE WITHOUT A FAILING TEST FIRST
```

- Wrote code before its test? **Delete it.** No "keep as reference", no "adapt while writing tests". Delete means delete. Implement fresh from the tests.
- **Exception — state it explicitly, then proceed:** throwaway prototypes, generated code, and config files are exempt from TDD. State the exemption in the output ("prototyping, no TDD") and move on. The user can object.

## 3. Red-Green-Refactor Cycle

```
RED (failing test) -> verify it fails -> GREEN (minimal code) -> verify passes -> REFACTOR -> repeat
```

### 3.1 RED — Write One Failing Test

Requirements:
- **One behavior** per test. "And" in the test name? Split it.
- **Name the intent**: the test name states what production behavior it locks in (e.g. `test_empty_email_rejected`).
- **Real code**, no mocks (in Zig: call the function under test directly; avoid stand-ins unless the dependency is genuinely slow/external).

```zig
// testcases/test_email_validation.zig (illustrative)
const std = @import("std");
const email = @import("../src/core/email.zig"); // project module under test

test "empty email rejected" {
    const result = email.validate("");
    try std.testing.expectEqual(email.Status.invalid, result);
}
```

### 3.2 Verify RED — Watch It Fail (MANDATORY, never skip)

```js
const r = mini.sh('zig build test -Dskip-e2e=true');
console.log(r.stdout);
```

Confirm:
- Test **fails** (not errors/crashes from a typo).
- Failure is for the expected reason (feature missing), not setup breakage.
- Long suite → run in background and poll:

```js
const job = mini.shBackground('zig build test -Dskip-e2e=true');
// poll in short reads so the watchdog never kills the turn
const st = mini.jobStatus(job.jobId);
if (st.running) { console.log(mini.jobLogs(job.jobId, 50)); }
```

- **Test passes already?** You're testing existing behavior — fix the test so it would fail against today's code.
- **Test errors (compile/panic)?** Fix the error, re-run, until it fails for the right reason.

### 3.3 GREEN — Minimal Code to Pass

Write the simplest production code that passes. No extra features, no options objects nobody asked for, no refactoring adjacent code.

```zig
pub fn validate(email: []const u8) Status {
    if (email.len == 0) return .invalid;
    // just enough to pass the test
}
```

### 3.4 Verify GREEN — Whole Suite, Not Just Your File

```js
const r = mini.sh('zig build test -Dskip-e2e=true');
```

- Your test passes **and** no other test broke. A green run of your one file is not a green suite.
- Any failure the run shows — even pre-existing or unrelated — is reported by name. Omission falsifies the report.
- Test fails? Fix the **code**, not the test.

### 3.5 REFACTOR — Only While Green

After green: remove duplication, improve names, extract helpers. No behavior changes. Re-run to stay green. Then next failing test.

## 4. Good Tests (essence of writing-good-tests)

- **One behavior per test.** Split "and"s. A test that catches two breaks catches neither reliably.
- **Name the intent.** Before writing the body, name the production change that would make this test fail — a bug, not a style decision. If only intentional changes (constant values, exact wording) fail it, it is a change detector: test the behavior that depends on the decision instead.
- **Check invariants, derive expectations by hand.** Assert literals or hand-checked fixtures, never values the code under test computes. No mirror assertions (`expect(build(q)).toBe(build(q))` is always true).
- **Exercise the real thing.** Don't assert on mocks/doubles; assert the component's behavior. A method called only from tests belongs in test utilities, not production.

## 5. Anti-Rationalizations

| Excuse | Reality |
|--------|---------|
| "Too simple to test" | Simple code breaks. The test takes 30 seconds. |
| "I'll add tests after" | Tests written after pass immediately — which proves nothing; you never watched the failure. |
| "I already manually tested it" | Manual is ad-hoc, unreproducible. "Worked when I tried" ≠ comprehensive. |
| "Deleting X hours is wasteful" | Sunk cost. Rewrite with TDD (high confidence) vs. keep unproven code (likely bugs). |
| "Keep old code as reference" | You will adapt it — that is testing after. Delete means delete. |
| "TDD is dogmatic, I'm being pragmatic" | TDD catches bugs before commit and makes refactors safe. The "pragmatic" shortcut is debugging in production. |

**Red flags — stop and start over:** code before test, test passes on first run, can't explain why a test failed, tests "added later", "spirit not ritual".

## 6. Verification Checklist

Before marking work complete:
- [ ] Every new/changed behavior has a test, written and failed first.
- [ ] Each test failed for the expected reason.
- [ ] Minimal code was written to pass.
- [ ] `zig build test -Dskip-e2e=true` fully green (or TDD exemption stated explicitly).

## 7. When Stuck

- Don't know how to test → write the wished-for API and the assertion first.
- Test too complicated → the design is too complicated; simplify the interface.
- Must mock everything → the code is too coupled; use dependency injection.
