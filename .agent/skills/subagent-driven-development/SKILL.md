---
name: subagent-driven-development
description: "Use when executing a multi-task implementation plan with mostly independent tasks in the current session. Dispatch a fresh implementer subagent per task, run a per-task review (spec compliance + code quality), and finish with a broad whole-branch review."
---

# Subagent-Driven Development Skill

Execute an implementation plan by dispatching a fresh implementer subagent per task, a task-scoped review after each task, and one broad whole-branch review at the end. You only coordinate: dispatch, verdicts, ledger, rulings. You never fix findings yourself.

## 1. When to Activate This Skill?

- A written implementation plan exists (from `writing-plans`) with 2+ mostly independent tasks.
- Tasks touch disjoint files/interfaces, so they can run in dependency layers.
- Per-task quality gates wanted in the current session (vs. `executing-plans`, which runs tasks inline and reviews only at the end).
- Tightly coupled tasks that cannot be isolated → fall back to `executing-plans` or manual execution.

## 2. Setup

1. **Isolation**: verify an isolated branch/worktree (`using-git-worktrees`); never start on main/master without user consent.
2. **Ledger**: create with `artifact_write` (`plan.md`), first line `# SDD ledger — plan: <plan file path>`. Update it after every dispatch/verdict; it survives compaction. Resume at the first task without a `Task <N>: complete` line.
3. **Read the plan once**, note Global Constraints; if a spec is named, read it — the spec is the binding authority, the plan is its argument.
4. **Pre-flight scan**: before Task 1, scan for conflicts between tasks / Global Constraints the rubric would flag. One ledger row per shared-file/interface task pair. Rule on every conflict: `Ruling: <decision> — <why> — <cost if wrong>`.
5. **Record BASE**: `git rev-parse HEAD` before each dispatch; diff reviews from this BASE, never `HEAD~1`.
6. **Layer the tasks**: group into dependency layers — tasks in one layer share no files/interfaces. ≥2 independent tasks in a layer → ONE `batch_invoke_subagents` call. Subagents sharing files never run in parallel.

## 3. The Task Loop (per task)

### 3.1 Dispatch the implementer

Dispatch via `invoke_subagent` (or `batch_invoke_subagents` for a whole layer). The task string is fully self-contained — the subagent sees NO session history. Embed: repo path, the plan text for this task verbatim, Global Constraints, earlier tasks' interfaces, conventions, completion criteria, report contract. Use template §7.

- One dispatch describes ONE task, never accumulated session history.
- Batch exception: several tiny same-shape edits → ONE dispatch listing every file and its change; review the diff as one unit.
- The implementer never spawns subagents (no helpers, no reviewers); a worker-spawned reviewer is a defect to flag.
- If an earlier task parked a finding in this task's area, carry a pointer to that ledger entry.
- Large artifacts: pass file paths the subagent reads with `mini.read`, never paste content.

### 3.2 Handle the report

- **DONE** → build the review package, dispatch the task reviewer.
- **DONE_WITH_CONCERNS** → read concerns. Correctness/scope concerns: resolve before review. Observations: note in ledger, proceed to review.
- **NEEDS_CONTEXT** → supply the missing context, re-dispatch.
- **BLOCKED** → (1) context gap: more context, re-dispatch; (2) needs more reasoning: re-dispatch with a substantially enriched prompt; (3) task too large: split it; (4) plan is wrong: rule, ledger, re-dispatch carrying the ruling. Never retry the same prompt unchanged.

Review package: `mini.sh("git log --oneline BASE..HEAD && git diff --stat BASE..HEAD && git diff -U10 BASE..HEAD")`. The reviewer receives the diff range, the task's plan text, and Global Constraints — never the pasted diff.

### 3.3 Review the task

Dispatch a task reviewer via `invoke_subagent` (template §8), scoped to the diff + spec. It returns two verdicts: **spec compliance** (missing/extra/misunderstood vs. the plan text) and **code quality** (clean, tested, maintainable), with Critical/Important/Minor issues and `⚠️ cannot-verify-from-diff` items.
Rules:
- Never skip the task review; a report missing either verdict is rejected.
- Reviewers are read-only and never re-run the implementer's tests — the report carries test evidence.
- Never pre-judge findings ("do not flag X" in a reviewer prompt is forbidden).
- `⚠️` items: resolve each yourself; a confirmed real gap enters the fix loop.
- Minor findings: ledger as `Task <N>: minor (deferred): <one-liner>`; never enter the loop, but the final review triages them.
- A finding conflicting with plan text: rule on it (spec is binding), ledger it, then act.

### 3.4 The fix loop

Triggers: spec ❌, any Critical/Important finding, or a confirmed `⚠️` gap. A fix round = one fix dispatch + one scoped re-review (template §9). **Max five rounds per task:**

- **Rounds 1–3**: re-dispatch an implementer carrying the task text, the previous report, and the open findings verbatim, with a note of what prior attempts tried.
- **Rounds 4–5**: dispatch a FRESH implementer with an enriched prompt framed as "a prior implementer attempted this N times; you own it now" — change the prompt substantially, not just the findings list.
- Every round: the fixer re-runs only the tests covering amended code and appends a fix report naming covering tests + command + output; confirm all three exist before the re-review.
- The re-review is scoped: diff range = fix commits only; verdicts each finding ADDRESSED/NOT ADDRESSED and checks new breakage in the fix diff only. New Critical/Important breakage joins the open list; out-of-scope observations → ledger as deferred minors.
- Ledger after each round: `Task <N>: fix round <R>/5 (<X> addressed, <Y> open; commits <a7>..<b7>)`.

**The breaker (round 5 cap).** Stop dispatching. Adjudicate each open finding:
- Reviewer wrong/contestable, or real but nothing downstream builds on it → park: `Task <N>: parked — <finding> — Ruling: <why the code stands>`.
- Real AND load-bearing (later tasks build on it, or it reveals a plan defect) → rule on the smallest unblocking change, ledger it, carry it into the next task's dispatch.
- Adjudicate ONLY at the cap; every adjudication is a ledger entry — silent discard is forbidden. Stop only if the defect leaves every path forward a guess.

### 3.5 Complete the task

Append `Task <N>: complete (commits <base7>..<head7>, review clean)` or `... (<K> parked)` to the ledger. Never start the next layer while Critical/Important findings are open and neither fixed nor parked-with-ruling.

## 4. Final Review

When all tasks are complete, dispatch a broad whole-branch reviewer via `invoke_subagent` (style of `requesting-code-review`): full-branch diff (`git merge-base main HEAD`..HEAD), the plan, the spec if named, and the ledger's deferred-minor + parked lines for triage.

If findings come back: dispatch ONE fix subagent with the complete list (never one fixer per finding), then exactly one scoped re-review, then adjudicate residuals with the breaker rules. No second fix wave — residual load-bearing findings surface to the user via `finishing-a-development-branch`.

## 5. Finish & Rulings

1. Present every ledger line containing `Ruling:` in order to the user as "Rulings I made".
2. Verify with `zig build test -Dskip-e2e=true` (fast) or `zig build test --summary all` (full, 13/13) before declaring done (`verification-before-completion`).
3. Delete this plan's ledger when the final review is clean; proceed via `finishing-a-development-branch`.

## 6. Operating Rules

- **Rulings, not stalls**: ambiguities, plan defects, cap situations are decided by you (spec is the binding authority); ledger every ruling.
- **Four stop conditions, only these**: an irreversible/destructive operation; a security-sensitive action; a side effect outside this worktree that the norms say to ask first about (merge, push, publish); a plan so broken every path forward is a guess. Then stop and ask the user.
- **Continuous execution**: no "should I continue?" check-ins between tasks.
- **Never fix findings in the controller session** — controller fixes skip review.

## 7. Implementer Task Template (embed into `invoke_subagent` / `batch_invoke_subagents`)

```
You are implementing Task <N>: <task name> in the repo at <repo path>.
Follow the plan exactly. No session history is available —
everything you need is below.

## Task (verbatim from the plan)
<embed the full task text: goals, files, exact values, signatures, test cases>

## Global Constraints
<embed the plan's Global Constraints verbatim>

## Context
<repo conventions: Zig 0.16.0, tests only in testcases/test_*.zig,
English comments, surgical minimal changes; earlier tasks'
interfaces; rulings that override the plan text>

## Your Job
1. Unclear requirement → status NEEDS_CONTEXT first; never guess.
   Escalate when in doubt — bad work is worse than no work.
2. Implement exactly what is specified; write tests; run
   `zig build test -Dskip-e2e=true` (full `--summary all` for core
   changes). Focused test while iterating; full suite once before commit.
3. One clear responsibility per file; if one grows beyond the plan's
   intent, report DONE_WITH_CONCERNS instead of splitting it yourself.
4. Commit in English: `module: short description`.
5. Self-review your own diff before reporting: completeness vs. spec,
   YAGNI, pristine test output; fix issues now.
6. Do NOT spawn any subagent — no helpers, no reviewers. Review is the
   controller's job, already scheduled after you report.

## Report (return under 15 lines)
- Status: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
- Commits (short SHA + subject); one-line test summary
- TDD evidence (RED/GREEN commands) if required
- Concerns, files changed
If BLOCKED/NEEDS_CONTEXT, put the exact blocker in the report.
```

## 8. Task Reviewer Template (embed into `invoke_subagent`)

```
You are reviewing Task <N> in the repo at <repo path>. Task-scoped gate,
read-only, no subagents, do not mutate the working tree.

## Task Spec
<embed the task text + Global Constraints verbatim>

## Diff Under Review
Base: <BASE>  Head: <HEAD>
Run: `git log --oneline BASE..HEAD`, `git diff --stat BASE..HEAD`,
`git diff -U10 BASE..HEAD`. Crawl outside the diff only for a concrete,
nameable risk (state it in the report).

## Implementer's Report (unverified claims — judge the code)
<embed the report; a stated rationale never downgrades a finding>
Tests already ran; only run a focused test for a specific doubt raised by
reading the code.

## Part 1: Spec Compliance
Missing / Extra / Misunderstood, each with file:line. Batched task:
every listed file must have its hunk. Unverifiable-from-diff items →
⚠️ list.

## Part 2: Code Quality
Clean separation, error handling, DRY without premature abstraction,
edge cases; tests verify real behavior, not mocks; files have one clear
responsibility. Cite file:line for every finding.

## Calibration
Critical = must fix before this task is trusted. Important = incorrect/
fragile behavior, missed requirement, merge-blocking maintainability
damage. Minor = polish. Plan-mandated defects are still findings
(label Important, plan-mandated).

## Output
### Spec Compliance: ✅ | ❌ <findings with file:line>; ⚠️ <items for the controller>
### Strengths (specific)
### Issues (Critical / Important / Minor; each: file:line, what, why, fix)
### Assessment: Task quality Approved | Needs fixes — 1-2 sentence reasoning
```

## 9. Scoped Re-Review Template (embed into `invoke_subagent`)

```
You are re-reviewing the fix round for Task <N> in <repo path>. A
previous review produced findings; an implementer fixed them. Scope:
the findings list and the fix diff ONLY. Read-only, no subagents.

## Findings to Verify (verbatim from the last review)
<embed Critical/Important findings + confirmed ⚠️ gaps>

## Diff
Base: <FIX_BASE — the head the previous review saw>  Head: <HEAD>
`git log --oneline` + `git diff -U10` over the range. Confirm the fix
report names covering tests, the command, and the output — do not
re-run the suite.

## Output
### Finding Verdicts
- <finding one-liner> — ADDRESSED | NOT ADDRESSED (file:line;
  "attempted" does not count)
### New Breakage in the Fix Diff
Critical/Important/Minor with file:line, or "None".
### Out-of-Scope Observations
Non-blocking ledger fodder only, or "None".
### Verdict
All addressed, no new Critical/Important | open findings: <list>
```
