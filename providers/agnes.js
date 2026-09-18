//! providers/agnes.js — JavaScript Provider Adapter for Agnes AI
//!
//! Custom hooks for Agnes AI API which may use non-standard reasoning fields
//! like delta.detail.reasoning_content instead of delta.reasoning_content.
//!
//! Usage: Set OPENAI_COMPAT_JS_PROVIDER=providers/agnes.js in your environment
//! or load via config.

export default {
    name: "Agnes AI",
    protocol: "chat_completions",
    echo_policy: "drop",
    thinking_tags: "english_only",
    reasoning_param: "top_level_effort",

    /**
     * Extract reasoning content from SSE chunks.
     * Handles both standard and nested formats used by Agnes AI.
     */
    extractReasoning(chunk) {
        // Try standard delta.reasoning_content
        if (chunk?.choices?.[0]?.delta?.reasoning_content) {
            return chunk.choices[0].delta.reasoning_content;
        }
        // Try nested delta.detail.reasoning_content (common in proxies)
        if (chunk?.choices?.[0]?.delta?.detail?.reasoning_content) {
            return chunk.choices[0].delta.detail.reasoning_content;
        }
        // Try delta.details.reasoning_content (another proxy pattern)
        if (chunk?.choices?.[0]?.delta?.details?.reasoning_content) {
            return chunk.choices[0].delta.details.reasoning_content;
        }
        // Fallback to standard delta.reasoning
        if (chunk?.choices?.[0]?.delta?.reasoning) {
            return chunk.choices[0].delta.reasoning;
        }
        return null;
    },

    /**
     * Extract text content from SSE chunks.
     */
    extractContent(chunk) {
        return chunk?.choices?.[0]?.delta?.content || null;
    },

    /**
     * Transform outgoing request before dispatch.
     * Can inject provider-specific headers or modify request body.
     */
    transformRequest(req) {
        // Add any custom headers or modifications here if needed
        // Example: req.model = "agnes-2.5-flash";
        return req;
    }
};
