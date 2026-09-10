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
const traverseNeighborhood = graph_mod.traverseNeighborhood;
const repairCycles = graph_mod.repairCycles;
const checkTerminalReachability = graph_mod.checkTerminalReachability;
const applyEventJson = graph_mod.applyEventJson;
const utils = @import("../utils.zig");

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
            std.os.linux.getpid(),
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

    /// Pre-seed foundational tool nodes and common developer workflow transitions.
    pub fn seedDefaults(self: *PGraphStore, io: std.Io) !void {
        // Core tools in mini-agent registry
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

        // Standard procedural transitions
        const default_edges = [_]struct {
            src: []const u8,
            rel: []const u8,
            dst: []const u8,
            cond: []const u8,
            guid: []const u8,
            pitfalls: []const u8,
        }{
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

    /// Extract h-hop neighborhood subgraph guidance formatted as markdown (RFC-010 PG-3).
    /// Returns null if no active transitions or if selective policy decides no guidance is needed.
    pub fn serializeGuidance(
        self: *PGraphStore,
        alloc: Allocator,
        last_action: ?[]const u8,
        recent_actions: []const []const u8,
        last_failed: bool,
        max_hops: u32,
    ) !?[]u8 {
        _ = recent_actions;
        const act_str = last_action orelse return null;
        const start_node_id = self.matchNode(act_str) orelse return null;

        // Selective guidance policy: check if node has active outgoing edges or previous act failed
        const out_edges = if (start_node_id < self.graph.out_adj.items.len) self.graph.out_adj.items[start_node_id].items else &.{};
        var active_out_count: usize = 0;
        for (out_edges) |eid| {
            if (eid < self.graph.edges.items.len and self.graph.edges.items[eid].is_active) {
                active_out_count += 1;
            }
        }

        if (active_out_count == 0 and !last_failed) {
            return null;
        }

        var neighborhood = try traverseNeighborhood(&self.graph, start_node_id, max_hops, alloc);
        defer neighborhood.deinit(alloc);

        const current_node_name = self.graph.nodes.items[start_node_id].name;

        var bw = utils.BufWriter.init(alloc);
        errdefer bw.deinit();

        try bw.writeAll("[Procedural Graph Guidance]\n");
        if (last_failed) {
            try bw.writeAll("⚠️ Previous action reported an error or non-zero exit code. Adhere to error recovery guidance:\n");
        }
        try bw.print("Current Action: `{s}`\nAdmissible Next Steps (h={d}-hop neighborhood):\n", .{ current_node_name, max_hops });

        var printed_edges: usize = 0;
        for (neighborhood.edges) |eid| {
            if (eid >= self.graph.edges.items.len) continue;
            const edge = self.graph.edges.items[eid];
            if (!edge.is_active) continue;

            const src_name = self.graph.nodes.items[edge.src].name;
            const dst_name = self.graph.nodes.items[edge.dst].name;
            const rel_str = edge.rel.toString();

            try bw.print("- `{s}` → `{s}` ({s})\n", .{ src_name, dst_name, rel_str });
            if (edge.attr.condition) |cond| {
                if (cond.len > 0) try bw.print("  - Condition: {s}\n", .{cond});
            }
            if (edge.attr.guidance) |guid| {
                if (guid.len > 0) try bw.print("  - Guidance: {s}\n", .{guid});
            }
            if (edge.attr.pitfalls) |pit| {
                if (pit.len > 0) try bw.print("  - Pitfalls: {s}\n", .{pit});
            }
            printed_edges += 1;
        }

        if (printed_edges == 0 and !last_failed) {
            bw.deinit();
            return null;
        }

        const slice = try bw.toOwnedSlice();
        return slice;
    }

    /// Record a transition between two tool actions (RFC-010 PG-2 population frequency gate).
    /// If transition frequency reaches threshold N=3, automatically persists candidate edge.
    pub fn recordTransition(self: *PGraphStore, io: std.Io, src_action: []const u8, dst_action: []const u8) !void {
        if (!self.auto_populate or std.mem.eql(u8, src_action, dst_action)) return;

        const src_id = self.matchNode(src_action) orelse return;
        const dst_id = self.matchNode(dst_action) orelse return;

        const src_name = self.graph.nodes.items[src_id].name;
        const dst_name = self.graph.nodes.items[dst_id].name;

        // If edge already exists and is active, no need to learn
        const out_edges = if (src_id < self.graph.out_adj.items.len) self.graph.out_adj.items[src_id].items else &.{};
        for (out_edges) |eid| {
            if (eid < self.graph.edges.items.len) {
                const edge = self.graph.edges.items[eid];
                if (edge.is_active and edge.dst == dst_id) return;
            }
        }

        const key = try std.fmt.allocPrint(self.alloc, "{s}->{s}", .{ src_name, dst_name });
        defer self.alloc.free(key);

        if (self.transitions.getPtr(key)) |count_ptr| {
            count_ptr.* += 1;
            if (count_ptr.* >= 3) {
                // Threshold reached: promote candidate edge to JSONL
                const eid = try self.nextId("pge");
                defer self.alloc.free(eid);

                const line = try std.fmt.allocPrint(self.alloc,
                    \\{{"ev":"add_edge","id":"{s}","edge":{{"src":"{s}","rel":"LEADS_TO","dst":"{s}","guidance":"Observed frequent transition (frequency >= 3)","condition":"frequent workflow pattern"}}}}
                , .{ eid, src_name, dst_name });
                defer self.alloc.free(line);

                try self.appendEvent(io, line);
            }
        } else {
            const owned_key = try self.alloc.dupe(u8, key);
            try self.transitions.put(owned_key, 1);
        }
    }
};
