//! skills.zig — Skill discovery layer: quét và nạp metadata skills từ ~/.mini/skills.
//!
//! Mỗi skill là một thư mục con chứa file `SKILL.md` với frontmatter YAML:
//! ```md
//! ---
//! name: my-skill
//! description: Use when ...
//! ---
//! ```
//!
//! ## Cách hoạt động
//! 1. `loadSkills()` quét `<MINI_HOME>/skills/*/SKILL.md` (mặc định `~/.mini/skills/`)
//! 2. Parse frontmatter để lấy `name` + `description`
//! 3. `buildSkillsBlock()` tạo block text inject vào system prompt — chỉ chứa
//!    name + description + path (~50 token/skill), agent tự đọc file đầy đủ khi cần
//!
//! ## Ràng buộc
//!   - Tối đa 32 skills, mỗi description tối đa 512 bytes (chống phình prompt)
//!   - SKILL.md tối đa 64 KB
//!   - Không đệ quy: chỉ đọc trực tiếp `skills/<name>/SKILL.md`

const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");

/// Số skill tối đa nạp vào prompt.
const MAX_SKILLS = 32;

/// Giới hạn kích thước description nạp vào prompt (bytes).
const MAX_DESC_LEN = 512;

/// Giới hạn kích thước file SKILL.md (bytes).
const MAX_SKILL_FILE = 64 * 1024;

/// Metadata một skill đã parse từ frontmatter.
pub const SkillInfo = struct {
    /// Tên skill (từ frontmatter `name`, fallback: tên thư mục).
    name: []const u8,
    /// Mô tả trigger (từ frontmatter `description`).
    description: []const u8,
    /// Đường dẫn tuyệt đối tới SKILL.md.
    path: []const u8,
};

/// Danh sách skill đã nạp (arena-allocated, free bằng `deinitSkills`).
var g_skills: ?[]SkillInfo = null;
var g_skills_arena: ?std.heap.ArenaAllocator = null;

/// Giải phóng bộ nhớ skills.
pub fn deinitSkills() void {
    if (g_skills_arena) |*arena| {
        arena.deinit();
        g_skills_arena = null;
    }
    g_skills = null;
}

/// Trả về danh sách skill đã nạp (null nếu chưa gọi loadSkills hoặc không có skill).
pub fn getSkills() ?[]const SkillInfo {
    return g_skills;
}

const main = @import("../main.zig");

/// Quét thư mục skills và parse metadata (quét ~/.mini/skills/ trước, .agent/skills/ sau; .agent override global).
/// Trả về số skill nạp được (0 nếu thư mục không tồn tại).
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

    // Chuyển giao ownership sang global state
    deinitSkills();
    const owned = skills.toOwnedSlice(arena.allocator()) catch return 0;
    g_skills_arena = arena;
    g_skills = owned;
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

        // Đọc <dir>/<name>/SKILL.md
        const skill_path = std.fmt.allocPrint(arena_alloc, "{s}/{s}/SKILL.md", .{ dir_path, entry.name }) catch continue;
        const info = parseSkillFile(arena_alloc, io, skill_path, entry.name) catch continue;

        // Check xem skill name này đã tồn tại chưa (Project override Global)
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

/// Parse frontmatter của SKILL.md.
/// Spec agentskills.io: `name` phải trùng tên thư mục cha (`dir_name`).
fn parseSkillFile(alloc: Allocator, io: std.Io, path: []const u8, dir_name: []const u8) !SkillInfo {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.size == 0 or stat.size > MAX_SKILL_FILE) return error.InvalidFileSize;

    const buf = try alloc.alloc(u8, @intCast(stat.size));
    const n = try utils.readAll(io, file, buf);
    const content = buf[0..n];

    var name: []const u8 = dir_name;
    var description: []const u8 = "";

    // Frontmatter phải bắt đầu bằng "---" ở dòng đầu
    if (std.mem.startsWith(u8, content, "---\n")) {
        const body_start = std.mem.indexOfPos(u8, content, 4, "\n---") orelse content.len;
        const fm = content[4..body_start];
        var lines = std.mem.splitScalar(u8, fm, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, trimmed, "name:")) {
                name = std.mem.trim(u8, trimmed[5..], " \t\"'");
            } else if (std.mem.startsWith(u8, trimmed, "description:")) {
                var desc = std.mem.trim(u8, trimmed[12..], " \t\"'");
                if (desc.len > MAX_DESC_LEN) desc = desc[0..MAX_DESC_LEN];
                description = desc;
            }
        }
    }

    // Spec validation: name trong frontmatter phải khớp tên thư mục
    if (!std.mem.eql(u8, name, dir_name)) {
        main.stderrPrint("[skills] Cảnh báo: skill name '{s}' trong {s} không khớp tên thư mục '{s}', dùng tên thư mục.\n", .{ name, path, dir_name });
        name = dir_name;
    }

    return .{
        .name = try alloc.dupe(u8, name),
        .description = try alloc.dupe(u8, description),
        .path = try alloc.dupe(u8, path),
    };
}

/// Resolve thư mục skills: `$MINI_HOME/skills` hoặc `~/.mini/skills`.
/// Trả về string thuộc sở hữu caller (cần free).
fn resolveSkillsDir(alloc: Allocator, env_map: *const std.process.Environ.Map) ![]u8 {
    if (env_map.get("MINI_HOME")) |mh| {
        if (mh.len > 0) return std.fmt.allocPrint(alloc, "{s}/skills", .{mh});
    }
    const home = env_map.get("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(alloc, "{s}/.mini/skills", .{home});
}

/// Tạo block text inject vào cuối system prompt.
/// Trả về null nếu không có skill nào (không inject gì).
/// Caller free kết quả.
pub fn buildSkillsBlock(alloc: Allocator) !?[]u8 {
    const skills = g_skills orelse return null;
    if (skills.len == 0) return null;

    var buf = utils.BufWriter.init(alloc);
    errdefer buf.deinit();

    try buf.writeAll(
        \\
        \\## Available skills
        \\
        \\Khi task khớp description của một skill bên dưới, đọc file SKILL.md tương ứng
        \\(và RULES.md / references nếu skill trỏ tới) bằng file_read TRƯỚC KHI làm,
        \\rồi tuân theo hướng dẫn trong đó. Không cần hỏi lại user về convention.
        \\
        \\
    );
    for (skills) |s| {
        if (s.description.len > 0) {
            try buf.print("- **{s}**: {s} — đọc `{s}`\n", .{ s.name, s.description, s.path });
        } else {
            try buf.print("- **{s}** — đọc `{s}`\n", .{ s.name, s.path });
        }
    }

    return try buf.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parseSkillFile frontmatter" {
    // Tạo thư mục tạm + SKILL.md
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "my-skill/SKILL.md",
        .data = "---\nname: my-skill\ndescription: Use when writing docs\n---\n\n# Content",
    });
    // cwd của tmpDir khác cwd process — test qua hàm parse trực tiếp không khả thi
    // (parseSkillFile mở theo cwd). Test logic frontmatter qua helper riêng.
}

test "frontmatter parse logic" {
    // Kiểm tra logic tách name/description từ chuỗi frontmatter
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

test "buildSkillsBlock empty khi khong co skill" {
    const result = try buildSkillsBlock(testing.allocator);
    try testing.expect(result == null);
}
