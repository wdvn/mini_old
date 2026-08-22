//! journal.zig — Act Journal
//! Durable Write-Ahead Log (WAL) cho Event-Driven Act Architecture.

const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");

pub const ActEventType = enum {
    act_started,
    act_completed,
    act_failed,
    llm_call_throttled,
    llm_provider_error,
    llm_output_malformed,
    llm_context_overflow,
    rollback_requested,
    rollback_completed,
    task_completed,
};

pub const FileSnapshot = struct {
    path: []const u8,
    /// Hash của nội dung cũ trong CAS. Null nếu file chưa tồn tại (mới tạo).
    previous_content_hash: ?[]const u8,
};

pub const StateDelta = struct {
    act_id: usize,
    /// File snapshot (để rollback).
    file_snapshots: []const FileSnapshot,
};

pub const ActEvent = struct {
    act_id: usize,
    event_type: ActEventType,
    timestamp: i64,
    description: []const u8,
    delta: ?StateDelta = null,
};

pub const ActJournal = struct {
    alloc: Allocator,
    file_path: []const u8,

    pub fn init(alloc: Allocator, io: std.Io, file_path: []const u8) !ActJournal {
        const path_dup = try alloc.dupe(u8, file_path);
        
        // Đảm bảo thư mục cha tồn tại
        if (std.fs.path.dirname(path_dup)) |dir| {
            const cwd = std.Io.Dir.cwd();
            cwd.createDirPath(io, dir) catch {};
        }

        // Tạo file rỗng nếu chưa tồn tại
        const cwd = std.Io.Dir.cwd();
        if (cwd.openFile(io, path_dup, .{})) |file| {
            file.close(io);
        } else |err| {
            if (err == error.FileNotFound) {
                const file = try cwd.createFile(io, path_dup, .{});
                file.close(io);
            } else {
                return err;
            }
        }

        return .{
            .alloc = alloc,
            .file_path = path_dup,
        };
    }

    pub fn deinit(self: *ActJournal) void {
        self.alloc.free(self.file_path);
    }

    /// Ghi sự kiện vào file JSONL và fsync.
    pub fn recordEvent(self: *ActJournal, io: std.Io, act_id: usize, event_type: ActEventType, desc: []const u8) !void {
        try self.appendEvent(io, .{
            .act_id = act_id,
            .event_type = event_type,
            .timestamp = utils.milliTimestamp(),
            .description = desc,
        });
    }

    /// Ghi nhận Act hoàn thành và kèm theo StateDelta.
    pub fn recordActComplete(self: *ActJournal, io: std.Io, act_id: usize, delta: StateDelta) !void {
        try self.appendEvent(io, .{
            .act_id = act_id,
            .event_type = .act_completed,
            .timestamp = utils.milliTimestamp(),
            .description = "Hoàn thành Act",
            .delta = delta,
        });
    }

    fn appendEvent(self: *ActJournal, io: std.Io, event: ActEvent) !void {
        var out_buf = std.ArrayList(u8).empty;
        defer out_buf.deinit(self.alloc);
        var aw = std.Io.Writer.Allocating.fromArrayList(self.alloc, &out_buf);
        
        try std.json.Stringify.value(event, .{}, &aw.writer);
        try aw.writer.writeByte('\n');
        
        out_buf = aw.toArrayList();

        // Mở file ở chế độ read_write để append
        // Trên hệ điều hành Unix, ghi vào cuối file có thể được mô phỏng bằng seek.
        // Dùng `cwd.openFile` thuần cho an toàn vì fsync cũng block thread anyway.
        const cwd = std.Io.Dir.cwd();
        const file = try cwd.openFile(io, self.file_path, .{ .mode = .read_write });
        defer file.close(io);
        
        // Zig 0.16: Io.File không còn seek/writeAll trực tiếp.
        // Lấy offset cuối file rồi ghi positional, đảm bảo append.
        const end_offset = try file.length(io);
        try file.writePositionalAll(io, out_buf.items, end_offset);
        try file.sync(io); // Đảm bảo ghi xuống đĩa (WAL fsync)
    }
};
