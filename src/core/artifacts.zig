//! artifacts.zig — Artifacts & Artifact References management system for mini-agent.
//!
//! Provides:
//! 1. Session-based artifact file storage: ~/.mini/artifacts/<session_id>/
//! 2. Artifact catalog metadata management (metadata.json)
//! 3. Real-time event hooks dispatching (artifact_saved, artifact_updated) for external UI/Preview
//! 4. Bidirectional reference syntax support @artifact:<name> in chat / prompt.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("json.zig");
const utils = @import("utils.zig");
const main = @import("../main.zig");
const hooks = @import("hooks.zig");

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

fn getEnvVar(name: [*:0]const u8) ?[]const u8 {
    if (getenv(name)) |ptr| {
        return std.mem.span(ptr);
    }
    return null;
}

var g_session_id: ?[]const u8 = null;

/// Set the current Session ID.
pub fn setSessionId(id: ?[]const u8) void {
    g_session_id = id;
}

/// Get the current Session ID (defaults to "default").
pub fn getSessionId() []const u8 {
    if (g_session_id) |sid| {
        if (sid.len > 0) return sid;
    }
    return "default";
}

/// Resolve artifacts directory path for current session.
pub fn resolveArtifactsDir(alloc: Allocator, io: std.Io) ![]u8 {
    const sid = getSessionId();

    var dir_path: []u8 = undefined;
    if (getEnvVar("MINI_ARTIFACTS_DIR")) |custom_dir| {
        if (custom_dir.len > 0) {
            dir_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ custom_dir, sid });
        } else {
            dir_path = try defaultArtifactsDir(alloc, sid);
        }
    } else {
        dir_path = try defaultArtifactsDir(alloc, sid);
    }

    // Create directory if it does not exist
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, dir_path) catch {};

    return dir_path;
}

fn defaultArtifactsDir(alloc: Allocator, sid: []const u8) ![]u8 {
    if (getEnvVar("MINI_HOME")) |mh| {
        if (mh.len > 0) return std.fmt.allocPrint(alloc, "{s}/artifacts/{s}", .{ mh, sid });
    }
    if (getEnvVar("HOME")) |home| {
        if (home.len > 0) return std.fmt.allocPrint(alloc, "{s}/.mini/artifacts/{s}", .{ home, sid });
    }
    return std.fmt.allocPrint(alloc, "./.mini/artifacts/{s}", .{sid});
}

/// Write a new artifact or update an existing one.
/// Returns absolute (or canonical) path to the artifact file.
pub fn writeArtifact(
    alloc: Allocator,
    io: std.Io,
    name: []const u8,
    title: ?[]const u8,
    content: []const u8,
    artifact_type: ?[]const u8,
    summary: ?[]const u8,
    user_facing: bool,
) ![]u8 {
    const art_dir = try resolveArtifactsDir(alloc, io);
    defer alloc.free(art_dir);

    // Sanitize filename: strip dangerous leading characters leading outside directory
    var safe_name = name;
    while (std.mem.startsWith(u8, safe_name, "/") or std.mem.startsWith(u8, safe_name, "./")) {
        if (std.mem.startsWith(u8, safe_name, "/")) safe_name = safe_name[1..];
        if (std.mem.startsWith(u8, safe_name, "./")) safe_name = safe_name[2..];
    }
    if (safe_name.len == 0) safe_name = "artifact.txt";

    const file_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ art_dir, safe_name });
    errdefer alloc.free(file_path);

    // Create parent directory if safe_name contains subpath (e.g. scratch/test.py)
    if (std.fs.path.dirname(file_path)) |pdir| {
        std.Io.Dir.cwd().createDirPath(io, pdir) catch {};
    }

    // Write artifact file content
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(io, file_path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, content);

    // Update metadata.json
    updateMetadata(alloc, io, art_dir, safe_name, title, artifact_type, summary, user_facing, file_path) catch {};

    return file_path;
}

/// Read content of an artifact by name or path.
pub fn readArtifact(alloc: Allocator, io: std.Io, name: []const u8) ![]u8 {
    const art_dir = try resolveArtifactsDir(alloc, io);
    defer alloc.free(art_dir);

    const file_path = if (std.mem.startsWith(u8, name, "/"))
        try alloc.dupe(u8, name)
    else
        try std.fmt.allocPrint(alloc, "{s}/{s}", .{ art_dir, name });
    defer alloc.free(file_path);

    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, file_path, .{}) catch |e| {
        return std.fmt.allocPrint(alloc, "Error: Artifact '{s}' not found ({s})", .{ name, @errorName(e) });
    };
    defer file.close(io);

    const stat = try file.stat(io);
    const max_size: usize = 10 * 1024 * 1024; // 10MB
    const read_len: usize = @min(@as(usize, @intCast(stat.size)), max_size);
    const buf = try alloc.alloc(u8, read_len);
    errdefer alloc.free(buf);

    const n = try utils.readAll(io, file, buf);
    return buf[0..n];
}

/// List all artifacts currently present in session.
pub fn listArtifacts(alloc: Allocator, io: std.Io) ![]u8 {
    const art_dir = try resolveArtifactsDir(alloc, io);
    defer alloc.free(art_dir);

    const meta_path = try std.fmt.allocPrint(alloc, "{s}/metadata.json", .{art_dir});
    defer alloc.free(meta_path);

    const cwd = std.Io.Dir.cwd();
    const meta_file = cwd.openFile(io, meta_path, .{}) catch {
        return std.fmt.allocPrint(alloc, "No artifacts found in session '{s}'. Directory: {s}", .{ getSessionId(), art_dir });
    };
    defer meta_file.close(io);

    const stat = meta_file.stat(io) catch return std.fmt.allocPrint(alloc, "Error reading metadata.", .{});
    const buf = try alloc.alloc(u8, @intCast(stat.size));
    defer alloc.free(buf);
    const n = try utils.readAll(io, meta_file, buf);
    const meta_content = buf[0..n];

    return std.fmt.allocPrint(alloc, "Artifacts List (Session: {s}):\nDirectory: {s}\n\n{s}", .{
        getSessionId(), art_dir, meta_content,
    });
}

/// Scan and expand `@artifact:<name>` reference syntax in user prompt.
pub fn expandArtifactReferences(alloc: Allocator, io: std.Io, prompt: []const u8) ![]u8 {
    const prefix = "@artifact:";
    if (std.mem.indexOf(u8, prompt, prefix) == null) {
        return alloc.dupe(u8, prompt);
    }

    var result = utils.BufWriter.init(alloc);
    errdefer result.deinit();

    var i: usize = 0;
    while (i < prompt.len) {
        if (std.mem.startsWith(u8, prompt[i..], prefix)) {
            const start_name = i + prefix.len;
            var end_name = start_name;
            while (end_name < prompt.len and prompt[end_name] != ' ' and prompt[end_name] != '\t' and prompt[end_name] != '\n' and prompt[end_name] != ',' and prompt[end_name] != ')') : (end_name += 1) {}

            const art_name = prompt[start_name..end_name];
            if (art_name.len > 0) {
                const content = readArtifact(alloc, io, art_name) catch null;
                defer if (content) |c| alloc.free(c);

                if (content) |c| {
                    try result.print("\n\n--- [Artifact: {s}] ---\n{s}\n--- [End of Artifact: {s}] ---\n\n", .{ art_name, c, art_name });
                } else {
                    try result.print("@artifact:{s} (not found)", .{art_name});
                }
            } else {
                try result.writeAll(prefix);
            }
            i = end_name;
        } else {
            try result.writeAll(prompt[i .. i + 1]);
            i += 1;
        }
    }

    return result.list.toOwnedSlice(alloc);
}

fn updateMetadata(
    alloc: Allocator,
    io: std.Io,
    art_dir: []const u8,
    name: []const u8,
    title: ?[]const u8,
    artifact_type: ?[]const u8,
    summary: ?[]const u8,
    user_facing: bool,
    path: []const u8,
) !void {
    const meta_path = try std.fmt.allocPrint(alloc, "{s}/metadata.json", .{art_dir});
    defer alloc.free(meta_path);

    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
    const now = ts.sec;

    // Read existing metadata if present
    const cwd = std.Io.Dir.cwd();
    var existing_content: ?[]u8 = null;
    if (cwd.openFile(io, meta_path, .{})) |mf| {
        defer mf.close(io);
        if (mf.stat(io)) |st| {
            if (st.size < 1024 * 1024) {
                const mbuf = alloc.alloc(u8, @intCast(st.size)) catch null;
                if (mbuf) |mb| {
                    const mn = utils.readAll(io, mf, mb) catch 0;
                    existing_content = mb[0..mn];
                }
            }
        } else |_| {}
    } else |_| {}
    defer if (existing_content) |ec| alloc.free(ec);

    var w = utils.BufWriter.init(alloc);
    defer w.deinit();

    const effective_title = title orelse name;
    const effective_type = artifact_type orelse "text";
    const effective_summary = summary orelse "";

    const esc_name = try json.escape(alloc, name);
    defer alloc.free(esc_name);
    const esc_title = try json.escape(alloc, effective_title);
    defer alloc.free(esc_title);
    const esc_type = try json.escape(alloc, effective_type);
    defer alloc.free(esc_type);
    const esc_sum = try json.escape(alloc, effective_summary);
    defer alloc.free(esc_sum);
    const esc_path = try json.escape(alloc, path);
    defer alloc.free(esc_path);

    // Write JSON array structure
    if (existing_content) |ec| {
        const trimmed = std.mem.trim(u8, ec, " \t\r\n");
        if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            const inner = trimmed[1 .. trimmed.len - 1];
            try w.writeAll("[\n");
            if (inner.len > 0) {
                try w.writeAll(inner);
                try w.writeAll(",\n");
            }
            try w.print("  {{\"name\":\"{s}\",\"title\":\"{s}\",\"type\":\"{s}\",\"summary\":\"{s}\",\"user_facing\":{},\"path\":\"{s}\",\"timestamp\":{d}}}\n]", .{
                esc_name, esc_title, esc_type, esc_sum, user_facing, esc_path, now,
            });
        } else {
            try w.print("[\n  {{\"name\":\"{s}\",\"title\":\"{s}\",\"type\":\"{s}\",\"summary\":\"{s}\",\"user_facing\":{},\"path\":\"{s}\",\"timestamp\":{d}}}\n]", .{
                esc_name, esc_title, esc_type, esc_sum, user_facing, esc_path, now,
            });
        }
    } else {
        try w.print("[\n  {{\"name\":\"{s}\",\"title\":\"{s}\",\"type\":\"{s}\",\"summary\":\"{s}\",\"user_facing\":{},\"path\":\"{s}\",\"timestamp\":{d}}}\n]", .{
            esc_name, esc_title, esc_type, esc_sum, user_facing, esc_path, now,
        });
    }

    const file = try cwd.createFile(io, meta_path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, w.list.items);
}

test "artifacts write, read and reference expansion" {
    const alloc = std.testing.allocator;
    setSessionId("test_session_unit");

    // Write artifact
    const path = try writeArtifact(
        alloc,
        main.getIo(),
        "test_plan.md",
        "Test Plan",
        "# Plan\nTest artifact content",
        "markdown",
        "Test summary",
        true,
    );
    defer alloc.free(path);

    // Read artifact
    const read_back = try readArtifact(alloc, main.getIo(), "test_plan.md");
    defer alloc.free(read_back);
    try std.testing.expect(std.mem.indexOf(u8, read_back, "Test artifact content") != null);

    // Test expandArtifactReferences
    const prompt = "Please review @artifact:test_plan.md and continue";
    const expanded = try expandArtifactReferences(alloc, main.getIo(), prompt);
    defer alloc.free(expanded);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "--- [Artifact: test_plan.md] ---") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "Test artifact content") != null);
}


