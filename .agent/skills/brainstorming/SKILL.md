---
name: brainstorming
description: "Use when creating features, building components, adding functionality, or modifying behavior, before any implementation. Explores user intent, requirements, and design via path classification (spike/bounded/architectural), hard approval gates, and a spec review step."
---

# Brainstorming Skill

Turn an idea into a validated design before implementation. Core rule: **no implementation action until the selected path's approval gate passes.**

## 1. When to Activate This Skill?
- Before creating a feature, building a component, adding functionality, or modifying behavior.
- When the request describes a new project/subsystem, an interface change, or a feasibility question.
- When scope or purpose is ambiguous.

## 2. Step 0: Establish Shared Understanding
1. **Discover intent** — intended outcome, who it is for, what success looks like. If missing, ask one focused question about purpose before proposing features or an approach.
2. **Write back understanding** — a short note separating what the user said from your assumptions; invite correction before treating it as the design brief.
3. **Carry intent into the artifact** — check every proposed feature and technical choice against the agreed understanding.
- If the request already supplies purpose and constraints, reflect that understanding instead of re-asking.

## 3. Classify the Path (say it out loud so the user can override)
- **Spike** — a feasibility question ("can we...", "is it possible...", "quick and dirty is fine"); the output is an answer, not code you keep.
- **Bounded** — a well-scoped change to code that already exists in the repo; the flow you are changing is already there to read. If there is no existing flow to change, the task is not bounded.
- **Architectural** — new projects, new subsystems, changes that restructure how components fit together or alter interfaces others depend on.

Rules:
- When in doubt between two paths, take the heavier one.
- The ratchet is one-way: hidden complexity discovered mid-task upgrades the path — stop, say so, and step up. Nothing downgrades mid-task.
- If a request spans multiple independent subsystems, flag it immediately and decompose into sub-projects first (independent pieces, relations, build order). Brainstorm the first sub-project; each sub-project gets its own spec → plan → implementation cycle.

## 4. Hard Gate — Before Any Implementation Action
Before writing product code, scaffolding, installing product dependencies, creating an external project, or invoking an implementation skill:
- **Spike**: the user approves the question and probe.
- **Bounded**: the user approves the short in-chat design.
- **Architectural**: the user reviews and approves the written spec, then reviews the written implementation plan and selects its execution method.

Stage-bound rules:
- A reply approves the stage actually presented. Approving an idea or scope does not approve artifacts that do not exist yet.
- Resume at the earliest incomplete stage; never turn one approval into permission to skip the rest.
- Read-only project exploration is allowed while prerequisites remain incomplete.
- A bounded task's approval is as hard a gate as an architectural one.

## 5. Path Checklists
**Spike:**
1. Explore project context — enough to frame the probe.
2. Present the question + probe plan in 2-3 sentences.
3. Get approval — a yes is enough.
4. Investigate — as cheaply as correctness allows.
5. Report findings — a recommendation; anything built stays labeled throwaway.

**Bounded:**
1. Explore project context — files, docs, recent commits.
2. Ask clarifying questions — one at a time, the ones that matter.
3. Present a short in-chat design — approach, files touched, testing.
4. **STOP and wait for an explicit yes** — presenting the design and starting in the same turn skips the gate.
5. Implement — proceed with the normal development workflow (test-driven-development applies); no plan document.

**Architectural:**
1. Explore project context — files, docs, recent commits.
2. Ask clarifying questions — one at a time: purpose, constraints, success criteria.
3. Propose 2-3 approaches — with trade-offs; lead with your recommendation and why; apply YAGNI ruthlessly.
4. Present the design — sections scaled to complexity (a few sentences if straightforward, up to 200-300 words if nuanced); cover architecture, components, data flow, error handling, testing; ask after each section whether it looks right.
5. Write the spec (§6). 6. Spec self-review (§7). 7. Spec review subagent (§8). 8. User review gate (§9). 9. Transition — invoke the writing-plans skill.

## 6. Write the Spec
- Output the spec via `artifact_write` (type `markdown`, `user_facing: true`), named `spec-<topic>.md`.
- In the mini repo, also save it under `docs/` as `rfc_NNN_<topic>_proposal.md` (next sequential RFC number) and commit: `mini.sh("git add docs/ && git commit -m 'docs: add <topic> proposal'")`.
- Content: the agreed understanding from §2, the chosen approach with trade-offs, the sectioned design, and success criteria.

## 7. Spec Self-Review (fresh eyes, fix inline)
1. **Placeholder scan** — any TBD/TODO/incomplete section/vague requirement? Fix them.
2. **Internal consistency** — do sections contradict each other? Does the architecture match the feature descriptions?
3. **Scope check** — focused enough for a single implementation plan, or does it need decomposition?
4. **Ambiguity check** — could any requirement be read two ways? Pick one and make it explicit.

Fix issues inline. No re-review loop — fix and move on.

## 8. Spec Review Subagent
Dispatch a reviewer with `invoke_subagent(task)` using a fully self-contained prompt (the subagent sees no shared history):

```
You are a spec document reviewer. Read the spec at <ABSOLUTE PATH TO SPEC>.
Check:
1. Completeness — no TODO/TBD/placeholder/incomplete sections.
2. Consistency — no internal contradictions or conflicting requirements.
3. Clarity — no requirement ambiguous enough to cause building the wrong thing.
4. Scope — focused for a single plan, not covering multiple independent subsystems.
5. YAGNI — no unrequested features or over-engineering.
Calibration: flag only issues that would cause real problems during implementation planning.
Approve unless there are serious gaps.
Return exactly:
## Spec Review
**Status:** Approved | Issues Found
**Issues:** [Section X: specific issue - why it matters for planning]
**Recommendations:** (advisory, do not block approval)
```

- Blocking issues → fix inline in the spec, re-dispatch the reviewer once.
- Recommendations are advisory — the user decides.

## 9. User Review Gate
After the review loop passes, ask the user:
> "Spec written and saved to `<path>`. Please review it and tell me if you want changes before we write the implementation plan."

Wait for the response. If changes are requested, make them and re-run §7-§8. Proceed only once the user approves.

## 10. Design Principles
- **Isolation and clarity** — break the system into units with one clear purpose, well-defined interfaces, independently understandable and testable. For each unit you can answer: what does it do, how do you use it, what does it depend on.
- **Existing codebases** — explore the current structure before proposing changes; follow existing patterns. Include targeted improvements only where existing problems affect the work (oversized files, unclear boundaries, tangled responsibilities). No unrelated refactoring.

## 11. Red Flags
| Thought | Reality |
|---------|---------|
| "This is too simple to need a design" | Follow the selected path: bounded gets a short chat design; architectural gets the spec. |
| "I'll call it bounded and skip the spec" | Reaching for a label to skip work IS the doubt — take the heavier path. |
| "The design is obvious — I'll start while the user reads it" | The gate is the approval, not the design's length. Present, then stop. |
| "I understand this kind of app, so it's bounded" | Bounded measures the repo, not your familiarity. No existing flow = architectural. |
| "The spike worked, so I'll keep the code" | A spike's output is an answer. Keeping the code is a new request — classify it. |
| "The user approved the spike, so the follow-up is approved too" | Each task gets its own classification and its own approval. |

## 12. Terminal States
- **Spike** — a reported recommendation; throwaway code is not kept.
- **Bounded** — implement directly via the normal development workflow; no plan document.
- **Architectural** — the ONLY skill invoked after brainstorming is writing-plans; never invoke another implementation skill.
