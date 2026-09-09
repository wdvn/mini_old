# Proposal: mini-agent Editor Upgrade → Multiline Composer

> Date: 2025 — Reference: [vercel-labs/fx](https://github.com/vercel-labs/fx)
> Scope: `src/ui/editor.zig` (258 lines), `src/ui/repl.zig`

---

## 1. Current State

The legacy editor was **single-line, byte-based**:

- Static buffer `buf: [8192]u8`, silent truncation on overflow.
- Raw byte processing → typing UTF-8 (multibyte characters, emoji) misaligned cursor and broke terminal rendering.
- In-memory history (lost on process exit).
- Keymap: Ctrl+A/E/U, Backspace/Delete, Home/End (ESC O H/F), ↑/↓ history, Ctrl+C/D exit.
- Bracketed paste: newline → space (all pasted content collapsed into a single line).
- Manual escape parsing (ad-hoc guessing), no Alt+<key> support, ambiguous combo resolution.

**Consequences:** Unable to compose multiline prompts, pasting long code broke formatting, no undo, no copy/cut, no `@` file references.

---

## 2. Gap Analysis vs. fx

### Already Implemented (No rework needed)
| Feature | Notes |
|---|---|
| Single-line editing, cursor move | OK |
| In-memory History ↑/↓ | OK, lacks disk persistence |
| Ctrl+A/E/U, Home/End | OK |
| Basic bracketed paste | Present, but collapsed newline→space |
| Ctrl+C/D exit | OK |

### Missing — 13 Groups, Ordered by Dependency

| # | Group | Specific Feature (from fx) | Complexity | Priority |
|---|---|---|---|---|
| 1 | **UTF-8 / unicode width** | `display_width`, grapheme clusters, emoji, tab stops | Medium | 🔴 P0 |
| 2 | **Dynamic buffer** | `ArrayList(u8)` instead of `[8192]u8` | Easy | 🔴 P0 |
| 3 | **Word motion** | word_left/right, delete_word_left/right, text_boundaries | Easy | 🔴 P0 |
| 4 | **Multiline composer** | Alt+Enter insert_newline, visual_up/down, page_up/down, paragraph_up/down, draft navigation, preferred-column, composer_line_continuation (backslash) | Hard | 🔴 P0 |
| 5 | **Persistent history** | Save JSONL to disk: text + pasted blocks + skill tokens; Ctrl+P/N. *Note: this refers to **prompt input history** (what the user types into the composer, following fx's `prompt_history_store` model) — not conversation history; conversation history semantics conform to RFC-003.* | Medium | 🟠 P1 |
| 6 | **Large-paste placeholder** | Paste >1000 chars → `[pasted block]`, expand on submit | Medium | 🟠 P1 |
| 7 | **Undo/Redo + Kill ring** | Ctrl+Z/Y edit_history snapshot; Ctrl+W/K cut, Ctrl+Y yank (5-item ring) | Medium | 🟠 P1 |
| 8 | **Input limit + reject** | max_message_bytes, clear error display instead of silent truncation | Easy | 🟠 P1 |
| 9 | **Kitty keyboard protocol / modifyOtherKeys** | Precise resolution for Ctrl/Alt/Shift combos | Medium | 🟡 P2 |
| 10 | **Ctrl+L redraw, line-continuation** | Trivial addons | Easy | 🟡 P2 |
| 11 | **Selection** | anchor/extend, select_all, copy/cut selection, collapse | Hard | 🟡 P2 (requires multiline) |
| 12 | **Inline pickers** | @file, @model, @skill, slash-command autocomplete overlay | Hard | 🟢 P3 |
| 13 | **Image attachments** | Attach images to composer | Hard | 🟢 P3 (depends on transport) |

---

## 3. Proposed Architecture

### 3.1 Modular Decomposition (simplified fx model)

```
src/ui/
  editor.zig          → Orchestrator, receives input events
  composer.zig        → NEW: Multiline state (lines, 2D cursor, anchor selection)
  unicode.zig         → NEW: display_width, grapheme iteration, tab stops
  history.zig         → NEW: Persistent JSONL + in-memory ring (prompt input history — RFC-003 does not apply)
  edit_history.zig    → NEW: Undo/redo snapshots
  escape_parser.zig   → NEW: Replaces manual escape parsing, supports kitty protocol
  paste.zig           → NEW: Bracketed paste + placeholder + block store
```

### 3.2 Composer State (Replacing 1D Buffer)

```zig
pub const Composer = struct {
    lines: std.ArrayList([]const u8),   // Line content
    cursor: Position,                    // { row, col } by grapheme
    anchor: ?Position,                   // Selection anchor
    preferred_col: usize,                // Preserved column on up/down
    undo_stack: [16]Snapshot,            // Ring buffer
    redo_stack: [16]Snapshot,
    kill_ring: [5][]const u8,            // Ctrl+W/K/Y
    pasted_blocks: std.ArrayList(PastedBlock), // Placeholder refs
    max_message_bytes: usize,            // Input limit, reject instead of truncate
};
```

### 3.3 2D Render Pipeline

1. Calculate display_width for each grapheme (`unicode.zig`).
2. Wrap according to terminal width, track visual↔logical mapping.
3. Render from cursor row → upward; prompt prefix appears only on the first line.

---

## 4. 4-Phase Roadmap

### Phase 0 — Quick Wins (1–2 days)
- [ ] Dynamic buffer `ArrayList(u8)` (Group 2)
- [ ] UTF-8 display_width + grapheme cursor movement (Group 1)
- [ ] Word motion: Alt+B/F, Alt+D/Backspace (Group 3)
- [ ] Ctrl+L redraw, input limit + reject message (Groups 8, 10 partial)

**Definition of Done:** Multibyte UTF-8 and emoji render without distortion; word navigation works smoothly.

### Phase 1 — Multiline Composer (3–5 days) 🔴 Critical
- [ ] Separate `composer.zig`, 2D cursor, wrapping logic
- [ ] Alt+Enter insert newline, Enter submit
- [ ] visual_up/down, page_up/down, paragraph_up/down, preferred-column
- [ ] Backslash line-continuation upon Enter
- [ ] Multiline rendering: correctly erase line counts, prompt prefix on first line

**Definition of Done:** Compose 10-line prompts, navigate naturally like a real text editor.

### Phase 2 — History, Paste, Undo (3–4 days)
- [ ] Persistent history JSONL (text + timestamps), Ctrl+P/N alongside ↑/↓
- [ ] Large-paste placeholder: >1000 chars → `[Pasted block #n]`, expand upon submit
- [ ] Undo/Redo Ctrl+Z/Y (snapshot before each mutation)
- [ ] Kill ring Ctrl+W/K/Y

**Definition of Done:** Pasting 5000 lines does not freeze terminal, undo works, history survives restart.

### Phase 3 — Precise Input + Selection (3–4 days)
- [ ] Standard escape parser: CSI, SS3, kitty keyboard protocol, modifyOtherKeys
- [ ] Selection: Shift+motion set anchor, select_all via double-tap Ctrl+A
- [ ] Copy/cut selection, collapse
- [ ] Inline picker @file (glob) + slash-command (when command registry exists)

**Definition of Done:** Alt+<key> resolves 100%, select and copy text ranges, `@` autocompletes files.

---

## 5. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Multiline rendering conflicts with streaming model output | Only re-render composer zone, freeze layout while model streams |
| Kitty protocol unsupported on older terminals | Feature-detect via response query, fallback to CSI parsing |
| Snapshot undo consumes excessive RAM on large buffers | 16-entry ring buffer, diff-only or cap at 4KB/snapshot |
| Persistent history contains sensitive data | Opt-in via config, documented clearly; JSONL format allows easy auditing |

## 6. Out of Scope (Deferred)
- Image attachments (Group 13) — awaiting transport/model support.
- Mouse wheel navigation — deferred until composer stabilizes.
- @model/@skill picker — deferred until model/skill registry is available.
