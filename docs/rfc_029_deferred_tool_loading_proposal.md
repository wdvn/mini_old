# RFC-029: Deferred Tool Loading with Cache-Aware Prompt Management

**Status**: Accepted (default-on)
**Issue**: #20
**Supersedes**: none

## 1. Problem

In `.tools`/`.auto` execution mode, every turn sends the full tool registry to the
model: 14 built-in tools **plus ALL mounted MCP tools** with complete JSON schemas
(`registry.zig getRelevantDefinitions`). Costs:

1. **Token bloat** — prompt size grows linearly with mounted MCP servers, on every
   act of every turn, even when the task uses only `bash` + `file_edit`.
2. **Cache prefix churn** — plan-driven filtering (`filterDefinitionsForPlan`)
   drops/re-adds tools between turns; Claude's `cache_control` breakpoints sit at
   the last tool entry, so any array mutation invalidates the tools-prefix cache.
3. **Attention dilution** — dozens of schemas compete with the actual task in the
   context window.

Pi 1.0 demonstrates the pattern: a `tool_search` meta-tool lets the model fetch
schemas on demand; tool definitions are materialized into the prompt only when
needed, and changes are appended positionally so the prompt cache stays valid.

## 2. Design

### 2.1 Tool tiers

| Tier | Tools | Sent to model |
|------|-------|---------------|
| **Essential core** | `bash`, `file_write`, `file_edit`, `http_request`, `skills` | Always (deferred mode) |
| **Meta** | `tool_search` (new) | Always (deferred mode) |
| **Deferred** | `invoke_subagent`, `batch_invoke_subagents`, `session_diagnostics`, `artifact_*`, `generate_image`, `generate_video`, `image_attach`, and every MCP tool | Only after promotion |

### 2.2 `tool_search` meta-tool

- Input: `query` (tool name or keyword), optional `limit` (default 10).
- Behavior: case-insensitive substring match against name + description of all
  non-sent tools (built-in deferred + MCP). Returns a JSON array of the matched
  tools' full definitions (`name`, `description`, `input_schema`).
- The tool is always *executable* (dispatch is unaffected — only the **definitions
  list** is restricted), so a call in the same act succeeds; promotion makes it
  visible for subsequent acts.

### 2.3 Promotion (grow-only, cache-stable)

- Session-level promotion set (mutex-guarded, grow-only): when a tool is matched
  by `tool_search`, or when an act actually invokes a deferred tool, or when a
  plan step's `tool_hint` names one, it is promoted.
- Deferred-mode tool list per act = essential core + `tool_search` + promoted tools
  in first-promotion order (deterministic; appended at the **tail** so earlier
  entries keep a stable prefix for provider prompt-cache — e.g. Claude's
  `cache_control` on the last tool moves forward as the list grows, never
  rewrites earlier entries).
- Never shrinks within a process lifetime → no cache invalidation from churn.

### 2.4 Per-act re-resolution

`executeTurnWorker` re-resolves the tool list at the start of each act when
deferred mode is on (previous acts' promotions become visible). In `.tools`
mode the `codeact` definition is still excluded; `.auto` keeps it.

### 2.5 Plan-aware filtering (RFC-019 interplay)

In deferred mode, `filterDefinitionsForPlan`'s drop-everything-else behavior is
replaced by **promotion**: a plan step's `tool_hint` promotes that tool instead of
mutating the sent list — preserving the cache prefix.

### 2.6 Configuration

- `Config.deferred_tool_loading: bool = true` (default on, all users).
- Opt-out: `MINI_DEFERRED_TOOLS=0|false` (safety valve, e.g. backends that
  strongly dislike meta-tool round-trips).
- No behavior change for `.codeact` mode (tool list is empty there; `mini.*` API
  is static and unchanged). MCP tools remain reachable in `.tools`/`.auto`
  through search → call.

### 2.7 Explicitly out of scope (follow-ups)

- `injectSemanticMemory` mutating the system prompt per act (cache-breaker for
  the system block) — separate RFC.
- Claude write-side `cache_control` breakpoint repositioning beyond tail-append
  stability.
- CodeAct-mode MCP exposure (`mini.mcpCall` binding).

## 3. Code surfaces

| File | Change |
|------|--------|
| `src/tooling/registry.zig` | `tool_search` definition + handler; global `g_deferred_enabled` (default true) + setter; promotion set + `promoteTool`/`resolveDeferredTools`; `getRelevantDefinitions` unchanged for legacy mode |
| `src/core/agent/turn.zig` | `resolveTurnToolDefinitions` deferred branch; plan-hint promotion instead of drop-filter |
| `src/core/agent/turn.zig` (`executeTurnWorker`) | Re-resolve tool list per act (deferred mode) |
| `src/core/agent/execution.zig` | Promote invoked tool names after native tool execution |
| `src/core/config/types.zig` + `resolvers.zig` | `deferred_tool_loading` flag + `MINI_DEFERRED_TOOLS` env |
| `src/main.zig` | Wire `tools_mod.setDeferredToolsEnabled(cfg.deferred_tool_loading)` |
| `testcases/test_deferred_tool_loading.zig` | Integration tests |

### 3.1 Implementation notes (deviation from the sketch above)

The promotion set is stored in a **static buffer** (`promoted_tools[64][96]u8` +
`promoted_tools_len[64]`), not an `ArrayListUnmanaged`. Reason: callers pass
per-turn arenas (`turn_alloc`), which are freed at turn end — heap-owning
promotion entries would dangle and double-free. Names are copied inline, so the
set has no allocator ownership and survives the whole process lifetime.

`promoteTool` normalizes the name (alias → canonical) and **skips tools that
are already essential**, so entries stay minimal and the sent list never
carries duplicates.

Snapshotting the set into a local list uses an explicit index loop
(`while (i < promoted_count)`) rather than `for (a, b) |x, y|` over two arrays;
multi-slice iteration over a `[N][M]u8` + `[N]usize` pair silently yielded only
the last entry.

## 4. Success criteria

- Deferred mode: default tool list ≤ 6 definitions regardless of MCP count.
- `tool_search` returns usable full schemas within one act; the tool is callable
  from the following act (promotion).
- List ordering is deterministic and grow-only across acts/turns.
- `MINI_DEFERRED_TOOLS=0` restores legacy behavior exactly.
- `zig build test --summary all` → 13/13 steps pass.
