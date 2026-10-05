//! lib/graph/serialization.zig — High-speed Binary & JSONL Event Serialization.
//!
//! Provides:
//! - ByteWriter / ByteReader memory streams
//! - Compact binary snapshot (.pgbin) format for instant loading of 100k+ nodes
//! - JSONL event stream ingestion (add_node, add_edge, delete_edge, supersedes)

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const NodeId = types.NodeId;
const EdgeId = types.EdgeId;
const NodeType = types.NodeType;
const RelationType = types.RelationType;
const storage = @import("storage.zig");
const Graph = storage.Graph;

pub const ByteWriter = struct {
    list: std.ArrayListUnmanaged(u8) = .empty,
    alloc: Allocator,

    pub fn init(alloc: Allocator) ByteWriter {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *ByteWriter) void {
        self.list.deinit(self.alloc);
    }

    pub fn writeAll(self: *ByteWriter, bytes: []const u8) !void {
        try self.list.appendSlice(self.alloc, bytes);
    }

    pub fn writeInt(self: *ByteWriter, comptime T: type, val: T, endian: std.builtin.Endian) !void {
        var bytes: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &bytes, val, endian);
        try self.writeAll(&bytes);
    }

    pub fn toOwnedSlice(self: *ByteWriter) ![]u8 {
        return self.list.toOwnedSlice(self.alloc);
    }

    pub fn getWritten(self: *const ByteWriter) []const u8 {
        return self.list.items;
    }
};

pub const ByteReader = struct {
    buffer: []const u8,
    pos: usize = 0,

    pub fn init(buffer: []const u8) ByteReader {
        return .{ .buffer = buffer, .pos = 0 };
    }

    pub fn readNoEof(self: *ByteReader, dest: []u8) !void {
        if (self.pos + dest.len > self.buffer.len) return error.EndOfStream;
        @memcpy(dest, self.buffer[self.pos .. self.pos + dest.len]);
        self.pos += dest.len;
    }

    pub fn readInt(self: *ByteReader, comptime T: type, endian: std.builtin.Endian) !T {
        var bytes: [@sizeOf(T)]u8 = undefined;
        try self.readNoEof(&bytes);
        return std.mem.readInt(T, &bytes, endian);
    }
};

const MAGIC_PGBIN = "MINIPG01";

/// Save Graph into compact binary snapshot format.
pub fn saveBinary(graph: *const Graph, writer: anytype) !void {
    try writer.writeAll(MAGIC_PGBIN);

    const node_count: u32 = @intCast(graph.nodes.items.len);
    const edge_count: u32 = @intCast(graph.edges.items.len);

    try writer.writeInt(u32, node_count, .little);
    try writer.writeInt(u32, edge_count, .little);

    // Write nodes
    for (graph.nodes.items) |n| {
        try writer.writeInt(u32, n.id, .little);
        try writer.writeInt(u8, @intFromEnum(n.node_type), .little);
        try writer.writeInt(u8, if (n.is_active) 1 else 0, .little);

        const name_len: u16 = @intCast(n.name.len);
        try writer.writeInt(u16, name_len, .little);
        try writer.writeAll(n.name);

        const desc_len: u16 = @intCast(n.desc.len);
        try writer.writeInt(u16, desc_len, .little);
        try writer.writeAll(n.desc);
    }

    // Write edges
    for (graph.edges.items) |e| {
        try writer.writeInt(u32, e.id, .little);
        try writer.writeInt(u32, e.src, .little);
        try writer.writeInt(u32, e.dst, .little);
        try writer.writeInt(u8, @intFromEnum(e.rel), .little);
        try writer.writeInt(u8, if (e.is_active) 1 else 0, .little);
        try writer.writeInt(u32, @as(u32, @bitCast(e.attr.weight)), .little);

        try writeOptString(writer, e.str_id);
        try writeOptString(writer, e.attr.condition);
        try writeOptString(writer, e.attr.guidance);
        try writeOptString(writer, e.attr.pitfalls);
        try writeOptString(writer, e.attr.supersedes);
    }
}

fn writeOptString(writer: anytype, opt: ?[]const u8) !void {
    if (opt) |s| {
        const len: u16 = @intCast(s.len);
        try writer.writeInt(u16, len, .little);
        try writer.writeAll(s);
    } else {
        try writer.writeInt(u16, 0, .little);
    }
}

fn readBinaryNode(reader: anytype, graph: *Graph) !void {
    // PSEUDOCODE:
    // 1. Read node type, active flag, name and desc
    // 2. Allocate buffers in graph arena and read string bytes
    // 3. Append NodeRecord and update lookup indices
    _ = try reader.readInt(u32, .little); // id
    const type_byte = try reader.readInt(u8, .little);
    const active_byte = try reader.readInt(u8, .little);
    const name_len = try reader.readInt(u16, .little);

    const arena_alloc = graph.arena.allocator();
    const name_buf = try arena_alloc.alloc(u8, name_len);
    try reader.readNoEof(name_buf);

    const desc_len = try reader.readInt(u16, .little);
    const desc_buf = try arena_alloc.alloc(u8, desc_len);
    try reader.readNoEof(desc_buf);

    const ntype: NodeType = @enumFromInt(type_byte);
    const nid: NodeId = @intCast(graph.nodes.items.len);

    try graph.nodes.append(graph.alloc, .{
        .id = nid,
        .name = name_buf,
        .node_type = ntype,
        .desc = desc_buf,
        .is_active = (active_byte == 1),
    });

    try graph.out_adj.append(graph.alloc, .empty);
    try graph.in_adj.append(graph.alloc, .empty);
    try graph.name_to_node.put(graph.alloc, name_buf, nid);
    if (active_byte == 1) graph.active_node_count += 1;
}

fn readBinaryEdge(reader: anytype, graph: *Graph) !void {
    // PSEUDOCODE:
    // 1. Read edge endpoints, relation type, active status, weight
    // 2. Read optional string attributes from arena
    // 3. Append EdgeRecord and update adjacency lists and edge lookup map
    _ = try reader.readInt(u32, .little); // id
    const src = try reader.readInt(u32, .little);
    const dst = try reader.readInt(u32, .little);
    const rel_byte = try reader.readInt(u8, .little);
    const active_byte = try reader.readInt(u8, .little);
    const weight_u32 = try reader.readInt(u32, .little);
    const weight: f32 = @bitCast(weight_u32);

    const arena_alloc = graph.arena.allocator();
    const str_id = try readOptString(arena_alloc, reader);
    const condition = try readOptString(arena_alloc, reader);
    const guidance = try readOptString(arena_alloc, reader);
    const pitfalls = try readOptString(arena_alloc, reader);
    const supersedes = try readOptString(arena_alloc, reader);

    const eid: EdgeId = @intCast(graph.edges.items.len);
    const rel: RelationType = @enumFromInt(rel_byte);

    try graph.edges.append(graph.alloc, .{
        .id = eid,
        .str_id = str_id,
        .src = src,
        .dst = dst,
        .rel = rel,
        .attr = .{
            .condition = condition,
            .guidance = guidance,
            .pitfalls = pitfalls,
            .weight = weight,
            .supersedes = supersedes,
        },
        .is_active = (active_byte == 1),
    });

    if (src < graph.out_adj.items.len) {
        try graph.out_adj.items[src].append(graph.alloc, eid);
    }
    if (dst < graph.in_adj.items.len) {
        try graph.in_adj.items[dst].append(graph.alloc, eid);
    }
    if (str_id) |sid| {
        try graph.str_id_to_edge.put(graph.alloc, sid, eid);
    }
    if (active_byte == 1) graph.active_edge_count += 1;
}

/// Load Graph from compact binary snapshot format.
pub fn loadBinary(alloc: Allocator, reader: anytype) !Graph {
    // PSEUDOCODE:
    // 1. Validate MAGIC_PGBIN header
    // 2. Read node and edge counts
    // 3. Sequentially read nodes and edges into graph
    // 4. Return initialized graph
    var magic: [8]u8 = undefined;
    try reader.readNoEof(&magic);
    if (!std.mem.eql(u8, &magic, MAGIC_PGBIN)) {
        return error.InvalidMagic;
    }

    const node_count = try reader.readInt(u32, .little);
    const edge_count = try reader.readInt(u32, .little);

    var graph = Graph.init(alloc);
    errdefer graph.deinit();

    var i: u32 = 0;
    while (i < node_count) : (i += 1) {
        try readBinaryNode(reader, &graph);
    }

    i = 0;
    while (i < edge_count) : (i += 1) {
        try readBinaryEdge(reader, &graph);
    }

    return graph;
}

fn readOptString(alloc: Allocator, reader: anytype) !?[]const u8 {
    const len = try reader.readInt(u16, .little);
    if (len == 0) return null;
    const buf = try alloc.alloc(u8, len);
    try reader.readNoEof(buf);
    return buf;
}

fn applyAddNodeEvent(graph: *Graph, root: std.json.ObjectMap) !void {
    const node_obj_val = root.get("node") orelse return;
    if (node_obj_val != .object) return;
    const nobj = node_obj_val.object;

    const name_val = nobj.get("name") orelse return;
    if (name_val != .string) return;
    const name = name_val.string;

    const type_str = if (nobj.get("type")) |v| (if (v == .string) v.string else "custom") else "custom";
    const desc_str = if (nobj.get("desc")) |v| (if (v == .string) v.string else "") else "";

    const ntype = NodeType.fromString(type_str) orelse .custom;
    _ = try graph.addNode(name, ntype, desc_str);
}

fn applyAddEdgeEvent(graph: *Graph, root: std.json.ObjectMap) !void {
    const edge_obj_val = root.get("edge") orelse return;
    if (edge_obj_val != .object) return;
    const eobj = edge_obj_val.object;

    const src_val = eobj.get("src") orelse return;
    const dst_val = eobj.get("dst") orelse return;
    const rel_val = eobj.get("rel") orelse return;
    if (src_val != .string or dst_val != .string or rel_val != .string) return;

    const src_id = try graph.getOrAddNode(src_val.string, .tool_action, "");
    const dst_id = try graph.getOrAddNode(dst_val.string, .tool_action, "");
    const rel = RelationType.fromString(rel_val.string) orelse return;

    const str_id = if (root.get("id")) |v| (if (v == .string) v.string else null) else null;
    const supersedes = if (root.get("supersedes")) |v| (if (v == .string) v.string else null) else null;
    const cond = if (eobj.get("condition")) |v| (if (v == .string) v.string else null) else null;
    const guidance = if (eobj.get("guidance")) |v| (if (v == .string) v.string else null) else null;
    const pitfalls = if (eobj.get("pitfalls")) |v| (if (v == .string) v.string else null) else null;

    _ = try graph.addEdge(src_id, dst_id, rel, .{
        .condition = cond,
        .guidance = guidance,
        .pitfalls = pitfalls,
        .supersedes = supersedes,
    }, str_id);
}

/// Apply a single JSON event line.
/// Format examples:
/// - {"ev":"add_node","id":"pgn_1","node":{"name":"edit_code","type":"tool_action","desc":"Edit code"}}
/// - {"ev":"add_edge","id":"pge_1","edge":{"src":"edit_code","rel":"LEADS_TO","dst":"run_test_suite","condition":"...","guidance":"...","pitfalls":"..."}}
/// - {"ev":"delete_edge","id":"pge_1"}
pub fn applyEventJson(graph: *Graph, line: []const u8) !void {
    // PSEUDOCODE:
    // 1. Trim line; return if empty
    // 2. Parse JSON object; inspect "ev" property
    // 3. Dispatch to add_node, add_edge, or delete_edge handlers
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return;

    var parsed = std.json.parseFromSlice(std.json.Value, graph.alloc, trimmed, .{}) catch return error.InvalidJson;
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidJson;
    const root = parsed.value.object;

    const ev_val = root.get("ev") orelse return;
    if (ev_val != .string) return;
    const ev = ev_val.string;

    if (std.mem.eql(u8, ev, "add_node")) {
        try applyAddNodeEvent(graph, root);
    } else if (std.mem.eql(u8, ev, "add_edge")) {
        try applyAddEdgeEvent(graph, root);
    } else if (std.mem.eql(u8, ev, "delete_edge")) {
        if (root.get("id")) |v| {
            if (v == .string) {
                _ = graph.deleteEdgeByStrId(v.string);
            }
        }
    }
}
