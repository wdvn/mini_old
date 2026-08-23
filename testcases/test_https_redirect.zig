//! Scratch test: redirect http → https qua lib/http_request.zig — reproduce bug
//! panic "attempt to use null value" (arxiv 301 http→https). Chạy: zig run test_https_redirect.zig

const std = @import("std");
const http_lib = @import("src/lib/http_request.zig");

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    const alloc = gpa.allocator();
    const io = init.io;

    var res = http_lib.fetch(alloc, io, .{
        .url = "http://export.arxiv.org/api/query?search_query=cat:cs.AI&max_results=1",
        .timeout_s = 30,
    }) catch |e| {
        std.debug.print("FAIL: {s}\n", .{@errorName(e)});
        return e;
    };
    defer res.deinit(alloc);
    std.debug.print("OK redirect http→https: status={d} body_len={d}\n", .{ res.status, res.body.len });
}
