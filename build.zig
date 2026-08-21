//! build.zig — Build system cho mini-agent.
//!
//! ## Targets
//!   zig build              → zig-out/bin/mini-agent (native)
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

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Chạy unit tests");
    test_step.dependOn(&run_tests.step);
}
