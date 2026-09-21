---
name: root-cause-analysis
description: Root Cause Analysis (RCA), debugging complex issues, reproducing incidents, and hypothesis validation. Use when investigating bugs, unhandled errors, crashes, timeouts, or unexpected behaviors in the codebase.
---

# Root Cause Analysis (RCA) Skill

Standard methodology for investigating, isolating, and identifying root causes of technical issues in `mini`.

---

## 1. When to Activate This Skill?

- When runtime errors occur (`UnknownStopReason`, `LLMAuthorizationError`, panics, crashes).
- When output does not meet expectations (logic bugs, incorrect metrics, duplicate events).
- When deadlocks, timeouts, lingering background threads, or resource leaks are detected.
- When the user's request is ambiguous or unclear — first clarify what they are asking.

---

## 2. Step 0: Deconstruct & Interpret the User's Question

Before launching into any technical investigation, explicitly analyze what the user is asking. This prevents solving the wrong problem.

### 2.1 Identify the Real Problem (Problem Domain)
- **Type of issue**: Runtime error? Logic bug? Performance? Config issue? Feature request? Documentation gap?
- **Component scope**: Backend (AI provider)? Agent loop? CodeAct VM? UI/REPL? Tooling? Memory/History? Concurrency?
- **Symptoms**: Crash/panic, wrong output, timeout, silent failure, UI glitch?

### 2.2 Identify True User Intent
- **Explicit intent**: What the user said directly.
- **Implicit intent**: What they actually need but didn't state (e.g., "fix it" vs "explain why it happened").
- **Success criteria**: How will they know the issue is resolved?

### 2.3 Gather Context Factors
- **Environment**: OS, Zig version, backend provider, model, API key status.
- **Recent changes**: New commits, config edits, dependency updates?
- **Reproducibility**: Can it be reliably reproduced? Single-turn or multi-turn?

### 2.4 Priority & Scope
- **Urgency**: Blocking issue? Degraded UX? Cosmetic?
- **Blast radius**: One user? All users? Specific backend only?

**Output of Step 0** — summarize into one sentence:
> *"The user is reporting [problem] in [component], with symptoms [symptoms]. They want [true intent]. Initial hypothesis: [hypothesis]."*

---

## 3. Critical Thinking Frameworks

Apply critical thinking frameworks throughout the RCA process to avoid cognitive biases and go down the wrong path.

### 3.1 Cognitive Biases to Recognize & Counter

| Bias | Manifestation in RCA | How to Counter |
|------|---------------------|----------------|
| **Confirmation Bias** | Only seek evidence supporting the initial hypothesis, ignore contradicting data | Actively seek evidence *against* your hypothesis |
| **Anchoring Effect** | Stop at the first symptom observed, miss deeper signals | Ask "what else?" — check logs, journal, full HTTP response |
| **Sunk Cost Fallacy** | Continue pursuing a wrong hypothesis because time was already invested | Be ready to abandon a hypothesis when clear disproof exists |
| **Hasty Generalization** | Conclude cause from 1–2 isolated cases | Check for patterns — can the issue be reproduced? Are there exceptions? |
| **Fundamental Attribution Error** | Blame the code ("buggy code") instead of system/handler error | Ask: Is the code working as designed? Is the input correct? Is the config correct? |
| **Narrative Fallacy** | Create a "plausible" story without evidence | Every conclusion step must have evidence, not speculation |
| **Curse of Knowledge** | Skip details because "it's obvious" | Re-check every assumption, don't skip any step even if trivial |

### 3.2 Red-Teaming & Falsification

Rule: **"Prove the hypothesis WRONG, not RIGHT"**:
- For each hypothesis H, ask: *"If H is false, what would we observe?"*
- Design test cases to **falsify** — if you can't falsify it, the hypothesis is not strong enough.
- Use **inversion**: *"If the issue did NOT exist, what would be different?"*

### 3.3 Edge-Case Stress Test

Check these corner cases after each hypothesis:
- Empty input (empty string, zero-length slice)
- Unicode / emoji / surrogate pairs in JSON/SSE
- Abrupt EOF — stream cut off mid-chunk
- Concurrent access — race condition between main thread and worker
- Memory pressure — OOM, allocator failure
- Zero/negative timeout, zero/negative retry count
- Extremely large payloads (context overflow)
- Malformed HTTP headers / SSE formatting

### 3.4 Alternative Hypothesis Generation

Always generate ≥2 alternative hypotheses before choosing:
```
H1: [Primary hypothesis] — evidence...
H2: [Alternative 1] — evidence...
H3: [Alternative 2] — evidence...
```
Select the hypothesis with **strongest explanatory power + highest falsifiability**, not the one that "feels right."

### 3.5 Counterfactual Reasoning

Ask counterfactual questions:
- *"If I replace X with Y, does the issue disappear?"*
- *"If Z were absent, would the issue still occur?"* (separate causal from coincidental)
- *"Does the issue also occur on a different backend?"* (isolate component)

---

## 4. 5-Step Investigation Methodology

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
- **⚠️ Critical Thinking**: Don't trust the first symptom — verify across at least 3 independent sources (logs, journal, direct observation).

### Step 2: Scope Isolation & Reproduction
- Isolate the scope: Where does the issue originate?
  - *Network / AI Provider*: Upstream rejection, rate limits, quota exhaustion?
  - *Data Parsing / Protocol*: SSE chunking, JSON escaping, header formatting?
  - *Runtime / Concurrency*: Race condition between main thread and worker threads?
  - *State Management*: History compaction, context overflow, state rollback?
- Write a standalone testcase in `testcases/test_<issue>.zig` to reproduce behavior where feasible.
- **⚠️ Critical Thinking**: If the issue cannot be reproduced → it may be a race condition, state-dependent, or environment-specific. Do not dismiss it just because it doesn't reproduce consistently.

### Step 3: Apply the 5-Whys Technique

Ask "Why?" repeatedly to avoid stopping at surface symptoms:
*Example*:
1. *Why did the agent report UnknownStopReason?* -> Because `response.stop_reason` returned `.unknown`.
2. *Why was stop_reason unknown?* -> Because the backend returned HTTP 403 with body "customer_verification_required".
3. *Why did the agent retry 4 times?* -> Because the error switch matched the fallback `else` branch instead of classifying an auth error.
4. *Root Cause*: Missing `LLMAuthenticationError` classification for HTTP 401/403 to fail-fast immediately.

**⚠️ Critical Thinking**:
- Stop when reaching an **actionable root cause** (one that can be fixed), not when you run out of "whys."
- If a "why" has multiple answers → split into branches, don't merge.
- **Avoid** circular 5-Whys (circular reasoning): A because B, B because A.

### Step 4: Data-Driven Validation

- **Falsification first**: Design test cases to **disprove** the hypothesis, not to prove it correct.
- **Challenge assumptions**: "If this hypothesis is true, what else must be observable?"
- **Check corner cases** (see §3.3): empty body, partial chunks, unicode, zero-length, abrupt EOF, concurrency.
- **Cross-source verification**: Journal evidence must match HTTP response; HTTP response must match logs.

### Step 5: Conclusion & Remediation Proposal
- Clearly present: (1) Symptoms, (2) Verified Evidence, (3) Root Cause, (4) Proposed Action Plan.
- **STOP ACTION LOOP**: Report findings and await user confirmation. Never mutate the system without user alignment.
- Upon confirmation, apply fixes with minimal blast radius and run regression tests.
- **⚠️ Critical Thinking**: After the fix, ask *"Can this issue reappear in a different form?"* — identify preventive measures (guard rail, assertion, test case).
