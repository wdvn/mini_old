# RFC-027: OpenRouter-Standardized Media Protocol — Dedicated Image & Video Generation Architecture

**Status**: Proposed  
**Date**: 2026-10-01  
**Author**: Media & Protocol Engineering  
**Related**: RFC-011 (Media Generation & Vision Loop-Back), RFC-012 (Provider Abstraction Layer)  
**Tags**: Multimodal, Image Generation, Video Generation, OpenRouter, Wire Protocol  

---

## 1. Executive Summary

This RFC establishes a unified, extensible **Media Generation Protocol** for `mini-agent`, standardizing image and video synthesis around the canonical **OpenRouter API specifications** (`/api/v1/images` and `/api/v1/videos`).

Currently, `mini-agent`'s media capabilities (introduced in RFC-011 via `src/tools/media_gen.zig`) rely on fragmented, hardcoded endpoints across legacy OpenAI routes (`/v1/images/generations`, `/v1/videos`) and ad-hoc vendor quirks (e.g., Agnes AI's `/agnesapi?video_id=...`). There is no normalized protocol layer, no capability discovery, and no mechanism for per-call or provider-level customization through CodeAct or tool execution.

This proposal introduces:
1. **Normalized Media Protocol (`src/core/media_protocol.zig`)**: Strongly-typed request/response data structures, aspect ratio, resolution, and async job lifecycle primitives modeled after OpenRouter.
2. **OpenRouter Canonical Provider Engine**: Native support for OpenRouter's synchronous `/api/v1/images` and asynchronous `/api/v1/videos` (Submit $\to$ Poll $\to$ Download) pipelines as the primary standard.
3. **Pluggable Media Provider Profiles**: Decoupled provider definitions enabling transparent routing between OpenRouter, OpenAI, and custom proxies (Agnes, Fal.ai, etc.) without altering tool logic.
4. **Enhanced CodeAct & Tool Interfaces**: Upgraded `mini.media(kind, prompt, opts)` and native tools (`generate_image`, `generate_video`) accepting modern multimodal parameters (`aspect_ratio`, `resolution`, `duration`, `input_reference`, `provider`).
5. **Full Backward Compatibility**: Seamless translation of legacy OpenAI parameters (`size="1024x1024"`, `seconds=4`) into canonical protocol structures.

---

## 2. Current State & Pain Points (RFC-011 Evidence)

### 2.1 Current Architecture & Deficiencies

| Component | Current Implementation (`src/tools/media_gen.zig`) | Architectural Limitation |
|---|---|---|
| **Image Generation** | Hardcoded POST to `<base_url>/images/generations` | OpenAI-only legacy schema; fails against modern multi-provider gateways like OpenRouter which use `/api/v1/images` with typed resolutions and aspect ratios. |
| **Video Generation** | Ad-hoc branching: standard Sora POST to `/videos` vs hardcoded Agnes polling to `/agnesapi?video_id={id}&model_name={model}` | Tight coupling in application code; cannot support new video providers without modifying Zig core files. |
| **Parameter Expressivity** | Only accepts `size` string (e.g. `"1024x1024"`) and `seconds` integer | Incompatible with modern models that expect aspect ratios (`"16:9"`, `"9:16"`, `"1:1"`), resolutions (`"720p"`, `"1080p"`, `"1K"`, `"2K"`), audio toggles, and image-to-image/reference inputs. |
| **Provider Selection** | Global env variables only (`MINI_IMAGE_GEN_PROVIDER`, `MINI_VIDEO_GEN_PROVIDER`) | CodeAct scripts (`mini.media`) cannot dynamically select a provider or model per execution turn. |
| **Async Polling** | Tight loop with basic JSON sniffing in `pollVideoJob` | Lacks exponential backoff, standardized job status normalization, and typed error code extraction. |

---

## 3. OpenRouter Canonical Specification Reference

OpenRouter provides dedicated generation endpoints designed specifically to normalize heterogeneous upstream models (Google Veo, Bytedance Seedream, Black Forest Labs Flux, Runway Gen-3, OpenAI Sora, etc.):

### 3.1 Image Generation (`POST /api/v1/images`)

**Request Payload:**
```json
{
  "model": "bytedance-seed/seedream-4.5",
  "prompt": "Cyberpunk terminal running in neon rain, 8k render",
  "resolution": "2K",
  "aspect_ratio": "16:9",
  "n": 1,
  "input_references": ["data:image/png;base64,..."]
}
```

**Response Payload:**
```json
{
  "created": 1748372400,
  "data": [
    {
      "b64_json": "<base64-encoded-image>",
      "media_type": "image/png",
      "url": "https://..."
    }
  ],
  "usage": {
    "prompt_tokens": 0,
    "completion_tokens": 0,
    "total_tokens": 0
  }
}
```

### 3.2 Video Generation (`POST /api/v1/videos` & Polling Workflow)

**Step 1: Submit Job (`POST /api/v1/videos`)**
```json
{
  "model": "google/veo-3.1",
  "prompt": "Camera sweeping over futuristic cityscape at sunrise",
  "duration": 6,
  "resolution": "1080p",
  "aspect_ratio": "16:9",
  "generate_audio": true
}
```

**Submission Response:**
```json
{
  "id": "gen_job_8f2940af1c",
  "status": "queued",
  "polling_url": "https://openrouter.ai/api/v1/videos/gen_job_8f2940af1c"
}
```

**Step 2: Status Polling (`GET /api/v1/videos/{job_id}` or `polling_url`)**
```json
{
  "id": "gen_job_8f2940af1c",
  "status": "completed",
  "metadata": {
    "url": "https://openrouter.ai/artifacts/videos/gen_job_8f2940af1c.mp4",
    "duration": 6,
    "format": "mp4"
  }
}
```
*Possible Status Values:* `"queued"` $\to$ `"processing"` $\to$ `"completed"` | `"failed"`.

---

## 4. Architectural Design

```
                     ┌────────────────────────────────────────────────────────┐
                     │          CodeAct (mini.media) / Native Tools           │
                     └──────────────────────────┬─────────────────────────────┘
                                                │
                                                ▼
                     ┌────────────────────────────────────────────────────────┐
                     │         src/core/media_protocol.zig (RFC-027)          │
                     │  • Typed Requests (Image/Video)                        │
                     │  • Enums: Resolution, AspectRatio, JobState            │
                     │  • Normalization & Legacy Parameter Mapping            │
                     └──────────────────────────┬─────────────────────────────┘
                                                │
                                                ▼
                     ┌────────────────────────────────────────────────────────┐
                     │            Media Provider Abstraction Layer            │
                     │  • OpenRouter Provider (Canonical Default)             │
                     │  • OpenAI Legacy Provider                              │
                     │  • Agnes / Custom Proxy Provider                       │
                     └──────────────────────────┬─────────────────────────────┘
                                                │
                       ┌────────────────────────┴────────────────────────┐
                       ▼                                                 ▼
        [POST /api/v1/images]                             [POST /api/v1/videos]
        • Direct HTTP POST                                • Async Job Submit
        • Sniff b64_json or URL                           • Non-blocking Backoff Polling
        • Local File & Hook Dispatch                      • Download, Verify & Hook Dispatch
```

### 4.1 Normalized Protocol Layer (`src/core/media_protocol.zig`)

```zig
pub const AspectRatio = enum {
    ar_1_1,     // "1:1"
    ar_16_9,    // "16:9"
    ar_9_16,    // "9:16"
    ar_4_3,     // "4:3"
    ar_3_4,     // "3:4"
    ar_21_9,    // "21:9"

    pub fn asString(self: AspectRatio) []const u8 {
        return switch (self) {
            .ar_1_1 => "1:1",
            .ar_16_9 => "16:9",
            .ar_9_16 => "9:16",
            .ar_4_3 => "4:3",
            .ar_3_4 => "3:4",
            .ar_21_9 => "21:9",
        };
    }

    pub fn parse(s: []const u8) ?AspectRatio {
        if (std.mem.eql(u8, s, "1:1") or std.mem.eql(u8, s, "square")) return .ar_1_1;
        if (std.mem.eql(u8, s, "16:9") or std.mem.eql(u8, s, "landscape")) return .ar_16_9;
        if (std.mem.eql(u8, s, "9:16") or std.mem.eql(u8, s, "portrait")) return .ar_9_16;
        if (std.mem.eql(u8, s, "4:3")) return .ar_4_3;
        if (std.mem.eql(u8, s, "3_4")) return .ar_3_4;
        if (std.mem.eql(u8, s, "21:9")) return .ar_21_9;
        return null;
    }
};

pub const Resolution = enum {
    res_720p,   // "720p"
    res_1080p,  // "1080p"
    res_1k,     // "1K"
    res_2k,     // "2K"
    res_4k,     // "4K"

    pub fn asString(self: Resolution) []const u8 {
        return switch (self) {
            .res_720p => "720p",
            .res_1080p => "1080p",
            .res_1k => "1K",
            .res_2k => "2K",
            .res_4k => "4K",
        };
    }

    pub fn parse(s: []const u8) ?Resolution {
        if (std.ascii.eqlIgnoreCase(s, "720p")) return .res_720p;
        if (std.ascii.eqlIgnoreCase(s, "1080p")) return .res_1080p;
        if (std.ascii.eqlIgnoreCase(s, "1k") or std.mem.eql(u8, s, "1024x1024")) return .res_1k;
        if (std.ascii.eqlIgnoreCase(s, "2k") or std.mem.eql(u8, s, "1536x1024")) return .res_2k;
        if (std.ascii.eqlIgnoreCase(s, "4k")) return .res_4k;
        return null;
    }
};

pub const JobState = enum {
    queued,
    processing,
    completed,
    failed,
    timeout,
};

pub const ImageGenRequest = struct {
    prompt: []const u8,
    model: ?[]const u8 = null,
    resolution: ?Resolution = null,
    aspect_ratio: ?AspectRatio = null,
    n: u8 = 1,
    filename: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    input_references: []const []const u8 = &.{},
};

pub const VideoGenRequest = struct {
    prompt: []const u8,
    model: ?[]const u8 = null,
    duration: u32 = 4,
    resolution: ?Resolution = null,
    aspect_ratio: ?AspectRatio = null,
    generate_audio: bool = false,
    filename: ?[]const u8 = null,
    provider: ?[]const u8 = null,
};
```

### 4.2 Media Provider Registry & Abstraction

To avoid scattered branching across `media_gen.zig`, each provider is represented by a `MediaProviderProfile`:

```zig
pub const MediaProviderType = enum {
    openrouter,
    openai,
    agnes,
    custom_compat,
};

pub const MediaProviderProfile = struct {
    provider_type: MediaProviderType,
    name: []const u8,
    default_base_url: []const u8,
    image_endpoint_path: []const u8,       // e.g. "api/v1/images" vs "v1/images/generations"
    video_endpoint_path: []const u8,       // e.g. "api/v1/videos" vs "v1/videos"
    supports_aspect_ratio_param: bool,     // true for OpenRouter; false for legacy OpenAI size string
    auth_header_format: enum { bearer, custom },
};
```

#### Provider Profile Configurations:
1. **`openrouter` (Default)**:
   - Base URL: `https://openrouter.ai/api/v1`
   - Image Endpoint: `images`
   - Video Endpoint: `videos`
   - Polling URL: Reads `polling_url` directly from submission response; falls back to `api/v1/videos/{id}`.
   - Format: Direct `resolution` and `aspect_ratio` properties.
2. **`openai` (Legacy)**:
   - Base URL: `https://api.openai.com/v1`
   - Image Endpoint: `images/generations`
   - Video Endpoint: `videos`
   - Format: Maps `(resolution, aspect_ratio)` into standard `size` string (e.g. `1024x1024`).
3. **`agnes` / `openai_compat`**:
   - Configurable base URL via `OPENAI_COMPAT_URL`.
   - Preserves compatibility with proxy endpoints while supporting OpenRouter-style parameters.

### 4.3 Asynchronous Video Polling with Adaptive Backoff

Video generation typically requires 15 seconds to 4 minutes. The polling engine is updated with adaptive backoff to reduce network overhead and respect rate limits:

```
[Job Submitted] ──> Initial delay: 3s
                         │
                         ▼
                    [Poll Status] 
                         │
        ┌────────────────┼────────────────┐
        ▼                ▼                ▼
   "completed"      "processing"       "failed"
        │                │                │
        │           Backoff:              │
        │           min(prev * 1.5, 10s)  ▼
        │                │           [Return Error]
        │                ▼
        │          Sleep duration
        │                │
        │                └───> (Repeat until timeout)
        ▼
   [Download Artifact via GET]
        │
        ▼
   [Sanitize & Write to Disk]
        │
        ▼
   [Dispatch `media_saved` Hook]
```

### 4.4 Upgraded CodeAct JS VM Binding (`mini.media`)

The QuickJS `mini.media` binding in `src/runtime/js_bindings.zig` is updated to parse the full OpenRouter option matrix:

```javascript
// Example 1: High-resolution cinematic image via OpenRouter
const img = mini.media("image", "Neon cyber-monk meditating on mountain peak", {
    model: "bytedance-seed/seedream-4.5",
    aspect_ratio: "16:9",
    resolution: "2K",
    filename: "cyber_monk"
});

// Example 2: Video generation with custom duration and aspect ratio
const vid = mini.media("video", "Drone flying through rainy futuristic market", {
    model: "google/veo-3.1",
    duration: 6,
    aspect_ratio: "16:9",
    resolution: "1080p",
    filename: "neon_market"
});

// Example 3: Explicit provider override
const quickImg = mini.media("image", "Minimalist logo", {
    provider: "openai",
    model: "dall-e-3",
    size: "1024x1024"
});
```

---

## 5. Configuration & Environment Variables

| Variable | Type | Default | Description |
|---|---|---|---|
| `MINI_MEDIA_PROVIDER` | string | `"openrouter"` | Canonical media provider: `"openrouter"`, `"openai"`, `"agnes"`, `"openai_compat"`. |
| `OPENROUTER_API_KEY` | string | `null` | Primary API key for OpenRouter endpoints. |
| `MINI_IMAGE_GEN_MODEL` | string | `"bytedance-seed/seedream-4.5"` | Default model for image generation when unstated. |
| `MINI_IMAGE_GEN_RESOLUTION` | string | `"1K"` | Default resolution (`"720p"`, `"1080p"`, `"1K"`, `"2K"`, `"4K"`). |
| `MINI_IMAGE_GEN_ASPECT_RATIO` | string | `"1:1"` | Default aspect ratio (`"1:1"`, `"16:9"`, `"9:16"`, `"4:3"`). |
| `MINI_VIDEO_GEN_MODEL` | string | `"google/veo-3.1"` | Default model for video generation when unstated. |
| `MINI_VIDEO_GEN_DURATION` | int | `4` | Default video duration in seconds. |
| `MINI_MEDIA_OUTPUT_DIR` | string | `"media"` | Destination directory for saved media files. |
| `MINI_VIDEO_POLL_TIMEOUT_SECS` | int | `600` | Max duration to poll video generation jobs (10 minutes). |

*Fallback Hierarchy:* If `OPENROUTER_API_KEY` is absent, the provider automatically checks `OPENAI_COMPAT_API_KEY` or `OPENAI_API_KEY`.

---

## 6. Security, Resource Controls & Safety Bounds

1. **Path Traversal Protection**: All user/model-supplied filenames pass through `sanitizeFilename()`, stripping `..`, slashes, non-alphanumeric characters (preserving `_` and `-`), capped at 64 characters.
2. **Download Size Quotas**:
   - Images: Max 25 MB payload limit.
   - Videos: Max 250 MB download stream limit.
3. **Polling Circuit Breaker**: Hard timeout at `video_poll_timeout_secs` (default 600s). In-progress jobs that stall or return 5xx errors $> 5$ consecutive times abort with a descriptive diagnostic error.
4. **Credential Isolation**: Bearer tokens are kept in core memory and never exposed to the JS VM global environment or recorded into session logs.

---

## 7. Migration & Backward Compatibility

- **Existing RFC-011 Tests**: Existing calls to `generateImageDirect` and `generateVideoDirect` will be retained as adapters forwarding to the new protocol layer.
- **Legacy Parameter Coercion**:
  - `opts.size = "1024x1024"` $\implies$ `resolution = .res_1k, aspect_ratio = .ar_1_1`.
  - `opts.size = "1536x1024"` $\implies$ `resolution = .res_2k, aspect_ratio = .ar_16_9`.
  - `opts.seconds = 6` $\implies$ `duration = 6`.
- **Existing Env Variables**: `MINI_IMAGE_GEN_PROVIDER` and `MINI_VIDEO_GEN_PROVIDER` continue to function as granular overrides over `MINI_MEDIA_PROVIDER`.

---

## 8. Implementation Plan & Verifiable Milestones

### Phase 1: Protocol Data Structures & Normalization
- Create `src/core/media_protocol.zig`.
- Implement `AspectRatio`, `Resolution`, `JobState` parsers and stringifiers.
- Implement legacy size string conversion functions.
- Unit test suite: `testcases/test_media_protocol.zig`.

### Phase 2: OpenRouter Provider Implementation
- Implement OpenRouter image dispatch (`POST /api/v1/images`).
- Implement OpenRouter video dispatch (`POST /api/v1/videos`) with adaptive polling loop.
- Support `b64_json` and direct binary download URLs.
- Update `src/tools/media_gen.zig` to use the unified provider engine.

### Phase 3: CodeAct JS VM Binding & Tool Registry Updates
- Update `MediaJsOptions` in `src/runtime/js_bindings.zig` to parse `aspect_ratio`, `resolution`, `duration`, and `provider`.
- Update native tool definitions (`generate_image`, `generate_video`) in `src/tooling/registry.zig`.
- Verify turn loop-back attachment integration (`image_attach`).

### Phase 4: Mock Server Integration & E2E Validation
- Update `scripts/mock_llm_server.js` to simulate OpenRouter `/api/v1/images` and `/api/v1/videos` polling with `polling_url`.
- Run full pre-commit verification: `zig build test --summary all` (all test steps must pass).
