# Issue & Design Proposal: Standardizing Security Policy, Hooks Dispatch & Journaling for CodeAct Runtime

| Attribute | Value |
|---|---|
| Issue Code | ISSUE-CODEACT-001 |
| Title | Standardize Security Policy, Hooks Dispatch & ActJournaling for CodeAct Runtime |
| Status | **Resolved / Implemented** (All 8 items completed; covered by 45 tests in `testcases/test_codeact_security.zig`) |
| Scope | `src/runtime/js_bindings.zig`, `src/runtime/quickjs_engine.zig`, `src/core/agent.zig` |
| Date | 2026-08-23 |

---

## 1. Problem Statement

The Code-Centric Agent (CodeAct) architecture of `mini-agent` allows the LLM to generate JavaScript code executed directly within an embedded CodeAct VM via the global `mini.*` object (`mini.sh`, `mini.read`, `mini.write`, `mini.patch`, `mini.http`, etc.).

Based on analysis of recent real-world execution sessions, tool execution through JS CodeAct was **separated from the core control mechanisms of the Agent Loop**, introducing 4 critical vulnerabilities:

### 1.1. Tool Allowlist / Blocklist Policy Bypass
- Configuration variables `MINI_TOOL_ALLOWLIST` and `MINI_TOOL_BLOCKLIST` (or settings in `config.json`) were previously checked only at the JSON Tool-Calling layer (`src/core/agent.zig` -> `executeToolCall`).
- The C-bindings in `src/runtime/js_bindings.zig` (`jsMiniSh`, `jsMiniWrite`, `jsMiniPatch`, etc.) called the tool execution functions directly WITHOUT checking security policies.
- **Consequence**: If a user configured `MINI_TOOL_BLOCKLIST=bash`, the Agent was blocked when using JSON tool-calling but could still execute shell commands via `mini.sh("rm -rf ...")` in CodeAct.

### 1.2. Monitoring Hook System Bypass (`MINI_HOOK_COMMAND`)
- Prehook / Posthook commands (`MINI_HOOK_COMMAND`) were only triggered in `AgentLoop.executeStep` when the Agent used JSON Tool-Calling.
- System operations executed by JS CodeAct (`mini.sh`, `mini.write`, `mini.http`) completely bypassed hook events (`pre-tool-use`, `post-tool-use`), disabling user background auditing and monitoring.

### 1.3. Missing File Snapshot Tracking for Event-Sourcing (ActJournal)
- File write/patch operations via `mini.write()` and `mini.patch()` operated directly on the filesystem without persisting `FileSnapshot` records (before/after hash + content backup) in `ActJournal` (conforming to RFC-002).
- **Consequence**: Inability to audit file mutation history caused by CodeAct and inability to rollback broken operations when a task fails.

### 1.4. Non-descriptive Self-Correction Error Feedback
- When a JS script threw an exception or a `mini.sh` command failed in CodeAct, the error message returned to the LLM was sometimes missing contextual information or was truncated, reducing the Agent's self-correction capabilities on subsequent turns.

### 1.5. Variable Scope Pollution Across Turns (Global Variable Scope Pollution across Acts)
- Previously, the CodeAct engine executed JS code blocks from the LLM using `c.JS_Eval(ctx, ..., c.JS_EVAL_TYPE_GLOBAL)`. All JS code blocks in the same session shared a single global `JSContext`.
- **Direct Consequence**: If the Agent declared `const data = mini.read(...)` or `const lines = ...` at the top level in Turn 1, reusing `const data = ...` at the top level in Turn 2 caused CodeAct to immediately throw `SyntaxError: Identifier 'data' has already been declared`. *(Thoroughly resolved with Per-Act VM Isolation)*.

### 1.7. LLM Emitting Pseudocode XML Tags (`<file_read>`, `<glob>`, `<bash>`) Instead of JavaScript ````js ... ```` Blocks in CodeAct Mode
- When CodeAct mode is enabled (`MINI_EXECUTION_MODE=codeact`), the native `tools` array in the API payload is hidden to suppress Native Function Calling. However, some LLMs (such as DeepSeek, Claude, Ollama) when lacking the `tools` array in the API payload tended to invent pseudo-XML tags (e.g., `<file_read file="..." />`, `<glob pattern="..." />`, `<bash command="..." />`) in their text response instead of generating a ````js ... ```` block.
- **Direct Consequence**: Previously `findJsCodeInResponse` did not scan pseudo-XML tags and returned `null`. Concurrently, the HTTP response stream completed (`stop_reason = .end_turn`), causing `AgentLoop` to mistakenly assume the turn was finished and **exit early (`✓ Completed after 1 iteration`)** without executing any operation.

### 1.8. HTTP 520 / 522 Cloudflare Errors from LLM Providers Misclassified as `UnknownStopReason`
- When communicating with LLM Providers through Cloudflare Gateway (e.g. DeepSeek V4 Pro API), the gateway returns HTTP error codes `520` (Web Server Unknown Error) and `522` (Connection Timed Out).
- **Direct Consequence**: The old HTTP error handling logic in `AgentLoop` only hardcoded checks for `500`, `502`, `503`. Codes `520` and `522` fell into the default `.unknown` branch and threw `UnknownStopReason`. This corrupted journal logs (`error_name: "UnknownStopReason"`) and bypassed the provider retry / Ollama fallback workflow.

### 1.9. Proactive 85% Context Compaction Causing Token Waste & Early Loss of Detail
- Previously `AgentLoop` estimated token count and proactively triggered MemAct Compaction (re-summarizing history via LLM) as soon as history reached 85% of the context window capacity before sending the request.
- **Direct Consequence**: Expensive, unnecessary summarization API calls even when the model could handle the context, while eroding detailed context from earlier turns prematurely.

---

## 2. Proposed Architecture

```
[Agent Context / Config / Journal]
               │
               ▼
   ┌──────────────────────┐
   │    CodeAct Engine    │
   └──────────┬───────────┘
              │ Calls mini.sh() / mini.write()
              ▼
   ┌────────────────────────────────────────────────────────┐
   │ C-Bindings (`src/runtime/js_bindings.zig`)             │
   │                                                        │
   │ 1. Check Config.isToolAllowed(tool_name) ──► Block? ──┐ │
   │ 2. Dispatch Pre-Hook (MINI_HOOK_COMMAND)              │ │ (Throw JS Exception)
   │ 3. Snapshot File (ActJournal)                         │ │
   │ 4. Execute Native Tool                                │ │
   │ 5. Dispatch Post-Hook                                 │ │
   └────────────────────────┬───────────────────────────────┘
                            │ Success / Clean Output
                            ▼
                    [JS Result Return]
```

### 2.1. Delegate Security Policy Checks to `js_bindings.zig`
- Every `jsMini*` binding function must verify the `allowlist` / `blocklist` from `Config` before executing tools.
- If prohibited, return `c.JS_ThrowTypeError(ctx, "Security Policy Error: Tool '%s' is blocked by configuration", tool_name)`.

### 2.2. Integrate Hook Dispatcher into the JS Runtime
- Pass `HookCommand` callbacks/references into `Engine` / `JSContext`.
- Before critical `mini.*` operations (`sh`, `write`, `patch`, `http`), invoke `hooks_mod.dispatchPreToolUse()`.
- After completion, invoke `hooks_mod.dispatchPostToolUse()`.

### 2.3. Register File Snapshots in ActJournal
- When `mini.write(path, content)` or `mini.patch(path, old, new)` is invoked:
  1. Capture a snapshot of the existing file into `ActJournal` (if the file exists).
  2. Perform file write/patch operation.
  3. Record the supplemental `file_snapshot` event into the journal.

### 2.4. Standardize Self-Correction Error Formatting
- Wrap CodeAct errors in a standardized format:
  ```
  [CodeAct JavaScript Execution Failed]
  Error Type: <TypeError / ReferenceError / RuntimeError>
  Message: <Error Message>
  Stack Trace:
    at <function> (<file>:<line>)
  ```
- Clear formatting helps the LLM immediately recognize error causes and produce accurate self-correction code in subsequent turns.

### 2.5. Total Isolation via Fresh JSContext for Each Act Execution (Per-Act VM Isolation)
- Instead of reusing a single global `JSContext` across a session or using Anonymous Block Wrapping `{ ... }` (which still risks `globalThis` or prototype pollution), `quickjs_engine.zig` **creates a 100% clean `JSContext` for each Act execution**.
- Execution lifecycle for each run (`eval`):
  1. Allocate a pristine `JSContext` (`c.JS_NewContext(rt)`) from `JSRuntime`.
  2. Re-register built-in objects (`console.log`, `mini.*` C-bindings).
  3. Execute LLM JavaScript code in a fully sterile environment.
  4. Free `JSContext` immediately after execution finishes (`c.JS_FreeContext(ctx)`).
- **Benefits**: Completely eliminates 100% of variable scope pollution (`const`/`let`/`var`), function name collisions, memory leaks, and hidden side effects between turns in the same session.

### 2.6. Automatically Suppress `tools` Array in API Requests in CodeAct Mode / Auto-Prompt Tuning
- To eliminate LLM RLHF Bias toward Native Tool Calls:
  1. **Hide `tools` array in API Payload**: When `execution_mode == .codeact` (or CodeAct preference is active), `AgentLoop` passes an empty `&[_]proto.ToolDefinition{}` array to the backend. Without the `tools` parameter in the API payload, LLMs immediately disable native function calling and output CodeAct JS code.
  2. **Tighten System Prompt Framing**: Adjust the System Prompt in `config.zig` from an optional recommendation to an explicit directive: `"For all tools and automation, you MUST write JavaScript code within ```js ... ``` blocks using the global mini.* object"`.

### 2.8. Automatic Pseudo-XML Tool Tag Conversion to `mini.*` JavaScript Code
- Added extraction and automatic translation in `convertXmlToolTagsToJs` in `src/core/agent.zig`:
  1. When `findJsCodeInResponse` finds no markdown ````js ... ```` code blocks, automatically scan response text for pseudo-XML tags such as `<file_read>`, `<glob>`, `<grep>`, `<bash>`, `<file_write>`.
  2. Extract attributes and automatically generate equivalent JS execution code (e.g., `mini.read(path)`, `mini.glob(pattern, path)`, `mini.sh(cmd)`).
  3. Execute the JS code in the CodeAct VM, log stdout, and continue the loop (`.continue_loop`) instead of exiting the run (`✓ Completed after 1 iteration`).

### 2.9. Extended HTTP 5xx Error Recognition & Automatic Retry Backoff
- Updated HTTP status code error categorization in `AgentLoop.executeStep`:
  - Map all status codes where `response.http_code >= 500 and response.http_code < 600` (including Cloudflare 520, 521, 522, 524) to `error.LLMProviderUnavailable`.
  - Enables `AgentLoop` to correctly log `.llm_provider_error` events in the journal, trigger exponential backoff retry, and fall back to local Ollama when the primary backend is unavailable.

### 2.10. Reactive Emergency Context Compaction
- Completely eliminated proactive compaction based on the 85% token estimation threshold.
- Switched to reactive compaction when the model returns an actual context overflow error (`error.LLMContextWindowExceeded` / HTTP 400 `context_length_exceeded`):
  1. Record `.llm_context_overflow` event in the journal.
  2. Execute `compactContext(act_id)` (MemAct compaction or fallback simple compact).
  3. Retry (`continue`) the turn with compacted context.

---

## 3. Code Modifications

| File | Changes |
|---|---|
| `src/runtime/quickjs_engine.zig` | Added pointers/references to `Config`, `ActJournal` in `Engine` struct; Switched to allocating & freeing fresh `JSContext` per `eval` for 100% execution isolation |
| `src/runtime/js_bindings.zig` | Check allowlist/blocklist, dispatch hooks, and capture file snapshots before executing `mini.sh`, `mini.write`, `mini.patch` |
| `src/core/agent.zig` | Pass `Config` and `ActJournal` instances to `Engine` on init; Suppress `tool_defs` payload when `execution_mode == .codeact`; Added `convertXmlToolTagsToJs`, HTTP 5xx classification, and reactive `compactContext` on overflow |
| `src/core/config.zig` | Strengthened explicit CodeAct directives in default System Prompt, prohibiting pseudo-XML tags |
| `src/tooling/registry.zig` | Registered `codeact` as standardized Native Tool Definition |
| `testcases/test_codeact_as_tool.zig` | Integration test verifying `codeact` native tool execution |
| `testcases/test_codeact_security.zig` | [NEW] Integration test verifying `MINI_TOOL_BLOCKLIST`, Hook Dispatcher, and Per-Act VM Isolation in CodeAct |

---

## 4. Implementation Milestones

- [x] **M1: Per-Act VM Isolation**: Updated `quickjs_engine.zig` to instantiate a fresh `JSContext` per `eval` and deinit immediately after, ensuring 100% isolation.
- [x] **M2: Security Enforcement**: Integrated allowlist/blocklist checks into `js_bindings.zig`.
- [x] **M3: Hook Integration**: Added pre-hook and post-hook dispatching for `mini.*` functions.
- [x] **M4: Journal Snapshot Integration**: Integrated `ActJournal` snapshots into `mini.write` and `mini.patch`.
- [x] **M5: Tool-Calling Suppression**: Suppressed `tools` array when `execution_mode == .codeact` and tightened prompt framing.
- [x] **M6: Native Tool Standardization**: Registered `codeact` as a native tool in registry and CodeAct runtime handler.
- [x] **M7: XML Tool Tag Auto-Conversion**: Automatically convert pseudo-XML tags (`<file_read>`, `<glob>`, `<bash>...`) to CodeAct JS code and continue Act loop.
- [x] **M8: HTTP 5xx Cloudflare Error Standardization**: Extended HTTP 5xx classification (520, 522...) to `LLMProviderUnavailable` for backoff retry.
- [x] **M9: Reactive Emergency Context Compaction**: Replaced 85% proactive compaction with reactive context compaction upon receiving `LLMContextWindowExceeded`.
- [x] **M10: Testing & Verification**: Wrote integration testcases in `testcases/test_codeact_security.zig` and ensured `zig build test` passes 100%.
