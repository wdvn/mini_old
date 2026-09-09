---
name: session-diagnostics
description: Inspect and diagnose session logs, journals, errors, and audit telemetry of mini-agent. Use when analyzing execution history, backend errors, rate limits, context overflow, or recent session failures.
---

# Session Diagnostics Skill

Guide for querying, extracting, and diagnosing issues using the Event Sourcing Journal system (`~/.mini/sessions/journal_*.jsonl`).

---

## 1. Journal File Structure in `~/.mini/sessions/`

Each running `mini-agent` process writes JSON Lines events to `journal_<pid>.jsonl`:

```json
{"act_id":1,"event_type":"act_started","timestamp":1787644166589,"description":"Act started","delta":null,"error_detail":null}
{"act_id":1,"event_type":"llm_provider_error","timestamp":1787644167000,"description":"Backend error","delta":null,"error_detail":{"backend":"openai-compat","model":"gpt-4o","error_name":"LLMProviderUnavailable","http_code":529,"attempt":1,"raw_snippet":"...","server_error":"..."}}
{"act_id":1,"event_type":"act_completed","timestamp":1787644169637,"description":"Act completed","delta":{"act_id":1,"file_snapshots":[]},"error_detail":null}
{"act_id":1,"event_type":"task_completed","timestamp":1787644172005,"description":"Task completed","delta":null,"error_detail":null}
```

---

## 2. Built-in Diagnostic Tools (Recommended for LLMs)

Instead of raw shell commands or parsing `/proc` directly (which can easily misinterpret kernel `anon_pipe_read` states), use these dedicated APIs:

### A. Using Tool `session_diagnostics` (JSON Tool Call)
1. **List all sessions and processes**:
   ```json
   {"operation": "list"}
   ```
2. **Inspect detailed state for a PID (including REPL vs Subagent classification and operational status)**:
   ```json
   {"operation": "detail", "pid": 340194}
   ```
3. **Safely terminate a hanging process**:
   ```json
   {"operation": "kill", "pid": 340194, "signal": "SIGTERM"}
   ```

### B. Using CodeAct JS VM (`mini.*`)
* `mini.sessions()`: Returns a table of sessions.
* `mini.sessionDetail(pid)`: Returns a detailed diagnostic report for the specified PID.
* `mini.sessionKill(pid, signal?)`: Sends a termination signal to the process.

---

## 3. Core Principles for Reading Process States

1. **Distinguish Interactive REPL vs Subagent/Batch**:
   - **REPL Session (`mini`)**: After completing a task (`task_completed`), the process remains **ALIVE** in state `idle_waiting_input` (waiting for user input at the prompt `You > `). Kernel wait states `anon_pipe_read` / `n_tty_read` are **completely expected**, NOT a hang or broken pipe!
   - **Subagent / Single-shot (`mini -e "..."`)**: Always exits automatically (`exit 0`) upon task completion. A subagent remaining ALIVE after `task_completed` or stuck at `act_started` for too long is an anomaly.

2. **Determine Status via Journal Events**:
   - `task_completed` at the end $\to$ Task completed 100%.
   - `act_started` at the end (with PID alive) $\to$ Calling LLM API or executing tools.
   - `act_completed` at the end $\to$ Transitioning between Acts.

---

## 4. Event Codes and Diagnostics

| Event Type | Meaning | Potential Issue to Check |
|---|---|---|
| `act_started` | New act loop begun | If file ends with `act_started` without `act_completed` -> process crashed, timed out, or was killed |
| `llm_call_throttled` | HTTP 429 Rate Limit | Review `backoff_s` and check API key quota/tier |
| `llm_provider_error` | HTTP 5xx / 529 Server Overload | Upstream AI server overloaded or temporarily unavailable |
| `llm_context_overflow` | Context exceeded token limit | Check MemAct context compaction and token estimator |
| `act_failed` | Act failed (terminal error or retry exhaustion) | Inspect `error_detail.error_name`, `error_detail.http_code`, `error_detail.raw_snippet` |
| `rollback_completed` | State rolled back and history truncated | Check whether CAS snapshots properly restored previous files |
