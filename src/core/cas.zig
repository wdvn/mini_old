//! cas.zig — Content-Addressed Storage
//! Stores file contents indexed by SHA-256 hash for snapshot and rollback.

const std = @import("std");
const Allocator = std.mem.Allocator;
const crypto = std.crypto;
const utils = @import("utils.zig");

pub const CAS = struct {
    alloc: Allocator,
    dir_path: []const u8,

    /// Initialize CAS at the specified directory path (e.g., ~/.mini/cas)
    pub fn init(alloc: Allocator, io: std.Io, dir_path: []const u8) !CAS {
        const path_dup = try alloc.dupe(u8, dir_path);
        // Create directory if it does not exist
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(io, path_dup) catch {}; // Ignore error if already exists
        return .{
            .alloc = alloc,
            .dir_path = path_dup,
        };
    }

    pub fn deinit(self: *CAS) void {
        self.alloc.free(self.dir_path);
    }

    /// Store data into CAS. Returns SHA-256 hash (64 hex characters).
    /// Caller owns the returned slice and must free it.
    pub fn store(self: *CAS, io: std.Io, content: []const u8) ![]u8 {
        var hash_bin: [crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        crypto.hash.sha2.Sha256.hash(content, &hash_bin, .{});

        // Zig 0.16: fmtSliceHexLower was removed, use bytesToHex.
        const hash_hex = try self.alloc.dupe(u8, &std.fmt.bytesToHex(hash_bin, .lower));
        errdefer self.alloc.free(hash_hex);

        const file_path = try std.fs.path.join(self.alloc, &.{ self.dir_path, hash_hex });
        defer self.alloc.free(file_path);

        const cwd = std.Io.Dir.cwd();

        // Check if already exists
        if (cwd.openFile(io, file_path, .{})) |file| {
            file.close(io);
            return hash_hex;
        } else |_| {}

        const file = try cwd.createFile(io, file_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, content);

        return hash_hex;
    }

    /// Read data from CAS by hash.
    /// Returns slice owned by the caller.
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
