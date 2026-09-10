//! lib/graph/storage.zig — Mutable Property Graph Storage.
//!
//! Provides dynamic node/edge insertion, O(1) attribute superseding (RFC-010),
//! String-to-NodeId interning, and conversion to CSR/CSC views.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const csr_mod = @import("csr.zig");

pub const NodeId = types.NodeId;
pub const EdgeId = types.EdgeId;
pub const RelationType = types.RelationType;
pub const NodeType = types.NodeType;
pub const EdgeAttributes = types.EdgeAttributes;
pub const NodeRecord = types.NodeRecord;
pub const EdgeRecord = types.EdgeRecord;
pub const CsrGraph = csr_mod.CsrGraph;

pub const Graph = struct {
    alloc: Allocator,
    arena: std.heap.ArenaAllocator,

    nodes: std.ArrayListUnmanaged(NodeRecord) = .empty,
    edges: std.ArrayListUnmanaged(EdgeRecord) = .empty,

    name_to_node: std.StringHashMapUnmanaged(NodeId) = .empty,
    str_id_to_edge: std.StringHashMapUnmanaged(EdgeId) = .empty,

    out_adj: std.ArrayListUnmanaged(std.ArrayListUnmanaged(EdgeId)) = .empty,
    in_adj: std.ArrayListUnmanaged(std.ArrayListUnmanaged(EdgeId)) = .empty,

    active_node_count: usize = 0,
    active_edge_count: usize = 0,

    pub fn init(alloc: Allocator) Graph {
        return .{
            .alloc = alloc,
            .arena = std.heap.ArenaAllocator.init(alloc),
        };
    }

    pub fn deinit(self: *Graph) void {
        for (self.out_adj.items) |*list| list.deinit(self.alloc);
        self.out_adj.deinit(self.alloc);

        for (self.in_adj.items) |*list| list.deinit(self.alloc);
        self.in_adj.deinit(self.alloc);

        self.nodes.deinit(self.alloc);
        self.edges.deinit(self.alloc);
        self.name_to_node.deinit(self.alloc);
        self.str_id_to_edge.deinit(self.alloc);

        self.arena.deinit();
        self.* = undefined;
    }

    /// Add a node to the graph. If already exists by name, returns existing ID.
    pub fn addNode(self: *Graph, name: []const u8, node_type: NodeType, desc: []const u8) !NodeId {
        if (self.name_to_node.get(name)) |existing| {
            // If exists and was inactive, reactivate
            if (!self.nodes.items[existing].is_active) {
                self.nodes.items[existing].is_active = true;
                self.active_node_count += 1;
            }
            return existing;
        }

        const arena_alloc = self.arena.allocator();
        const id: NodeId = @intCast(self.nodes.items.len);

        const dup_name = try arena_alloc.dupe(u8, name);
        const dup_desc = if (desc.len > 0) try arena_alloc.dupe(u8, desc) else "";

        try self.nodes.append(self.alloc, .{
            .id = id,
            .name = dup_name,
            .node_type = node_type,
            .desc = dup_desc,
            .is_active = true,
        });

        try self.out_adj.append(self.alloc, .empty);
        try self.in_adj.append(self.alloc, .empty);

        try self.name_to_node.put(self.alloc, dup_name, id);
        self.active_node_count += 1;
        return id;
    }

    /// Get existing node ID by name, or add it if not found.
    pub fn getOrAddNode(self: *Graph, name: []const u8, node_type: NodeType, desc: []const u8) !NodeId {
        return self.addNode(name, node_type, desc);
    }

    /// Find node ID by exact name.
    pub fn findNodeByName(self: *const Graph, name: []const u8) ?NodeId {
        return self.name_to_node.get(name);
    }

    /// Get node record by ID.
    pub fn getNode(self: *const Graph, id: NodeId) ?*const NodeRecord {
        if (id >= self.nodes.items.len) return null;
        const n = &self.nodes.items[id];
        if (!n.is_active) return null;
        return n;
    }

    /// Add an edge between src and dst.
    pub fn addEdge(
        self: *Graph,
        src: NodeId,
        dst: NodeId,
        rel: RelationType,
        attr: EdgeAttributes,
        str_id: ?[]const u8,
    ) !EdgeId {
        if (src >= self.nodes.items.len or dst >= self.nodes.items.len) {
            return error.NodeNotFound;
        }

        const arena_alloc = self.arena.allocator();
        const edge_id: EdgeId = @intCast(self.edges.items.len);

        const dup_str_id = if (str_id) |sid| try arena_alloc.dupe(u8, sid) else null;
        const dup_cond = if (attr.condition) |c| try arena_alloc.dupe(u8, c) else null;
        const dup_guidance = if (attr.guidance) |g| try arena_alloc.dupe(u8, g) else null;
        const dup_pitfalls = if (attr.pitfalls) |p| try arena_alloc.dupe(u8, p) else null;
        const dup_supersedes = if (attr.supersedes) |s| try arena_alloc.dupe(u8, s) else null;

        // If this edge supersedes a prior edge, mark old edge inactive
        if (dup_supersedes) |old_sid| {
            if (self.str_id_to_edge.get(old_sid)) |old_eid| {
                if (self.edges.items[old_eid].is_active) {
                    self.edges.items[old_eid].is_active = false;
                    if (self.active_edge_count > 0) self.active_edge_count -= 1;
                }
            }
        }

        try self.edges.append(self.alloc, .{
            .id = edge_id,
            .str_id = dup_str_id,
            .src = src,
            .dst = dst,
            .rel = rel,
            .attr = .{
                .condition = dup_cond,
                .guidance = dup_guidance,
                .pitfalls = dup_pitfalls,
                .weight = attr.weight,
                .supersedes = dup_supersedes,
            },
            .is_active = true,
        });

        try self.out_adj.items[src].append(self.alloc, edge_id);
        try self.in_adj.items[dst].append(self.alloc, edge_id);

        if (dup_str_id) |sid| {
            try self.str_id_to_edge.put(self.alloc, sid, edge_id);
        }

        self.active_edge_count += 1;
        return edge_id;
    }

    /// Supersede an existing edge by its string ID.
    pub fn supersedeEdge(
        self: *Graph,
        old_str_id: []const u8,
        src: NodeId,
        dst: NodeId,
        rel: RelationType,
        mut_attr: EdgeAttributes,
        new_str_id: []const u8,
    ) !EdgeId {
        var attr = mut_attr;
        attr.supersedes = old_str_id;
        return self.addEdge(src, dst, rel, attr, new_str_id);
    }

    /// Mark an edge inactive by EdgeId.
    pub fn deleteEdge(self: *Graph, edge_id: EdgeId) void {
        if (edge_id < self.edges.items.len) {
            if (self.edges.items[edge_id].is_active) {
                self.edges.items[edge_id].is_active = false;
                if (self.active_edge_count > 0) self.active_edge_count -= 1;
            }
        }
    }

    /// Mark an edge inactive by string ID (RFC-010 `delete_edge`).
    pub fn deleteEdgeByStrId(self: *Graph, str_id: []const u8) bool {
        if (self.str_id_to_edge.get(str_id)) |eid| {
            self.deleteEdge(eid);
            return true;
        }
        return false;
    }

    /// Compile this graph into a cache-optimized, contiguous CSR/CSC representation.
    pub fn toCsr(self: *const Graph, alloc: Allocator) !CsrGraph {
        return CsrGraph.build(alloc, self.nodes.items, self.edges.items);
    }
};
