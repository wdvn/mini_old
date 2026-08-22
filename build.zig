//! build.zig — Build system cho mini-agent.
//!
//! ## Targets
//!   zig build              → zig-out/bin/mini (native)
//!   zig build run          → build và chạy interactive REPL
//!   zig build run -- -e .. → build và chạy single-shot
//!
//! ## Cross-compile
//!   zig build -Dtarget=x86_64-linux-gnu
//!   zig build -Dtarget=aarch64-linux-gnu
//!
//! ## Dependencies (dynamic linking)
//!   libcurl  — HTTPS requests đến AI APIs và web search
//!   libsqlite3 — (reserved cho future history persistence)

const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -----------------------------------------------------------------------
    // Build info: timestamp + metadata, inject vào binary qua options module.
    // Giá trị đổi theo mỗi lần chạy `zig build` → cache luôn bị invalidate,
    // binary luôn mang timestamp của lần build gần nhất.
    // -----------------------------------------------------------------------
    const now_ts = std.Io.Timestamp.now(b.graph.io, .real);
    const build_info = b.addOptions();
    build_info.addOption([]const u8, "build_time", formatBuildTime(b.allocator, now_ts.toSeconds()));
    build_info.addOption([]const u8, "optimize_mode", @tagName(optimize));
    build_info.addOption([]const u8, "target_triple", target.result.zigTriple(b.allocator) catch "unknown");
    build_info.addOption([]const u8, "zig_version", builtin.zig_version_string);

    const quickjs_dep = b.dependency("quickjs", .{});
    const qjs_path = quickjs_dep.path("");

    const qjs_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    qjs_mod.addCSourceFiles(.{
        .root = qjs_path,
        .files = &.{
            "quickjs.c",
            "libregexp.c",
            "libunicode.c",
            "cutils.c",
            "libbf.c",
        },
        .flags = &.{
            "-D_GNU_SOURCE",
            "-DCONFIG_VERSION=\"0.8.0\"",
            "-DCONFIG_BIGNUM",
        },
    });
    qjs_mod.addIncludePath(qjs_path);

    const qjs_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "quickjs",
        .root_module = qjs_mod,
    });

    // -----------------------------------------------------------------------
    // mini-agent executable
    // -----------------------------------------------------------------------

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addIncludePath(qjs_path);
    exe_mod.linkLibrary(qjs_lib);
    exe_mod.addOptions("build_info", build_info);

    const exe = b.addExecutable(.{
        .name = "mini",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    // -----------------------------------------------------------------------
    // Run step: `zig build run -- [args]`
    // -----------------------------------------------------------------------

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Build và chạy mini-agent");
    run_step.dependOn(&run_cmd.step);

    // -----------------------------------------------------------------------
    // Test step: `zig build test`
    // -----------------------------------------------------------------------

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addIncludePath(qjs_path);
    test_mod.linkLibrary(qjs_lib);
    test_mod.addOptions("build_info", build_info);

    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Chạy unit tests");
    test_step.dependOn(&run_tests.step);
}

/// Format Unix timestamp thành "YYYY-MM-DD HH:MM:SS UTC" (không phụ thuộc libc).
fn formatBuildTime(alloc: std.mem.Allocator, ts: i64) []const u8 {
    const epoch: u64 = if (ts > 0) @intCast(ts) else 0;
    const es = std.time.epoch.EpochSeconds{ .secs = epoch };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();

    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch "unknown";
}
