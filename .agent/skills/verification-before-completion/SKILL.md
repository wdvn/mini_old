---
name: verification-before-completion
description: "Use before claiming work is complete, fixed, or passing, or before committing/creating PRs. Run fresh verification commands and quote actual output (exitCode + stdout) as evidence; no success claims without evidence in this message."
---

# Verification Before Completion Skill

Standard gate for asserting success in `mini`: evidence before claims, always. No status claim without fresh verification output from THIS message.

---

## 1. When to Activate This Skill?

- Before claiming work is complete, fixed, or passing.
- Before committing, pushing, or creating a PR.
- When reporting subagent results (a subagent's "success" is not evidence).
- Before expressing satisfaction or moving to the next task.

---

## 2. The Iron Law

```
NO COMPLETION CLAIMS WITHOUT FRESH VERIFICATION EVIDENCE IN THIS MESSAGE
```

Previous outputs, memory of earlier turns, or agent reports are not evidence. If you have not run the verification in THIS message, you cannot claim it passes.

---

## 3. The 5-Step Gate

Before claiming any status or expressing satisfaction:

```
1. IDENTIFY: What command proves this claim?
2. RUN:      Execute the FULL command fresh (mini.sh, or mini.shBackground for long ones)
3. READ:     Full stdout/stderr, check exitCode, count failures
4. VERIFY:   Does the output confirm the claim?
             - If NO: state the actual status with the output
             - If YES: state the claim WITH the output quoted
5. ONLY THEN: make the claim
```

Skip any step = lying, not verifying.

---

## 4. mini Execution Rules

- **Repo changes**: verify with `mini.sh("cd /home/mypc/projects/mini && zig build test --summary all")`. All 13/13 steps must pass (unit + CodeAct/security + E2E mock LLM). Faster iteration without Node: `zig build test -Dskip-e2e=true`.
- **Command checks**: `mini.sh` returns `{ exitCode, stdout, stderr, ok }`. Quote `exitCode` and the relevant `stdout` lines as evidence — e.g. `[exitCode: 0] ... 13/13 steps passed` — never paraphrase success without quoting output.
- **Watchdog**: mini kills hung sync actions. Long builds/tests may not survive a sync `mini.sh` call — split into bounded commands, or use `mini.shBackground("zig build test --summary all")` and poll with `mini.jobStatus(jobId)` / `mini.jobLogs(jobId, 50)`. Never claim completion from a killed job; re-run and capture the real result.
- **Subagents**: verify their claims independently — read changed files, run the check yourself, inspect the VCS diff.

---

## 5. Common Failures

| Claim | Requires | Not Sufficient |
|-------|----------|----------------|
| Tests pass | `zig build test --summary all` output: 13/13 pass, 0 failures | Previous run, "should pass" |
| Build succeeds | `mini.sh` exitCode 0 from `zig build` | Linter output, logs look good |
| Bug fixed | Re-run original repro command: exitCode 0 / expected output | Code changed, assumed fixed |
| Regression test works | Red-green verified (fails without fix, passes with) | Test passes once |
| Agent completed | VCS diff + independent check shows the changes | Agent reports "success" |
| Requirements met | Line-by-line checklist against the plan, each item verified | Tests passing |

---

## 6. Red Flags — STOP

- "should", "probably", "seems to"
- Satisfaction words before verification ("Great!", "Perfect!", "Done!")
- About to commit/push/PR without a fresh run
- Trusting subagent success reports
- Partial verification ("that one check passed")
- "just this once" / tired / different wording — spirit over letter: ANY implication of success requires evidence

---

## 7. Key Patterns

```
OK:   mini.sh("zig build test --summary all") -> quote "[exitCode] 0 ... 13/13" -> "All tests pass"
FAIL: "Should pass now" / "Looks correct"

OK:   write test -> run (FAILS, quote output) -> apply fix -> run (PASSES, quote output)
FAIL: "I've written a regression test" without the red-green cycle
```

Applies to exact phrases, paraphrases, and any implication of completion or correctness.
