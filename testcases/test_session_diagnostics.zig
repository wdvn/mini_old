//! test_session_diagnostics.zig — Unit tests for session listing and diagnostics telemetry.

const std = @import("std");
const testing = std.testing;
const mini = @import("mini");
const session_diag = mini.session_diagnostics;

test "session_diagnostics: listSessions returns non-empty result" {
    const alloc = testing.allocator;
    const result = try session_diag.listSessions(alloc, testing.io);
    defer alloc.free(result);

    try testing.expect(result.len > 0);
    try testing.expect(std.mem.indexOf(u8, result, "Sessions & Subprocesses List") != null);
}

test "session_diagnostics: executeTool operation=list and invalid op handling" {
    const alloc = testing.allocator;
    const res_list = try session_diag.executeTool(alloc, testing.io, "{\"operation\":\"list\"}");
    defer alloc.free(res_list);
    try testing.expect(std.mem.indexOf(u8, res_list, "Sessions & Subprocesses List") != null);

    const res_invalid = try session_diag.executeTool(alloc, testing.io, "{\"operation\":\"unknown_op\"}");
    defer alloc.free(res_invalid);
    try testing.expect(std.mem.indexOf(u8, res_invalid, "Error: invalid operation") != null);
}

test "session_diagnostics: detail of current process" {
    const alloc = testing.allocator;
    const my_pid: i32 = @intCast(std.os.linux.getpid());
    const input = try std.fmt.allocPrint(alloc, "{{\"operation\":\"detail\",\"pid\":{d}}}", .{my_pid});
    defer alloc.free(input);
    const res = try session_diag.executeTool(alloc, testing.io, input);
    defer alloc.free(res);

    // Should not crash, returns non-empty output
    try testing.expect(res.len > 0);
}

test "session_diagnostics: analyzeJournal parses throttling and errors accurately without leaks" {
    const alloc = testing.allocator;
    const test_journal_path = "/tmp/test_session_diag_journal.jsonl";
    const f = try std.Io.Dir.cwd().createFile(testing.io, test_journal_path, .{});
    const sample_content =
        \\{"act_id":1,"event_type":"act_started","timestamp":1788919924527,"description":"Act started","delta":null,"error_detail":null}
        \\{"act_id":1,"event_type":"llm_call_throttled","timestamp":1788919925568,"description":"Rate limit (429) from backend","delta":null,"error_detail":{"backend":"openai-compat","model":"nex-agi/nex-n2.5-mini:free","error_name":"LLMRateLimitExceeded","http_code":429,"attempt":1,"server_error":"Rate limit exceeded: free-models-per-day","remedy_hint":"Wait for the daily reset"}}
        \\
    ;
    try f.writeStreamingAll(testing.io, sample_content);
    f.close(testing.io);
    defer std.Io.Dir.cwd().deleteFile(testing.io, test_journal_path) catch {};

    const summary = try session_diag.analyzeJournal(alloc, testing.io, test_journal_path, 9999999);
    try testing.expectEqualStrings("llm_call_throttled", summary.lastEvent());
    try testing.expectEqual(@as(usize, 1), summary.last_act_id);
    try testing.expectEqual(@as(usize, 1), summary.error_count);
    try testing.expectEqual(@as(u32, 429), summary.last_error_code);
    try testing.expectEqualStrings("LLMRateLimitExceeded", summary.lastErrorName());
    try testing.expectEqualStrings("Rate limit exceeded: free-models-per-day", summary.lastErrorMessage());
    try testing.expect(summary.state == .crashed or summary.state == .finished);
}

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

test "session_diagnostics: detailSession formats a hermetic session cleanly" {
    const alloc = testing.allocator;

    // Hermetic: point MINI_HOME to temporary directory and generate journal for the test process PID
    const saved_mini_home: ?[:0]const u8 = if (getenv("MINI_HOME")) |mh|
        try alloc.dupeZ(u8, std.mem.span(mh))
    else
        null;
    defer if (saved_mini_home) |mh| alloc.free(mh);

    var tmp_buf: [64]u8 = undefined;
    const tmp_dir = try std.fmt.bufPrintZ(&tmp_buf, "/tmp/mini_diag_test_{d}", .{std.os.linux.getpid()});
    var sess_buf: [128]u8 = undefined;
    const sess_dir = try std.fmt.bufPrint(&sess_buf, "{s}/sessions", .{tmp_dir});
    std.Io.Dir.cwd().createDirPath(testing.io, sess_dir) catch {};
    _ = setenv("MINI_HOME", tmp_dir.ptr, 1);
    defer {
        _ = setenv("MINI_HOME", if (saved_mini_home) |mh| mh.ptr else "", 1);
        std.Io.Dir.cwd().deleteTree(testing.io, tmp_dir) catch {};
    }

    const my_pid: i32 = @intCast(std.os.linux.getpid());
    var path_buf: [256]u8 = undefined;
    const journal_path = try std.fmt.bufPrint(&path_buf, "{s}/sessions/journal_{d}.jsonl", .{ tmp_dir, my_pid });

    const sample_content =
        \\{"act_id":1,"event_type":"act_started","timestamp":1788919924527,"description":"Act started","delta":null,"error_detail":null}
        \\{"act_id":1,"event_type":"llm_call_throttled","timestamp":1788919925568,"description":"Rate limit (429) from backend","delta":null,"error_detail":{"backend":"openai-compat","model":"test-model","error_name":"LLMRateLimitExceeded","http_code":429,"attempt":1,"server_error":"Rate limit exceeded","remedy_hint":"Wait"}}
        \\
    ;
    const f = try std.Io.Dir.cwd().createFile(testing.io, journal_path, .{});
    try f.writeStreamingAll(testing.io, sample_content);
    f.close(testing.io);

    const report = try session_diag.detailSession(alloc, testing.io, my_pid);
    defer alloc.free(report);

    try testing.expect(report.len > 0);
    try testing.expect(std.mem.indexOf(u8, report, "Session Diagnostic Report PID") != null);
    try testing.expect(std.mem.indexOf(u8, report, "throttled") != null or
        std.mem.indexOf(u8, report, "crashed") != null or
        std.mem.indexOf(u8, report, "finished") != null);
    try testing.expect(std.mem.indexOf(u8, report, "HTTP 429") != null);
    try testing.expect(std.mem.indexOf(u8, report, "Thinking Profile") != null);
}

test "session_diagnostics: computeThinkingProfile computes percentiles, retries, and slowest acts correctly" {
    const alloc = testing.allocator;

    const fixture =
        \\{"act_id":1,"event_type":"act_started","timestamp":1000}
        \\{"act_id":1,"event_type":"llm_generation_ended","timestamp":11000}
        \\{"act_id":1,"event_type":"act_completed","timestamp":11100,"delta":{"act_id":1,"response_validity":"final_text","attempt":1}}
        \\{"act_id":2,"event_type":"act_started","timestamp":20000}
        \\{"act_id":2,"event_type":"llm_generation_ended","timestamp":90000}
        \\{"act_id":2,"event_type":"act_completed","timestamp":90100,"delta":{"act_id":2,"response_validity":"thinking_only","attempt":2}}
        \\{"act_id":3,"event_type":"act_started","timestamp":100000}
        \\{"act_id":3,"event_type":"llm_generation_ended","timestamp":105000}
        \\{"act_id":3,"event_type":"act_completed","timestamp":105100,"delta":{"act_id":3,"response_validity":"codeact","attempt":1}}
        \\
    ;

    const profile = try session_diag.computeThinkingProfile(alloc, fixture);
    try testing.expectEqual(@as(usize, 3), profile.total_acts);
    try testing.expectEqual(@as(usize, 1), profile.thinking_only_count);
    try testing.expectEqual(@as(usize, 1), profile.retry_acts_count);
    try testing.expectEqual(@as(usize, 1), profile.acts_over_60s); // act 2 is 70s (>60s)

    // Latencies: act 1 = 10s, act 2 = 70s, act 3 = 5s.
    // Sorted: 5s, 10s, 70s
    // p50 (idx 1): 10.0s, max: 70.0s
    try testing.expectEqual(@as(f64, 70.0), profile.max_s);
    try testing.expectEqual(@as(f64, 10.0), profile.p50_s);

    // Top slowest acts
    try testing.expectEqual(@as(usize, 3), profile.slowest_count);
    try testing.expectEqual(@as(usize, 2), profile.slowest_acts[0].act_id);
    try testing.expectEqual(@as(f64, 70.0), profile.slowest_acts[0].duration_s);
    try testing.expectEqual(@as(usize, 1), profile.slowest_acts[1].act_id);
    try testing.expectEqual(@as(f64, 10.0), profile.slowest_acts[1].duration_s);
    try testing.expectEqual(@as(usize, 3), profile.slowest_acts[2].act_id);
    try testing.expectEqual(@as(f64, 5.0), profile.slowest_acts[2].duration_s);
}

