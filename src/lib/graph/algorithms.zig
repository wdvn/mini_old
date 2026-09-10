//! lib/graph/algorithms.zig — Graph Algorithms for mini-agent.
//!
//! High-performance implementations of:
//! - h-hop neighborhood subgraph extraction (BFS with dynamic bitset)
//! - 3-color cycle detection and automated cycle repair (for RFC-010 validator)
//! - Terminal reachability verification (reverse BFS from out-degree = 0 nodes)
//! - Shortest path finding

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const NodeId = types.NodeId;
const EdgeId = types.EdgeId;
const INVALID_NODE = types.INVALID_NODE;
const storage = @import("storage.zig");
const Graph = storage.Graph;
const csr_mod = @import("csr.zig");
const CsrGraph = csr_mod.CsrGraph;

// ---------------------------------------------------------------------------
// 1. h-hop Neighborhood Subgraph Traversal
// ---------------------------------------------------------------------------

pub const NodeWithHop = struct {
    id: NodeId,
    hop: u32,
};

pub const NeighborhoodResult = struct {
    nodes: []NodeWithHop,
    edges: []EdgeId,

    pub fn deinit(self: *NeighborhoodResult, alloc: Allocator) void {
        alloc.free(self.nodes);
        alloc.free(self.edges);
        self.* = undefined;
    }
};

/// Extract h-hop neighborhood subgraph starting from `start_node`.
/// Optimized using dynamic bitset for visited check in O(1) time.
pub fn traverseNeighborhood(
    graph: *const Graph,
    start_node: NodeId,
    max_hops: u32,
    alloc: Allocator,
) !NeighborhoodResult {
    const csr = try graph.toCsr(alloc);
    var csr_mut = csr;
    defer csr_mut.deinit();

    return traverseNeighborhoodCsr(&csr_mut, start_node, max_hops, alloc);
}

/// Fast h-hop neighborhood extraction directly on CSR representation.
pub fn traverseNeighborhoodCsr(
    csr: *const CsrGraph,
    start_node: NodeId,
    max_hops: u32,
    alloc: Allocator,
) !NeighborhoodResult {
    if (start_node >= csr.node_count) {
        return .{
            .nodes = try alloc.alloc(NodeWithHop, 0),
            .edges = try alloc.alloc(EdgeId, 0),
        };
    }

    var visited = try std.DynamicBitSetUnmanaged.initEmpty(alloc, csr.node_count);
    defer visited.deinit(alloc);

    var collected_nodes: std.ArrayListUnmanaged(NodeWithHop) = .empty;
    defer collected_nodes.deinit(alloc);

    var collected_edges: std.ArrayListUnmanaged(EdgeId) = .empty;
    defer collected_edges.deinit(alloc);

    // BFS Queue
    const QueueItem = struct { id: NodeId, hop: u32 };
    var queue: std.ArrayListUnmanaged(QueueItem) = .empty;
    defer queue.deinit(alloc);

    visited.set(start_node);
    try queue.append(alloc, .{ .id = start_node, .hop = 0 });
    try collected_nodes.append(alloc, .{ .id = start_node, .hop = 0 });

    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const curr = queue.items[head];
        if (curr.hop >= max_hops) continue;

        const nbrs = csr.outNeighbors(curr.id);
        const eids = csr.outEdges(curr.id);

        for (nbrs, eids) |nbr, eid| {
            try collected_edges.append(alloc, eid);

            if (!visited.isSet(nbr)) {
                visited.set(nbr);
                const next_hop = curr.hop + 1;
                try collected_nodes.append(alloc, .{ .id = nbr, .hop = next_hop });
                try queue.append(alloc, .{ .id = nbr, .hop = next_hop });
            }
        }
    }

    return .{
        .nodes = try collected_nodes.toOwnedSlice(alloc),
        .edges = try collected_edges.toOwnedSlice(alloc),
    };
}

// ---------------------------------------------------------------------------
// 2. Cycle Detection & Repair
// ---------------------------------------------------------------------------

pub const CycleResult = struct {
    has_cycle: bool,
    closing_edges: []EdgeId,

    pub fn deinit(self: *CycleResult, alloc: Allocator) void {
        alloc.free(self.closing_edges);
        self.* = undefined;
    }
};

/// 3-color DFS to detect cycles and identify cycle-closing edges.
/// 0: White (unvisited), 1: Gray (currently on recursion stack), 2: Black (finished).
pub fn detectCycles(graph: *const Graph, alloc: Allocator) !CycleResult {
    const csr = try graph.toCsr(alloc);
    var csr_mut = csr;
    defer csr_mut.deinit();

    return detectCyclesCsr(&csr_mut, alloc);
}

pub fn detectCyclesCsr(csr: *const CsrGraph, alloc: Allocator) !CycleResult {
    const n = csr.node_count;
    const colors = try alloc.alloc(u8, n);
    defer alloc.free(colors);
    @memset(colors, 0);

    var closing_edges: std.ArrayListUnmanaged(EdgeId) = .empty;
    defer closing_edges.deinit(alloc);

    // Iterative stack for DFS. For 100k nodes, we use an explicit stack to prevent stack overflow.
    const StackFrame = struct {
        node: NodeId,
        edge_idx: usize,
        edge_count: usize,
    };

    var stack: std.ArrayListUnmanaged(StackFrame) = .empty;
    defer stack.deinit(alloc);

    for (0..n) |root| {
        if (colors[root] != 0) continue;

        const root_node: NodeId = @intCast(root);
        colors[root_node] = 1; // Gray

        const root_out = csr.outNeighbors(root_node).len;
        try stack.append(alloc, .{
            .node = root_node,
            .edge_idx = 0,
            .edge_count = root_out,
        });

        while (stack.items.len > 0) {
            var top = &stack.items[stack.items.len - 1];
            const curr_node = top.node;

            if (top.edge_idx < top.edge_count) {
                const nbrs = csr.outNeighbors(curr_node);
                const eids = csr.outEdges(curr_node);
                const nbr = nbrs[top.edge_idx];
                const eid = eids[top.edge_idx];
                top.edge_idx += 1;

                if (colors[nbr] == 1) {
                    // Back-edge detected! Closing a cycle.
                    try closing_edges.append(alloc, eid);
                } else if (colors[nbr] == 0) {
                    // Unvisited tree edge: recurse
                    colors[nbr] = 1; // Gray
                    try stack.append(alloc, .{
                        .node = nbr,
                        .edge_idx = 0,
                        .edge_count = csr.outNeighbors(nbr).len,
                    });
                }
            } else {
                // Finished all outgoing edges: color Black and pop
                colors[curr_node] = 2;
                _ = stack.pop();
            }
        }
    }

    const has_cycle = (closing_edges.items.len > 0);
    return .{
        .has_cycle = has_cycle,
        .closing_edges = try closing_edges.toOwnedSlice(alloc),
    };
}

/// Repair cycles by marking cycle-closing edges as inactive.
pub fn repairCycles(graph: *Graph, alloc: Allocator) !usize {
    var res = try detectCycles(graph, alloc);
    defer res.deinit(alloc);

    for (res.closing_edges) |eid| {
        graph.deleteEdge(eid);
    }
    return res.closing_edges.len;
}

// ---------------------------------------------------------------------------
// 3. Terminal Reachability
// ---------------------------------------------------------------------------

pub const ReachabilityResult = struct {
    all_reachable: bool,
    terminal_count: usize,
    unreachable_nodes: []NodeId,

    pub fn deinit(self: *ReachabilityResult, alloc: Allocator) void {
        alloc.free(self.unreachable_nodes);
        self.* = undefined;
    }
};

/// Check terminal reachability: every active node must have a path to at least one terminal node (out-degree = 0).
pub fn checkTerminalReachability(graph: *const Graph, alloc: Allocator) !ReachabilityResult {
    const csr = try graph.toCsr(alloc);
    var csr_mut = csr;
    defer csr_mut.deinit();

    return checkTerminalReachabilityCsr(&csr_mut, alloc);
}

pub fn checkTerminalReachabilityCsr(csr: *const CsrGraph, alloc: Allocator) !ReachabilityResult {
    const n = csr.node_count;
    if (n == 0) {
        return .{
            .all_reachable = true,
            .terminal_count = 0,
            .unreachable_nodes = try alloc.alloc(NodeId, 0),
        };
    }

    var can_reach_terminal = try std.DynamicBitSetUnmanaged.initEmpty(alloc, n);
    defer can_reach_terminal.deinit(alloc);

    var queue: std.ArrayListUnmanaged(NodeId) = .empty;
    defer queue.deinit(alloc);

    var terminal_count: usize = 0;

    // 1. Find all terminal nodes (out-degree == 0)
    for (0..n) |i| {
        const u: NodeId = @intCast(i);
        if (csr.outDegree(u) == 0) {
            terminal_count += 1;
            can_reach_terminal.set(u);
            try queue.append(alloc, u);
        }
    }

    // 2. Reverse BFS from terminal nodes using incoming edges
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const curr = queue.items[head];
        const in_nbrs = csr.inNeighbors(curr);
        for (in_nbrs) |pred| {
            if (!can_reach_terminal.isSet(pred)) {
                can_reach_terminal.set(pred);
                try queue.append(alloc, pred);
            }
        }
    }

    // 3. Find any nodes that cannot reach a terminal
    var unreachable_list: std.ArrayListUnmanaged(NodeId) = .empty;
    defer unreachable_list.deinit(alloc);

    for (0..n) |i| {
        const u: NodeId = @intCast(i);
        if (!can_reach_terminal.isSet(u)) {
            try unreachable_list.append(alloc, u);
        }
    }

    return .{
        .all_reachable = (unreachable_list.items.len == 0),
        .terminal_count = terminal_count,
        .unreachable_nodes = try unreachable_list.toOwnedSlice(alloc),
    };
}

// ---------------------------------------------------------------------------
// 4. Shortest Path Search
// ---------------------------------------------------------------------------

/// Find shortest path between start and goal using BFS.
pub fn findShortestPath(
    graph: *const Graph,
    start: NodeId,
    goal: NodeId,
    alloc: Allocator,
) !?[]NodeId {
    if (start == goal) {
        const path = try alloc.alloc(NodeId, 1);
        path[0] = start;
        return path;
    }

    const csr = try graph.toCsr(alloc);
    var csr_mut = csr;
    defer csr_mut.deinit();

    const n = csr.node_count;
    if (start >= n or goal >= n) return null;

    var parent = try alloc.alloc(NodeId, n);
    defer alloc.free(parent);
    @memset(parent, INVALID_NODE);

    var visited = try std.DynamicBitSetUnmanaged.initEmpty(alloc, n);
    defer visited.deinit(alloc);

    var queue: std.ArrayListUnmanaged(NodeId) = .empty;
    defer queue.deinit(alloc);

    visited.set(start);
    try queue.append(alloc, start);

    var found = false;
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const curr = queue.items[head];
        if (curr == goal) {
            found = true;
            break;
        }

        const nbrs = csr.outNeighbors(curr);
        for (nbrs) |nbr| {
            if (!visited.isSet(nbr)) {
                visited.set(nbr);
                parent[nbr] = curr;
                try queue.append(alloc, nbr);
            }
        }
    }

    if (!found) return null;

    // Reconstruct path
    var path_list: std.ArrayListUnmanaged(NodeId) = .empty;
    defer path_list.deinit(alloc);

    var curr = goal;
    while (curr != INVALID_NODE) {
        try path_list.append(alloc, curr);
        curr = parent[curr];
    }

    // Reverse path so it goes from start -> goal
    const slice = try path_list.toOwnedSlice(alloc);
    std.mem.reverse(NodeId, slice);
    return slice;
}
