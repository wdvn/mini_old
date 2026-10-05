//! config/workspace.zig — Workspace context discovery and system prompt builder.

const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("../utils.zig");
const main = @import("../../main.zig");
const prompts_mod = @import("../prompts.zig");
pub const skills_mod = @import("../skills.zig");
const types_mod = @import("types.zig");

pub const SpResult = struct { buf: ?[]u8, text: []const u8 };

/// Scans the workspace directory to build a dynamic context block informing the
/// model about the current environment (working directory, project name, detected
/// project stack, git branch, and top-level files/directories).
pub fn resolveWorkspaceRoot(env_map: *const std.process.Environ.Map) ?[]const u8 {
    if (env_map.get("MINI_WORKSPACE_ROOT")) |r| return r;
    if (env_map.get("MINI_AGENT_FOLDER")) |agent_dir| {
        if (std.fs.path.dirname(agent_dir)) |parent| return parent;
    }
    return env_map.get("PWD");
}

pub fn resolveWorkspaceRootAndName(env_map: *const std.process.Environ.Map) ?struct { root: []const u8, prj_name: []const u8 } {
    const root = resolveWorkspaceRoot(env_map) orelse return null;
    var prj_name = std.fs.path.basename(root);
    if (std.mem.eql(u8, prj_name, ".") or prj_name.len == 0) {
        if (env_map.get("PWD")) |pwd| {
            const b = std.fs.path.basename(pwd);
            if (b.len > 0 and !std.mem.eql(u8, b, ".")) prj_name = b;
        }
    }
    return .{ .root = root, .prj_name = prj_name };
}

pub const WorkspaceMarker = struct {
    file: []const u8,
    name: []const u8,
};

pub const WORKSPACE_MARKERS = [_]WorkspaceMarker{
    .{ .file = "go.mod", .name = "Go" },
    .{ .file = "package.json", .name = "Node.js / Web" },
    .{ .file = "Cargo.toml", .name = "Rust" },
    .{ .file = "build.zig", .name = "Zig" },
    .{ .file = "build.zig.zon", .name = "Zig" },
    .{ .file = "pyproject.toml", .name = "Python" },
    .{ .file = "requirements.txt", .name = "Python" },
    .{ .file = "setup.py", .name = "Python" },
    .{ .file = "pom.xml", .name = "Java (Maven)" },
    .{ .file = "build.gradle", .name = "Java/Kotlin (Gradle)" },
    .{ .file = "CMakeLists.txt", .name = "C/C++" },
    .{ .file = "Makefile", .name = "Make" },
};

pub fn detectProjectTypes(alloc: Allocator, io: std.Io, dir: *std.Io.Dir, list: *std.ArrayList([]const u8)) void {
    for (WORKSPACE_MARKERS) |marker| {
        if (dir.statFile(io, marker.file, .{})) |_| {
            var already = false;
            for (list.items) |existing| {
                if (std.mem.eql(u8, existing, marker.name)) {
                    already = true;
                    break;
                }
            }
            if (!already) list.append(alloc, marker.name) catch {};
        } else |_| {}
    }
}

pub fn detectGitBranch(io: std.Io, dir: *std.Io.Dir, buf: *[128]u8) ?[]const u8 {
    const head_file = dir.openFile(io, ".git/HEAD", .{}) catch return null;
    defer head_file.close(io);
    const n = utils.readAll(io, head_file, buf) catch return null;
    const head_content = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (std.mem.startsWith(u8, head_content, "ref: refs/heads/")) {
        return head_content["ref: refs/heads/".len..];
    }
    if (head_content.len >= 7) return head_content[0..7];
    return null;
}

pub fn isIgnoredWorkspaceEntry(name: []const u8) bool {
    const IGNORED = [_][]const u8{ "node_modules", "zig-cache", "zig-out", "__pycache__", "target", "dist", "build" };
    for (IGNORED) |ign| {
        if (std.mem.eql(u8, name, ign)) return true;
    }
    return false;
}

pub fn collectWorkspaceEntries(alloc: Allocator, io: std.Io, dir: *std.Io.Dir, list: *std.ArrayList([]const u8)) void {
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (isIgnoredWorkspaceEntry(entry.name)) continue;

        if (entry.kind == .directory) {
            const dname = std.fmt.allocPrint(alloc, "{s}/", .{entry.name}) catch continue;
            list.append(alloc, dname) catch {
                alloc.free(dname);
                continue;
            };
        } else {
            const fname = alloc.dupe(u8, entry.name) catch continue;
            list.append(alloc, fname) catch {
                alloc.free(fname);
                continue;
            };
        }
        if (list.items.len >= 35) break;
    }
    std.mem.sort([]const u8, list.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
}

pub fn formatWorkspaceContext(
    alloc: Allocator,
    root: []const u8,
    prj_name: []const u8,
    types: []const []const u8,
    branch: ?[]const u8,
    entries: []const []const u8,
) ?[]u8 {
    var bw = utils.BufWriter.init(alloc);
    defer bw.deinit();

    bw.print("<workspace_context>\n", .{}) catch return null;
    bw.print("- Working Directory: {s}\n- Project Name: {s}\n", .{ root, prj_name }) catch return null;

    if (types.len > 0) {
        bw.print("- Project Type: ", .{}) catch return null;
        for (types, 0..) |t, idx| {
            if (idx > 0) bw.print(", ", .{}) catch return null;
            bw.print("{s}", .{t}) catch return null;
        }
        bw.print("\n", .{}) catch return null;
    }
    if (branch) |b| bw.print("- Git Branch: {s}\n", .{b}) catch return null;

    if (entries.len > 0) {
        bw.print("- Workspace Entries: ", .{}) catch return null;
        for (entries, 0..) |item, idx| {
            if (idx > 0) bw.print(", ", .{}) catch return null;
            bw.print("{s}", .{item}) catch return null;
        }
        bw.print("\n", .{}) catch return null;
    }
    bw.print("</workspace_context>\n", .{}) catch return null;
    return bw.toOwnedSlice() catch null;
}

pub fn buildWorkspaceContext(alloc: Allocator, env_map: *const std.process.Environ.Map, io: std.Io) ?[]u8 {
    // PSEUDOCODE:
    // 1. Resolve workspace root directory and project name
    // 2. Open directory iterator
    // 3. Detect project types via marker files
    // 4. Detect current Git branch from .git/HEAD
    // 5. Collect top-level workspace entries (up to 35 items)
    // 6. Format workspace context XML block
    const ws = resolveWorkspaceRootAndName(env_map) orelse return null;
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, ws.root, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var detected_types = std.ArrayList([]const u8).empty;
    defer detected_types.deinit(alloc);
    detectProjectTypes(alloc, io, &dir, &detected_types);

    var head_buf: [128]u8 = undefined;
    const git_branch = detectGitBranch(io, &dir, &head_buf);

    var entries_list = std.ArrayList([]const u8).empty;
    defer {
        for (entries_list.items) |item| alloc.free(item);
        entries_list.deinit(alloc);
    }
    collectWorkspaceEntries(alloc, io, &dir, &entries_list);

    return formatWorkspaceContext(alloc, ws.root, ws.prj_name, detected_types.items, git_branch, entries_list.items);
}

pub fn loadBaseSystemPrompt(alloc: Allocator, env_map: *const std.process.Environ.Map, io: std.Io) SpResult {
    const path = env_map.get("MINI_SYSTEM_FILE") orelse return .{ .buf = null, .text = types_mod.Config.default_system_prompt };
    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, path, .{}) catch {
        if (!utils.isSubagent()) main.stderrPrint("[config] Failed to open system prompt: {s}, using default.\n", .{path});
        return .{ .buf = null, .text = types_mod.Config.default_system_prompt };
    };
    defer file.close(io);

    const stat = file.stat(io) catch return .{ .buf = null, .text = types_mod.Config.default_system_prompt };
    if (stat.size == 0 or stat.size > 64 * 1024) return .{ .buf = null, .text = types_mod.Config.default_system_prompt };

    const buf = alloc.alloc(u8, @intCast(stat.size)) catch return .{ .buf = null, .text = types_mod.Config.default_system_prompt };
    const n = utils.readAll(io, file, buf) catch {
        alloc.free(buf);
        return .{ .buf = null, .text = types_mod.Config.default_system_prompt };
    };
    if (!utils.isSubagent()) main.stderrPrint("[config] System prompt: {s} ({d} bytes)\n", .{ path, n });
    return .{ .buf = buf, .text = buf[0..n] };
}

pub fn injectWorkspaceContext(alloc: Allocator, env_map: *const std.process.Environ.Map, io: std.Io, current: SpResult) SpResult {
    const ws_ctx = buildWorkspaceContext(alloc, env_map, io) orelse return current;
    defer alloc.free(ws_ctx);
    const combined = std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ current.text, ws_ctx }) catch return current;
    if (current.buf) |b| alloc.free(b);
    if (!utils.isSubagent()) main.stderrPrint("[config] Injected workspace context into system prompt\n", .{});
    return .{ .buf = combined, .text = combined };
}

pub fn appendAgentRuleFile(alloc: Allocator, io: std.Io, accum: *std.ArrayList(u8), path: []const u8, label: []const u8) bool {
    const text = readAgentFile(alloc, io, path) orelse return false;
    defer alloc.free(text);
    accum.appendSlice(alloc, text) catch return false;
    accum.appendSlice(alloc, "\n\n") catch return false;
    if (!utils.isSubagent()) main.stderrPrint("[config] Loaded {s} ({d} bytes)\n", .{ label, text.len });
    return true;
}

pub fn readAgentFile(alloc: Allocator, io: std.Io, path: []const u8) ?[]u8 {
    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, path, .{}) catch return null;
    defer file.close(io);

    const stat = file.stat(io) catch return null;
    if (stat.size == 0 or stat.size > 128 * 1024) return null;

    const buf = alloc.alloc(u8, @intCast(stat.size)) catch return null;
    const n = utils.readAll(io, file, buf) catch {
        alloc.free(buf);
        return null;
    };
    return buf[0..n];
}

pub fn collectAgentRules(alloc: Allocator, env_map: *const std.process.Environ.Map, io: std.Io) ?[]u8 {
    var accum = std.ArrayList(u8).empty;
    defer accum.deinit(alloc);

    const ws_root = resolveWorkspaceRoot(env_map);
    var path_buf: [512]u8 = undefined;

    if (ws_root) |root| {
        if (std.fmt.bufPrint(&path_buf, "{s}/AGENTS.md", .{root})) |p| {
            if (!appendAgentRuleFile(alloc, io, &accum, p, "workspace AGENTS.md")) {
                if (std.fmt.bufPrint(&path_buf, "{s}/CLAUDE.md", .{root})) |cp| {
                    _ = appendAgentRuleFile(alloc, io, &accum, cp, "workspace CLAUDE.md");
                } else |_| {}
            }
        } else |_| {}
    }

    if (env_map.get("MINI_AGENT_FOLDER")) |agent_dir| {
        const is_same = if (ws_root) |root| std.mem.eql(u8, root, agent_dir) else false;
        if (!is_same) {
            if (std.fmt.bufPrint(&path_buf, "{s}/AGENTS.md", .{agent_dir})) |pp| {
                _ = appendAgentRuleFile(alloc, io, &accum, pp, ".agent AGENTS.md");
            } else |_| {}
        }
    }

    if (env_map.get("HOME")) |home| {
        if (std.fmt.bufPrint(&path_buf, "{s}/.mini/AGENTS.md", .{home})) |gp| {
            _ = appendAgentRuleFile(alloc, io, &accum, gp, "global AGENTS.md");
        } else |_| {}
    }

    if (accum.items.len == 0) return null;
    return alloc.dupe(u8, accum.items) catch null;
}

/// Injects skills block at the end of system prompt.
/// Loads skills from disk first (loadSkills), then builds block and appends it.
/// Returns new SpResult; if no skills exist, returns original.
pub fn appendSkillsBlock(alloc: Allocator, env_map: *const std.process.Environ.Map, io: std.Io, prev: SpResult) SpResult {
    const n = skills_mod.loadSkills(alloc, io, env_map);
    if (n == 0) return prev;

    const block = skills_mod.buildSkillsBlock(alloc) catch return prev;
    if (block) |b| {
        const combined = std.fmt.allocPrint(alloc, "{s}\n{s}", .{ prev.text, b }) catch {
            alloc.free(b);
            return prev;
        };
        alloc.free(b);
        if (prev.buf) |old| alloc.free(old);
        if (!utils.isSubagent()) main.stderrPrint("[config] Loaded {d} skill(s) into system prompt\n", .{n});
        return .{ .buf = combined, .text = combined };
    }
    return prev;
}

pub fn loadSystemPrompt(alloc: Allocator, env_map: *const std.process.Environ.Map, io: std.Io) SpResult {
    // PSEUDOCODE:
    // 1. Load base prompt from file or fallback to default
    // 2. Inject workspace context if available
    // 3. Collect and append AGENTS.md rules
    // 4. Append skills block
    var result = loadBaseSystemPrompt(alloc, env_map, io);
    result = injectWorkspaceContext(alloc, env_map, io, result);

    if (collectAgentRules(alloc, env_map, io)) |rules| {
        defer alloc.free(rules);
        const combined = std.fmt.allocPrint(alloc, "{s}\n\n<RULE[AGENTS.md]>\n{s}</RULE[AGENTS.md]>\n", .{ result.text, rules }) catch return appendSkillsBlock(alloc, env_map, io, result);
        if (result.buf) |b| alloc.free(b);
        result = .{ .buf = combined, .text = combined };
    }

    return appendSkillsBlock(alloc, env_map, io, result);
}
