//! core/task/store.zig — Persistent TaskStore (RFC-030).
//!
//! Append-only `tasks.jsonl` per project directory
//! (`~/.mini/tasks/<project_hash>/tasks.jsonl`), mirroring `plan/store.zig`
//! conventions: last line per `task_id` wins; `compact` folds the file to the
//! latest record per task id.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const utils = @import("../utils.zig");
const TaskRecord = types.TaskRecord;

/// Append-only task metadata store.
pub const TaskStore = struct {
    alloc: Allocator,
    /// Absolute path of tasks.jsonl (owned).
    file_path: []u8,
    /// Absolute path of the tasks base directory (owned).
    dir_path: []u8,

    /// Initializes the store at `base_dir`, creating the directory and an
    /// empty tasks.jsonl if needed.
    pub fn init(alloc: Allocator, io: std.Io, base_dir: []const u8) !TaskStore {
        // PSEUDOCODE:
        // 1. Ensure base dir exists
        // 2. Join file path "<base>/tasks.jsonl"
        // 3. Create empty file if missing
        const dir_dup = try alloc.dupe(u8, base_dir);
        errdefer alloc.free(dir_dup);
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(io, dir_dup) catch {};
        const file_path = try std.fs.path.join(alloc, &.{ dir_dup, "tasks.jsonl" });
        errdefer alloc.free(file_path);
        if (cwd.openFile(io, file_path, .{})) |f| {
            f.close(io);
        } else |err| {
            if (err == error.FileNotFound) {
                const f = try cwd.createFile(io, file_path, .{});
                f.close(io);
            } else {
                return err;
            }
        }
        return .{ .alloc = alloc, .file_path = file_path, .dir_path = dir_dup };
    }

    pub fn deinit(self: *TaskStore) void {
        self.alloc.free(self.file_path);
        self.alloc.free(self.dir_path);
    }

    /// Appends one JSON line for the record.
    pub fn append(self: *TaskStore, io: std.Io, rec: *const TaskRecord) !void {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.alloc);
        var aw = std.Io.Writer.Allocating.fromArrayList(self.alloc, &buf);
        try std.json.Stringify.value(rec, .{}, &aw.writer);
        buf = aw.toArrayList();
        try buf.append(self.alloc, '\n');

        const cwd = std.Io.Dir.cwd();
        const f = try cwd.openFile(io, self.file_path, .{ .mode = .read_write });
        defer f.close(io);
        // Zig 0.16: positional write to end-of-file for append semantics.
        const end_offset = try f.length(io);
        try f.writePositionalAll(io, buf.items, end_offset);
        try f.sync(io);
    }

    /// Reads the latest record for `task_id`, or null when absent.
    /// Caller owns the returned record (strings duped); free via `deinit`.
    pub fn readLatest(self: *TaskStore, alloc: Allocator, io: std.Io, task_id: []const u8) !?TaskRecord {
        const content = try self.readFileAlloc(io);
        defer self.alloc.free(content);

        var it = std.mem.splitScalar(u8, content, '\n');
        var found: ?TaskRecord = null;
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            const parsed = std.json.parseFromSlice(TaskRecord, self.alloc, trimmed, .{
                .ignore_unknown_fields = true,
            }) catch continue;
            defer parsed.deinit();
            if (std.mem.eql(u8, parsed.value.task_id, task_id)) {
                if (found) |*prev| prev.deinit(alloc);
                found = try dupRecord(alloc, parsed.value);
            }
        }
        return found;
    }

    // PSEUDOCODE:
    // 1. Read all lines from tasks.jsonl
    // 2. Parse TaskRecord and pick the record with the latest updated_at
    // 3. Return best record (owned by caller)
    pub fn readLatestResumable(self: *TaskStore, alloc: Allocator, io: std.Io) !?TaskRecord {
        const content = try self.readFileAlloc(io);
        defer self.alloc.free(content);

        var best: ?TaskRecord = null;
        var best_ts: i64 = 0;
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            const parsed = std.json.parseFromSlice(TaskRecord, self.alloc, trimmed, .{
                .ignore_unknown_fields = true,
            }) catch continue;
            defer parsed.deinit();
            if (parsed.value.updated_at >= best_ts) {
                if (best) |*prev| prev.deinit(alloc);
                best = try dupRecord(alloc, parsed.value);
                best_ts = parsed.value.updated_at;
            }
        }
        return best;
    }

    /// Folds the file to the latest record per task_id (keeps file order).
    pub fn compact(self: *TaskStore, io: std.Io) !void {
        const content = try self.readFileAlloc(io);
        defer self.alloc.free(content);

        // PSEUDOCODE:
        // 1. Parse all lines; keep latest record per task_id in encounter order
        // 2. Rewrite the file atomically (tmp file + rename)
        var latest = std.StringHashMapUnmanaged(usize).empty;
        defer {
            var kit = latest.keyIterator();
            while (kit.next()) |k| self.alloc.free(k.*);
            latest.deinit(self.alloc);
        }
        var records = std.ArrayListUnmanaged(TaskRecord).empty;
        defer {
            for (records.items) |*rec| rec.deinit(self.alloc);
            records.deinit(self.alloc);
        }

        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            const parsed = std.json.parseFromSlice(TaskRecord, self.alloc, trimmed, .{
                .ignore_unknown_fields = true,
            }) catch continue;
            defer parsed.deinit();
            const dup = try dupRecord(self.alloc, parsed.value);
            if (latest.get(dup.task_id)) |idx| {
                records.items[idx].deinit(self.alloc);
                records.items[idx] = dup;
            } else {
                try latest.put(self.alloc, try self.alloc.dupe(u8, dup.task_id), records.items.len);
                try records.append(self.alloc, dup);
            }
        }

        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.alloc);
        for (records.items) |*rec| {
            var aw = std.Io.Writer.Allocating.fromArrayList(self.alloc, &out);
            try std.json.Stringify.value(rec, .{}, &aw.writer);
            out = aw.toArrayList();
            try out.append(self.alloc, '\n');
        }

        const tmp_path = try std.fmt.allocPrint(self.alloc, "{s}.tmp", .{self.file_path});
        defer self.alloc.free(tmp_path);
        const cwd = std.Io.Dir.cwd();
        {
            const f = try cwd.createFile(io, tmp_path, .{});
            defer f.close(io);
            try f.writeStreamingAll(io, out.items);
            try f.sync(io);
        }
        try cwd.rename(tmp_path, cwd, self.file_path, io);
    }

    fn readFileAlloc(self: *TaskStore, io: std.Io) ![]u8 {
        const cwd = std.Io.Dir.cwd();
        const f = try cwd.openFile(io, self.file_path, .{});
        defer f.close(io);
        const stat_size = try f.length(io);
        const buf = try self.alloc.alloc(u8, @intCast(stat_size));
        const n = try utils.readAll(io, f, buf);
        return buf[0..n];
    }

    fn dupRecord(alloc: Allocator, rec: TaskRecord) !TaskRecord {
        var out = rec;
        out.task_id = try alloc.dupe(u8, rec.task_id);
        errdefer alloc.free(out.task_id);
        out.title = try alloc.dupe(u8, rec.title);
        return out;
    }
};
