//! providers/agnes.js — JavaScript Provider Adapter for Agnes AI
//!
//! Custom hooks for Agnes AI API which may use non-standard reasoning fields
//! like delta.detail.reasoning_content instead of delta.reasoning_content.
//!
//! Usage: Set OPENAI_COMPAT_JS_PROVIDER=providers/agnes.js in your environment
//! or load via config.
//!
//! NOTE: Uses ES5-compatible syntax (no optional chaining) for QuickJS 0.8.0 compatibility.

export default {
    name: "Agnes AI",
    protocol: "chat_completions",
    echo_policy: "drop",
    thinking_tags: "english_only",
    reasoning_param: "top_level_effort",

    /**
     * Helper: safely get nested property without optional chaining (QuickJS 0.8.0 compat).
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
     * Handles both standard and nested formats used by Agnes AI.
     */
    extractReasoning(chunk) {
        if (!chunk || !chunk.choices) return null;
        var firstChoice = chunk.choices[0];
        if (!firstChoice || !firstChoice.delta) return null;
        var delta = firstChoice.delta;

        // Try standard delta.reasoning_content
        if (delta.reasoning_content) {
            return delta.reasoning_content;
        }
        // Try nested delta.detail.reasoning_content (common in proxies)
        if (delta.detail && delta.detail.reasoning_content) {
            return delta.detail.reasoning_content;
        }
        // Try delta.details.reasoning_content (another proxy pattern)
        if (delta.details && delta.details.reasoning_content) {
            return delta.details.reasoning_content;
        }
        // Fallback to standard delta.reasoning
        if (delta.reasoning) {
            return delta.reasoning;
        }
        return null;
    },

    /**
     * Extract text content from SSE chunks.
     */
    extractContent(chunk) {
        if (chunk && chunk.choices && chunk.choices[0] && chunk.choices[0].delta) {
            return chunk.choices[0].delta.content || null;
        }
        return null;
    },

    /**
     * Transform outgoing request before dispatch.
     * Agnes 3.0 Flash enables thinking via chat_template_kwargs.enable_thinking
     * (per https://www.agnes-ai.com/en/docs/agnes-30-flash#thinking-mode).
     * The generic pipeline injects "reasoning_effort" which Agnes does not
     * recognize, so map it to enable_thinking and drop the original field.
     */
    transformRequest(req) {
        var effort = req.reasoning_effort;
        var reasoningEffortIsNone = (effort === "none");
        if (!reasoningEffortIsNone) {
            req.chat_template_kwargs = { enable_thinking: true };
        }
        delete req.reasoning_effort;
        return req;
    }
};