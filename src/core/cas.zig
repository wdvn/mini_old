//! cas.zig — Content-Addressed Storage
//! Lưu trữ nội dung file theo SHA-256 hash để phục vụ snapshot và rollback.

const std = @import("std");
const Allocator = std.mem.Allocator;
const crypto = std.crypto;
const utils = @import("utils.zig");

pub const CAS = struct {
    alloc: Allocator,
    dir_path: []const u8,

    /// Khởi tạo CAS tại đường dẫn chỉ định (vd: ~/.mini/cas)
    pub fn init(alloc: Allocator, io: std.Io, dir_path: []const u8) !CAS {
        const path_dup = try alloc.dupe(u8, dir_path);
        // Tạo thư mục nếu chưa có
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(io, path_dup) catch {}; // Ignore error nếu đã tồn tại
        return .{
            .alloc = alloc,
            .dir_path = path_dup,
        };
    }

    pub fn deinit(self: *CAS) void {
        self.alloc.free(self.dir_path);
    }

    /// Lưu dữ liệu vào CAS. Trả về mã hash SHA-256 (64 ký tự hex).
    /// Caller có trách nhiệm `free` chuỗi trả về.
    pub fn store(self: *CAS, io: std.Io, content: []const u8) ![]u8 {
        var hash_bin: [crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        crypto.hash.sha2.Sha256.hash(content, &hash_bin, .{});

        // Zig 0.16: fmtSliceHexLower đã bị xóa, dùng bytesToHex.
        const hash_hex = try self.alloc.dupe(u8, &std.fmt.bytesToHex(hash_bin, .lower));
        errdefer self.alloc.free(hash_hex);

        const file_path = try std.fs.path.join(self.alloc, &.{ self.dir_path, hash_hex });
        defer self.alloc.free(file_path);

        const cwd = std.Io.Dir.cwd();

        // Kiểm tra xem đã có chưa
        if (cwd.openFile(io, file_path, .{})) |file| {
            file.close(io);
            return hash_hex;
        } else |_| {}

        const file = try cwd.createFile(io, file_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, content);

        return hash_hex;
    }

    /// Đọc dữ liệu từ CAS bằng hash.
    /// Trả về slice do caller sở hữu.
    pub fn retrieve(self: *CAS, io: std.Io, hash_hex: []const u8) ![]u8 {
        const file_path = try std.fs.path.join(self.alloc, &.{ self.dir_path, hash_hex });
        defer self.alloc.free(file_path);

        const cwd = std.Io.Dir.cwd();
        const file = try cwd.openFile(io, file_path, .{});
        defer file.close(io);

        const stat = try file.stat(io);
        const buf = try self.alloc.alloc(u8, @intCast(stat.size));
        errdefer self.alloc.free(buf);

        const read_len = try utils.readAll(io, file, buf);
        return buf[0..read_len];
    }
};
