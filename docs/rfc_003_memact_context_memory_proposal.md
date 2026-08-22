# RFC-003: MemAct — Context Window & Memory Management cho mini-agent

| Thuộc tính | Giá trị |
|---|---|
| RFC | 003 |
| Tên | MemAct: Context Window & Memory Management |
| Trạng thái | Draft — chờ review |
| Vai trò | **RFC chuẩn (normative)**: mọi RFC khác khi nói về history / context / memory đều quy chiếu về đây. Thuật ngữ chuẩn: conversation history (4 tier PINNED/RECENT/SUMMARIZED/ARCHIVED), compaction (token-aware, tool-boundary), memory (semantic/episodic/project_state). Riêng **prompt input history** của editor (RFC-000) là khái niệm độc lập, không thuộc phạm vi RFC này. |
| Phiên bản | 0.1 |
| Phụ thuộc | RFC-001 (Code-Centric QuickJS), RFC-002 (Event-Driven Act) |
| Tác giả | mini-agent |

---

## 1. Vấn đề (Motivation)

Khảo sát hiện trạng code cho thấy 4 lỗ hổng trong quản lý context:

### 1.1. Auto-compaction chưa được nối vào agent loop
`src/core/history.zig` đã có đầy đủ `compact()`, `compactWithSummary()`, `needsCompaction()` — nhưng **không có call-site nào** trong `src/` invoke các hàm này. History chỉ bị cắt thủ công, không tự động.

### 1.2. Compaction "mù" — đếm message, không đếm token
Ngưỡng compaction là `DEFAULT_MAX_MESSAGES = 40`. Một message 200 token và một message 20.000 token được tính như nhau. Với model có context window lớn (Claude: 200K) hoặc nhỏ (Ollama local: 4–8K), ngưỡng cố định hoặc lãng phí hoặc tràn window gây lỗi 400 từ backend.

### 1.3. Mất ngữ cảnh khi compact
`compact()` hiện chỉ "giữ nửa sau" của history. Mọi quyết định, ràng buộc, lỗi đã học ở nửa đầu biến mất hoàn toàn giữa phiên. `compactWithSummary()` tồn tại nhưng summary rời rạc, không có cấu trúc, không được dùng để phục hồi ngữ cảnh.

### 1.4. Không có long-term memory
History là in-memory + backup file thuần (`~/.mini/sessions/sess_*.json`). Mỗi session mới bắt đầu từ zero: agent không nhớ cấu trúc project, quy ước code, lỗi đã sửa, hay quyết định kiến trúc từ session trước. Đây là khác biệt lớn so với Claude Code (CLAUDE.md + auto memory) và Cursor (project context).

---

## 2. Mục tiêu

**Goals**
1. Token-aware context window management — compaction dựa trên ước lượng token, không phải số message.
2. Tiered context: pinned → recent → summarized → archived. Không mất thông tin quan trọng khi compact.
3. Long-term memory: extract & lưu trữ kiến thức xuyên session (semantic, episodic, project-state).
4. Retrieval & injection: memory liên quan được đưa vào system prompt tự động.
5. Tích hợp không phá vỡ: dùng lại `hooks.zig` (lifecycle dispatch) và Act event model của RFC-002.

**Non-goals (v1)**
- Vector database / embedding-based retrieval (deferred — dùng keyword + recency scoring trước).
- Cross-project memory sharing.
- Học online model weights / fine-tuning.
- Multi-user memory isolation (giả định single-user, `~/.mini/`).

---

## 3. Kiến trúc tổng thể

```
┌─────────────────────────────────────────────────────────┐
│                      AgentLoop (agent.zig)               │
│                                                          │
│  ┌──────────────┐   pre-prompt    ┌───────────────────┐  │
│  │  hooks.zig   │ ──────────────▶ │  MemAct            │  │
│  │  (dispatch)  │                 │  ┌───────────────┐ │  │
│  └──────┬───────┘                 │  │ TokenEstimator│ │  │
│         │ post-response           │  ├───────────────┤ │  │
│         ▼                         │  │ ContextWindow │ │  │
│  ┌──────────────┐                 │  │  (4 tiers)    │ │  │
│  │ MemAct:      │                 │  ├───────────────┤ │  │
│  │  - extract   │ ──────────────▶ │  │ MemoryStore  │ │  │
│  │  - compact   │                 │  │  (JSONL log)  │ │  │
│  └──────────────┘                 │  ├───────────────┤ │  │
│                                   │  │ Retriever     │ │  │
│  system prompt ◀──────────────────│  └───────────────┘ │  │
│  (memory block injected)          └───────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

MemAct là module Zig thuần (`src/core/memact/`) gồm 4 thành phần độc lập, giao tiếp qua struct + function call trực tiếp (không qua IPC):

| Thành phần | File | Trách nhiệm |
|---|---|---|
| TokenEstimator | `memact/tokens.zig` | Ước lượng token cho message/history |
| ContextWindow | `memact/window.zig` | 4-tier buffer, quyết định compact |
| MemoryStore | `memact/store.zig` | Persist memory ra disk (JSONL) |
| Retriever | `memact/retrieve.zig | Chọn memory liên quan, render vào prompt |

---

## 4. Thiết kế chi tiết

### 4.1. TokenEstimator (`tokens.zig`)

Không nhúng tokenizer thật (bloat binary). Dùng heuristic 2 tầng:

```zig
pub const TokenEstimator = struct {
    cache: std.StringHashMap(u32),

    /// Heuristic: ~4 chars/token cho EN/code, ~1.5 chars/token cho CJK/VN diacritics.
    pub fn estimate(self: *TokenEstimator, text: []const u8) u32 {
        if (self.cache.get(text)) |v| return v;
        const n_cjk = countWideChars(text);   // codepoint > 0x2E80
        const n_ascii = text.len - n_cjk;
        const tokens = @as(u32, @intFromFloat(@as(f64, @floatFromInt(n_ascii)) / 3.8))
                     + @as(u32, @intFromFloat(@as(f64, @floatFromInt(n_cjk)) / 1.4));
        self.cachePut(text, tokens);
        return tokens;
    }

    pub fn estimateMessage(msg: *Message) u32;  // content + tool_use overhead (~40 tok/call)
    pub fn estimateHistory(hist: *History) u32;
};
```

Sai số chấp nhận được: ±15%. Kết hợp với **safety margin 15%** khi so với budget là đủ an toàn.

### 4.2. ContextWindow — 4 tiers (`window.zig`)

Thay thế quan niệm "history = 1 list phẳng". Mỗi message được gán vào 1 tier:

| Tier | Vai trò | Biên giới |
|---|---|---|
| **PINNED** | System prompt, memory block, ràng buộc user, @file quan trọng | Không bao giờ bị compact. Budget riêng. |
| **RECENT** | N message gần nhất nguyên vẹn | Chiếm phần lớn budget còn lại |
| **SUMMARIZED** | History cũ đã được LLM tóm tắt thành 1 summary message có cấu trúc | 1 message, ~800–2000 token |
| **ARCHIVED** | Message cũ hơn nữa, ghi ra disk, out of context | Không tiêu tốn budget |

**Compaction algorithm** (chạy trước mỗi lần call backend, trong `pre-prompt` hook slot):

```
budget = context_window - reserved_for_response - pinned_tokens
if estimate(recent) > budget * 0.85:          # sớm, không đợi tràn
    split = tìm điểm cắt ở tool-boundary gần budget * 0.6
    summary_old = llm.summarize(recent[0..split], last_summary)   # gộp dồn
    move recent[0..split] -> archived (append JSONL)
    recent = [summary_old] ++ recent[split..]
```

Điểm quan trọng:
- **Cắt tại tool-call boundary**, không cắt giữa một cặp `tool_use`/`tool_result` (gây lỗi protocol với Claude/OpenAI).
- Summary **dồn tích lũy** (mỗi lần compact gộp với summary cũ) → context dài hàng trăm iteration chỉ tốn ~2K token summary.
- `history.compact()/compactWithSummary()` hiện có được deprecate, thay bằng `window.compactWith(estimator, budget)`.

### 4.3. Cấu trúc summary có stencil

Summary không phải văn bản tự do — dùng stencil để LLM điền, đảm bảo machine-parseable:

```json
{
  "type": "context_summary",
  "iteration_range": [4, 27],
  "task_state": "đang refactor src/core/agent.zig, xong 60%",
  "decisions": [
    "Dùng union-tagged Backend thay vì interface vtable",
    "Giữ QuickJS engine, không thêm Lua"
  ],
  "open_questions": ["chưa xử lý streaming cho ollama backend"],
  "learned_errors": ["build.zig: dependency 'zap' cần version >=0.9"],
  "files_touched": ["src/core/agent.zig", "src/core/history.zig"],
  "next_step": "wire memact vào pre-prompt hook"
}
```

### 4.4. MemoryStore (`store.zig`) — event-log JSONL

Tái dùng pattern của `artifacts.zig` (thư mục + metadata), nhưng là **append-only event log**:

```
~/.mini/memory/
  <project_hash>/
    memory.jsonl          # append-only, mỗi dòng 1 event
    index.json            # materialized view: type → [ids], keyword → [ids]
```

3 loại memory:

| Type | Ví dụ | TTL | Extraction trigger |
|---|---|---|---|
| `semantic` | "Project dùng Zig 0.13 + Build.zig, test bằng `zig build test`" | vĩnh viễn | post-response hook, batch cuối session |
| `episodic` | "Session 2025-01-15: đã fix leak trong ollama streaming" | 30 ngày | end-of-session |
| `project_state` | "Branch `feat/memact`, đang dở milestone M2" | tới khi bị update | mỗi pre-prompt |

Event schema (1 dòng JSONL):

```json
{
  "id": "mem_a1b2c3",
  "ts": "2025-06-01T10:00:00Z",
  "type": "semantic",
  "content": "…",
  "keywords": ["zig", "build", "test"],
  "source_session": "sess_xyz",
  "confidence": 0.9,
  "supersedes": "mem_older_id",
  "access_count": 3,
  "last_access": "…"
}
```

Quy tắc:
- `supersedes`: memory mới cùng chủ đề **thay thế** cũ trong index (giống compaction của event-sourcing) — không xóa dòng cũ, giữ audit trail.
- Extraction prompt chạy **async/batch** (cuối session hoặc N response 1 lần) để không thêm latency vào mỗi turn.
- Extraction là 1 LLM call riêng, rẻ (model nhỏ nếu backend hỗ trợ dual-model).

### 4.5. Retriever (`retrieve.zig`) — scoring & injection

Score mỗi memory khi build system prompt:

```
score = 2.0 * keyword_overlap(last_user_msg)
      + 1.0 * recency_decay(last_access, half_life=7d)
      + 0.5 * min(access_count, 5)/5
      + 1.5 * (type == project_state)      # luôn ưu tiên state hiện tại
```

Top-K (K=8, tunable) được render vào **memory block** trong system prompt:

```
<memory>
<project_state priority="high">…</project_state>
<semantic>…</semantic>
<episodic>…</episodic>
</memory>

<context_summary>…summary dồn từ window tier…</context_summary>
```

Memory block thuộc tier PINNED → không bao giờ bị compact. Budget cho memory block: ~2000 token, trừ đi khi tính budget của RECENT.

### 4.6. Wire vào hệ thống hiện có

**hooks.zig** — thêm 2 hook point (dùng cơ chế dispatch shell + env vars sẵn có):

| Hook | Timing | Env vars |
|---|---|---|
| `pre-context-build` | trước khi assemble messages cho backend | `MINI_CTX_BUDGET`, `MINI_CTX_USED` |
| `post-session-end` | khi session kết thúc | `MINI_SESSION_FILE`, `MINI_MEMORY_DIR` |

**RFC-002 Act integration**: MemAct phát event `memact.compacted`, `memact.memory_extracted`, `memact.memory_recalled` vào event bus của Act model → có thể rollback/mirror/x-replay việc compact như mọi action khác. Compaction trở thành **observable & reversible** (archived JSONL chính là undo log).

**history.zig**: giữ làm storage layer, thêm field `tier` vào `Message`. Không breaking change với session file format cũ (field mới optional).

---

## 5. Configuration

Env vars mới:

```bash
MINI_CONTEXT_WINDOW=128000        # override auto-detect từ backend
MINI_CTX_SAFETY_MARGIN=0.15       # % budget giữ cho response
MINI_CTX_COMPACT_THRESHOLD=0.85   # compact khi recent > 85% budget
MINI_MEMACT_ENABLED=1             # tổng switch
MINI_MEMACT_MEMORY_DIR=~/.mini/memory
MINI_MEMACT_TOP_K=8               # số memory inject vào prompt
MINI_MEMACT_MEMORY_BUDGET=2000    # token budget cho memory block
MINI_MEMACT_EXTRACT=async         # async | sync | off
```

Auto-detect window theo backend khi không set: `openai → 128000`, `claude → 200000`, `ollama → query /api/tags hoặc default 8192`.

---

## 6. Milestones

| M | Nội dung | Deliverable | Ước tính |
|---|---|---|---|
| **M1** | TokenEstimator + ContextWindow 4 tiers, thay `needsCompaction` bằng token-based; wire vào agent loop | Compact tự chạy, cắt đúng boundary | 1–2 ngày |
| **M2** | Structured summary stencil + LLM summarization dồn tích lũy | `context_summary` message hoạt động | 1 ngày |
| **M3** | MemoryStore JSONL + index + project-hash scoping | Memory persist xuyên session | 1–2 ngày |
| **M4** | Retriever scoring + injection vào system prompt (memory block) | Auto-recall khi start session mới | 1 ngày |
| **M5** | Extraction pipeline (post-session-end hook) + Act events + docs | End-to-end: session N nhớ session N−1 | 1–2 ngày |

M1+M2 độc lập với M3–M5: có thể ship context management trước, memory sau.

---

## 7. Acceptance criteria

1. **Token safety**: chạy 200+ iterations với tool calls dày đặc (mỗi turn >5K token) không bao giờ gặp context-length error từ backend.
2. **No mid-pair split**: không có `tool_use` nào bị tách khỏi `tool_result` sau compact (property test với generator message ngẫu nhiên).
3. **Context continuity**: sau compact, agent vẫn trả lời đúng câu hỏi về quyết định ở phần đã summarize (eval scripted: đặt fact ở iteration 5, hỏi lại ở iteration 80).
4. **Cross-session recall**: session mới trong cùng project → memory block chứa project_state + ≥1 semantic memory relevant.
5. **Latency**: memory retrieval + scoring <5ms cho 1.000 memory entries (keyword-based, no LLM call).
6. **Hook compat**: tất cả hook hiện có vẫn dispatch đúng; `MINI_MEMACT_ENABLED=0` tắt hoàn toàn, behavior fallback = hiện trạng.
7. **Disk format**: memory.jsonl đọc lại được bằng `jq`, index.json rebuild được từ jsonl (idempotent).

---

## 8. Risks & mitigation

| Rủi ro | Mitigation |
|---|---|
| Token estimate sai → tràn window thật | safety margin 15% + auto-đo từ error response backend để hiệu chỉnh heuristic |
| Summary LLM hallucination làm hỏng context | stencil bắt buộc + chỉ summarize facts/tool results, không suy diễn; summary luôn kèm `iteration_range` để user audit |
| Extraction tốn thêm LLM call | batch async cuối session; `MINI_MEMACT_EXTRACT=off` cho môi trường nghèo |
| Memory stale gây nhiễu prompt | `supersedes` + recency decay + confidence threshold 0.7 |
| Keyword retrieval kém với từ đồng nghĩa | chấp nhận v1; thiết kế interface `Retriever` để swap sang embedding ở v2 không đổi call-site |

---

## 9. Alternatives considered

1. **Dùng tiktoken-clTokenCount WASM** — chính xác hơn nhưng thêm ~2MB binary + init cost; heuristic + margin đủ cho mục tiêu "không tràn".
2. **SQLite thay JSONL** — query mạnh hơn nhưng thêm dependency, khó đọc bằng tool Unix; JSONL + index materialized đủ cho quy mô <10K entries/project.
3. **RAG với embedding local** — đúng hướng v2 nhưng blocking cho v1 (build complexity, model download).

---

## 10. Future work (v2+)

- Embedding-based retrieval (`all-MiniLM` qua ONNX), giữ keyword làm hybrid rank.
- Memory inspector CLI: `mini memory list|prune|export`.
- User-editable memory (như CLAUDE.md) — file `MINI.md` tự động vào tier PINNED.
- Multi-agent shared memory namespace.
