//! tools/artifact.zig — Tool tạo, đọc và quản lý Artifacts cho Agent.
//!
//! Cho phép Agent xuất các sản phẩm công việc độc lập (kế hoạch, walkthrough,
//! diagrams, code diffs, html previews) ra thư mục artifact của session và
//! tự động kích hoạt event hook thời gian thực (Level D).

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../core/json.zig");
const artifacts = @import("../core/artifacts.zig");
const hooks = @import("../core/hooks.zig");

/// Tool artifact_write: Tạo hoặc cập nhật một artifact.
/// Input: {"name":"...", "content":"...", "title":"...", "type":"markdown", "summary":"...", "user_facing":true}
pub fn writeTool(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    const name = json.findString(input_json, "name") orelse
        return std.fmt.allocPrint(alloc, "Lỗi: thiếu trường 'name' cho artifact", .{});
    const content = json.findString(input_json, "content") orelse
        return std.fmt.allocPrint(alloc, "Lỗi: thiếu trường 'content' cho artifact", .{});

    const title = json.findString(input_json, "title");
    const art_type = json.findString(input_json, "type") orelse "markdown";
    const summary = json.findString(input_json, "summary");

    // Check user_facing
    var user_facing = true;
    if (json.findString(input_json, "user_facing")) |uf| {
        if (std.mem.eql(u8, uf, "false")) user_facing = false;
    }

    // Unescape content nếu cần
    const unescaped = json.unescape(alloc, content) catch content;
    defer if (!std.mem.eql(u8, content, unescaped)) alloc.free(unescaped);

    // Ghi file artifact và cập nhật metadata
    const path = try artifacts.writeArtifact(alloc, io, name, title, unescaped, art_type, summary, user_facing);
    defer alloc.free(path);

    // Bắn sự kiện thời gian thực qua Hooks (Level D: Live Preview / External UI)
    hooks.dispatch(alloc, io, .{
        .event = "artifact_saved",
        .artifact_name = name,
        .artifact_path = path,
        .artifact_type = art_type,
        .artifact_title = title orelse name,
    });

    return std.fmt.allocPrint(alloc,
        "Đã lưu artifact thành công tại: [{s}](file://{s})\nSession: {s} | Type: {s}",
        .{ name, path, artifacts.getSessionId(), art_type },
    );
}

/// Tool artifact_read: Đọc nội dung một artifact đã lưu.
/// Input: {"name":"..."}
pub fn readTool(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    const name = json.findString(input_json, "name") orelse
        return std.fmt.allocPrint(alloc, "Lỗi: thiếu trường 'name'", .{});

    return artifacts.readArtifact(alloc, io, name);
}

/// Tool artifact_list: Liệt kê tất cả artifacts trong session hiện tại.
/// Input: {}
pub fn listTool(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    _ = input_json;
    return artifacts.listArtifacts(alloc, io);
}
