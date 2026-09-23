//! agent_loop_monitor.zig — Loop monitoring and orbit detection for AgentLoop.
//!
//! Provides stuck turn detection, loop repetition monitoring, and 3D trajectory
//! orbit analysis via procedural graph telemetry.

const std = @import("std");
const json_mod = @import("json.zig");
const graph_store_mod = @import("memact/graph_store.zig");
const agent_mod = @import("agent.zig");
const AgentLoop = agent_mod.AgentLoop;

pub fn isReadOnlyTool(name: []const u8) bool {
    return std.mem.eql(u8, name, "file_read") or
        std.mem.eql(u8, name, "read") or
        std.mem.eql(u8, name, "grep") or
        std.mem.eql(u8, name, "glob") or
        std.mem.eql(u8, name, "list_dir") or
        std.mem.eql(u8, name, "session_diagnostics");
}

pub fn isMutatingTool(name: []const u8) bool {
    return std.mem.eql(u8, name, "file_edit") or
        std.mem.eql(u8, name, "edit") or
        std.mem.eql(u8, name, "multi_file_edit") or
        std.mem.eql(u8, name, "file_write") or
        std.mem.eql(u8, name, "write");
}

pub fn isExploratoryToolCall(tool_name: []const u8, input_json: []const u8) bool {
    if (isReadOnlyTool(tool_name)) return true;
    if (std.mem.eql(u8, tool_name, "bash")) {
        if (json_mod.findString(input_json, "command")) |cmd| {
            const trimmed = std.mem.trim(u8, cmd, " \t\r\n");
            // Check if modifying or redirecting output
            if (std.mem.startsWith(u8, trimmed, "sed -i") or
                std.mem.indexOf(u8, trimmed, " > ") != null or
                std.mem.indexOf(u8, trimmed, " >> ") != null or
                std.mem.startsWith(u8, trimmed, "cat >") or
                std.mem.startsWith(u8, trimmed, "cat <<"))
            {
                return false;
            }
            if (std.mem.startsWith(u8, trimmed, "cat ") or
                std.mem.startsWith(u8, trimmed, "sed ") or
                std.mem.startsWith(u8, trimmed, "grep ") or
                std.mem.startsWith(u8, trimmed, "head ") or
                std.mem.startsWith(u8, trimmed, "tail ") or
                std.mem.startsWith(u8, trimmed, "ls ") or
                std.mem.eql(u8, trimmed, "ls") or
                std.mem.startsWith(u8, trimmed, "find "))
            {
                return true;
            }
        }
    }
    return false;
}

pub const MacroCycle = struct {
    period: usize,
    repetitions: usize,
};

/// Detects repeating patterns in tool name sequence:
/// - 2-cycle: [A, B, A, B] (period = 2)
/// - 3-cycle: [A, B, C, A, B, C] (period = 3)
pub fn detectMacroCycle(records: []const AgentLoop.ToolCallRecord, current_name: []const u8) ?MacroCycle {
    const len = records.len;
    // Check period 2: [A, B, A, B]
    if (len >= 3) {
        const b = current_name;
        const a = records[len - 1].name;
        if (!std.mem.eql(u8, a, b)) {
            if (std.mem.eql(u8, records[len - 2].name, b) and std.mem.eql(u8, records[len - 3].name, a)) {
                var reps: usize = 2;
                if (len >= 5 and std.mem.eql(u8, records[len - 4].name, b) and std.mem.eql(u8, records[len - 5].name, a)) {
                    reps = 3;
                }
                return .{ .period = 2, .repetitions = reps };
            }
        }
    }

    // Check period 3: [A, B, C, A, B, C]
    if (len >= 5) {
        const c = current_name;
        const b = records[len - 1].name;
        const a = records[len - 2].name;
        if (!std.mem.eql(u8, a, b) and !std.mem.eql(u8, b, c) and !std.mem.eql(u8, a, c)) {
            if (std.mem.eql(u8, records[len - 3].name, c) and
                std.mem.eql(u8, records[len - 4].name, b) and
                std.mem.eql(u8, records[len - 5].name, a))
            {
                var reps: usize = 2;
                if (len >= 8 and
                    std.mem.eql(u8, records[len - 6].name, c) and
                    std.mem.eql(u8, records[len - 7].name, b) and
                    std.mem.eql(u8, records[len - 8].name, a))
                {
                    reps = 3;
                }
                return .{ .period = 3, .repetitions = reps };
            }
        }
    }

    return null;
}

/// RFC-022 Gate 2: true when the most recent tool call this turn was a
/// mutating tool (file write/edit) and the act did not fail — indicating
/// the last mutation was verified successful, so a text-only turn is a
/// legitimate Final Answer rather than plan stalling.
pub fn hasRecentVerifiedMutation(self: *AgentLoop) bool {
    if (self.last_act_failed) return false;
    const recs = self.turn_tool_records.items;
    if (recs.len == 0) return false;
    const last = recs[recs.len - 1].name;
    return std.mem.startsWith(u8, last, "file_write") or
        std.mem.startsWith(u8, last, "file_edit") or
        std.mem.startsWith(u8, last, "edit") or
        std.mem.startsWith(u8, last, "write");
}

/// Evaluates whether a tool call constitutes an action loop (consecutive identical, sliding window repeat,
/// macro-cycle alternating sequence, or read-only exploratory budget exceeded).
pub fn checkActionLoop(self: *AgentLoop, tool_name: []const u8, input_json: []const u8) !AgentLoop.LoopCheckResult {
    const trimmed = std.mem.trim(u8, input_json, " \t\r\n");
    // Whitespace-insensitive hash: replays after truncation often re-serialize
    // the same JSON with different formatting; treat them as identical calls.
    const args_hash = fuzzyArgsHash(trimmed);

    // 1. Update read-only exploratory counter
    if (isReadOnlyTool(tool_name)) {
        self.consecutive_readonly_count += 1;
    } else {
        // Any non-readonly tool resets the read-only counter (dropping rule requiring file mutation)
        self.consecutive_readonly_count = 0;
    }

    // 2. Check macro-cycle (alternating tool names across consecutive calls)
    const macro_cycle = detectMacroCycle(self.turn_tool_records.items, tool_name);

    // 3. Check consecutive duplicates (identical arguments)
    if (self.turn_tool_records.items.len > 0) {
        const last = self.turn_tool_records.items[self.turn_tool_records.items.len - 1];
        if (std.mem.eql(u8, last.name, tool_name) and last.args_hash == args_hash) {
            self.consecutive_dup_tool_count += 1;
        } else {
            self.consecutive_dup_tool_count = 1;
        }
    } else {
        self.consecutive_dup_tool_count = 1;
    }

    // 4. Count occurrences in sliding window of recent tool executions
    var window_count: usize = 0;
    const window_size = @min(self.turn_tool_records.items.len, 10);
    const start_idx = self.turn_tool_records.items.len - window_size;
    for (self.turn_tool_records.items[start_idx..]) |rec| {
        if (std.mem.eql(u8, rec.name, tool_name) and rec.args_hash == args_hash) {
            window_count += 1;
        }
    }
    window_count += 1; // including current

    // 5. Append to turn records (cap at 16 items)
    if (self.turn_tool_records.items.len >= 16) {
        const oldest = self.turn_tool_records.orderedRemove(0);
        self.alloc.free(oldest.name);
    }
    const dup_name = try self.alloc.dupe(u8, tool_name);
    errdefer self.alloc.free(dup_name);
    try self.turn_tool_records.append(self.alloc, .{
        .name = dup_name,
        .args_hash = args_hash,
    });

    // Also append to 3D trajectory (cap at 32 items)
    if (self.turn_tool_trajectory.items.len >= 32) {
        const oldest_t = self.turn_tool_trajectory.orderedRemove(0);
        self.alloc.free(oldest_t);
    }
    const dup_traj = try self.alloc.dupe(u8, tool_name);
    errdefer self.alloc.free(dup_traj);
    try self.turn_tool_trajectory.append(self.alloc, dup_traj);

    // Check 3D procedural map orbit
    const traj_orbit = graph_store_mod.PGraphStore.detectTrajectoryOrbit(self.turn_tool_trajectory.items, tool_name);

    // 6. Evaluate circuit breaker thresholds (TRIP)
    if (self.consecutive_dup_tool_count >= self.config.action_loop_consecutive_cap or
        window_count >= self.config.action_loop_window_cap)
    {
        self.action_loop_tripped = true;
        self.last_loop_reason = if (self.consecutive_dup_tool_count >= self.config.action_loop_consecutive_cap) .identical_repeat else .window_repeat;
        return .trip;
    }

    if (macro_cycle) |mc| {
        if (mc.repetitions >= 3) {
            self.action_loop_tripped = true;
            self.last_loop_reason = if (mc.period == 2) .macro_cycle_2 else .macro_cycle_3;
            return .trip;
        }
    }

    if (traj_orbit) |orbit| {
        if (orbit.revolutions >= self.config.action_loop_orbit_cap) {
            self.action_loop_tripped = true;
            self.last_loop_reason = .orbit_cycle;
            return .trip;
        }
    }

    // Note: readonly actions do not trip circuit breaker alone unless repetitive (handled by window/consecutive/orbit checks)
    // or procrastinating on an active plan (handled by Plan Watchdog).

    // 7. Evaluate warning thresholds (WARN)
    if (self.consecutive_dup_tool_count >= 2 or window_count >= 3) {
        self.last_loop_reason = if (self.consecutive_dup_tool_count >= 2) .identical_repeat else .window_repeat;
        return .warn;
    }

    if (macro_cycle) |mc| {
        if (mc.repetitions >= self.config.action_loop_macro_cycle_cap) {
            self.last_loop_reason = if (mc.period == 2) .macro_cycle_2 else .macro_cycle_3;
            return .warn;
        }
    }

    if (traj_orbit) |orbit| {
        if (orbit.revolutions >= 1) {
            self.last_loop_reason = .orbit_cycle;
            return .warn;
        }
    }

    if (self.consecutive_readonly_count >= self.config.action_loop_readonly_warn_cap) {
        self.last_loop_reason = .readonly_budget;
        return .warn;
    }

    self.last_loop_reason = .none;
    return .allow;
}

pub fn clearTurnToolRecords(self: *AgentLoop) void {
    for (self.turn_tool_records.items) |rec| {
        self.alloc.free(rec.name);
    }
    self.turn_tool_records.clearRetainingCapacity();
    self.clearToolCache();
    for (self.turn_tool_trajectory.items) |t| {
        self.alloc.free(t);
    }
    self.turn_tool_trajectory.clearRetainingCapacity();
    self.consecutive_dup_tool_count = 0;
    self.consecutive_readonly_count = 0;
    self.last_loop_reason = .none;
}

pub fn deinitTurnToolRecords(self: *AgentLoop) void {
    self.clearTurnToolRecords();
    self.turn_tool_records.deinit(self.alloc);
    self.turn_tool_trajectory.deinit(self.alloc);
    self.clearToolCache();
    self.tool_cache.deinit(self.alloc);
}

/// Frees all cached tool results (called on turn reset and deinit).
pub fn clearToolCache(self: *AgentLoop) void {
    for (self.tool_cache.items) |entry| {
        self.alloc.free(entry.name);
        self.alloc.free(entry.result);
    }
    self.tool_cache.clearRetainingCapacity();
}

/// Whitespace-insensitive args hash: collapses runs of whitespace outside of
/// nothing (JSON args are compact strings; escaping keeps structure intact) so
/// that a replayed tool call with re-serialized JSON still matches the original
/// signature. Falls back to exact bytes when normalization is unnecessary.
pub fn fuzzyArgsHash(input_json: []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    var i: usize = 0;
    var in_string = false;
    var prev_space = false;
    while (i < input_json.len) : (i += 1) {
        const c = input_json[i];
        if (in_string) {
            h.update(&[_]u8{c});
            if (c == '\\' and i + 1 < input_json.len) {
                i += 1;
                h.update(&[_]u8{input_json[i]});
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        if (c == '"') {
            in_string = true;
            prev_space = false;
            h.update(&[_]u8{c});
            continue;
        }
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            // Collapse whitespace runs outside strings into a single marker.
            if (!prev_space) h.update(&[_]u8{' '});
            prev_space = true;
            continue;
        }
        prev_space = false;
        h.update(&[_]u8{c});
    }
    return h.final();
}

/// Looks up a cached result for a read-only tool call with matching args.
/// Returns the cached result slice (owned by tool_cache, valid until clearToolCache).
pub fn lookupToolCache(self: *AgentLoop, tool_name: []const u8, args_hash: u64) ?[]const u8 {
    for (self.tool_cache.items) |entry| {
        if (entry.args_hash == args_hash and std.mem.eql(u8, entry.name, tool_name)) {
            return entry.result;
        }
    }
    return null;
}

/// Stores a tool result in the per-turn dedupe cache (cap 8 entries, FIFO eviction).
pub fn storeToolCache(self: *AgentLoop, tool_name: []const u8, args_hash: u64, result: []const u8) !void {
    if (self.tool_cache.items.len >= 8) {
        const oldest = self.tool_cache.orderedRemove(0);
        self.alloc.free(oldest.name);
        self.alloc.free(oldest.result);
    }
    try self.tool_cache.append(self.alloc, .{
        .name = try self.alloc.dupe(u8, tool_name),
        .args_hash = args_hash,
        .result = try self.alloc.dupe(u8, result),
    });
}
