---
name: root-cause-analysis
description: Root Cause Analysis (RCA), debugging complex issues, reproducing incidents, and hypothesis validation. Use when investigating bugs, unhandled errors, crashes, timeouts, or unexpected behaviors in the codebase.
---

# Root Cause Analysis (RCA) Skill

Standard methodology for investigating, isolating, and identifying root causes of technical issues in `mini`.

---

## 1. When to Activate This Skill?

- When runtime errors occur (`UnknownStopReason`, `LLMProviderUnavailable`, panics, crashes).
- When output does not meet expectations (logic bugs, incorrect metrics, duplicate events).
- When deadlocks, timeouts, lingering background threads, or resource leaks are detected.

---

## 2. 5-Step Investigation Methodology

```
[1. Symptom Collection]
       │
       ▼
[2. Isolation & Reproduction]
       │
       ▼
[3. 5-Whys Analysis & Hypothesis Formulation]
       │
       ▼
[4. Data-Driven Validation]
       │
       ▼
[5. Fix Proposal & Verification]
```

### Step 1: Collect Accurate Symptoms
- **Error name & Error trace**: Identify the exact Zig error name (`error.Name`) and stack trace.
- **HTTP status & Raw Response**: For AI backend errors, inspect the HTTP code (400, 401, 403, 429, 500, 529...) and raw JSON snippet returned by the server.
- **Logs & Journal**: Read the corresponding journal file in `~/.mini/sessions/journal_<pid>.jsonl`.

### Step 2: Scope Isolation & Reproduction
- Isolate the scope: Where does the issue originate?
  - *Network / AI Provider*: Upstream rejection, rate limits, quota exhaustion?
  - *Data Parsing / Protocol*: SSE chunking, JSON escaping, header formatting?
  - *Runtime / Concurrency*: Race condition between main thread and worker threads?
  - *State Management*: History compaction, context overflow, state rollback?
- Write a standalone testcase in `testcases/test_<issue>.zig` to reproduce behavior where feasible.

### Step 3: Apply the 5-Whys Technique
Ask "Why?" repeatedly to avoid stopping at surface symptoms:
*Example*:
1. *Why did the agent report UnknownStopReason?* -> Because `response.stop_reason` returned `.unknown`.
2. *Why was stop_reason unknown?* -> Because the backend returned HTTP 403 with body "customer_verification_required".
3. *Why did the agent retry 4 times?* -> Because the error switch matched the fallback `else` branch instead of classifying an auth error.
4. *Root Cause*: Missing `LLMAuthenticationError` classification for HTTP 401/403 to fail-fast immediately.

### Step 4: Validate Hypotheses
- Challenge assumptions: "If this hypothesis is true, what else must be observed? If false, why?"
- Check corner cases: empty response body, partial chunks, unicode characters, zero-length strings, abrupt EOF.

### Step 5: Conclusion & Remediation Proposal
- Clearly present: (1) Symptoms, (2) Verified Evidence, (3) Root Cause, (4) Proposed Action Plan.
- STOP ACTION LOOP: Report findings and await user confirmation. Never mutate the system without user alignment.
- Upon confirmation, apply fixes with minimal blast radius and run regression tests.
