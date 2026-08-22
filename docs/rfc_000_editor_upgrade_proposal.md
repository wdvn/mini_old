# Proposal: Nâng cấp Editor mini-agent → Multiline Composer

> Ngày: 2025 — Tham chiếu: [vercel-labs/fx](https://github.com/vercel-labs/fx)
> Phạm vi: `src/ui/editor.zig` (258 dòng), `src/ui/repl.zig`

---

## 1. Tình trạng hiện tại

Editor hiện tại là **single-line, byte-based**:

- Buffer tĩnh `buf: [8192]u8`, truncate im lặng khi vượt.
- Xử lý byte thô → gõ UTF-8 (tiếng Việt, emoji) làm lệch cursor và vỡ render.
- History in-memory (mất khi thoát process).
- Keymap: Ctrl+A/E/U, Backspace/Delete, Home/End (ESC O H/F), ↑/↓ history, Ctrl+C/D exit.
- Bracketed paste: newline → space (mọi paste đều dính thành 1 dòng).
- Escape parsing thủ công (đoán mò), không hỗ trợ Alt+<key>, không phân giải combo chính xác.

**Hệ quả:** không soạn được prompt nhiều dòng, paste code dài bị hỏng format, undo không có, không copy/cut, không tham chiếu file bằng `@`.

---

## 2. Gap analysis so với fx

### Đã có (không cần làm lại)
| Tính năng | Ghi chú |
|---|---|
| Single-line editing, cursor move | OK |
| History ↑/↓ in-memory | OK, thiếu persistence |
| Ctrl+A/E/U, Home/End | OK |
| Bracketed paste cơ bản | Có nhưng newline→space |
| Ctrl+C/D exit | OK |

### Thiếu — 13 nhóm, xếp theo dependency

| # | Nhóm | Tính năng cụ thể (từ fx) | Độ khó | Ưu tiên |
|---|---|---|---|---|
| 1 | **UTF-8 / unicode width** | `display_width`, grapheme cluster, emoji, tab stops | Trung bình | 🔴 P0 |
| 2 | **Buffer động** | `ArrayList(u8)` thay `[8192]u8` | Dễ | 🔴 P0 |
| 3 | **Word motion** | word_left/right, delete_word_left/right, text_boundaries | Dễ | 🔴 P0 |
| 4 | **Multiline composer** | Alt+Enter insert_newline, visual_up/down, page_up/down, paragraph_up/down, draft navigation, preferred-column, composer_line_continuation (backslash) | Khó | 🔴 P0 |
| 5 | **Persistent history** | Lưu JSONL ra disk: text + pasted blocks + skill tokens; Ctrl+P/N | Trung bình | 🟠 P1 |
| 6 | **Large-paste placeholder** | Paste >1000 chars → `[pasted block]`, expand khi submit | Trung bình | 🟠 P1 |
| 7 | **Undo/Redo + Kill ring** | Ctrl+Z/Y edit_history snapshot; Ctrl+W/K cut, Ctrl+Y yank (ring 5 mục) | Trung bình | 🟠 P1 |
| 8 | **Input limit + reject** | max_message_bytes, hiển thị lỗi rõ ràng thay vì truncate im lặng | Dễ | 🟠 P1 |
| 9 | **Kitty keyboard protocol / modifyOtherKeys** | Phân giải chính xác Ctrl/Alt/Shift combos | Trung bình | 🟡 P2 |
| 10 | **Ctrl+L redraw, line-continuation** | Trivial addons | Dễ | 🟡 P2 |
| 11 | **Selection** | anchor/extend, select_all, copy/cut selection, collapse | Khó | 🟡 P2 (cần multiline) |
| 12 | **Inline pickers** | @file, @model, @skill, slash-command autocomplete overlay | Khó | 🟢 P3 |
| 13 | **Image attachments** | Attach ảnh vào composer | Khó | 🟢 P3 (phụ thuộc transport) |

---

## 3. Kiến trúc đề xuất

### 3.1 Tách module (theo mô hình fx, đơn giản hóa)

```
src/ui/
  editor.zig          → giữ làm orchestrator, nhận input event
  composer.zig        → MỚI: multiline state (dòng, cursor 2D, anchor selection)
  unicode.zig         → MỚI: display_width, grapheme iteration, tab stops
  history.zig         → MỚI: persistent JSONL + in-memory ring
  edit_history.zig    → MỚI: undo/redo snapshots
  escape_parser.zig   → MỚI: thay thế manual escape parsing, hỗ trợ kitty protocol
  paste.zig           → MỚI: bracketed paste + placeholder + block store
```

### 3.2 Composer state (thay buffer 1 chiều)

```zig
pub const Composer = struct {
    lines: std.ArrayList([]const u8),   // nội dung theo dòng
    cursor: Position,                    // { row, col } theo grapheme
    anchor: ?Position,                   // selection anchor
    preferred_col: usize,                // giữ cột khi đi lên/xuống
    undo_stack: [16]Snapshot,            // ring buffer
    redo_stack: [16]Snapshot,
    kill_ring: [5][]const u8,            // Ctrl+W/K/Y
    pasted_blocks: std.ArrayList(PastedBlock), // placeholder refs
    max_message_bytes: usize,            // input limit, reject thay vì truncate
};
```

### 3.3 Thứ tự render 2 chiều

1. Tính display_width từng grapheme (`unicode.zig`).
2. Wrap theo terminal width, track visual↔logical mapping.
3. Render từ cursor row → lên trên; prompt prefix chỉ ở dòng đầu.

---

## 4. Lộ trình 4 phase

### Phase 0 — Quick wins (1–2 ngày)
- [ ] Buffer động `ArrayList(u8)` (nhóm 2)
- [ ] UTF-8 display_width + grapheme cursor movement (nhóm 1)
- [ ] Word motion: Alt+B/F, Alt+D/Backspace (nhóm 3)
- [ ] Ctrl+L redraw, input limit + reject message (nhóm 8, 10 một phần)

**Definition of done:** gõ tiếng Việt/emoji không vỡ, di chuyển theo từ hoạt động.

### Phase 1 — Multiline composer (3–5 ngày) 🔴 then chốt
- [ ] Tách `composer.zig`, cursor 2D, wrap logic
- [ ] Alt+Enter insert newline, Enter submit
- [ ] visual_up/down, page_up/down, paragraph_up/down, preferred-column
- [ ] Backslash line-continuation khi Enter
- [ ] Render multiline: xóa đúng số dòng, prompt prefix dòng đầu

**Definition of done:** soạn prompt 10 dòng, di chuyển tự nhiên như editor thật.

### Phase 2 — History, paste, undo (3–4 ngày)
- [ ] Persistent history JSONL (text + timestamps), Ctrl+P/N song song ↑/↓
- [ ] Large-paste placeholder: >1000 chars → `[Pasted block #n]`, expand khi submit
- [ ] Undo/Redo Ctrl+Z/Y (snapshot trước mỗi mutation)
- [ ] Kill ring Ctrl+W/K/Y

**Definition of done:** paste 5000 dòng không đơ terminal, undo hoạt động, history sống sót qua restart.

### Phase 3 — Input chính xác + selection (3–4 ngày)
- [ ] Escape parser chuẩn: CSI, SS3, kitty keyboard protocol, modifyOtherKeys
- [ ] Selection: Shift+motion set anchor, select_all Ctrl+A double-tap
- [ ] Copy/cut selection, collapse
- [ ] Inline picker @file (glob) + slash-command (nếu có command registry)

**Definition of done:** Alt+<key> phân giải 100%, select + copy đoạn text, @ gợi ý file.

---

## 5. Rủi ro & lưu ý

| Rủi ro | Giảm thiểu |
|---|---|
| Multiline render xung đột với stream output của model | Chỉ re-render composer zone, chốt layout khi model đang stream |
| Kitty protocol không supported trên terminal cũ | Feature-detect bằng response, fallback CSI parsing |
| Snapshot undo tốn RAM với buffer lớn | Ring buffer 16 mục, chỉ diff hoặc cap 4KB/snapshot |
| Persistent history chứa dữ liệu nhạy cảm | Opt-in qua config, ghi rõ trong docs; format JSONL dễ audit |

## 6. Out of scope (defer)
- Image attachments (nhóm 13) — chờ transport/model support.
- Mouse wheel navigation — sau khi composer ổn định.
- @model/@skill picker — sau khi có model/skill registry.
