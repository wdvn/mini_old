//! agent_folder.zig — Backward-compatibility forwarder for `core/agent/folder.zig`.

const folder = @import("agent/folder.zig");
pub const AgentFolder = folder.AgentFolder;
pub const resolveOrInitAgentFolder = folder.resolveOrInitAgentFolder;
