//! providers/apodex.js — JavaScript Provider Adapter for Apodex (apodex/apodex-1.1-mini:free)
//!
//! Custom adapter for Apodex model hosted on OpenRouter or OpenAI-compatible proxies.
//! Normalizes reasoning extraction across standard and nested proxy fields,
//! ensures safe text delta parsing, and cleans up unsupported request fields.
//!
//! Usage: Set OPENAI_COMPAT_PROVIDER=apodex in your environment or ~/.mini/config.json
//!
//! NOTE: Uses ES5-compatible syntax (no optional chaining) for QuickJS compatibility.

export default {
    name: "Apodex",
    protocol: "chat_completions",
    echo_policy: "drop",
    thinking_tags: "english_only",
    reasoning_param: "top_level_effort",

    /**
     * Helper: safely get nested property without optional chaining (QuickJS compat).
     */
    _safeGet(obj, path) {
        var parts = path.split('.');
        var current = obj;
        for (var i = 0; i < parts.length; i++) {
            if (current == null || current === undefined) return undefined;
            current = current[parts[i]];
        }
        return current;
    },

    /**
     * Extract reasoning content from SSE chunks.
     * Supports standard delta.reasoning_content and proxy-wrapped
     * delta.detail(s).reasoning_content as well as delta.reasoning.
     */
    extractReasoning(chunk) {
        if (!chunk || !chunk.choices) return null;
        var firstChoice = chunk.choices[0];
        if (!firstChoice || !firstChoice.delta) return null;
        var delta = firstChoice.delta;

        // 1. Standard delta.reasoning_content
        if (delta.reasoning_content) {
            return delta.reasoning_content;
        }
        // 2. Proxy wrapped in delta.detail.reasoning_content
        if (delta.detail && delta.detail.reasoning_content) {
            return delta.detail.reasoning_content;
        }
        // 3. Proxy wrapped in delta.details.reasoning_content
        if (delta.details && delta.details.reasoning_content) {
            return delta.details.reasoning_content;
        }
        // 4. Standard delta.reasoning fallback
        if (delta.reasoning) {
            return delta.reasoning;
        }
        return null;
    },

    /**
     * Extract text content from SSE chunks.
     * Ensures non-empty string return; returns null for empty deltas or metadata-only chunks.
     */
    extractContent(chunk) {
        if (!chunk || !chunk.choices || !chunk.choices[0] || !chunk.choices[0].delta) return null;
        var content = chunk.choices[0].delta.content;
        if (typeof content === 'string' && content.length > 0) {
            return content;
        }
        return null;
    },

    /**
     * Transform outgoing request before dispatch.
     * Normalizes reasoning_effort for upstream proxies.
     */
    transformRequest(req) {
        if (req.reasoning_effort === "none" || req.reasoning_effort === "default") {
            delete req.reasoning_effort;
        }
        return req;
    }
};
