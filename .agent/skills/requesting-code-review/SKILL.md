---
name: requesting-code-review
description: "Use when completing tasks, after major features, or before merging to dispatch a self-contained reviewer subagent via invoke_subagent with git diff range and build/test verification, reporting findings as blocker/major/minor."
---

# Requesting Code Review Skill

Dispatch a code reviewer subagent to catch issues before they cascade. The reviewer receives a precisely crafted, self-contained task — **never your session history**. Subagents see no shared context; every fact they need must be inlined into the task string.

**Core principle:** Review early, review often.

---

## 1. When to Activate This Skill?

**Mandatory timing:**
- After each task in subagent-driven development
- After completing a major feature
- Before merge to main

**Optional but valuable:**
- When stuck (fresh perspective)
- Before refactoring (baseline check)
- After fixing a complex bug

**Never:**
- Skip review because "it's simple"
- Ignore blocker issues, or proceed with unfixed major issues
- Argue with valid technical feedback (push back only with code/test evidence)

---

## 2. Process

### 2.1 Capture the Git Range

```js
const head = mini.sh("git rev-parse HEAD").stdout.trim();        // HEAD_SHA
const base = mini.sh("git merge-base main HEAD").stdout.trim();   // BASE_SHA (use main/master as appropriate)
console.log(base, head);
```

### 2.2 Dispatch the Reviewer

Build one self-contained task string from the template in §3. Fill every `{{...}}` placeholder:
- `{{DESCRIPTION}}` — what was implemented, 2-5 sentences.
- `{{PLAN_OR_REQUIREMENTS}}` — the spec/plan text **inlined verbatim** (subagents cannot read your session history).
- `{{BASE_SHA}}`, `{{HEAD_SHA}}` — from §2.1.

Then dispatch:

```js
invoke_subagent(task=<filled template from §3>);
```

For independent review passes, use `batch_invoke_subagents([task1, task2])` — one task per review scope.

### 2.3 Act on Findings

- **blocker** → fix immediately; do not proceed.
- **major** → fix before proceeding to the next task/merge.
- **minor** → note for later.
- Wrong finding → push back with technical reasoning or a test that proves it; the reviewer's report is input, not authority.

---

## 3. Reviewer Task Template

Copy the block below, fill all `{{...}}` placeholders, pass as the single task string to `invoke_subagent`.

```
You are a senior code reviewer for the mini-agent Zig repo (/home/mypc/projects/mini).
Review the completed work against its requirements. Your review is read-only:
inspect with `git diff`, `git show`, `git log`; never mutate the working tree.

## What Was Implemented
{{DESCRIPTION}}

## Requirements / Plan
{{PLAN_OR_REQUIREMENTS}}

## Git Range
BASE_SHA: {{BASE_SHA}}
HEAD_SHA: {{HEAD_SHA}}

Run:
  git diff --stat {{BASE_SHA}}..{{HEAD_SHA}}
  git diff {{BASE_SHA}}..{{HEAD_SHA}}
  zig build test -Dskip-e2e=true   # must pass; report any failure

## Review Checklist
- Requirements: all plan requirements met? implementation matches spec? no scope creep? breaking changes documented?
- Code quality: clean separation of concerns? proper error handling? edge cases handled? no magic values?
- Architecture: sound design? performance and security implications? integrates cleanly with surrounding code?
- Testing: tests verify real behavior (not just mocks)? edge cases covered? all tests passing?
- Production readiness: backward compatibility considered? documentation complete? no obvious bugs?
- Spec silence rule: where the spec is silent, judge by what a reasonable user would expect; grade findings by that impact.

Do all review work yourself; review large diffs in multiple passes and say so.

## Rules
- Categorize by actual severity (not everything is blocker).
- Be specific: file:line, what is wrong, why it matters, suggested fix.
- Acknowledge strengths. Give a clear verdict.
- No "looks good" without checking; no vague findings.

## Output Format
### Strengths
(What is well done — be specific)
### Issues
For each: severity (blocker / major / minor), file:line, what is wrong, why it matters, suggested fix.
- blocker: bugs, security, data loss, broken functionality (must fix)
- major: architecture problems, missing features, test gaps (fix before proceeding)
- minor: style, polish, documentation (note for later)
### Build & Test
Result of `zig build test -Dskip-e2e=true` (pass/fail summary)
### Assessment
Ready to proceed? Yes | No | With fixes — plus 1-2 sentence reasoning.
```

---

## 4. Example

```
[Completed Task 2: index verification]

git rev-parse HEAD       -> 3df7661
git merge-base main HEAD -> a7981ec

invoke_subagent(task=<template filled with DESCRIPTION="Added verifyIndex()
and repairIndex() with 4 issue types", PLAN_OR_REQUIREMENTS=<task 2 spec text
inlined>, BASE_SHA=a7981ec, HEAD_SHA=3df7661>)

[Reviewer returns]: major — missing progress indicator; minor — magic number
for reporting interval. Build & tests pass.

-> Fix the major issue, commit, continue to Task 3.
```
