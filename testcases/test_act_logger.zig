const std = @import("std");
const testing = std.testing;
const mini = @import("mini");
const act_logger = mini.act_logger_mod;
const proto = mini.protocol_mod;

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn unsetenv(name: [*:0]const u8) c_int;

test "act_logger: logAct writes full JSON to act_<pid>_<act_id>.json" {
    const alloc = testing.allocator;
    const io = testing.io;

    const test_dir = "/tmp/test_mini_acts_log";
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, test_dir) catch {};
    defer cwd.deleteTree(io, test_dir) catch {};

    var logger = try act_logger.ActLogger.init(alloc, io, test_dir);
    defer logger.deinit();

    const data = act_logger.ActDebugData{
        .session_pid = 99999,
        .act_id = 1,
        .timestamp = 1234567890,
        .backend_name = "openai-compat",
        .backend_model = "gpt-5.6-luna",
        .system_prompt = "You are a helpful assistant.",
        .messages_count = 1,
        .input_messages = &.{},
        .tool_definitions = &.{},
        .llm_response = .{
            .http_code = 200,
            .stop_reason = "end_turn",
            .text = "Hello world!",
            .thinking = "Let me think...",
            .js_code = "console.log('hi');",
            .tool_calls = null,
            .usage = .{ .prompt_tokens = 10, .completion_tokens = 20, .total_tokens = 30 },
            .raw_debug_info = null,
        },
        .execution = .{
            .exec_type = "codeact",
            .stdout = "hi\n",
            .return_value_json = null,
            .is_error = false,
            .duration_ms = 15,
            .error_message = null,
        },
        .snapshots = &.{},
    };

    try logger.logAct(io, data);

    // Verify file was created
    const file_path = "/tmp/test_mini_acts_log/act_99999_1.json";
    const file = try cwd.openFile(io, file_path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    try testing.expect(stat.size > 0);

    const buf = try alloc.alloc(u8, @intCast(stat.size));
    defer alloc.free(buf);
    _ = try file.readStreaming(io, &.{buf});

    try testing.expect(std.mem.indexOf(u8, buf, "\"session_pid\": 99999") != null);
    try testing.expect(std.mem.indexOf(u8, buf, "\"act_id\": 1") != null);
    try testing.expect(std.mem.indexOf(u8, buf, "\"backend_model\": \"gpt-5.6-luna\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf, "\"thinking\": \"Let me think...\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf, "\"stdout\": \"hi\\n\"") != null);
}

test "act_logger: pruneOldActs retains at most N newest files" {
    const alloc = testing.allocator;
    const io = testing.io;

    const test_dir = "/tmp/test_mini_acts_prune";
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, test_dir) catch {};
    defer cwd.deleteTree(io, test_dir) catch {};

    try cwd.createDirPath(io, test_dir);

    // Create 10 files act_0_1.json through act_0_10.json
    var i: usize = 1;
    while (i <= 10) : (i += 1) {
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "act_0_{d}.json", .{i});
        const full_path = try std.fs.path.join(alloc, &.{ test_dir, name });
        defer alloc.free(full_path);

        const f = try cwd.createFile(io, full_path, .{});
        try f.writeStreamingAll(io, "{}");
        f.close(io);

        // Sleep 2ms to create mtime difference
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2), .awake) catch {};
    }

    _ = setenv("MINI_ACTS_KEEP", "3", 1);
    defer _ = unsetenv("MINI_ACTS_KEEP");

    act_logger.ActLogger.pruneOldActs(alloc, io, test_dir);

    // Verify remaining file count
    var dir = try cwd.openDir(io, test_dir, .{ .iterate = true });
    defer dir.close(io);

    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file and std.mem.startsWith(u8, entry.name, "act_")) {
            count += 1;
        }
    }

    try testing.expectEqual(@as(usize, 3), count);
}
