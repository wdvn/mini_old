//! agent_backend.zig — Backend initialization and protocol negotiation for AgentLoop.
//!
//! Handles provider detection (OpenAI, Claude, Ollama), base URL configuration,
//! and wire protocol auto-negotiation.

const std = @import("std");
const proto = @import("../protocol.zig");
const openai_mod = @import("../../backends/openai.zig");
const claude_mod = @import("../../backends/claude.zig");
const ollama_mod = @import("../../backends/ollama.zig");
const history_mod = @import("../history.zig");

/// Active AI backend.
pub const Backend = union(enum) {
    openai: openai_mod.Client,
    claude: claude_mod.Client,
    ollama: ollama_mod.Client,

    /// Display name of backend.
    pub fn name(self: Backend) []const u8 {
        return switch (self) {
            .openai => "openai-compat",
            .claude => "claude",
            .ollama => "ollama",
        };
    }

    /// Model name in use.
    pub fn model(self: Backend) []const u8 {
        return switch (self) {
            .openai => |c| c.model,
            .claude => |c| c.model,
            .ollama => |c| c.model,
        };
    }

    /// Sanitizes history according to backend formatting requirements (dispatches instead of
    /// scattering if-else throughout agent loop).
    pub fn sanitizeHistory(self: *Backend, hist: *history_mod.History) bool {
        return switch (self.*) {
            .openai => hist.ensureOpenAICompatible(),
            .claude => hist.ensureClaudeCompatible(),
            // Ollama uses OpenAI-compatible format.
            .ollama => hist.ensureOpenAICompatible(),
        };
    }

    /// Sends message to backend. Returns complete Response.
    pub fn send(
        self: *Backend,
        system_prompt: []const u8,
        msgs: []const proto.Message,
        tool_defs: []const proto.ToolDefinition,
        text_cb: ?*const fn ([]const u8) void,
        think_cb: ?*const fn ([]const u8) void,
    ) !proto.Response {
        return switch (self.*) {
            .openai => |*c| c.sendMessage(system_prompt, msgs, tool_defs, text_cb, think_cb),
            .claude => |*c| c.sendMessage(system_prompt, msgs, tool_defs, text_cb, think_cb),
            .ollama => |*c| c.sendMessage(system_prompt, msgs, tool_defs, text_cb, think_cb),
        };
    }

    /// Sets dynamic reasoning effort ("low" | "medium" | "high" | "none" | null).
    pub fn setReasoningEffort(self: *Backend, effort: ?[]const u8) void {
        switch (self.*) {
            .openai => |*c| c.setReasoningEffort(effort),
            else => {},
        }
    }

    /// Sets dynamic thinking budget tokens (or null).
    pub fn setThinkingBudget(self: *Backend, budget: ?u32) void {
        switch (self.*) {
            .claude => |*c| c.setThinkingBudget(budget),
            else => {},
        }
    }

    /// Sets dynamic reasoning max tokens (or null).
    pub fn setReasoningMaxTokens(self: *Backend, max_tokens: ?u32) void {
        switch (self.*) {
            .openai => |*c| c.setReasoningMaxTokens(max_tokens),
            .claude => |*c| c.setThinkingBudget(max_tokens),
            else => {},
        }
    }
};
