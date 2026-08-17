//! tools.zig — Registry và dispatcher cho toàn bộ tool system.
//!
//! Module trung tâm điều phối lời gọi tool từ AI đến handler tương ứng.
//!
//! ## Luồng hoạt động
//! 1. Agent nhận `tool_use` từ AI (name + input_json)
//! 2. Agent gọi `executeTool(alloc, name, input_json)`
//! 3. Registry kiểm tra policy (allowlist/blocklist)
//! 4. Dispatch đến handler tương ứng
//! 5. Nếu không tìm thấy → thử MCP manager
//!
//! ## Policy
//!   - Allowlist: nếu được set, CHỈ các tool trong list mới được chạy
//!   - Blocklist: các tool trong list bị từ chối
//!   - Allowlist có ưu tiên cao hơn blocklist
//!
//! ## Core tools (luôn gửi lên API)
//! bash, file_read, file_write, file_edit, glob, grep, http_request, web_search, skills
//!
//! ## Extended tools (gửi theo keyword match)
//! Xem `extended_triggers` bên dưới.

const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("protocol.zig");
const json = @import("json.zig");
const utils = @import("utils.zig");

const bash_tool = @import("tools/bash.zig");
const file_tool = @import("tools/file.zig");
const glob_tool = @import("tools/glob.zig");
const grep_tool = @import("tools/grep.zig");
const http_tool = @import("tools/http.zig");
const search_tool = @import("tools/search.zig");
const browser_tool = @import("tools/browser.zig");
const subagent = @import("tools/subagent.zig");
const batch_subagent = @import("tools/batch_subagent.zig");
const artifact_tool = @import("tools/artifact.zig");
const mcp_mod = @import("mcp.zig");
const hooks = @import("hooks.zig");

// ---------------------------------------------------------------------------
// Global state (single-threaded)
// ---------------------------------------------------------------------------

/// MCP manager — set bởi main.zig sau khi khởi tạo MCP.
var g_mcp: ?*mcp_mod.McpClientManager = null;

/// Allowlist comma-separated. Null = không giới hạn.
var g_allowlist: ?[]const u8 = null;

/// Blocklist comma-separated. Null = không chặn gì.
var g_blocklist: ?[]const u8 = null;

/// Thiết lập MCP manager để fallback khi không có built-in tool khớp.
pub fn setMcpManager(m: ?*mcp_mod.McpClientManager) void {
    g_mcp = m;
}

/// Thiết lập policy cho tool execution.
/// allowlist và blocklist là pointer vào config strings (không copy).
pub fn setPolicy(allowlist: ?[]const u8, blocklist: ?[]const u8) void {
    g_allowlist = allowlist;
    g_blocklist = blocklist;
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

fn executeToolInternal(alloc: Allocator, io: std.Io, name: []const u8, input_json: []const u8) ![]u8 {
    // Built-in tool dispatch
    if (std.mem.eql(u8, name, "bash"))          return bash_tool.executeTool(alloc, io, input_json);
    if (std.mem.eql(u8, name, "file_read"))     return file_tool.readTool(alloc, io, input_json);
    if (std.mem.eql(u8, name, "file_write"))    return file_tool.writeTool(alloc, io, input_json);
    if (std.mem.eql(u8, name, "file_edit"))     return file_tool.editTool(alloc, io, input_json);
    if (std.mem.eql(u8, name, "glob"))          return glob_tool.executeTool(alloc, io, input_json);
    if (std.mem.eql(u8, name, "grep"))          return grep_tool.executeTool(alloc, io, input_json);
    if (std.mem.eql(u8, name, "http_request"))  return http_tool.executeTool(alloc, input_json);
    if (std.mem.eql(u8, name, "web_search"))    return search_tool.executeTool(alloc, input_json);
    if (std.mem.eql(u8, name, "browser"))       return browser_tool.executeTool(alloc, io, input_json);
    if (std.mem.eql(u8, name, "invoke_subagent")) return subagent.executeTool(alloc, io, input_json);
    if (std.mem.eql(u8, name, "batch_invoke_subagents")) return batch_subagent.executeTool(alloc, io, input_json);
    if (std.mem.eql(u8, name, "artifact_write")) return artifact_tool.writeTool(alloc, io, input_json);
    if (std.mem.eql(u8, name, "artifact_read"))  return artifact_tool.readTool(alloc, io, input_json);
    if (std.mem.eql(u8, name, "artifact_list"))  return artifact_tool.listTool(alloc, io, input_json);
    if (std.mem.eql(u8, name, "skills"))        return executeSkills(alloc, input_json);

    // MCP fallback: tên có dạng "server__toolname"
    if (g_mcp) |mgr| {
        if (mgr.callTool(name, input_json)) |result| return result;
    }

    return std.fmt.allocPrint(alloc,
        "Tool không tồn tại: '{s}'. Dùng tool 'skills' để xem danh sách.", .{name},
    );
}

/// Thực thi tool theo tên.
/// Trả về kết quả dạng string. Caller phải free.
pub fn executeTool(alloc: Allocator, io: std.Io, name: []const u8, input_json: []const u8) ![]u8 {
    // Policy check
    if (!isPermitted(name)) {
        const err_msg = try std.fmt.allocPrint(alloc, "Tool '{s}' bị từ chối bởi policy hiện tại.", .{name});
        hooks.dispatch(alloc, io, .{
            .event = "post-tool-use",
            .tool_name = name,
            .input_json = input_json,
            .tool_result = err_msg,
            .is_error = true,
        });
        return err_msg;
    }

    hooks.dispatch(alloc, io, .{
        .event = "pre-tool-use",
        .tool_name = name,
        .input_json = input_json,
    });

    var is_error = false;
    const res = executeToolInternal(alloc, io, name, input_json) catch |e| blk: {
        is_error = true;
        break :blk try std.fmt.allocPrint(alloc, "Lỗi tool: {s}", .{@errorName(e)});
    };

    hooks.dispatch(alloc, io, .{
        .event = "post-tool-use",
        .tool_name = name,
        .input_json = input_json,
        .tool_result = res,
        .is_error = is_error,
    });

    return res;
}

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

/// Danh sách định nghĩa tất cả built-in tools.
/// Được gửi lên AI API trong mỗi request.
pub const definitions = [_]proto.ToolDefinition{
    .{
        .name = "bash",
        .description = "Chạy lệnh shell và trả về stdout/stderr. Dùng cho git, lệnh hệ thống, chạy script.",
        .input_schema_json = \\{"type":"object","properties":{"command":{"type":"string","description":"Lệnh shell cần chạy"}},"required":["command"]}
        ,
    },
    .{
        .name = "file_read",
        .description = "Đọc nội dung file. Trả về các dòng có đánh số. Dùng offset/limit cho file lớn.",
        .input_schema_json = \\{"type":"object","properties":{"path":{"type":"string","description":"Đường dẫn file"},"offset":{"type":"integer","description":"Bắt đầu từ dòng số (mặc định: 1)"},"limit":{"type":"integer","description":"Số dòng tối đa (mặc định: 2000)"}},"required":["path"]}
        ,
    },
    .{
        .name = "file_write",
        .description = "Tạo hoặc ghi đè file với nội dung cho trước. Tạo thư mục cha nếu cần.",
        .input_schema_json = \\{"type":"object","properties":{"path":{"type":"string","description":"Đường dẫn file"},"content":{"type":"string","description":"Nội dung cần ghi"}},"required":["path","content"]}
        ,
    },
    .{
        .name = "file_edit",
        .description = "Sửa file: tìm old_string (phải duy nhất trong file) và thay bằng new_string.",
        .input_schema_json = \\{"type":"object","properties":{"path":{"type":"string","description":"Đường dẫn file"},"old_string":{"type":"string","description":"Chuỗi cần tìm (phải duy nhất)"},"new_string":{"type":"string","description":"Chuỗi thay thế"}},"required":["path","old_string","new_string"]}
        ,
    },
    .{
        .name = "glob",
        .description = "Tìm file theo wildcard pattern. Hỗ trợ *, **, ? . Ví dụ: **/*.zig, src/*.ts",
        .input_schema_json = \\{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern (ví dụ: **/*.zig)"},"path":{"type":"string","description":"Thư mục gốc để tìm (mặc định: .)"}},"required":["pattern"]}
        ,
    },
    .{
        .name = "grep",
        .description = "Tìm kiếm nội dung trong file. Trả về path:dòng:nội_dòng.",
        .input_schema_json = \\{"type":"object","properties":{"pattern":{"type":"string","description":"Pattern cần tìm"},"path":{"type":"string","description":"File hoặc thư mục (mặc định: .)"},"case_insensitive":{"type":"string","description":"\"true\" để tìm không phân biệt hoa thường"}},"required":["pattern"]}
        ,
    },
    .{
        .name = "http_request",
        .description = "Gửi HTTP request đến bất kỳ URL. Hỗ trợ GET, POST, PUT, DELETE, HEAD. Response tối đa 30KB.",
        .input_schema_json = \\{"type":"object","properties":{"url":{"type":"string","description":"URL đầy đủ (phải có http:// hoặc https://)"},"method":{"type":"string","enum":["GET","POST","PUT","DELETE","HEAD"],"description":"HTTP method (mặc định: GET)"},"body":{"type":"string","description":"Request body (cho POST/PUT)"},"headers":{"type":"object","description":"Custom headers dạng key-value"}},"required":["url"]}
        ,
    },
    .{
        .name = "web_search",
        .description = "Tìm kiếm web qua DuckDuckGo. Trả về tiêu đề, URL và snippet. Không cần API key.",
        .input_schema_json = \\{"type":"object","properties":{"query":{"type":"string","description":"Câu tìm kiếm"},"num_results":{"type":"integer","description":"Số kết quả (1-10, mặc định: 5)"}},"required":["query"]}
        ,
    },
    .{
        .name = "browser",
        .description = "Điều khiển trình duyệt bằng Playwright. Hỗ trợ goto, click, type, screenshot, html, scroll, drag_drop, exec, upload_file.",
        .input_schema_json = \\{"type":"object","properties":{"action":{"type":"string","enum":["goto","click","type","screenshot","html","scroll","drag_drop","exec","upload_file"],"description":"Hành động cần thực hiện"},"url":{"type":"string","description":"URL (cho goto)"},"selector":{"type":"string","description":"CSS/XPath selector (cho click/type/drag_drop/upload_file)"},"target_selector":{"type":"string","description":"Selector đích (cho drag_drop)"},"text":{"type":"string","description":"Nội dung cần gõ (cho type)"},"script":{"type":"string","description":"Javascript code (cho exec)"},"direction":{"type":"string","enum":["up","down"],"description":"Hướng cuộn (cho scroll)"},"distance":{"type":"string","description":"Khoảng cách cuộn px (cho scroll)"},"profile_dir":{"type":"string","description":"Thư mục profile để giữ session"},"path":{"type":"string","description":"Đường dẫn lưu ảnh (hoặc đường dẫn file để upload)"}},"required":["action"]}
        ,
    },
    .{
        .name = "invoke_subagent",
        .description = "Gọi một agent con để thực hiện một tác vụ phức tạp (chia để trị). Phù hợp khi cần phân tích thư mục, refactor nhiều file, hoặc xử lý chuỗi hành động dài.",
        .input_schema_json = \\{"type":"object","properties":{"task":{"type":"string","description":"Nhiệm vụ chi tiết dành cho sub-agent"}},"required":["task"]}
        ,
    },
    .{
        .name = "batch_invoke_subagents",
        .description = "Gọi nhiều agent con chạy song song để xử lý các tác vụ độc lập. Phù hợp cho batch processing (ví dụ: upload nhiều video cùng lúc).",
        .input_schema_json = \\{"type":"object","properties":{"tasks":{"type":"array","items":{"type":"string"},"description":"Danh sách các nhiệm vụ chi tiết dành cho các sub-agent"}},"required":["tasks"]}
        ,
    },
    .{
        .name = "skills",
        .description = "Xem danh sách tool đang có. operation=\"list\" để liệt kê, operation=\"detail\" với name=<tool> để xem chi tiết.",
        .input_schema_json = \\{"type":"object","properties":{"operation":{"type":"string","enum":["list","detail"],"description":"list hoặc detail"},"name":{"type":"string","description":"Tên tool (cho detail)"}},"required":[]}
        ,
    },
    .{
        .name = "artifact_write",
        .description = "Tạo hoặc cập nhật một artifact độc lập (kế hoạch, walkthrough, markdown, html, svg, code diff, mockup). Tự động lưu vào session artifacts và kích hoạt live preview hook.",
        .input_schema_json = \\{"type":"object","properties":{"name":{"type":"string","description":"Tên tệp artifact (ví dụ: plan.md, walkthrough.md, preview.html, diagram.svg)"},"content":{"type":"string","description":"Nội dung tệp artifact"},"title":{"type":"string","description":"Tiêu đề mô tả ngắn cho artifact"},"type":{"type":"string","enum":["markdown","html","svg","code","diff","text"],"description":"Loại artifact (mặc định: markdown)"},"summary":{"type":"string","description":"Tóm tắt ngắn gọn nội dung artifact"},"user_facing":{"type":"string","enum":["true","false"],"description":"true nếu là tài liệu cho người dùng xem"}},"required":["name","content"]}
        ,
    },
    .{
        .name = "artifact_read",
        .description = "Đọc nội dung một artifact đã lưu trong session hiện tại theo tên.",
        .input_schema_json = \\{"type":"object","properties":{"name":{"type":"string","description":"Tên artifact cần đọc (ví dụ: plan.md)"}},"required":["name"]}
        ,
    },
    .{
        .name = "artifact_list",
        .description = "Liệt kê danh sách tất cả artifacts kèm metadata và đường dẫn trong session hiện tại.",
        .input_schema_json = \\{"type":"object","properties":{},"required":[]}
        ,
    },
};

/// Các tên tool core (luôn gửi lên API).
const core_tools = [_][]const u8{
    "bash", "file_read", "file_write", "file_edit",
    "glob", "grep", "http_request", "web_search", "browser", "invoke_subagent", "batch_invoke_subagents", "skills",
    "artifact_write", "artifact_read", "artifact_list",
};

/// Keyword trigger cho extended tools (gửi theo ngữ cảnh).
const Trigger = struct {
    tool: []const u8,
    keywords: []const []const u8,
};

const extended_triggers = [_]Trigger{
    // Không có extended tools trong phiên bản minimal này.
    // Thêm ở đây khi bổ sung tools mới.
};

// ---------------------------------------------------------------------------
// Tool selection
// ---------------------------------------------------------------------------

/// Buffer cho filtered tool list (module-level, single-threaded safe).
var filtered_buf: [definitions.len + 64]proto.ToolDefinition = undefined;

/// Trả về tất cả tool definitions.
pub fn getDefinitions() []const proto.ToolDefinition {
    return &definitions;
}

/// Trả về tool definitions phù hợp với user message.
/// Core tools luôn được include. Extended tools chỉ khi có keyword match.
/// MCP tools được append thêm nếu có McpManager.
pub fn getRelevantDefinitions(alloc: Allocator, user_text: []const u8) []const proto.ToolDefinition {
    var count: usize = 0;

    // Core tools (subject to policy)
    for (&definitions) |*td| {
        if (!isCoreTool(td.name)) continue;
        if (!isPermitted(td.name)) continue;
        filtered_buf[count] = td.*;
        count += 1;
    }

    // Extended tools theo keyword
    for (&extended_triggers) |*t| {
        for (t.keywords) |kw| {
            if (containsCI(user_text, kw)) {
                // Tìm definition
                for (&definitions) |*td| {
                    if (std.mem.eql(u8, td.name, t.tool) and isPermitted(td.name)) {
                        filtered_buf[count] = td.*;
                        count += 1;
                        break;
                    }
                }
                break;
            }
        }
    }

    // MCP tools
    if (g_mcp) |mgr| {
        const mcp_tools = mgr.getToolDefinitions(alloc);
        defer if (mcp_tools.len > 0) alloc.free(mcp_tools);
        for (mcp_tools) |mt| {
            if (count >= filtered_buf.len) break;
            filtered_buf[count] = mt;
            count += 1;
        }
    }

    return filtered_buf[0..count];
}

fn isCoreTool(name: []const u8) bool {
    for (&core_tools) |ct| {
        if (std.mem.eql(u8, name, ct)) return true;
    }
    return false;
}

fn isPermitted(name: []const u8) bool {
    if (g_allowlist) |list| {
        // Allowlist: CHỈ cho phép những tool được liệt kê
        var it = std.mem.splitScalar(u8, list, ',');
        while (it.next()) |entry| {
            if (std.mem.eql(u8, std.mem.trim(u8, entry, " \t"), name)) return true;
        }
        return false; // không có trong allowlist
    }
    if (g_blocklist) |list| {
        var it = std.mem.splitScalar(u8, list, ',');
        while (it.next()) |entry| {
            if (std.mem.eql(u8, std.mem.trim(u8, entry, " \t"), name)) return false;
        }
    }
    return true;
}

fn containsCI(text: []const u8, kw: []const u8) bool {
    if (kw.len > text.len) return false;
    var i: usize = 0;
    while (i + kw.len <= text.len) : (i += 1) {
        var match = true;
        for (0..kw.len) |j| {
            if (std.ascii.toLower(text[i + j]) != std.ascii.toLower(kw[j])) {
                match = false; break;
            }
        }
        if (match) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Skills tool (liệt kê tools)
// ---------------------------------------------------------------------------

fn executeSkills(alloc: Allocator, input_json: []const u8) ![]u8 {
    const operation = json.findString(input_json, "operation") orelse "list";

    if (std.mem.eql(u8, operation, "detail")) {
        const name = json.findString(input_json, "name") orelse
            return std.fmt.allocPrint(alloc, "Lỗi: cần trường 'name' cho operation detail", .{});
        for (&definitions) |*td| {
            if (std.mem.eql(u8, td.name, name)) {
                return std.fmt.allocPrint(alloc,
                    "## {s}\n\n{s}\n\n**Schema:**\n```json\n{s}\n```",
                    .{ td.name, td.description, td.input_schema_json },
                );
            }
        }
        return std.fmt.allocPrint(alloc, "Không tìm thấy tool '{s}'.", .{name});
    }

    // List all
    var buf = utils.BufWriter.init(alloc);
    errdefer buf.deinit();
    const w = &buf;
    try w.writeAll("## Danh sách tools\n\n");
    for (&definitions) |*td| {
        const permitted = isPermitted(td.name);
        const status = if (permitted) "✓" else "✗";
        try w.print("  {s} **{s}** — {s}\n", .{ status, td.name, td.description });
    }
    if (g_mcp) |mgr| {
        if (mgr.servers.items.len > 0) {
            try w.writeAll("\n## MCP Tools\n\n");
            for (mgr.servers.items) |*server| {
                for (server.tools.items) |t| {
                    try w.print("  ✓ **{s}** — {s}\n", .{ t.prefixed_name, t.description });
                }
            }
        }
    }
    return buf.toOwnedSlice();
}
