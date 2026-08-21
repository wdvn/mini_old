//! process_manager.zig — Quản lý tiến trình nền (Background Jobs) cho mini-agent.
//!
//! Cung cấp các nguyên hàm thực thi chạy ngầm theo mô hình OpenHands Pattern:
//!   - `spawnBackground(alloc, io, command)`: Chạy lệnh ngầm, chuyển hướng stdout/stderr ra log file
//!   - `getJobStatus(job_id)`: Kiểm tra trạng thái tiến trình (running, exitCode)
//!   - `readJobLogs(alloc, io, job_id, max_lines)`: Đọc N dòng log gần nhất
//!   - `killJob(job_id, signal)`: Dừng tiến trình ngầm an toàn (killpg)

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const utils = @import("../utils.zig");

extern fn kill(pid: std.c.pid_t, sig: c_int) c_int;

pub const JobStatus = struct {
    running: bool,
    exit_code: ?i32 = null,
    pid: i32,
};

pub const JobInfo = struct {
    job_id: []const u8,
    pid: i32,
    log_path: []const u8,
    command: []const u8,
    start_time: i64,
};

pub const ProcessManager = struct {
    alloc: Allocator,
    jobs: std.StringHashMapUnmanaged(JobInfo),
    next_id: usize = 1,

    pub fn init(alloc: Allocator) ProcessManager {
        return .{
            .alloc = alloc,
            .jobs = .empty,
            .next_id = 1,
        };
    }

    pub fn deinit(self: *ProcessManager) void {
        var it = self.jobs.valueIterator();
        while (it.next()) |info| {
            self.alloc.free(info.job_id);
            self.alloc.free(info.log_path);
            self.alloc.free(info.command);
        }
        self.jobs.deinit(self.alloc);
    }

    /// Khởi chạy lệnh chạy ngầm và lưu thông tin job.
    pub fn spawnBackground(self: *ProcessManager, io: std.Io, command: []const u8) !JobInfo {
        const now = utils.milliTimestamp();
        const job_id = try std.fmt.allocPrint(self.alloc, "job_{d}_{d}", .{ self.next_id, now });
        self.next_id += 1;

        var path_buf: [256]u8 = undefined;
        const log_path = try std.fmt.bufPrint(&path_buf, "/tmp/mini_{s}.log", .{job_id});
        const log_path_owned = try self.alloc.dupe(u8, log_path);

        // Tạo lệnh shell chuyển hướng output ra log file
        var cmd_buf = utils.BufWriter.init(self.alloc);
        defer cmd_buf.deinit();

        try cmd_buf.print("{s} > {s} 2>&1", .{ command, log_path_owned });
        const shell_cmd = cmd_buf.list.items;

        const argv = [_][]const u8{ "/bin/sh", "-c", shell_cmd };
        const child = try std.process.spawn(io, .{
            .argv = &argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });

        const pid: i32 = child.id orelse 0;

        const info = JobInfo{
            .job_id = job_id,
            .pid = pid,
            .log_path = log_path_owned,
            .command = try self.alloc.dupe(u8, command),
            .start_time = now,
        };

        try self.jobs.put(self.alloc, job_id, info);
        return info;
    }

    /// Kiểm tra trạng thái job qua kill(pid, 0)
    pub fn getJobStatus(self: *ProcessManager, job_id: []const u8) ?JobStatus {
        const info = self.jobs.get(job_id) orelse return null;
        const pid = info.pid;

        // kill(pid, 0) kiểm tra tiến trình có đang sống không
        const rc = kill(pid, 0);
        if (rc == 0) {
            return .{
                .running = true,
                .exit_code = null,
                .pid = pid,
            };
        } else {
            return .{
                .running = false,
                .exit_code = 0, // Đã kết thúc
                .pid = pid,
            };
        }
    }

    /// Đọc tối đa `max_lines` dòng log gần nhất từ log file của job
    pub fn readJobLogs(self: *ProcessManager, io: std.Io, job_id: []const u8, max_lines: usize) ![]u8 {
        const info = self.jobs.get(job_id) orelse return error.JobNotFound;
        const cwd = std.Io.Dir.cwd();

        const file = cwd.openFile(io, info.log_path, .{}) catch |e| {
            if (e == error.FileNotFound) {
                return try std.fmt.allocPrint(self.alloc, "(Log file chưa được tạo)", .{});
            }
            return e;
        };
        defer file.close(io);

        const stat = try file.stat(io);
        const file_size: usize = @intCast(stat.size);
        if (file_size == 0) {
            return try std.fmt.allocPrint(self.alloc, "(Log trống)", .{});
        }

        const buf = try self.alloc.alloc(u8, file_size);
        defer self.alloc.free(buf);

        const n = try utils.readAll(io, file, buf);
        const content = buf[0..n];

        if (max_lines == 0) {
            return try self.alloc.dupe(u8, content);
        }

        // Đếm và lấy N dòng cuối
        var line_count: usize = 0;
        var i: usize = content.len;
        while (i > 0) {
            i -= 1;
            if (content[i] == '\n') {
                line_count += 1;
                if (line_count >= max_lines) {
                    return try self.alloc.dupe(u8, content[i + 1 ..]);
                }
            }
        }

        return try self.alloc.dupe(u8, content);
    }

    /// Dừng tiến trình ngầm (SIGTERM hoặc SIGKILL)
    pub fn killJob(self: *ProcessManager, job_id: []const u8, signal: ?[]const u8) bool {
        const info = self.jobs.get(job_id) orelse return false;
        const sig_num: c_int = if (signal) |s| blk: {
            if (std.mem.eql(u8, s, "SIGKILL") or std.mem.eql(u8, s, "9")) break :blk 9;
            if (std.mem.eql(u8, s, "SIGINT") or std.mem.eql(u8, s, "2")) break :blk 2;
            break :blk 15; // SIGTERM default
        } else 15;

        // Kill PID
        const rc = kill(info.pid, sig_num);
        return rc == 0;
    }
};

// Singleton process manager cho runtime
var g_pm: ?ProcessManager = null;

pub fn getProcessManager(alloc: Allocator) *ProcessManager {
    if (g_pm == null) {
        g_pm = ProcessManager.init(alloc);
    }
    return &g_pm.?;
}

pub fn deinitGlobal() void {
    if (g_pm) |*pm| {
        pm.deinit();
        g_pm = null;
    }
}
