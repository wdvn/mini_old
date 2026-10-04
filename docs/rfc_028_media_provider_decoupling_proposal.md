# RFC-028: Media Provider Decoupling — Per-Plane Configuration & Custom Provider Support

**Status**: Proposed
**Date**: 2026-10-03
**Supersedes**: RFC-027 §5 (specified there, never implemented)
**Related**: RFC-011 (Media Generation & Vision Loop-Back), RFC-027 (Universal Media Protocol)

**Sources** (fetched 2026-10-03, verified against live docs):
- `https://openrouter.ai/docs/guides/overview/multimodal/image-generation.md`
- `https://openrouter.ai/docs/guides/overview/multimodal/video-generation.md`

---

## 1. Agreed Understanding

### 1.1 What the user asked

Original question: *"verify protocol có hỗ trợ được custom provider có gen media không"* — verify whether the protocol supports custom providers that generate media.

Verified answer: **No.** Findings, with file/line evidence:

| Finding | Evidence |
|---|---|
| `media_protocol.zig` (RFC-027) is a types-only module, not wired into dispatch | No field of `ImageGenRequest` / `VideoGenRequest` is ever read outside their own definition file |
| Only 3 provider names understood: `openai_compat`, `agnes`, `agnesai` (plus any string containing `agnes`) | `src/tools/media_gen.zig:170-175` `isCompatOrAgnes` |
| Unknown provider **silently falls back to `api.openai.com`** | `src/tools/media_gen.zig:208-218` `resolveBaseUrl` — `is_compat == false` falls through to `return "https://api.openai.com/v1"` at line 217 |
| RFC-027 §5 config keys do not exist | `grep "MINI_IMAGE_GEN_URL\|MINI_VIDEO_GEN_URL\|MINI_IMAGE_GEN_API_KEY\|OPENROUTER_API_KEY" src/` → 0 hits |
| Auth header hardcoded to `Authorization: Bearer` | `src/tools/media_gen.zig:117-124` `buildAuthHeaders` — line 120 emits the literal string; `OPENAI_COMPAT_API_HEADER` is read only at `src/core/config/resolvers.zig:68` for the chat plane |
| Media plane borrows the **chat plane's** URL and key | `src/core/agent/loop.zig:371-372` passes `config.openai_compat_url` / `config.openai_compat_key` into `media_gen_tool.setConfig` |

### 1.2 Root cause (the P0 defect)

`resolveBaseUrl` conflates "this provider is a known compat proxy" with "this is OpenAI". A user who sets `MINI_IMAGE_GEN_PROVIDER=openrouter` gets a **successful-looking request to `api.openai.com`**. Depending on which key is configured, this either fails with an opaque HTTP 401 from OpenAI, or **succeeds and bills the wrong vendor/account** with a model name that vendor has never heard of.

There is no validation, no warning, no error. The failure is silent and expensive.

### 1.3 Scope decision

1. **P0 fix** — unknown provider fails fast with an actionable error, never silently routes to a different vendor.
2. **Per-plane configuration** — image and video become two independent structs. The media plane reads **nothing** from the chat plane (agreed decision: option **b**, full decoupling).
3. **Provider options passthrough** — request fields beyond `prompt` / `model` become configurable per plane, based on the **verified** OpenRouter Image and Video API surfaces.

### 1.4 Out of scope (deferred to a follow-up plan)

| Deferred item | Reason |
|---|---|
| Request-body builder that *emits* the new option fields | This plan defines and validates the config surface only. Emitting a field a provider does not accept causes a 400, so each field must be opt-in and needs its own validation pass. |
| Configurable **poll / download** endpoints for video | Partially solved by the `polling_url` field — see §3.5. |
| Built-in provider presets (openrouter, fal, replicate, comfyui) | Presets would hardcode unverified paths. The configurable endpoint makes them unnecessary. |
| JS media hook in `src/backends/js_provider.zig` | Separate subsystem. |
| Per-request `provider` override in `mini.media(...)` | Independent of the config surface. |

---

## 2. Approach and Trade-offs

### 2.1 Per-plane structs

The flat `image_gen_*` / `video_gen_*` field list is replaced by two independent structs. Two structs rather than one shared `PlaneConfig`, because `size` / `n` / `quality` only apply to images while `duration` / `poll_timeout_secs` only apply to video — a shared struct would force nulls for "not applicable", which is exactly the ambiguity RFC-027 forbids.

Field values below are transcribed from the OpenRouter docs cited at the top of this RFC.

```zig
pub const ImagePlaneConfig = struct {
    enabled: bool = false,
    provider: []const u8 = "openai",
    model: []const u8 = "gpt-image-1",
    url: ?[]const u8 = null,
    key: ?[]const u8 = null,
    api_header: []const u8 = "Authorization",
    endpoint: []const u8 = "images/generations",
    // Verified OpenRouter POST /api/v1/images fields
    resolution: ?[]const u8 = null,   // "512" | "768" | "1K" | "1.5K" | "2K" | "4K"
    aspect_ratio: ?[]const u8 = null, // "1:1" "16:9" "9:16" "4:3" "3:4" "3:2" "2:3" "4:5" "5:4" "1:2" "2:1" "1:4" "4:1" "1:8" "8:1" "9:21" "21:9" "auto"
    size: []const u8 = "1024x1024",   // shorthand; explicit pixels are authoritative
    n: u8 = 1,                       // 1..10
    quality: ?[]const u8 = null,      // "auto" | "low" | "medium" | "high"
    output_format: ?[]const u8 = null, // "png" | "jpeg" | "webp" | "svg"
    background: ?[]const u8 = null,   // "auto" | "transparent" | "opaque"
    output_compression: ?u8 = null,   // 0..100, webp/jpeg only
    stream: bool = false,
    seed: ?i64 = null,
    // Provider routing (the OpenRouter `provider` object)
    provider_only: ?[]const []const u8 = null,
    provider_order: ?[]const []const u8 = null,
    provider_ignore: ?[]const []const u8 = null,
    provider_sort: ?[]const u8 = null, // "price" | "throughput" | "latency"
    provider_allow_fallbacks: ?bool = null,
    provider_options: ?[]const u8 = null, // raw JSON object keyed by provider slug
};

pub const VideoPlaneConfig = struct {
    enabled: bool = false,
    provider: []const u8 = "openai",
    model: []const u8 = "sora-2",
    url: ?[]const u8 = null,
    key: ?[]const u8 = null,
    api_header: []const u8 = "Authorization",
    endpoint: []const u8 = "videos",
    // Verified OpenRouter POST /api/v1/videos fields
    resolution: ?[]const u8 = null,   // "480p" | "720p" | "768p" | "1080p" | "1K" | "2K" | "4K"
    aspect_ratio: ?[]const u8 = null,
    size: ?[]const u8 = null,         // "1280x720", interchangeable with resolution+aspect_ratio
    duration: u32 = 4,                // seconds
    generate_audio: bool = false,
    seed: ?i64 = null,
    callback_url: ?[]const u8 = null, // HTTPS only; webhook receiver
    frame_images: ?[]const []const u8 = null,    // image-to-video, each entry carries frame_type
    input_references: ?[]const []const u8 = null, // reference-to-video
    // Provider routing
    provider_only: ?[]const []const u8 = null,
    provider_order: ?[]const []const u8 = null,
    provider_ignore: ?[]const []const u8 = null,
    provider_sort: ?[]const u8 = null,
    provider_allow_fallbacks: ?bool = null,
    provider_options: ?[]const u8 = null,
    // Local polling (only used when the provider returns no polling_url)
    poll_interval_secs: u32 = 5,
    poll_timeout_secs: u32 = 300,
};

pub const MediaGenConfig = struct {
    image: ImagePlaneConfig = .{},
    video: VideoPlaneConfig = .{},
    output_dir: ?[]const u8 = null,
    input_max_bytes: usize = 10 * 1024 * 1024,
    input_max_per_turn: u8 = 5,
};
```

`MediaGenConfig` **no longer contains** `openai_compat_url` or `openai_compat_key`. That is decision (b).

### 2.2 Trade-off accepted

`provider_options` is a raw JSON string rather than a typed map. A typed version would need a generic key/value bag for arbitrary vendor keys. A raw passthrough string keeps each plane extensible to any vendor without a schema change, and mirrors how the chat plane already handles provider-specific fields via `transformRequest`. Validation is limited to "parses as a JSON object" — semantics belong to the provider.

### 2.3 Alternatives considered

| Alternative | Why rejected |
|---|---|
| Keep the silent fallback but log a warning to stderr | Invisible to the agent, invisible in non-TTY mode, and the request still goes to the wrong vendor. The billing risk remains. |
| Hardcode OpenRouter / Fal.ai / Replicate preset branches | Unverified paths produce a plausible-looking but broken integration. |
| Route media through the chat backend abstraction | The chat plane is a streaming-text abstraction; media is a request/poll/download lifecycle. Forcing media through it re-couples the two planes. |
| Reuse `ProviderProfile` for media | It models reasoning and streaming concerns (`ReasoningField`, `EchoPolicy`, `ThinkingTagSet`) that are meaningless for media, and adding media fields would pollute all 10 existing profiles. |
| Export a mock HTTP server and assert on captured requests | URL, header, and option resolution are pure-function operations. No transport seam is needed. |

---

## 3. Design

### 3.1 Config plumbing

New fields are added to `Config` (`src/core/config/types.zig:167-181`), `JsonConfig` (`:323-330`), and `ReasoningAndMediaSettings` (`src/core/config/resolvers.zig:183-201`), then copied into `Config` by `applyReasoningMediaPlanningToConfig` (`src/core/config/resolvers.zig:430`) and mapped from JSON by `applyActionLoopAndMediaJsonConfig` (`src/core/config/dotenv.zig:219-248`).

Every new field is optional with a default, so existing configurations keep working untouched.

**Image plane — 16 env vars:**

| Env var | JSON key |
|---|---|
| `MINI_IMAGE_GEN_URL` | `image_gen_url` |
| `MINI_IMAGE_GEN_KEY` | `image_gen_key` |
| `MINI_IMAGE_GEN_API_HEADER` | `image_gen_api_header` |
| `MINI_IMAGE_GEN_ENDPOINT` | `image_gen_endpoint` |
| `MINI_IMAGE_GEN_RESOLUTION` | `image_gen_resolution` |
| `MINI_IMAGE_GEN_ASPECT_RATIO` | `image_gen_aspect_ratio` |
| `MINI_IMAGE_GEN_QUALITY` | `image_gen_quality` |
| `MINI_IMAGE_GEN_OUTPUT_FORMAT` | `image_gen_output_format` |
| `MINI_IMAGE_GEN_BACKGROUND` | `image_gen_background` |
| `MINI_IMAGE_GEN_OUTPUT_COMPRESSION` | `image_gen_output_compression` |
| `MINI_IMAGE_GEN_N` | `image_gen_n` |
| `MINI_IMAGE_GEN_STREAM` | `image_gen_stream` |
| `MINI_IMAGE_GEN_SEED` | `image_gen_seed` |
| `MINI_IMAGE_GEN_PROVIDER_ONLY` | `image_gen_provider_only` |
| `MINI_IMAGE_GEN_PROVIDER_SORT` | `image_gen_provider_sort` |
| `MINI_IMAGE_GEN_PROVIDER_ALLOW_FALLBACKS` | `image_gen_provider_allow_fallbacks` |
| `MINI_IMAGE_GEN_PROVIDER_OPTIONS` | `image_gen_provider_options` |

The three list-valued routing fields (`provider_only` / `provider_order` / `provider_ignore`) are **not** individually exposed as env vars — they are comma-separated in `MINI_IMAGE_GEN_PROVIDER_ONLY` and `..._PROVIDER_ORDER`, matching the existing `MINI_TOOL_ALLOWLIST` convention in this codebase.

**Video plane — 16 env vars:**

| Env var | JSON key |
|---|---|
| `MINI_VIDEO_GEN_URL` | `video_gen_url` |
| `MINI_VIDEO_GEN_KEY` | `video_gen_key` |
| `MINI_VIDEO_GEN_API_HEADER` | `video_gen_api_header` |
| `MINI_VIDEO_GEN_ENDPOINT` | `video_gen_endpoint` |
| `MINI_VIDEO_GEN_RESOLUTION` | `video_gen_resolution` |
| `MINI_VIDEO_GEN_ASPECT_RATIO` | `video_gen_aspect_ratio` |
| `MINI_VIDEO_GEN_SIZE` | `video_gen_size` |
| `MINI_VIDEO_GEN_DURATION` | `video_gen_duration` |
| `MINI_VIDEO_GEN_GENERATE_AUDIO` | `video_gen_generate_audio` |
| `MINI_VIDEO_GEN_SEED` | `video_gen_seed` |
| `MINI_VIDEO_GEN_CALLBACK_URL` | `video_gen_callback_url` |
| `MINI_VIDEO_GEN_PROVIDER_ONLY` | `video_gen_provider_only` |
| `MINI_VIDEO_GEN_PROVIDER_SORT` | `video_gen_provider_sort` |
| `MINI_VIDEO_GEN_PROVIDER_ALLOW_FALLBACKS` | `video_gen_provider_allow_fallbacks` |
| `MINI_VIDEO_GEN_PROVIDER_OPTIONS` | `video_gen_provider_options` |
| `MINI_VIDEO_GEN_POLL_INTERVAL_SECS` | `video_gen_poll_interval_secs` |

`MINI_VIDEO_GEN_POLL_TIMEOUT_SECS` and `MINI_IMAGE_INPUT_*` / `MINI_MEDIA_OUTPUT_DIR` keep their existing names and meaning; only their struct location changes.

### 3.2 Base URL resolution and the migration path

Base URL, image plane (video plane identical with `_VIDEO_`):

```
1. <PLANE>_GEN_URL                    → used verbatim (§3.3)
2. provider contains "agnes"           → "https://apihub.agnes.ai/v1"
3. provider == "openai"                → "https://api.openai.com/v1"
4. provider == "openai_compat"         → cleanBaseUrl(OPENAI_COMPAT_URL), else "https://api.openai.com/v1"
5. anything else                       → error, no request issued
```

The step-4 fallback reads `OPENAI_COMPAT_URL`, and step "key 2" below reads `OPENAI_COMPAT_API_KEY`, **but not from the chat-plane config struct**. They are resolved in `resolveReasoningAndMediaSettings` (`src/core/config/resolvers.zig`), which already holds the merged `env_map`, and stored into the media plane's own `url` / `key` fields:

```zig
// inside resolveReasoningAndMediaSettings
const img_url = env_map.get("MINI_IMAGE_GEN_URL") orelse
    (if (std.mem.eql(u8, img_prov, "openai_compat")) b.openai_url else null);
```

Rationale: `utils.getEnvSlice` (`src/core/utils.zig:29`) reads the real process environment via `getenv` and therefore **cannot see values injected by `config.json`**, which are written into `env_map` by `tryLoadJsonConfig`. Resolving the fallback inside the resolver is the only place where both sources are visible. The result is that `MediaGenConfig` carries no chat-plane field, while every existing `openai_compat` configuration still resolves to the same URL it does today.

API key, image plane:

```
1. MINI_IMAGE_GEN_KEY
2. provider == "openai_compat" → OPENAI_COMPAT_API_KEY     (same resolver-local lookup)
3. null → no auth header; public endpoints stay usable
```

Behavior contract with **no** dedicated URL set:

| `..._GEN_PROVIDER` | Base URL before | Base URL after |
|---|---|---|
| `openai` | `https://api.openai.com/v1` | **unchanged** |
| `agnes` / `agnesai` / any `*agnes*` | `https://apihub.agnes.ai/v1` | **unchanged** |
| `openai_compat` + `OPENAI_COMPAT_URL` set | `cleanBaseUrl(OPENAI_COMPAT_URL)` | **unchanged** |
| `openai_compat`, no `OPENAI_COMPAT_URL` | `https://api.openai.com/v1` | **unchanged** |
| anything else | `https://api.openai.com/v1` | **error, no request issued** |

The step-5 error message:

```
Unknown image provider '<provider>'. Set MINI_IMAGE_GEN_URL (and
MINI_IMAGE_GEN_KEY) to configure it, or use one of: openai, openai_compat, agnes
```

with the video-plane equivalent naming `MINI_VIDEO_GEN_URL` / `MINI_VIDEO_GEN_KEY`.

Note that the provider string is usually *not* literally `openai`: `resolveReasoningAndMediaSettings` (`src/core/config/resolvers.zig:219-222`) derives the default from `OPENAI_COMPAT_PROVIDER` / `MINI_MEDIA_PROVIDER`. A chat backend set to `deepseek` therefore yields provider `deepseek`, which hits step 5. This is intended strictness — a DeepSeek chat backend must not silently send image requests to OpenAI.

### 3.3 Dedicated URL is used verbatim

`MINI_IMAGE_GEN_URL` / `MINI_VIDEO_GEN_URL` are **not** passed through `cleanBaseUrl` (`src/tools/media_gen.zig:177-186`); only a trailing `/` is trimmed. `cleanBaseUrl` exists to strip chat-plane suffixes (`/chat/completions`, `/responses`) off a reused *chat* URL. A purpose-built media URL has no such contamination, and silently truncating a user's intentional path would introduce a new silent-mutation bug of exactly the kind this RFC exists to remove.

Worked example:

```
MINI_IMAGE_GEN_URL=http://localhost:7860/sdapi/v1
MINI_IMAGE_GEN_ENDPOINT=txt2img
→ http://localhost:7860/sdapi/v1/txt2img
```

**Documented limitation**: `resolveEndpointUrl` (`src/tools/media_gen.zig:220-225`) appends `/v1/` when the base does not already end in `/v1`, so an API root that is not `/v1`-shaped cannot be expressed as `base + endpoint`. Such a provider is reached by placing everything up to the final path segment in `..._GEN_URL` and the final segment in `..._GEN_ENDPOINT`. Stated in the help text.

### 3.4 Auth header

`buildAuthHeaders` gains a header-name parameter:

```zig
pub fn buildAuthHeaders(alloc: Allocator, header_name: []const u8, key: ?[]const u8) ![]const u8
```

- `key == null` → `{"Content-Type":"application/json"}` (unchanged; public endpoints unaffected).
- header name `Authorization` → `{"Authorization":"Bearer <key>","Content-Type":"application/json"}` (unchanged for all existing configurations).
- any other header name → `{"<header>":"<key>","Content-Type":"application/json"}`, **no** `Bearer ` prefix. Providers using custom auth headers do not expect the scheme prefix; a user who needs one includes it in the key value.

### 3.5 Provider routing object

A new pure function assembles the OpenRouter `provider` object from the six routing fields:

```zig
pub fn resolveProviderOptionsJson(
    alloc: Allocator,
    provider_only: ?[]const []const u8,
    provider_order: ?[]const []const u8,
    provider_ignore: ?[]const []const u8,
    provider_sort: ?[]const u8,
    allow_fallbacks: ?bool,
    raw_options: ?[]const u8,
) !?[]u8
```

Returns `null` when no routing field is set, so no `"provider"` key is emitted. `raw_options` is validated as a JSON object (rejecting arrays, scalars, and malformed input) and, when valid, is merged under the routing keys. This function is **not** called by the request builder in this plan — it is delivered and tested so the follow-up plan can wire it.

### 3.6 Video polling improvement (included, small)

OpenRouter returns `polling_url` in the submit response and `unsigned_urls[0]` in the completed poll response, neither of which the current code reads:

```json
{ "id": "abc123", "polling_url": "https://.../videos/abc123", "status": "pending" }
```

`buildVideoPollUrl` (`src/tools/media_gen.zig:494-508`) currently reconstructs the poll URL from `base` + `videos/{job_id}`, which happens to match OpenRouter but is hardcoded. This plan adds: **if the submit response contains `polling_url`, use it verbatim.** This is a 3-line change that makes any Sora-shaped provider work without config, and it directly reduces the gap identified in §1.4. `resolveVideoDownloadUrl` gains the same treatment: prefer `unsigned_urls[0]` from the poll body when present.

### 3.7 Error surface

`generateImageDirect` / `generateVideoDirect` already return `MediaResult{ .ok = false, .message = ... }` for every other failure (prompt too long, HTTP error, missing data). The unknown-provider case returns through the **same existing channel** — no new error type, no new tool-result shape, no agent-loop change. `generateImageTool` / `generateVideoTool` format it as `"Error: {s}"`, and `makeMediaResult` in `src/runtime/js_bindings.zig` surfaces `message` to the model, so the agent can tell the user which env var to set.

### 3.8 Files touched

| File | Change |
|---|---|
| `src/tools/media_gen.zig` | Replace flat fields with `ImagePlaneConfig` / `VideoPlaneConfig`; strict `resolveBaseUrl`; `resolveApiKey`; `pub` + parameterized `buildAuthHeaders`; `resolveProviderOptionsJson`; `polling_url` / `unsigned_urls` support; 4 call sites updated |
| `src/core/config/types.zig` | 16 image fields on `Config`, 16 on `JsonConfig` |
| `src/core/config/resolvers.zig` | `ReasoningAndMediaSettings`; 32 env reads incl. the `openai_compat` → `OPENAI_COMPAT_*` migration lookup |
| `src/core/config/dotenv.zig` | 32 lines in `applyActionLoopAndMediaJsonConfig` (`:219-248`) |
| `src/core/agent/loop.zig` | `initMediaAndTools` (`:371-372`) builds nested structs; drops the two chat-plane fields |
| `src/ui/repl.zig` | `:515-535` reads `config.image_gen_*` → `config.image_gen_*` (unchanged names on `Config`) |
| `src/main.zig`, `src/ui/repl.zig` | Help text for the 32 new vars |
| `testcases/test_media_gen.zig` | New tests |

`src/core/media_protocol.zig` is **not** modified. It remains a types module; wiring it into dispatch belongs to the deferred builder work.

---

## 4. Success Criteria

1. `resolveBaseUrl` with `provider = "openrouter"` and no URL returns `unknown_provider`; the message names both `openrouter` and `MINI_IMAGE_GEN_URL`.
2. `resolveBaseUrl` with `provider = "openrouter"` and `MINI_IMAGE_GEN_URL = "https://example.test/api/v1"` returns that base verbatim; combined with `resolveEndpointUrl(..., "images/generations")` it yields exactly `https://example.test/api/v1/images/generations`.
3. For `openai`, `agnes`, and `openai_compat` (with and without `OPENAI_COMPAT_URL`), the resolved base URL is identical to the pre-change value.
4. `resolveBaseUrl` with `MINI_IMAGE_GEN_URL = "https://host/v1/images/generations"` returns the full string unmodified — `cleanBaseUrl` does not truncate it.
5. `buildAuthHeaders` with header `X-API-Key` and key `k` emits `X-API-Key` with value `k` and no `Bearer` prefix; with header `Authorization` and key `k` emits `Bearer k`; with `key = null` emits only `Content-Type`.
6. `MediaGenConfig` contains no field sourced from the chat plane; `initMediaAndTools` passes no `openai_compat_url` / `openai_compat_key`.
7. `resolveReasoningAndMediaSettings` maps each of the 32 env vars to its `Config` field, and the `openai_compat` provider with only `OPENAI_COMPAT_URL` set still yields that URL in `image_gen_url`.
8. `resolveProviderOptionsJson` returns `null` when all routing fields are unset; emits `{"only":[...],"sort":"price","allow_fallbacks":false}` when they are set; returns an error when `provider_options` is a JSON array or malformed text.
9. A video submit response containing `polling_url` is used verbatim as the poll URL; a completed poll body containing `unsigned_urls[0]` is used verbatim as the download URL.
10. `zig build test -Dskip-e2e=true` passes; `zig build test --summary all` passes 13/13.