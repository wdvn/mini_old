# RFC-027: Universal Media Protocol — Flexible & Provider-Agnostic Synthesis Architecture

**Status**: Proposed  
**Date**: 2026-10-01  
**Author**: Media & Protocol Engineering  
**Related**: RFC-011 (Media Generation & Vision Loop-Back), RFC-012 (Provider Abstraction Layer)  
**Tags**: Multimodal, Image Generation, Video Generation, Wire Protocol, Provider-Agnostic, Flexible Adapter, Zero-Lock-In  

---

## 1. Executive Summary

This RFC establishes a flexible, extensible, and **completely provider-agnostic Media Generation Protocol** for `mini-agent`.

### Design Philosophy: Reference Pattern, Not Vendor Lock-In
We draw inspiration from modern multimodal gateway designs (such as **OpenRouter's clean separation of concerns** across heterogeneous image and video backends) purely as an **architectural mental model**. The protocol defines clean, canonical representations for media synthesis (aspect ratio, resolution, duration, and async job lifecycle) without tying `mini-agent` to any single vendor, gateway, or closed schema.

### Core Principles
1. **Design Reference (Zero Vendor Lock-In & Zero Strictness)**:
   Modern multimodal APIs demonstrate the elegance of expressing generation requests via clean dimensions: prompt, aspect ratio, resolution, and lifecycle states. Any provider—whether standard OpenAI, OpenRouter, Agnes AI, Fal.ai, Replicate, or a local proxy—plugs cleanly into this protocol.
2. **Postel's Law (Liberal Acceptance, Robust Forwarding)**:
   The protocol is **completely permissive**:
   - Provides standard presets (`1:1`, `16:9`, `9:16`, `1080p`, `2K`, etc.) as ergonomic conveniences.
   - **Never rejects custom values**: arbitrary aspect ratios (e.g., `"3:2"`, `"2:3"`, `"4:5"`), custom resolutions (e.g., `"512x512"`, `"1920x1080"`, `"480p"`, `"8k"`), or novel provider parameters pass through verbatim via optional raw fields (`raw_aspect_ratio`, `raw_resolution`) without lossy coercion or validation errors.
3. **Pluggable & Extensible Provider Adapters**:
   The protocol layer adapts normalized parameters to any target provider:
   - **OpenAI**: Maps standard presets to legacy `size` strings (e.g., `"1024x1024"`), passes raw dimension strings if supplied, and forwards to standard `/v1/images/generations` and `/v1/videos`.
   - **OpenRouter & Modern Gateways**: Emits clean `aspect_ratio`, `resolution`, and `duration` fields to `/api/v1/images` and `/api/v1/videos`.
   - **Agnes AI & Custom Proxies**: Seamlessly respects custom endpoints (`OPENAI_COMPAT_URL`) and async polling mechanisms.
   - **Local & Future Providers**: Any HTTP endpoint can be wired with zero changes to core agent logic.
4. **Preserve All Existing Defaults & 100% Backward Compatibility**:
   - Default provider remains `openai` (`MINI_IMAGE_GEN_PROVIDER="openai"`, `MINI_VIDEO_GEN_PROVIDER="openai"`).
   - Default models remain `gpt-image-1` and `sora-2`.
   - Legacy tool parameters (`size="1024x1024"`, `seconds=4`) and direct tool signatures remain fully functional.

---

## 2. Motivation & Architectural Background

In RFC-011 (`src/tools/media_gen.zig`), media synthesis was coupled directly to legacy OpenAI API paths (`/images/generations`) with ad-hoc conditionals for custom proxy endpoints.

### Decoupling Intent from Vendor Wire Format
When an agent or user requests media, the intent is conceptual:
- **Image**: Prompt, Model, Aspect Ratio, Resolution.
- **Video**: Prompt, Model, Duration, Aspect Ratio, Resolution.

Different backend providers expect this intent formatted differently:
- Legacy OpenAI expects `size: "1024x1024"`.
- Modern gateways (OpenRouter, Fal, etc.) expect `aspect_ratio: "16:9"` and `resolution: "1080p"`.
- Custom endpoints might accept arbitrary width/height or custom flags.

By establishing an unopinionated protocol layer in `src/core/media_protocol.zig`, we ensure that:
- Agents can express standard or custom parameters cleanly in CodeAct JS (`mini.media`).
- Providers can be swapped or combined without changing tool definitions or user workflows.
- No single provider's idiosyncrasies dictate the agent's internal architecture.

---

## 3. Protocol Design Pattern (Open Reference Architecture)

Drawing from the clean decomposition pattern seen in modern multimodal gateways:

### 3.1 Flexible Request Schema
- **Image Synthesis**:
  - `prompt`: Text description.
  - `model`: Optional target model identifier.
  - `aspect_ratio`: Recognized preset enum (`1:1`, `16:9`, `9:16`, `4:3`, `3:4`, `21:9`) **OR** arbitrary custom ratio string (`raw_aspect_ratio`, e.g., `"3:2"`).
  - `resolution`: Recognized preset enum (`720p`, `1080p`, `1K`, `2K`, `4K`) **OR** arbitrary custom dimension string (`raw_resolution`, e.g., `"512x512"`).
  - `n`: Number of outputs (default: 1).
  - `filename`: Optional output destination filename.
  - `provider`: Optional per-request provider override (e.g., `"openrouter"`, `"openai"`, `"agnes"`).
  - `input_references`: Optional reference image URLs or file paths for image-to-image synthesis.
- **Video Synthesis (Async Lifecycle)**:
  - `prompt`: Motion/scene description.
  - `model`: Optional video model identifier.
  - `duration`: Target duration in seconds (safely clamped, default: 4s).
  - `aspect_ratio` & `resolution`: Flexible preset or raw string.
  - `generate_audio`: Optional boolean flag for models supporting audio tracks.
  - `filename`: Optional output destination filename.
  - `provider`: Optional per-request provider override.
  - Standard Job States: `queued` $\to$ `processing` $\to$ `completed` | `failed` | `timeout`. Lenient parsing ensures unknown provider statuses gracefully map to `processing` rather than throwing errors.

---

## 4. Architecture & Component Layout

```
                  ┌────────────────────────────────────────────────────────┐
                  │          CodeAct (mini.media) / Native Tools           │
                  └──────────────────────────┬─────────────────────────────┘
                                             │
                                             ▼
                  ┌────────────────────────────────────────────────────────┐
                  │         src/core/media_protocol.zig (RFC-027)          │
                  │  • Normalized Requests (ImageGenRequest, VideoGenReq)  │
                  │  • Standard Preset Enums (AspectRatio, Resolution)     │
                  │  • Raw Passthrough (raw_aspect_ratio, raw_resolution)  │
                  │  • Tolerant Coercion & String Extraction Helpers       │
                  └──────────────────────────┬─────────────────────────────┘
                                             │
                                             ▼
                  ┌────────────────────────────────────────────────────────┐
                  │                 Media Dispatch Engine                  │
                  │              (src/tools/media_gen.zig)                 │
                  └──────────────────────────┬─────────────────────────────┘
                                             │
             ┌───────────────────────────────┼───────────────────────────────┐
             ▼                               ▼                               ▼
    [OpenAI Provider]              [OpenRouter Provider]            [Agnes / Custom Proxy]
    • Maps presets to `size`       • Sends native schema            • Respects custom paths
    • /images/generations          • /api/v1/images                 • OPENAI_COMPAT_URL
    • /videos                      • /api/v1/videos (async job)     • Custom polling logic
```

### 4.1 Permissive Protocol Definitions (`src/core/media_protocol.zig`)

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
        if (std.mem.eql(u8, s, "3:4")) return .ar_3_4;
        if (std.mem.eql(u8, s, "21:9")) return .ar_21_9;
        return null; // Custom ratios are retained via raw_aspect_ratio
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
        if (std.ascii.eqlIgnoreCase(s, "2k") or std.mem.eql(u8, s, "1536x1024") or std.mem.eql(u8, s, "1024x1536")) return .res_2k;
        if (std.ascii.eqlIgnoreCase(s, "4k")) return .res_4k;
        return null; // Custom resolutions are retained via raw_resolution
    }
};

pub const JobState = enum {
    queued,
    processing,
    completed,
    failed,
    timeout,

    pub fn asString(self: JobState) []const u8 {
        return switch (self) {
            .queued => "queued",
            .processing => "processing",
            .completed => "completed",
            .failed => "failed",
            .timeout => "timeout",
        };
    }

    pub fn parse(s: []const u8) JobState {
        if (std.ascii.eqlIgnoreCase(s, "completed") or std.ascii.eqlIgnoreCase(s, "succeeded")) return .completed;
        if (std.ascii.eqlIgnoreCase(s, "failed") or std.ascii.eqlIgnoreCase(s, "error")) return .failed;
        if (std.ascii.eqlIgnoreCase(s, "processing") or std.ascii.eqlIgnoreCase(s, "in_progress") or std.ascii.eqlIgnoreCase(s, "running")) return .processing;
        return .queued; // Unknown states default gracefully to queued/processing without crashing
    }
};

pub const ImageGenRequest = struct {
    prompt: []const u8,
    model: ?[]const u8 = null,
    resolution: ?Resolution = null,
    raw_resolution: ?[]const u8 = null,
    aspect_ratio: ?AspectRatio = null,
    raw_aspect_ratio: ?[]const u8 = null,
    n: u8 = 1,
    filename: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    input_references: []const []const u8 = &.{},

    pub fn getAspectRatioString(self: ImageGenRequest) ?[]const u8 {
        if (self.raw_aspect_ratio) |raw| return raw;
        if (self.aspect_ratio) |ar| return ar.asString();
        return null;
    }

    pub fn getResolutionString(self: ImageGenRequest) ?[]const u8 {
        if (self.raw_resolution) |raw| return raw;
        if (self.resolution) |res| return res.asString();
        return null;
    }
};

pub const VideoGenRequest = struct {
    prompt: []const u8,
    model: ?[]const u8 = null,
    duration: u32 = 4,
    resolution: ?Resolution = null,
    raw_resolution: ?[]const u8 = null,
    aspect_ratio: ?AspectRatio = null,
    raw_aspect_ratio: ?[]const u8 = null,
    generate_audio: bool = false,
    filename: ?[]const u8 = null,
    provider: ?[]const u8 = null,

    pub fn getAspectRatioString(self: VideoGenRequest) ?[]const u8 {
        if (self.raw_aspect_ratio) |raw| return raw;
        if (self.aspect_ratio) |ar| return ar.asString();
        return null;
    }

    pub fn getResolutionString(self: VideoGenRequest) ?[]const u8 {
        if (self.raw_resolution) |raw| return raw;
        if (self.resolution) |res| return res.asString();
        return null;
    }
};
```

### 4.2 Flexible Provider Adapters

The dispatcher resolves parameters dynamically without forcing any provider as mandatory:

1. **Standard OpenAI Adapter**:
   - Maps preset `(resolution, aspect_ratio)` to compatible `size` string (e.g. `"1024x1024"`).
   - If a custom `raw_resolution` contains an explicit `"WxH"` dimension (e.g., `"512x512"`), it passes that dimension directly.
   - Dispatches to `<base_url>/images/generations` and `<base_url>/videos`.
2. **OpenRouter & Gateway Adapter**:
   - Dispatches `aspect_ratio` and `resolution` strings directly to `/api/v1/images` and `/api/v1/videos`.
   - Supports both standard presets and arbitrary custom aspect ratios.
3. **Agnes AI & Custom Compat Adapter**:
   - Routes to configured `OPENAI_COMPAT_URL`.
   - Preserves custom polling logic (e.g., `/agnesapi?video_id=...`).
4. **Extensibility**:
   - New backends (e.g., local Diffusers, Fal.ai) can be registered without modifying the caller interface.

### 4.3 CodeAct JS VM Usage (`mini.media`)

QuickJS options support both standard presets and custom values seamlessly:

```javascript
// Preset style (clean and portable across providers)
mini.media("image", "A serene Japanese zen garden in autumn", {
    aspect_ratio: "16:9",
    resolution: "2K",
    filename: "garden"
});

// Custom aspect ratio & resolution (never rejected or dropped)
mini.media("image", "Panoramic mountain ridge", {
    aspect_ratio: "3:2",
    resolution: "1920x1080"
});

// Legacy style (100% backward compatible)
mini.media("image", "Company mascot icon", {
    size: "1024x1024",
    model: "gpt-image-1"
});

// Video generation with flexible duration
mini.media("video", "Drone flying over ocean waves", {
    duration: 6,
    aspect_ratio: "16:9"
});
```

---

## 5. Non-Breaking Configuration Strategy

All existing defaults and behaviors remain completely intact:
- `image_gen_provider`: defaults to `"openai"`.
- `video_gen_provider`: defaults to `"openai"`.
- `image_gen_model`: defaults to `"gpt-image-1"`.
- `video_gen_model`: defaults to `"sora-2"`.

Users or agents can configure any provider via environment variables:
```bash
# Default remains standard OpenAI:
# MINI_IMAGE_GEN_PROVIDER="openai" (default)
# MINI_VIDEO_GEN_PROVIDER="openai" (default)

# Optional: Switch to OpenRouter, Agnes AI, or custom endpoint
MINI_IMAGE_GEN_PROVIDER="openrouter" # or "openai_compat", "agnes"
MINI_VIDEO_GEN_PROVIDER="openrouter"

# Optional: Provider-specific or fallback API keys
OPENAI_API_KEY="sk-..."              # Standard OpenAI key
OPENROUTER_API_KEY="sk-or-..."      # Used when provider is openrouter
OPENAI_COMPAT_API_KEY="sk-..."       # Used for compat or custom gateways
```

---

## 6. Permissive Backward Compatibility & Non-Dogmatic Coercion

1. **Non-Lossy `size` Coercion**:
   - Standard strings map to presets (`"1024x1024"` $\implies$ `1K, 1:1`; `"1536x1024"` $\implies$ `2K, 16:9`; `"1024x1536"` $\implies$ `2K, 9:16`).
   - Custom dimension strings (e.g., `"512x512"`, `"800x600"`, `"1920x1080"`) are **preserved in `raw_resolution` / `raw_size`** so downstream providers supporting custom sizes receive the exact requested dimensions rather than having them overridden.
2. **Safe `seconds` Coercion**:
   - `seconds` maps to `duration`. Clamped to `[1, 60]`; defaults to 4s if unspecified.
3. **Preserved Tool Signatures**:
   - `generateImageDirect` and `generateVideoDirect` remain fully operational as backward-compatible wrappers over the protocol request structs.

---

## 7. Deliverables & Verification

- `src/core/media_protocol.zig`: Permissive, unopinionated data structures with preset enums and raw string passthrough.
- `src/tools/media_gen.zig`: Adaptive dispatch engine supporting OpenAI, OpenRouter, and Agnes AI.
- `src/runtime/js_bindings.zig`: Enhanced `mini.media` options parsing supporting presets, raw strings, and legacy options.
- `testcases/test_media_protocol.zig`: Unit tests verifying parsing, raw string preservation, and legacy coercion.
