# RFC-023: End-Turn Completion Semantics

**Status**: Implemented
**Date**: 2026-09-24
**Author**: mini-agent team
**Related**: RFC-002 (Event Sourcing & CAS), RFC-006 (OpenAI-Compatible Response Standardization), RFC-009 (Thinking Budget & Reasoning Effort), RFC-019 (Structured Planning), RFC-022 (Watchdog False-Positive Elimination)
**Supersedes**: None


---

## 1. Summary

RFC-023 fixes the end-turn failure in mini where the provider reports a normal stop but the response contains no final answer and no executable action.

The incident is visible in session `2619196`, Act 52:

- The first request attempt returned HTTP 500.
- The next attempt returned HTTP 200 with `stop_reason: "end_turn"`.
- The response contained partial `thinking` only.
- `text` was `null`.
- `tool_calls` were `null`.
- No CodeAct block was executed.
- Mini recorded the Act as completed and continued to the next Act through an empty-response advisory.

The same design can recur because `end_turn` currently represents both provider generation termination and agent task completion. `handleEndTurnStop()` may return either `.exit_loop` or `.continue_loop`, while the journal and Act logger still use `end_turn` as if it were a terminal task outcome.

RFC-023 introduces a typed response state and an explicit agent decision layer:

1. Record whether the provider emitted a valid terminal event.
2. Classify the response payload before dispatching the stop reason.
3. Execute native tools or CodeAct when valid actions exist.
4. Treat only meaningful final text as task completion.
5. Recover thinking-only and empty responses inside the same Act with a bounded failure-class budget.
6. End stalled or failed turns without writing `task_completed`.
7. Keep long horizontal workflows unbounded by the number of Acts.

---

## 2. Incident and Current Failure Path

### 2.1 Evidence from session `2619196`

The Act log `~/.mini/acts/act_2619196_52.json` records:

| Field | Value |
|---|---|
| `act_id` | `52` |
| `backend_name` | `openai-compat` |
| `backend_model` | `agnes-2.5-flash` |
| `http_code` | `200` |
| `stop_reason` | `end_turn` |
| `text` | `null` |
| `thinking` | Present, 1,314 characters |
| `tool_calls` | `null` |
| `completion_tokens` | `367` |
| `execution.exec_type` | `none` |

The journal records a prior Act 52 provider error with HTTP 500 and a second Act 52 attempt that reached `act_completed`:

`~/.mini/sessions/journal_2619196.jsonl:106-109`.

The provider-side cause of the short response is unknown because the raw successful SSE response was not retained. RFC-023 must classify the observed agent-side condition without claiming a specific upstream cause.

### 2.2 Current code path

The current path is:

```text
OpenAI-compatible provider returns HTTP 200
    │
    ├─ finish_reason: "stop"
    │      └─ openai.zig maps it to .end_turn
    │
    ├─ thinking accumulator is finalized
    │      └─ response contains .thinking only
    │
    ├─ no text block
    ├─ no native tool_use block
    └─ no CodeAct block
           │
           ▼
agent_step.executeStep()
    │
    ├─ history.addAssistantResponse()
    ├─ scanResponseContent()
    │      └─ response_content_empty = true
    ├─ no native tool execution
    ├─ no CodeAct execution
    └─ dispatchStopReason()
           └─ handleEndTurnStop()
                  ├─ handleEmptyResponseAdvisory()
                  └─ return .continue_loop
```

The relevant code is:

- `src/backends/openai.zig:1016-1027`: maps `finish_reason: "stop"` to `.end_turn`.
- `src/backends/openai.zig:883-899`: may assign `.end_turn` during `[DONE]` finalization when no explicit reason was received.
- `src/backends/openai.zig:1226-1269`: finalizes partial text, thinking, and tool calls, then applies the same fallback.
- `src/core/agent_step.zig:135-175`: considers only meaningful text or native tool use as actionable.
- `src/core/agent_step.zig:404-416`: injects an empty-response advisory and resets the boolean flag.
- `src/core/agent_step.zig:419-464`: allows `end_turn` to produce either completion or continuation.
- `src/core/agent_step.zig:647-662`: dispatches `.end_turn` and `.stop_sequence` through the same handler.
- `src/core/agent_turn.zig:504-511`: writes `task_completed` whenever the step returns `.exit_loop`.

### 2.3 Why the current recovery is unsafe

The boolean `response_content_empty` is reset after each advisory. It does not count repeated failures, preserve the Act retry identity, or distinguish a one-off empty response from a provider that repeatedly stops during reasoning.

The current recovery therefore has this risk:

```text
natural end + thinking-only
    → advisory
    → new Act
    → natural end + thinking-only
    → advisory
    → new Act
    → ...
```

The current response logger also overwrites `act_<pid>_<act_id>.json` when the same Act is retried. The journal records the retry count only for classified provider errors, not for a successful HTTP 200 response with an unusable payload.

---

## 3. Problem Statement

Mini has no single authoritative state for these questions:

1. Did the provider terminate normally?
2. Was the response payload usable?
3. Did the model request an action?
4. Did the agent execute the action?
5. Did the user task complete?
6. Did the turn stop because of failure, cancellation, or recovery exhaustion?

The current `StopReason` field answers only the provider-level question. The agent currently infers the remaining questions from content blocks, plan state, and loop return values.

RFC-023 defines a state chain:

```text
GenerationStop
    → ResponseValidity
    → AgentDecision
    → StepOutcome
    → TurnOutcome
```

No later stage may infer completion from an earlier stage alone.

---

## 4. Design Goals

1. A normal provider stop without meaningful text or executable action must never complete a user task.
2. Thinking-only, whitespace-only, and empty responses must have explicit recovery behavior.
3. Native tools and CodeAct blocks must be detected before final-answer handling.
4. A valid tool-driven workflow may run through an arbitrary number of Acts.
5. Recovery is bounded by failure class, not by total Act count.
6. Same-Act recovery must roll back the unusable response before retrying.
7. Each response attempt must be observable.
8. A stalled or failed turn must not be logged as `task_completed`.
9. Plan watchdog enforcement must remain separate from provider generation termination.
10. ACP must report the actual turn outcome.

---

## 5. Non-Goals

RFC-023 does not introduce:

- A maximum number of Acts per user turn.
- A maximum number of tools per user turn.
- A maximum duration for a horizontal task.
- A semantic completion judge.
- A requirement that a completed task mutate a file.
- A new planning format.
- A new provider SDK.
- A change to the meaning of valid native tool execution.
- A change to the meaning of valid CodeAct execution.

A long horizontal task remains allowed because every valid native tool action or CodeAct execution resets transient response-recovery state.

---

## 6. Typed State Model

### 6.1 GenerationStop

Replace the provider-level interpretation of `StopReason` with:

```zig
pub const GenerationStop = enum {
    natural_end,
    tool_call,
    max_tokens,
    stop_sequence,
    stream_aborted,
    missing_terminal_event,
    content_filter,
    provider_error,
};
```

Mapping for the OpenAI-compatible backend:

| Wire event | `GenerationStop` |
|---|---|
| `finish_reason: "stop"` | `.natural_end` |
| `finish_reason: "tool_calls"` or `"function"` | `.tool_call` |
| `finish_reason: "length"` | `.max_tokens` |
| stop sequence event | `.stop_sequence` |
| idle watchdog abort | `.stream_aborted` |
| stream closes without explicit terminal reason | `.missing_terminal_event` |
| content filter | `.content_filter` |
| HTTP/provider failure | `.provider_error` |

The important change is:

```text
missing terminal event → missing_terminal_event
missing terminal event → never natural_end
```

The terminal event state is explicit in the streaming context:

```zig
terminal_event_received: bool = false,
```

For Chat Completions, a non-null `finish_reason` sets the state. For Responses API, `response.completed` sets the state. A bare `[DONE]` marker may finalize the transport, but it does not prove a natural model completion if no explicit response status or finish reason was received.

### 6.2 ResponseValidity

Response validity is derived from normalized content blocks after the backend response is parsed:

```zig
pub const ResponseValidity = enum {
    final_text,
    native_tool_calls,
    codeact,
    thinking_only,
    whitespace_only,
    partial_text,
    malformed_tool_call,
    empty,
};
```

Classification rules:

| Condition | Validity |
|---|---|
| Non-whitespace `.text` and no executable action | `.final_text` |
| One or more valid `.tool_use` blocks | `.native_tool_calls` |
| Executable ` ```js...``` ` block in text | `.codeact` |
| `.thinking` exists without text/tool/codeact | `.thinking_only` |
| Text exists but trims to empty | `.whitespace_only` |
| Stream abort or missing terminal event with partial text | `.partial_text` |
| Malformed tool call or invalid action payload | `.malformed_tool_call` |
| No normalized content | `.empty` |

A thinking block is diagnostic and optional continuation context. It is not a final answer.

### 6.3 AgentDecision

The agent computes one decision per response:

```zig
pub const AgentDecision = enum {
    execute_native_tools,
    execute_codeact,
    deliver_final_answer,
    request_continuation,
    retry_transient,
    fail_stalled,
    fail_protocol,
    cancel,
};
```

The decision is calculated in this precedence order:

```text
1. cancelled signal
2. malformed tool/action payload
3. valid native tool calls
4. valid CodeAct block
5. meaningful final text
6. partial-text recovery
7. thinking-only/empty recovery
8. protocol/provider failure
```

The stop reason is an input to this decision. It is never the decision itself.

### 6.4 StepOutcome and TurnOutcome

An Act is not a user turn. An Act can execute a tool, recover, or fail while the user turn remains pending.

```zig
pub const StepOutcome = enum {
    actions_executed,
    final_answer,
    continuation_requested,
    transient_retry,
    protocol_failure,
    provider_failure,
    cancelled,
};

pub const TurnOutcome = enum {
    completed,
    stalled,
    failed,
    blocked,
    cancelled,
};
```

Mapping:

| Final agent decision | Step outcome | Turn outcome |
|---|---|---|
| `execute_native_tools` | `actions_executed` | Pending |
| `execute_codeact` | `actions_executed` | Pending |
| `deliver_final_answer` | `final_answer` | `completed` |
| `request_continuation` | `continuation_requested` | Pending |
| successful `retry_transient` | `transient_retry` | Pending |
| exhausted `retry_transient` | `transient_retry` | `stalled` |
| `fail_protocol` | `protocol_failure` | `failed` |
| provider retries exhausted | `provider_failure` | `failed` |
| cancellation | `cancelled` | `cancelled` |

---

## 7. Backend Changes

### 7.1 Remove implicit natural completion

The following behavior must be removed from the OpenAI-compatible backend:

```zig
if (self.response.stop_reason == .unknown and !finish_reason_received) {
    self.response.stop_reason = .end_turn;
}
```

When the stream closes without a terminal event, the backend must:

1. Preserve partial text, thinking, and tool-call data.
2. Set `.missing_terminal_event`.
3. Preserve a bounded raw diagnostic.
4. Return the response to the agent decision layer.

The backend must not decide that the user task is complete.

### 7.2 Explicit terminal state

The streaming context must record:

- `terminal_event_received`.
- `terminal_event_kind`, when recognized.
- `finish_reason_received`.
- Whether finalization happened through `[DONE]`, explicit response completion, or EOF.

The state is used for diagnostics and recovery classification. It is not serialized as raw credentials or unbounded provider output.

### 7.3 Partial tool calls

A `max_tokens` response with an incomplete tool call must not execute the tool. The adapter must preserve safe text, discard malformed tool arguments, and let the agent request continuation or report stalled.

The same rule applies to a missing terminal event if the tool call was not closed and validated.

### 7.4 Backward-compatible logging

The Act log and journal may temporarily retain the serialized field `stop_reason` for existing consumers, but it must contain the normalized `GenerationStop`. New fields are required for agent-level state:

```json
{
  "generation_stop": "natural_end",
  "response_validity": "thinking_only",
  "agent_decision": "retry_transient"
}
```

New control flow must not infer task completion from the legacy field name.

---

## 8. Agent Decision Flow

### 8.1 Capture the Act history boundary

Before sending a model request, record:

```zig
const history_len = self.history.messages().len;
```

The boundary is used to rollback only the current Act response during transient recovery. It must not truncate earlier Acts or user history.

### 8.2 Parse and append response

After receiving the backend response:

1. Reset the response-specific classification state.
2. Classify the response before adding it to model-visible history.
3. Detect native tool calls.
4. Detect an executable CodeAct block.
5. Detect meaningful final text.
6. Detect thinking-only, whitespace-only, partial, malformed, or empty payloads.
7. Append a usable response to history or retain an unusable response only in bounded diagnostic storage.

The current call order in `src/core/agent_step.zig:784-795` must become an explicit decision function rather than stop-reason dispatch.

### 8.3 Native tool precedence

If valid native tool calls exist:

```text
append assistant tool call
execute native tools
append tool results
record StepOutcome.actions_executed
keep TurnOutcome pending
```

A native tool response never produces `TurnOutcome.completed`, even if the provider also reports `.natural_end`.

### 8.4 CodeAct precedence

If no native tool call exists and the text contains an executable CodeAct block:

```text
append assistant CodeAct text
execute CodeAct
append execution observation
record StepOutcome.actions_executed
keep TurnOutcome pending
```

CodeAct failure is a tool execution failure, not an empty final answer. Its existing retry/error policy remains separate from provider response recovery.

### 8.5 Final answer

The response is a final answer only when:

- No valid native tool call exists.
- No executable CodeAct block exists.
- `GenerationStop == .natural_end`.
- At least one text block contains non-whitespace content.

Then:

```text
record StepOutcome.final_answer
set TurnOutcome.completed
write task_completed once
```

A final answer does not require a file mutation. Analysis, audit, research, and inspection tasks are allowed to complete with text only.

### 8.6 Thinking-only recovery

For `GenerationStop == .natural_end` and `ResponseValidity == .thinking_only`:

1. Do not write `task_completed`.
2. Save bounded diagnostic metadata: thinking length, completion tokens, HTTP code, and generation stop.
3. Do not add the partial thinking to model-visible history.
4. Increment the `thinking_only` recovery counter for the current Act.
5. If the counter is below the budget, add one synthetic continuation observation.
6. Retry the same Act.
7. If the budget is exhausted, set `TurnOutcome.stalled` and write `task_stalled`.

The synthetic observation must describe the actual condition:

```text
[System] The previous response ended after reasoning without a final answer or tool call. Continue the same Act and produce either a substantive final answer or exactly one valid action.
```

The raw partial thinking text is not copied repeatedly into provider-visible history. A bounded diagnostic copy may be retained in the Act log.

### 8.7 Empty and whitespace recovery

For `.empty` or `.whitespace_only`:

- Use the same same-Act retry structure without retaining an unusable assistant message.
- Keep a separate `empty_response` recovery counter.
- Do not describe a thinking-only response as empty.
- If the budget is exhausted, set `TurnOutcome.stalled`.

### 8.8 Missing terminal event

For `.missing_terminal_event`:

- If safe partial text exists, request continuation rather than final delivery.
- If only thinking or no content exists, use the same-Act transient recovery budget.
- If the provider repeats the missing terminal event, report `TurnOutcome.stalled`.
- Never convert the missing terminal event into `natural_end`.

### 8.9 Stream abort

For `.stream_aborted`:

- If partial text can be safely continued, request continuation.
- If tool calls are incomplete, do not execute them.
- If there is no resumable content, use a bounded `stream_aborted` recovery budget.
- Exhaustion produces `TurnOutcome.stalled`.

### 8.10 Stop sequence

Remove `.stop_sequence` from the natural final-answer dispatch path.

A stop sequence is a controlled interruption:

- Resume when continuation is safe.
- Otherwise fail stalled.
- Never produce `TurnOutcome.completed` solely because the stop reason is `.stop_sequence`.

---

## 9. Recovery Budget

Recovery is a failure-class budget, not a task-duration limit.

```zig
pub const ResponseRecoveryBudget = struct {
    thinking_only_retries: u8 = 2,
    empty_response_retries: u8 = 20,
    missing_terminal_retries: u8 = 20,
    stream_aborted_retries: u8 = 20,
};
```

The budget is scoped to the current Act and current user turn.

The budget resets when:

- A valid native tool call is executed.
- A valid CodeAct block is executed.
- A valid final answer is delivered.
- A new user turn begins.

The budget does not reset merely because:

- The advisory is injected.
- The same thinking-only response occurs in the next Act.
- A different Act number is reached.
- The provider returns a new HTTP 200 response with the same failure class.

A valid long horizontal task remains unrestricted because each valid action resets the recovery budget. The budget terminates only repeated unusable provider responses.

### 9.1 Same-Act retry identity

The retry must preserve the Act identity:

```text
Act 52, attempt 1 → provider error
Act 52, attempt 2 → thinking-only, recovery class thinking_only
Act 52, attempt 3 → thinking-only, recovery class thinking_only
Act 52 → task_stalled
```

The Act id must not advance for a response-recovery retry. The attempt number must be visible in the Act log and journal.

---

## 10. Plan Watchdog and Completion

The plan watchdog remains an agent-level policy. It must run only after the response has a valid final text candidate.

### 10.1 Valid final text

For meaningful final text:

1. Set `AgentDecision.deliver_final_answer`.
2. Call `handleEndTurnWatchdog()`.
3. If watchdog returns `.no_action`, set `TurnOutcome.completed`.
4. If watchdog returns `.continue_loop`, set `AgentDecision.request_continuation` and keep the turn pending.
5. If watchdog reaches its existing cap, set `TurnOutcome.stalled` with reason `plan_stalled`.

### 10.2 No mutation requirement

The watchdog must not require a recent file mutation before accepting a final answer. Mutation evidence is only one completion signal for implementation tasks and must not block valid research, audit, analysis, or inspection answers.

The RFC-022 provenance rules remain active:

- Only verifiable structured plans are enforceable.
- Plan-only requests follow the plan-only exception.
- Descriptive text containing implementation keywords is not automatically an active enforceable plan.

### 10.3 Remove duplicate completion writes

Only the outer turn lifecycle writes the terminal event. `handleEndTurnStop()` must not write `task_completed` directly.

The outer lifecycle writes exactly one of:

```text
task_completed
task_stalled
task_failed
task_interrupted
```

---

## 11. Journal and Act Logging

### 11.1 New journal events

Add:

```zig
llm_generation_ended,
llm_response_invalid,
agent_decision,
task_stalled,
task_failed,
```

Keep `act_completed` as a backend/Act event. It does not imply user-turn completion.

### 11.2 Response attempt record

Every model response attempt records:

```json
{
  "act_id": 52,
  "attempt": 2,
  "http_code": 200,
  "generation_stop": "natural_end",
  "response_validity": "thinking_only",
  "agent_decision": "retry_transient",
  "recovery_class": "thinking_only",
  "has_text": false,
  "has_tool_calls": false,
  "has_thinking": true,
  "thinking_length": 1314,
  "completion_tokens": 367
}
```

The record must not include credentials or unbounded raw SSE data.

### 11.3 Attempt storage

The existing Act filename may remain for compatibility, but each retry must be distinguishable. The implementation must use one of:

- Attempt suffix in the Act filename.
- An append-only response event stream keyed by `act_id` and `attempt`.
- A single Act record containing an array of response attempts.

The selected mechanism must preserve the first HTTP 500 attempt and the later HTTP 200 unusable response as separate attempts.

### 11.4 Terminal turn event

The terminal turn event is based on `TurnOutcome`:

| Outcome | Journal event | Meaning |
|---|---|---|
| `completed` | `task_completed` | Meaningful final text delivered |
| `stalled` | `task_stalled` | Recovery budget exhausted or plan stalled |
| `failed` | `task_failed` | Protocol/provider failure |
| `cancelled` | `task_interrupted` | User/system cancellation |

---

## 12. ACP Interface

ACP must derive `stopReason` from `TurnOutcome`, not from a default initialized to `end_turn`.

| Turn outcome | ACP `stopReason` |
|---|---|
| `completed` | `end_turn` |
| `stalled` | `stalled` |
| `failed` | `error` |
| provider retries exhausted | `provider_unavailable` |
| rate limit exhausted | `rate_limited` |
| `cancelled` | `cancelled` |
| `blocked` | `blocked` |

The current hardcoded default at `src/acp/server.zig:293` must be removed. An empty ACP prompt may return `end_turn` only because no agent task was started; it must not be used as a fallback for an agent failure.

---

## 13. API Result Contract

To avoid requiring ACP and other callers to infer the result from side effects, `processInputWithImages()` must return a terminal result:

```zig
pub const TurnResult = struct {
    outcome: TurnOutcome,
    generation_stop: GenerationStop,
    response_validity: ResponseValidity,
    last_agent_message: ?[]const u8,
    act_count: usize,
    recovery_attempts: usize,
};
```

Callers can then map the result deterministically. Errors reserved for process-level failures remain Zig errors; normal terminal workflow outcomes are represented by `TurnResult.outcome`.

---

## 14. Implementation Plan

### Phase 1: Protocol and backend state

- Add `GenerationStop`.
- Add terminal-event state to the OpenAI-compatible streaming context.
- Stop converting unknown EOF into natural completion.
- Preserve partial data for recovery.
- Reject incomplete tool calls.
- Add backend tests for explicit stop, missing terminal event, max tokens, and stop sequence.

### Phase 2: Response classification

- Add `ResponseValidity`.
- Classify native tools before final text.
- Classify CodeAct before final text.
- Detect thinking-only, whitespace-only, partial, malformed, and empty responses.
- Add unit tests for all response shapes.

### Phase 3: Agent decision layer

- Add `AgentDecision`.
- Replace direct `handleEndTurnStop()` completion inference.
- Route native tools and CodeAct through explicit action decisions.
- Route valid final text through watchdog and terminal completion.
- Route no-action anomalies through recovery or stalled outcomes.

### Phase 4: Same-Act recovery

- Capture `history_len` before the model call.
- Remove unusable responses from model-visible history.
- Add failure-class recovery budgets.
- Preserve Act identity during recovery.
- Return distinct `completed`, `stalled`, `failed`, and `cancelled` outcomes.
- Add regression tests for repeated thinking-only responses.

### Phase 5: Journal and ACP

- Record every attempt with generation stop, validity, and decision.
- Add `task_stalled` and `task_failed`.
- Remove duplicate task completion writes.
- Return `TurnResult` from the public agent API.
- Map ACP stop reasons from `TurnResult.outcome`.

### Phase 6: Verification

- Run `zig build test --summary all`.
- Run the OpenAI-compatible streaming fixtures.
- Run Act 52 regression fixture with a 500 attempt followed by 200 thinking-only response.
- Run repeated thinking-only responses and verify `task_stalled`.
- Run a long native-tool workflow and verify no global Act limit is applied.
- Run a long CodeAct workflow and verify the same.
- Verify `task_completed` is not emitted for stalled or failed turns.

---

## 15. Test Matrix

| Case | Expected decision | Expected turn result |
|---|---|---|
| Natural stop + meaningful text | `deliver_final_answer` | `completed` |
| Natural stop + valid native tool | `execute_native_tools` | Pending |
| Natural stop + executable CodeAct | `execute_codeact` | Pending |
| Natural stop + thinking-only | `retry_transient` | Pending until budget, then `stalled` |
| Natural stop + whitespace-only | `retry_transient` | Pending until budget, then `stalled` |
| Natural stop + no content | `retry_transient` | Pending until budget, then `stalled` |
| HTTP 500 followed by valid text | Provider retry then final answer | `completed` |
| HTTP 500 followed by thinking-only | Same-Act recovery | Pending or `stalled` |
| EOF without terminal event | Protocol recovery | Pending or `stalled` |
| Max tokens + partial text | Continuation | Pending or `stalled` |
| Max tokens + incomplete tool call | Drop tool, recover | Pending or `stalled` |
| Stop sequence + partial text | Continuation | Never `completed` by stop reason |
| Valid action after 100 Acts | Execute action | Pending |
| Plan watchdog retry exhausted | `fail_stalled` | `stalled` |
| User cancellation | `cancel` | `cancelled` |
| ACP stalled result | N/A | `stopReason: "stalled"` |
| ACP completed result | N/A | `stopReason: "end_turn"` |

---

## 16. Acceptance Criteria

RFC-023 is satisfied when:

1. A missing terminal event is never mapped to natural completion.
2. Thinking-only, whitespace-only, and empty responses never produce a final answer.
3. Native tools and CodeAct are classified before final-answer handling.
4. Repeated thinking-only responses retry the same Act with a failure-class budget.
5. A response recovery retry preserves Act identity and attempt history.
6. Long horizontal workflows have no global Act limit.
7. Tool-only responses do not complete the user turn.
8. `task_completed` is emitted exactly once and only for meaningful final text.
9. Watchdog exhaustion produces `task_stalled`, not `task_completed`.
10. Journal and Act logs distinguish generation stop, response validity, agent decision, and attempt.
11. ACP maps the actual `TurnOutcome` instead of a hardcoded success default.
12. The Act 52 regression scenario is covered by a deterministic fixture.

---

## 17. Risks and Mitigations

| Risk | Mitigation |
|---|---|
| A compatible provider omits a terminal event on otherwise valid output | Allow one bounded missing-terminal retry, record the event, then return stalled |
| A provider intentionally emits no text for a valid task | Require a substantive final answer; classify repeated absence as stalled rather than false completion |
| Strict final-answer validation blocks a valid analysis task | Do not require mutation; any non-whitespace final text is valid |
| Recovery budget is mistaken for an Act limit | Scope it to failure class and current Act; reset after valid actions |
| CodeAct and native tool precedence changes existing behavior | Add focused tests for both action types before changing dispatch |
| Existing journal consumers read `stop_reason` | Keep the serialized field during migration and add typed fields alongside it |
| Attempt logs expose sensitive content | Store bounded metadata and sanitized content only |
| Plan watchdog reports stalled after a valid final answer | Apply watchdog only to verifiable active plans and preserve the RFC-022 exceptions |

---

## 18. Related RFCs

- RFC-002 provides Act Journal and CAS rollback foundations.
- RFC-006 provides normalized OpenAI-compatible streaming response handling.
- RFC-009 defines thinking and reasoning-effort behavior.
- RFC-019 defines structured plan lifecycle and plan enforcement.
- RFC-022 defines plan provenance and false-positive watchdog protections.

RFC-023 changes termination classification, response validity, recovery identity, and turn outcome reporting. It does not impose a maximum workflow length and does not require every task to mutate a file.
