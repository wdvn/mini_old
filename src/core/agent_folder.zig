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

/// Search for the `.agent/` directory upward from cwd to root.
/// If not found, automatically create `.agent/` in cwd and generate default .gitignore.
pub fn resolveOrInitAgentFolder(alloc: Allocator, io: std.Io, env_map: *const std.process.Environ.Map) !AgentFolder {
    const cwd_path = env_map.get("PWD") orelse return error.NoPwd;
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
            return AgentFolder{
                .alloc = alloc,
                .path = try alloc.dupe(u8, test_path),
            };
        }

        const parent = std.fs.path.dirname(current_dir);
        if (parent == null or std.mem.eql(u8, parent.?, current_dir)) {
            break;
        }
        current_dir = parent.?;
    }

    // If not found, create at cwd_path
    const agent_path = try std.fmt.allocPrint(alloc, "{s}/.agent", .{cwd_path});
    errdefer alloc.free(agent_path);

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, agent_path);
    
    // Create .gitignore
    const gitignore_path = try std.fmt.allocPrint(alloc, "{s}/.gitignore", .{agent_path});
    defer alloc.free(gitignore_path);

    const file = try cwd.createFile(io, gitignore_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "output/\n");

    main.stderrPrint("[agent_folder] Created configuration directory {s}\n", .{agent_path});

    return AgentFolder{
        .alloc = alloc,
        .path = agent_path,
    };
}
