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
    // Test step: `zig build test` (All-In-One: unit tests + testcases + E2E mock)
    // -----------------------------------------------------------------------

    const skip_e2e = b.option(bool, "skip-e2e", "Bỏ qua E2E tests với mock LLM server") orelse false;
    const test_port = b.option([]const u8, "test-port", "Port cho mock LLM server (mặc định: 8399)") orelse "8399";

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addIncludePath(qjs_path);
    test_mod.linkLibrary(qjs_lib);
    test_mod.addOptions("build_info", build_info);

    // Module "mini" cho testcases/ import (rooted tại src/main.zig)
    const testcase_mod = b.createModule(.{
        .root_source_file = b.path("testcases/test_codeact_security.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    testcase_mod.addImport("mini", test_mod);
    testcase_mod.addIncludePath(qjs_path);
    testcase_mod.linkLibrary(qjs_lib);

    // 1. Unit tests (src/main.zig)
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);

    // 2. Integration / Security testcases (testcases/test_codeact_security.zig)
    const testcase_tests = b.addTest(.{ .root_module = testcase_mod });
    const run_testcase_tests = b.addRunArtifact(testcase_tests);

    // Step test-unit: chạy riêng unit tests và testcases
    const test_unit_step = b.step("test-unit", "Chạy riêng unit tests & testcases (không kèm E2E mock)");
    test_unit_step.dependOn(&run_tests.step);
    test_unit_step.dependOn(&run_testcase_tests.step);

    // 3. E2E tests với mock LLM server
    const run_e2e = b.addSystemCommand(&.{
        "bash",
        "scripts/run_tests_with_mock.sh",
        "--e2e-only",
    });
    run_e2e.addArtifactArg(exe);
    run_e2e.addArg(test_port);
    run_e2e.stdio = .inherit;
    run_e2e.step.dependOn(b.getInstallStep());

    // Step test-e2e: chạy riêng E2E tests
    const test_e2e_step = b.step("test-e2e", "Chạy riêng E2E tests với mock LLM server");
    test_e2e_step.dependOn(&run_e2e.step);

    // Step test chính: ALL-IN-ONE (unit tests -> testcases -> E2E mock LLM)
    const test_step = b.step("test", "Chạy all-in-one test suite (unit tests + testcases + mock LLM E2E)");
    test_step.dependOn(test_unit_step);
    if (!skip_e2e) {
        // Đảm bảo unit tests hoàn thành thành công trước khi chạy E2E
        run_e2e.step.dependOn(test_unit_step);
        test_step.dependOn(&run_e2e.step);
    }
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
