//! agent_folder.zig — Manage the `.agent/` directory in the workspace.
//! Implements RFC-005.

const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");
const main = @import("../main.zig");

pub const AgentFolder = struct {
    alloc: Allocator,
    path: []const u8, // Absolute path to `.agent/` directory

    pub fn deinit(self: *AgentFolder) void {
        self.alloc.free(self.path);
    }
};

fn findAgentFolderUpward(alloc: Allocator, io: std.Io, cwd_path: []const u8) !?[]u8 {
    // PSEUDOCODE:
    // 1. Traverse upwards from cwd_path checking for .agent directory.
    // 2. Return duped path if found, or null if root reached.
    var current_dir: []const u8 = cwd_path;
    while (true) {
        const test_path = try std.fmt.allocPrint(alloc, "{s}/.agent", .{current_dir});
        defer alloc.free(test_path);

        const cwd = std.Io.Dir.cwd();
        var is_dir = false;
        if (cwd.openDir(io, test_path, .{})) |*d| {
            d.close(io);
            is_dir = true;
        } else |_| {}

        if (is_dir) {
            return try alloc.dupe(u8, test_path);
        }

        const parent = std.fs.path.dirname(current_dir) orelse break;
        if (std.mem.eql(u8, parent, current_dir)) break;
        current_dir = parent;
    }
    return null;
}

fn createDefaultAgentFolder(alloc: Allocator, io: std.Io, cwd_path: []const u8) ![]u8 {
    // PSEUDOCODE:
    // 1. Create .agent directory in cwd_path.
    // 2. Generate default .gitignore ignoring output/.
    // 3. Return allocated path.
    const agent_path = try std.fmt.allocPrint(alloc, "{s}/.agent", .{cwd_path});
    errdefer alloc.free(agent_path);

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, agent_path);

    const gitignore_path = try std.fmt.allocPrint(alloc, "{s}/.gitignore", .{agent_path});
    defer alloc.free(gitignore_path);

    const file = try cwd.createFile(io, gitignore_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "output/\n");

    main.stderrPrint("[agent_folder] Created configuration directory {s}\n", .{agent_path});
    return agent_path;
}

/// Search for the `.agent/` directory upward from cwd to root.
/// If not found, automatically create `.agent/` in cwd and generate default .gitignore.
pub fn resolveOrInitAgentFolder(alloc: Allocator, io: std.Io, env_map: *const std.process.Environ.Map) !AgentFolder {
    // PSEUDOCODE:
    // 1. Get PWD from env_map.
    // 2. Look for existing .agent upwards; if found, return it.
    // 3. Otherwise create default .agent in cwd and return.
    const cwd_path = env_map.get("PWD") orelse return error.NoPwd;
    if (try findAgentFolderUpward(alloc, io, cwd_path)) |path| {
        return AgentFolder{ .alloc = alloc, .path = path };
    }
    const agent_path = try createDefaultAgentFolder(alloc, io, cwd_path);
    return AgentFolder{ .alloc = alloc, .path = agent_path };
}
