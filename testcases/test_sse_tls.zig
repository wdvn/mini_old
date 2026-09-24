//! Scratch test: reproduce TlsInitializationFailed/WriteFailed error of std.http.Client
//! via lib/http_request.zig (postStream) when calling OPENAI_COMPAT_URL. Run: zig run test_sse_tls.zig

const std = @import("std");
const main_mod = @import("mini");
const sse = main_mod.http_request;

var sink_buffer: [4096]u8 = undefined;
var total: usize = 0;

fn onChunk(chunk: []const u8, _: *anyopaque) void {
    total += chunk.len;
    if (total < 600) {
        const n = @min(chunk.len, sink_buffer.len - 1);
        @memcpy(sink_buffer[0..n], chunk[0..n]);
        sink_buffer[n] = 0;
    }
}

pub fn main(init: std.process.Init) !void {
    main_mod.g_io = init.io;
    var gpa = std.heap.DebugAllocator(.{}){};
    const alloc = gpa.allocator();

    const url = init.environ_map.get("OPENAI_COMPAT_URL") orelse "https://api.techopenclaw.com/v1";
    const model = init.environ_map.get("OPENAI_COMPAT_MODEL") orelse "deepseek-v4-flash";

    var full = std.ArrayList(u8).empty;
    defer full.deinit(alloc);
    try full.appendSlice(alloc, url);
    try full.appendSlice(alloc, "/chat/completions");

    const body = try std.fmt.allocPrint(alloc,
        \\{{"model":"{s}","stream":true,"max_tokens":32,"messages":[{{"role":"user","content":"hi"}}]}}
    , .{model});
    defer alloc.free(body);

    std.debug.print("POST {s}\n", .{full.items});
    const code = sse.postStream(alloc, main_mod.g_io, .{
        .url = full.items,
        .headers = &.{
            "Content-Type: application/json",
            "Authorization: Bearer toc-a7b1bcf3c0a74074a58d5a2db40a2f64-wglak9-84016094",
        },
        .body = body,
    }, onChunk, undefined) catch |e| {
        std.debug.print("ERROR: {s}\n", .{@errorName(e)});
        return e;
    };
    std.debug.print("HTTP {d}, bytes={d}\nfirst: {s}\n", .{ code, total, sink_buffer[0..@min(total, 500)] });
}
