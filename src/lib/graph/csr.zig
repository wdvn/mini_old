//! lib/graph/csr.zig — Compressed Sparse Row (CSR) & Column (CSC) Representation.
//!
//! Provides cache-friendly, zero-pointer-chasing flat memory layout for
//! rapid multi-hop traversal and analytical graph checks on 100k+ nodes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const NodeId = types.NodeId;
const EdgeId = types.EdgeId;
const NodeRecord = types.NodeRecord;
const EdgeRecord = types.EdgeRecord;

pub const CsrGraph = struct {
    alloc: Allocator,
    node_count: u32,
    edge_count: u32,

    /// Outgoing edges CSR
    row_offsets: []u32,
    col_indices: []u32,
    edge_ids: []EdgeId,

    /// Incoming edges CSC (for reverse traversal / terminal reachability)
    rev_offsets: []u32,
    rev_indices: []u32,
    rev_edge_ids: []EdgeId,

    pub fn build(alloc: Allocator, nodes: []const NodeRecord, edges: []const EdgeRecord) !CsrGraph {
        const n: u32 = @intCast(nodes.len);
        var active_e: u32 = 0;
        for (edges) |e| {
            if (e.is_active and nodes[e.src].is_active and nodes[e.dst].is_active) {
                active_e += 1;
            }
        }

        // 1. Calculate degrees
        const out_degree = try alloc.alloc(u32, n);
        defer alloc.free(out_degree);
        @memset(out_degree, 0);

        const in_degree = try alloc.alloc(u32, n);
        defer alloc.free(in_degree);
        @memset(in_degree, 0);

        for (edges) |e| {
            if (e.is_active and nodes[e.src].is_active and nodes[e.dst].is_active) {
                out_degree[e.src] += 1;
                in_degree[e.dst] += 1;
            }
        }

        // 2. Allocate CSR/CSC slices
        const row_offsets = try alloc.alloc(u32, n + 1);
        errdefer alloc.free(row_offsets);

        const col_indices = try alloc.alloc(u32, active_e);
        errdefer alloc.free(col_indices);

        const edge_ids = try alloc.alloc(EdgeId, active_e);
        errdefer alloc.free(edge_ids);

        const rev_offsets = try alloc.alloc(u32, n + 1);
        errdefer alloc.free(rev_offsets);

        const rev_indices = try alloc.alloc(u32, active_e);
        errdefer alloc.free(rev_indices);

        const rev_edge_ids = try alloc.alloc(EdgeId, active_e);
        errdefer alloc.free(rev_edge_ids);

        // 3. Prefix sum for offsets
        row_offsets[0] = 0;
        rev_offsets[0] = 0;
        for (0..n) |i| {
            row_offsets[i + 1] = row_offsets[i] + out_degree[i];
            rev_offsets[i + 1] = rev_offsets[i] + in_degree[i];
        }

        // 4. Fill edges
        const current_out = try alloc.alloc(u32, n);
        defer alloc.free(current_out);
        @memcpy(current_out, row_offsets[0..n]);

        const current_in = try alloc.alloc(u32, n);
        defer alloc.free(current_in);
        @memcpy(current_in, rev_offsets[0..n]);

        for (edges) |e| {
            if (e.is_active and nodes[e.src].is_active and nodes[e.dst].is_active) {
                const out_idx = current_out[e.src];
                col_indices[out_idx] = e.dst;
                edge_ids[out_idx] = e.id;
                current_out[e.src] += 1;

                const in_idx = current_in[e.dst];
                rev_indices[in_idx] = e.src;
                rev_edge_ids[in_idx] = e.id;
                current_in[e.dst] += 1;
            }
        }

        return .{
            .alloc = alloc,
            .node_count = n,
            .edge_count = active_e,
            .row_offsets = row_offsets,
            .col_indices = col_indices,
            .edge_ids = edge_ids,
            .rev_offsets = rev_offsets,
            .rev_indices = rev_indices,
            .rev_edge_ids = rev_edge_ids,
        };
    }

    pub fn deinit(self: *CsrGraph) void {
        self.alloc.free(self.row_offsets);
        self.alloc.free(self.col_indices);
        self.alloc.free(self.edge_ids);
        self.alloc.free(self.rev_offsets);
        self.alloc.free(self.rev_indices);
        self.alloc.free(self.rev_edge_ids);
        self.* = undefined;
    }

    pub fn outNeighbors(self: *const CsrGraph, u: NodeId) []const u32 {
        if (u >= self.node_count) return &.{};
        const start = self.row_offsets[u];
        const end = self.row_offsets[u + 1];
        return self.col_indices[start..end];
    }

    pub fn outEdges(self: *const CsrGraph, u: NodeId) []const EdgeId {
        if (u >= self.node_count) return &.{};
        const start = self.row_offsets[u];
        const end = self.row_offsets[u + 1];
        return self.edge_ids[start..end];
    }

    pub fn inNeighbors(self: *const CsrGraph, u: NodeId) []const u32 {
        if (u >= self.node_count) return &.{};
        const start = self.rev_offsets[u];
        const end = self.rev_offsets[u + 1];
        return self.rev_indices[start..end];
    }

    pub fn inEdges(self: *const CsrGraph, u: NodeId) []const EdgeId {
        if (u >= self.node_count) return &.{};
        const start = self.rev_offsets[u];
        const end = self.rev_offsets[u + 1];
        return self.rev_edge_ids[start..end];
    }

    pub fn outDegree(self: *const CsrGraph, u: NodeId) u32 {
        if (u >= self.node_count) return 0;
        return self.row_offsets[u + 1] - self.row_offsets[u];
    }

    pub fn inDegree(self: *const CsrGraph, u: NodeId) u32 {
        if (u >= self.node_count) return 0;
        return self.rev_offsets[u + 1] - self.rev_offsets[u];
    }
};
