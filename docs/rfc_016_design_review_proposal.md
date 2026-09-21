# RFC-016: Design & Architecture Review — mini-agent

| Attribute | Value |
|---|---|
| **Status** | Draft |
| **Author** | mini-agent Review |
| **Date** | 2025-07-18 |
| **Tracks** | Platform portability, Thread safety, Error handling, Config consistency |

---

## 1. Summary

This RFC documents design and architectural issues discovered during a comprehensive code review of mini-agent (96 `.zig` modules, 3467-line agent loop, 3-thread runtime, 15 built-in tools). Issues are categorized by severity with explicit acceptance criteria.

---

## 2. Critical Issues

### C1 — Linux Platform Coupling

**Problem**: 30+ occurrences of `std.os.linux.*` across the codebase make the project Linux-only despite cross-compilation claims.

**Affected files**:
- `src/core/agent.zig` — `std.os.linux.timespec`, `clock_gettime`
- `src/core/journal.zig` — `extern fn getpid`
- `src/runtime/js_bindings.zig` — `std.os.linux.getpid()`
- `src/tools/session_diagnostics.zig` — `std.os.linux.*`
- `src/core/act_logger.zig` — `std.os.linux.*`
- `src/ui/repl.zig` — `std.os.linux.*`
- `src/acp/server.zig` — duplicate `extern fn getpid`

**Checklist**:
- [ ] Replace all `std.os.linux.*` with `std.posix.*` (uniform POSIX API in Zig 0.16)
- [ ] Remove 9 duplicate `extern fn getenv` declarations — consolidate into `core/utils.zig`
- [ ] Remove 7 duplicate `extern fn getpid` declarations — use `std.posix.getpid()`
- [ ] Add CI target for macOS (`x86_64-apple-darwin`)
- [ ] Verify cross-compile: `zig build -Dtarget=x86_64-apple-darwin`
- [ ] Document supported platforms in README

---

### C2 — Global Mutable State (Thread Safety)

**Problem**: 3-thread architecture (RFC-015) + ACP server share process space, but critical globals have no synchronization.

**Affected globals**:
| Variable | File | Thread access pattern |
|---|---|---|
| `g_active_agent` | `core/agent.zig` | Thread 1 (REPL) + Thread 3 (Act) + ACP |
| `g_hook_cmd`, `g_hook_listener`, `g_tool_listener`, `g_output_listener` | `core/hooks.zig` | Any thread can set via `register_*` |
| `g_skills`, `g_skills_arena` | `core/skills.zig` | Read during act, could be reloaded |
| `g_mcp`, `g_allowlist`, `g_blocklist` | `tooling/registry.zig` | Modified by config reload |
| `g_pending_thinking` | `runtime/js_bindings.zig` | Set by provider, read by JS bindings |
| `current_renderer` | `ui/repl.zig` | Set by REPL, read by agent loop |

**Checklist**:
- [ ] Define `Session` struct that encapsulates all mutable state per interaction
- [ ] Pass `*Session` explicitly through `AgentLoop`, `TurnRenderer`, `JSBindings` call chains
- [ ] Protect `g_hooks` with a mutex or replace with per-session hook registration
- [ ] Protect `g_skills` — either freeze after init or add read-write lock
- [ ] Protect `current_renderer` — remove global, pass via `AgentLoop` context
- [ ] Add `ThreadSanitizer` to CI: compile with `-fthread-sanitizer` and run E2E tests
- [ ] Document thread ownership model in `AGENTS.md`

---

## 3. Major Issues

### M1 — Swallowed Errors (`catch {}`)

**Problem**: 183 occurrences of `catch {}` silently discard failures. 37 in `agent.zig` alone.

**Critical paths affected**:
```zig
// agent.zig:970 — tool call list append failure silent
.tool_use => |tu| tool_calls_list.append(self.alloc, tu) catch {},

// agent.zig:1237 — journal checkpoint write failure silent
j.recordEvent(self.io, act_id, .checkpoint_created, "...") catch {};

// agent.zig:1594 — procedural graph transition loss silent
pg.recordTransition(self.io, prev_tool, tool_name) catch {};

// agent.zig:1897 — rate limit backoff sleep failure silent
std.Io.sleep(self.io, ..., .awake) catch {};
```

**Checklist**:
- [ ] Audit all 183 `catch {}` occurrences — classify each as: safe-skip / log-and-skip / propagate
- [ ] For journal writes: propagate error or log to stderr with act ID context
- [ ] For rate-limit sleep: propagate error so caller can retry
- [ ] For non-critical debug logging: keep `catch {}` but add comment explaining why
- [ ] Add integration test verifying journal is writable (disk-full scenario)
- [ ] Add integration test verifying rate-limit sleep actually sleeps

---

### M2 — Hardcoded Constants Ignoring Config

**Problem**: `agent.zig` hardcodes limits instead of reading from `Config`.

| Constant | Hardcoded value | Config field | File:line |
|---|---|---|---|
| `max_tokens_continues` limit | `5` | `max_tokens_continue_cap` | `agent.zig:???` |
| Output buffer size | `64 * 1024` | *(none)* | `quickjs_engine.zig:61` |
| Backoff initial seconds | *(likely hardcoded)* | *(check config)* | `agent.zig` |

**Checklist**:
- [ ] Replace hardcoded `> 5` check with `self.config.max_tokens_continue_cap`
- [ ] Add `MINI_MAX_TOKENS_CONTINUE_CAP` env var documentation
- [ ] Make `MAX_OUTPUT_BUFFER` configurable via `MINI_JS_OUTPUT_BUFFER` (default 64KB)
- [ ] Emit warning when output buffer truncates: `"⚠️ CodeAct output truncated at 64KB"`
- [ ] Add unit test: script producing >64KB output triggers truncation warning

---

### M3 — System Prompt Embedded in Binary

**Problem**: 50+ line system prompt in `config.zig:382-430` string literal. No hot-reload.

**Checklist**:
- [ ] Extract prompt to `assets/system_prompt.md` in repository
- [ ] At runtime: if `MINI_SYSTEM_FILE` is set, load from file; else load from embedded asset
- [ ] Support SIGHUP signal to reload system prompt without restart
- [ ] Add `mini --reload-config` CLI subcommand
- [ ] Document in README: "System prompt can be customized via `MINI_SYSTEM_FILE`"
- [ ] Add test: custom system prompt is reflected in first turn

---

### M4 — Implicit CWD Dependency

**Problem**: 20+ calls to `std.Io.Dir.cwd()` create implicit path resolution dependency that breaks when subagents `chdir`.

**Affected modules**:
- `runtime/process_manager.zig:117`
- `runtime/js_bindings.zig:381,398`
- `acp/server.zig:245,281,533`
- `tooling/mcp.zig:377`
- `core/skills.zig:101,132`
- `core/artifacts.zig:56,100,104`

**Checklist**:
- [ ] Add `working_dir: std.fs.Dir` field to `Session` or `AgentContext`
- [ ] Thread `working_dir` through all tool execution paths
- [ ] Replace `std.Io.Dir.cwd()` calls with `self.ctx.working_dir`
- [ ] Subagent chdir: push new dir onto context stack, restore on exit
- [ ] Add integration test: subagent chdir does not affect parent's path resolution
- [ ] Document: "Mini always resolves relative paths against the session working directory"

---

## 4. Minor Issues

### mn1 — History Compaction Tier Stale

**Location**: `core/history.zig:compact()`

**Checklist**:
- [ ] After `copyForwards`, update `tier` field on compacted messages to `recent`
- [ ] Or: document that `tier` is advisory and callers should not depend on it post-compaction
- [ ] Add unit test: compact then verify tier values

### mn2 — No Tool Input Schema Validation

**Location**: `tooling/registry.zig:executeToolInternal()`

**Checklist**:
- [ ] Add optional schema validation in registry before dispatching to tools
- [ ] For each tool, compare required vs provided fields in input JSON
- [ ] Return structured error: `"Tool 'bash': missing required field 'command'"`
- [ ] Document tool input contract in each tool's doc comment
- [ ] Add test: malformed tool input returns validation error, not tool execution error

### mn3 — Test Coverage Gaps

**Checklist**:
- [ ] Add unit test for Claude backend SSE parsing (non-streaming + streaming)
- [ ] Add unit test for Ollama NDJSON parsing
- [ ] Add editor UI test: bracketed paste with mixed UTF-8 / ASCII
- [ ] Add editor UI test: Ctrl+A/E/U key handling
- [ ] Add procedural graph test: N>=3 transition learning triggers auto-injection
- [ ] Add MemAct compaction test: verify original prompt preserved at index 0
- [ ] Report coverage: `zig build test --coverage` and add to CI

---

## 5. Security Observations (No Action Required — For Awareness)

| Finding | Severity | Recommendation |
|---|---|---|
| No sandboxing beyond QuickJS defaults | Low-Med | Consider Cap'n Proto or seccomp filters for CodeAct scripts |
| Hook commands run with agent privileges | Low | Document security model; recommend users audit hook scripts |
| MCP servers run as child processes | Low | Already bounded by allowlist/blocklist |
| File write paths restricted from `/etc`, `/sys`, `/proc`, `/dev` | ✅ Good | — |

---

## 6. Implementation Priority

| Priority | Item | Estimated Effort | Blocking |
|---|---|---|---|
| P0 | M1 — Error handling audit | 2 days | Reliability |
| P0 | C2 — Thread-safe globals | 3 days | Concurrency stability |
| P1 | M2 — Config-driven constants | 0.5 day | Correctness |
| P1 | M3 — Externalize system prompt | 1 day | DX |
| P1 | M4 — Explicit CWD | 2 days | Subagent correctness |
| P2 | C1 — Platform abstraction | 2 days | Portability |
| P2 | mn2 — Tool input validation | 1 day | Robustness |
| P2 | mn3 — Test gaps | 3 days | Quality |
| P3 | mn1 — History tier fix | 0.5 day | Correctness |

**Total estimated effort: ~15 days**

---

## 7. Acceptance Criteria (All must pass before RFC closes)

- [ ] Zero `std.os.linux.*` references in `src/` (use `std.posix.*`)
- [ ] Zero duplicate `extern fn` declarations across modules
- [ ] Zero `catch {}` in `src/core/` and `src/runtime/` (all replaced with proper error handling)
- [ ] All hardcoded limits in `agent.zig` read from `Config`
- [ ] System prompt loads from `MINI_SYSTEM_FILE` when set
- [ ] No `std.Io.Dir.cwd()` calls — all resolved via explicit context
- [ ] ThreadSanitizer passes on full E2E test suite
- [ ] Test coverage for Claude, Ollama, Editor, Procedural Graph modules
- [ ] `zig build test` — all 13/13 steps pass
- [ ] `zig build test -Dskip-e2e=true` — all unit + security tests pass

---

## 8. References

- RFC-010: Procedural Graph (event-sourced directed graph)
- RFC-012: Provider Abstraction Layer
- RFC-015: Three-Thread Runtime & Unified Watchdog
- AGENTS.md: Project conventions and testing requirements
