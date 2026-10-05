//! history.zig — In-memory conversation history facade for mini-agent.
//!
//! Refactored into modular sub-package under `core/history/`:
//!   - `history/types.zig`   — History struct definition, memory management, block cloning
//!   - `history/append.zig`  — Message appending, image ingestion, error observation, rollback
//!   - `history/compact.zig` — Auto-compaction, summary compaction, and MemAct context compression
//!   - `history/compat.zig`  — Claude and OpenAI protocol compatibility sanitizers
//!   - `history/backup.zig`  — History serialization and file backup/restore
//!
//! This file maintains 100% backward compatibility for all existing imports.

const root = @import("history/root.zig");

// Submodules
pub const types = root.types;
pub const backup = root.backup;
pub const append = root.append;
pub const compact = root.compact;
pub const compat = root.compat;

// Re-exports
pub const History = root.History;
pub const DEFAULT_MAX_MESSAGES = root.DEFAULT_MAX_MESSAGES;

test {
    _ = root;
}
