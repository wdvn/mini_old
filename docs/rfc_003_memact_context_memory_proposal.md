# RFC-003: MemAct — Context Compaction & Memory Management cho mini-agent

| Thuộc tính | Giá trị |
|---|---|
| RFC | 003 |
| Tên | MemAct: Context Compaction & Memory Management |
| Trạng thái | **v0.3 Implemented / Production** — Agent Loop đã chuyển hoàn toàn sang Reactive Compaction khi gặp lỗi context length (drop-all + summary tại index 1, giữ nguyên prompt gốc index 0). M3/M4/M5 deferred theo lộ trình |
| Vai trò | **RFC chuẩn (normative)**: mọi RFC khác khi nói về history / context / memory đều quy chiếu về đây. Thuật ngữ chuẩn: conversation history (tier PINNED/RECENT/SUMMARIZED/ARCHIVED), compaction (reactive — chỉ khi model báo, drop-all + summary dồn), memory (semantic/episodic/project_state). Riêng **prompt input history** của editor (RFC-000) là khối niệm độc lập, không thuộc phạm vi RFC này. |
| Phiên bản | 0.3 — bỏ toàn bộ cơ chế window-based (TokenEstimator wiring, ContextWindow, ngưỡng %, safety margin); compaction chuyển sang **reactive-only**: chỉ nén khi model/backend báo lỗi context |
| Phụ thuộc | RFC-001 (Code-Centric CodeAct), RFC-002 (Event-Driven Act) |
| Tác giả | mini-agent |

> [!NOTE]
> Lịch sử thiết kế:
> - **v0.1**: compaction kiểu "sliding window" (giữ N messages gần nhất) + scoring retrieval — bỏ.
> - **v0.2**: token-aware proactive compaction (ước lượng token bằng heuristic, compact khi
>   vượt ngưỡng % context window) + drop-all + summary dồn tích lũy.
> - **v0.3 (bản này)**: bỏ hẳn cơ chế window — **không còn khái niệm context window trong
>   mini**. Compaction chỉ chạy reactive: khi backend trả lỗi "context too long", agent nén
>   history rồi retry. Lý do xem §1.2.

---

## 1. Vấn đề (Motivation)

### 1.1. Lịch sử lỗ hổng (đã xử lý ở v0.2, giữ nguyên kết quả)

1. **Compaction "mù"** — đếm message thay vì token → đã thay bằng token-aware (v0.2), nay
   thay tiếp bằng reactive (v0.3): chính model là nguồn sự thật về window.
2. **Mất ngữ cảnh khi compact** — compact cũ "giữ nửa sau" → thay bằng summary stencil JSON
   có cấu trúc, dồn tích lũy (giữ nguyên ở v0.3).
3. **Không có long-term memory** — mỗi session bắt đầu từ zero → MemoryStore JSONL đã có
   (`store.zig`), chưa wire (M3, deferred).
4. **Claude API 400 "first message must be user"** — role-fix tự động (giữ nguyên ở v0.3).
5. **Vòng lặp compact vô hạn** của sliding window (v0.1) — drop-all giải quyết (giữ nguyên).

### 1.2. Vì sao bỏ window-based, chuyển sang reactive-only (thay đổi lớn nhất của v0.3)

Cơ chế v0.2 (ước lượng token + ngưỡng % window) có 4 nhược điểm bộc lộ trong thực tế:

1. **Ước lượng luôn sai** — heuristic ±15% (không có tokenizer thật) → compact sớm (lãng phí
   context, mất thông tin không cần thiết) hoặc compact muộn (vẫn dính lỗi 400 rồi phải xử lý).
2. **Window phải configure, luôn lạc hậu** — `MINI_CONTEXT_WINDOW` + auto-detect per-backend
   là bảng tra model cần maintain mỗi khi model mới ra (128K → 200K → 1M...). Với endpoint
   compat (vLLM, OpenRouter, LiteLLM) window thật phụ thuộc cấu hình server, gần như không
   đoán đúng.
3. **Chi phí zero-value mỗi turn** — gọi estimator trên toàn bộ history trước MỖI backend
   call, trong phần lớn cuộc đời session điều kiện compact không bao giờ đạt.
4. **Model đã báo chính xác** — mọi backend lớn đều trả lỗi có thể nhận diện khi prompt tràn
   window (xem §4.2). Không cần dự đoán thứ model tự biết.

Reactive-only = **zero-config** (không cần biết window là bao nhiêu), luôn đúng window thật
của model đang gọi, không tốn chi phí kiểm tra mỗi turn. Chi phí trả trước: đúng 1 request
bị từ chối mỗi lần thực sự tràn window — chấp nhận được vì compact vốn hiếm.

---

## 2. Mục tiêu

**Goals**
1. **Reactive compaction** — chỉ nén khi model báo lỗi context; sau khi nén, retry ngay trong
   cùng turn (model tiếp tục đúng việc qua `task_state`/`next_step`).
2. Context continuity: summary stencil JSON có cấu trúc, dồn tích lũy qua các lần compact.
3. Zero-config về window: không biến môi trường, không auto-detect, không heuristic.
4. Long-term memory: extract & lưu trữ kiến thức xuyên session (deferred — store sẵn sàng).
5. Tích hợp không phá vỡ: hooks dispatch + Act event model của RFC-002.

**Non-goals**
- Bất kỳ hình thức **proactive/predictive compaction** nào (token estimate, ngưỡng %, message
  count) — bỏ hoàn toàn.
- Retrieval scoring (keyword overlap + recency + access_count) — bỏ (từ v0.2). Quy mô memory
  thực tế nhỏ, lọc + Top-K là đủ.
- Vector database / embedding-based retrieval (deferred).
- Cross-project memory sharing, multi-user memory isolation.

---

## 3. Kiến trúc tổng thể

```
┌──────────────────────────────────────────────────────────────────┐
│                      AgentLoop (agent.zig)                        │
│                                                                   │
│  mỗi turn: GỌI BACKEND TRỰC TIẾP (không pre-check, không estimate)│
│                                                                   │
│  nhánh lỗi backend response:                                      │
│   if matchContextOverflowError(raw):            ── signature match│
│     summary = buildLocalSummary(prev_summary)   ── stencil local  │
│     history.compactMemAct(act_id, summary)      ── drop-all       │
│     journal: memact_compacted (reason=reactive)                   │
│     retry backend call (tối đa 2 lần/turn)                        │
│     └─ vẫn lỗi ở dạng [prompt, summary] tối thiểu → terminal fail │
│                                                                   │
│  ┌────────────────────────┐   ┌────────────────────────────────┐ │
│  │ History (history.zig)  │   │ MemoryStore (M3)               │ │
│  │ compactMemAct, tiers   │   │ store.zig — JSONL (chưa wire)  │ │
│  │ ✅ wired               │   │ ⚠️ deferred                    │ │
│  └────────────────────────┘   └────────────────────────────────┘ │
│  (TokenEstimator — bỏ khỏi loop, giữ utility-only;               │
│   ContextWindow window.zig — XÓA)                                 │
└──────────────────────────────────────────────────────────────────┘
```

| Thành phần | File | Trạng thái v0.3 | Trách nhiệm |
|---|---|---|---|
| History + `compactMemAct` | `memact/history.zig` | ✅ wired | Drop-all compaction, tiers, invariant msgs[0] |
| Context-overflow signature matcher | `agent.zig` (local fn) | ✅ (M2c) | Nhận diện lỗi tràn context từ raw body các backend |
| Local summary builder | `memact/history.zig` | ✅ (M2c) | Stencil JSON tự sinh, không qua LLM |
| ~~ContextWindow~~ | ~~`memact/window.zig`~~ | ❌ **xóa** | Không còn khái niệm window |
| ~~TokenEstimator (wired)~~ | `memact/tokens.zig` | ➖ utility-only | Không còn call-site trong agent loop; giữ làm tiện ích estimate (dùng cho memory budget M4 nếu cần) |
| MemoryStore | `memact/store.zig` | ⚠️ code sẵn, chưa wire | Persist memory ra disk (JSONL append-only + index) |

---

## 4. Thiết kế chi tiết

### 4.1. Agent loop — không còn pre-call check

Mỗi turn gọi backend trực tiếp với toàn bộ history. Mọi logic "có nên compact chưa" bị xóa:
không `needsCompaction()`, không `pinned_tokens`, không estimator cache. History dài bao
lâu là quyền của model quyết định.

### 4.2. Context-overflow signature matching (thành phần mới, trái tim của v0.3)

Khi backend trả HTTP 400 (hoặc response error), agent match raw body theo danh sách
signature đã biết:

| Backend | Signature trong raw body |
|---|---|
| OpenAI / compat | `context_length_exceeded` |
| Anthropic (Claude) | `prompt is too long`, `input length and max_tokens exceed context limit` |
| Ollama | `context length exceeded`, `would exceed context length` |
| OpenRouter / vLLM / LiteLLM | `maximum context length`, `requested tokens exceed context` |

Quy tắc match: case-insensitive substring trên raw error body. Signature list là bảng tra
duy nhất, thêm backend mới = thêm 1 dòng.

Lưu ý phân biệt: lỗi **request** `max_tokens` (giới hạn response) KHÔNG phải context
overflow — v0.2 từng match nhầm `"max_tokens"` chung chung; v0.3 chỉ match các signature
trên.

### 4.3. Compaction — DROP-ALL (giữ nguyên từ v0.2, đổi trigger)

**Cơ chế (`compactMemAct`):** khi model báo tràn context, history thu về đúng 2 messages:

```
trước: [prompt gốc, (summary cũ?), msgs... ]
sau:   [prompt gốc (tier .pinned), summary mới (role .user, tier .summarized)]
```

- **msgs[0] (user prompt gốc) không bao giờ bị drop** — invariant của mọi lần compact.
- Summary mới **merge** summary cũ (nếu msgs[1] đã là tier `.summarized`) → dồn tích lũy.
- Guard: nếu history đã ở dạng tối thiểu `[prompt, summary]` mà model vẫn báo tràn →
  prompt gốc/summary quá lớn cho window của model → **terminal error**, không compact nữa
  (compact không thể giảm thêm), báo user rõ nguyên nhân.
- Retry budget: tối đa 2 lần compact-reactive mỗi turn (`reactive_compact_attempts`) —
  chống vòng lặp khi signature match false-positive hoặc model vẫn từ chối.

### 4.4. Summary — LOCAL stencil (thay đổi so với v0.2)

v0.2 gọi LLM để sinh summary stencil từ history sắp bị drop. **Vấn đề với reactive**: request
vừa bị từ chối vì quá dài → summary call với cùng history (còn dài hơn nữa stencil prompt)
cũng sẽ bị từ chối. Vòng luẩn quẩn.

v0.3 sinh summary **hoàn toàn local**, không LLM call:

```json
{
  "type": "context_summary",
  "trigger": "reactive",
  "error_signature": "context_length_exceeded",
  "iteration_range": [12, 87],
  "task_state": "Context vượt giới hạn model tại Act 87; đã nén 74 messages. Chỉ còn summary tích lũy bên dưới.",
  "decisions": ["...giữ nguyên từ summary cũ..."],
  "open_questions": ["..."],
  "learned_errors": ["..."],
  "files_touched": ["..."],
  "next_step": "Review lại summary này và yêu cầu user/đội xác nhận bước tiếp theo nếu thiếu ngữ cảnh."
}
```

- Các trường `decisions/open_questions/learned_errors/files_touched` được **kéo nguyên vẹn
  từ summary cũ** (nếu có) — thông tin tích lũy không mất.
- Nếu chưa có summary cũ (lần compact đầu): các trường rỗng, `task_state` nêu rõ toàn bộ
  history chi tiết đã bị drop; model tự hỏi lại user những gì còn thiếu. Tradeoff chấp nhận:
  hiếm khi session compact lần đầu chưa từng có summary mà không kịp ra quyết định quan
  trọng — và quyết định quan trọng thường đã nằm trong tool outputs mà user có thể replay.
- **Refine sau compact (tuỳ chọn, cùng turn):** sau khi drop-all, history nhỏ → có thể gọi
  1 LLM call "điền khuyết stencil" từ summary hiện có + prompt gốc nếu cần chất lượng hơn.
  Không blocking; mặc định tắt.

### 4.5. Role-fix Claude 400 (giữ nguyên từ v0.2)

- `ensureClaudeCompatible()`: đổi role message đầu thành `.user` nếu cần.
- Agent loop phát hiện HTTP 400 role/first-message → gọi role-fix → retry tối đa 2 lần/turn.
- Phân nhánh với context-overflow: match role-signature TRƯỚC khi match overflow-signature.

### 4.6. MemoryStore (`store.zig`) — code hoàn chỉnh, chưa wire (giữ nguyên M3+)

```
~/.mini/memory/
  <project_hash>/
    memory.jsonl          # append-only, mỗi dòng 1 event
    index.json            # materialized view: entries hiện hành (có áp supersedes)
```

Event schema + 3 loại memory (`semantic`/`episodic`/`project_state`) + quy tắc supersedes:
giữ nguyên mô tả v0.2 (xem git history của file này nếu cần chi tiết). Khi M4 wire: load
index → lọc type + `confidence >= 0.7` → sort `ts` → Top-K. Không scoring.

### 4.7. Wire vào hệ thống hiện có

| Hook / Event | Thực tế v0.3 |
|---|---|
| `pre-prompt` dispatch | ✅ giữ — KHÔNG còn dùng để check compact (chỉ hooks user) |
| `pre-context-build` hook + `MINI_CTX_BUDGET`/`MINI_CTX_USED` | ❌ **xóa payload fields** (không còn khái niệm ctx budget); hook riêng cho M5 sẽ thiết kế lại khi wire |
| `post-session-end` hook | ⚠️ infra sẵn, chưa call-site (M5) |
| Act event `memact_compacted` | ✅ thêm field `reason="reactive"` + `error_signature` |
| Field `tier` trong `Message` | ✅ giữ nguyên (`protocol.zig`) |
| Archived JSONL (undo log) | ❌ chưa làm — drop-all mất message gốc sau compact (như v0.2) |

**Kiểm soát rollback:** `History.last_compaction_act_id` chặn rollback vượt mốc compact
(giữ nguyên v0.2).

---

## 5. Configuration

Env vars sau đây **bỏ** (đánh dấu deprecated, parser xóa trong M2c):

```bash
MINI_CONTEXT_WINDOW=128000        # ❌ bỏ — không còn khái niệm window
MINI_CTX_SAFETY_MARGIN=0.15       # ❌ bỏ
MINI_CTX_COMPACT_THRESHOLD=0.85   # ❌ bỏ
```

Env vars giữ:

```bash
MINI_MEMACT_TOP_K=8               # (M4) số memory inject vào prompt
MINI_MEMACT_MEMORY_BUDGET=2000    # (M4) token budget cho memory block
MINI_MEMACT_EXTRACT=async         # (M5) async | sync | off
MINI_MEMORY_DIR=~/.mini/memory    # (M3) thư mục memory store
```

`MINI_MEMACT_ENABLED`: bỏ (không còn 2 chế độ để bật/tắt — chỉ còn 1 cơ chế reactive).

Auto-detect window theo backend: **xóa** cùng `ContextWindow`.

Ghi chú: `MINI_MEMACT_TOP_K`, `MINI_MEMACT_MEMORY_BUDGET`, `MINI_MEMACT_EXTRACT`,
`MINI_MEMORY_DIR` vẫn là dead config cho tới khi M3/M4/M5 wire.

---

## 6. Milestones

| M | Nội dung | Trạng thái | Ghi chú |
|---|---|---|---|
| **M1** | ~~TokenEstimator + ContextWindow wire~~ | ✅ (v0.2) → **xóa trong M2c** | commit `774faad` |
| **M2a** | Giữ prompt gốc qua compact + role-fix Claude 400 | ✅ giữ nguyên | commit `1c8e721` |
| **M2b** | Drop-all + summary dồn tích lũy | ✅ giữ nguyên | commit `8d782e9` |
| **M2c** | **Reactive rewrite**: xóa needsCompaction/estimator wiring/window.zig, thêm signature matcher + local summary builder + retry-on-overflow | ⬜ **next** | RFC này |
| **M3** | MemoryStore wire vào agent | ⚠️ code xong (`373beea`), chưa wire | — |
| **M4** | Inject memory vào system prompt (lọc + Top-K) | ❌ chưa làm | — |
| **M5** | Extraction pipeline + Act events memory | ❌ chưa làm | — |

---

## 7. Acceptance criteria

Đã đạt (kế thừa v0.2, vẫn đúng):

1. ✅ **No mid-pair split** — drop-all không chừa `tool_use` mồ côi.
2. ✅ **Context continuity** — summary stencil + dồn tích lũy; msgs[0] nguyên vẹn.
3. ✅ **Claude 400 role-fix** — ensureClaudeCompatible + retry 2 lần/turn.

Mục tiêu M2c (chưa đạt):

4. ⬜ **Zero window config** — xóa 3 env vars + auto-detect; grep không còn `MINI_CONTEXT_WINDOW`/`MINI_CTX_` trong code.
5. ⬜ **Reactive compact** — mô phỏng backend trả `context_length_exceeded` → agent compact + retry thành công trong cùng turn; unit test cho signature matcher (4 backend), local summary builder (merge summary cũ), guard terminal ([prompt, summary] vẫn tràn → error, không loop).
6. ⬜ **Không compact khi không lỗi** — history 100+ messages, model vẫn nhận → không thay đổi history.

Chờ M3/M4/M5 (như cũ):

7. ⬜ **Cross-session recall** — session mới cùng project → memory block chứa project_state.
8. ⬜ **Disk format** — memory.jsonl + index idempotent end-to-end.
9. ⬜ **Latency** — retrieval <5ms/1.000 entries.

---

## 8. Risks & mitigation

| Rủi ro | Mitigation |
|---|---|
| Wasted request mỗi lần tràn thật (1 call bị 400 trước khi compact) | Chấp nhận — compact hiếm, đổi lại zero-config + luôn đúng window thật |
| Signature match false-positive (400 khác bị nhận là overflow) | Signature list hẹp, chỉ chuỗi đặc trưng; retry budget 2 lần/turn chặn vòng lặp |
| Backend mới chưa có signature → lỗi 400 tràn context bị nuốt thành unknown | Fallback: HTTP 400 + chuỗi `context`/`length`/`token` → log rõ raw body kèm hướng dẫn thêm signature |
| Local summary chất lượng thấp hơn LLM summary (v0.2) | Kéo nguyên fields từ summary cũ; option refine LLM sau compact; `task_state` chỉ thị rõ đã drop gì để model hỏi lại chủ động |
| Lỗi context lặp lại dù đã compact về [prompt, summary] | Guard terminal error, báo user prompt gốc + summary vượt window model — model không dùng được, cần đổi model/đặt lại session |
| Drop-all mất message gốc vĩnh viễn | `last_compaction_act_id` chặn rollback; archived JSONL là việc tương lai |
| Memory stale gây nhiễu prompt | `supersedes` + confidence threshold 0.7 (khi M4 wire) |

---

## 9. Alternatives considered

1. **(v0.2) Proactive token-aware compaction** — đã chạy production nhưng: heuristic sai ±15%,
   window config lạc hậu, chi phí check mỗi turn, vẫn phải xử lý reactive cho trường hợp
   estimate lệch. Kết luận: proactive là trùng lặp — model đã báo chính xác.
2. **tiktoken WASM tokenizer** — chính xác hơn heuristic nhưng không giải quyết được gốc:
   vẫn phải biết window của model đang gọi (compat endpoint không透露). Bỏ cùng proactive.
3. **SQLite thay JSONL** — thêm dependency; JSONL + index đủ cho <10K entries.
4. **RAG với embedding local** — đúng hướng v2, blocking cho v1.
5. **Hybrid: proactive khi gần window ước lượng + reactive làm safety net** — phức tạp 2 cơ
   chế, vẫn giữ toàn bộ nhược điểm window config. Bỏ.

---

## 10. Future work (v2+)

- Wire MemoryStore vào agent loop (M3): init theo project-hash, persist cuối session.
- Inject memory block vào system prompt (M4): lọc + Top-K, không scoring.
- Act events memory + extraction pipeline (M5).
- Archived JSONL khi compact — biến drop-all thành reversible (undo log cho Act rollback).
- LLM refine summary sau compact (option, §4.4).
- Embedding-based retrieval nếu quy mô memory vượt ~1.000 entries/project.
- Memory inspector CLI: `mini memory list|prune|export`.
- User-editable memory — file `MINI.md` tự động vào tier PINNED.
