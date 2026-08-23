//! agent_folder.zig — Quản lý thư mục `.agent/` trong workspace
//! Triển khai RFC-005

const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");
const main = @import("../main.zig");

pub const AgentFolder = struct {
    alloc: Allocator,
    path: []const u8, // Đường dẫn tuyệt đối đến thư mục `.agent/`

    pub fn deinit(self: *AgentFolder) void {
        self.alloc.free(self.path);
    }
};

/// Tìm thư mục `.agent/` từ cwd đi lên dần đến root.
/// Nếu không thấy, tự động tạo `.agent/` ở cwd và tạo .gitignore mặc định.
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

    // Không tìm thấy thì tạo ở cwd_path
    const agent_path = try std.fmt.allocPrint(alloc, "{s}/.agent", .{cwd_path});
    errdefer alloc.free(agent_path);

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, agent_path);
    
    // Tạo .gitignore
    const gitignore_path = try std.fmt.allocPrint(alloc, "{s}/.gitignore", .{agent_path});
    defer alloc.free(gitignore_path);

    const file = try cwd.createFile(io, gitignore_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "output/\n");

    main.stderrPrint("[agent_folder] Đã tạo thư mục cấu hình {s}\n", .{agent_path});

    return AgentFolder{
        .alloc = alloc,
        .path = agent_path,
    };
}
