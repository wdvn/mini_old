//! tools/artifact.zig — Tool for creating, reading, and managing Agent artifacts.
//!
//! Enables the Agent to output standalone work products (plans, walkthroughs,
//! diagrams, code diffs, html previews) to the session artifact directory and
//! automatically trigger real-time event hooks (Level D).

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../core/json.zig");
const artifacts = @import("../core/artifacts.zig");
const hooks = @import("../core/hooks.zig");

/// Tool artifact_write: Create or update an artifact.
/// Input: {"name":"...", "content":"...", "title":"...", "type":"markdown", "summary":"...", "user_facing":true}
pub fn writeTool(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    const name = (try json.findStringOwned(alloc, input_json, "name")) orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'name' parameter for artifact", .{});
    defer alloc.free(name);
    const content = (try json.findStringOwned(alloc, input_json, "content")) orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'content' parameter for artifact", .{});
    defer alloc.free(content);

    const title = json.findString(input_json, "title");
    const art_type = json.findString(input_json, "type") orelse "markdown";
    const summary = json.findString(input_json, "summary");

    // Check user_facing
    var user_facing = true;
    if (json.findString(input_json, "user_facing")) |uf| {
        if (std.mem.eql(u8, uf, "false")) user_facing = false;
    }

    // Write artifact file and update metadata
    const path = try artifacts.writeArtifact(alloc, io, name, title, content, art_type, summary, user_facing);
    defer alloc.free(path);

    // Dispatch real-time hook event (Level D: Live Preview / External UI)
    hooks.dispatch(alloc, io, .{
        .event = "artifact_saved",
        .artifact_name = name,
        .artifact_path = path,
        .artifact_type = art_type,
        .artifact_title = title orelse name,
    });

    return std.fmt.allocPrint(
        alloc,
        "Successfully saved artifact at: [{s}](file://{s})\nSession: {s} | Type: {s}",
        .{ name, path, artifacts.getSessionId(), art_type },
    );
}

/// Tool artifact_read: Read contents of a saved artifact.
/// Input: {"name":"..."}
pub fn readTool(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    const name = (try json.findStringOwned(alloc, input_json, "name")) orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'name' parameter", .{});
    defer alloc.free(name);

    return artifacts.readArtifact(alloc, io, name);
}

/// Tool artifact_list: List all artifacts in the current session.
/// Input: {}
pub fn listTool(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    _ = input_json;
    return artifacts.listArtifacts(alloc, io);
}
