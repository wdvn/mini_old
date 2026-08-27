//! journal.zig — Act Journal
//! Durable Write-Ahead Log (WAL) cho Event-Driven Act Architecture.
//!
//! Retention: mỗi process sinh 1 file `journal_<pid>.jsonl` trong thư mục
//! sessions — `init` tự động prune file cũ, chỉ giữ lại `max_journal_files`
//! file mới nhất (override bằng env `MINI_JOURNAL_KEEP`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");
const json_mod = @import("json.zig");

// Zig 0.16: std.posix.getenv không còn — extern libc getenv (build link libc),
// cùng pattern với agent.zig / artifacts.zig.
extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn unsetenv(name: [*:0]const u8) c_int;

fn getEnvVar(name: [*:0]const u8) ?[]const u8 {
    if (getenv(name)) |ptr| {
        return std.mem.span(ptr);
    }
    return null;
}

pub const ActEventType = enum {
    act_started,
    act_completed,
    act_failed,
    llm_call_throttled,
    llm_provider_error,
    llm_output_malformed,
    llm_context_overflow,
    rollback_requested,
    rollback_completed,
    task_completed,
    task_interrupted,
    /// RFC-003 §4.6: MemAct compaction hoàn tất (observable & reversible qua Act model).
    memact_compacted,
};

pub const FileSnapshot = struct {
    path: []const u8,
    /// Hash của nội dung cũ trong CAS. Null nếu file chưa tồn tại (mới tạo).
    previous_content_hash: ?[]const u8,
};

/// Chi tiết lỗi backend (RFC-002): đủ ngữ cảnh để debug sau này từ journal —
/// backend/model nào, lỗi gì, HTTP code, lần thử thứ mấy, raw body (nếu có).
pub const ErrorDetail = struct {
    /// Tên backend ("openai-compat" / "claude" / "ollama").
    backend: []const u8,
    /// Model đang gọi.
    model: []const u8,
    /// Zig error name (ví dụ "LLMRateLimitExceeded").
    error_name: []const u8,
    /// HTTP status code (0 nếu không phải lỗi HTTP).
    http_code: u32 = 0,
    /// Lần thử thứ mấy trong chuỗi retry (bắt đầu từ 1).
    attempt: usize = 1,
    /// Raw body/response từ server, truncate ngắn để journal không phình.
    raw_snippet: ?[]const u8 = null,
    /// Thông điệp lỗi server trích từ raw_snippet (vd "missing model").
    /// Giúp phân biệt lỗi thật khi error_name Zig gây hiểu lầm
    /// (UnknownStopReason nhưng server trả "missing model").
    /// Null khi không parse được "message" từ raw body.
    server_error: ?[]const u8 = null,
};

pub const StateDelta = struct {
    act_id: usize,
    /// File snapshot (để rollback).
    file_snapshots: []const FileSnapshot,
};

pub const ActEvent = struct {
    act_id: usize,
    event_type: ActEventType,
    timestamp: i64,
    description: []const u8,
    delta: ?StateDelta = null,
    /// Chi tiết lỗi backend khi event_type là lỗi LLM/provider.
    /// Null với các event khác để JSONL không phình.
    error_detail: ?ErrorDetail = null,
};

pub const ActJournal = struct {
    alloc: Allocator,
    file_path: []const u8,
    /// RFC-002 mở rộng (subagent merge): đường dẫn journal của agent cha đọc từ
    /// env MINI_PARENT_JOURNAL lúc init. Null nếu không set / rỗng / trùng file_path.
    /// Event được mirror 1 tầng (ghi trực tiếp, không đệ quy appendEvent).
    parent_path: ?[]u8 = null,

    pub fn init(alloc: Allocator, io: std.Io, file_path: []const u8) !ActJournal {
        const path_dup = try alloc.dupe(u8, file_path);
        
        // Đảm bảo thư mục cha tồn tại
        if (std.fs.path.dirname(path_dup)) |dir| {
            const cwd = std.Io.Dir.cwd();
            cwd.createDirPath(io, dir) catch {};
        }

        // Tạo file rỗng nếu chưa tồn tại
        const cwd = std.Io.Dir.cwd();
        if (cwd.openFile(io, path_dup, .{})) |file| {
            file.close(io);
        } else |err| {
            if (err == error.FileNotFound) {
                const file = try cwd.createFile(io, path_dup, .{});
                file.close(io);
            } else {
                return err;
            }
        }

        // Prune journal cũ ngay sau khi tạo file mới của process này:
        // mỗi process chạy sinh 1 file journal_<pid>.jsonl → nếu không prune,
        // thư mục sessions phình nhanh (spam). Giữ lại N file mới nhất.
        pruneOldJournals(alloc, io, path_dup);

        // Cache đường dẫn parent journal (subagent merge). Chỉ mirror khi hợp lệ:
        // env tồn tại, khác rỗng, và khác chính journal này (tránh self-loop).
        var parent_path: ?[]u8 = null;
        if (getEnvVar("MINI_PARENT_JOURNAL")) |pp| {
            if (pp.len > 0 and !std.mem.eql(u8, pp, path_dup)) {
                parent_path = try alloc.dupe(u8, pp);
            }
        }

        return .{
            .alloc = alloc,
            .file_path = path_dup,
            .parent_path = parent_path,
        };
    }

    /// Số file journal tối đa giữ lại (mặc định 30, override env MINI_JOURNAL_KEEP).
    pub const default_max_journal_files: usize = 30;

    /// Prune các file `journal_*.jsonl` CÙNG thư mục với `self_path`,
    /// giữ lại `max_journal_files` file mới nhất theo mtime.
    /// File của process hiện tại luôn được giữ (vừa được tạo/ghi).
    /// Best-effort: mọi lỗi bỏ qua im lặng — prune không được làm hỏng agent.
    pub fn pruneOldJournals(alloc: Allocator, io: std.Io, self_path: []const u8) void {
        const dir_path = std.fs.path.dirname(self_path) orelse ".";

        const cwd = std.Io.Dir.cwd();
        var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(io);

        const max_keep = blk: {
            const s = getEnvVar("MINI_JOURNAL_KEEP") orelse break :blk default_max_journal_files;
            const v = std.fmt.parseInt(usize, s, 10) catch break :blk default_max_journal_files;
            break :blk if (v == 0) default_max_journal_files else v;
        };

        // Thu thập {name, mtime} của mọi journal_*.jsonl trong thư mục.
        const Item = struct { name: []u8, mtime_ns: i96 };
        var items: std.ArrayList(Item) = .empty;
        defer {
            for (items.items) |it_| alloc.free(it_.name);
            items.deinit(alloc);
        }

        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.startsWith(u8, entry.name, "journal_") or !std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
            const name_dup = alloc.dupe(u8, entry.name) catch continue;
            const mtime_ns: i96 = blk2: {
                const st = dir.statFile(io, entry.name, .{}) catch {
                    alloc.free(name_dup);
                    continue;
                };
                break :blk2 st.mtime.nanoseconds;
            };
            items.append(alloc, .{ .name = name_dup, .mtime_ns = mtime_ns }) catch {
                alloc.free(name_dup);
                continue;
            };
        }

        if (items.items.len <= max_keep) return;

        // Sort giảm dần theo mtime (mới nhất lên đầu) — giữ `max_keep` đầu.
        std.mem.sort(Item, items.items, {}, struct {
            fn lt(_: void, a: Item, b: Item) bool {
                return a.mtime_ns > b.mtime_ns;
            }
        }.lt);

        for (items.items[max_keep..]) |old| {
            // Không bao giờ xóa journal của process hiện tại
            if (std.mem.eql(u8, old.name, std.fs.path.basename(self_path))) continue;
            dir.deleteFile(io, old.name) catch {};
        }
    }

    pub fn deinit(self: *ActJournal) void {
        self.alloc.free(self.file_path);
        if (self.parent_path) |pp| self.alloc.free(pp);
    }

    /// Ghi sự kiện vào file JSONL và fsync.
    pub fn recordEvent(self: *ActJournal, io: std.Io, act_id: usize, event_type: ActEventType, desc: []const u8) !void {
        try self.appendEvent(io, .{
            .act_id = act_id,
            .event_type = event_type,
            .timestamp = utils.milliTimestamp(),
            .description = desc,
        });
    }

    /// Ghi nhận Act hoàn thành và kèm theo StateDelta.
    pub fn recordActComplete(self: *ActJournal, io: std.Io, act_id: usize, delta: StateDelta) !void {
        try self.appendEvent(io, .{
            .act_id = act_id,
            .event_type = .act_completed,
            .timestamp = utils.milliTimestamp(),
            .description = "Hoàn thành Act",
            .delta = delta,
        });
    }

    /// Ghi event lỗi backend với đầy đủ ErrorDetail để debug trong session.
    /// `desc` mô tả ngắn (hiển thị khi scan journal), chi tiết nằm trong error_detail.
    /// Raw snippet được truncate tại đây để không phình file JSONL.
    /// Trích "message" từ raw body lỗi dạng {"error":{"message":"..."}},
    /// trả về slice trỏ vào raw (không owned — raw_snippet sống cùng event).
    /// Trả null nếu không tìm thấy cấu trúc này.
    fn extractServerError(raw: ?[]const u8) ?[]const u8 {
        const r = raw orelse return null;
        const err_obj = json_mod.findObject(r, "error") orelse return json_mod.findString(r, "message");
        return json_mod.findString(err_obj, "message");
    }

    pub fn recordError(
        self: *ActJournal,
        io: std.Io,
        act_id: usize,
        event_type: ActEventType,
        desc: []const u8,
        detail_in: ErrorDetail,
    ) !void {
        var detail = detail_in;
        if (detail.raw_snippet) |raw| {
            if (raw.len > max_raw_snippet_len) {
                detail.raw_snippet = raw[0..max_raw_snippet_len];
            }
        }
        // Tự trích thông điệp lỗi từ server nếu caller chưa cung cấp,
        // để error_name Zig (vd UnknownStopReason) không che giấu lỗi thật.
        if (detail.server_error == null) {
            detail.server_error = extractServerError(detail.raw_snippet);
        }
        try self.appendEvent(io, .{
            .act_id = act_id,
            .event_type = event_type,
            .timestamp = utils.milliTimestamp(),
            .description = desc,
            .error_detail = detail,
        });
    }

    /// Độ dài tối đa raw body lưu trong journal (kích thước bytes).
    const max_raw_snippet_len = 2048;

    /// Ghi 1 dòng (đã kết thúc '\n') vào cuối file JSONL + fsync.
    /// Tạo file nếu chưa tồn tại (parent journal có thể chưa được init).
    /// Tách riêng làm helper để test độc lập và tái dùng cho mirror sang parent journal.
    pub fn writeLineTo(alloc: Allocator, io: std.Io, path: []const u8, line: []const u8) !void {
        _ = alloc;
        // Mở file ở chế độ read_write để append; nếu chưa tồn tại thì tạo mới.
        // Trên hệ điều hành Unix, ghi vào cuối file có thể được mô phỏng bằng seek.
        // Dùng `cwd.openFile` thuần cho an toàn vì fsync cũng block thread anyway.
        const cwd = std.Io.Dir.cwd();
        const file = cwd.openFile(io, path, .{ .mode = .read_write }) catch |err| blk: {
            if (err != error.FileNotFound) return err;
            // Tạo thư mục cha nếu cần (parent journal có thể ở thư mục khác)
            if (std.fs.path.dirname(path)) |dir| {
                cwd.createDirPath(io, dir) catch {};
            }
            break :blk try cwd.createFile(io, path, .{});
        };
        defer file.close(io);

        // Zig 0.16: Io.File không còn seek/writeAll trực tiếp.
        // Lấy offset cuối file rồi ghi positional, đảm bảo append.
        const end_offset = try file.length(io);
        try file.writePositionalAll(io, line, end_offset);
        try file.sync(io); // Đảm bảo ghi xuống đĩa (WAL fsync)
        _ = alloc;
    }

    fn appendEvent(self: *ActJournal, io: std.Io, event: ActEvent) !void {
        var out_buf = std.ArrayList(u8).empty;
        defer out_buf.deinit(self.alloc);
        var aw = std.Io.Writer.Allocating.fromArrayList(self.alloc, &out_buf);
        
        try std.json.Stringify.value(event, .{}, &aw.writer);
        try aw.writer.writeByte('\n');
        
        out_buf = aw.toArrayList();

        // Ghi vào journal chính
        try writeLineTo(self.alloc, io, self.file_path, out_buf.items);

        // RFC-002 mở rộng: mirror 1 tầng sang journal của agent cha (subagent merge).
        // Ghi trực tiếp cùng dòng JSON — KHÔNG gọi appendEvent đệ quy để tránh
        // vòng lặp khi parent cũng có MINI_PARENT_JOURNAL set.
        if (self.parent_path) |pp| {
            writeLineTo(self.alloc, io, pp, out_buf.items) catch {};
        }
    }
};

test "ActEventType stringify chứa memact_compacted" {
    // Enum mặc định stringify của Zig dùng snake_case tên field — RFC-003 §4.6
    try std.testing.expectEqualStrings("memact_compacted", @tagName(ActEventType.memact_compacted));
    // Stringify JSON của enum cũng dùng tag name
    var buf: [64]u8 = undefined;
    var sw = std.Io.Writer.fixed(&buf);
    try std.json.Stringify.value(ActEventType.memact_compacted, .{}, &sw);
    try std.testing.expectEqualStrings("\"memact_compacted\"", sw.buffered());
}

test "appendEvent mirror sang parent journal qua MINI_PARENT_JOURNAL" {
    // Pattern test của repo: g_io style — dùng std.testing.io cho các thao tác file Io
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const main_path = "/tmp/journal_child_test.jsonl";
    const parent_path = "/tmp/journal_parent_test.jsonl";

    // Dọn file cũ từ lần chạy trước
    std.Io.Dir.deleteFileAbsolute(io, main_path) catch {};
    std.Io.Dir.deleteFileAbsolute(io, parent_path) catch {};

    // Set env trước init — journal cache parent_path lúc init (getenv 1 lần)
    _ = setenv("MINI_PARENT_JOURNAL", parent_path, 1);
    defer _ = unsetenv("MINI_PARENT_JOURNAL");

    var j = try ActJournal.init(alloc, io, main_path);
    defer j.deinit();

    // init phải cache được parent_path
    try std.testing.expect(j.parent_path != null);
    try std.testing.expectEqualStrings(parent_path, j.parent_path.?);

    try j.recordEvent(io, 1, .act_started, "bắt đầu act test");

    // Cả 2 file phải chứa cùng 1 dòng JSON
    const main_line = try readWholeFile(alloc, io, main_path);
    defer alloc.free(main_line);
    const parent_line = try readWholeFile(alloc, io, parent_path);
    defer alloc.free(parent_line);

    try std.testing.expect(main_line.len > 0);
    try std.testing.expectEqualStrings(main_line, parent_line);
    try std.testing.expect(std.mem.indexOf(u8, parent_line, "\"act_started\"") != null);

    std.Io.Dir.deleteFileAbsolute(io, main_path) catch {};
    std.Io.Dir.deleteFileAbsolute(io, parent_path) catch {};
}

test "recordError ghi đủ ErrorDetail vào journal JSONL" {
    // Backend lỗi phải log đủ ngữ cảnh trong session để debug sau này
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const path = "/tmp/journal_recorderror_test.jsonl";
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, path) catch {};

    var j = try ActJournal.init(alloc, io, path);
    defer j.deinit();

    // Raw body dài — recordError phải truncate còn max_raw_snippet_len
    const long_raw = "x" ** 5000;
    try j.recordError(io, 3, .llm_provider_error, "Backend lỗi (5xx / provider unavailable)", .{
        .backend = "openai-compat",
        .model = "gpt-4o",
        .error_name = "LLMProviderUnavailable",
        .http_code = 503,
        .attempt = 2,
        .raw_snippet = long_raw,
    });

    // Lỗi HTTP 400 có error body từ server — server_error phải được tự trích
    try j.recordError(io, 4, .act_failed, "Act lỗi — rollback & retry", .{
        .backend = "openai-compat",
        .model = "deepseek-v4-flash",
        .error_name = "UnknownStopReason",
        .http_code = 400,
        .attempt = 1,
        .raw_snippet = "{\"error\":{\"message\":\"missing model\",\"type\":\"invalid_request_error\",\"param\":null,\"code\":null}}",
    });

    const content = try readWholeFile(alloc, io, path);
    defer alloc.free(content);

    // Đủ các trường debug quan trọng trong 1 dòng JSON
    try std.testing.expect(std.mem.indexOf(u8, content, "\"llm_provider_error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"openai-compat\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"gpt-4o\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"LLMProviderUnavailable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"http_code\":503") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"attempt\":2") != null);
    // JSON mỗi event 1 dòng (2 events) + có raw snippet đã truncate
    try std.testing.expect(std.mem.count(u8, content, "\n") == 2);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"raw_snippet\"") != null);
    try std.testing.expect(content.len < 5000);
    // server_error tự trích từ raw body: thấy "missing model" thay vì chỉ UnknownStopReason
    try std.testing.expect(std.mem.indexOf(u8, content, "\"server_error\":\"missing model\"") != null);
}

test "pruneOldJournals giữ lại N file mới nhất, không xóa file hiện tại" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // Thư mục test riêng — không đụng ~/.mini/sessions thật
    var buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrint(&buf, "/tmp/mini_journal_prune_test_{d}", .{std.os.linux.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dir);

    // Tạo 5 file journal cũ + 1 file "hiện tại" + 1 file không phải journal
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        var pbuf: [256]u8 = undefined;
        const p = try std.fmt.bufPrint(&pbuf, "{s}/journal_old{s}.jsonl", .{ dir, [_]u8{'0' + @as(u8, @intCast(i))} });
        const f = try cwd.createFile(io, p, .{});
        f.close(io);
        // mtime phân biệt: file i cũ hơn file i+1 (sleep nhỏ cho chắc chắn khác ns)
        std.Io.sleep(io, .{ .nanoseconds = 2 * std.time.ns_per_ms }, .real) catch {};
    }
    var curbuf: [256]u8 = undefined;
    const cur = try std.fmt.bufPrint(&curbuf, "{s}/journal_current.jsonl", .{dir});
    {
        const f = try cwd.createFile(io, cur, .{});
        f.close(io);
    }
    var otherbuf: [256]u8 = undefined;
    const other = try std.fmt.bufPrint(&otherbuf, "{s}/conv_data.json", .{dir});
    {
        const f = try cwd.createFile(io, other, .{});
        f.close(io);
    }

    // Env override giữ 3 file
    _ = setenv("MINI_JOURNAL_KEEP", "3", 1);
    defer _ = unsetenv("MINI_JOURNAL_KEEP");

    ActJournal.pruneOldJournals(alloc, io, cur);

    // Đếm lại journal còn lại trong thư mục
    var d2 = try cwd.openDir(io, dir, .{ .iterate = true });
    defer d2.close(io);
    var n: usize = 0;
    var has_current = false;
    var has_other = false;
    var it2 = d2.iterate();
    while (it2.next(io) catch null) |entry| {
        if (std.mem.startsWith(u8, entry.name, "journal_") and std.mem.endsWith(u8, entry.name, ".jsonl")) {
            n += 1;
            if (std.mem.eql(u8, entry.name, "journal_current.jsonl")) has_current = true;
        } else if (std.mem.eql(u8, entry.name, "conv_data.json")) has_other = true;
    }

    // 5 cũ + 1 current = 6 → giữ 3; current luôn sống; file ngoài scope không đụng
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expect(has_current);
    try std.testing.expect(has_other);
}

test "writeLineTo append đúng vị trí và tạo nội dung tuần tự" {    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const path = "/tmp/journal_writeline_test.jsonl";
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, path) catch {};

    // Helper tự tạo file nếu chưa có (init của ActJournal lo phần đó; ở đây
    // tạo thủ công rồi append 2 dòng kiểm tra offset)
    {
        const cwd = std.Io.Dir.cwd();
        const f = try cwd.createFile(io, path, .{});
        f.close(io);
    }
    try ActJournal.writeLineTo(alloc, io, path, "line1\n");
    try ActJournal.writeLineTo(alloc, io, path, "line2\n");

    const content = try readWholeFile(alloc, io, path);
    defer alloc.free(content);
    try std.testing.expectEqualStrings("line1\nline2\n", content);
}

/// Đọc toàn bộ file vào buffer cấp phát (helper cho test — Zig 0.16 không còn readFileAlloc).
fn readWholeFile(alloc: Allocator, io: std.Io, path: []const u8) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.openFile(io, path, .{});
    defer file.close(io);
    const len = try file.length(io);
    const buf = try alloc.alloc(u8, @intCast(len));
    errdefer alloc.free(buf);
    const n = try file.readPositionalAll(io, buf, 0);
    return buf[0..n];
}
