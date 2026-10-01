# RFC-027: Universal Media Protocol — Provider-Agnostic Image & Video Generation Architecture

**Status**: Proposed  
**Date**: 2026-10-01  
**Author**: Media & Protocol Engineering  
**Related**: RFC-011 (Media Generation & Vision Loop-Back), RFC-012 (Provider Abstraction Layer)  
**Tags**: Multimodal, Image Generation, Video Generation, OpenRouter, Wire Protocol, Provider-Agnostic  

---

## 1. Executive Summary

This RFC establishes a clean, extensible, and **provider-agnostic Media Generation Protocol** for `mini-agent`. Taking inspiration from **OpenRouter's unified multimodal design patterns** (`/api/v1/images` and `/api/v1/videos`), this RFC defines a standard agent protocol representation for image and video synthesis that cleanly decouples tool execution from any specific vendor API.

### Core Objectives
1. **Design as Protocol Reference (Not Vendor Lock-In)**:
   Use modern industry patterns (typed aspect ratios, resolutions, normalized duration, and async job lifecycle) as the canonical design contract. Any provider—whether OpenAI, OpenRouter, Agnes AI, or a custom local proxy—plugs into this unified interface.
2. **Normalized Data Structures (`src/core/media_protocol.zig`)**:
   Establish strongly-typed enums (`AspectRatio`, `Resolution`, `JobState`) and request descriptors (`ImageGenRequest`, `VideoGenRequest`) without hardcoding vendor-specific requirements into the agent core.
3. **Pluggable & Non-Invasive Provider Translation**:
   The protocol automatically translates normalized requests into vendor-specific wire formats:
   - **OpenAI**: Translates `(resolution, aspect_ratio)` into legacy `size` strings (e.g., `1024x1024`), duration into seconds, dispatching to standard `/v1/images/generations` and `/v1/videos`.
   - **OpenRouter & Modern Gateways**: Passes typed `resolution`, `aspect_ratio`, and `duration` directly to `/api/v1/images` and `/api/v1/videos`.
   - **Agnes AI & Custom Proxies**: Respects existing base URLs, custom headers, and polling endpoints seamlessly.
4. **Preserve Existing Defaults & Backward Compatibility**:
   Existing configurations, default models (`gpt-image-1`, `sora-2`), and environment variables remain 100% untouched. No vendor is enforced as a mandatory default.

---

## 2. Motivation & Architectural Background

In RFC-011 (`src/tools/media_gen.zig`), image and video generation were tightly bound to legacy OpenAI API paths (`/images/generations`) with ad-hoc conditionals for vendor proxies (such as Agnes AI's `/agnesapi?video_id=...`).

### The Missing Layer: A Normalized Protocol
When an LLM agent wants to generate media, it needs standard parameters:
- **Image**: Prompt, Model, Aspect Ratio (`16:9`, `1:1`, `9:16`), Resolution (`1K`, `2K`, `1080p`).
- **Video**: Prompt, Model, Duration, Resolution, Aspect Ratio.

Without a normalized protocol layer, tools had to:
- Accept arbitrary, loosely-typed strings.
- Force hardcoded parameter transformations in every tool handler.
- Restrict CodeAct scripts from expressing modern multimodal parameters.

By modeling our protocol around the clean design pattern established by OpenRouter, we decouple **what the agent requests** from **how a specific provider fulfills it**.

---

## 3. Protocol Design Pattern (Inspired by OpenRouter)

OpenRouter's API demonstrates how to normalize multimodal generation across 30+ heterogeneous upstream providers (Flux, Stable Diffusion, DALL-E, Sora, Veo, Runway, Luma):

### 3.1 Normalized Request Schema
- **Image**:
  - `prompt`: Text description.
  - `model`: Optional target model identifier.
  - `resolution`: Standard enum (`720p`, `1080p`, `1K`, `2K`, `4K`).
  - `aspect_ratio`: Standard enum (`1:1`, `16:9`, `9:16`, `4:3`, `3:4`, `21:9`).
  - `n`: Number of outputs.
  - `input_references`: Optional reference image URLs or base64 data for image-to-image.
- **Video (Async Job Lifecycle)**:
  - `prompt`: Motion/scene description.
  - `model`: Target video model identifier.
  - `duration`: Target duration in seconds.
  - `resolution` & `aspect_ratio`: Output format.
  - Standard Job States: `queued` $\to$ `processing` $\to$ `completed` | `failed`.

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
                  │  • Standard Enums: AspectRatio, Resolution, JobState   │
                  │  • Legacy Coercion Helpers                             │
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
    • Maps to `size` string        • Maps to native schema          • Maps to compat schema
    • /images/generations          • /api/v1/images                 • OPENAI_COMPAT_URL
    • /videos                      • /api/v1/videos (async job)     • Polling adapters
```

### 4.1 Normalized Protocol Definitions (`src/core/media_protocol.zig`)

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
        if (std.ascii.eqlIgnoreCase(s, "2k") or std.mem.eql(u8, s, "1536x1024") or std.mem.eql(u8, s, "1024x1536")) return .res_2k;
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

    pub fn asString(self: JobState) []const u8 {
        return switch (self) {
            .queued => "queued",
            .processing => "processing",
            .completed => "completed",
            .failed => "failed",
            .timeout => "timeout",
        };
    }
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

### 4.2 Flexible Provider Adapters

The dispatcher dynamically detects provider wire format based on the configured or requested provider:

1. **OpenAI Mode**:
   - Maps `resolution` + `aspect_ratio` into OpenAI's legacy `size` parameter (`"1024x1024"`, `"1536x1024"`, etc.).
   - Dispatches to `<base_url>/images/generations` and `<base_url>/videos`.
2. **OpenRouter Mode**:
   - Emits canonical `resolution` and `aspect_ratio` properties in payload.
   - Dispatches to `<base_url>/images` and `<base_url>/videos`.
   - Reads job `polling_url` directly from submission response when available.
3. **Agnes & Custom Compat Mode**:
   - Uses configured `OPENAI_COMPAT_URL` with automatic endpoint resolution.
   - Preserves custom video polling logic (`/agnesapi?video_id=...`).

### 4.3 CodeAct JS VM Options (`mini.media`)

The QuickJS interface is updated to allow optional modern parameters without breaking existing calls:

```javascript
// Standard Call (works across all providers)
mini.media("image", "A tranquil mountain temple at dawn", {
    aspect_ratio: "16:9",
    resolution: "2K",
    filename: "temple"
});

// Legacy Call (automatically coerced)
mini.media("image", "Logo design", {
    size: "1024x1024",
    model: "dall-e-3"
});

// Video with custom duration
mini.media("video", "Waves crashing on rocky shore", {
    duration: 6,
    aspect_ratio: "16:9"
});
```

---

## 5. Non-Breaking Configuration Strategy

All existing defaults remain unchanged:
- `image_gen_provider`: defaults to `"openai"`.
- `video_gen_provider`: defaults to `"openai"`.
- `image_gen_model`: defaults to `"gpt-image-1"`.
- `video_gen_model`: defaults to `"sora-2"`.

Users or agents can configure any provider via standard environment variables:
```bash
# Optional: Set OpenRouter or any custom provider
MINI_IMAGE_GEN_PROVIDER="openrouter" # or "openai", "agnes", "openai_compat"
MINI_VIDEO_GEN_PROVIDER="openrouter"

# Optional: Dedicated or fallback API keys
OPENROUTER_API_KEY="sk-or-..."      # Used if provider is openrouter
OPENAI_COMPAT_API_KEY="sk-..."       # Used as fallback or compat key
OPENAI_API_KEY="sk-..."              # Standard OpenAI key
```

---

## 6. Backward Compatibility & Non-Dogmatic Coercion

1. **Legacy `size` String Coercion**:
   - `"1024x1024"` $\implies$ `Resolution.res_1k, AspectRatio.ar_1_1`
   - `"1536x1024"` $\implies$ `Resolution.res_2k, AspectRatio.ar_16_9`
   - `"1024x1536"` $\implies$ `Resolution.res_2k, AspectRatio.ar_9_16`
   - Any unknown string gracefully falls back to `Resolution.res_1k, AspectRatio.ar_1_1` without error.
2. **Legacy `seconds` Coercion**:
   - `seconds` maps directly to `duration`. Values $\le 0$ default to 4; values $> 60$ clamp safely to 60.
3. **Existing Tool Signatures**:
   - `generateImageDirect` and `generateVideoDirect` remain fully available and act as thin wrappers around the protocol request structs.

---

## 7. Summary of Deliverables

- `src/core/media_protocol.zig`: Generic, provider-agnostic data types, enums, and coercion functions.
- `src/tools/media_gen.zig`: Protocol-aware request execution that adapts to OpenAI, OpenRouter, and Agnes seamlessly.
- `src/runtime/js_bindings.zig`: Enhanced `mini.media` options parsing with zero breaking changes.
- `testcases/test_media_protocol.zig`: Comprehensive unit tests for protocol parsing, coercion, and validation.
