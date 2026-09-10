//! lib/graph/types.zig — Fundamental data types for the Graph Engine.
//!
//! Defines Node/Edge identifiers, Procedural Graph relation types (RFC-010),
//! node types, and attribute payload structures.

const std = @import("std");

pub const NodeId = u32;
pub const EdgeId = u32;
pub const INVALID_NODE: NodeId = std.math.maxInt(u32);
pub const INVALID_EDGE: EdgeId = std.math.maxInt(u32);

/// Relation types defined by RFC-010 Procedural Graph (and extensible for code graphs).
pub const RelationType = enum(u8) {
    leads_to = 0,
    triggers = 1,
    provides_input_for = 2,
    converges_to = 3,
    custom = 255,

    pub fn fromString(s: []const u8) ?RelationType {
        if (std.ascii.eqlIgnoreCase(s, "LEADS_TO") or std.ascii.eqlIgnoreCase(s, "leads_to")) return .leads_to;
        if (std.ascii.eqlIgnoreCase(s, "TRIGGERS") or std.ascii.eqlIgnoreCase(s, "triggers")) return .triggers;
        if (std.ascii.eqlIgnoreCase(s, "PROVIDES_INPUT_FOR") or std.ascii.eqlIgnoreCase(s, "provides_input_for")) return .provides_input_for;
        if (std.ascii.eqlIgnoreCase(s, "CONVERGES_TO") or std.ascii.eqlIgnoreCase(s, "converges_to")) return .converges_to;
        if (std.ascii.eqlIgnoreCase(s, "CUSTOM") or std.ascii.eqlIgnoreCase(s, "custom")) return .custom;
        return null;
    }

    pub fn toString(self: RelationType) []const u8 {
        return switch (self) {
            .leads_to => "LEADS_TO",
            .triggers => "TRIGGERS",
            .provides_input_for => "PROVIDES_INPUT_FOR",
            .converges_to => "CONVERGES_TO",
            .custom => "CUSTOM",
        };
    }
};

/// Node types supported by Procedural Graph and Code Knowledge Graph.
pub const NodeType = enum(u8) {
    tool_action = 0,
    skill = 1,
    reasoning_step = 2,
    task_state = 3,
    code_symbol = 4,
    custom = 255,

    pub fn fromString(s: []const u8) ?NodeType {
        if (std.ascii.eqlIgnoreCase(s, "tool_action")) return .tool_action;
        if (std.ascii.eqlIgnoreCase(s, "skill")) return .skill;
        if (std.ascii.eqlIgnoreCase(s, "reasoning_step")) return .reasoning_step;
        if (std.ascii.eqlIgnoreCase(s, "task_state")) return .task_state;
        if (std.ascii.eqlIgnoreCase(s, "code_symbol")) return .code_symbol;
        if (std.ascii.eqlIgnoreCase(s, "custom")) return .custom;
        return null;
    }

    pub fn toString(self: NodeType) []const u8 {
        return switch (self) {
            .tool_action => "tool_action",
            .skill => "skill",
            .reasoning_step => "reasoning_step",
            .task_state => "task_state",
            .code_symbol => "code_symbol",
            .custom => "custom",
        };
    }
};

/// Attributed edge properties (Φ in RFC-010).
pub const EdgeAttributes = struct {
    condition: ?[]const u8 = null,
    guidance: ?[]const u8 = null,
    pitfalls: ?[]const u8 = null,
    weight: f32 = 1.0,
    supersedes: ?[]const u8 = null,
};

/// Stored Node Record.
pub const NodeRecord = struct {
    id: NodeId,
    name: []const u8,
    node_type: NodeType,
    desc: []const u8,
    is_active: bool = true,
};

/// Stored Edge Record.
pub const EdgeRecord = struct {
    id: EdgeId,
    str_id: ?[]const u8 = null,
    src: NodeId,
    dst: NodeId,
    rel: RelationType,
    attr: EdgeAttributes,
    is_active: bool = true,
};
