//! act_logger.zig — Act debug logger for session replay & diagnostics.
//! Stores detailed state for each Act in ~/.mini/acts/
//! to aid in reproduction, debugging, and incident analysis.

const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("protocol.zig");
const utils = @import("utils.zig");
const journal = @import("journal.zig");

pub const ActExecutionInfo = struct {
    exec_type: []const u8 = "none", // "codeact", "tool_call", "none"
    stdout: ?[]const u8 = null,
    return_value_json: ?[]const u8 = null,
    is_error: bool = false,
    duration_ms: u64 = 0,
    error_message: ?[]const u8 = null,
};

pub const ActLlmResponseInfo = struct {
    http_code: u32 = 0,
    stop_reason: []const u8 = "missing_terminal_event",
    generation_stop: []const u8 = "unknown",
    response_validity: []const u8 = "empty",
    agent_decision: []const u8 = "request_continuation",
    recovery_class: ?[]const u8 = null,
    attempt: usize = 1,
    text: ?[]const u8 = null,
    thinking: ?[]const u8 = null,
    js_code: ?[]const u8 = null,
    tool_calls: ?[]const proto.ToolUse = null,
    usage: proto.Usage = .{},
    raw_debug_info: ?[]const u8 = null,
};

pub const ActSnapshotInfo = struct {
    path: []const u8,
    previous_content_hash: ?[]const u8 = null,
};

pub const ActDebugData = struct {
    session_pid: u32,
    act_id: usize,
    timestamp: i64,
    backend_name: []const u8,
    backend_model: []const u8,
    system_prompt: []const u8,
    messages_count: usize,
    input_messages: []const proto.Message,
    tool_definitions: []const proto.ToolDefinition,
    llm_response: ActLlmResponseInfo,
    execution: ActExecutionInfo,
    snapshots: []const ActSnapshotInfo,
};

pub const ActLogger = struct {
    alloc: Allocator,
    acts_dir: []const u8,

    pub const default_max_act_files: usize = 100;

    pub fn init(alloc: Allocator, io: std.Io, acts_dir: []const u8) !ActLogger {
        const path_dup = try alloc.dupe(u8, acts_dir);
        errdefer alloc.free(path_dup);

        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(io, path_dup) catch {};

        // Prune old acts during initialization
        pruneOldActs(alloc, io, path_dup);

        return .{
            .alloc = alloc,
            .acts_dir = path_dup,
        };
    }

    pub fn deinit(self: *ActLogger) void {
        self.alloc.free(self.acts_dir);
    }

    /// Write detailed Act log to file ~/.mini/acts/act_<pid>_<act_id>_<attempt>.json
    pub fn logAct(self: *ActLogger, io: std.Io, data: ActDebugData) !void {
        var file_name_buf: [128]u8 = undefined;
        const file_name = std.fmt.bufPrint(&file_name_buf, "act_{d}_{d}_{d}.json", .{ data.session_pid, data.act_id, data.llm_response.attempt }) catch return;

        const full_path = try std.fs.path.join(self.alloc, &.{ self.acts_dir, file_name });
        defer self.alloc.free(full_path);

        var out_buf = std.ArrayList(u8).empty;
        defer out_buf.deinit(self.alloc);
        var aw = std.Io.Writer.Allocating.fromArrayList(self.alloc, &out_buf);

        try std.json.Stringify.value(data, .{ .whitespace = .indent_2 }, &aw.writer);
        try aw.writer.writeByte('\n');
        out_buf = aw.toArrayList();

        const cwd = std.Io.Dir.cwd();
        const file = try cwd.createFile(io, full_path, .{});
        defer file.close(io);

        try file.writeStreamingAll(io, out_buf.items);
        try file.sync(io);
    }

    /// Prune `act_*.json` files in the acts directory, keeping the N newest files by mtime.
    pub fn pruneOldActs(alloc: Allocator, io: std.Io, dir_path: []const u8) void {
        const cwd = std.Io.Dir.cwd();
        var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(io);

        const max_keep = blk: {
            const s = utils.getEnvSlice("MINI_ACTS_KEEP") orelse utils.getEnvSlice("MINI_ACT_KEEP") orelse break :blk default_max_act_files;
            const v = std.fmt.parseInt(usize, s, 10) catch break :blk default_max_act_files;
            break :blk if (v == 0) default_max_act_files else v;
        };

        const Item = struct { name: []u8, mtime_ns: i96 };
        var items: std.ArrayList(Item) = .empty;
        defer {
            for (items.items) |it_| alloc.free(it_.name);
            items.deinit(alloc);
        }

        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.startsWith(u8, entry.name, "act_") or !std.mem.endsWith(u8, entry.name, ".json")) continue;
            const name_dup = alloc.dupe(u8, entry.name) catch continue;
            const mtime_ns: i96 = blk2: {
                const st = dir.statFile(io, entry.name, .{}) catch {
                    alloc.free(name_dup);
                    continue;
                };
                break :blk2 st.mtime.nanoseconds;
            };
            items.append(alloc, .{ .name = name_dup, .mtime_ns = mtime_ns }) catch {
                alloc.free(name_dup);
                continue;
            };
        }

        if (items.items.len <= max_keep) return;

        // Sort descending by mtime (newest first)
        std.mem.sort(Item, items.items, {}, struct {
            fn lt(_: void, a: Item, b: Item) bool {
                return a.mtime_ns > b.mtime_ns;
            }
        }.lt);

        for (items.items[max_keep..]) |old| {
            dir.deleteFile(io, old.name) catch {};
        }
    }
};
