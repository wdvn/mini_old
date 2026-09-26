---
name: writing-plans
description: Use when you have a spec or requirements for a multi-step task, before touching code. Produces a self-contained implementation plan as a plan.md artifact with right-sized TDD tasks, then dispatches a reviewer subagent.
---

# Writing Plans Skill

Write comprehensive implementation plans assuming the executor has zero context for the codebase. Document everything needed: which files to touch per task, code, tests, docs to check, how to verify. Give the whole plan as bite-sized tasks. DRY. YAGNI. TDD. Frequent commits.

Assume a skilled developer who knows almost nothing about the toolset or problem domain, and does not know good test design very well.

## 1. When to Activate This Skill?

- When a spec or requirements document exists for a multi-step task (>= 2 steps, architectural changes, multi-file edits).
- Before touching code, when the work needs decomposition into reviewable tasks.

## 2. Scope Check

If the spec covers multiple independent subsystems, it should have been broken into sub-project specs during brainstorming. If it was not, suggest breaking it into separate plans — one per subsystem. Each plan must produce working, testable software on its own.

## 3. File Structure Mapping

Before defining tasks, map which files will be created or modified and what each one is responsible for. This is where decomposition decisions get locked in.

- Design units with clear boundaries and well-defined interfaces. One clear responsibility per file.
- Reasoning and edits are more reliable when files are focused. Prefer smaller, focused files over large ones that do too much.
- Files that change together should live together. Split by responsibility, not by technical layer.
- In existing codebases, follow established patterns. If the codebase uses large files, do not unilaterally restructure — but if a file being modified has grown unwieldy, including a split in the plan is reasonable.

This structure informs the task decomposition. Each task should produce self-contained changes that make sense independently.

## 4. Task Right-Sizing

A task is the smallest unit that carries its own test cycle and is worth a fresh reviewer's gate. When drawing task boundaries:

- Fold setup, configuration, scaffolding, and documentation steps into the task whose deliverable needs them.
- Split only where a reviewer could meaningfully reject one task while approving its neighbor.
- Each task ends with an independently testable deliverable.

**Bite-sized step granularity — each step is one action (2-5 minutes):**
- "Write the failing test" — step
- "Run it to make sure it fails" — step
- "Implement the minimal code to make the test pass" — step
- "Run the tests and make sure they pass" — step
- "Commit" — step

## 5. Plan Document Format

Save the plan via `artifact_write` as `plan.md` (user preference for another location overrides this). Every plan starts with this header:

```markdown
# [Feature Name] Implementation Plan

**Goal:** [one sentence describing what this builds]

**Architecture:** [2-3 sentences about the approach]

**Tech Stack:** [key technologies/libraries]

**Spec:** [path to the spec/design doc this plan implements — the plan argues
from the spec, so the spec travels with it; executors read both]

## Global Constraints

[Project-wide requirements from the spec — version floors, dependency limits,
naming rules, platform requirements — one line each, exact values copied
verbatim. Every task's requirements implicitly include this section.]

## Review Focus

[The five input classes or failure modes the spec implies but no task's tests
exercise, most likely to bite first — one line each, naming the input and the
behavior a reasonable user would expect. Add the test pinning each line to the
task that owns the code.]
```

## 6. Task Structure

```markdown
### Task N: [Component Name]

**Files:**
- Create: `exact/path/to/file`
- Modify: `exact/path/to/existing:123-145`
- Test: `tests/exact/path/to/test`

**Interfaces:**
- Consumes: [what this task uses from earlier tasks — exact signatures]
- Produces: [what later tasks rely on — exact names, parameter and return
  types. A task's executor sees only their own task; this block is how they
  learn the names and types neighboring tasks use.]

- [ ] **Step 1: Write the failing test** (code block)
- [ ] **Step 2: Run test to verify it fails** — command, expected: FAIL
- [ ] **Step 3: Write minimal implementation** (code block)
- [ ] **Step 4: Run test to verify it passes** — command, expected: PASS
- [ ] **Step 5: Commit** — `git add ... && git commit -m "module: description"`
```

Steps use checkbox (`- [ ]`) syntax for progress tracking.

## 7. No Placeholders

Every step must contain the actual content the executor needs. These are plan failures — never write them:

- "TBD", "TODO", "implement later", "fill in details"
- "Add appropriate error handling" / "add validation" / "handle edge cases"
- "Write tests for the above" (without actual test code)
- "Similar to Task N" (repeat the content — the executor may read tasks out of order)
- Steps that describe what to do without showing how (code blocks required for code steps)
- References to types, functions, or methods not defined in any task

## 8. Self-Review (before dispatching the reviewer)

After writing the complete plan, check it against the spec with fresh eyes. This is a checklist you run yourself:

1. **Spec coverage:** Skim each spec section/requirement. Can you point to a task that implements it? List gaps; add missing tasks.
2. **Placeholder scan:** Search the plan for the red flags from §7. Fix them.
3. **Type consistency:** Do names and signatures used in later tasks match those defined in earlier tasks? A function called `clearLayers()` in Task 3 but `clearFullLayers()` in Task 7 is a bug.
4. **Review Focus:** For each implied input class or failure mode, is there a task whose tests exercise it? An empty Review Focus section means you checked and found none, not that you skipped the check.

Fix issues inline; no need to re-review.

## 9. Plan Reviewer Dispatch

After self-review, dispatch a reviewer via `invoke_subagent` with a fully self-contained task (the subagent sees no shared context):

```
You are a plan document reviewer. Verify this plan is complete and ready for
implementation.

PLAN TO REVIEW: <paste full plan.md content here>
SPEC FOR REFERENCE: <paste spec, or its path + relevant sections>

Check:
- Completeness: TODOs, placeholders, incomplete tasks, missing steps
- Spec alignment: plan covers spec requirements, no major scope creep
- Task decomposition: clear boundaries, actionable steps
- Buildability: could an executor follow this plan without getting stuck?

Calibration: only flag issues that would cause real problems during
implementation. An executor building the wrong thing or getting stuck is an
issue; wording preferences and "nice to have" suggestions are not. Approve
unless there are serious gaps — missing spec requirements, contradictory
steps, placeholder content, or tasks too vague to act on.

Return:
## Plan Review
Status: Approved | Issues Found
Issues (if any): [Task X, Step Y]: [issue] - [why it matters]
Recommendations (advisory, do not block): [suggestions]
```

Apply blocking issues to the plan, re-run §8 if changed, then proceed to handoff.

## 10. Execution Handoff

Present the plan to the user. If they already supplied an execution method, ask them to confirm the plan captures what they want; wait before implementing. Otherwise, ask them to choose:

- **Subagent-driven** — a fresh subagent implements each task, a fresh reviewer checks it before the next, whole-branch review at the end (skill: `subagent-driven-development`). Most thorough; costs fresh context per task.
- **Native** — implement every task in this session, then one fresh reviewer on the whole branch (skill: `executing-plans`). Cheapest and fastest; no independent review until the end.

Recommend one, in one sentence, based on how much the tasks depend on each other's interfaces, how many there are, and what a shipped mistake would cost.

## 11. Mini-project Adaptation

For the mini-agent repo (Zig, /home/mypc/projects/mini):

- Tests live only in `testcases/test_*.zig` (never in the root directory).
- The TDD cycle per task becomes:
  1. Write the failing testcase file: `testcases/test_<feature>.zig`
  2. Run: `mini.sh("zig build test -Dskip-e2e=true")` — expect FAIL
  3. Implement minimal code
  4. Run: `mini.sh("zig build test -Dskip-e2e=true")` — expect PASS
  5. `mini.sh("git add ... && git commit -m \"module: short description\"")`
- Verify with `zig build test -Dskip-e2e=true` (faster than the full suite; E2E needs a Node mock server). For core/tools/runtime changes, additionally require `zig build test --summary all` to pass 13/13.
- Follow the 3-step code workflow from AGENTS.md: pseudocode first, verify Zig API against `src/` before implementing, minimal surgical edits, English comments.
