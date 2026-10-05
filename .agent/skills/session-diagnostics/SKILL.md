---
name: session-diagnostics
description: Inspect and diagnose mini-agent sessions: journals, process states, backend errors, cost/latency, context overflow, stalled or failed sessions. Use when the user asks "why did it do that", "why so slow/expensive", or before killing a hung process.
---

# Session Diagnostics Skill

Evidence-based diagnosis of what mini-agent did, why it failed or ran slow, and how to recover. Built on the Event Sourcing Journal system (`~/.mini/sessions/journal_*.jsonl`).

**Iron rule: every finding cites `journal_<pid>.jsonl:<line>`. No citation, no finding. Every number comes from the journal or from a command you just ran — never from memory.**

---

## 1. Intake Before Analysis (a complaint is not a problem statement)

"It took too long", "why is it so expensive", "it's stuck" are complaints, not scoped problems. Before touching logs, pin down:

- Which session: current (live PID) or past (`journal_*.jsonl` path / id)?
- What was expected, what happened?
- Which observable you care about: wall-clock, tokens, repeated actions, one specific act?

Ask one question at a time. If the user cannot answer yet, write the questions and stop — a statement you reconstructed is not an answer. An already-scoped request ("inspect act 14 of journal_X", "why did the subagent in this batch fail") is itself the statement: answer it directly.

**Read-only discipline:** never modify, move, or delete session files. Diagnostics are read-only; killing a process (Section 7) is the single sanctioned mutation.

---

## 2. Where Evidence Lives

Each mini process (REPL, `mini -e` single-shot, subagent) writes JSONL to `~/.mini/sessions/journal_<pid>.jsonl`. Event shape:

```json
{"act_id":1,"event_type":"act_started","timestamp":1787644166589,"description":"Act started","delta":null,"error_detail":null}
{"act_id":1,"event_type":"llm_provider_error","timestamp":1787644167000,"description":"Backend error","delta":null,"error_detail":{"backend":"openai-compat","model":"gpt-4o","error_name":"LLMProviderUnavailable","http_code":529,"attempt":1,"raw_snippet":"...","server_error":"..."}}
```

Event types (from `src/core/journal.zig` — `ActEventType`):

| Event | Meaning |
|---|---|
| `act_started` / `act_completed` | Act boundary; `description` summarizes the act's tool calls |
| `act_failed` | Terminal act failure; inspect `error_detail` |
| `llm_call_throttled` | HTTP 429; check `backoff_s` |
| `llm_provider_error` | 5xx/529/401/403; check `http_code`, `raw_snippet` |
| `llm_response_invalid` / `llm_output_malformed` | Backend returned unparseable content |
| `llm_context_overflow` | Context exceeded window; MemAct compaction involved |
| `llm_generation_ended` | Generation finished; usage/tokens here |
| `agent_decision` | LLM-driven watchdog/routing decision |
| `task_completed` / `task_failed` / `task_stalled` / `task_interrupted` | Task-level terminal states |
| `rollback_requested` / `rollback_completed` | State rolled back (CAS file snapshots restored) |
| `memact_compacted` | Context compacted; preserved prompt + summary inserted |
| `checkpoint_created` | Progress checkpoint after orbit/loop detection |
| `plan_phase_changed` / `plan_step_verified` / `plan_review_outcome` | plan lifecycle |
| `skill_loaded` / `post_compact_reinject` | Skill read into context; re-injection after compaction |

---

## 3. Built-in APIs (prefer over raw /proc)

Parsing `/proc` wait-channels (`anon_pipe_read`, `n_tty_read`) easily misinterprets normal idle states. Use the dedicated APIs:

- Tool `session_diagnostics`: `{"operation":"list"}`, `{"operation":"detail","pid":<pid>}`, `{"operation":"kill","pid":<pid>,"signal":"SIGTERM"}`
- CodeAct: `mini.sessions()`, `mini.sessionDetail(pid)`, `mini.sessionKill(pid, signal?)`

Process-state semantics:

- **REPL session**: after `task_completed` the process stays ALIVE in `idle_waiting_input` — expected, not a hang.
- **Subagent / single-shot**: exits with 0 after `task_completed`. A subagent ALIVE after task completion, or stuck at `act_started` for a long time, is an anomaly.

---

## 4. Complaint → First Evidence (triage table)

| Complaint | Read first |
|---|---|
| "It took too long" | `llm_call_throttled`, `checkpoint_created`, act timestamp gaps; `agent_decision` (watchdog WAIT decisions) |
| "Why so expensive" | `llm_generation_ended` token usage; `memact_compacted` + `post_compact_reinject` (lost context → re-reads) |
| "It repeated work" | `checkpoint_created`, repeated identical `act_started` descriptions |
| "It broke / failed" | `act_failed` / `task_failed` + `error_detail` (backend, http_code, raw_snippet) |
| "It lost context / re-read files" | `memact_compacted`, `post_compact_reinject`, `rollback_completed` |
| "Plan drift" | `plan_phase_changed`, `plan_step_verified`, `plan_review_outcome` |
| "A skill never fired" | `skill_loaded` events (or their absence) for the session |

---

## 5. Journal Reading Rules (context safety)

- A single journal line can embed megabytes of tool output. **Never `cat` a whole journal.** Use: `tail -n 20`, `grep -c`, `jq` field projection, or `mini.read(path, offset, limit)`.
- When a line is too big: project fields first — `jq -c 'select(.error_detail != null) | {act_id, event_type, error_detail}' journal_<pid>.jsonl`.
- Cite `journal_<pid>.jsonl:<line>` in every finding. Numbers you did not extract from the journal or a command output are invented — cite them or drop them.

---

## 6. Deep-Dive Multi-Dimension Analysis

For a past session with several complaints, fan out one subagent per complaint dimension in a single `batch_invoke_subagents` call (dimensions are independent): repeated-work, stumbles/loops, cost-and-time, plan-adherence, quality-evidence. Each task string must be fully self-contained: absolute journal path, the dimension, and the evidence rule (findings without `journal:<line>` citations are discarded). Discard citation-free findings; merge the rest.

---

## 7. Recovery

- **Hung process**: `session_diagnostics` detail(pid) → confirm anomaly → kill(pid, "SIGTERM") (SIGKILL fallback) → confirm via list.
- **Backend errors** (from `error_detail.http_code`): 429 → check quota/key, note `backoff_s`; 5xx/529 → transient overload, retry later; 401/403 → credentials in `~/.mini/.env` (mask values in reports — use `$OPENAI_COMPAT_API_KEY` style, never print raw keys).
- **Context overflow**: raise `MINI_CONTEXT_WINDOW`, or enable MemAct (`MINI_MEMACT_ENABLED=1`) so compaction handles it.
- Helper script (quick sweep of the 10 newest sessions): `mini.sh("~/.mini/skills/session-diagnostics/scripts/diagnose_sessions.sh")`.
