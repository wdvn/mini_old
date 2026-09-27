//! graph_store.zig — Event-Sourced Procedural Graph Storage for MemAct (RFC-010).
//!
//! Manages persistent Procedural Graph storage at `~/.mini/memory/<project_hash>/pgraph.jsonl`.
//! Replays JSONL event stream into `lib.graph.Graph` (RFC-010 PG-1), tracks tool transitions
//! (PG-2 population pipeline), and generates localized h-hop situational guidance (PG-3).

const std = @import("std");
const Allocator = std.mem.Allocator;
const graph_mod = @import("../../lib/graph.zig");
const Graph = graph_mod.Graph;
const NodeId = graph_mod.NodeId;
const EdgeId = graph_mod.EdgeId;
const RelationType = graph_mod.RelationType;
const NodeType = graph_mod.NodeType;
const EdgeAttributes = graph_mod.EdgeAttributes;
const EdgeRecord = graph_mod.EdgeRecord;
const NeighborhoodResult = graph_mod.NeighborhoodResult;
const traverseNeighborhood = graph_mod.traverseNeighborhood;
const repairCycles = graph_mod.repairCycles;
const checkTerminalReachability = graph_mod.checkTerminalReachability;
const applyEventJson = graph_mod.applyEventJson;
const utils = @import("../utils.zig");
const prompts_mod = @import("../prompts.zig");

pub const PGraphStore = struct {
    alloc: Allocator,
    dir_path: []u8,
    file_path: []u8,
    graph: Graph,
    transitions: std.StringHashMap(u32),
    auto_populate: bool = true,
    id_counter: u64 = 0,

    /// Initialize Procedural Graph store at `dir_path` (e.g. `~/.mini/memory/<project_hash>/`).
    pub fn init(alloc: Allocator, io: std.Io, dir_path: []const u8) !PGraphStore {
        const dir_dup = try alloc.dupe(u8, dir_path);
        errdefer alloc.free(dir_dup);

        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(io, dir_dup) catch {};

        const file_path = try std.fs.path.join(alloc, &.{ dir_dup, "pgraph.jsonl" });
        errdefer alloc.free(file_path);

        return .{
            .alloc = alloc,
            .dir_path = dir_dup,
            .file_path = file_path,
            .graph = Graph.init(alloc),
            .transitions = std.StringHashMap(u32).init(alloc),
            .auto_populate = true,
            .id_counter = 0,
        };
    }

    pub fn deinit(self: *PGraphStore) void {
        var it = self.transitions.keyIterator();
        while (it.next()) |k| {
            self.alloc.free(k.*);
        }
        self.transitions.deinit();
        self.graph.deinit();
        self.alloc.free(self.file_path);
        self.alloc.free(self.dir_path);
    }

    /// Generate unique event ID: prefix + timestamp hex + counter hex + pid hex.
    fn nextId(self: *PGraphStore, prefix: []const u8) ![]u8 {
        self.id_counter += 1;
        return std.fmt.allocPrint(self.alloc, "{s}_{x}_{x}_{x}", .{
            prefix,
            utils.milliTimestamp(),
            self.id_counter,
            std.c.getpid(),
        });
    }

    /// Load index from `pgraph.jsonl`.
    /// If file does not exist, seed foundational default tools and procedural transitions.
    pub fn loadIndex(self: *PGraphStore, io: std.Io) !void {
        const cwd = std.Io.Dir.cwd();
        const file = cwd.openFile(io, self.file_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                try self.seedDefaults(io);
                return;
            }
            return err;
        };
        defer file.close(io);

        const stat = try file.stat(io);
        if (stat.size == 0) {
            try self.seedDefaults(io);
            return;
        }

        const buf = try self.alloc.alloc(u8, @intCast(stat.size));
        defer self.alloc.free(buf);
        const n = try utils.readAll(io, file, buf);

        var it = std.mem.splitScalar(u8, buf[0..n], '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0) continue;
            applyEventJson(&self.graph, line) catch continue;
        }

        // Repair any detected cycle to ensure DAG invariant
        _ = repairCycles(&self.graph, self.alloc) catch 0;
    }

    /// Append a single event line to `pgraph.jsonl` and update in-memory graph.
    pub fn appendEvent(self: *PGraphStore, io: std.Io, line: []const u8) !void {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) return;

        // 1. Update in-memory graph
        try applyEventJson(&self.graph, trimmed);

        // 2. Append to disk
        const cwd = std.Io.Dir.cwd();
        const file = cwd.openFile(io, self.file_path, .{ .mode = .read_write }) catch |err| blk: {
            if (err == error.FileNotFound) {
                break :blk try cwd.createFile(io, self.file_path, .{});
            }
            return err;
        };
        defer file.close(io);

        const end_offset = try file.length(io);
        var write_buf = try self.alloc.alloc(u8, trimmed.len + 1);
        defer self.alloc.free(write_buf);
        @memcpy(write_buf[0..trimmed.len], trimmed);
        write_buf[trimmed.len] = '\n';

        try file.writePositionalAll(io, write_buf, end_offset);
    }

    fn seedDefaultNodes(self: *PGraphStore, io: std.Io) !void {
        // PSEUDOCODE: Append default core tool nodes to graph.
        const default_nodes = [_]struct { name: []const u8, desc: []const u8 }{
            .{ .name = "bash", .desc = "Run shell commands, execute compiler, run tests" },
            .{ .name = "file_read", .desc = "Read and view file content" },
            .{ .name = "file_write", .desc = "Create or overwrite file" },
            .{ .name = "file_edit", .desc = "Perform precise single contiguous code replacement" },
            .{ .name = "multi_file_edit", .desc = "Perform multiple non-contiguous edits in a file" },
            .{ .name = "glob", .desc = "Find files by pattern matching" },
            .{ .name = "grep", .desc = "Search text or regex pattern across codebase" },
            .{ .name = "list_dir", .desc = "List directory contents" },
            .{ .name = "session_diagnostics", .desc = "Inspect session logs, subprocesses, and audit journals" },
            .{ .name = "subagent", .desc = "Spawn subagent for isolated subtasks" },
        };

        for (default_nodes) |dn| {
            const nid = try self.nextId("pgn");
            defer self.alloc.free(nid);
            const line = try std.fmt.allocPrint(self.alloc,
                \\{{"ev":"add_node","id":"{s}","node":{{"name":"{s}","type":"tool_action","desc":"{s}"}}}}
            , .{ nid, dn.name, dn.desc });
            defer self.alloc.free(line);
            try self.appendEvent(io, line);
        }
    }

    const DefaultEdgeDef = struct {
        src: []const u8,
        rel: []const u8,
        dst: []const u8,
        cond: []const u8,
        guid: []const u8,
        pitfalls: []const u8,
    };

    const default_edges = [_]DefaultEdgeDef{
        .{
            .src = "grep",
            .rel = "LEADS_TO",
            .dst = "file_read",
            .cond = "match located in file",
            .guid = "Inspect the exact file and line range discovered by grep to understand context.",
            .pitfalls = "Do not modify code without viewing its surrounding context first.",
        },
        .{
            .src = "glob",
            .rel = "LEADS_TO",
            .dst = "file_read",
            .cond = "target files identified",
            .guid = "Read the target file before making any edits.",
            .pitfalls = "Do not make blind assumptions on file structure.",
        },
        .{
            .src = "file_edit",
            .rel = "LEADS_TO",
            .dst = "bash",
            .cond = "code edit applied",
            .guid = "Run tests or compiler checks immediately after editing code.",
            .pitfalls = "Do not leave scratch test files outside testcases/ or unvalidated edits.",
        },
        .{
            .src = "multi_file_edit",
            .rel = "LEADS_TO",
            .dst = "bash",
            .cond = "multi-chunk edits applied",
            .guid = "Run test suite to verify code compiles and passes validation.",
            .pitfalls = "Ensure all chunks match uniquely without leaving syntax errors.",
        },
        .{
            .src = "file_write",
            .rel = "LEADS_TO",
            .dst = "bash",
            .cond = "new file written",
            .guid = "Run build or tests to verify newly created module.",
            .pitfalls = "Ensure parent directories exist and build targets compile.",
        },
        .{
            .src = "bash",
            .rel = "TRIGGERS",
            .dst = "grep",
            .cond = "compiler error or test failure",
            .guid = "Search codebase for failing symbol or error message to diagnose root cause.",
            .pitfalls = "Do not mutate code before understanding exact error cause.",
        },
        .{
            .src = "bash",
            .rel = "TRIGGERS",
            .dst = "session_diagnostics",
            .cond = "crash, timeout, or unexpected failure",
            .guid = "Inspect session logs and audit journal in ~/.mini/sessions to review telemetry.",
            .pitfalls = "Do not guess backend errors without checking raw_snippet.",
        },
    };

    fn seedDefaultEdges(self: *PGraphStore, io: std.Io) !void {
        // PSEUDOCODE: Append default procedural transitions to graph.
        for (default_edges) |de| {
            const eid = try self.nextId("pge");
            defer self.alloc.free(eid);
            const line = try std.fmt.allocPrint(self.alloc,
                \\{{"ev":"add_edge","id":"{s}","edge":{{"src":"{s}","rel":"{s}","dst":"{s}","condition":"{s}","guidance":"{s}","pitfalls":"{s}"}}}}
            , .{ eid, de.src, de.rel, de.dst, de.cond, de.guid, de.pitfalls });
            defer self.alloc.free(line);
            try self.appendEvent(io, line);
        }
    }

    /// Pre-seed foundational tool nodes and common developer workflow transitions.
    pub fn seedDefaults(self: *PGraphStore, io: std.Io) !void {
        // PSEUDOCODE:
        // 1. Pre-seed default core tool nodes.
        // 2. Pre-seed standard procedural transitions between tools.
        try self.seedDefaultNodes(io);
        try self.seedDefaultEdges(io);
    }

    /// RFC-025 Phase 3: render a compact 2-hop causal chain for a node by
    /// its Node ID (from a memory entry's `node_ref`). Returns the node name,
    /// up to `max` cause/effect neighbors with LEADS_TO guidance. `null` when
    /// the id is dangling (node missing or no active edges) — the record then
    /// renders without graph context (RFC-025 §7).
    pub fn enrichNode(
        self: *PGraphStore,
        alloc: Allocator,
        node_id: NodeId,
        max: usize,
    ) !?[]u8 {
        // PSEUDOCODE:
        // 1. Null-guard: node id must be within the active graph.
        // 2. Collect active out (effects) and in (causes) edges, cap at `max`.
        // 3. Render "[Procedural Context (name)]" header + edge lines.
        //    Empty (no active edges) -> null, so the record renders plain.
        if (node_id >= self.graph.nodes.items.len) return null;
        const node_name = self.graph.nodes.items[node_id].name;

        var body = utils.BufWriter.init(alloc);
        errdefer body.deinit();

        var emitted: usize = 0;
        // Outgoing effects: node -> next.
        for (self.graph.edges.items) |edge| {
            if (emitted >= max) break;
            if (!edge.is_active or edge.src != node_id) continue;
            if (edge.dst >= self.graph.nodes.items.len) continue;
            try self.formatSuggestedEdge(&body, edge);
            emitted += 1;
        }
        // Incoming causes: prev -> node.
        for (self.graph.edges.items) |edge| {
            if (emitted >= max) break;
            if (!edge.is_active or edge.dst != node_id) continue;
            if (edge.src >= self.graph.nodes.items.len) continue;
            try self.formatSuggestedEdge(&body, edge);
            emitted += 1;
        }

        if (emitted == 0) return null;

        // `toOwnedSlice` empties `body` (its `deinit` is then a no-op).
        const body_text = try body.toOwnedSlice();
        defer alloc.free(body_text);
        return std.fmt.allocPrint(alloc, "[Procedural Context ({s})]\n{s}", .{ node_name, body_text }) catch return null;
    }

    /// Match tool action string to known node ID (with common alias normalization).
    pub fn matchNode(self: *const PGraphStore, action_name: []const u8) ?NodeId {
        const normalized = if (std.mem.eql(u8, action_name, "run_command") or std.mem.eql(u8, action_name, "sh"))
            "bash"
        else if (std.mem.eql(u8, action_name, "read_file") or std.mem.eql(u8, action_name, "view_file") or std.mem.eql(u8, action_name, "read"))
            "file_read"
        else if (std.mem.eql(u8, action_name, "write_to_file") or std.mem.eql(u8, action_name, "write"))
            "file_write"
        else if (std.mem.eql(u8, action_name, "replace_file_content") or std.mem.eql(u8, action_name, "patch"))
            "file_edit"
        else if (std.mem.eql(u8, action_name, "multi_replace_file_content"))
            "multi_file_edit"
        else if (std.mem.eql(u8, action_name, "grep_search"))
            "grep"
        else
            action_name;

        return self.graph.findNodeByName(normalized);
    }

    /// Check whether `to` node is reachable from `from` node via active directed edges.
    fn isReachable(graph: *const Graph, from: NodeId, to: NodeId, alloc: Allocator) bool {
        if (from == to) return true;
        var visited = std.AutoHashMap(NodeId, void).init(alloc);
        defer visited.deinit();
        var queue = std.ArrayList(NodeId).empty;
        defer queue.deinit(alloc);

        queue.append(alloc, from) catch return false;
        visited.put(from, {}) catch return false;

        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const curr = queue.items[head];
            if (curr == to) return true;
            if (curr >= graph.out_adj.items.len) continue;
            for (graph.out_adj.items[curr].items) |eid| {
                if (eid >= graph.edges.items.len) continue;
                const edge = graph.edges.items[eid];
                if (!edge.is_active) continue;
                if (!visited.contains(edge.dst)) {
                    if (edge.dst == to) return true;
                    visited.put(edge.dst, {}) catch continue;
                    queue.append(alloc, edge.dst) catch continue;
                }
            }
        }
        return false;
    }

    /// 3D functional domains for procedural state space navigation.
    pub const ToolDomain3D = enum {
        explore,
        mutate,
        verify,
        meta,

        pub fn fromToolName(name: []const u8) ToolDomain3D {
            if (std.mem.eql(u8, name, "file_edit") or
                std.mem.eql(u8, name, "multi_file_edit") or
                std.mem.eql(u8, name, "file_write"))
            {
                return .mutate;
            }
            if (std.mem.eql(u8, name, "subagent") or
                std.mem.eql(u8, name, "codeact") or
                std.mem.eql(u8, name, "batch_subagent"))
            {
                return .meta;
            }
            if (std.mem.eql(u8, name, "bash") or
                std.mem.eql(u8, name, "http"))
            {
                return .verify;
            }
            // Explicit explore tools
            if (std.mem.eql(u8, name, "grep") or
                std.mem.eql(u8, name, "glob") or
                std.mem.eql(u8, name, "list_dir") or
                std.mem.eql(u8, name, "session_diagnostics") or
                std.mem.eql(u8, name, "file_read") or
                std.mem.eql(u8, name, "artifact") or
                std.mem.eql(u8, name, "media_gen"))
            {
                return .explore;
            }
            return .explore;
        }

        pub fn label(self: ToolDomain3D) []const u8 {
            return switch (self) {
                .explore => "EXPLORE",
                .mutate => "MUTATE",
                .verify => "VERIFY",
                .meta => "META",
            };
        }
    };

    pub const OrbitInfo = struct {
        period: usize,
        revolutions: usize,
        orbit_nodes: []const []const u8,
    };

    fn isCycleNodesDistinct(cycle: []const []const u8) bool {
        for (cycle, 0..) |n1, a| {
            for (cycle[a + 1 ..]) |n2| {
                if (std.mem.eql(u8, n1, n2)) return false;
            }
        }
        return true;
    }

    fn hasMutationNode(cycle: []const []const u8) bool {
        for (cycle) |node_name| {
            if (ToolDomain3D.fromToolName(node_name) == .mutate) return true;
        }
        return false;
    }

    fn countMultiRevolutions(trajectory: []const []const u8, p: usize) usize {
        var revs: usize = 2;
        var offset: usize = 3 * p;
        while (trajectory.len >= offset) : (offset += p) {
            var rev_match = true;
            var j: usize = 0;
            while (j < p) : (j += 1) {
                if (!std.mem.eql(u8, trajectory[trajectory.len - p + j], trajectory[trajectory.len - offset + j])) {
                    rev_match = false;
                    break;
                }
            }
            if (rev_match) revs += 1 else break;
        }
        return revs;
    }

    fn checkMultiRevolutionOrbit(trajectory: []const []const u8) ?OrbitInfo {
        var p: usize = 2;
        while (p <= 5) : (p += 1) {
            if (trajectory.len < 2 * p) continue;
            var matches = true;
            var i: usize = 0;
            while (i < p) : (i += 1) {
                const idx1 = trajectory.len - p + i;
                const idx2 = trajectory.len - 2 * p + i;
                if (!std.mem.eql(u8, trajectory[idx1], trajectory[idx2])) {
                    matches = false;
                    break;
                }
            }
            if (!matches) continue;
            const cycle = trajectory[trajectory.len - p .. trajectory.len];
            if (!isCycleNodesDistinct(cycle) or hasMutationNode(cycle)) continue;

            return OrbitInfo{
                .period = p,
                .revolutions = countMultiRevolutions(trajectory, p),
                .orbit_nodes = cycle,
            };
        }
        return null;
    }

    fn checkFirstClosureOrbit(trajectory: []const []const u8, active_tool: []const u8) ?OrbitInfo {
        var p: usize = 2;
        while (p <= 5) : (p += 1) {
            if (trajectory.len < p + 1) continue;
            const head = trajectory[trajectory.len - 1];
            const tail = trajectory[trajectory.len - 1 - p];
            if (std.mem.eql(u8, head, tail) and std.mem.eql(u8, head, active_tool)) {
                const cycle = trajectory[trajectory.len - 1 - p .. trajectory.len - 1];
                if (!isCycleNodesDistinct(cycle) or hasMutationNode(cycle)) continue;

                return OrbitInfo{
                    .period = p,
                    .revolutions = 1,
                    .orbit_nodes = cycle,
                };
            }
        }
        return null;
    }

    /// Detects whether the trajectory exhibits signs of orbiting in 3D procedural space.
    /// An orbit is a repeating closed cycle of length P in [2, 5] with zero code mutation (ΔZ = 0).
    pub fn detectTrajectoryOrbit(trajectory: []const []const u8, current_tool: ?[]const u8) ?OrbitInfo {
        // PSEUDOCODE:
        // 1. Guard against short trajectory (< 2).
        // 2. Check for multi-revolution periodic repeating patterns.
        // 3. Check for first closure of orbit with zero mutation.
        if (trajectory.len < 2) return null;
        if (checkMultiRevolutionOrbit(trajectory)) |info| return info;
        const active_tool = current_tool orelse trajectory[trajectory.len - 1];
        return checkFirstClosureOrbit(trajectory, active_tool);
    }

    fn isObservationalOrGeneric(name: []const u8) bool {
        return std.mem.eql(u8, name, "bash") or
            std.mem.eql(u8, name, "file_read") or
            std.mem.eql(u8, name, "session_diagnostics");
    }

    /// Extract h-hop neighborhood subgraph guidance formatted as markdown (RFC-010 PG-3).
    /// If an orbit is detected in 3D procedural space, produces a
    /// Checkpoint & Recap block instead of cyclic forward step suggestions.
    /// `user_request` is the original task prompt — injected to keep the model anchored
    /// to its goal rather than drifting into generic exploration.
    fn formatOrbitCheckpoint(
        self: *PGraphStore,
        alloc: Allocator,
        act_str: []const u8,
        orbit: OrbitInfo,
        user_request: ?[]const u8,
    ) ![]u8 {
        var bw = utils.BufWriter.init(alloc);
        errdefer bw.deinit();

        try bw.writeAll("[Procedural 3D Map Checkpoint & Trajectory Recap]\n");
        try bw.print("📍 Waypoint: 3D Trajectory Orbit Detected (circling pattern: ", .{});
        for (orbit.orbit_nodes) |on| {
            try bw.print("`{s}` → ", .{on});
        }
        try bw.print("`{s}`, period={d}, revolutions={d})\n\n", .{ act_str, orbit.period, orbit.revolutions });

        try bw.writeAll("🗺️ Explored Territory Recap:\n");
        for (orbit.orbit_nodes) |on| {
            const dom = ToolDomain3D.fromToolName(on);
            const desc = if (self.matchNode(on)) |nid| self.graph.nodes.items[nid].desc else "";
            try bw.print("- `{s}` [{s}]: {s}\n", .{ on, dom.label(), desc });
        }

        try bw.writeAll("\n⚠️ Navigation Checkpoint (ΔZ = 0, zero code mutation in orbit):\n");
        try bw.print("You have scouted this region of the procedural map. All immediate forward paths from `{s}` have already been explored in this trajectory.\n\n", .{act_str});

        try bw.writeAll("\n⚡ Orbit Break Directive:\n");
        try bw.writeAll(prompts_mod.pg_orbit_break_directive);

        if (user_request) |req| {
            const trunc = if (req.len > 180) req[0..180] ++ "..." else req;
            try bw.print("🎯 Your task: \"{s}\"\n\n", .{trunc});
        }

        try bw.writeAll(prompts_mod.pg_orbit_must_list);

        return try bw.toOwnedSlice();
    }

    fn isEdgeSuppressed(self: *PGraphStore, edge: EdgeRecord, start_node_id: usize, recent_actions: []const []const u8) bool {
        if (!edge.is_active or edge.src == edge.dst) return true;
        for (recent_actions) |ra| {
            if (self.matchNode(ra)) |ra_id| {
                if (ra_id == edge.dst or (edge.src != start_node_id and ra_id == edge.src)) return true;
            }
        }
        return false;
    }

    fn formatSuggestedEdge(self: *PGraphStore, bw: *utils.BufWriter, edge: EdgeRecord) !void {
        const src_name = self.graph.nodes.items[edge.src].name;
        const dst_name = self.graph.nodes.items[edge.dst].name;
        try bw.print("- `{s}` → `{s}` ({s})\n", .{ src_name, dst_name, edge.rel.toString() });
        if (edge.attr.condition) |cond| {
            if (cond.len > 0) try bw.print("  - Condition: {s}\n", .{cond});
        }
        if (edge.attr.guidance) |guid| {
            if (guid.len > 0) try bw.print("  - Suggestion: {s}\n", .{guid});
        }
        if (edge.attr.pitfalls) |pit| {
            if (pit.len > 0) try bw.print("  - Pitfalls: {s}\n", .{pit});
        }
    }

    fn formatNeighborhoodAdvisory(
        self: *PGraphStore,
        alloc: Allocator,
        start_node_id: usize,
        neighborhood: NeighborhoodResult,
        recent_actions: []const []const u8,
        last_failed: bool,
        user_request: ?[]const u8,
        max_hops: u32,
    ) !?[]u8 {
        var bw = utils.BufWriter.init(alloc);
        errdefer bw.deinit();

        try bw.writeAll("[Procedural Advisory (Optional Suggestions)]\n");
        if (last_failed) {
            try bw.writeAll("Notice: Previous action reported a non-zero exit code or failure. Consider these heuristic suggestions if helpful (you are NOT required to follow them):\n");
        }
        const current_node_name = self.graph.nodes.items[start_node_id].name;
        try bw.print("Current Action: `{s}`\nObserved Pattern Suggestions (h={d}-hop neighborhood):\n", .{ current_node_name, max_hops });

        var printed_edges: usize = 0;
        for (neighborhood.edges) |eid| {
            if (eid >= self.graph.edges.items.len) continue;
            const edge = self.graph.edges.items[eid];
            if (self.isEdgeSuppressed(edge, start_node_id, recent_actions)) continue;
            try self.formatSuggestedEdge(&bw, edge);
            printed_edges += 1;
        }

        if (printed_edges == 0) {
            if (!last_failed) {
                bw.deinit();
                return null;
            }
            try bw.writeAll(prompts_mod.pg_no_recovery_note);
            return try bw.toOwnedSlice();
        }

        try bw.writeAll(prompts_mod.advisory_note_strong ++ "\n");
        if (user_request) |req| {
            const trunc = if (req.len > 200) req[0..200] ++ "..." else req;
            try bw.print(prompts_mod.pg_task_reminder_fmt, .{trunc});
        }
        return try bw.toOwnedSlice();
    }

    /// Extract h-hop neighborhood subgraph guidance formatted as markdown (RFC-010 PG-3).
    /// If an orbit is detected in 3D procedural space, produces a
    /// Checkpoint & Recap block instead of cyclic forward step suggestions.
    /// `user_request` is the original task prompt — injected to keep the model anchored
    /// to its goal rather than drifting into generic exploration.
    pub fn serializeGuidance(
        self: *PGraphStore,
        alloc: Allocator,
        last_action: ?[]const u8,
        recent_actions: []const []const u8,
        last_failed: bool,
        max_hops: u32,
        user_request: ?[]const u8,
    ) !?[]u8 {
        const act_str = last_action orelse return null;
        const start_node_id = self.matchNode(act_str) orelse return null;

        if (detectTrajectoryOrbit(recent_actions, act_str)) |orbit| {
            return try self.formatOrbitCheckpoint(alloc, act_str, orbit, user_request);
        }

        const out_edges = if (start_node_id < self.graph.out_adj.items.len) self.graph.out_adj.items[start_node_id].items else &.{};
        var active_out_count: usize = 0;
        for (out_edges) |eid| {
            if (eid < self.graph.edges.items.len and self.graph.edges.items[eid].is_active) {
                active_out_count += 1;
            }
        }
        if (active_out_count == 0 and !last_failed) return null;

        var neighborhood = try traverseNeighborhood(&self.graph, start_node_id, max_hops, alloc);
        defer neighborhood.deinit(alloc);

        return try self.formatNeighborhoodAdvisory(alloc, start_node_id, neighborhood, recent_actions, last_failed, user_request, max_hops);
    }

    fn hasActiveEdge(graph: *const Graph, src_id: usize, dst_id: usize) bool {
        // PSEUDOCODE: Check if active directed edge exists between src_id and dst_id.
        const edges = if (src_id < graph.out_adj.items.len) graph.out_adj.items[src_id].items else &.{};
        for (edges) |eid| {
            if (eid < graph.edges.items.len) {
                const edge = graph.edges.items[eid];
                if (edge.is_active and edge.dst == dst_id) return true;
            }
        }
        return false;
    }

    fn promoteCandidateEdge(self: *PGraphStore, io: std.Io, src_name: []const u8, dst_name: []const u8) !void {
        // PSEUDOCODE: Generate edge ID and append add_edge event to JSONL, then repair cycles.
        const eid = try self.nextId("pge");
        defer self.alloc.free(eid);

        const line = try std.fmt.allocPrint(self.alloc,
            \\{{"ev":"add_edge","id":"{s}","edge":{{"src":"{s}","rel":"LEADS_TO","dst":"{s}","guidance":"Observed frequent transition (frequency >= 3)","condition":"frequent workflow pattern"}}}}
        , .{ eid, src_name, dst_name });
        defer self.alloc.free(line);

        try self.appendEvent(io, line);
        _ = repairCycles(&self.graph, self.alloc) catch 0;
    }

    /// Record a transition between two tool actions (RFC-010 PG-2 population frequency gate).
    /// If transition frequency reaches threshold N=3, automatically persists candidate edge.
    pub fn recordTransition(self: *PGraphStore, io: std.Io, src_action: []const u8, dst_action: []const u8) !void {
        // PSEUDOCODE:
        // 1. Guard against self-transitions or generic tool pairs.
        // 2. Validate nodes exist and no active or reverse edges exist.
        // 3. Increment transition counter and promote if threshold N=3 reached.
        if (!self.auto_populate or std.mem.eql(u8, src_action, dst_action)) return;

        const src_id = self.matchNode(src_action) orelse return;
        const dst_id = self.matchNode(dst_action) orelse return;
        const src_name = self.graph.nodes.items[src_id].name;
        const dst_name = self.graph.nodes.items[dst_id].name;

        if (isObservationalOrGeneric(src_name) and isObservationalOrGeneric(dst_name)) return;
        if (hasActiveEdge(&self.graph, src_id, dst_id)) return;
        if (hasActiveEdge(&self.graph, dst_id, src_id)) return;
        if (isReachable(&self.graph, dst_id, src_id, self.alloc)) return;

        const key = try std.fmt.allocPrint(self.alloc, "{s}->{s}", .{ src_name, dst_name });
        defer self.alloc.free(key);

        if (self.transitions.getPtr(key)) |count_ptr| {
            count_ptr.* += 1;
            if (count_ptr.* >= 3) {
                try self.promoteCandidateEdge(io, src_name, dst_name);
            }
        } else {
            const owned_key = try self.alloc.dupe(u8, key);
            try self.transitions.put(owned_key, 1);
        }
    }
};
