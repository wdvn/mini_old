//! journal.zig — Act Journal
//! Durable Write-Ahead Log (WAL) for Event-Driven Act Architecture.
//!
//! Retention: each process generates 1 `journal_<pid>.jsonl` file in the
//! sessions directory — `init` automatically prunes old files, retaining only the
//! `max_journal_files` newest files (override via `MINI_JOURNAL_KEEP` env var).

const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");
const json_mod = @import("json.zig");

// Zig 0.16: std.posix.getenv removed — extern libc getenv (build links libc),
// matching pattern in agent.zig / artifacts.zig.
extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn unsetenv(name: [*:0]const u8) c_int;

pub const ActEventType = enum {
    act_started,
    act_completed,
    act_failed,
    llm_generation_ended,
    llm_response_invalid,
    agent_decision,
    llm_call_throttled,
    llm_provider_error,
    llm_output_malformed,
    llm_context_overflow,
    rollback_requested,
    rollback_completed,
    task_completed,
    task_stalled,
    task_failed,
    task_interrupted,
    /// MemAct compaction completed (observable & reversible via Act model).
    memact_compacted,
    /// Progress Checkpoint & Recap created upon orbit/loop detection or act limit.
    checkpoint_created,
    /// Plan lifecycle phase transition (proposed → approved → executing → complete/rejected).
    plan_phase_changed,
    /// Step verification check outcome (passed/failed/timed_out/error).
    plan_step_verified,
    /// Two-stage review gate verdict (Critical/Important/Minor) on a
    /// subagent-executed plan step.
    plan_review_outcome,
    /// A skill was read into the conversation (tracked for post-compaction reinjection).
    skill_loaded,
    /// Plan/skill/task context re-injected after MemAct compaction.
    post_compact_reinject,
    /// Act generation latency exceeded slow turn threshold.
    act_generation_slow,
};

pub const FileSnapshot = struct {
    path: []const u8,
    /// Hash of previous content in CAS. Null if file did not exist (newly created).
    previous_content_hash: ?[]const u8,
};

/// Backend error details: sufficient context for future debugging from journal —
/// which backend/model, error details, HTTP code, attempt number, raw body (if any).
pub const ErrorDetail = struct {
    /// Backend name ("openai-compat" / "claude" / "ollama").
    backend: []const u8,
    /// Model invoked.
    model: []const u8,
    /// Zig error name (e.g. "LLMRateLimitExceeded").
    error_name: []const u8,
    /// HTTP status code (0 if not an HTTP error).
    http_code: u32 = 0,
    /// Attempt number in retry sequence (starting at 1).
    attempt: usize = 1,
    /// Raw body/response from server, truncated to avoid bloating journal.
    raw_snippet: ?[]const u8 = null,
    /// Server error message extracted from raw_snippet (e.g. "missing model").
    /// Helps distinguish real errors when Zig error_name is misleading
    /// (e.g. UnknownStopReason while server returned "missing model").
    /// Null when "message" cannot be parsed from raw body.
    server_error: ?[]const u8 = null,
};

pub const DeltaUsage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    reasoning_tokens: u64 = 0,
};

pub const StateDelta = struct {
    act_id: usize,
    /// File snapshot (for rollback).
    file_snapshots: []const FileSnapshot,
    /// LLM stop reason for this act (debugging loop/termination).
    stop_reason: ?[]const u8 = null,
    generation_stop: ?[]const u8 = null,
    response_validity: ?[]const u8 = null,
    agent_decision: ?[]const u8 = null,
    recovery_class: ?[]const u8 = null,
    attempt: usize = 1,
    /// Token usage telemetry for this act.
    usage: ?DeltaUsage = null,
    /// Active prompt context size in tokens.
    context_tokens: ?usize = null,
};

pub const ActEvent = struct {
    act_id: usize,
    event_type: ActEventType,
    timestamp: i64,
    description: []const u8,
    delta: ?StateDelta = null,
    /// Backend error details when event_type is an LLM/provider error.
    /// Null for other events to keep JSONL compact.
    error_detail: ?ErrorDetail = null,
};

pub const ActJournal = struct {
    alloc: Allocator,
    file_path: []const u8,
    /// Extension (subagent merge): parent agent journal path read from
    /// MINI_PARENT_JOURNAL env at init. Null if not set / empty / identical to file_path.
    /// Events are mirrored 1-level (direct write, non-recursive appendEvent).
    parent_path: ?[]u8 = null,

    pub fn init(alloc: Allocator, io: std.Io, file_path: []const u8) !ActJournal {
        const path_dup = try alloc.dupe(u8, file_path);

        // Ensure parent directory exists
        if (std.fs.path.dirname(path_dup)) |dir| {
            const cwd = std.Io.Dir.cwd();
            cwd.createDirPath(io, dir) catch {};
        }

        // Create empty file if not yet existing
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

        // Prune old journals immediately after creating new file for this process:
        // each process run generates 1 journal_<pid>.jsonl file -> without pruning,
        // sessions directory grows rapidly (spam). Keep N newest files.
        pruneOldJournals(alloc, io, path_dup);

        // Cache parent journal path (subagent merge). Only mirror when valid:
        // env exists, non-empty, and different from this journal (avoid self-loop).
        var parent_path: ?[]u8 = null;
        if (utils.getEnvSlice("MINI_PARENT_JOURNAL")) |pp| {
            if (pp.len > 0 and !std.mem.eql(u8, pp, path_dup)) {
                parent_path = try alloc.dupe(u8, pp);
            }
        }

        return .{
            .alloc = alloc,
            .file_path = path_dup,
            .parent_path = parent_path,
        };
    }

    /// Maximum journal files to retain (default 30, overridden by MINI_JOURNAL_KEEP).
    pub const default_max_journal_files: usize = 30;

    const JournalItem = struct { name: []u8, mtime_ns: i96 };

    fn resolveMaxJournalKeep() usize {
        const s = utils.getEnvSlice("MINI_JOURNAL_KEEP") orelse return default_max_journal_files;
        const v = std.fmt.parseInt(usize, s, 10) catch return default_max_journal_files;
        return if (v == 0) default_max_journal_files else v;
    }

    fn collectJournalItems(alloc: Allocator, io: std.Io, dir: *std.Io.Dir, items: *std.ArrayList(JournalItem)) void {
        // PSEUDOCODE:
        // 1. Iterate entries in directory.
        // 2. Filter for journal_*.jsonl files.
        // 3. Stat mtime and append to items list.
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.startsWith(u8, entry.name, "journal_") or !std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
            const name_dup = alloc.dupe(u8, entry.name) catch continue;
            const st = dir.statFile(io, entry.name, .{}) catch {
                alloc.free(name_dup);
                continue;
            };
            items.append(alloc, .{ .name = name_dup, .mtime_ns = st.mtime.nanoseconds }) catch {
                alloc.free(name_dup);
                continue;
            };
        }
    }

    /// Prune `journal_*.jsonl` files in SAME directory as `self_path`,
    /// keeping the `max_journal_files` newest files by mtime.
    /// Current process's file is always kept (just created/written).
    /// Best-effort: silently ignore errors — pruning must never fail the agent.
    pub fn pruneOldJournals(alloc: Allocator, io: std.Io, self_path: []const u8) void {
        // PSEUDOCODE:
        // 1. Open journals directory and collect all journal items.
        // 2. Sort descending by mtime (newest first).
        // 3. Delete files exceeding max_keep (except self_path).
        const dir_path = std.fs.path.dirname(self_path) orelse ".";
        const cwd = std.Io.Dir.cwd();
        var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(io);

        var items: std.ArrayList(JournalItem) = .empty;
        defer {
            for (items.items) |it_| alloc.free(it_.name);
            items.deinit(alloc);
        }
        collectJournalItems(alloc, io, &dir, &items);

        const max_keep = resolveMaxJournalKeep();
        if (items.items.len <= max_keep) return;

        std.mem.sort(JournalItem, items.items, {}, struct {
            fn lt(_: void, a: JournalItem, b: JournalItem) bool {
                return a.mtime_ns > b.mtime_ns;
            }
        }.lt);

        const current_base = std.fs.path.basename(self_path);
        for (items.items[max_keep..]) |old| {
            if (std.mem.eql(u8, old.name, current_base)) continue;
            dir.deleteFile(io, old.name) catch {};
        }
    }

    pub fn deinit(self: *ActJournal) void {
        self.alloc.free(self.file_path);
        if (self.parent_path) |pp| self.alloc.free(pp);
    }

    /// Record event to JSONL file and fsync.
    pub fn recordEvent(self: *ActJournal, io: std.Io, act_id: usize, event_type: ActEventType, desc: []const u8) !void {
        try self.appendEvent(io, .{
            .act_id = act_id,
            .event_type = event_type,
            .timestamp = utils.milliTimestamp(),
            .description = desc,
        });
    }

    /// Record Act completion accompanied by StateDelta.
    pub fn recordActComplete(self: *ActJournal, io: std.Io, act_id: usize, delta: StateDelta) !void {
        try self.appendEvent(io, .{
            .act_id = act_id,
            .event_type = .act_completed,
            .timestamp = utils.milliTimestamp(),
            .description = "Act completed",
            .delta = delta,
        });
    }

    /// Record backend error event with full ErrorDetail for session debugging.
    /// `desc` is a short description (shown when scanning journal), details are in error_detail.
    /// Raw snippet is truncated here to avoid bloating the JSONL file.
    /// Extracts "message" from raw error body format {"error":{"message":"..."}},
    /// returning slice pointing into raw (not owned — raw_snippet lifetime matches event).
    /// Returns null if this structure is not found.
    fn extractServerError(raw: ?[]const u8) ?[]const u8 {
        const r = raw orelse return null;
        const err_obj = json_mod.findObject(r, "error") orelse return json_mod.findString(r, "message");
        return json_mod.findString(err_obj, "message");
    }

    pub fn recordError(
        self: *ActJournal,
        io: std.Io,
        act_id: usize,
        event_type: ActEventType,
        desc: []const u8,
        detail_in: ErrorDetail,
    ) !void {
        var detail = detail_in;
        if (detail.raw_snippet) |raw| {
            if (raw.len > max_raw_snippet_len) {
                detail.raw_snippet = raw[0..max_raw_snippet_len];
            }
        }
        // Auto-extract error message from server if caller did not supply one,
        // so Zig error_name (e.g. UnknownStopReason) does not obscure the real error.
        if (detail.server_error == null) {
            detail.server_error = extractServerError(detail.raw_snippet);
        }
        try self.appendEvent(io, .{
            .act_id = act_id,
            .event_type = event_type,
            .timestamp = utils.milliTimestamp(),
            .description = desc,
            .error_detail = detail,
        });
    }

    /// Maximum length of raw body stored in journal (byte size).
    const max_raw_snippet_len = 2048;

    /// Writes 1 line (ending with '\n') to the end of JSONL file + fsync.
    /// Creates file if it doesn't exist (parent journal might not be initialized yet).
    /// Kept separate as a helper for independent testing and reuse for mirroring to parent journal.
    pub fn writeLineTo(alloc: Allocator, io: std.Io, path: []const u8, line: []const u8) !void {
        _ = alloc;
        // Open file in read_write mode to append; create new if not found.
        // On Unix operating systems, writing to end of file can be simulated with seek.
        // Use plain `cwd.openFile` safely since fsync blocks the thread anyway.
        const cwd = std.Io.Dir.cwd();
        const file = cwd.openFile(io, path, .{ .mode = .read_write }) catch |err| blk: {
            if (err != error.FileNotFound) return err;
            // Create parent directory if needed (parent journal may be in another folder)
            if (std.fs.path.dirname(path)) |dir| {
                cwd.createDirPath(io, dir) catch {};
            }
            break :blk try cwd.createFile(io, path, .{});
        };
        defer file.close(io);

        // Zig 0.16: Io.File no longer has seek/writeAll directly.
        // Get end offset of file and do positional write to ensure append.
        const end_offset = try file.length(io);
        try file.writePositionalAll(io, line, end_offset);
        try file.sync(io); // Ensure flushed to disk (WAL fsync)
        _ = alloc;
    }

    fn appendEvent(self: *ActJournal, io: std.Io, event: ActEvent) !void {
        var out_buf = std.ArrayList(u8).empty;
        defer out_buf.deinit(self.alloc);
        var aw = std.Io.Writer.Allocating.fromArrayList(self.alloc, &out_buf);

        try std.json.Stringify.value(event, .{}, &aw.writer);
        try aw.writer.writeByte('\n');

        out_buf = aw.toArrayList();

        // Write to main journal
        try writeLineTo(self.alloc, io, self.file_path, out_buf.items);

        // Extension: 1-tier mirror to parent agent's journal (subagent merge).
        // Write the same JSON line directly — do NOT recursively call appendEvent to prevent
        // loops when parent also has MINI_PARENT_JOURNAL set.
        if (self.parent_path) |pp| {
            writeLineTo(self.alloc, io, pp, out_buf.items) catch {};
        }
    }
};

test "ActEventType stringify contains memact_compacted" {
    // Default enum stringify in Zig uses snake_case field names —
    try std.testing.expectEqualStrings("memact_compacted", @tagName(ActEventType.memact_compacted));
    // Enum JSON stringify also uses tag name
    var buf: [64]u8 = undefined;
    var sw = std.Io.Writer.fixed(&buf);
    try std.json.Stringify.value(ActEventType.memact_compacted, .{}, &sw);
    try std.testing.expectEqualStrings("\"memact_compacted\"", sw.buffered());
}

test "appendEvent mirrors to parent journal via MINI_PARENT_JOURNAL" {
    // Repo test pattern: g_io style — use std.testing.io for file Io operations
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const main_path = "/tmp/journal_child_test.jsonl";
    const parent_path = "/tmp/journal_parent_test.jsonl";

    // Clean up previous test run files
    std.Io.Dir.deleteFileAbsolute(io, main_path) catch {};
    std.Io.Dir.deleteFileAbsolute(io, parent_path) catch {};

    // Set env before init — journal caches parent_path at init (single getenv)
    _ = setenv("MINI_PARENT_JOURNAL", parent_path, 1);
    defer _ = unsetenv("MINI_PARENT_JOURNAL");

    var j = try ActJournal.init(alloc, io, main_path);
    defer j.deinit();

    // init must successfully cache parent_path
    try std.testing.expect(j.parent_path != null);
    try std.testing.expectEqualStrings(parent_path, j.parent_path.?);

    try j.recordEvent(io, 1, .act_started, "start act test");

    // Both files must contain the exact same JSON line
    const main_line = try readWholeFile(alloc, io, main_path);
    defer alloc.free(main_line);
    const parent_line = try readWholeFile(alloc, io, parent_path);
    defer alloc.free(parent_line);

    try std.testing.expect(main_line.len > 0);
    try std.testing.expectEqualStrings(main_line, parent_line);
    try std.testing.expect(std.mem.indexOf(u8, parent_line, "\"act_started\"") != null);

    std.Io.Dir.deleteFileAbsolute(io, main_path) catch {};
    std.Io.Dir.deleteFileAbsolute(io, parent_path) catch {};
}

test "recordError writes full ErrorDetail to journal JSONL" {
    // Backend errors must log sufficient session context for later debugging
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const path = "/tmp/journal_recorderror_test.jsonl";
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, path) catch {};

    var j = try ActJournal.init(alloc, io, path);
    defer j.deinit();

    // Long raw body — recordError must truncate to max_raw_snippet_len
    const long_raw = "x" ** 5000;
    try j.recordError(io, 3, .llm_provider_error, "Backend error (5xx / provider unavailable)", .{
        .backend = "openai-compat",
        .model = "gpt-4o",
        .error_name = "LLMProviderUnavailable",
        .http_code = 503,
        .attempt = 2,
        .raw_snippet = long_raw,
    });

    // HTTP 400 error with server error body — server_error should be auto-extracted
    try j.recordError(io, 4, .act_failed, "Act error — rollback & retry", .{
        .backend = "openai-compat",
        .model = "deepseek-v4-flash",
        .error_name = "UnknownStopReason",
        .http_code = 400,
        .attempt = 1,
        .raw_snippet = "{\"error\":{\"message\":\"missing model\",\"type\":\"invalid_request_error\",\"param\":null,\"code\":null}}",
    });

    const content = try readWholeFile(alloc, io, path);
    defer alloc.free(content);

    // Important debug fields present in 1 JSON line
    try std.testing.expect(std.mem.indexOf(u8, content, "\"llm_provider_error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"openai-compat\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"gpt-4o\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"LLMProviderUnavailable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"http_code\":503") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"attempt\":2") != null);
    // JSON with 1 event per line (2 events) + truncated raw snippet
    try std.testing.expect(std.mem.count(u8, content, "\n") == 2);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"raw_snippet\"") != null);
    try std.testing.expect(content.len < 5000);
    // server_error auto-extracted from raw body: "missing model" found instead of just UnknownStopReason
    try std.testing.expect(std.mem.indexOf(u8, content, "\"server_error\":\"missing model\"") != null);
}

test "pruneOldJournals keeps N newest files, preserves current file" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // Dedicated test directory — do not touch actual ~/.mini/sessions
    var buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrint(&buf, "/tmp/mini_journal_prune_test_{d}", .{std.c.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dir);

    // Create 5 old journal files + 1 "current" file + 1 non-journal file
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        var pbuf: [256]u8 = undefined;
        const p = try std.fmt.bufPrint(&pbuf, "{s}/journal_old{s}.jsonl", .{ dir, [_]u8{'0' + @as(u8, @intCast(i))} });
        const f = try cwd.createFile(io, p, .{});
        f.close(io);
        // Distinguish mtime: file i is older than file i+1 (sleep slightly to ensure different ns)
        std.Io.sleep(io, .{ .nanoseconds = 2 * std.time.ns_per_ms }, .real) catch {};
    }
    var curbuf: [256]u8 = undefined;
    const cur = try std.fmt.bufPrint(&curbuf, "{s}/journal_current.jsonl", .{dir});
    {
        const f = try cwd.createFile(io, cur, .{});
        f.close(io);
    }
    var otherbuf: [256]u8 = undefined;
    const other = try std.fmt.bufPrint(&otherbuf, "{s}/conv_data.json", .{dir});
    {
        const f = try cwd.createFile(io, other, .{});
        f.close(io);
    }

    // Env override keeps 3 files
    _ = setenv("MINI_JOURNAL_KEEP", "3", 1);
    defer _ = unsetenv("MINI_JOURNAL_KEEP");

    ActJournal.pruneOldJournals(alloc, io, cur);

    // Recount remaining journals in directory
    var d2 = try cwd.openDir(io, dir, .{ .iterate = true });
    defer d2.close(io);
    var n: usize = 0;
    var has_current = false;
    var has_other = false;
    var it2 = d2.iterate();
    while (it2.next(io) catch null) |entry| {
        if (std.mem.startsWith(u8, entry.name, "journal_") and std.mem.endsWith(u8, entry.name, ".jsonl")) {
            n += 1;
            if (std.mem.eql(u8, entry.name, "journal_current.jsonl")) has_current = true;
        } else if (std.mem.eql(u8, entry.name, "conv_data.json")) has_other = true;
    }

    // 5 old + 1 current = 6 -> keeps 3; current always preserved; out-of-scope files untouched
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expect(has_current);
    try std.testing.expect(has_other);
}

test "writeLineTo appends at correct position and generates sequential content" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const path = "/tmp/journal_writeline_test.jsonl";
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, path) catch {};

    // Helper creates file if not present (ActJournal init handles that; here
    // create manually then append 2 lines to verify offset)
    {
        const cwd = std.Io.Dir.cwd();
        const f = try cwd.createFile(io, path, .{});
        f.close(io);
    }
    try ActJournal.writeLineTo(alloc, io, path, "line1\n");
    try ActJournal.writeLineTo(alloc, io, path, "line2\n");

    const content = try readWholeFile(alloc, io, path);
    defer alloc.free(content);
    try std.testing.expectEqualStrings("line1\nline2\n", content);
}

test "recordActComplete records usage and context_tokens in delta" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const path = "/tmp/journal_usage_delta_test.jsonl";
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, path) catch {};

    var j = try ActJournal.init(alloc, io, path);
    defer j.deinit();

    try j.recordActComplete(io, 1, .{
        .act_id = 1,
        .file_snapshots = &.{},
        .stop_reason = "end_turn",
        .generation_stop = "natural_end",
        .response_validity = "final_text",
        .agent_decision = "deliver_final_answer",
        .usage = .{
            .input_tokens = 1234,
            .output_tokens = 567,
            .reasoning_tokens = 89,
        },
        .context_tokens = 2048,
    });

    const content = try readWholeFile(alloc, io, path);
    defer alloc.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "\"usage\":{\"input_tokens\":1234,\"output_tokens\":567,\"reasoning_tokens\":89}") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"context_tokens\":2048") != null);
}

/// Reads whole file into allocated buffer (test helper — Zig 0.16 no longer has readFileAlloc).
fn readWholeFile(alloc: Allocator, io: std.Io, path: []const u8) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.openFile(io, path, .{});
    defer file.close(io);
    const len = try file.length(io);
    const buf = try alloc.alloc(u8, @intCast(len));
    errdefer alloc.free(buf);
    const n = try file.readPositionalAll(io, buf, 0);
    return buf[0..n];
}

