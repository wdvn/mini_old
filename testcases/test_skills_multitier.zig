//! test_skills_multitier.zig — Integration tests for RFC-031 Multi-Tier Skills Architecture.
//!
//! Validates:
//!   1. Multi-tier directory hierarchy discovery (SKILL.md, references/, templates/, scripts/)
//!   2. Extended YAML frontmatter metadata (version, author, platforms, requires_tools)
//!   3. Sub-resource resolution via tool `skills` (operation="detail", file_path=...)
//!   4. Anti-traversal security guards on file_path
//!   5. CodeAct JS integration via `mini.skill(name, file_path?)`

const std = @import("std");
const mini = @import("mini");
const skills_mod = mini.skills_mod;
const registry = mini.tools_mod;
const quickjs = mini.quickjs_engine;

test "skills: multi-tier directory structure and extended metadata discovery" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // 1. Setup multi-tier skill directory hierarchy
    try tmp.dir.createDirPath(io, "skills/k8s-ops/references");
    try tmp.dir.createDirPath(io, "skills/k8s-ops/templates");
    try tmp.dir.createDirPath(io, "skills/k8s-ops/scripts");

    try tmp.dir.writeFile(io, .{
        .sub_path = "skills/k8s-ops/SKILL.md",
        .data =
            \\---
            \\name: k8s-ops
            \\description: Manage and operate Kubernetes clusters.
            \\version: 2.1.0
            \\author: Infrastructure Platform Team
            \\platforms: linux, darwin
            \\requires_tools: bash, http_request
            \\---
            \\# Kubernetes Ops Guide
            \\Comprehensive production workflow.
        ,
    });

    try tmp.dir.writeFile(io, .{
        .sub_path = "skills/k8s-ops/references/deploy_spec.md",
        .data = "# Deployment Specification v1\nSpecs for zero-downtime deployment.",
    });

    try tmp.dir.writeFile(io, .{
        .sub_path = "skills/k8s-ops/templates/manifest.yaml",
        .data = "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: app",
    });

    try tmp.dir.writeFile(io, .{
        .sub_path = "skills/k8s-ops/scripts/healthcheck.sh",
        .data = "#!/bin/bash\necho ok",
    });

    const real_tmp_path = try tmp.dir.realPathFileAlloc(io, "skills", alloc);
    defer alloc.free(real_tmp_path);

    var env_map = std.process.Environ.Map.init(alloc);
    defer env_map.deinit();
    try env_map.put("MINI_HOME", real_tmp_path[0 .. real_tmp_path.len - "/skills".len]);

    // 2. Load skills and verify discovery
    const count = skills_mod.loadSkills(alloc, io, &env_map);
    defer skills_mod.deinitSkills();

    try std.testing.expect(count >= 1);
    const skills = skills_mod.getSkills().?;
    var found: ?skills_mod.SkillInfo = null;
    for (skills) |s| {
        if (std.mem.eql(u8, s.name, "k8s-ops")) {
            found = s;
            break;
        }
    }
    try std.testing.expect(found != null);
    const s = found.?;

    try std.testing.expectEqualStrings("k8s-ops", s.name);
    try std.testing.expectEqualStrings("Manage and operate Kubernetes clusters.", s.description);
    try std.testing.expectEqualStrings("2.1.0", s.version.?);
    try std.testing.expectEqualStrings("Infrastructure Platform Team", s.author.?);
    try std.testing.expectEqualStrings("linux, darwin", s.platforms.?);
    try std.testing.expectEqualStrings("bash, http_request", s.requires_tools.?);
    try std.testing.expect(s.has_references);
    try std.testing.expect(s.has_templates);
    try std.testing.expect(s.has_scripts);

    // 3. Verify tool executeSkills (default detail with sub-resource manifest)
    const query_default = "{\"operation\":\"detail\",\"name\":\"k8s-ops\"}";
    const out_default = try registry.executeSkills(alloc, io, query_default);
    defer alloc.free(out_default);

    try std.testing.expect(std.mem.indexOf(u8, out_default, "## Skill: k8s-ops") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_default, "Version: 2.1.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_default, "Available Sub-Resources:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_default, "references/deploy_spec.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_default, "templates/manifest.yaml") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_default, "scripts/healthcheck.sh") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_default, "# Kubernetes Ops Guide") != null);

    // 4. Verify tool executeSkills with file_path loading sub-resource
    const query_ref = "{\"operation\":\"detail\",\"name\":\"k8s-ops\",\"file_path\":\"references/deploy_spec.md\"}";
    const out_ref = try registry.executeSkills(alloc, io, query_ref);
    defer alloc.free(out_ref);

    try std.testing.expect(std.mem.indexOf(u8, out_ref, "## Skill Resource: k8s-ops (references/deploy_spec.md)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_ref, "Deployment Specification v1") != null);

    const query_tmpl = "{\"operation\":\"detail\",\"name\":\"k8s-ops\",\"file_path\":\"templates/manifest.yaml\"}";
    const out_tmpl = try registry.executeSkills(alloc, io, query_tmpl);
    defer alloc.free(out_tmpl);

    try std.testing.expect(std.mem.indexOf(u8, out_tmpl, "apiVersion: apps/v1") != null);

    // 5. Verify security guard against path traversal attacks
    const query_attack1 = "{\"operation\":\"detail\",\"name\":\"k8s-ops\",\"file_path\":\"../../etc/shadow\"}";
    const out_attack1 = try registry.executeSkills(alloc, io, query_attack1);
    defer alloc.free(out_attack1);
    try std.testing.expect(std.mem.indexOf(u8, out_attack1, "Security error") != null);

    const query_attack2 = "{\"operation\":\"detail\",\"name\":\"k8s-ops\",\"file_path\":\"references/../../secret\"}";
    const out_attack2 = try registry.executeSkills(alloc, io, query_attack2);
    defer alloc.free(out_attack2);
    try std.testing.expect(std.mem.indexOf(u8, out_attack2, "Security error") != null);

    // 6. Verify CodeAct JS VM integration mini.skill(name, file_path?)
    var engine = try quickjs.Engine.init(alloc, io);
    defer engine.deinit();

    var js_res = try engine.eval(
        \\ const guide = mini.skill("k8s-ops");
        \\ const spec = mini.skill("k8s-ops", "references/deploy_spec.md");
        \\ const tmpl = mini.skill("k8s-ops", "templates/manifest.yaml");
        \\ const bad = mini.skill("k8s-ops", "../evil");
        \\ console.log("guide_ok:", guide.includes("Kubernetes Ops Guide"));
        \\ console.log("spec_ok:", spec.includes("Deployment Specification v1"));
        \\ console.log("tmpl_ok:", tmpl.includes("apiVersion: apps/v1"));
        \\ console.log("sec_ok:", bad.includes("Security error"));
    , "test_multitier.js");
    defer js_res.deinit();

    try std.testing.expect(!js_res.is_error);
    try std.testing.expect(std.mem.indexOf(u8, js_res.stdout, "guide_ok: true") != null);
    try std.testing.expect(std.mem.indexOf(u8, js_res.stdout, "spec_ok: true") != null);
    try std.testing.expect(std.mem.indexOf(u8, js_res.stdout, "tmpl_ok: true") != null);
    try std.testing.expect(std.mem.indexOf(u8, js_res.stdout, "sec_ok: true") != null);
}
