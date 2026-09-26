# RFC-024: AI Plan Framework — Superpowers-Grade Methodology on Top of RFC-019

**Status**: Proposed
**Date**: 2026-09-25
**Author**: mini-agent team
**Related**: RFC-019 (Structured Planning), RFC-020 (Semantic Advisory Enforcement), RFC-022 (Watchdog False-Positive Elimination), RFC-023 (End-Turn Completion Semantics)
**Supersedes**: None
**External reference**: [obra/superpowers](https://github.com/obra/superpowers) — composable skills + mandatory workflow methodology (brainstorming → worktree → writing-plans → subagent-driven-development → TDD → code review → branch finishing)

---

## 1. Executive Summary

mini already ships a substantial planning substrate (RFC-019): a DAG plan model
(dependency resolution is implemented in the library layer — `executePlanStep()` checks
prerequisites — but the production runtime today completes steps sequentially by
`tool_hint` match, §2.1), JSON/Markdown parsing, drift monitoring, CAS-based cross-turn
persistence, plan rendering in the REPL, a skills system, and parallel subagent dispatch. What mini does **not**
have is a **plan framework** — the layer that turns a parsed plan into a disciplined
engineering process: verified task boundaries, an explicit proposed→approved plan
advisory before mutation,
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
2. **Plan approval advisory** — plans are *proposed*, not silently executed; `proposed →
   approved` is a first-class phase with `/plan` REPL control. Approval is an **advisory
   gate by design** (mutating tools are not hard-blocked; the model receives a standing
   advisory), consistent with RFC-020's "guidance, not hard block" — a hard dispatch-time
   gate is explicitly out of scope (§8), and the detection-vs-dispatch timing window is
   documented as a known limitation (§3.2).
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
| ⚠ Runtime wiring (capability vs reality) | `src/core/agent.zig:1461-1479` | Production completion is **sequential by `tool_hint` name match**; `executePlanStep()` is called only from the module itself and tests — the dependency-resolution path is not wired into the agent loop. `findActiveStepIndex()` (`plan.zig:253`) returns the first pending/active step, ignoring dependencies |
| Drift monitor | `src/core/plan_monitor.zig` (286 lines) | `checkPlanDrift()`, `calculateDriftScore()` (0.3 same category / 0.8 cross-category), `generateDriftCorrection()` |
| CAS persistence | `src/core/plan_store.zig` (309 lines) | `save()`/`restore(request_hash)` via Content-Addressed Store + `metadata.jsonl`; `listPlans()` |
| Orchestration state | `src/core/plan_integration.zig` | `PlanState` (legacy watchdog + RFC-019 fields consolidated); `setStructuredPlan()` + `renderPlanDisplay()` writes full plan to the active `TurnRenderer`; `tryRestoreFromStore()` called at turn start (`agent_turn.zig:95`) |
| Auto completion detection | `src/core/agent.zig:1455-1478` | after each tool act: if executed tool == `tool_hint` of active step → `completeStep()`; when `is_complete` → `plan_store.save()` + `clearPlan()` |
| Prompt-side planning modes | `src/core/prompts.zig` | "ReAct Mode (Default)" vs "Proactive Planning Mode (RFC-019)" with JSON plan template; `plan_replan_suggestion_fmt`, `plan_drift_significant`, `plan_step_enforcement_head` |
| REPL control | `src/ui/repl.zig:249, 335-346` | `/plan on\|off\|status` toggles `enable_structured_planning` |
| Config | `src/core/config.zig:240-253, 506-519` | Struct field default for `enable_structured_planning` is **true**, but the env-resolved loader default (the *actual runtime value*) is **false** (`config.zig:512` — no `MINI_ENABLE_STRUCTURED_PLANNING` env var → false). Also: `plan_drift_detection`, `plan_max_steps` (20), `plans_dir`, `enhanced_progress_checkpoint` (parsed but unused outside config — gates nothing), `prompt_enforcement_enabled` (default **false**; gates the progress block) |

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

- **Verification result states (normative):** a `StepVerification` run yields one of
  `passed | failed | timed_out | error | skipped` (skipped = no verification field,
  legacy behavior). Only `passed` transitions the step to `.completed`;
  `failed`/`timed_out`/`error` keep it in `.verifying` and emit
  `verification_failed` drift (below). Result + wall-time + trimmed output are stored
  on the step and journaled.
- **Safety bounds for `shell` verification:** hard timeout (bounded by
  `act_timeout_secs` class, per-verification cap), cancellation via process-group
  kill on timeout, and a read-only allowlist default: verification commands are
  run in a restricted profile that blocks file-mutating tools
  (`file_write`/`file_edit`/`rm`/`git commit` class) — a verification command
  that *mutates* state is treated as a `failed` verification with an advisory,
  not executed to completion.
- **No double-counting:** `verifyStep()` runs the check *outside* the tool
  registry's lifecycle hook path (or uses a hook-suppressed variant of the
  registry call) so a verification run is never journaled as an agent tool
  call that advances step progress or the tool trajectory.
- **CodeAct mode:** when the agent executes a step via JavaScript
  (`executeCodeActBlock`) instead of native tool dispatch, verification is
  evaluated from the CodeAct turn's terminal state (final tool results inside
  the JS block), not by re-running native `bash`/`file_read` — `verifyStep()`
  accepts a `?[]const u8` of observed terminal outputs so both paths converge
  on the same result-state machine.

Superpowers parallel: *writing-plans* "every task has verification steps" +
*verification-before-completion* "evidence before assertions".

### 3.2 Phase 2 — Plan approval advisory (soft gate)

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
- **Design decision (normative): this is an *advisory*, not a hard gate.** Mutating
  tools are not blocked anywhere; enforcement is prompt-level, per RFC-020's
  "guidance, not hard block" policy. A hard gate would require blocking at the
  native-tool dispatch point — and is defeated today anyway by a timing window:
  plans are detected while scanning response *text* (`agent_step.zig:182-187`)
  after the tool definitions for that same response were already selected
  (`agent_turn.zig:104-127`), so the mutation calls riding in the very response
  that produced the plan execute before the plan object even exists. Documented
  as a known limitation; a hard gate is out of scope (see §8).
- REPL: extend `/plan` with `approve | reject | status | list` (`repl.zig`, backed by
  `plan_store.listPlans()`).
- `plan_store` persists `PlanPhase`. **Persistence triggers (normative):** on every
  phase transition (`proposed → approved`, `approved → executing`, step
  verification results), *not only* at completion — today `save()` fires only at
  `is_complete` (`agent.zig:1471-1476`), so a crash mid-plan loses the running plan.
  `restore()` must filter metadata by `!is_complete` when reviving a running plan;
  a completed plan is retained for reference but not re-activated.

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
- **Mechanism correction (what is actually lost):** the `skills_guidance_header`
  *list* (name + description + path of every available skill) lives in the
  **system prompt**, which is re-sent on every request — it is *not* dropped by
  `compactMemAct()` (that only rewrites the history array, not the system prompt).
  What *is* lost is **skill *content* that was read into the conversation**
  (`mini.read` of a SKILL.md becomes a history tool-result, which compaction
  discards). The reinject block therefore targets the read-skill content list
  (item (b) above), not the guidance list. Rebuilding the guidance list from
  `skills.getSkills()` at compaction time is a defensive measure only for
  `MINI_SYSTEM_FILE` users and subagent one-shot runs whose index-0 shape differs
  from the default system prompt.

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
  Superpowers' `dispatching-parallel-agents`. **Dependency:** the runtime today only
  completes steps sequentially by `tool_hint` match (§2.1 runtime-wiring gap), so
  auto-batching additionally requires wiring a dependency-aware ready-set selector
  into the production loop (`executePlanStep()` / first-ready-step selection,
  replacing `findActiveStepIndex()`'s sequential scan) — that wiring is a
  precondition of this phase and is scoped into §3.4 work.

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

The RFC must state precisely what happens when planning is *not* active. Note on the
baseline: the struct-field default for `enable_structured_planning` is `true`
(`config.zig:241`), but the **actual runtime value** comes from the env-resolved
loader (`config.zig:512`), which defaults to **false** when the env var is absent —
so, out of the box, the feature is OFF and State A describes default behavior.
The flag only *enables* the parser/monitor; whether a plan actually exists depends
on the LLM emitting a parseable plan in a response. There are four distinct
states, each with defined behavior under this RFC.

**State A — `enable_structured_planning = false` (feature fully off):**
- `tryDetectPlanInResponse` falls to the legacy `detectPlanInText` string-matching path
  (160-byte summary), exactly as today. No `StepVerification`, no phase gate, no
  reinjection, no subagent dispatch. All RFC-024 features are inert.
- Drift monitor and progress checkpoint behave per current `prompt_enforcement_enabled`.
- *Guarantee*: turning the flag off is a true no-op for RFC-024 — zero behavior change.

**State B — Feature on, but no structured plan was parsed for the current task:**
- The model is in **ReAct mode** (default). It may freely explore and act; there is no
  `PlanPhase`, no verification gate, no approval advisory, no review gate — none of
  §3.1–§3.4 machinery has a plan object to attach to, so none of it fires.
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
| `src/core/plan_executor.zig` | `verifyStep()`, `dispatchStep()`, and a dependency-aware ready-set selector that picks the next actionable step from `dependencies` (wired into the runtime to replace the sequential `tool_hint`-match completion, §3.4) |
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
| Approval advisory adds a turn of latency to simple tasks | Advisory only applies to parsed **structured** plans; ReAct-mode single-step tasks (no plan detected) are untouched. A hard dispatch-time gate was considered and rejected: plans are detected after the response's tool definitions are already chosen, so the timing window (§3.2) makes any in-response hard block unreliable; out of scope. |
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


# Đánh giá RFC-024: AI Plan Framework

## Kết luận

RFC-024 nhắm đúng các thiếu hụt về xác minh step, duyệt kế hoạch, giữ ngữ cảnh sau compaction và review kết quả subagent. **Tuy nhiên, bản hiện tại chưa sẵn sàng để triển khai**: một số mô tả hiện trạng sai hoặc mâu thuẫn, và “approval gate” như thiết kế chưa thực sự đảm bảo người dùng đã chấp thuận trước khi có thay đổi.

## Các điểm cần sửa trước — ưu tiên cao

### 1. Mâu thuẫn về mặc định của structured planning

RFC nói enable_structured_planning mặc định bật (§2.1, §3.6). Struct Config có giá trị khởi tạo true, nhưng config loader lấy từ resolvePlanningAndWatchdogSettings() với giá trị môi trường mặc định **false** (src/core/config.zig:239-253, 506-519). Cần thống nhất RFC mô tả **giá trị mặc định thực tế khi chạy**, không chỉ giá trị mặc định của struct.

Mâu thuẫn này tác động trực tiếp đến fallback semantics, test no-op và các tuyên bố tương thích ngược.

### 2. Approval gate hiện chỉ là advisory, không phải user sign-off

RFC gọi đây là approval gate và nhấn mạnh user sign-off, nhưng §3.6 lại ghi rõ tool làm thay đổi dữ liệu **không bị chặn** — model chỉ nhận lời nhắc. Như vậy đây là **soft advisory**, không đảm bảo người dùng đã duyệt.

Có thêm một lỗ hổng về thời điểm: plan được nhận diện khi quét nội dung response (src/core/agent_step.zig:182-187), rồi các native tool call trong chính response đó được dispatch (src/core/agent_step.zig:1136-1142). Các tool definitions lại đã được chọn trước khi response đến (src/core/agent_turn.zig:104-127). Vì thế một plan mới được phát hiện chưa thể ngăn tool mutation đi kèm response đó.

Nếu mục tiêu là yêu cầu phê duyệt thật, RFC cần quy định **hard gate tại đường dispatch tool**, trước khi mutation chạy. Nếu chỉ muốn gợi ý, nên đổi tên và tiêu chí thành “approval advisory”; hiện hai mục tiêu đang bị trộn lẫn.

### 3. Phần mô tả “DAG execution” đang đánh giá quá cao hiện trạng

Mô hình plan có dependencies, và executePlanStep() kiểm tra dependency (src/core/plan.zig:48-68; src/core/plan_executor.zig:45-67). Nhưng lượt rà soát call sites chỉ thấy hàm này được gọi trong chính module và test; luồng agent production đánh dấu step hoàn tất bằng cách so sánh tên tool với tool_hint, rồi tăng chỉ số step tuần tự (src/core/agent.zig:1461-1479). findActiveStepIndex() cũng chọn step pending hoặc active đầu tiên mà không xét dependency (src/core/plan.zig:253-264).

Do đó, câu RFC-024 rằng mini hiện có “DAG plan model with dependency resolution” cần phân biệt **khả năng trong thư viện** với **dependency resolution đang được nối vào runtime**. Điều này đặc biệt quan trọng cho §3.4: không thể chỉ kiểm tra hai step “không có dependency edge” rồi batch nếu luồng hiện tại chưa xác định tập step sẵn sàng.

### 4. Plan đang được lưu khi hoàn thành, không phải ở các trạng thái đang chạy

PlanStore.save() serial hóa plan và ghi CAS (src/core/plan_store.zig:84-103), nhưng call site trong agent là lúc plan đã hoàn tất, ngay trước khi xóa plan khỏi trạng thái hiện tại (src/core/agent.zig:1471-1476). tryRestoreFromStore() có thể khôi phục plan theo request hash (src/core/plan_integration.zig:274-289), nhưng điều đó chưa đồng nghĩa plan đang thực hiện được lưu bền vững qua crash/turn.

Vì approval và review phụ thuộc lifecycle như proposed, approved, executing, RFC cần định nghĩa **lưu ở các transition nào**, tránh chỉ lưu trạng thái hoàn tất. Cũng cần quy định khôi phục một plan đã hoàn tất; restore hiện đọc plan mới nhất khớp request hash, không thấy lọc theo metadata is_complete ở đường khôi phục.

## Các điểm cần làm rõ theo phase

### Phase 1 — Verification-gated steps

Hiện PlanStep chưa có trường verification (src/core/plan.zig:48-67), parser chỉ đọc id, description, dependencies, tool_hint, status (src/core/plan_parser.zig:33-74), và auto-completion xảy ra khi tool thành công có tên khớp chính xác tool_hint (src/core/agent.zig:1461-1468).

RFC cần xác định thêm:

- Schema JSON chính thức: ví dụ {"shell": ...} chưa khớp trực tiếp với struct kind + value; file_contains cũng cần định dạng path/pattern cụ thể.
- Verification có trạng thái passed / failed / error / timed_out / skipped hay chỉ bool; nơi lưu output, thời gian và kết quả.
- Ranh giới an toàn của shell: một lệnh verification có thể gây thay đổi, không chỉ kiểm tra. Quy định phải bao gồm timeout, hủy, phạm vi path và cách xử lý lệnh không an toàn.
- Cách chạy verifier để không bị tính nhầm như tool hành động của agent. Nếu gọi registry tool bình thường, nó phát lifecycle hook như tool call (src/tooling/registry.zig:172-205); cần tránh double-count hoặc làm thay đổi tiến độ/tool trajectory ngoài ý muốn.
- CodeAct mode: tool dispatch của agent không đi qua cùng đường native-tool tracking. RFC nên nêu rõ verification và ghi nhận step hoạt động thế nào khi agent thực thi JavaScript thay vì native tool (src/core/agent_step.zig:1097-1100, 1144-1150).

### Phase 3 — Post-compaction reinjection

compactMemAct() giữ yêu cầu gốc ở msgs[0], tạo summary ở index 1 và xóa các message còn lại (src/core/history.zig:363-388). RFC vì thế không cần “nhắc lại” yêu cầu gốc theo cách trùng lặp; nên nói rõ phần nào chỉ được khôi phục để chống việc summary bỏ sót.

RFC cũng nói skills guidance bị mất. **Danh sách skill được build thành system prompt** (src/core/config.zig:960-976, 998-1012) và system_prompt được gửi trong request tiếp theo (src/core/agent_step.zig:1059-1065), nên phần danh sách không bị compactMemAct() xóa khỏi history theo cách RFC mô tả. Khác với danh sách, **nội dung skill đã được đọc vào conversation** có thể biến mất sau compaction. Nên theo dõi skill content đã nạp, thay vì giả định toàn bộ skill guidance đã mất.

post_compact_reinject mặc định bật nhưng §3.6 nói State A phải không có behavior mới; RFC cần quy định cờ này bị giới hạn bởi enable_structured_planning hay được phép chạy cả khi planning tắt. “Chỉ bổ sung thông tin nên không thể phá luồng” chưa đủ để bảo đảm không đổi hành vi, token budget hoặc cách model phản hồi.

Cuối cùng, RFC cần chỉ rõ vai trò và tier của context block ở index 2. Summary tại index 1 phải là .user để giữ tương thích Claude; việc thêm block và compaction tiếp theo cần có contract rõ.

### Phase 4 — Subagent và review

Có thể tái sử dụng subagent hiện có, nhưng giao diện của chúng là task string / mảng task tự do, không nhận đối tượng PlanStep có cấu trúc (src/tools/subagent.zig:88-135; src/tools/batch_subagent.zig:138-181). RFC cần định nghĩa:

- Mapping task ID ↔ kết quả ↔ review ↔ verification.
- Cấu trúc phản hồi bắt buộc từ worker và reviewer; quy tắc khi subagent lỗi, không có output, bị kill hoặc vượt giới hạn.
- Quyền thao tác, tool policy, timeout và snapshot/rollback cho mutation do child process thực hiện.
- Review “hai giai đoạn” là một hay hai lần chạy reviewer; output và severity có schema máy đọc được nào.
- Cách tắt approval/review gate trong subagent được dispatch. Subagent khởi chạy tiến trình mini mới và nhận environment hiện tại (src/tools/subagent.zig:104-120), nên các config mới có thể được kế thừa nếu không xử lý riêng.

### Phase 5 — Telemetry và config

ActEventType hiện chưa có các event RFC đề xuất (src/core/journal.zig:18-39). Journal event có event_type và description, nhưng chưa có payload chuyên biệt cho step ID, verification status hoặc review severity (src/core/journal.zig:82-91). Chỉ thêm tên event sẽ chưa đủ để tính các metrics đã liệt kê; RFC nên định nghĩa schema sự kiện và mẫu số/tập hợp của từng metric.

session_diagnostics detail hiện hiển thị trạng thái tiến trình, lỗi và tối đa 10 event cuối, chưa tổng hợp plan metrics (src/tools/session_diagnostics.zig:396-433). Cần nêu rõ phần metrics sẽ đọc toàn journal nào, xử lý event cũ/thiếu dữ liệu ra sao và có giới hạn chi phí không.

RFC-024 cũng nên chỉnh lại hai chi tiết hiện trạng:

- planning_min_task_length được parse nhưng chưa thấy dùng trong logic; nhận xét này phù hợp với code.
- actual_acts được gán từ current_step_acts khi complete, nhưng không tìm thấy đường production tăng các bộ đếm current_step_acts/total_acts (src/core/plan_executor.zig:22-33, 64-67, 83-94; chỉ có field/serialization và gán). Vì vậy nên viết chính xác là **đường đếm act chưa được nối đầy đủ**, không phải completion không bao giờ cập nhật actual_acts.
- enhanced_progress_checkpoint được cấu hình, nhưng progress block đang gate bằng prompt_enforcement_enabled (src/core/config.zig:250-253; src/core/plan_integration.zig:309-344). Việc đề xuất hợp nhất hai cờ là hợp lý, nhưng cần nêu rõ giữ giá trị mặc định/hành vi nào.

## Kết luận review

**Khuyến nghị: sửa RFC trước khi viết implementation plan.** Nên chốt trước bốn quyết định nền tảng:

1. Structured planning mặc định bật hay tắt khi khởi tạo cấu hình thực tế.
2. Approval là hard gate hay chỉ advisory; nếu hard gate, chặn chính xác ở điểm nào trước mutation.
3. Runtime có thực sự điều phối DAG dependency, hay chỉ tuần tự hoàn tất step theo tool_hint.
4. Verification và lifecycle event có schema, timeout, lỗi và quy tắc rollback cụ thể nào.

## Chốt 4 quyết định (đã phản ánh vào RFC)

1. **Default thực tế = TẮT** (env-resolved loader, `config.zig:512`). §2.1 và §3.6 đã sửa để mô tả giá trị mặc định *khi chạy*, không phải struct default.
2. **Approval = advisory (soft gate)**, giữ nhất quán RFC-020; hard gate bị loại bỏ khỏi phạm vi do timing window (detection sau khi tool definitions đã chọn). §3.2 đổi tên thành "Plan approval advisory", ghi rõ decision normative + known limitation; §8 cập nhật risk.
3. **Runtime hiện chỉ tuần tự theo tool_hint** — capability DAG nằm trong lib, chưa nối vào production. §2.1 thêm hàng "⚠ Runtime wiring (capability vs reality)"; §3.4 yêu cầu wiring dependency-aware ready-set selector là precondition của auto-batching; §5 (plan_executor) cập nhật scope.
4. **Verification schema + persistence triggers**: §3.1 bổ sung result-state machine `passed | failed | timed_out | error | skipped` (chỉ `passed` → `.completed`), safety bounds cho `shell` (timeout + process-group kill + read-only allowlist), no-double-counting (chạy ngoài lifecycle hook path), và CodeAct convergence; rollback không phát minh mới — kế thừa CAS snapshot (RFC-002). §3.2 quy định save tại mọi phase transition (không chỉ completion) + restore filter `!is_complete`.
