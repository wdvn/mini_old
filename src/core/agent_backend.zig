//! agent_backend.zig — Backward-compatibility forwarder for `core/agent/backend.zig`.

const backend = @import("agent/backend.zig");
pub const Backend = backend.Backend;
