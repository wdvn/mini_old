//! process_manager.zig — Background job management for mini-agent.
//!
//! Provides background execution primitives following the OpenHands Pattern:
//!   - `spawnBackground(alloc, io, command)`: run a command in the background, redirecting stdout/stderr to a log file
//!   - `getJobStatus(job_id)`: check process status (running, exitCode)
//!   - `readJobLogs(alloc, io, job_id, max_lines)`: read the most recent N log lines
//!   - `killJob(job_id, signal)`: safely stop a background process (killpg)

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const utils = @import("../core/utils.zig");

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
    child: std.process.Child,
    exit_code: ?i32 = null,
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

    /// Launch a background command and store job info.
    pub fn spawnBackground(self: *ProcessManager, io: std.Io, command: []const u8) !JobInfo {
        const now = utils.milliTimestamp();
        const job_id = try std.fmt.allocPrint(self.alloc, "job_{d}_{d}", .{ self.next_id, now });
        self.next_id += 1;

        var path_buf: [256]u8 = undefined;
        const log_path = try std.fmt.bufPrint(&path_buf, "/tmp/mini_{s}.log", .{job_id});
        const log_path_owned = try self.alloc.dupe(u8, log_path);

        // Build a shell command redirecting output to the log file
        var cmd_buf = utils.BufWriter.init(self.alloc);
        defer cmd_buf.deinit();

        try cmd_buf.print("{s} > {s} 2>&1", .{ command, log_path_owned });
        const shell_cmd = cmd_buf.list.items;

        const argv = [_][]const u8{ "/bin/sh", "-c", shell_cmd };
        // PSEUDOCODE:
        // 1. Start /bin/sh as the leader of a dedicated process group.
        // 2. Keep the Child handle so completed direct children can be reaped.
        const child = try std.process.spawn(io, .{
            .argv = &argv,
            .pgid = 0,
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
            .child = child,
        };

        try self.jobs.put(self.alloc, job_id, info);
        return info;
    }

    /// Check and reap a background job without blocking.
    pub fn getJobStatus(self: *ProcessManager, job_id: []const u8) ?JobStatus {
        const info = self.jobs.getPtr(job_id) orelse return null;
        const pid = info.pid;

        // PSEUDOCODE:
        // 1. Poll the direct child with waitpid(WNOHANG).
        // 2. Reap it when the shell exits and cache the termination result.
        // 3. Report cached completion instead of treating a zombie as running.
        if (info.child.id != null and comptime builtin.os.tag != .windows) {
            while (true) {
                var raw_status: c_int = 0;
                const result = std.c.waitpid(pid, &raw_status, std.c.W.NOHANG);
                switch (std.c.errno(result)) {
                    .INTR => continue,
                    .SUCCESS => {
                        if (result == 0) break;
                        const status: u32 = @intCast(raw_status);
                        info.child.id = null;
                        info.exit_code = if (std.c.W.IFEXITED(status))
                            @intCast(std.c.W.EXITSTATUS(status))
                        else
                            128 + @as(i32, @intCast(status & 0x7f));
                        break;
                    },
                    else => break,
                }
            }
        }

        return .{
            .running = info.child.id != null,
            .exit_code = info.exit_code,
            .pid = pid,
        };
    }

    /// Read at most `max_lines` recent log lines from the job's log file
    pub fn readJobLogs(self: *ProcessManager, io: std.Io, job_id: []const u8, max_lines: usize) ![]u8 {
        const info = self.jobs.get(job_id) orelse return error.JobNotFound;
        const cwd = std.Io.Dir.cwd();

        const file = cwd.openFile(io, info.log_path, .{}) catch |e| {
            if (e == error.FileNotFound) {
                return try std.fmt.allocPrint(self.alloc, "(Log file not created yet)", .{});
            }
            return e;
        };
        defer file.close(io);

        const stat = try file.stat(io);
        const file_size: usize = @intCast(stat.size);
        if (file_size == 0) {
            return try std.fmt.allocPrint(self.alloc, "(Empty log)", .{});
        }

        const buf = try self.alloc.alloc(u8, file_size);
        defer self.alloc.free(buf);

        const n = try utils.readAll(io, file, buf);
        const content = buf[0..n];

        if (max_lines == 0) {
            return try self.alloc.dupe(u8, content);
        }

        // Count and take the last N lines
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

    /// Signal every running background process group.
    pub fn forceKillAllJobs(self: *ProcessManager, signal: ?[]const u8) bool {
        // PSEUDOCODE:
        // 1. Inspect each retained job without allocating or blocking.
        // 2. Signal every running process group through killJob.
        // 3. Return false only when an active group rejected the signal.
        var all_signaled = true;
        var values = self.jobs.valueIterator();
        while (values.next()) |info| {
            if (info.child.id == null) continue;
            if (!self.killJob(info.job_id, signal)) all_signaled = false;
        }
        return all_signaled;
    }

    /// Stop a background process group (SIGTERM, SIGINT, or SIGKILL).
    pub fn killJob(self: *ProcessManager, job_id: []const u8, signal: ?[]const u8) bool {
        const info = self.jobs.get(job_id) orelse return false;
        if (info.child.id == null) return false;
        const sig_num: c_int = if (signal) |s| blk: {
            if (std.mem.eql(u8, s, "SIGKILL") or std.mem.eql(u8, s, "9")) break :blk 9;
            if (std.mem.eql(u8, s, "SIGINT") or std.mem.eql(u8, s, "2")) break :blk 2;
            break :blk 15; // SIGTERM default
        } else 15;

        // PSEUDOCODE:
        // 1. Signal the dedicated process group so descendants terminate too.
        // 2. Fall back to the direct shell PID for non-POSIX or unusual cases.
        // 3. Leave non-blocking reaping to getJobStatus or a later status poll.
        if (comptime builtin.os.tag != .windows) {
            if (kill(-info.pid, sig_num) == 0) return true;
        }
        return kill(info.pid, sig_num) == 0;
    }
};

test "killJob terminates background descendants" {
    if (comptime @import("builtin").os.tag == .windows) return;

    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const pid_file = try std.fmt.allocPrint(
        alloc,
        "/tmp/mini_process_manager_child_{d}.pid",
        .{utils.milliTimestamp()},
    );
    defer alloc.free(pid_file);
    defer std.Io.Dir.cwd().deleteFile(io, pid_file) catch {};

    const command = try std.fmt.allocPrint(
        alloc,
        "sleep 30 & child=$!; printf '%s' \"$child\" > {s}; wait",
        .{pid_file},
    );
    defer alloc.free(command);

    var manager = ProcessManager.init(alloc);
    defer manager.deinit();

    const info = try manager.spawnBackground(io, command);
    var child_pid: i32 = 0;
    for (0..100) |_| {
        if (std.Io.Dir.cwd().openFile(io, pid_file, .{})) |file| {
            defer file.close(io);
            const stat = try file.stat(io);
            if (stat.size > 0) {
                const buf = try alloc.alloc(u8, @intCast(stat.size));
                defer alloc.free(buf);
                const n = try utils.readAll(io, file, buf);
                child_pid = try std.fmt.parseInt(i32, std.mem.trim(u8, buf[0..n], " \t\r\n"), 10);
                break;
            }
        } else |_| {}
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    }
    errdefer {
        if (child_pid > 0) {
            _ = kill(child_pid, 9);
            _ = kill(-child_pid, 9);
        }
    }
    try std.testing.expect(child_pid > 0);

    try std.testing.expect(manager.killJob(info.job_id, "SIGKILL"));

    var descendant_alive = true;
    var status_reports_running = true;
    for (0..100) |_| {
        descendant_alive = kill(child_pid, 0) == 0;
        if (manager.getJobStatus(info.job_id)) |status| {
            status_reports_running = status.running;
        }
        if (!descendant_alive and !status_reports_running) break;
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    }

    try std.testing.expect(!descendant_alive);
    try std.testing.expect(!status_reports_running);
}

test "forceKillAllJobs terminates every running background job" {
    if (comptime @import("builtin").os.tag == .windows) return;

    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var manager = ProcessManager.init(alloc);
    defer manager.deinit();

    const first = try manager.spawnBackground(io, "sleep 30");
    const second = try manager.spawnBackground(io, "sleep 30");

    try std.testing.expect(manager.forceKillAllJobs("SIGKILL"));

    for ([_]JobInfo{ first, second }) |info| {
        var running = true;
        for (0..100) |_| {
            const status = manager.getJobStatus(info.job_id) orelse return error.TestUnexpectedResult;
            running = status.running;
            if (!running) break;
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake) catch {};
        }
        try std.testing.expect(!running);
    }
}

test "getJobStatus reaps a completed background shell" {
    if (comptime @import("builtin").os.tag == .windows) return;

    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var manager = ProcessManager.init(alloc);
    defer manager.deinit();

    const info = try manager.spawnBackground(io, "exit 0");
    var running = true;
    for (0..100) |_| {
        const status = manager.getJobStatus(info.job_id) orelse return error.TestUnexpectedResult;
        running = status.running;
        if (!running) {
            try std.testing.expectEqual(@as(?i32, 0), status.exit_code);
            return;
        }
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    }

    try std.testing.expect(!running);
}

// Singleton process manager for runtime
var g_pm: ?ProcessManager = null;

pub fn getProcessManager(alloc: Allocator) *ProcessManager {
    if (g_pm == null) {
        g_pm = ProcessManager.init(alloc);
    }
    return &g_pm.?;
}

/// Stop all background jobs without initializing an unused singleton.
pub fn forceKillAllJobs(signal: ?[]const u8) bool {
    var pm = g_pm orelse return true;
    return pm.forceKillAllJobs(signal);
}

pub fn deinitGlobal() void {
    if (g_pm) |*pm| {
        pm.deinit();
        g_pm = null;
    }
}
