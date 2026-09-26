---
name: receiving-code-review
description: Use when receiving code review feedback or user corrections to the agent's own work, before implementing suggestions, especially if feedback is unclear or technically questionable. Verifies every claim against the codebase, pushes back with technical reasoning, and implements one item at a time.
---

# Receiving Code Review

Handling review feedback with technical rigor: verify before implementing, never performative agreement. Applies to external reviewer comments and to the user correcting the agent's own work (user corrections get more trust but the same verification discipline).

**Core principle:** Verify before implementing. Ask before assuming. Technical correctness over social comfort.

## 1. The 6-Step Response Pattern

```
WHEN receiving review feedback (reviewer comment or user correction):
  1. READ      - complete feedback without reacting
  2. UNDERSTAND - restate each item in own words, or mark unclear
  3. VERIFY    - check each item against codebase reality
  4. EVALUATE  - is it technically sound for THIS codebase?
  5. RESPOND   - technical acknowledgment or reasoned pushback
  6. IMPLEMENT - one item at a time, test each
```

## 2. Forbidden Performative Responses

NEVER: "You're absolutely right!" / "Great point!" / "Excellent feedback!" / "Thanks for catching that!" / "Let me implement that now" (before verification).

INSTEAD: restate the technical requirement, ask specific clarifying questions, push back with technical reasoning, or just start working (actions over words). If you catch yourself about to write "Thanks", delete it and state the fix.

When feedback IS correct: "Fixed. [brief description of what changed]" or just show the diff. No gratitude.

## 3. Verify Against Reality (Step 3 detail)

Before implementing any suggestion, ground it in the active codebase:

- `mini.read(path)` - read the affected file, confirm the claimed problem exists
- `mini.grep(pattern, path)` - check actual usage (feeds the YAGNI check, §4)
- `mini.sh("zig build test -Dskip-e2e=true")` - confirm current test state before changing
- `mini.sh("git log -p -- <path>")` - check why the code was written this way

IF a suggestion seems wrong: push back with technical reasoning.
IF you cannot easily verify: say so - "I can't verify this without [X]. Should I investigate / ask / proceed?"
IF it conflicts with a prior user decision: stop and discuss with the user first.

## 4. YAGNI Check for "Professional" Features

```
IF reviewer suggests "implement this properly" (database, export, filters...):
  grep the codebase for actual usage of the target
  IF unused:  "Nothing calls this. Remove it (YAGNI)?"
  IF used:    then implement properly
```

Rule: the user's direction beats the reviewer's. If the user doesn't need the feature, don't add it.

## 5. Handling Unclear Feedback

```
IF any item is unclear:
  STOP - do not implement anything yet
  ASK for clarification on the unclear items

WHY: Items may be related. Partial understanding = wrong implementation.
```

Example: "Fix items 1-6". You understand 1, 2, 3, 6. Unclear on 4, 5.
WRONG: implement 1, 2, 3, 6 now, ask about 4, 5 later.
RIGHT: "I understand items 1, 2, 3, 6. Need clarification on 4 and 5 before proceeding."

## 6. Pushing Back

Push back when:
- the suggestion breaks existing functionality
- the reviewer lacks full context of this codebase
- it violates YAGNI (unused feature)
- it is technically incorrect for this stack (Zig 0.16.0, CodeAct VM, mini.* API)
- legacy/compatibility reasons exist
- it conflicts with the user's architectural decisions

How: use technical reasoning, not defensiveness. Ask specific questions. Reference working tests and code. Involve the user for architectural conflicts.

If you later find out your pushback was wrong: "You were right - I checked [X] and it does [Y]. Implementing now." State it factually, no long apology, no defending the pushback, move on.

## 7. Implementation Order

FOR multi-item feedback:
1. Clarify anything unclear FIRST
2. Then implement in order: blocking issues (breaks, security) -> simple fixes (typos, imports) -> complex fixes (refactoring, logic)
3. One item at a time - implement a single item via `mini.patch(path, oldStr, newStr)` (minimal surgical edit)
4. After each item, run `mini.sh("zig build test -Dskip-e2e=true")` and confirm no regressions before the next
5. After all items, run the full suite `mini.sh("zig build test --summary all")` if E2E/node is available

## 8. Common Mistakes

| Mistake | Fix |
|---------|-----|
| Performative agreement | State the requirement, or just act |
| Blind implementation | Verify with mini.read / mini.grep / mini.sh first |
| Batch without testing | One item at a time, `zig build test -Dskip-e2e=true` after each |
| Assuming reviewer is right | Check whether it breaks existing behavior |
| Avoiding pushback | Technical correctness over comfort |
| Partial implementation | Clarify all unclear items first |
| Can't verify, proceed anyway | State the limitation, ask for direction |
