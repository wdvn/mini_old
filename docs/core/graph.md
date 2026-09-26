# Graph engine

`src/lib/graph.zig` exposes a directed, attributed graph API with mutable storage, compact traversal views, graph algorithms, and serialization. MemAct uses it to replay procedural-graph events and derive tool-workflow guidance.

## Module layout

```text
src/lib/graph.zig               Public facade and re-exports
src/lib/graph/types.zig         IDs, node/edge records, relation and node types
src/lib/graph/storage.zig       Mutable graph and adjacency indexes
src/lib/graph/csr.zig           Compact CSR/CSC traversal view
src/lib/graph/algorithms.zig    Neighborhood, cycle, reachability, and path algorithms
src/lib/graph/serialization.zig Binary snapshots and JSON event ingestion
```

The facade re-exports the main types and functions for consumers (`src/lib/graph.zig:17-63`).

## Architecture and data flow

```text
Create nodes / replay events
             ↓
        Mutable Graph
             ↓ toCsr()
     CSR and CSC arrays
             ↓
   Graph algorithms and queries

Mutable Graph ── saveBinary() ──> binary snapshot
JSON event ── applyEventJson() ──> mutate Graph
```

Algorithms that accept `Graph` compile it to a temporary CSR/CSC view, run against the view, and release it. CSR-specific variants let callers reuse an already-built view (`src/lib/graph/storage.zig:209-212`; `src/lib/graph/algorithms.zig:42-53, 148-156, 268-275`).

## Data model

| Type | Purpose | Source |
|---|---|---|
| `NodeId`, `EdgeId` | `u32` indexes into node and edge records. | `src/lib/graph/types.zig:8-11` |
| `NodeRecord` | Node ID, exact name, type, description, and active flag. | `src/lib/graph/types.zig:81-88` |
| `EdgeRecord` | Directed endpoint IDs, relation, optional string ID, attributes, and active flag. | `src/lib/graph/types.zig:90-99` |
| `EdgeAttributes` | Optional condition, guidance, pitfalls, superseded edge ID, and `f32` weight. | `src/lib/graph/types.zig:72-79` |
| `RelationType` | The edge relation enum. | `src/lib/graph/types.zig:13-39` |
| `NodeType` | The node classification enum. | `src/lib/graph/types.zig:41-70` |

Relation values:

```text
leads_to, triggers, provides_input_for, converges_to, custom
```

Node values:

```text
tool_action, skill, reasoning_step, task_state, code_symbol, custom
```

## Mutable storage

`Graph` keeps records in arrays, maps exact node names and optional edge string IDs to numeric IDs, and maintains outgoing and incoming edge-ID adjacency lists (`src/lib/graph/storage.zig:20-34`).

Graph-owned strings are copied into an arena. `deinit()` releases the graph's collections and arena (`src/lib/graph/storage.zig:36-56, 70-88, 147-169`).

- `addNode()` reuses an existing node with the same exact name and reactivates it if inactive (`src/lib/graph/storage.zig:59-89`).
- `addEdge()` validates both endpoint IDs, appends a directed edge, and updates both adjacency lists (`src/lib/graph/storage.zig:129-172`).
- `deleteEdge()` marks an edge inactive without removing its record. `deleteEdgeByStrId()` resolves an edge through its optional string ID (`src/lib/graph/storage.zig:190-207`).
- `supersedeEdge()` adds a replacement referring to the previous edge's string ID. Insertion deactivates the old edge when that ID is indexed (`src/lib/graph/storage.zig:110-127, 175-188`).

## CSR and CSC traversal view

`Graph.toCsr()` builds a compact view containing only active edges whose endpoint nodes are active (`src/lib/graph/storage.zig:209-212`; `src/lib/graph/csr.zig:29-49`).

The view contains:

- CSR arrays for outgoing neighbors and their edge IDs.
- CSC-style reverse arrays for incoming neighbors and their edge IDs.
- Offset arrays and in/out degree accessors (`src/lib/graph/csr.zig:14-27, 118-137, 150-185`).

The view represents the active topology at conversion time. Later mutations to `Graph` do not update an existing `CsrGraph`.

## Algorithms

| Name | Description | Source |
|---|---|---|
| `traverseNeighborhood()` | Breadth-first collection of nodes up to `max_hops` and their outgoing edges. | `src/lib/graph/algorithms.zig:40-53, 85-132` |
| `traverseNeighborhoodCsr()` | Runs neighborhood traversal directly on a `CsrGraph`. | `src/lib/graph/algorithms.zig:85-132` |
| `detectCycles()` | Iterative three-color DFS that reports back-edges closing directed cycles. | `src/lib/graph/algorithms.zig:148-240` |
| `repairCycles()` | Marks reported cycle-closing edges inactive in the mutable graph. | `src/lib/graph/algorithms.zig:242-251` |
| `checkTerminalReachability()` | Reverse-BFS from nodes with out-degree zero; reports nodes that cannot reach a terminal. | `src/lib/graph/algorithms.zig:268-348` |
| `findShortestPath()` | BFS over directed outgoing edges; returns a node-ID path or `null`. | `src/lib/graph/algorithms.zig:401-440` |

Algorithm result slices are owned by the caller. `NeighborhoodResult`, `CycleResult`, and `ReachabilityResult` each provide `deinit()`; `findShortestPath()` returns a slice that the caller frees using the allocator passed to the call (`src/lib/graph/algorithms.zig:29-37, 138-145, 257-265, 401-440`).

## Serialization and event replay

`saveBinary()` and `loadBinary()` encode and decode a binary graph snapshot. The format starts with the eight-byte `MINIPG01` magic and `u32` node and edge counts. Integer fields are little-endian; optional strings use `u16` lengths (`src/lib/graph/serialization.zig:49-80, 82-122, 210-239`).

`applyEventJson()` parses one JSON object and dispatches these event types (`src/lib/graph/serialization.zig:250-327`):

- `add_node`
- `add_edge`
- `delete_edge`

The graph engine applies one event at a time. Reading JSONL files and deciding how to handle invalid lines belong to the calling store, not `applyEventJson()`.

> **Event input detail:** The `add_edge` handler reads endpoint names, relation, ID, condition, guidance, pitfalls, and supersedes fields. It does not read a `weight` field, so JSON-created edges use the default weight `1.0` (`src/lib/graph/serialization.zig:266-291`; `src/lib/graph/types.zig:72-79`).

## MemAct integration

`PGraphStore` owns a `Graph`, replays `pgraph.jsonl` through `applyEventJson()`, and attempts cycle repair after loading (`src/core/memact/graph_store.zig:25-53, 78-110`).

The integration flow is:

1. Tool completion records a transition in `PGraphStore` (`src/core/agent.zig:745-751`).
2. Frequent eligible transitions can be promoted to graph edges (`src/core/memact/graph_store.zig:637-668`).
3. `serializeGuidance()` extracts h-hop guidance around the latest action (`src/core/memact/graph_store.zig:575-609`).
4. The step pipeline may append that guidance as a temporary user message (`src/core/agent_step.zig:54-80`).

## Tests

Unit tests in `src/lib/graph.zig` and integration tests in `testcases/test_procedural_graph.zig` cover graph operations, event replay, cycle repair, terminal reachability, neighborhood traversal, and binary snapshot round trips (`src/lib/graph.zig:75-355`; `testcases/test_procedural_graph.zig:1-9`).