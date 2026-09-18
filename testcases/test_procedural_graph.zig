//! test_procedural_graph.zig — Validation suite for src/lib/graph.zig (RFC-010).
//!
//! Validates the graph engine against the exact scenarios the MemAct update
//! (RFC-010 PG-1/PG-2/PG-3) will rely on:
//!   1. JSONL event replay semantics (store.zig pattern: append-only + supersedes)
//!   2. Tolerance to corrupted / unknown event lines (skip-not-fail at caller)
//!   3. Candidate edit pipeline: add edges -> cycle repair -> terminal reachability
//!   4. matchNode + h-hop subgraph extraction (paper §3.2, h=2)
//!   5. Binary snapshot round-trip preserving inactive (superseded/deleted) edges

const std = @import("std");
const testing = std.testing;
const mini = @import("mini");
const graph_mod = mini.graph_mod;

const Graph = graph_mod.Graph;
const RelationType = graph_mod.RelationType;
const NodeType = graph_mod.NodeType;
const EdgeAttributes = graph_mod.EdgeAttributes;
const detectCycles = graph_mod.detectCycles;
const repairCycles = graph_mod.repairCycles;
const checkTerminalReachability = graph_mod.checkTerminalReachability;
const traverseNeighborhoodCsr = graph_mod.traverseNeighborhoodCsr;
const applyEventJson = graph_mod.applyEventJson;
const ByteWriter = graph_mod.ByteWriter;
const ByteReader = graph_mod.ByteReader;
const saveBinary = graph_mod.saveBinary;
const loadBinary = graph_mod.loadBinary;

// ---------------------------------------------------------------------------
// 1. JSONL replay semantics — the exact contract graph_store.zig will follow
// ---------------------------------------------------------------------------

test "pg: JSONL replay with supersedes deactivates prior edge (store.loadIndex contract)" {
    const alloc = testing.allocator;
    var g = Graph.init(alloc);
    defer g.deinit();

    // Simulate graph_store.loadIndex: replay lines in file order.
    // Line 1: node declarations
    try applyEventJson(&g,
        \\{"ev":"add_node","id":"pgn_1","node":{"name":"edit_code","type":"tool_action","desc":"Edit a file"}}
    );
    try applyEventJson(&g,
        \\{"ev":"add_node","id":"pgn_2","node":{"name":"run_test_suite","type":"tool_action","desc":"Run zig build test"}}
    );
    // Line 2: original edge
    try applyEventJson(&g,
        \\{"ev":"add_edge","id":"pge_1","edge":{"src":"edit_code","rel":"LEADS_TO","dst":"run_test_suite","condition":"change compiles","guidance":"run full suite","pitfalls":"no scratch files"}}
    );
    try testing.expectEqual(@as(usize, 1), g.active_edge_count);

    // Line 3: attribute revision via supersedes (paper: delete + re-add)
    try applyEventJson(&g,
        \\{"ev":"add_edge","id":"pge_2","supersedes":"pge_1","edge":{"src":"edit_code","rel":"LEADS_TO","dst":"run_test_suite","guidance":"run All-In-One suite, all 13 steps must pass"}}
    );

    // Index state: new edge active, old edge deactivated, counts consistent.
    try testing.expectEqual(@as(usize, 1), g.active_edge_count);
    try testing.expectEqual(@as(usize, 2), g.edges.items.len); // both retained on "disk"
    const old_eid = g.str_id_to_edge.get("pge_1").?;
    const new_eid = g.str_id_to_edge.get("pge_2").?;
    try testing.expect(!g.edges.items[old_eid].is_active);
    try testing.expect(g.edges.items[new_eid].is_active);
    try testing.expectEqualStrings("pge_1", g.edges.items[new_eid].attr.supersedes.?);
    try testing.expectEqualStrings("run All-In-One suite, all 13 steps must pass", g.edges.items[new_eid].attr.guidance.?);

    // Old edge id stays resolvable for audit (event-sourcing trail).
    try testing.expectEqualStrings("change compiles", g.edges.items[old_eid].attr.condition.?);
}

test "pg: replay tolerates corrupted / unknown lines without aborting the stream" {
    const alloc = testing.allocator;
    var g = Graph.init(alloc);
    defer g.deinit();

    try applyEventJson(&g,
        \\{"ev":"add_node","id":"pgn_1","node":{"name":"tool_bash","type":"tool_action","desc":"bash"}}
    );

    // Corrupted JSON -> applyEventJson returns error; graph_store must skip (catch) and continue.
    const bad = applyEventJson(&g, "{not valid json");
    try testing.expectError(error.InvalidJson, bad);

    // Unknown event type -> silently ignored (evidence-only lines like reject_candidate).
    try applyEventJson(&g,
        \\{"ev":"reject_candidate","round":3,"reason":"validation dropped"}
    );

    // Valid event after garbage -> stream continues.
    try applyEventJson(&g,
        \\{"ev":"add_node","id":"pgn_2","node":{"name":"tool_read","type":"tool_action","desc":"read"}}
    );
    try testing.expectEqual(@as(usize, 2), g.active_node_count);
    try testing.expectEqual(@as(usize, 0), g.active_edge_count);

    // Unknown relation -> edge silently dropped (RFC-010 4-relation vocabulary).
    try applyEventJson(&g,
        \\{"ev":"add_edge","id":"pge_x","edge":{"src":"tool_bash","rel":"MAGICAL_LINK","dst":"tool_read"}}
    );
    try testing.expectEqual(@as(usize, 0), g.active_edge_count);
}

test "pg: delete_edge then re-add same endpoints (paper edit semantics)" {
    const alloc = testing.allocator;
    var g = Graph.init(alloc);
    defer g.deinit();

    try applyEventJson(&g,
        \\{"ev":"add_edge","id":"pge_1","edge":{"src":"a","rel":"LEADS_TO","dst":"b","guidance":"old path"}}
    );
    // Paper B.5: delete_edges removes all edges between endpoints; to retain
    // selected transitions, include them in add_edges (applied after deletion).
    try applyEventJson(&g, "{\"ev\":\"delete_edge\",\"id\":\"pge_1\"}");
    try testing.expectEqual(@as(usize, 0), g.active_edge_count);

    try applyEventJson(&g,
        \\{"ev":"add_edge","id":"pge_2","edge":{"src":"a","rel":"TRIGGERS","dst":"b","guidance":"new path"}}
    );
    try testing.expectEqual(@as(usize, 1), g.active_edge_count);
    const eid = g.str_id_to_edge.get("pge_2").?;
    try testing.expectEqual(RelationType.triggers, g.edges.items[eid].rel);
}

// ---------------------------------------------------------------------------
// 2. Candidate edit pipeline (paper Algorithm 1, Step 2-3 structural checks)
// ---------------------------------------------------------------------------

test "pg: candidate edits introducing a cycle are detected and repaired, then pass reachability" {
    const alloc = testing.allocator;
    var g = Graph.init(alloc);
    defer g.deinit();

    // Base backbone: edit -> test -> commit (terminal)
    try applyEventJson(&g,
        \\{"ev":"add_node","id":"pgn_1","node":{"name":"edit_code","type":"tool_action","desc":""}}
    );
    try applyEventJson(&g,
        \\{"ev":"add_node","id":"pgn_2","node":{"name":"run_test_suite","type":"tool_action","desc":""}}
    );
    try applyEventJson(&g,
        \\{"ev":"add_node","id":"pgn_3","node":{"name":"commit_code","type":"tool_action","desc":""}}
    );
    try applyEventJson(&g,
        \\{"ev":"add_edge","id":"pge_1","edge":{"src":"edit_code","rel":"LEADS_TO","dst":"run_test_suite"}}
    );
    try applyEventJson(&g,
        \\{"ev":"add_edge","id":"pge_2","edge":{"src":"run_test_suite","rel":"LEADS_TO","dst":"commit_code"}}
    );

    // Candidate edit (from refiner): add a verification shortcut that closes a cycle
    // commit -> edit would loop; a candidate proposes commit_code -> edit_code.
    try applyEventJson(&g,
        \\{"ev":"add_edge","id":"pge_cand","edge":{"src":"commit_code","rel":"CONVERGES_TO","dst":"edit_code"}}
    );

    // Structural check: cycle detected, repair removes closing edge.
    var cyc = try detectCycles(&g, alloc);
    defer cyc.deinit(alloc);
    try testing.expect(cyc.has_cycle);
    const removed = try repairCycles(&g, alloc);
    try testing.expectEqual(@as(usize, 1), removed);

    var cyc2 = try detectCycles(&g, alloc);
    defer cyc2.deinit(alloc);
    try testing.expect(!cyc2.has_cycle);

    // Gate check: after repair every node reaches a terminal (commit_code).
    var reach = try checkTerminalReachability(&g, alloc);
    defer reach.deinit(alloc);
    try testing.expect(reach.all_reachable);
    try testing.expectEqual(@as(usize, 1), reach.terminal_count);

    // Backbone intact: edit -> test -> commit still active.
    try testing.expectEqual(@as(usize, 2), g.active_edge_count);
}

test "pg: dangling branch (no path to terminal) is reported by reachability check" {
    const alloc = testing.allocator;
    var g = Graph.init(alloc);
    defer g.deinit();

    try applyEventJson(&g,
        \\{"ev":"add_edge","id":"pge_1","edge":{"src":"edit_code","rel":"LEADS_TO","dst":"run_test_suite"}}
    );
    // Refiner added an edge into a node that never reaches any terminal.
    try applyEventJson(&g,
        \\{"ev":"add_edge","id":"pge_2","edge":{"src":"run_test_suite","rel":"TRIGGERS","dst":"forever_loop"}}
    );
    // forever_loop has a self-edge -> part of a cycle AND unreachable to terminal.
    try applyEventJson(&g,
        \\{"ev":"add_edge","id":"pge_3","edge":{"src":"forever_loop","rel":"LEADS_TO","dst":"forever_loop"}}
    );

    _ = try repairCycles(&g, alloc);

    var reach = try checkTerminalReachability(&g, alloc);
    defer reach.deinit(alloc);
    // After removing the cycle-closing self-loop, forever_loop has out-degree 0
    // and becomes a terminal itself -> all reachable again.
    try testing.expect(reach.all_reachable);
}

// ---------------------------------------------------------------------------
// 3. matchNode + h-hop subgraph (paper §3.2 — online guidance extraction)
// ---------------------------------------------------------------------------

test "pg: match last tool call and extract 2-hop guidance subgraph" {
    const alloc = testing.allocator;
    var g = Graph.init(alloc);
    defer g.deinit();

    // Workflow: bash -> run_test_suite -> commit_code; bash -> grep -> run_test_suite
    const bash = try g.addNode("bash", .tool_action, "Run shell commands");
    const grep = try g.addNode("grep", .tool_action, "Search code");
    const test_suite = try g.addNode("run_test_suite", .tool_action, "All-In-One suite");
    const commit = try g.addNode("commit_code", .tool_action, "Commit changes");

    _ = try g.addEdge(bash, test_suite, .leads_to, .{
        .condition = "code changed",
        .guidance = "run zig build test --summary all",
        .pitfalls = "never commit with failing tests",
    }, "pge_1");
    _ = try g.addEdge(grep, test_suite, .provides_input_for, .{
        .condition = "locating failing test",
    }, "pge_2");
    _ = try g.addEdge(test_suite, commit, .leads_to, .{
        .condition = "all 13 steps pass",
        .guidance = "commit with module prefix message",
    }, "pge_3");

    // matchNode(a_{t-1}) = exact name match — paper Eq.2 Match(a_{t-1}, V).
    const u_t = g.findNodeByName("bash") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(bash, u_t);

    // Extract h=2 neighborhood from the localized node.
    var csr_view = try g.toCsr(alloc);
    defer csr_view.deinit();
    var nbhd = try traverseNeighborhoodCsr(&csr_view, u_t, 2, alloc);
    defer nbhd.deinit(alloc);

    // Nodes: bash(0), run_test_suite(1), commit_code(2) — grep is NOT reachable.
    try testing.expectEqual(@as(usize, 3), nbhd.nodes.len);
    try testing.expectEqual(@as(u32, 0), nbhd.nodes[0].hop);
    // Edges within hop<2 expansion: bash->test, test->commit = 2 (grep branch excluded).
    try testing.expectEqual(@as(usize, 2), nbhd.edges.len);

    // Verify the second hop edge is test_suite -> commit.
    const e2 = g.edges.items[nbhd.edges[1]];
    try testing.expectEqual(test_suite, e2.src);
    try testing.expectEqual(commit, e2.dst);
    try testing.expectEqualStrings("commit with module prefix message", e2.attr.guidance.?);
}

test "pg: neighborhood of unknown node and empty graph degrade gracefully" {
    const alloc = testing.allocator;
    var g = Graph.init(alloc);
    defer g.deinit();

    // Unknown start node -> empty result (caller falls back to full-graph serialization).
    var csr_view = try g.toCsr(alloc);
    defer csr_view.deinit();
    var nbhd = try traverseNeighborhoodCsr(&csr_view, 42, 2, alloc);
    defer nbhd.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), nbhd.nodes.len);

    // Empty graph reachability -> trivially valid.
    var reach = try checkTerminalReachability(&g, alloc);
    defer reach.deinit(alloc);
    try testing.expect(reach.all_reachable);
    try testing.expectEqual(@as(usize, 0), reach.terminal_count);
}

// ---------------------------------------------------------------------------
// 4. Binary snapshot round-trip preserves inactive edges (checkpoint/rollback)
// ---------------------------------------------------------------------------

test "pg: binary snapshot round-trip keeps superseded edges inactive for CAS-style rollback" {
    const alloc = testing.allocator;
    var g1 = Graph.init(alloc);
    defer g1.deinit();

    try applyEventJson(&g1,
        \\{"ev":"add_edge","id":"pge_1","edge":{"src":"edit_code","rel":"LEADS_TO","dst":"run_test_suite","guidance":"v1"}}
    );
    try applyEventJson(&g1,
        \\{"ev":"add_edge","id":"pge_2","supersedes":"pge_1","edge":{"src":"edit_code","rel":"LEADS_TO","dst":"run_test_suite","guidance":"v2"}}
    );
    try testing.expectEqual(@as(usize, 1), g1.active_edge_count);

    var writer = ByteWriter.init(alloc);
    defer writer.deinit();
    try saveBinary(&g1, &writer);

    var reader = ByteReader.init(writer.getWritten());
    var g2 = try loadBinary(alloc, &reader);
    defer g2.deinit();

    try testing.expectEqual(@as(usize, 1), g2.active_edge_count);
    try testing.expectEqual(@as(usize, 2), g2.edges.items.len);

    // Both edges resolvable; old one stays inactive after reload.
    const old_eid = g2.str_id_to_edge.get("pge_1").?;
    const new_eid = g2.str_id_to_edge.get("pge_2").?;
    try testing.expect(!g2.edges.items[old_eid].is_active);
    try testing.expect(g2.edges.items[new_eid].is_active);
    try testing.expectEqualStrings("v2", g2.edges.items[new_eid].attr.guidance.?);
    try testing.expectEqualStrings("pge_1", g2.edges.items[new_eid].attr.supersedes.?);

    // 2-hop traversal works identically on the reloaded graph.
    const src = g2.findNodeByName("edit_code").?;
    var csr_view = try g2.toCsr(alloc);
    defer csr_view.deinit();
    var nbhd = try traverseNeighborhoodCsr(&csr_view, src, 2, alloc);
    defer nbhd.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), nbhd.edges.len); // only the active v2 edge
}

// ---------------------------------------------------------------------------
// 6. PGraphStore (RFC-010 PG-1, PG-2, PG-3)
// ---------------------------------------------------------------------------

const PGraphStore = mini.graph_store_mod.PGraphStore;

test "pg: PGraphStore seedDefaults creates JSONL and populates graph" {
    const alloc = testing.allocator;
    const io = std.testing.io;

    var buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrint(&buf, "/tmp/mini_pgstore_test_{d}_1", .{std.os.linux.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var store = try PGraphStore.init(alloc, io, dir);
    defer store.deinit();

    try store.loadIndex(io);

    // Default tools and edges must be present
    try testing.expect(store.graph.active_node_count >= 10);
    try testing.expect(store.graph.active_edge_count >= 5);

    // Verify key nodes
    try testing.expect(store.matchNode("bash") != null);
    try testing.expect(store.matchNode("file_read") != null);
    try testing.expect(store.matchNode("grep") != null);
    try testing.expect(store.matchNode("file_edit") != null);

    // Verify alias normalization
    try testing.expectEqual(store.matchNode("bash"), store.matchNode("run_command"));
    try testing.expectEqual(store.matchNode("bash"), store.matchNode("sh"));
    try testing.expectEqual(store.matchNode("file_read"), store.matchNode("read_file"));
    try testing.expectEqual(store.matchNode("file_read"), store.matchNode("view_file"));
    try testing.expectEqual(store.matchNode("file_edit"), store.matchNode("replace_file_content"));
    try testing.expectEqual(store.matchNode("file_edit"), store.matchNode("patch"));
}

test "pg: serializeGuidance generates 2-hop markdown guidance block" {
    const alloc = testing.allocator;
    const io = std.testing.io;

    var buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrint(&buf, "/tmp/mini_pgstore_test_{d}_2", .{std.os.linux.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var store = try PGraphStore.init(alloc, io, dir);
    defer store.deinit();

    try store.loadIndex(io);

    // Guidance for file_edit should suggest bash
    const guidance_opt = try store.serializeGuidance(alloc, "file_edit", &.{}, false, 2);
    try testing.expect(guidance_opt != null);
    const guidance = guidance_opt.?;
    defer alloc.free(guidance);

    try testing.expect(std.mem.indexOf(u8, guidance, "[Procedural Advisory") != null);
    try testing.expect(std.mem.indexOf(u8, guidance, "Current Action: `file_edit`") != null);
    try testing.expect(std.mem.indexOf(u8, guidance, "`bash`") != null);
}

test "pg: recordTransition frequency gate promotes candidate edge at N >= 3" {
    const alloc = testing.allocator;
    const io = std.testing.io;

    var buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrint(&buf, "/tmp/mini_pgstore_test_{d}_3", .{std.os.linux.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var store = try PGraphStore.init(alloc, io, dir);
    defer store.deinit();

    try store.loadIndex(io);

    const initial_edges = store.graph.active_edge_count;

    // Transition from list_dir to glob
    try store.recordTransition(io, "list_dir", "glob");
    try testing.expectEqual(initial_edges, store.graph.active_edge_count);

    try store.recordTransition(io, "list_dir", "glob");
    try testing.expectEqual(initial_edges, store.graph.active_edge_count);

    // 3rd time: threshold reached -> edge promoted!
    try store.recordTransition(io, "list_dir", "glob");
    try testing.expectEqual(initial_edges + 1, store.graph.active_edge_count);

    // Reload index from file to confirm persistence to JSONL
    var store2 = try PGraphStore.init(alloc, io, dir);
    defer store2.deinit();
    try store2.loadIndex(io);
    try testing.expectEqual(initial_edges + 1, store2.graph.active_edge_count);
}

test "pg: recordTransition rejects cycle and generic observational pairs" {
    const alloc = testing.allocator;
    const io = std.testing.io;

    var buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrint(&buf, "/tmp/mini_pgstore_test_{d}_4", .{std.os.linux.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var store = try PGraphStore.init(alloc, io, dir);
    defer store.deinit();
    try store.loadIndex(io);

    const initial_edges = store.graph.active_edge_count;

    // 1. Generic observational pair (bash <-> file_read) should never be promoted
    try store.recordTransition(io, "bash", "file_read");
    try store.recordTransition(io, "bash", "file_read");
    try store.recordTransition(io, "bash", "file_read");
    try testing.expectEqual(initial_edges, store.graph.active_edge_count);

    // 2. Add valid edge list_dir -> glob
    try store.recordTransition(io, "list_dir", "glob");
    try store.recordTransition(io, "list_dir", "glob");
    try store.recordTransition(io, "list_dir", "glob");
    try testing.expectEqual(initial_edges + 1, store.graph.active_edge_count);

    // 3. Attempting reverse edge glob -> list_dir must be rejected by cycle guard
    try store.recordTransition(io, "glob", "list_dir");
    try store.recordTransition(io, "glob", "list_dir");
    try store.recordTransition(io, "glob", "list_dir");
    try testing.expectEqual(initial_edges + 1, store.graph.active_edge_count);
}

test "pg: serializeGuidance suppresses recent actions in trajectory window" {
    const alloc = testing.allocator;
    const io = std.testing.io;

    var buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrint(&buf, "/tmp/mini_pgstore_test_{d}_5", .{std.os.linux.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var store = try PGraphStore.init(alloc, io, dir);
    defer store.deinit();
    try store.loadIndex(io);

    // Default for file_edit leads to bash.
    // If bash was NOT recently run, it is suggested:
    const g_normal = try store.serializeGuidance(alloc, "file_edit", &.{}, false, 2);
    try testing.expect(g_normal != null);
    defer alloc.free(g_normal.?);
    try testing.expect(std.mem.indexOf(u8, g_normal.?, "`bash`") != null);

    // If bash WAS recently run, it is suppressed to prevent ping-pong:
    const g_suppressed = try store.serializeGuidance(alloc, "file_edit", &.{ "bash" }, false, 2);
    try testing.expect(g_suppressed == null);

    // If previous act failed, suppression is STILL enforced to prevent infinite ping-pong loops.
    // Instead of re-suggesting recently executed bash, it emits an anti-loop advisory:
    const g_retry = try store.serializeGuidance(alloc, "file_edit", &.{ "bash" }, true, 2);
    try testing.expect(g_retry != null);
    defer alloc.free(g_retry.?);
    try testing.expect(std.mem.indexOf(u8, g_retry.?, "`bash` →") == null); // bash is NOT suggested as next step
    try testing.expect(std.mem.indexOf(u8, g_retry.?, "No new untried recovery steps found") != null);
    try testing.expect(std.mem.indexOf(u8, g_retry.?, "Do NOT repeat previous searches") != null);
}

test "pg: detectTrajectoryOrbit identifies 3D exploratory loops and respects mutation displacement" {
    // Case 1: Closed orbit of period 3 (bash -> grep -> file_read -> bash)
    const traj_orbit1: []const []const u8 = &.{ "bash", "grep", "file_read", "bash" };
    const res1 = PGraphStore.detectTrajectoryOrbit(traj_orbit1, "bash");
    try testing.expect(res1 != null);
    try testing.expectEqual(@as(usize, 3), res1.?.period);
    try testing.expectEqual(@as(usize, 1), res1.?.revolutions);

    // Case 2: Trajectory containing mutation tool (file_edit) has ΔZ > 0 -> not an exploratory orbit!
    const traj_mutate: []const []const u8 = &.{ "bash", "grep", "file_read", "file_edit", "bash" };
    const res_mutate = PGraphStore.detectTrajectoryOrbit(traj_mutate, "bash");
    try testing.expect(res_mutate == null);

    // Case 3: Degenerate self-loops (consecutive bash) are not simple orbits
    const traj_self: []const []const u8 = &.{ "bash", "bash", "bash", "bash" };
    const res_self = PGraphStore.detectTrajectoryOrbit(traj_self, "bash");
    try testing.expect(res_self == null);

    // Case 4: Multi-revolution orbit (2 full cycles of bash -> grep -> file_read)
    const traj_orbit2: []const []const u8 = &.{ "bash", "grep", "file_read", "bash", "grep", "file_read" };
    const res2 = PGraphStore.detectTrajectoryOrbit(traj_orbit2, "file_read");
    try testing.expect(res2 != null);
    try testing.expectEqual(@as(usize, 3), res2.?.period);
    try testing.expectEqual(@as(usize, 2), res2.?.revolutions);
}

test "pg: serializeGuidance generates 3D Map Checkpoint & Recap on orbit" {
    const alloc = testing.allocator;
    const io = std.testing.io;

    var buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrint(&buf, "/tmp/mini_pgstore_test_{d}_6", .{std.os.linux.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var store = try PGraphStore.init(alloc, io, dir);
    defer store.deinit();
    try store.loadIndex(io);

    // Provide trajectory with closed orbit: bash -> grep -> file_read -> bash
    const traj: []const []const u8 = &.{ "bash", "grep", "file_read", "bash" };
    const g_orbit = try store.serializeGuidance(alloc, "bash", traj, false, 2);
    try testing.expect(g_orbit != null);
    defer alloc.free(g_orbit.?);

    // Verify Checkpoint & Recap formatting
    try testing.expect(std.mem.indexOf(u8, g_orbit.?, "[Procedural 3D Map Checkpoint & Trajectory Recap]") != null);
    try testing.expect(std.mem.indexOf(u8, g_orbit.?, "3D Trajectory Orbit Detected") != null);
    try testing.expect(std.mem.indexOf(u8, g_orbit.?, "Explored Territory Recap") != null);
    try testing.expect(std.mem.indexOf(u8, g_orbit.?, "Orbit Break Directive") != null);
    try testing.expect(std.mem.indexOf(u8, g_orbit.?, "Formulate a concise step-by-step plan") != null);
    try testing.expect(std.mem.indexOf(u8, g_orbit.?, "MUTATE domain") != null);

    // Crucial: regular forward step suggestion is suppressed during orbit!
    try testing.expect(std.mem.indexOf(u8, g_orbit.?, "Observed Pattern Suggestions") == null);
}


