# RFC-003: MemAct — Context Window & Memory Management cho mini-agent

| Thuộc tính | Giá trị |
|---|---|
| RFC | 003 |
| Tên | MemAct: Context Window & Memory Management |
| Trạng thái | Implemented (M1+M2) — M3 một phần, M4/M5 deferred |
| Vai trò | **RFC chuẩn (normative)**: mọi RFC khác khi nói về history / context / memory đều quy chiếu về đây. Thuật ngữ chuẩn: conversation history (tier PINNED/RECENT/SUMMARIZED/ARCHIVED), compaction (token-aware, drop-all + summary dồn), memory (semantic/episodic/project_state). Riêng **prompt input history** của editor (RFC-000) là khái niệm độc lập, không thuộc phạm vi RFC này. |
| Phiên bản | 0.2 — đối chiếu lại với code thực tế sau các commit `774faad`, `1c8e721`, `8d782e9`, `373beea` |
| Phụ thuộc | RFC-001 (Code-Centric QuickJS), RFC-002 (Event-Driven Act) |
| Tác giả | mini-agent |

> [!NOTE]
> Bản 0.1 thiết kế compaction kiểu "sliding window" (giữ N messages gần nhất + scoring retrieval
> cho memory). Sau khi triển khai thực tế, cả hai cơ chế này bị **bỏ**: sliding window gây vòng
> lặp compact vô hạn với window lớn, scoring retrieval không còn ý nghĩa khi mỗi project chỉ có
> một lượng nhỏ memory entries (chọn toàn bộ nhanh hơn và đáng tin hơn). Bản 0.2 mô tả đúng
> những gì đã chạy trong production, kèm các use case thực tế phát sinh.

---

## 1. Vấn đề (Motivation) — cập nhật từ thực tế triển khai

Khảo sát hiện trạng code trước RFC này cho thấy 4 lỗ hổng, tất cả đã được xử lý ở M1+M2:

1. **Auto-compaction chưa được nối vào agent loop** — `compact()`/`needsCompaction()` tồn tại
   nhưng không có call-site. → Đã wire vào `agent.zig` (mỗi turn, trước backend call).
2. **Compaction "mù"** — ngưỡng `DEFAULT_MAX_MESSAGES = 40` đếm message thay vì token. → Đã thay
   bằng `TokenEstimator` heuristic + ngưỡng `% context window`.
3. **Mất ngữ cảnh khi compact** — compact cũ "giữ nửa sau", mọi quyết định ở nửa đầu biến mất.
   → Đã thay bằng summary stencil JSON có cấu trúc, dồn tích lũy qua các lần compact.
4. **Không có long-term memory** — mỗi session bắt đầu từ zero. → MemoryStore JSONL đã có
   (`store.zig`) nhưng **chưa wire vào agent loop** (xem M3, deferred).

Ngoài ra, quá trình triển khai làm lộ thêm 2 vấn đề không nằm trong thiết kế gốc:

5. **Claude API 400 "first message must be user"** — session cũ compact kiểu cũ có thể để
   assistant message ở đầu history → Claude từ chối cả turn. Cần role-fix tự động.
6. **Vòng lặp compact vô hạn** — sliding window giữ ~60% window gần nhất: với window lớn,
   phần giữ lại vẫn vượt ngưỡng compact → mỗi vòng lặp lại gọi LLM summary (đốt API call)
   trong khi history không bao giờ xuống dưới ngưỡng.

---

## 2. Mục tiêu

**Goals**
1. Token-aware context window management — compaction dựa trên ước lượng token (đã xong).
2. Context continuity: sau compact, agent vẫn tiếp tục đúng việc đang dở qua summary
   `task_state`/`next_step` (đã xong).
3. Long-term memory: extract & lưu trữ kiến thức xuyên session (deferred — store sẵn sàng).
4. Tích hợp không phá vỡ: hooks dispatch + Act event model của RFC-002 (một phần).

**Non-goals (điều chỉnh ở v0.2)**
- ~~Retrieval scoring (keyword overlap + recency + access_count)~~ — **bỏ**. Với quy mô
  memory thực tế (< vài trăm entries/project), inject toàn bộ project_state + lọc theo
  `MINI_MEMACT_TOP_K` bẳng đơn giản là đủ; hàm scoring 4 thành phần là over-engineering.
- Vector database / embedding-based retrieval (vẫn deferred).
- Cross-project memory sharing, multi-user memory isolation (giữ nguyên).
- **Giữ N messages gần nhất khi compact (sliding window)** — **bỏ** (nguyên nhân vòng lặp
  compact vô hạn, xem §4.2).

---

## 3. Kiến trúc tổng thể

```
┌──────────────────────────────────────────────────────────────┐
│                      AgentLoop (agent.zig)                    │
│                                                               │
│  mỗi turn, trước backend call:                                │
│   pinned = est(system_prompt)                                 │
│   if memact_enabled and msgs.len > 2                          │
│      and window.needsCompaction(est, msgs, pinned):           │
│        summary = LLM(stencil prompt, msgs)     ── LLM call    │
│        history.compactMemAct(act_id, summary)  ── drop-all    │
│        journal: memact_compacted                               │
│                                                               │
│  ┌───────────────┐  ┌──────────────┐  ┌────────────────────┐ │
│  │ TokenEstimator│  │ ContextWindow│  │ MemoryStore (M3)   │ │
│  │ tokens.zig    │  │ window.zig   │  │ store.zig — JSONL  │ │
│  │ ✅ wired      │  │ ✅ wired     │  │ ⚠️ chưa wire       │ │
│  └───────────────┘  └──────────────┘  └────────────────────┘ │
└──────────────────────────────────────────────────────────────┘
```

| Thành phần | File | Trạng thái | Trách nhiệm |
|---|---|---|---|
| TokenEstimator | `memact/tokens.zig` | ✅ wired | Ước lượng token cho message/history (heuristic + cache) |
| ContextWindow | `memact/window.zig` | ✅ wired | needsCompaction token-based, tìm split tool-boundary |
| MemoryStore | `memact/store.zig` | ⚠️ code sẵn, chưa wire | Persist memory ra disk (JSONL append-only + index) |
| ~~Retriever~~ | ~~`memact/retrieve.zig`~~ | ❌ bỏ | Bỏ scoring; inject đơn giản khi làm M4 |

---

## 4. Thiết kế chi tiết (theo code thực tế)

### 4.1. TokenEstimator (`tokens.zig`) — như thiết kế, đã triển khai

Heuristic 2 tầng, sai số chấp nhận ±15%, kèm cache `StringHashMap` để không duyệt lại chuỗi
đã ước lượng:

- ASCII/code: `len / 3.8` token
- CJK/VN diacritics (codepoint > 0x2E80): `len / 1.4` token
- Overhead cố định: `tool_use` +40, `tool_result` +20, `thinking` tính cả `signature`.

```zig
pub fn estimate(self: *TokenEstimator, text: []const u8) u32
pub fn estimateMessage(self: *TokenEstimator, msg: *const proto.Message) u32
```

### 4.2. Compaction — DROP-ALL (bài học lớn nhất của v0.2)

**Thiết kế v0.1 (SAI, đã bỏ):** giữ N messages gần nhất (~60% window), phần cũ thành summary.
**Thực tế:** với window lớn, 60% giữ lại vẫn vượt ngưỡng 85% → compact chạy mỗi vòng lặp
(LLM call mỗi iteration) mà history không bao giờ giảm → vòng lặp compact vô hạn, đốt API.

**Cơ chế thực tế (`compactMemAct`):** khi vượt ngưỡng, history thu về đúng 2 messages:

```
trước: [prompt gốc, (summary cũ?), msgs... 40+ messages]
sau:   [prompt gốc (tier .pinned), summary mới (role .user, tier .summarized)]
```

- **msgs[0] (user prompt gốc) không bao giờ bị drop** — invariant của mọi lần compact.
- Summary mới **merge** summary cũ (nếu msgs[1] đã là tier `.summarized`) → dồn tích lũy,
  context dài bao nhiêu iteration cũng chỉ tốn 1 summary message.
- Trạng thái "đang ở bước nào" nằm trong `task_state`/`next_step` của summary nên model
  tiếp tục đúng chỗ mà không cần message gốc.
- Guard trong agent loop: chỉ compact khi `msgs.len > 2` — history đã ở dạng tối thiểu
  `[prompt, summary]` mà vẫn vượt ngưỡng (prompt/summary quá lớn) thì không compact nữa,
  chỉ log cảnh báo, tránh gọi LLM summary vô nghĩa mỗi vòng.

**Tool-boundary split (`findSplitIndex`)** vẫn được giữ trong `window.zig` cho tương lai
(tách cặp `tool_use`/`tool_result`), nhưng drop-all hiện tại khiến nó không còn call-site
trong agent loop — an toàn tuyệt đối về protocol vì không bao giờ chừa lại tool_use mồ côi.

### 4.3. Summary stencil — như thiết kế, đã triển khai

LLM nhận prompt yêu cầu xuất JSON theo stencil:

```json
{
  "type": "context_summary",
  "iteration_range": [1, 99],
  "task_state": "mô tả tiến độ",
  "decisions": ["quyết định 1"],
  "open_questions": [],
  "learned_errors": [],
  "files_touched": [],
  "next_step": "bước tiếp theo"
}
```

- Summary được bọc marker `[MemAct Context Summary]\n{json}` khi chèn vào history.
- Prompt tường minh: "hãy gộp (merge) nội dung summary cũ vào summary mới" → dồn tích lũy.
- **Fallback**: LLM không trả về text block nào → dùng `history.compact()` cũ (giữ nửa sau,
  không summary). Đường fallback này không theo stencil — chấp nhận được vì hiếm, nhưng là
  điểm yếu đã biết.

### 4.4. Role-fix Claude 400 (use case thực tế, không có trong v0.1)

Session cũ compact kiểu cũ có thể bắt đầu bằng assistant message → Claude trả 400
"first message must be user". Xử lý:

- `ensureClaudeCompatible()`: đổi role message đầu thành `.user` nếu cần.
- Agent loop phát hiện HTTP 400 role/first-message → gọi role-fix → retry tối đa 2 lần/turn
  (`role_fix_attempts`).

### 4.5. MemoryStore (`store.zig`) — code hoàn chỉnh, chưa wire

```
~/.mini/memory/
  <project_hash>/
    memory.jsonl          # append-only, mỗi dòng 1 event
    index.json            # materialized view: entries hiện hành (có áp supersedes)
```

Event schema (đã implement đủ field):

```json
{
  "id": "mem_<hex ts>_<hex counter>_<hex pid>",
  "ts": 1692700000000,
  "type": "semantic",
  "content": "…",
  "keywords": ["zig", "build", "test"],
  "source_session": "sess_xyz",
  "confidence": 0.9,
  "supersedes": "mem_older_id",
  "access_count": 3,
  "last_access": 1692700000000
}
```

3 loại memory giữ nguyên: `semantic` (vĩnh viễn), `episodic` (30 ngày),
`project_state` (tới khi bị supersedes).

Quy tắc supersedes giữ nguyên: entry mới thay thế entry cũ trong index, không xóa dòng cũ
trong JSONL (audit trail).

**Thay đổi so với v0.1:** bỏ hàm scoring của Retriever. Khi M4 được làm, việc chọn memory
inject vào system prompt chỉ là: load index → lọc theo type + `confidence >= 0.7` → sort
theo `ts` → cắt Top-K. Không cần keyword-overlap/recency/access_count scoring — `matchKeyword()`
giữ lại trong `store.zig` như tiện ích lọc thô, không phải thành phần kiến trúc.

### 4.6. Wire vào hệ thống hiện có

| Hook / Event | Thiết kế v0.1 | Thực tế |
|---|---|---|
| `pre-prompt` dispatch | (đã có sẵn) | ✅ dùng làm timing kiểm tra compact |
| `pre-context-build` hook + `MINI_CTX_BUDGET`/`MINI_CTX_USED` | hook mới | ⚠️ payload fields + env export đã có trong `hooks.zig`, **chưa dispatch** — cần khi làm M4 |
| `post-session-end` hook + `MINI_SESSION_FILE`/`MINI_MEMORY_DIR` | hook mới | ⚠️ idem, infra sẵn sàng, chưa có call-site |
| Act event `memact_compacted` | 1 trong 3 events | ✅ có trong `journal.zig`; `memact_memory_extracted`, `memact_memory_recalled` chờ M4/M5 |
| Field `tier` trong `Message` | optional, non-breaking | ✅ `protocol.zig` (`pinned/recent/summarized/archived`, null = tạo kiểu cũ) |
| Archived JSONL (undo log cho Act rollback) | message cũ ghi ra disk | ❌ chưa làm — drop-all hiện tại mất message gốc vĩnh viễn sau compact |

**Kiểm soát rollback:** `History.last_compaction_act_id` ghi lại Act ID lần compact gần nhất
để block rollback vượt quá mốc này (history đã bị drop, không dựng lại được từ RAM).

---

## 5. Configuration

Env vars (đã parse đủ trong `config.zig`):

```bash
MINI_CONTEXT_WINDOW=128000        # override auto-detect từ backend
MINI_CTX_SAFETY_MARGIN=0.15       # phần budget giữ cho response
MINI_CTX_COMPACT_THRESHOLD=0.85   # compact khi recent > 85% available
MINI_MEMACT_ENABLED=1             # "0" → fallback về compact kiểu cũ theo message count
MINI_MEMACT_TOP_K=8               # (M4) số memory inject vào prompt
MINI_MEMACT_MEMORY_BUDGET=2000    # (M4) token budget cho memory block
MINI_MEMACT_EXTRACT=async         # (M5) async | sync | off
MINI_MEMORY_DIR=~/.mini/memory    # (M3) thư mục memory store
```

Auto-detect window theo backend khi không set: `openai → 128000`, `claude → 200000`,
`ollama → query /api/tags hoặc default 8192`. ✅ đã implement.

Ghi chú thực tế: `MINI_MEMACT_TOP_K`, `MINI_MEMACT_MEMORY_BUDGET`, `MINI_MEMACT_EXTRACT`,
`MINI_MEMORY_DIR` hiện là **dead config** — parse xong chưa ai đọc; sẽ sống lại khi M3/M4/M5
được wire.

---

## 6. Milestones — cập nhật theo commit thực tế

| M | Nội dung | Trạng thái | Commit |
|---|---|---|---|
| **M1** | TokenEstimator + ContextWindow token-based + wire vào agent loop | ✅ xong | `774faad` |
| **M2a** | Giữ prompt gốc qua compact + role-fix Claude 400 + guards | ✅ xong | `1c8e721` |
| **M2b** | Drop-all thay sliding window + summary dồn tích lũy | ✅ xong | `8d782e9` |
| **M3** | MemoryStore JSONL + index + supersedes | ⚠️ code xong (`373beea`), **chưa wire vào agent** | — |
| **M4** | Inject memory vào system prompt (không scoring — chỉ lọc + Top-K) | ❌ chưa làm | — |
| **M5** | Extraction pipeline + hook `pre-context-build`/`post-session-end` + Act events memory | ❌ chưa làm | — |

M1+M2 đã ship: context management chạy production. M3–M5 là memory cross-session, độc lập,
làm sau.

---

## 7. Acceptance criteria

Đã đạt:

1. ✅ **Token safety** — compact token-based với safety margin 15%, chạy trước mỗi backend call.
2. ✅ **No mid-pair split** — drop-all không chừa lại `tool_use` mồ côi (an toàn tuyệt đối;
   boundary-split giữ lại trong `window.zig` cho tương lai).
3. ✅ **Context continuity** — summary stencil `task_state`/`next_step` + dồn tích lũy; unit
   test xác nhận msgs[0] nguyên vẹn qua nhiều lần compact.
4. ✅ **Hook compat** — `MINI_MEMACT_ENABLED=0` fallback đúng về behavior cũ (compact theo
   message count); 4 hook hiện có dispatch đúng.
5. ✅ **Claude 400 role-fix** — ensureClaudeCompatible + retry 2 lần/turn.

Chưa đạt (chờ M3/M4/M5):

6. ⬜ **Cross-session recall** — session mới cùng project → memory block chứa project_state.
7. ⬜ **Disk format** — memory.jsonl đọc được bằng `jq`, index rebuild từ jsonl (idempotent)
   — logic có trong `store.zig` kèm unit test, nhưng chưa chạy end-to-end.
8. ⬜ **Latency** — retrieval <5ms/1.000 entries — chuẩn bị kiểm chứng khi M4 wire.

Kiểm chứng hiện tại: `zig build test` — 40/40 pass, trong đó 14 test thuộc memact/history
(tokens 1, window 7, store 5, history 4).

---

## 8. Risks & mitigation — cập nhật

| Rủi ro | Mitigation |
|---|---|
| Token estimate sai → tràn window thật | safety margin 15%; guard `msgs.len > 2` chặn compact lặp vô hạn kể cả khi estimate lệch |
| Summary LLM hallucination làm hỏng context | stencil bắt buộc + merge tường minh trong prompt; summary kèm `iteration_range` để audit |
| LLM summary không trả text → fallback `compact()` cũ mất stencil | chấp nhận (hiếm); cải thiện sau bằng retry hoặc dùng block cuối bất kỳ |
| Drop-all mất message gốc vĩnh viễn (không undo log) | `last_compaction_act_id` chặn rollback vượt mốc; archived JSONL là việc còn thiếu nếu cần reversible hoàn toàn |
| Memory stale gây nhiễu prompt | `supersedes` + confidence threshold 0.7 (khi M4 wire) |
| Dead config gây hiểu nhầm đã bật memory | §5 ghi rõ config nào đang sống; giữ lại để M3–M5 dùng lại nguyên |

---

## 9. Alternatives considered

1. **tiktoken WASM tokenizer** — chính xác hơn nhưng +2MB binary + init cost; heuristic + margin đủ.
2. **SQLite thay JSONL** — query mạnh hơn nhưng thêm dependency; JSONL + index đủ cho <10K entries.
3. **RAG với embedding local** — đúng hướng v2, blocking cho v1.
4. **(Mới v0.2) Giữ sliding window + hạ threshold** — đã thử trong đầu: chỉ đổi "vòng lặp
   compact" thành "compact sớm hơn nhưng vẫn lặp"; gốc vấn đề là phần giữ lại tỷ lệ thuận
   với window. Drop-all giải quyết triệt để.

---

## 10. Future work (v2+)

- Wire MemoryStore vào agent loop (M3): init theo project-hash, persist cuối session.
- Inject memory block vào system prompt (M4): lọc + Top-K, không scoring.
- Dispatch `pre-context-build` / `post-session-end` hooks; Act events memory (M5).
- Archived JSONL khi compact — biến drop-all thành reversible (undo log cho Act rollback).
- Embedding-based retrieval nếu quy mô memory vượt ~1.000 entries/project (khi đó scoring
  mới trở lại có ý nghĩa).
- Memory inspector CLI: `mini memory list|prune|export`.
- User-editable memory — file `MINI.md` tự động vào tier PINNED.
