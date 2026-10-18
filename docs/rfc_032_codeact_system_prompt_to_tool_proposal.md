# RFC-032: Migrate CodeAct Runtime Instructions from System Prompt to Native Tool Definition

- **Status**: Proposed
- **Author**: Antigravity Pair Programming
- **Date**: 2026-10-18
- **Area**: Core / Prompts / Tooling / Runtime
- **Target Version**: mini-agent v0.10+
- **Related Issues**: ISSUE-CODEACT-001, PR #1, PR #33

---

## 1. Executive Summary

This RFC proposes decoupling the **CodeAct** runtime instructions and `mini.*` JavaScript API manual from the global `system_prompt` and relocating them directly into the native **`codeact`** tool definition (`src/tooling/registry.zig`).

By doing so:
1. **System Prompt Token Reduction**: Eliminates ~90 lines (~1,200+ tokens) of tool-specific instructions from the base system prompt on every conversation turn.
2. **Elimination of Protocol Conflicts**: Resolves the contradiction where the system prompt declares `"TOOL EXECUTION IS CODEACT-ONLY. Never emit a tool_call object..."`, which breaks function-calling in `auto` mode and conflicts with MCP tools or native tools (`bash`, `skills`, `tool_search`).
3. **Symmetry in `auto` Mode**: In `auto` mode, the model receives `codeact` in its tool list with a complete, rich API definition, instead of being starved of `mini.*` API documentation.
4. **Architectural Encapsulation**: Restores tool encapsulation — tool capabilities, API signatures, execution constraints, and observation protocols belong to the tool's schema/description, not the agent's core persona.

---

## 2. Motivation & Current Pain Points

### 2.1. Bloated System Prompt & Cache Inefficiency

In `src/core/prompts.zig`, `codeact_execution_instructions` spans lines 32–120. When `execution_mode == .codeact`, `appendCodeActInstructions` (`src/core/config/types.zig`) appends this entire block to `cfg.system_prompt`:

```zig
pub fn appendCodeActInstructions(self: *Config, alloc: Allocator) void {
    if (self.execution_mode != .codeact) return;
    if (std.mem.indexOf(u8, self.system_prompt, "## CodeAct Execution Instructions") != null) return;
    const combined = std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{
        self.system_prompt,
        prompts_mod.codeact_execution_instructions,
    }) catch return;
    ...
}
```

This injects:
- Mandatory CodeAct Output Protocol (` ```js ` block requirements, anti-JSON tool_call warnings)
- JavaScript Execution Constraints (synchronous QuickJS execution, no top-level `await`, no `Promise`)
- Operational Modes (ReAct vs Proactive planning)
- The complete `mini.*` API reference (17 methods: `read`, `write`, `patch`, `exists`, `stat`, `glob`, `grep`, `sh`, `shBackground`, `jobStatus`, `jobLogs`, `jobKill`, `http`, `media`, `artifact`, `env`, `setThinking`)
- Batched information gathering guidelines
- ReAct interaction rules and discipline

This block consumes ~1,200 tokens on **every single LLM invocation**. Because it is conditionally appended depending on execution mode and overrides, it degrades prompt caching predictability across heterogeneous backends (OpenAI, Anthropic, Ollama).

### 2.2. Protocol Collision with Native Tool Calling

The prompt explicitly dictates:
> `"TOOL EXECUTION IS CODEACT-ONLY. When a task requires any tool, the only executable action is a single executable JavaScript block that calls the global mini object... A tool_call is not executable CodeAct syntax. Never emit a tool_call object or place it in a JSON/XML envelope."`

This rule directly contradicts:
- Multi-tool operations in `auto` mode where the model is expected to invoke native JSON tools (`bash`, `skills`, `session_diagnostics`).
- Dynamic MCP tools registered from external servers.
- Meta-tools like `tool_search` when deferred tool loading is active.

### 2.3. Asymmetry and Broken Knowledge in `auto` Mode

In `src/core/agent/turn.zig`:
- When `execution_mode == .codeact`: `raw_tool_defs = &[_]proto.ToolDefinition{}`. The model gets zero tool schemas, relying entirely on the system prompt block to write raw Markdown ` ```js ` blocks.
- When `execution_mode == .auto`: Tool definitions are exposed via `getRelevantDefinitions`, including `codeact`. **However**, because `execution_mode != .codeact`, `appendCodeActInstructions` **does not run**.
- Consequently, in `auto` mode, the model sees:
  ```json
  {
    "name": "codeact",
    "description": "Execute JavaScript in an embedded CodeAct VM with mini.* global API (mini.sh, mini.read, mini.write, mini.patch, mini.http, mini.sessions, mini.sessionDetail, mini.sessionKill, mini.setThinking). Use for automating complex multi-step logic or data processing.",
    "input_schema_json": "{\"type\":\"object\",\"properties\":{\"code\":{\"type\":\"string\",\"description\":\"JavaScript code to execute in CodeAct VM\"}},\"required\":[\"code\"]}"
  }
  ```
- The model is given **no signature documentation** for `mini.read(path, offset, limit)`, `mini.patch(path, old, new)`, `mini.grep(pattern, path)`, or `mini.glob(pattern)`. It also does not know that execution is synchronous and that outputs must be printed via `console.log(...)` to appear in Observation.

### 2.4. Tool Encapsulation Principle

Under clean agent design:
- **System Prompt**: Defines persona, general operating principles (grounding, surgical edits, verify empirically, stop on completion), reasoning, and safety.
- **Tool Definition**: Encapsulates all capabilities, input contracts, API specifications, and operational constraints needed to execute that specific tool.

---

## 3. Proposed Architecture & Technical Design

```
+-----------------------------------------------------------------------------------+
| BEFORE (Leaky System Prompt)                                                     |
|                                                                                   |
|  [System Prompt]                                                                  |
|   ├── Persona & General Principles                                                |
|   └── ## CodeAct Execution Instructions (~1,200 tokens)                           |
|        ├── Protocol: Output ```js, NO tool_call                                   |
|        ├── Constraints: Synchronous, no await                                     |
|        ├── mini.* Full API Manual (17 methods)                                    |
|        └── ReAct & Batching rules                                                 |
|                                                                                   |
|  [Tool: codeact] -> 1-sentence vague description (Missing API docs)               |
+-----------------------------------------------------------------------------------+

+-----------------------------------------------------------------------------------+
| AFTER (Clean Encapsulation)                                                      |
|                                                                                   |
|  [System Prompt] (Lean ~200 tokens, 100% cache-stable)                            |
|   └── Persona & General Principles (investigate before mutating, stop, verify)   |
|                                                                                   |
|  [Tool: codeact] (Self-contained Native Tool Schema & Documentation)              |
|   ├── Description: Embedded QuickJS VM rules (synchronous, console.log capture)  |
|   ├── Input Schema: "code" parameter with comprehensive mini.* API reference      |
|   │    ├── Filesystem: mini.read, mini.write, mini.patch, mini.exists, mini.stat  |
|   │    ├── Search: mini.glob, mini.grep                                           |
|   │    ├── Process/Shell: mini.sh, mini.shBackground, mini.jobStatus/Logs/Kill    |
|   │    ├── Network & State: mini.http, mini.env, mini.artifact, mini.skill        |
|   │    └── Governance: mini.setThinking("low"|"high")                             |
|   └── Execution contract: Batch multiple calls in 1 script; console.log output   |
+-----------------------------------------------------------------------------------+
```

### 3.1. Clean System Prompt

`src/core/prompts.zig`:
- Deprecate and remove `codeact_execution_instructions` from base system prompt assembly.
- Keep `default_system_prompt` focused purely on:
  1. Persona & role.
  2. Operating principles (investigate, surgical changes, verify empirically, stop on completion).
  3. Planning & communication discipline.

`src/core/config/types.zig` & `src/core/config/resolvers.zig`:
- Remove `appendCodeActInstructions(alloc)` and its invocations in `resolvers.zig` and `main.zig`.
- Remove `system_prompt_buf` reallocation overhead for appending CodeAct instructions.

### 3.2. Rich Tool Definition in `src/tooling/registry.zig`

Upgrade the `codeact` tool entry in `definitions`:

```zig
    .{
        .name = "codeact",
        .description = 
            \\Execute JavaScript in an embedded QuickJS engine with the synchronous `mini.*` runtime API.
            \\Execution is synchronous (no top-level `await`). Use `console.log(...)` to emit observations.
            \\Batch multiple operations into a single script to minimize round-trips.
            \\Available global APIs:
            \\- mini.read(path, offset?, limit?): Read lines from file.
            \\- mini.write(path, content): Create or overwrite file (auto-creates dirs, captures CAS).
            \\- mini.patch(path, oldStr, newStr, opts?): Surgical exact string replacement.
            \\- mini.exists(path): Check file or directory existence (returns boolean).
            \\- mini.stat(path): File metadata { size, is_file, is_dir, modified }.
            \\- mini.glob(pattern, basePath?): Wildcard path matching (returns string[]).
            \\- mini.grep(pattern, path?, opts?): Text/regex search across files.
            \\- mini.sh(command): Run shell command synchronously { exitCode, stdout, stderr, ok }.
            \\- mini.shBackground(command): Start background job { jobId, pid, logPath }.
            \\- mini.jobStatus(jobId): Query background job { running, exitCode, pid }.
            \\- mini.jobLogs(jobId, lines?): Inspect recent output lines from background job.
            \\- mini.jobKill(jobId, signal?): Terminate background job.
            \\- mini.http(method, url, opts?): HTTP request { status, body, headers }.
            \\- mini.artifact(name, content, opts?): Persist artifact document.
            \\- mini.skill(name, file_path?): Load skill instruction or sub-resource.
            \\- mini.env(name): Read environment variable.
            \\- mini.setThinking(levelOrTokens): Adjust reasoning budget ("low"|"medium"|"high").
            \\- console.log(...): Emit output to observation buffer.
        ,
        .input_schema_json =
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "code": {
            \\      "type": "string",
            \\      "description": "Executable JavaScript code calling mini.* APIs synchronously."
            \\    }
            \\  },
            \\  "required": ["code"]
            \\}
        ,
    },
```

### 3.3. Handling `execution_mode = .codeact` (Fallback Mode)

For users or local models running with `MINI_EXECUTION_MODE=codeact` (where tool calls are emitted as raw fenced ` ```js ` Markdown blocks rather than JSON tool calls):
- The agent loop can dynamically format the `codeact` tool's definition as an ephemeral tool prompt block if and only if raw text mode is selected.
- This preserves 100% backwards compatibility while keeping the primary `system_prompt` clean and single-sourced.

---

## 4. Work Breakdown & Implementation Plan

```
[Phase 1: Tool Registry Expansion]
 ├── Update src/tooling/registry.zig with rich description & mini.* API reference
 └── Add unit tests in testcases/test_codeact_as_tool.zig verifying rich schema

[Phase 2: System Prompt Decoupling]
 ├── Deprecate codeact_execution_instructions in src/core/prompts.zig
 ├── Remove appendCodeActInstructions from src/core/config/types.zig
 └── Clean up call sites in src/core/config/resolvers.zig and src/main.zig

[Phase 3: Mode Alignment & Tests]
 ├── Update testcases/test_workspace_context.zig (remove old assertion on system_prompt)
 ├── Run full unit test suite (zig build test-unit)
 └── Verify E2E mock server flows with tool call codeact
```

---

## 5. Acceptance Criteria

- [ ] `system_prompt` across all execution modes does **not** contain `## CodeAct Execution Instructions` or inline `mini.*` signatures.
- [ ] Base `system_prompt` token footprint is reduced by ~1,200 tokens (~80% reduction for base prompt).
- [ ] `registry.definitions` contains complete signatures and usage guidelines for all 17+ `mini.*` methods under the `codeact` tool entry.
- [ ] In `execution_mode == .auto`, the LLM receives the `codeact` tool definition containing the complete `mini.*` API reference.
- [ ] In `execution_mode == .codeact`, raw ` ```js ` execution continues to work seamlessly without regressions.
- [ ] All unit and integration testcases pass (`zig build test-unit`).
- [ ] Documentation updated in `docs/tools.md` and `docs/codeact_runtime.md`.
