//! lib/graph.zig — High-Performance Native Graph Engine for mini-agent.
//!
//! Designed for RFC-010 (Procedural Graph) and MemAct long-term memory.
//! Capable of scaling from small localized graphs (10-50 nodes) up to
//! massive knowledge and code graphs (100k+ nodes, 500k+ edges) with
//! sub-millisecond query latency and minimal memory footprint (< 10MB).
//!
//! ## Submodules
//! - `types`: Node/Edge IDs, RelationType, NodeType, EdgeAttributes, Records
//! - `storage`: Dynamic mutable Property Graph with StringInterner & supersedes
//! - `csr`: Compressed Sparse Row (CSR) & Column (CSC) high-speed views
//! - `algorithms`: Neighborhood traversal, cycle detection/repair, terminal reachability, shortest path
//! - `serialization`: ByteWriter/ByteReader, binary snapshot (.pgbin), JSONL event ingestion

const std = @import("std");

// Submodules
pub const types = @import("graph/types.zig");
pub const csr = @import("graph/csr.zig");
pub const storage = @import("graph/storage.zig");
pub const algorithms = @import("graph/algorithms.zig");
pub const serialization = @import("graph/serialization.zig");

// ---------------------------------------------------------------------------
// Top-Level Re-exports (Ergonomic API)
// ---------------------------------------------------------------------------

// Types
pub const NodeId = types.NodeId;
pub const EdgeId = types.EdgeId;
pub const INVALID_NODE = types.INVALID_NODE;
pub const INVALID_EDGE = types.INVALID_EDGE;
pub const RelationType = types.RelationType;
pub const NodeType = types.NodeType;
pub const EdgeAttributes = types.EdgeAttributes;
pub const NodeRecord = types.NodeRecord;
pub const EdgeRecord = types.EdgeRecord;

// Storage & Views
pub const Graph = storage.Graph;
pub const CsrGraph = csr.CsrGraph;

// Algorithm Results & Functions
pub const NodeWithHop = algorithms.NodeWithHop;
pub const NeighborhoodResult = algorithms.NeighborhoodResult;
pub const CycleResult = algorithms.CycleResult;
pub const ReachabilityResult = algorithms.ReachabilityResult;

pub const traverseNeighborhood = algorithms.traverseNeighborhood;
pub const traverseNeighborhoodCsr = algorithms.traverseNeighborhoodCsr;
pub const detectCycles = algorithms.detectCycles;
pub const detectCyclesCsr = algorithms.detectCyclesCsr;
pub const repairCycles = algorithms.repairCycles;
pub const checkTerminalReachability = algorithms.checkTerminalReachability;
pub const checkTerminalReachabilityCsr = algorithms.checkTerminalReachabilityCsr;
pub const findShortestPath = algorithms.findShortestPath;

// Serialization
pub const ByteWriter = serialization.ByteWriter;
pub const ByteReader = serialization.ByteReader;
pub const saveBinary = serialization.saveBinary;
pub const loadBinary = serialization.loadBinary;
pub const applyEventJson = serialization.applyEventJson;

// ---------------------------------------------------------------------------
// Integration Tests & Scalability Benchmarks
// ---------------------------------------------------------------------------

fn getMonotonicTimeNs() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, @intCast(ts.sec)) * 1_000_000_000 + ts.nsec;
}

test "graph - basic CRUD and CSR compilation" {
    const alloc = std.testing.allocator;
    var g = Graph.init(alloc);
    defer g.deinit();

    const node1 = try g.addNode("edit_code", .tool_action, "Edits a file");
    const node2 = try g.addNode("run_test_suite", .tool_action, "Runs zig build test");
    const node3 = try g.addNode("commit_code", .tool_action, "Commits changes");

    try std.testing.expectEqual(@as(usize, 3), g.active_node_count);

    const e1 = try g.addEdge(node1, node2, .leads_to, .{
        .condition = "code change complete",
        .guidance = "run full test suite",
        .pitfalls = "do not leave scratch files",
    }, "pge_1");

    const e2 = try g.addEdge(node2, node3, .leads_to, .{
        .condition = "all tests pass",
        .guidance = "commit with clear message",
    }, "pge_2");

    _ = e1;
    _ = e2;

    try std.testing.expectEqual(@as(usize, 2), g.active_edge_count);

    // Compile to CSR
    var csrg = try g.toCsr(alloc);
    defer csrg.deinit();

    try std.testing.expectEqual(@as(u32, 3), csrg.node_count);
    try std.testing.expectEqual(@as(u32, 2), csrg.edge_count);

    const out1 = csrg.outNeighbors(node1);
    try std.testing.expectEqual(@as(usize, 1), out1.len);
    try std.testing.expectEqual(node2, out1[0]);

    const in2 = csrg.inNeighbors(node2);
    try std.testing.expectEqual(@as(usize, 1), in2.len);
    try std.testing.expectEqual(node1, in2[0]);
}

test "graph - 2-hop neighborhood extraction" {
    const alloc = std.testing.allocator;
    var g = Graph.init(alloc);
    defer g.deinit();

    // Line: A -> B -> C -> D
    const a = try g.addNode("A", .task_state, "");
    const b = try g.addNode("B", .task_state, "");
    const c = try g.addNode("C", .task_state, "");
    const d = try g.addNode("D", .task_state, "");

    _ = try g.addEdge(a, b, .leads_to, .{}, null);
    _ = try g.addEdge(b, c, .leads_to, .{}, null);
    _ = try g.addEdge(c, d, .leads_to, .{}, null);

    // 2-hop from A should collect A (hop 0), B (hop 1), C (hop 2), but NOT D (hop 3)
    var res = try traverseNeighborhood(&g, a, 2, alloc);
    defer res.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 3), res.nodes.len);
    try std.testing.expectEqual(a, res.nodes[0].id);
    try std.testing.expectEqual(@as(u32, 0), res.nodes[0].hop);
    try std.testing.expectEqual(b, res.nodes[1].id);
    try std.testing.expectEqual(@as(u32, 1), res.nodes[1].hop);
    try std.testing.expectEqual(c, res.nodes[2].id);
    try std.testing.expectEqual(@as(u32, 2), res.nodes[2].hop);

    try std.testing.expectEqual(@as(usize, 2), res.edges.len);
}

test "graph - cycle detection and repair" {
    const alloc = std.testing.allocator;
    var g = Graph.init(alloc);
    defer g.deinit();

    // Triangle cycle: A -> B -> C -> A
    const a = try g.addNode("A", .tool_action, "");
    const b = try g.addNode("B", .tool_action, "");
    const c = try g.addNode("C", .tool_action, "");

    _ = try g.addEdge(a, b, .leads_to, .{}, null);
    _ = try g.addEdge(b, c, .leads_to, .{}, null);
    const cycle_edge = try g.addEdge(c, a, .leads_to, .{}, null);

    var cycle_res = try detectCycles(&g, alloc);
    defer cycle_res.deinit(alloc);

    try std.testing.expect(cycle_res.has_cycle);
    try std.testing.expectEqual(@as(usize, 1), cycle_res.closing_edges.len);
    try std.testing.expectEqual(cycle_edge, cycle_res.closing_edges[0]);

    // Repair cycles
    const repaired_count = try repairCycles(&g, alloc);
    try std.testing.expectEqual(@as(usize, 1), repaired_count);

    // After repair, cycle should be gone
    var cycle_res2 = try detectCycles(&g, alloc);
    defer cycle_res2.deinit(alloc);
    try std.testing.expect(!cycle_res2.has_cycle);
}

test "graph - terminal reachability" {
    const alloc = std.testing.allocator;
    var g = Graph.init(alloc);
    defer g.deinit();

    // A -> B -> C (C has out-degree 0, so C is terminal)
    // D -> D (cycle with no terminal path)
    const a = try g.addNode("A", .task_state, "");
    const b = try g.addNode("B", .task_state, "");
    const c = try g.addNode("C", .task_state, "");
    const d = try g.addNode("D", .task_state, "");

    _ = try g.addEdge(a, b, .leads_to, .{}, null);
    _ = try g.addEdge(b, c, .leads_to, .{}, null);
    _ = try g.addEdge(d, d, .leads_to, .{}, null); // self-loop

    var reach = try checkTerminalReachability(&g, alloc);
    defer reach.deinit(alloc);

    try std.testing.expect(!reach.all_reachable);
    try std.testing.expectEqual(@as(usize, 1), reach.terminal_count);
    try std.testing.expectEqual(@as(usize, 1), reach.unreachable_nodes.len);
    try std.testing.expectEqual(d, reach.unreachable_nodes[0]);
}

test "graph - shortest path" {
    const alloc = std.testing.allocator;
    var g = Graph.init(alloc);
    defer g.deinit();

    const a = try g.addNode("A", .task_state, "");
    const b = try g.addNode("B", .task_state, "");
    const c = try g.addNode("C", .task_state, "");
    const d = try g.addNode("D", .task_state, "");

    _ = try g.addEdge(a, b, .leads_to, .{}, null);
    _ = try g.addEdge(b, c, .leads_to, .{}, null);
    _ = try g.addEdge(c, d, .leads_to, .{}, null);
    _ = try g.addEdge(a, d, .leads_to, .{}, null); // direct shortcut

    const path = (try findShortestPath(&g, a, d, alloc)).?;
    defer alloc.free(path);

    try std.testing.expectEqual(@as(usize, 2), path.len);
    try std.testing.expectEqual(a, path[0]);
    try std.testing.expectEqual(d, path[1]);
}

test "graph - supersedes edge replacement" {
    const alloc = std.testing.allocator;
    var g = Graph.init(alloc);
    defer g.deinit();

    const a = try g.addNode("edit", .tool_action, "");
    const b = try g.addNode("test", .tool_action, "");

    const e1 = try g.addEdge(a, b, .leads_to, .{ .guidance = "old guidance" }, "edge_1");
    try std.testing.expect(g.edges.items[e1].is_active);

    const e2 = try g.supersedeEdge("edge_1", a, b, .leads_to, .{ .guidance = "updated guidance" }, "edge_2");

    try std.testing.expect(!g.edges.items[e1].is_active);
    try std.testing.expect(g.edges.items[e2].is_active);
    try std.testing.expectEqualStrings("updated guidance", g.edges.items[e2].attr.guidance.?);
}

test "graph - binary serialization round-trip" {
    const alloc = std.testing.allocator;
    var g1 = Graph.init(alloc);
    defer g1.deinit();

    const n1 = try g1.addNode("node_alpha", .tool_action, "Alpha desc");
    const n2 = try g1.addNode("node_beta", .skill, "Beta desc");
    _ = try g1.addEdge(n1, n2, .triggers, .{
        .condition = "cond 1",
        .guidance = "guide 1",
        .pitfalls = "pitfall 1",
    }, "edge_ab");

    var writer = ByteWriter.init(alloc);
    defer writer.deinit();

    try saveBinary(&g1, &writer);

    var reader = ByteReader.init(writer.getWritten());
    var g2 = try loadBinary(alloc, &reader);
    defer g2.deinit();

    try std.testing.expectEqual(g1.active_node_count, g2.active_node_count);
    try std.testing.expectEqual(g1.active_edge_count, g2.active_edge_count);

    const loaded_n1 = g2.findNodeByName("node_alpha").?;
    const loaded_n2 = g2.findNodeByName("node_beta").?;
    try std.testing.expectEqualStrings("Alpha desc", g2.getNode(loaded_n1).?.desc);
    try std.testing.expectEqual(NodeType.skill, g2.getNode(loaded_n2).?.node_type);
}

test "graph - JSONL event parsing" {
    const alloc = std.testing.allocator;
    var g = Graph.init(alloc);
    defer g.deinit();

    try applyEventJson(&g, "{\"ev\":\"add_node\",\"id\":\"pgn_1\",\"node\":{\"name\":\"tool_bash\",\"type\":\"tool_action\",\"desc\":\"Execute bash\"}}");
    try applyEventJson(&g, "{\"ev\":\"add_node\",\"id\":\"pgn_2\",\"node\":{\"name\":\"tool_file\",\"type\":\"tool_action\",\"desc\":\"Read file\"}}");
    try applyEventJson(&g, "{\"ev\":\"add_edge\",\"id\":\"pge_1\",\"edge\":{\"src\":\"tool_bash\",\"rel\":\"LEADS_TO\",\"dst\":\"tool_file\",\"guidance\":\"Check output file\"}}");

    try std.testing.expectEqual(@as(usize, 2), g.active_node_count);
    try std.testing.expectEqual(@as(usize, 1), g.active_edge_count);

    // Delete edge
    try applyEventJson(&g, "{\"ev\":\"delete_edge\",\"id\":\"pge_1\"}");
    try std.testing.expectEqual(@as(usize, 0), g.active_edge_count);
}

test "graph - 100,000 nodes high-scale stress test" {
    const alloc = std.testing.allocator;
    var g = Graph.init(alloc);
    defer g.deinit();

    const NUM_NODES: usize = 100_000;
    const EDGES_PER_NODE: usize = 3;

    // 1. Pre-allocate nodes directly for synthetic benchmark
    try g.nodes.ensureTotalCapacity(alloc, NUM_NODES);
    try g.out_adj.ensureTotalCapacity(alloc, NUM_NODES);
    try g.in_adj.ensureTotalCapacity(alloc, NUM_NODES);

    for (0..NUM_NODES) |i| {
        const nid: NodeId = @intCast(i);
        g.nodes.appendAssumeCapacity(.{
            .id = nid,
            .name = "",
            .node_type = .code_symbol,
            .desc = "",
            .is_active = true,
        });
        g.out_adj.appendAssumeCapacity(.empty);
        g.in_adj.appendAssumeCapacity(.empty);
    }
    g.active_node_count = NUM_NODES;

    // 2. Add 300,000 edges in a ring + forward leaps
    const TOTAL_EDGES = NUM_NODES * EDGES_PER_NODE;
    try g.edges.ensureTotalCapacity(alloc, TOTAL_EDGES);

    for (0..NUM_NODES) |i| {
        const src: NodeId = @intCast(i);
        for (1..EDGES_PER_NODE + 1) |step| {
            const dst: NodeId = @intCast((i + step) % NUM_NODES);
            const eid: EdgeId = @intCast(g.edges.items.len);
            g.edges.appendAssumeCapacity(.{
                .id = eid,
                .src = src,
                .dst = dst,
                .rel = .leads_to,
                .attr = .{},
                .is_active = true,
            });
            try g.out_adj.items[src].append(alloc, eid);
            try g.in_adj.items[dst].append(alloc, eid);
        }
    }
    g.active_edge_count = TOTAL_EDGES;

    // 3. Compile to CSR
    const timer_start = getMonotonicTimeNs();
    var csrg = try g.toCsr(alloc);
    defer csrg.deinit();
    const csr_build_ns = getMonotonicTimeNs() - timer_start;
    _ = csr_build_ns;

    try std.testing.expectEqual(@as(u32, NUM_NODES), csrg.node_count);
    try std.testing.expectEqual(@as(u32, TOTAL_EDGES), csrg.edge_count);

    // 4. Measure 2-hop neighborhood traversal latency on 100k graph
    const trav_start = getMonotonicTimeNs();
    var res = try traverseNeighborhoodCsr(&csrg, 0, 2, alloc);
    defer res.deinit(alloc);
    const trav_ns = getMonotonicTimeNs() - trav_start;

    // Hop 0: 1 node (node 0)
    // Hop 1: 3 nodes (1, 2, 3)
    // Hop 2: nodes 2, 3, 4, 5, 6 -> union = 7 nodes total
    try std.testing.expectEqual(@as(usize, 7), res.nodes.len);

    // Must be blazing fast (< 5 milliseconds = 5_000_000 ns)
    try std.testing.expect(trav_ns < 5_000_000);
}
