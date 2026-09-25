# RFC-024: AI Plan Framework — Superpowers-Grade Methodology on Top of RFC-019

**Status**: Proposed
**Date**: 2026-09-25
**Author**: mini-agent team
**Related**: RFC-019 (Structured Planning), RFC-020 (Semantic Advisory Enforcement), RFC-022 (Watchdog False-Positive Elimination), RFC-023 (End-Turn Completion Semantics)
**Supersedes**: None
**External reference**: [obra/superpowers](https://github.com/obra/superpowers) — composable skills + mandatory workflow methodology (brainstorming → worktree → writing-plans → subagent-driven-development → TDD → code review → branch finishing)

---

## 1. Executive Summary

mini already ships a substantial planning substrate (RFC-019): a DAG plan model with dependency
resolution, JSON/Markdown parsing, drift monitoring, CAS-based cross-turn persistence, plan
rendering in the REPL, a skills system, and parallel subagent dispatch. What mini does **not**
have is a **plan framework** — the layer that turns a parsed plan into a disciplined
engineering process: verified task boundaries, user sign-off before mutation,
compaction-resistant context re-injection, per-step review gates, and skill-driven orchestration.

Superpowers fills exactly that layer, but with two properties that don't transfer directly:
it is **prompt-only** (skills are Markdown read by the LLM; enforcement is social, via
`using-superpowers` bootstrap text) and it targets **Claude-family harnesses** that already
have SessionStart hooks, worktrees, and subagent tooling.

This RFC proposes a hybrid: keep mini's **hard, compiled enforcement** (drift monitor,
watchdog, event sourcing) and layer Superpowers' **methodology semantics** on top, native where
possible:

1. **Verification-gated plan steps** — a step is not "completed" when its hint tool ran, but
   when an explicit verification (test/build command, expected file state) passes.
2. **Plan approval gate** — plans are *proposed*, not auto-executed; user sign-off is a
   first-class state (`proposed → approved`), with `/plan` REPL control.
3. **Compaction-resilient plan context** — after `compactMemAct`, the active plan and
   in-use skills are re-injected into history (Superpowers' Pi extension does the same for its
   bootstrap).
4. **Step-scoped subagent orchestration** — plan steps can be dispatched to subagents
   (single or parallel), each followed by a two-stage review gate, reusing the existing
   `invoke_subagent` / `batch_invoke_subagents` tools.
5. **Methodology telemetry** — journal events + `session_diagnostics` metrics to measure plan
   completion accuracy, gate compliance, and skill usage (closes the RFC-020 "zero telemetry"
   gap for the plan path specifically).
6. **Explicit fallback semantics** — normative definition of behavior when planning is off,
   when no plan was parsed, and when a plan is unapproved (§3.6), so "opt-in" is provable,
   not assumed.

---

## 2. Current State — What mini Already Has (Evidence)

### 2.1 RFC-019 structured planning (implemented)

| Component | File | Evidence |
|---|---|---|
| Plan data model (DAG, `StepStatus`, `PlanDrift`) | `src/core/plan.zig` (747 lines) | `PlanStep { id, description, dependencies, tool_hint, estimated_acts, ... }`; `Plan.findActiveStepIndex()` (L254), `Plan.isComplete()` (L267), custom JSON (de)serialization |
| Plan parser (JSON + Markdown fallback) | `src/core/plan_parser.zig` (561 lines) | `extractStructuredPlan()` fenced-JSON then numbered-list fallback; validates `tool_hint` against registry |
| Step executor + progress | `src/core/plan_executor.zig` (387 lines) | `executePlanStep()` (dependency check), `completeStep`/`failStep`/`skipStep`, `generateProgressSummary()`, `getProgressPercent()` |
| Drift monitor | `src/core/plan_monitor.zig` (286 lines) | `checkPlanDrift()`, `calculateDriftScore()` (0.3 same category / 0.8 cross-category), `generateDriftCorrection()` |
| CAS persistence | `src/core/plan_store.zig` (309 lines) | `save()`/`restore(request_hash)` via Content-Addressed Store + `metadata.jsonl`; `listPlans()` |
| Orchestration state | `src/core/plan_integration.zig` | `PlanState` (legacy watchdog + RFC-019 fields consolidated); `setStructuredPlan()` + `renderPlanDisplay()` writes full plan to the active `TurnRenderer`; `tryRestoreFromStore()` called at turn start (`agent_turn.zig:95`) |
| Auto completion detection | `src/core/agent.zig:1455-1478` | after each tool act: if executed tool == `tool_hint` of active step → `completeStep()`; when `is_complete` → `plan_store.save()` + `clearPlan()` |
| Prompt-side planning modes | `src/core/prompts.zig` | "ReAct Mode (Default)" vs "Proactive Planning Mode (RFC-019)" with JSON plan template; `plan_replan_suggestion_fmt`, `plan_drift_significant`, `plan_step_enforcement_head` |
| REPL control | `src/ui/repl.zig:249, 335-346` | `/plan on\|off\|status` toggles `enable_structured_planning` |
| Config | `src/core/config.zig:240-253` | `enable_structured_planning` (default **true**), `plan_drift_detection`, `plan_max_steps` (20), `plans_dir`, `enhanced_progress_checkpoint`, `prompt_enforcement_enabled` (default **false**) |

### 2.2 Skills system (subset of Superpowers, prompt-based)

- `src/core/skills.zig` (343 lines): scans `~/.mini/skills/` then `.agent/skills/` (project
  overrides global), parses YAML frontmatter (`name` + `description`), caps at 32 skills /
  512-byte descriptions; `buildSkillsBlock()` injects name + description + **file path** into
  the system prompt; the agent is instructed to `mini.read` the SKILL.md when triggered
  (`prompts.zig:141` `skills_guidance_header`).
- 13 Superpowers-derived skills are already installed at `~/.mini/skills/`
  (`brainstorming`, `writing-plans`, `executing-plans`, `subagent-driven-development`,
  `test-driven-development`, `systematic-debugging`, `requesting-code-review`,
  `receiving-code-review`, `verification-before-completion`, `using-git-worktrees`,
  `finishing-a-development-branch`, `writing-skills`, `using-superpowers`).
- A `skills` tool (`registry.zig`) exposes `list`/`detail` operations to the LLM.

**Key property**: skills are *passive reference material*. Nothing forces the agent to check
them before acting; the "mandatory invocation" rule that Superpowers gets from its
`using-superpowers` bootstrap is, in mini, a one-paragraph prompt instruction that
compaction silently destroys (see §3.3).

### 2.3 Subagents & parallelism

- `src/tools/subagent.zig`: `invoke_subagent` spawns `/proc/self/exe -e <task>` with
  parent-death-guarded process groups, streams child output to stderr, depth-limited
  (`MINI_MAX_SUBAGENT_DEPTH`, default 2).
- `src/tools/batch_subagent.zig`: `batch_invoke_subagents` runs N subagent tasks on parallel
  threads with per-task result collection.
- `session_diagnostics` tool: inspect/kill running agent + subagent processes.

**Key property**: subagent tasks are free-form strings. There is no coupling between plan
steps and subagent dispatch, and no review gate after a subagent returns.

### 2.4 Context lifecycle

- `src/core/history.zig:363` `compactMemAct()`: reactive-only; preserves `msgs[0]`
  (original prompt), inserts/ replaces a `.summarized` message at index 1, **drops all
  messages from index 1+**.
- No post-compaction re-injection of anything: active plan text, loaded-skill state, and
  "task reminder" context are all lost from the model's window (the plan object itself
  survives in `PlanState`/CAS, but the model no longer *sees* it).
- Plan/progress checkpoint text is only injected when
  `config.prompt_enforcement_enabled` is true — **off by default**
  (`config.zig:252`), so in default configuration the enhanced RFC-019 progress block and
  drift advisories never reach the model.

### 2.5 Artifacts & hooks

- `src/core/artifacts.zig`: session-scoped artifact store with live-preview event hooks and
  `@artifact:<name>` bidirectional references.
- `src/core/hooks.zig`: pre-prompt / post-response / pre-tool-use / post-tool-use + streaming
  + MCP hooks (single global command or listener).
- **No `SessionStart` hook and no post-compaction hook** exist today (verified: no
  `session_start`/`post_compact` symbols in `src/`).

### 2.6 Methodology gaps, Superpowers-feature by Superpowers-feature

| Superpowers feature | mini status | Verdict |
|---|---|---|
| `brainstorming` (design refinement before code) | Skill file exists; nothing forces it | Passive |
| `using-git-worktrees` (isolation) | Skill file exists; no native worktree support | Passive |
| `writing-plans` (bite-sized tasks, exact files, **verification per task**) | PlanStep has `tool_hint` + `estimated_acts` but **no verification/acceptance field** | Partial |
| `subagent-driven-development` (fresh subagent per task + two-stage review: spec compliance, then code quality) | `invoke_subagent`/`batch_invoke_subagents` exist; **no plan-step coupling, no post-execution review gate** | Gap |
| `test-driven-development` (RED-GREEN-REFACTOR, "delete code written before tests") | Skill file exists; no enforcement | Passive |
| `requesting-code-review` (severity-tagged review; Critical blocks) | Skill file exists; no review tooling on the plan path | Passive |
| `verification-before-completion` (evidence before "done") | RFC-023 handles *empty* end_turn; but step completion is decided by **tool_hint match only** (`agent.zig:1460`) | Gap |
| `using-superpowers` bootstrap (skill check before ANY response) | `skills_guidance_header` prompt paragraph only; lost on compaction | Gap |
| Post-compaction bootstrap re-injection (Pi extension) | **None** — `compactMemAct` drops everything after index 0/1 | Gap |
| User sign-off on design/plan before autonomous execution | Plan auto-executes on parse; `/plan` only toggles the feature | Gap |
| `diagnosing-superpowers` (session RCA with evidence) | `session_diagnostics` tool + journal + act logs — **covered** | ✅ Has better infra |
| `dispatching-parallel-agents` | `batch_invoke_subagents` — **covered** | ✅ |

### 2.7 Dead / under-wired code

- `planning_min_task_length` (`config.zig:243`) is parsed, defaulted, and exported to env but
  **referenced nowhere** in agent logic — planning trigger is LLM-driven (prompt §Proactive
  Planning Mode) plus `tryDetectPlanInResponse`, not length-based.
- `enhanced_progress_checkpoint` (`config.zig:251`) is read into config but the progress
  block builder gates on `prompt_enforcement_enabled` instead — two config keys describing
  one behavior.
- Plan steps have `estimated_acts` / `actual_acts` accounting fields that are never updated in
  the execution path.

---

## 3. Proposed Design

Design principle: **Superpowers semantics, mini's enforcement style.** Where Superpowers
uses prompt pressure ("you MUST invoke the skill"), mini hard-enforces in Zig (parser,
gates, journal events) and keeps prompt pressure only where the LLM's judgment is the
signal. All phases opt-in behind new config flags; default behavior for existing users is
unchanged except flag (5) telemetry, which is inert.

### 3.1 Phase 1 — Verification-gated plan steps

Add to `PlanStep` (`src/core/plan.zig`):

```zig
/// Optional acceptance check. A step is "completed" only when this passes.
verification: ?StepVerification = null,

pub const StepVerification = struct {
    kind: enum { shell, file_exists, file_contains },
    /// shell: command to run (must exit 0). file_exists: path. file_contains: {path, pattern}.
    value: []const u8,
};
```

- `plan_parser.zig`: accept optional `"verification": {"shell": "zig build test"}` or
  string shorthand (`"verification": "zig build test"`).
- `plan_executor.zig`: new `verifyStep(plan, step) bool` — runs the check through the
  existing `registry` (`bash` / `file_read` paths), records result into step.
- **Completion rule change** (`agent.zig:1455-1478`): step auto-complete on `tool_hint`
  match becomes **necessary-not-sufficient** — the step moves to `active → verifying`,
  and only a passing `verifyStep()` transitions to `.completed`. Without `verification`,
  current behavior is unchanged (backward compatible).
- Drift monitor (`plan_monitor.zig`): a failed verification now counts as a
  `PlanDrift` with a dedicated `verification_failed` classification feeding
  `plan_replan_suggestion_fmt` (REALIGN / REPLAN / CONCLUDE), closing the loop with
  RFC-022's completion semantics.

Superpowers parallel: *writing-plans* "every task has verification steps" +
*verification-before-completion* "evidence before assertions".

### 3.2 Phase 2 — Plan approval gate

New plan lifecycle state in `plan.zig`:

```zig
pub const PlanPhase = enum { proposed, approved, executing, complete, rejected };
```

- `tryDetectPlanInResponse` sets phase `proposed`; `renderPlanDisplay()` shows
  `[proposed — run `/plan approve`]` instead of silently executing.
- Execution path (`agent_step.zig` / `agent.zig` act dispatch): plan steps are only
  injected as guidance when phase == `approved`; before that the model may still explore
  (read-only tools), but mutating tools carry an advisory: "plan is proposed, not
  approved — call `/plan approve` or execute the next step as user confirmation".
- REPL: extend `/plan` with `approve | reject | status | list` (`repl.zig`, backed by
  `plan_store.listPlans()`).
- `plan_store` persists `PlanPhase`, so a restore across sessions revives a plan in
  `proposed` state, not auto-executing.

Superpowers parallel: "After you've signed off on the design … once you say 'go', it
launches subagent-driven-development".

### 3.3 Phase 3 — Compaction-resilient plan & skill context

- New hook event in `hooks.zig`: `post_compact` (dispatched from
  `agent.zig:compactContext()` after `compactMemAct` succeeds).
- `agent.zig`: on compaction, append a synthetic `.summarized`-tier context block at
  index 2 containing: (a) active plan render (reuse `plan_executor.generateProgressSummary`),
  (b) names + paths of skills already read this session (tracked via a small
  `skill_loaded` journal event list), (c) original user request (`msgs[0]` already preserved
  — restate as task reminder, cf. `pg_task_reminder_fmt`).
- This mirrors Superpowers' Pi extension behavior ("injects the bootstrap at session
  startup and again after compaction") and revives the `using-superpowers` "check for
  relevant skills before any action" rule that compaction today silently kills.
- Also re-inject the `skills_guidance_header` list — today it lives only in `msgs[0]`,
  which *is* preserved, but only for the default system prompt; `MINI_SYSTEM_FILE` users
  and subagent one-shot runs have different index-0 shapes, so the block is rebuilt from
  `skills.getSkills()` at compaction time.

### 3.4 Phase 4 — Step-scoped subagent orchestration + review gates

New optional plan-step field:

```zig
/// "inline" (default) | "subagent" | "parallel:<batch>"
executor_mode: ?[]const u8 = null,
```

- `plan_executor.zig` new `dispatchStep(plan, step, ctx)`: renders a self-contained task
  string (step description + dependencies' results + verification + relevant skill paths +
  2-hop pgraph guidance) and calls the existing `subagent.executeTool` /
  `batch_subagent.executeTool` — no new process machinery.
- **Two-stage review gate** (Superpowers `subagent-driven-development`): after a
  subagent-executed step, before `verifyStep()`, spawn a reviewer subagent with the
  `requesting-code-review` skill content embedded: stage 1 spec-compliance (did it do what
  the step description says), stage 2 code quality. Review verdicts are journal events
  (`review_outcome`, with Critical/Important/Minor severity, Critical → step `failed`).
- `batch_invoke_subagents` mapping: independent steps (no dependency edge between them)
  can be auto-batched in one `parallel` dispatch; this is the plan-aware upgrade of
  Superpowers' `dispatching-parallel-agents`.

All off by default: `plan_subagent_dispatch = false`, `plan_review_gate = false`.

### 3.5 Phase 5 — Methodology telemetry & cleanup

New `ActEventType`s in `journal.zig`: `plan_phase_changed`, `plan_step_verified`,
`plan_review_outcome`, `skill_loaded`, `post_compact_reinject`.

- Extend `session_diagnostics` `detail` view with a "Plan methodology" section: phase
  history, step pass/fail/verify stats, review verdicts, skill-usage counts — the
  plan-path half of RFC-020's telemetry requirement.
- `PlanMetrics` from RFC-019 §19 becomes real: computed from journal events, surfaced via
  `session_diagnostics`.
- **Cleanup**: wire or delete `planning_min_task_length` (recommend: delete; trigger is
  semantic/LLM-driven per prompt); collapse `enhanced_progress_checkpoint` into
  `prompt_enforcement_enabled` (one key, one behavior); start updating
  `actual_acts` counters in the completion path so `estimated_acts` accounting works.

### 3.6 Plan Mode Off / No Active Plan — Explicit Fallback Semantics

The RFC must state precisely what happens when planning is *not* active, because today this
is underspecified: `enable_structured_planning` defaults **true** but only *enables* the
parser/monitor; whether a plan actually exists depends on the LLM emitting a parseable plan
in a response. There are four distinct states, each with defined behavior under this RFC.

**State A — `enable_structured_planning = false` (feature fully off):**
- `tryDetectPlanInResponse` falls to the legacy `detectPlanInText` string-matching path
  (160-byte summary), exactly as today. No `StepVerification`, no phase gate, no
  reinjection, no subagent dispatch. All RFC-024 features are inert.
- Drift monitor and progress checkpoint behave per current `prompt_enforcement_enabled`.
- *Guarantee*: turning the flag off is a true no-op for RFC-024 — zero behavior change.

**State B — Feature on, but no structured plan was parsed for the current task:**
- The model is in **ReAct mode** (default). It may freely explore and act; there is no
  `PlanPhase`, no verification gate, no approval gate, no review gate — none of §3.1–§3.4
  machinery has a plan object to attach to, so none of it fires.
- **Post-compaction reinjection (§3.3) still applies** but degrades gracefully: if there is
  no active plan, the index-2 block contains only the read-skill names + task reminder
  (`msgs[0]` restated), *not* a plan summary. This is the only RFC-024 behavior that runs
  without a plan, and it is a pure information add (cannot suppress existing flow).
- Telemetry (§3.5) records `skill_loaded` and `post_compact_reinject` events regardless of
  plan state.

**State C — Feature on, a structured plan was parsed, but user has not approved it
  (Phase 2 gate, §3.2), and `plan_approval_gate = true`:**
- Plan sits in `proposed`. Read-only / exploration tools work normally (no plan context
  is *subtracted* from the model — nothing is hidden, the plan is simply not yet binding).
- Mutating tools are **not blocked**; the model receives an advisory ("plan is proposed,
  not approved — approve or proceed with explicit user confirmation"). This is a *soft*
  gate consistent with RFC-020's "guidance, not hard block" for the advisory path; a hard
  block is out of scope (see §8).
- No verification/review gates run (no step is `active` yet).

**State D — Feature on, plan is `approved`/`executing` (normal RFC-019 + RFC-024 flow):**
- All of §3.1/§3.4 apply per-step. This is the only state where step-level gates are live.

**What is explicitly NOT done:**
- No global "plan mode" toggle that changes ReAct-loop semantics. Planning stays an
  *opt-in per-task artifact* (the LLM decides when to emit one), not a separate REPL mode.
  The existing `/plan on|off` toggle controls *feature enablement* (State A vs B–D), never
  *task-level* planning decisions.
- No behavior change for subagents (`utils.isSubagent()`): subagents inherit
  `enable_structured_planning` but never get approval gates or review gates
  (review gates only attach to the *parent's* plan steps; a subagent executing a
  dispatched step reports back, it does not self-gate).

This section is normative: implementers must preserve State A/B no-ops and only add
behavior in States C/D.

---

## 4. Configuration (additions to `src/core/config.zig`)

```zig
// RFC-024: AI Plan Framework
/// Gate plan step completion on explicit verification. Default: false.
plan_verification_gate: bool = false,
/// Require user approval before executing a parsed plan. Default: false.
plan_approval_gate: bool = false,
/// Re-inject plan + skill + task context after MemAct compaction. Default: true.
post_compact_reinject: bool = true,
/// Dispatch plan steps to subagents (per-step or auto-parallel for independent steps). Default: false.
plan_subagent_dispatch: bool = false,
/// Two-stage review gate after subagent-executed steps. Default: false.
plan_review_gate: bool = false,
```

Backward compatibility: every new gate defaults off except `post_compact_reinject`
(which only adds a message and cannot break existing flows — it re-emits information the
model already had before compaction).

---

## 5. Files Modified / Created

| File | Change |
|---|---|
| `src/core/plan.zig` | `StepVerification`, `PlanPhase`, `executor_mode` fields + JSON (de)serialization + `verifyStep()` storage |
| `src/core/plan_parser.zig` | parse `verification` / `executor_mode` / `phase` |
| `src/core/plan_executor.zig` | `verifyStep()`, `dispatchStep()` |
| `src/core/plan_monitor.zig` | `verification_failed` drift classification |
| `src/core/plan_integration.zig` | phase-aware `renderPlanDisplay()`, approval-state gating, skill-read tracking |
| `src/core/plan_store.zig` | persist `PlanPhase`, `verification` results |
| `src/core/agent.zig` | completion rule (hint-match → verifying → verified), `post_compact` dispatch, reinject block builder |
| `src/core/agent_step.zig` | guidance injection gated on `approved` phase |
| `src/core/hooks.zig` | `post_compact` event |
| `src/core/journal.zig` | new event types |
| `src/core/config.zig` | 5 new flags; delete/collapse dead keys (§3.5) |
| `src/ui/repl.zig` | `/plan approve\|reject\|status\|list` |
| `src/tools/review_subagent.zig` (new) | two-stage reviewer dispatch (wraps `subagent.zig`, embeds `requesting-code-review` skill text) |
| `src/tools/session_diagnostics.zig` | plan-methodology section in `detail` |
| `testcases/test_plan_verification.zig` (new) | verifyStep pass/fail, completion rule, gate interactions |
| `testcases/test_plan_approval.zig` (new) | phase transitions, restore-in-proposed, REPL `/plan approve` |
| `testcases/test_post_compact_reinject.zig` (new) | block composition after `compactMemAct`, skill dedupe |
| `testcases/test_plan_subagent_dispatch.zig` (new) | step→task rendering, parallel batching of independent steps, review gate verdicts |

---

## 6. Implementation Phases

| Phase | Content | Effort |
|---|---|---|
| 1 | Verification gate (§3.1) + journal events for it | 2–3 days |
| 2 | Approval gate + `/plan` REPL + store persistence (§3.2) | 2–3 days |
| 3 | Post-compaction reinjection (§3.3) | 1–2 days |
| 4 | Step-scoped subagent dispatch + review gates (§3.4) | 4–6 days |
| 5 | Telemetry, `session_diagnostics` section, dead-config cleanup (§3.5) | 2 days |

Total: ~11–16 days. Phases 1–3 are independent and landable in that order; Phase 4 depends
on 1+2 (review gate consumes verification results and approval state).

---

## 7. Success Metrics

```zig
const PlanMethodologyMetrics = struct {
    plans_proposed: usize,
    plans_approved: usize,          // approval rate = approved / proposed
    steps_verification_pass_rate: f64,
    review_critical_blocked: usize,
    reinjects_after_compaction: usize,
    subagent_steps_dispatched: usize,
    subagent_steps_reviewed: usize,
};
```

Acceptance criteria per phase:
1. Step with `verification: zig build test` does not reach `.completed` while the command
   fails; unit test in `test_plan_verification.zig`.
2. Parsed plan defaults to `proposed`; mutating guidance suppressed until `/plan approve`;
   restore of a stored `proposed` plan stays `proposed`.
3. After forced `compactMemAct`, index-2 context block contains active plan summary,
   read-skill names, and task reminder; LLM in the next act refers to the plan without
   re-asking.
4. Plan with two independent steps + `executor_mode: "parallel"` executes via
   `batch_invoke_subagents` in one dispatch; a Critical review verdict fails the step and
   injects `plan_replan_suggestion_fmt`.
5. `session_diagnostics detail` shows the metrics block for the current session.
6. **State A/B no-op proof (§3.6)**: with `enable_structured_planning = false`, a session
   log is byte-identical in journal event stream to pre-RFC-024 behavior (feature inert);
   with feature on and no parsed plan, only `post_compact_reinject` (plan-less variant:
   skills + task reminder) may appear — no plan/verification/review events.

---

## 8. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Approval gate adds a turn of latency to simple tasks | Gate only applies to parsed **structured** plans; ReAct-mode single-step tasks (no plan detected) are untouched. |
| `verification: shell` commands re-run expensive suites per step | Verification is per-step, not per-act; cached negative results within the step's `active` window; config cap on verification duration (reuse `act_timeout_secs` class). |
| Review subagent cost doubles token usage on every step | `plan_review_gate` defaults off; recommend "final step + after each `mutate`-category step" as the sane preset, exposed as `/plan review on\|off`. |
| Post-compaction block bloats context | Reinject block capped at ~2 KB (plan summary reuses `generateProgressSummary` which is already bounded; skill list is name+path only). |
| Phase 4 couples plan layer to subagent binaries (`/proc/self/exe -e`) | It already does, via existing tools — Phase 4 only reuses `subagent.executeTool`; no new process machinery. |

---

## 9. References

- [obra/superpowers](https://github.com/obra/superpowers) — README workflow (brainstorming →
  worktrees → writing-plans → subagent-driven-development → TDD → code review → finishing),
  skills library, Pi post-compaction bootstrap, `diagnosing-superpowers`.
- Installed local skills: `~/.mini/skills/{writing-plans,executing-plans,subagent-driven-development,test-driven-development,requesting-code-review,verification-before-completion,using-superpowers}/SKILL.md`.
- `docs/rfc_019_structured_planning_system_proposal.md` (§19 PlanMetrics, Appendix C gap table).
- `docs/rfc_020_semantic_advisory_enforcement.md` (telemetry phase — plan-path coverage via §3.5).
- `docs/rfc_022_watchdog_false_positive_proposal.md` (completion semantics consumed by §3.1).
- `docs/rfc_023_end_turn_completion_semantics_proposal.md` (typed response state; "CONCLUDE" replan option).
