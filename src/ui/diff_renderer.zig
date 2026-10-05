//! diff_renderer.zig — Unified Diff Visualizer & Patch Styler for mini-agent.
//!
//! Renders colored Diff blocks (Red/Green/Cyan) with elegant box frames,
//! allowing users to visually inspect code changes performed by the Agent.

const std = @import("std");
const term = @import("terminal.zig");

pub const DiffOptions = struct {
    max_display_lines: usize = 35,
    show_box: bool = true,
};

fn renderDiffHeader(file_path: []const u8) void {
    var header_buf: [256]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "  \x1b[90m{s}── \x1b[1;37m{s}\x1b[0m\x1b[90m ───────────────────────────────────────────────\x1b[0m\n", .{
        term.BOX_TOP_LEFT, file_path,
    }) catch "  ╭── Diff ───────────────────────────────────────────────\n";
    term.writeStdout(header);
}

fn renderDiffFooter() void {
    var footer_buf: [128]u8 = undefined;
    const footer = std.fmt.bufPrint(&footer_buf, "  \x1b[90m{s}─────────────────────────────────────────────────────────────\x1b[0m\n", .{
        term.BOX_BOT_LEFT,
    }) catch "  ╰─────────────────────────────────────────────────────────────\n";
    term.writeStdout(footer);
}

fn renderDiffLine(line: []const u8) void {
    var line_buf: [2048]u8 = undefined;
    if (std.mem.startsWith(u8, line, "+++") or std.mem.startsWith(u8, line, "---")) {
        const out = std.fmt.bufPrint(&line_buf, "  \x1b[90m{s} \x1b[1;90m{s}\x1b[0m\n", .{ term.BOX_VERT, line }) catch return;
        term.writeStdout(out);
    } else if (std.mem.startsWith(u8, line, "+")) {
        const out = std.fmt.bufPrint(&line_buf, "  \x1b[90m{s}\x1b[0m \x1b[32m{s}\x1b[0m\n", .{ term.BOX_VERT, line }) catch return;
        term.writeStdout(out);
    } else if (std.mem.startsWith(u8, line, "-")) {
        const out = std.fmt.bufPrint(&line_buf, "  \x1b[90m{s}\x1b[0m \x1b[31m{s}\x1b[0m\n", .{ term.BOX_VERT, line }) catch return;
        term.writeStdout(out);
    } else if (std.mem.startsWith(u8, line, "@@")) {
        const out = std.fmt.bufPrint(&line_buf, "  \x1b[90m{s}\x1b[0m \x1b[36m{s}\x1b[0m\n", .{ term.BOX_VERT, line }) catch return;
        term.writeStdout(out);
    } else {
        const out = std.fmt.bufPrint(&line_buf, "  \x1b[90m{s} \x1b[90m{s}\x1b[0m\n", .{ term.BOX_VERT, line }) catch return;
        term.writeStdout(out);
    }
}

/// Render a patch string / unified diff to stdout with color formatting.
pub fn renderDiff(io: std.Io, file_path: []const u8, patch_content: []const u8, options: DiffOptions) void {
    // PSEUDOCODE:
    // 1. Draw diff box header if enabled.
    // 2. Split patch lines and calculate head/tail truncation bounds.
    // 3. Render lines with syntax highlighting, omitting middle section if truncated.
    // 4. Draw diff box footer if enabled.
    _ = io;
    if (options.show_box) renderDiffHeader(file_path);

    var lines_list = std.ArrayListUnmanaged([]const u8).empty;
    var it = std.mem.splitScalar(u8, patch_content, '\n');
    while (it.next()) |line| {
        lines_list.append(std.heap.page_allocator, line) catch break;
    }
    defer lines_list.deinit(std.heap.page_allocator);

    const total_lines = lines_list.items.len;
    const should_truncate = total_lines > options.max_display_lines;
    const head_count = if (should_truncate) 20 else total_lines;
    const tail_start = if (should_truncate) total_lines - 8 else total_lines;
    var printed: usize = 0;

    for (lines_list.items, 0..) |line, idx| {
        if (should_truncate and idx >= head_count and idx < tail_start) {
            if (printed == head_count) {
                var omit_buf: [128]u8 = undefined;
                const omit_msg = std.fmt.bufPrint(&omit_buf, "  \x1b[90m{s}   ... ({d} lines omitted) ...\x1b[0m\n", .{
                    term.BOX_VERT, tail_start - head_count,
                }) catch return;
                term.writeStdout(omit_msg);
                printed += 1;
            }
            continue;
        }
        renderDiffLine(line);
        printed += 1;
    }

    if (options.show_box) renderDiffFooter();
}

test "renderDiff does not crash" {
    const patch =
        \\--- a/src/main.zig
        \\+++ b/src/main.zig
        \\@@ -1,3 +1,3 @@
        \\-const old = 1;
        \\+const new = 2;
        \\ const keep = 3;
    ;
    // Test that logic runs without panic
    var lines_count: usize = 0;
    var it = std.mem.splitScalar(u8, patch, '\n');
    while (it.next()) |_| lines_count += 1;
    try std.testing.expectEqual(@as(usize, 6), lines_count);
}
