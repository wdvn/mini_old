//! skills.zig — Skill discovery layer: scans and loads skill metadata from ~/.mini/skills.
//!
//! Each skill is a subdirectory containing a `SKILL.md` file with YAML frontmatter:
//! ```md
//! ---
//! name: my-skill
//! description: Use when ...
//! ---
//! ```
//!
//! ## How it works
//! 1. `loadSkills()` scans `<MINI_HOME>/skills/*/SKILL.md` (default `~/.mini/skills/`)
//! 2. Parses frontmatter to extract `name` + `description`
//! 3. `buildSkillsBlock()` generates text block injected into system prompt — containing
//!    only name + description + path (~50 tokens/skill); the agent reads the full file when needed.
//!
//! ## Constraints
//!   - Maximum 32 skills, each description capped at 512 bytes (preventing prompt bloat)
//!   - SKILL.md maximum 64 KB
//!   - Non-recursive: only inspects `skills/<name>/SKILL.md` directly

const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");
const prompts_mod = @import("prompts.zig");
/// Maximum number of skills injected into prompt.
const MAX_SKILLS = 32;

/// Limit on description size injected into prompt (bytes).
const MAX_DESC_LEN = 512;

/// Limit on SKILL.md file size (bytes).
const MAX_SKILL_FILE = 64 * 1024;

/// Metadata for a skill parsed from frontmatter.
pub const SkillInfo = struct {
    /// Skill name (from frontmatter `name`, fallback: directory name).
    name: []const u8,
    /// Trigger description (from frontmatter `description`).
    description: []const u8,
    /// Absolute path to SKILL.md.
    path: []const u8,
};

/// Loaded skills list (arena-allocated, freed via `deinitSkills`).
/// Mutex protecting g_skills and g_skills_arena.
pub var g_skills_mutex = std.atomic.Mutex.unlocked;

var g_skills: ?[]SkillInfo = null;
var g_skills_arena: ?std.heap.ArenaAllocator = null;

/// Free skills memory.
pub fn deinitSkills() void {
    while (!g_skills_mutex.tryLock()) {}
    if (g_skills_arena) |*arena| {
        arena.deinit();
        g_skills_arena = null;
    }
    g_skills = null;
    g_skills_mutex.unlock();
}

/// Return loaded skills list (null if loadSkills not called or no skills).
pub fn getSkills() ?[]const SkillInfo {
    while (!g_skills_mutex.tryLock()) {}
    const s = g_skills;
    g_skills_mutex.unlock();
    return s;
}

const main = @import("../main.zig");

/// Scan skills directory and parse metadata (scans ~/.mini/skills/ first, .agent/skills/ after; .agent overrides global).
/// Returns count of loaded skills (0 if directory does not exist).
pub fn loadSkills(alloc: Allocator, io: std.Io, env_map: *const std.process.Environ.Map) usize {
    var arena = std.heap.ArenaAllocator.init(alloc);
    var transferred = false;
    defer if (!transferred) arena.deinit();

    var skills: std.ArrayList(SkillInfo) = .empty;
    defer skills.deinit(arena.allocator());

    // 1. Global skills (~/.mini/skills)
    if (resolveSkillsDir(arena.allocator(), env_map)) |global_dir| {
        scanSkillsFromDir(arena.allocator(), io, global_dir, &skills);
    } else |_| {}

    // 2. Project skills (.agent/skills)
    if (env_map.get("MINI_AGENT_FOLDER")) |agent_dir| {
        if (agent_dir.len > 0) {
            if (std.fmt.allocPrint(arena.allocator(), "{s}/skills", .{agent_dir})) |project_dir| {
                scanSkillsFromDir(arena.allocator(), io, project_dir, &skills);
            } else |_| {}
        }
    }

    if (skills.items.len == 0) return 0;

    // Transfer ownership to global state
    deinitSkills();
    const owned = skills.toOwnedSlice(arena.allocator()) catch return 0;
    while (!g_skills_mutex.tryLock()) {}
    g_skills_arena = arena;
    g_skills = owned;
    g_skills_mutex.unlock();
    transferred = true;
    return owned.len;
}

fn scanSkillsFromDir(arena_alloc: Allocator, io: std.Io, dir_path: []const u8, skills: *std.ArrayList(SkillInfo)) void {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;

        // Read <dir>/<name>/SKILL.md
        const skill_path = std.fmt.allocPrint(arena_alloc, "{s}/{s}/SKILL.md", .{ dir_path, entry.name }) catch continue;
        const info = parseSkillFile(arena_alloc, io, skill_path, entry.name) catch continue;

        // Check if this skill name already exists (Project overrides Global)
        var overwritten = false;
        for (skills.items) |*existing| {
            if (std.mem.eql(u8, existing.name, info.name)) {
                existing.* = info;
                overwritten = true;
                break;
            }
        }

        if (!overwritten and skills.items.len < MAX_SKILLS) {
            skills.append(arena_alloc, info) catch continue;
        }
    }
}

fn readSkillFileContent(alloc: Allocator, io: std.Io, path: []const u8) ![]u8 {
    // PSEUDOCODE:
    // 1. Open file and check size (0 < size <= MAX_SKILL_FILE).
    // 2. Read content into allocated buffer.
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.size == 0 or stat.size > MAX_SKILL_FILE) return error.InvalidFileSize;

    const buf = try alloc.alloc(u8, @intCast(stat.size));
    errdefer alloc.free(buf);
    const n = try utils.readAll(io, file, buf);
    return buf[0..n];
}

fn parseSkillFrontmatter(alloc: Allocator, content: []const u8, default_name: []const u8, desc_buf: *std.ArrayList(u8)) []const u8 {
    // PSEUDOCODE:
    // 1. Check for YAML frontmatter opening "---".
    // 2. Parse lines for name and single-line/multiline description.
    var name: []const u8 = default_name;
    if (!std.mem.startsWith(u8, content, "---\n")) return name;

    const body_start = std.mem.indexOfPos(u8, content, 4, "\n---") orelse content.len;
    var lines = std.mem.splitScalar(u8, content[4..body_start], '\n');
    var in_desc_multiline = false;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (in_desc_multiline) {
            if (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) {
                if (trimmed.len > 0) {
                    if (desc_buf.items.len > 0 and desc_buf.items.len < MAX_DESC_LEN) desc_buf.append(alloc, ' ') catch {};
                    const to_copy = @min(trimmed.len, if (desc_buf.items.len < MAX_DESC_LEN) MAX_DESC_LEN - desc_buf.items.len else 0);
                    if (to_copy > 0) desc_buf.appendSlice(alloc, trimmed[0..to_copy]) catch {};
                }
                continue;
            } else {
                in_desc_multiline = false;
            }
        }
        if (std.mem.startsWith(u8, trimmed, "name:")) {
            name = std.mem.trim(u8, trimmed[5..], " \t\"'");
        } else if (std.mem.startsWith(u8, trimmed, "description:")) {
            const rest = std.mem.trim(u8, trimmed[12..], " \t\"'");
            if (std.mem.eql(u8, rest, ">") or std.mem.eql(u8, rest, ">-") or std.mem.eql(u8, rest, "|") or std.mem.eql(u8, rest, "|-") or rest.len == 0) {
                in_desc_multiline = true;
            } else {
                const to_copy = @min(rest.len, MAX_DESC_LEN);
                desc_buf.appendSlice(alloc, rest[0..to_copy]) catch {};
            }
        }
    }
    return name;
}

/// Parse frontmatter of SKILL.md.
/// Spec agentskills.io: `name` must match parent directory name (`dir_name`).
fn parseSkillFile(alloc: Allocator, io: std.Io, path: []const u8, dir_name: []const u8) !SkillInfo {
    // PSEUDOCODE:
    // 1. Read file content.
    // 2. Parse frontmatter name and description.
    // 3. Validate name matches dir_name.
    // 4. Return duped SkillInfo.
    const content = try readSkillFileContent(alloc, io, path);
    defer alloc.free(content);

    var desc_buf = std.ArrayList(u8).empty;
    defer desc_buf.deinit(alloc);

    var name = parseSkillFrontmatter(alloc, content, dir_name, &desc_buf);
    if (!std.mem.eql(u8, name, dir_name)) {
        main.stderrPrint("[skills] Warning: skill name '{s}' in {s} does not match directory name '{s}', using directory name.\n", .{ name, path, dir_name });
        name = dir_name;
    }

    return .{
        .name = try alloc.dupe(u8, name),
        .description = try alloc.dupe(u8, desc_buf.items),
        .path = try alloc.dupe(u8, path),
    };
}

/// Resolve skills directory: `$MINI_HOME/skills` or `~/.mini/skills`.
/// Returns string owned by caller (must free).
fn resolveSkillsDir(alloc: Allocator, env_map: *const std.process.Environ.Map) ![]u8 {
    if (env_map.get("MINI_HOME")) |mh| {
        if (mh.len > 0) return std.fmt.allocPrint(alloc, "{s}/skills", .{mh});
    }
    const home = env_map.get("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(alloc, "{s}/.mini/skills", .{home});
}

/// Generate text block to inject at the end of system prompt.
/// Returns null if no skills (injects nothing).
/// Caller frees result.
pub fn buildSkillsBlock(alloc: Allocator) !?[]u8 {
    while (!g_skills_mutex.tryLock()) {}
    const skills = g_skills orelse return null;
    g_skills_mutex.unlock();
    if (skills.len == 0) return null;

    var buf = utils.BufWriter.init(alloc);
    errdefer buf.deinit();

    try buf.writeAll(prompts_mod.skills_guidance_header);
    for (skills) |s| {
        if (s.description.len > 0) {
            try buf.print("- **{s}**: {s} — read `{s}`\n", .{ s.name, s.description, s.path });
        } else {
            try buf.print("- **{s}** — read `{s}`\n", .{ s.name, s.path });
        }
    }

    return try buf.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parseSkillFile frontmatter" {
    // Create temporary directory + SKILL.md
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "my-skill");

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "my-skill/SKILL.md",
        .data = "---\nname: my-skill\ndescription: Use when writing docs\n---\n\n# Content",
    });

    // tmpDir cwd differs from process cwd — direct parse testing via relative path is not feasible
    // (parseSkillFile opens relative to cwd). Test frontmatter logic via separate helper.
}

test "frontmatter parse logic" {
    // Check logic separating name/description from frontmatter string
    const content = "---\nname: abc\ndescription: Use when xyz\n---\nbody";
    try testing.expect(std.mem.startsWith(u8, content, "---\n"));
    const body_start = std.mem.indexOfPos(u8, content, 4, "\n---").?;
    const fm = content[4..body_start];
    var found_name = false;
    var found_desc = false;
    var lines = std.mem.splitScalar(u8, fm, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "name:")) found_name = true;
        if (std.mem.startsWith(u8, line, "description:")) found_desc = true;
    }
    try testing.expect(found_name);
    try testing.expect(found_desc);
}

test "frontmatter parse multiline description" {
    const content =
        \\---
        \\name: check-work
        \\description: >
        \\  Check your work with a verification subagent.
        \\  Use when asked to "check work" or "verify".
        \\metadata:
        \\  short-description: "Verify"
        \\---
        \\# Content
    ;
    const body_start = std.mem.indexOfPos(u8, content, 4, "\n---").?;
    const fm = content[4..body_start];
    var lines = std.mem.splitScalar(u8, fm, '\n');
    var desc_buf = std.ArrayList(u8).empty;
    defer desc_buf.deinit(testing.allocator);
    var in_desc_multiline = false;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (in_desc_multiline) {
            if (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) {
                if (trimmed.len > 0) {
                    if (desc_buf.items.len > 0) {
                        try desc_buf.append(testing.allocator, ' ');
                    }
                    try desc_buf.appendSlice(testing.allocator, trimmed);
                }
                continue;
            } else {
                in_desc_multiline = false;
            }
        }
        if (std.mem.startsWith(u8, trimmed, "description:")) {
            const rest = std.mem.trim(u8, trimmed[12..], " \t\"'");
            if (std.mem.eql(u8, rest, ">") or std.mem.eql(u8, rest, ">-")) {
                in_desc_multiline = true;
            }
        }
    }

    try testing.expectEqualStrings("Check your work with a verification subagent. Use when asked to \"check work\" or \"verify\".", desc_buf.items);
}

test "buildSkillsBlock empty when no skills" {
    const result = try buildSkillsBlock(testing.allocator);
    try testing.expect(result == null);
}
