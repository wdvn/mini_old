# RFC-007: REPL Chat Stream & Turn UI Optimization

- **Author:** mini-agent team
- **Date:** 2026-08-25
- **Status:** Implemented / Production
- **Scope:** `src/ui/`, `src/core/agent.zig`, `src/ui/repl.zig`, `src/ui/chat_stream.zig`

---

## 1. Context & Objectives

In modern AI Coding Agent CLIs (such as Claude Code, Aider, Codex CLI), the terminal interface is not merely raw streaming text or cluttered `stderr` logs. The user experience during a single turn lifecycle decisively determines how smooth, intuitive, and professional the tool feels.

### State Prior to RFC-007 in `mini`:
1. **Output Stream Collisions (`stdout` vs `stderr`)**: Tool logs and agent status wrote to `stderr`, while AI responses wrote to `stdout`. Unsynchronized flushing caused text overwrites and jitter.
2. **Scrollback Pollution**: `<think>` reasoning blocks and loop iteration logs dumped hundreds of raw lines without bounding boxes or summaries.
3. **Lack of Visual Tool Feedback**: When calling `file_edit` or `mini.patch()`, users saw no visual Diff (`+`/`-`); `bash` or `codeact` only showed a single `[ok]` line.
4. **Missing Telemetry & Context Window Metrics**: Users had no visibility into consumed tokens, response latency, or remaining context window percentage (especially critical for MemAct - RFC-003).

### Objectives of RFC-007:
- Build UI primitives 100% in standard Zig (ANSI styling, Box drawing, non-blocking Braille spinner).
- Establish a clear visual hierarchy for each turn: **User Prompt Card → Reasoning Block → Action Cards & Diff View → Streaming Markdown & Code Highlight → Telemetry Footer**.
- Ensure high performance: zero heap fragmentation, smooth flicker-free streaming.

---

## 2. Visual Hierarchy Design

```
╭─ ❯ You ────────────────────────────────────────────────────────────────────────╮
│  Refactor readAll in src/core/utils.zig and verify tests                       │
╰────────────────────────────────────────────────────────────────────────────────╯

 💭 Thinking (1.8s)
 │  Model is analyzing utils.zig structure and identifying related test cases...

 ⚡ Action [1/2]  mini.read("src/core/utils.zig")
    ✓ Read 184 lines (6.2 KB) • 12ms

 ⚡ Action [2/2]  mini.patch("src/core/utils.zig")
    ╭── src/core/utils.zig ──────────────────────────────────────────────────────╮
    │ @@ -45,7 +45,7 @@ pub fn readAll(...) !usize {                            │
    │ -    var total: usize = 0;                                                 │
    │ +    var total_read: usize = 0;                                            │
    │ ╰──────────────────────────────────────────────────────────────────────────╯
    ✓ Applied cleanly • CAS hash: a1f8...

 🤖 mini-agent
 Refactored the `readAll` function to optimize buffer memory:

 ```zig
 // src/core/utils.zig
 pub fn readAll(io: std.Io, file: std.Io.File, buf: []u8) !usize { ... }
 ```

 ─────────────────────────────────────────────────────────────────────────────────
 📊 1,248 tokens (480 reasoning) • 2.4s • Context: 18.5k/128k (14%) • 2 acts
```

---

## 3. UI Module Architecture

```
src/ui/
  ├── terminal.zig        — ANSI styling, 16/256 colors, UTF-8 box characters, cursor helpers
  ├── spinner.zig         — Live non-blocking Braille spinner + stopwatch timer
  ├── diff_renderer.zig   — Unified Diff visualizer (Red/Green syntax, line numbers, CAS hash)
  ├── markdown.zig        — Streaming lightweight Markdown & Syntax highlighter
  ├── chat_stream.zig     — TurnRenderer orchestrator managing the full 1-turn lifecycle
  ├── repl.zig            — Connects TurnRenderer into REPL loop
  ├── paste.zig           — Incremental bracketed paste state machine
  └── editor.zig          — Single-line composer & input parser
```

### 3.1. `terminal.zig`: ANSI Primitives & Box Characters
- Provides standard ANSI escape code constants: Bold (`\x1b[1m`), Dim (`\x1b[2m`), Italic (`\x1b[3m`), Reset (`\x1b[0m`).
- 16-color palette and UTF-8 box drawing characters (`╭`, `─`, `╮`, `│`, `╰`, `╯`, `⚡`, `✓`, `✗`, `💭`, `📊`, `🤖`, `❯`).
- Cursor control functions: `clearLine()`, `hideCursor()`, `showCursor()`.

### 3.2. `spinner.zig`: Non-blocking Braille Spinner
- Braille character set: `⠋`, `⠙`, `⠹`, `⠸`, `⠼`, `⠴`, `⠦`, `⠧`, `⠇`, `⠏`.
- Execution stopwatch timer tracking (`std.time.milliTimestamp`).
- In-place line updates using `\r\x1b[2K` to avoid scrollback noise.

### 3.3. `diff_renderer.zig`: Unified Diff Visualizer
- Analyzes patch / file edit contents:
  - Additions (`+`): Green (`\x1b[32m`).
  - Deletions (`-`): Red (`\x1b[31m`).
  - Hunk Header (`@@`): Cyan (`\x1b[36m`).
  - Automatically draws bounding frames and summarizes diffs exceeding maximum lines.

### 3.4. `markdown.zig`: Streaming Markdown & Code Highlighter
- Ultra-lightweight state machine (Zero-allocation) processing stream chunks:
  - Headers (`#`, `##`, `###`) → Bold prominent text.
  - Inline Code (`` `...` ``) → Yellow with dark background.
  - Code Block (````lang ... ````) → Framed border and syntax highlighted keywords (Zig, JS, Rust, Python, Go, Shell).
  - Maintains a small lookahead buffer so split delimiters between chunks (e.g., partial `**` across boundaries) do not break parsing.

### 3.5. `chat_stream.zig`: Turn Orchestrator
- `TurnRenderer` struct tracking the lifecycle of an interaction turn:
  - `startTurn(prompt)`: Initializes turn, prints header card.
  - `startThinking()` / `streamThinking(text)` / `endThinking()`: Streams reasoning inside dim vertical border `│` with FNV-1a deduplication filter.
  - `startTool(name, input_json)`: Displays Action card with spinner.
  - `finishTool(name, result, is_error, duration_ms)`: Prints action result and optional diff.
  - `streamResponse(text)`: Streams response through Markdown highlighter.
  - `finishTurn(stats)`: Prints telemetry footer summarizing tokens, latency, and context usage.

### 3.6. Inplace Stream Replacement & Raw Backend Error Formatting
- **Inplace Overwrite on Retry**:
  - Upon encountering recoverable backend errors (HTTP 429 Rate Limit, HTTP 503 Overloaded, Cloudflare 520/522/524), `TurnRenderer` records the retry line and uses VT100 sequence `\x1b[1A\x1b[2K\r` to overwrite countdown messages in place, eliminating terminal spam.
- **Display Safety (Anti-Wrap Truncation)**:
  - `visibleWidth` accurately computes terminal visual width (stripping ANSI escape codes, counting 2 columns for full-width East Asian and Vietnamese wide runes) and `truncateAnsi` truncates lines based on window width (`term_cols`), preventing automatic line wrapping from breaking `\x1b[1A` cursor arithmetic.
- **Formatted Backend Raw Response**:
  - When backend errors include structured bodies, `formatRawBackendResponse` extracts standard fields (`error.message`, `error.code`, `metadata.limit_source`, `metadata.remedy_hint`). For non-standard payloads, it pretty-prints indented JSON in an alert box so users see the exact cause without truncation.

---

## 4. Backward Compatibility & Non-interactive Mode
- When running single-shot prompts (`mini -e "..."`) or piping to file/command (`!isatty`), dynamic spinners and ANSI styling are simplified or disabled to prevent breaking automated scripts.
- Adheres strictly to: zero external dependencies, strict Zig 0.16.0 compliance.
