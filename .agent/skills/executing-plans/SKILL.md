---
name: executing-plans
description: "Use when executing an implementation plan inline in the current session - task-by-task execution with a plan ledger as memory, a TDD gate per task, rulings-not-stalls with four stop conditions, and one final whole-branch review dispatched to a reviewer subagent."
---

# Executing Plans Skill

Execute the plan inline in this session, task by task: no implementer subagent per task, no reviewer per task. One fresh-context review of the whole branch at the end.

**Core principle:** The plan already did the thinking. Execute it exactly, prove each step with a test you watched fail and then pass, and keep a ledger that survives context compaction.

## 1. When to Activate This Skill?

- A plan from writing-plans is ready and the user chose inline execution.
- Tasks are mostly independent - the same precondition as subagent-driven-development.
- Prefer subagent-driven-development instead when the user wants a review gate on every task, or when the plan is long enough that its later tasks would run on a compacted context. Inline execution over a long plan still works - the ledger is what makes it recoverable - but the last tasks get the least of you.

## 2. Setup

1. **Isolated workspace.** Create or verify a git worktree via using-git-worktrees. Never start implementation on main/master without the user's explicit consent.
2. **Plan ledger (your memory).** Conversation context does not survive compaction; an executor that loses its place re-implements tasks whose commits already exist. Create the ledger as an artifact and update it in the same call as each commit - never in a call of its own:

   ```js
   mini.artifact("plan-ledger.md", "# Plan ledger - plan: <plan file path>\n");
   ```

   - If a ledger for this plan already exists, tasks with a `Task <N>: complete` line are DONE - do not redo them; resume at the first task without one. After compaction, trust the ledger and `git log` over your own recollection.
   - A ledger whose first line names a different plan file is another plan's progress: leave it and start your own, fresh.
3. **Read the plan once.** Note its context and Global Constraints. If it names a Spec, read that too: the spec is the binding authority, and conflicts inside the plan resolve against it. A plan with no reachable spec gets a ledger note saying so - rulings made without one are provisional.
4. **Pre-flight scan.** For every task that consumes what an earlier task produces, write one ledger row: the two tasks, what one produces against what the other consumes, and what you found. Rule on each conflict with the spec as authority, record the ruling beside its row. Tasks that share nothing get no row; a plan whose tasks share nothing gets the single line `Pre-flight: no shared interfaces`.
5. **Load test-driven-development now**, before Task 1. It governs every step of every task; a plan whose steps already say "write the failing test first" does not exempt you from reading it.

## 3. The Task Loop

For each task, in order. Redirect long command output (log files, tail a few lines) so it does not bloat the context.

### 3.1 Take the task

Read the task's steps from the plan - exact values, signatures, and test cases, not your summary. Note BASE, the commit the task's verification range is cut from. Never use `HEAD~1` as BASE.

### 3.2 Work the steps (TDD gate)

The steps are in RED-GREEN order; follow that order. A test step is written first and run first - watching it fail is a step, not a formality; a test that passes before the implementation exists is a finding about the test.

Every step that runs a command has an `Expected:` line. Run the command, read its output, and compare. Three outcomes:

- **Matches.** Next step.
- **The code is wrong.** Use systematic-debugging. Find the cause; never patch the symptom to make the output match.
- **The plan is wrong.** A step contradicts the spec, an interface from an earlier task does not match, or a command cannot work. Rule on the smallest change that satisfies the spec, ledger it, and continue. The ruling is carried, not remembered: later tasks that touch the same interface read it from the ledger.

Verification commands:

```js
// fast iteration (no Node mock server needed)
mini.sh("zig build test -Dskip-e2e=true");
// full gate: all steps must pass; E2E needs the mock server (Node)
mini.sh("zig build test --summary all");
```

Long builds or full test runs: run in the background and poll, instead of blocking:

```js
const j = mini.shBackground("zig build test --summary all");
// poll until finished:
console.log(mini.jobStatus(j.jobId));
console.log(mini.jobLogs(j.jobId, 30));
```

Commit as the plan's commit steps say: English, `module: short description`. A task that spans several commits is fine.

### 3.3 Rulings, not stalls

Conflicts, ambiguities, plan defects - decide them. The spec is the binding authority, the plan is its argument, and your judgment settles what neither answers. Record every decision in the ledger as:

`Task <N>: Ruling: <what you decided> - <why> - <what it costs if wrong>`

and keep going. Deviating from the plan without a ledgered ruling is a decision made in secret.

**Exactly four things stop you - stop and ask the user for these and only these:**

1. An irreversible or destructive operation.
2. A security-sensitive action.
3. A side effect outside this worktree that norms say to ask about first (a merge, a push to a shared branch, a publish).
4. A plan so broken that every path forward is a guess.

Do not pause between tasks to ask "should I continue?". The user chose inline execution to spend less; progress prompts spend their time instead.

### 3.4 Complete the task

Before the task's ledger line, all of the following are true, with evidence in this session - not inferred from the diff looking right:

- Every test the task names exists and ran in this task, and you read the output.
- The final test run for the task passed - it writes the command and result into the ledger line.
- Every `Expected:` line was compared against real output.
- Every deviation from the plan has a `Ruling:` line in the ledger.

verification-before-completion governs the claim. If any item is missing, the task is not complete: finish it.

Run the task's final test command, then - only if it passes - append to the ledger in the same call as the commit:

`Task <N>: complete (commits <base7>..<head7>, tests: <command> - <result>)`

A failing run records nothing; the task is not complete.

## 4. Final Whole-Branch Review

Dispatch ONE reviewer subagent with a fresh context - do not skip it, and do not replace it with your own read of the diff. It is the one fresh context this run buys. The task string must be fully self-contained: the subagent sees no shared history.

```js
invoke_subagent(`
Fresh-eyes code review of a whole branch.
- Repo: <absolute path>, branch <branch>, range: git merge-base main HEAD..HEAD
- Plan: <plan file path>; Spec: <spec path>
- Review Focus (verbatim from plan, if present): <the input classes and failure modes the plan's tests do not exercise - check each deliberately>
- Ledger rulings to weigh (judge these calls, do not re-litigate settled ones): <paste the Ruling: lines>
- Verify: run \`zig build test -Dskip-e2e=true\` (or \`zig build test --summary all\` when the Node mock server is available); must pass.
- Report findings as blocker/major/minor, each with evidence (file:line, command output). Do not fix anything.
`);
```

Re-grade the findings by effect before acting: a finding's grade is what a reasonable person using this software gets if it ships - not whether the spec names the input that triggers it. A reviewer who graded a finding minor because the spec was silent has graded the spec, not the effect.

- **Critical/Important** enter the fix pass. Fix them yourself in ONE pass. Each fix is verified by TDD: write the test that reproduces the finding, watch it fail, make it pass, then run the whole suite (`zig build test --summary all`, or `-Dskip-e2e=true` when E2E is unavailable). Ledger each as `Final: fixed <finding> - <test name> RED->GREEN, suite <N>/<N>`. A fix without a test that failed first is not verified; a suite that is not green after the pass means the pass is not over.
- **Minor** goes to the ledger as `Final: minor (deferred): <one-liner>` and to the final message under "Deferred minors". Minors never enter the fix pass.
- A finding you decide not to fix is a ruling: `Final: Ruling: <finding> - <why the code stands> - <cost if wrong>`. There is no second fix pass, and do not dispatch a re-review: the covering tests and the suite run already answer "addressed" and "broke nothing".

## 5. Finish

Your final message lists, exhaustively:

- **"Rulings I made"**: every ledger `Ruling:` line, in the order made, each with its cost if wrong.
- **"Deferred minors"**: every `minor (deferred)` line.

When the final review is clean and its fixes are committed, clean up this plan's ledger - the git history is the record now. Then use finishing-a-development-branch.

## 6. Anti-patterns

| Excuse | Rule |
|--------|------|
| "I remember what Task N says" | You remember a summary. The steps have the exact values. Read them. |
| "Skip watching the test fail" | A test you never saw fail proves nothing. It is one step. Run it. |
| "Run the full suite at the end only" | Per-step runs show which step broke it. The end-of-task run is the contract, not a substitute. |
| "The plan is wrong, I'll just do the right thing" | Do the right thing and ledger the ruling. Unledgered deviation is a secret decision. |
| "Write the ledger lines after a few tasks" | Compaction does not wait. One line per task, in the same call as the commit. |
| "Let me check in before the next task" | Only the four stop conditions stop you. |
| "Subagents are slow, skip the final review too" | Inline already removed the per-task reviewers. One whole-branch review is the floor. |
