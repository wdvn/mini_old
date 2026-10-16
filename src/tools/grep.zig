//! tools/grep.zig — Content search in files.
//!
//! Searches for pattern in a file or directory (recursive).
//! Returns matches in `path:line_num:line_content` format.
//!
//! ## Input schema
//! ```json
//! { "pattern": "fn main", "path": "./src", "case_insensitive": "false" }
//! ```
//!
//! ## Output format
//! ```
//! src/main.zig:42:pub fn main() !void {
//! src/agent.zig:10:fn main_loop() void {
//! ```
//!
//! ## Limits
//!   - Max 200 matches (distinct lines); a truncation notice with the number of
//!     dropped matches is appended so the agent can refine the query
//!   - Near-identical lines are deduplicated (first 120 chars) so the cap is
//!     not consumed by duplicates
//!   - On zero matches, a small set of closest-candidate identifiers (Levenshtein
//!     distance <= 3 on identifier-like patterns) is suggested
//!   - Skip files > 1MB
//!   - Binary files automatically ignored

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../core/json.zig");
const utils = @import("../core/utils.zig");

const MAX_MATCHES = 200;
const MAX_FILE_SIZE = 1024 * 1024;
/// Number of closest-candidate words suggested on zero matches.
const MAX_SUGGESTIONS = 5;
/// Total distinct candidate words collected across the search (hard bound).
const MAX_CANDIDATES = 100;
/// Lines sharing this prefix are considered duplicates.
const DEDUP_PREFIX_LEN = 120;

/// Search state shared across all files in one search.
const GrepState = struct {
    result: *utils.BufWriter,
    /// Total raw match lines (before dedup).
    total: usize = 0,
    /// Distinct match lines printed so far.
    printed: usize = 0,
    /// Distinct match lines dropped because MAX_MATCHES was reached.
    truncated: usize = 0,
    /// Trimmed dedup keys of lines already printed (bounded by MAX_MATCHES).
    printed_keys: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Distinct identifiers collected for zero-match suggestions (bounded by MAX_CANDIDATES).
    candidates: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(g: *GrepState, alloc: Allocator) void {
        for (g.printed_keys.items) |k| alloc.free(k);
        g.printed_keys.deinit(alloc);
        for (g.candidates.items) |w| alloc.free(w);
        g.candidates.deinit(alloc);
    }
};

/// Tool entry point.
/// Input: {"pattern":"...", "path":".", "case_insensitive":"false"}
pub fn executeTool(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    const pattern = (try json.findStringOwned(alloc, input_json, "pattern")) orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'pattern' parameter", .{});
    defer alloc.free(pattern);
    const search_path = (try json.findStringOwned(alloc, input_json, "path")) orelse
        try alloc.dupe(u8, ".");
    defer alloc.free(search_path);
    const ci_str = json.findString(input_json, "case_insensitive") orelse "false";
    const case_insensitive = std.mem.eql(u8, ci_str, "true");

    return searchContent(alloc, io, pattern, search_path, case_insensitive);
}

/// Search for pattern in search_path (file or directory).
pub fn searchContent(alloc: Allocator, io: std.Io, pattern: []const u8, search_path: []const u8, case_insensitive: bool) ![]u8 {
    var result = utils.BufWriter.init(alloc);
    errdefer result.deinit();
    var g = GrepState{ .result = &result };
    errdefer g.deinit(alloc);

    const cwd = std.Io.Dir.cwd();

    // Try statting path first
    const stat = cwd.statFile(io, search_path, .{}) catch |e| {
        return std.fmt.allocPrint(alloc, "Error accessing '{s}': {s}", .{ search_path, @errorName(e) });
    };

    if (stat.kind == .file) {
        try searchFile(alloc, io, &g, pattern, search_path, case_insensitive);
    } else if (stat.kind == .directory) {
        var dir = cwd.openDir(io, search_path, .{ .iterate = true }) catch |e| {
            return std.fmt.allocPrint(alloc, "Error opening directory '{s}': {s}", .{ search_path, @errorName(e) });
        };
        defer dir.close(io);

        var walker = try dir.walk(alloc);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (g.printed >= MAX_MATCHES) break;

            if (isBinaryName(entry.path)) continue;

            const full_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ search_path, entry.path });
            defer alloc.free(full_path);
            try searchFile(alloc, io, &g, pattern, full_path, case_insensitive);
        }
    }

    if (g.total == 0) {
        const closest = try suggestClosest(alloc, &g, pattern);
        return std.fmt.allocPrint(alloc, "No match found for '{s}' in '{s}'.{s}", .{ pattern, search_path, closest });
    }

    try result.print("\n{d} match(es) found.", .{g.total});
    if (g.truncated > 0) {
        try result.print(" [truncated: {d} more match(es) not shown - refine the pattern or narrow the path]", .{g.truncated});
    }
    return result.toOwnedSlice();
}

/// Record one matched line: dedup by trimmed prefix, enforce the cap, print.
fn recordMatch(g: *GrepState, alloc: Allocator, path: []const u8, line_num: usize, line: []const u8) Allocator.Error!void {
    g.total += 1;

    // PSEUDOCODE:
    // 1. key = right-trimmed line, truncated to DEDUP_PREFIX_LEN.
    // 2. If key already printed: duplicate, count only, return.
    // 3. If cap reached: count as truncated, return.
    // 4. Otherwise print `path:line:content` and remember the key.
    const trimmed = std.mem.trimEnd(u8, line, " \t\r");
    const key_len = @min(trimmed.len, DEDUP_PREFIX_LEN);
    const key = try alloc.dupe(u8, trimmed[0..key_len]);
    for (g.printed_keys.items) |k| {
        if (k.len == key.len and std.mem.eql(u8, k, key)) {
            alloc.free(key);
            return;
        }
    }
    if (g.printed >= MAX_MATCHES) {
        g.truncated += 1;
        alloc.free(key);
        return;
    }
    try g.printed_keys.append(alloc, key);
    try g.result.print("{s}:{d}:{s}\n", .{ path, line_num, line });
    g.printed += 1;
}

/// Collect distinct identifiers from a line for later closest-candidate suggestions.
fn maybeCollectCandidates(g: *GrepState, alloc: Allocator, pattern: []const u8, line: []const u8) Allocator.Error!void {
    if (g.candidates.items.len >= MAX_CANDIDATES) return;
    if (!isIdentifierPattern(pattern)) return;
    // PSEUDOCODE:
    // 1. Split line into word chars ([A-Za-z0-9._-]).
    // 2. Skip words outside a sane length range.
    // 3. Keep words with Levenshtein distance <= 3 to the pattern.
    // 4. Dedup against already-collected candidates.
    var i: usize = 0;
    while (i < line.len) {
        if (!isWordChar(line[i])) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < line.len and isWordChar(line[j])) j += 1;
        const word = line[i..j];
        i = j;
        if (word.len < 3 or word.len > 64) continue;
        if (levenshteinCap(word, pattern, 4) > 3) continue;
        var seen = false;
        for (g.candidates.items) |w| {
            if (std.mem.eql(u8, w, word)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        try g.candidates.append(alloc, try alloc.dupe(u8, word));
    }
}

/// True when the pattern looks like a single identifier (fuzzy suggestions apply).
fn isIdentifierPattern(pattern: []const u8) bool {
    if (pattern.len < 4 or pattern.len > 64) return false;
    for (pattern) |c| {
        if (!isWordChar(c)) return false;
    }
    return true;
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-';
}

/// PSEUDOCODE:
/// 1. Two-row Levenshtein DP over the two inputs.
/// 2. Early-exit as soon as the row minimum exceeds cap (ranking bound only).
fn levenshteinCap(a: []const u8, b: []const u8, cap: u32) u32 {
    const n = b.len;
    var prev: [129]u32 = undefined;
    var cur: [129]u32 = undefined;
    for (0..(n + 1)) |i| prev[i] = @intCast(i);
    var rows: usize = 1;
    while (rows <= a.len) : (rows += 1) {
        cur[0] = @intCast(rows);
        var row_min = cur[0];
        for (1..(n + 1)) |j| {
            const cost: u32 = if (a[rows - 1] == b[j - 1]) 0 else 1;
            const v = @min(@min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + cost);
            cur[j] = v;
            if (v < row_min) row_min = v;
        }
        // Early exit: remaining rows can only be >= row_min.
        if (row_min > cap) return cap + 1;
        const t = prev;
        prev = cur;
        cur = t;
    }
    return if (prev[n] > cap) cap + 1 else prev[n];
}

/// Build the closest-candidate suggestion for zero-match searches.
/// PSEUDOCODE:
/// 1. No candidates collected -> return empty string (short/unusual query).
/// 2. Rank candidates by edit distance to the pattern, ties broken lexically.
/// 3. Emit up to MAX_SUGGESTIONS.
fn suggestClosest(alloc: Allocator, g: *GrepState, pattern: []const u8) ![]const u8 {
    const items = g.candidates.items;
    if (items.len == 0) return "";

    const Entry = struct { word: []const u8, dist: u32 };
    var ranked: std.ArrayListUnmanaged(Entry) = .empty;
    defer ranked.deinit(alloc);
    for (items) |w| {
        try ranked.append(alloc, .{ .word = w, .dist = levenshteinCap(w, pattern, 4) });
    }
    // Insertion sort by (dist, word).
    for (1..ranked.items.len) |i| {
        var j = i;
        while (j > 0) : (j -= 1) {
            const a = ranked.items[j - 1];
            const b = ranked.items[j];
            if (b.dist < a.dist or (b.dist == a.dist and std.mem.lessThan(u8, b.word, a.word))) {
                const tmp = ranked.items[j];
                ranked.items[j] = ranked.items[j - 1];
                ranked.items[j - 1] = tmp;
            } else break;
        }
    }

    var out = utils.BufWriter.init(alloc);
    defer out.deinit();
    try out.print(" Closest candidates: ", .{});
    const show = @min(ranked.items.len, MAX_SUGGESTIONS);
    for (ranked.items[0..show], 0..) |e, i| {
        if (i > 0) try out.writeAll(", ");
        try out.writeAll(e.word);
    }
    return out.toOwnedSlice();
}

fn searchFile(
    alloc: Allocator,
    io: std.Io,
    g: *GrepState,
    pattern: []const u8,
    path: []const u8,
    case_insensitive: bool,
) !void {
    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, path, .{}) catch return;
    defer file.close(io);

    const stat = file.stat(io) catch return;
    if (stat.size > MAX_FILE_SIZE or stat.size == 0) return;

    const buf = alloc.alloc(u8, @intCast(stat.size)) catch return;
    defer alloc.free(buf);
    const n = utils.readAll(io, file, buf) catch return;
    const content = buf[0..n];

    // Skip binary: check for null byte in first 512 bytes
    const check_len = @min(content.len, 512);
    for (content[0..check_len]) |c| {
        if (c == 0) return;
    }

    var line_num: usize = 1;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| : (line_num += 1) {
        const matched = if (case_insensitive)
            containsCI(line, pattern)
        else
            std.mem.indexOf(u8, line, pattern) != null;

        if (matched) {
            try recordMatch(g, alloc, path, line_num, line);
        } else if (g.candidates.items.len < MAX_CANDIDATES) {
            try maybeCollectCandidates(g, alloc, pattern, line);
        }
    }
}

/// Case-insensitive substring search.
fn containsCI(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (0..needle.len) |j| {
            const h = std.ascii.toLower(haystack[i + j]);
            const n = std.ascii.toLower(needle[j]);
            if (h != n) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

/// Check if filename extension suggests binary content.
fn isBinaryName(name: []const u8) bool {
    const binary_exts = [_][]const u8{
        ".o",   ".a",    ".so",   ".dylib", ".dll", ".exe",
        ".png", ".jpg",  ".jpeg", ".gif",   ".bmp", ".ico",
        ".zip", ".tar",  ".gz",   ".bz2",   ".xz",  ".pdf",
        ".bin", ".wasm",
    };
    for (binary_exts) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return true;
    }
    return false;
}
