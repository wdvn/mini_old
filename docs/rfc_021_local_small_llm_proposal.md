# RFC-021: Embedded Local Small-LLM (Edge Judge)

## Summary

Nhúng một model LLM nhỏ chạy local trực tiếp vào binary mini-agent (qua llama.cpp, static link) để thực hiện semantic judging cho RFC-020 (Semantic Advisory Enforcement), không phụ thuộc network hay Ollama bên ngoài.

**Target hardware (hard constraint):** PC 1 CPU core, 1 GB RAM. Mọi thiết kế dưới đây phải pass budget test trên cấu hình này.

**Related**: RFC-020 (Semantic Advisory Enforcement — consumer của judge), RFC-015 (Three Thread Runtime & Watchdog — nơi judge chạy async).

---

## 1. Motivation

RFC-020 còn lỗ hổng: compliance đo bằng naive tool-name matching (sai khi advisory được thực hiện qua `js` block hoặc tool khác tên), và LLM-as-Judge (mục 5.1 của RFC-020) chưa chỉ định model. Gọi API lớn realtime là quá đắt và vi phạm tính offline.

Giải pháp: embed model cực nhỏ (≤ 360M params, quantized GGUF) chạy in-process.

---

## 2. Model Tier Selection (1 CPU + 1 GB RAM)

### 2.1 Budget RAM (tier 1)

| Component | RSS |
|-----------|-----|
| mini binary + QuickJS + runtime Zig | ~20–40 MB |
| llama.cpp runtime (static) | ~50–100 MB |
| SmolLM2-135M Q4_K_M GGUF (mmap) | ~150–200 MB |
| KV cache @ ctx 1024 | ~30–50 MB |
| mini history / buffers / VMs | ~50–100 MB |
| **Total** | **~300–500 MB** ✅ (dư ≥ 500 MB cho main session) |

### 2.2 Tier table

| Tier | Model | Params | GGUF Q4_K_M | RAM khi chạy | Tốc độ 1 core | Vai trò |
|------|-------|--------|-------------|--------------|----------------|---------|
| **1 (default)** | SmolLM2-135M-Instruct | 135M | ~90–100 MB | ~250 MB RSS | ~40–80 tok/s | Judge phân loại |
| **2 (accuracy)** | SmolLM2-360M-Instruct | 360M | ~230–250 MB | ~400 MB RSS | ~20–40 tok/s | Judge khi cần chính xác hơn |
| 3 (optional) | Qwen2.5-0.5B-Instruct | 494M | ~380 MB | ~600 MB RSS | ~10–20 tok/s | Chỉ khi RAM thực tế > 1.2 GB |

**Không khuyến nghị**: model ≥ 1B (overflow RAM), model < 100M (TinyStories/Pythia-70M — quality không đủ cho classification trên input dài).

**Không embed weights vào binary** — GGUF đặt tại `~/.mini/models/`, load bằng `mmap` on-demand (tận dụng OS page cache, tránh làm phình binary ~100+ MB).

### 2.3 Floor chất lượng

- 135M chỉ đủ cho **binary/3-class classification** (`complied / ignored / ambiguous`) với constrained decoding (logit cho phép 1 trong N token đầu ra). Không dùng cho sinh text tự do.
- Advisory rewriting vẫn giữ template rule (deterministic) — không giao cho LLM nhỏ.
- Trước khi chốt tier 1: benchmark A/B 135M vs 0.5B trên ~100 session. Tiêu chí: agreement ≥ 90% với judge lớn → dùng 135M.

---

## 3. Architecture

### 3.1 Integration pattern — giống QuickJS

`build.zig` (static C library link, đúng pattern `quickjs_dep` hiện có):

```zig
const llama_dep = b.dependency("llama_cpp", .{});
const llama_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
llama_mod.addCSourceFiles(.{ .root = llama_dep.path(""), .files = &.{ /* core C/C++ files */ } });
// link static + -lc++; exe_mod.linkLibrary(llama_lib)
```

**Lưu ý vi phạm quy ước**: AGENTS.md yêu cầu "std lib only" — llama.cpp là external C++ dependency đầu tiên của repo. RFC này chính là proposal bắt buộc trước khi code (đúng thủ tục). Build time tăng đáng kể; cross-compile vẫn OK qua Zig.

### 3.2 File layout

| File | Vai trò |
|------|---------|
| `src/backends/local.zig` | Local inference backend, **conform `core/protocol.zig`** (quy tắc AGENTS.md: không bypass protocol) |
| `src/runtime/local_llm.zig` | Wrapper llama.cpp: mmap GGUF, ctx 1024–2048, 1 context duy nhất (1 CPU → không pool) |
| `build.zig` | Thêm llama_cpp dependency + build options |
| `scripts/setup_home_mini.sh` | Bổ sung bước tải GGUF vào `~/.mini/models/` (tier 1: ~100 MB, one-time) |

### 3.3 Async judge flow (ghép RFC-015 + RFC-020)

```
Act N: advisory injected (RFC-020) ──► judge job queue (watchdog thread, low priority)
Act N+1: tool call xảy ra ──► telemetry ghi naive match (baseline, luôn có)
Background: judge prompt (≤ 150 token: action + advisory + tool name, không full trajectory)
            → logit classification 1–3 token → ~3–5s (tier 1)
Kết quả: chỉ điều chỉnh weight cho các turn SAU (hệ số 0.8–1.2 vào
         công thức weight = 1.0 + 0.5 * log10(1 + transition_count))
```

**Quy tắc bất biến:**
1. Judge KHÔNG bao giờ block act loop — chạy async trên watchdog thread.
2. Severity (OPTIONAL/RECOMMENDED/MANDATORY) vẫn do threshold deterministic của RFC-020 quyết định; judge chỉ điều chỉnh weight.
3. Naive tool-name matching giữ làm baseline metric; judge score là metric chính sau khi đủ 100+ sessions.
4. Fallback: model load fail / timeout / OOM → pipeline RFC-020 chạy hoàn toàn deterministic, chỉ mất phần telemetry adjusted. Không bao giờ để advisory chết vì judge chết.

---

## 4. Configuration

Thêm vào `src/core/config.zig` (env-based, mặc định OFF — giữ tính portable):

| Env var | Default | Ý nghĩa |
|---------|---------|---------|
| `MINI_LOCAL_LLM_ENABLED` | `0` | Bật/tắt embedded judge |
| `MINI_LOCAL_LLM_MODEL` | `tier1` | `tier1` \| `tier2` \| đường dẫn GGUF tùy chỉnh |
| `MINI_LOCAL_LLM_CTX` | `1024` | Context size (giảm nếu RAM thấp) |

Startup log: `[config] Local LLM: enabled, tier1 (SmolLM2-135M Q4_K_M), ctx=1024` — nếu GGUF thiếu → cảnh báo + chạy fallback deterministic (không error).

---

## 5. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| RAM overflow trên máy 1 GB | Medium | High | Tier 1 default (250 MB RSS); mmap; ctx ≤ 1024; config OFF khi thiếu GGUF |
| Chậm trên 1 CPU | High | Medium | Async + logit decoding (1–3 token) + prompt ≤ 150 token |
| Judge 135M sai lệch | Medium | High | Constrained decoding; A/B benchmark; agreement threshold 90%; judge lớn spot-check định kỳ |
| Build time / phức tạp dependency | Medium | Medium | llama.cpp static qua Zig build (đã chứng minh với QuickJS); chỉ link core, không build examples |
| CPU contention với main session | Medium | Medium | Watchdog thread nice/priority thấp; chỉ infer giữa các act |

---

## 6. Implementation Plan

| Week | Task | Deliverable | Verify |
|------|------|-------------|--------|
| 1 | llama.cpp dep + `src/runtime/local_llm.zig` wrapper (load/mmap/infer) | Binary build với `-DMINI_LOCAL_LLM` | `zig build test-unit` pass; infer smoke test 1 token |
| 2 | `src/backends/local.zig` conform protocol + config keys | Backend có thể trả completion nội bộ | Unit test classification output |
| 3 | Async judge thread + telemetry wiring vào RFC-020 journal events | Judge chạy ngầm, weight adjusted | `testcases/test_local_llm.zig` (mock GGUF); E2E vẫn pass với LLM disabled |
| 4 | Benchmark 1 CPU / 1 GB RAM + A/B 135M vs 0.5B | Báo cáo tok/s, RSS, agreement | KPI: judge ≤ 5s, RSS tổng ≤ 800 MB |

**Testing lưu ý**: toàn bộ test suite phải pass khi `MINI_LOCAL_LLM_ENABLED=0` (default) — không breaking change cho người dùng hiện tại và CI không cần GGUF.

---

## 7. Success Metrics

| Metric | Target |
|--------|--------|
| Total RSS (mini + local LLM) | ≤ 800 MB trên máy 1 GB |
| Judge latency | ≤ 5s (tier 1, async) |
| Judge agreement với judge lớn | ≥ 90% |
| Compliance rate improvement (RFC-020 KPI) | ~0% → > 70% |
| Overhead khi disabled | 0 (chỉ +binary size) |

---

## 8. Conclusion

Embed SmolLM2-135M (tier 1) là cấu hình duy nhất đáp ứng hard constraint 1 CPU + 1 GB RAM: RSS tổng ~300–500 MB, judge ~3–5s async, binary GGUF chỉ ~100 MB. Tier 2 (360M) là nâng cấp độ chính xác khi RAM cho phép.

**Recommendation**: Implement Week 1–2 (runtime + backend) trước, judge async sau — cùng triết lý với RFC-020: đo được đã, enforcement deterministic vẫn là backbone.

**References:**
- RFC-020: Semantic Advisory Enforcement System
- RFC-015: Three Thread Runtime and Watchdog
- RFC-010: Procedural Graph