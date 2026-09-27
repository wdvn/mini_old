//! bm25.zig — In-tree BM25 ranking + Reciprocal Rank Fusion (RRF) for
//! Dual-Path Semantic Memory retrieval (RFC-025 Phases 1-2).
//! Std-only, embedding-free.
//!
//! ## Responsibilities
//! - `Index`: BM25 (Okapi) score over a list of documents (memory records,
//!   text = `content` + `" "` + `keywords` joined).
//! - `Index.rank`: score docs against 1 query, return top-n by score descending.
//! - `rrfFuse`: fuse two ranked lists (Path A original query + Path B
//!   LLM-expanded query) with Reciprocal Rank Fusion, k=60.
//!
//! Design principle (RFC-025 §3.1): semantic understanding at the query
//! layer (stateless), lexical exact-match at the storage layer.
//! Graceful degrade: when Path B is empty/failed, fused scores reduce to
//! `1/(k+rank_A)` — ranking is preserved, absolute scores scale down.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// BM25 Okapi parameters (standard defaults).
pub const BM25_K1: f32 = 1.5;
pub const BM25_B: f32 = 0.75;

/// RRF constant (standard value, k=60 per RFC-025 §3.1).
pub const RRF_K: u32 = 60;

/// One ranked document. `doc_index` is the position in the source docs list;
/// list position encodes rank (1-based) in fused paths.
pub const Ranked = struct {
    doc_index: usize,
    score: f32,
};

/// BM25 index over a fixed document set (memory entries).
pub const Index = struct {
    /// Per-doc term frequencies (term -> tf).
    doc_tfs: []std.StringHashMap(u32),
    /// Per-doc length in tokens.
    doc_lens: []u32,
    /// Mean doc length.
    avg_len: f32,
    /// Global doc frequency (term -> doc count).
    df: std.StringHashMap(u32),
    /// Pool of term bytes that outlive the maps: `tf_map`/`df` keys are
    /// slices pointing into this pool (the index owns the bytes).
    term_pool: [][]const u8,

    /// Build an index from document text lines.
    pub fn build(alloc: Allocator, docs: []const []const u8) !Index {
        var out = Index{
            .doc_tfs = try alloc.alloc(std.StringHashMap(u32), docs.len),
            .doc_lens = try alloc.alloc(u32, docs.len),
            .df = std.StringHashMap(u32).init(alloc),
            .avg_len = 0,
            .term_pool = try alloc.alloc([]const u8, 0),
        };
        errdefer out.deinit(alloc);

        var total_len: u64 = 0;
        for (docs, 0..) |text, i| {
            const terms = try tokenize(alloc, text);

            var tf_map = std.StringHashMap(u32).init(alloc);
            for (terms) |term| {
                const gop = try tf_map.getOrPut(term);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            }
            out.doc_tfs[i] = tf_map;
            out.doc_lens[i] = @intCast(terms.len);
            total_len += terms.len;

            // Global doc frequency: once per unique term in this doc.
            var it = tf_map.iterator();
            while (it.next()) |kv| {
                const gop = try out.df.getOrPut(kv.key_ptr.*);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            }

            // Move term bytes into the pool (pool owns them for the index
            // lifetime: map keys are slices into these bytes). Free only the
            // wrapper arrays — the byte allocations transfer to the pool.
            const new_pool = try alloc.alloc([]const u8, out.term_pool.len + terms.len);
            for (new_pool, 0..) |*slot, j| {
                slot.* = if (j < out.term_pool.len) out.term_pool[j] else terms[j - out.term_pool.len];
            }
            if (out.term_pool.len > 0) alloc.free(out.term_pool); // old wrapper
            alloc.free(terms); // current wrapper (bytes now owned by new_pool)
            out.term_pool = new_pool;
        }

        if (docs.len > 0) out.avg_len = @as(f32, @floatFromInt(total_len / @as(u64, docs.len)));
        return out;
    }

    /// Score all docs against `query`; return up to `top_n` docs with score > 0,
    /// descending (ties: lower doc_index first). `top_n == 0` means no limit.
    /// Caller owns the returned slice (`alloc.free`).
    pub fn rank(self: *Index, alloc: Allocator, query: []const u8, top_n: usize) ![]Ranked {
        // PSEUDOCODE:
        // 1. Tokenize query; for each term compute IDF (BM25+ variant).
        // 2. For each doc containing the term, accumulate the BM25 tf term.
        // 3. Collect docs with score > 0, sort descending, take top_n.
        const q_terms = try tokenize(alloc, query);
        defer freeTokens(alloc, q_terms);

        const n_f: f32 = @floatFromInt(self.doc_tfs.len);
        var scores = try alloc.alloc(f32, self.doc_tfs.len);
        defer alloc.free(scores);
        for (scores) |*s| s.* = 0.0;

        for (q_terms) |q_term| {
            const df_v = self.df.get(q_term) orelse continue;
            // IDF (BM25+ variant): log10(1 + (N - df + 0.5) / (df + 0.5))
            const idf: f32 = @log10(1 + (n_f - @as(f32, @floatFromInt(df_v)) + 0.5) / (@as(f32, @floatFromInt(df_v)) + 0.5));
            if (idf <= 0) continue;

            for (self.doc_tfs, 0..) |*tf_map, i| {
                const tf = tf_map.get(q_term) orelse continue;
                const norm = BM25_K1 * (1 - BM25_B + BM25_B * @as(f32, @floatFromInt(self.doc_lens[i])) / @max(self.avg_len, 0.001));
                scores[i] += idf * @as(f32, @floatFromInt(tf)) * (BM25_K1 + 1) / (@as(f32, @floatFromInt(tf)) + norm);
            }
        }

        var pairs = std.ArrayList(Ranked).empty;
        errdefer pairs.deinit(alloc);
        for (scores, 0..) |s, i| {
            if (s > 0) try pairs.append(alloc, .{ .doc_index = i, .score = s });
        }
        std.mem.sort(Ranked, pairs.items, {}, struct {
            fn lessThan(_: void, a: Ranked, b: Ranked) bool {
                if (a.score != b.score) return a.score > b.score;
                return a.doc_index < b.doc_index; // stable tie-break
            }
        }.lessThan);

        const limit: usize = if (top_n == 0) pairs.items.len else @min(top_n, pairs.items.len);
        const result = try alloc.alloc(Ranked, limit);
        for (result, 0..) |*slot, i| slot.* = pairs.items[i];
        pairs.deinit(alloc);
        return result;
    }

    pub fn deinit(self: *Index, alloc: Allocator) void {
        for (self.doc_tfs) |*map| map.deinit();
        alloc.free(self.doc_tfs);
        alloc.free(self.doc_lens);
        self.df.deinit();
        for (self.term_pool) |t| alloc.free(t);
        alloc.free(self.term_pool);
    }
};

/// Tokenize text into lowercase terms (alpha/digit, length 2..=40,
/// whitespace-delimited). Returns owned slice; free via `freeTokens`.
fn tokenize(alloc: Allocator, text: []const u8) ![][]const u8 {
    // PSEUDOCODE: split on spaces, trim punctuation, drop out-of-range words.
    var out = std.ArrayList([]const u8).empty;
    errdefer out.deinit(alloc);

    var it = std.mem.splitScalar(u8, text, ' ');
    while (it.next()) |word| {
        const w = std.mem.trim(u8, word, " \t\r\n,.;:()[]{}\"'`/\\|<>!?*&^~%$#@+=_-");
        if (w.len < 2 or w.len > 40) continue;
        var lc = w;
        while (lc.len > 0 and !std.ascii.isAlphanumeric(lc[0])) lc = lc[1..];
        while (lc.len > 0 and !std.ascii.isAlphanumeric(lc[lc.len - 1])) lc = lc[0 .. lc.len - 1];
        if (lc.len < 2) continue;
        const owned = try alloc.dupe(u8, lc);
        _ = std.ascii.lowerString(owned, lc);
        try out.append(alloc, owned);
    }
    return try out.toOwnedSlice(alloc);
}

fn freeTokens(alloc: Allocator, tokens: [][]const u8) void {
    for (tokens) |t| alloc.free(t);
    alloc.free(tokens);
}

/// Fuse two ranked lists (Path A original + Path B expanded) with RRF (k=60):
/// `score(d) = 1/(k + rank_A(d)) + 1/(k + rank_B(d))`, rank is 1-based list
/// position. Docs missing from a path contribute 0 on that path (graceful
/// degrade — a single standing path is fine). Returns docs sorted by fused
/// score descending (ties: lower doc_index first). Caller owns the result.
pub fn rrfFuse(alloc: Allocator, path_a: []const Ranked, path_b: []const Ranked) ![]Ranked {
    // PSEUDOCODE: accumulate RRF terms per doc_index, sort descending.
    var accum = std.AutoHashMap(usize, f32).init(alloc);
    errdefer accum.deinit();

    inline for (&.{ path_a, path_b }) |path| {
        for (path, 0..) |r, pos| {
            const rank_term: f32 = 1.0 / @as(f32, @floatFromInt(RRF_K + pos + 1));
            const gop = try accum.getOrPut(r.doc_index);
            if (!gop.found_existing) gop.value_ptr.* = 0.0;
            gop.value_ptr.* += rank_term;
        }
    }

    var out = std.ArrayList(Ranked).empty;
    errdefer out.deinit(alloc);
    var it = accum.iterator();
    while (it.next()) |kv| {
        try out.append(alloc, .{ .doc_index = kv.key_ptr.*, .score = kv.value_ptr.* });
    }
    std.mem.sort(Ranked, out.items, {}, struct {
        fn lessThan(_: void, a: Ranked, b: Ranked) bool {
            if (a.score != b.score) return a.score > b.score;
            return a.doc_index < b.doc_index;
        }
    }.lessThan);
    const fused = out.toOwnedSlice(alloc);
    accum.deinit();
    return fused;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "bm25 ranks doc containing all query terms highest" {
    const alloc = std.testing.allocator;

    const docs = [_][]const u8{
        "zig build test memory store bm25",
        "ollama streaming leak fix",
        "zig 016 compiler upgrade",
    };
    var index = try Index.build(alloc, &docs);
    defer index.deinit(alloc);

    const ranked = try index.rank(alloc, "zig build memory", 3);
    defer alloc.free(ranked);

    try std.testing.expectEqual(@as(usize, 2), ranked.len);
    try std.testing.expectEqual(@as(usize, 0), ranked[0].doc_index);
}

test "bm25 query with no matching terms returns empty" {
    const alloc = std.testing.allocator;
    const docs = [_][]const u8{ "alpha beta gamma" };
    var index = try Index.build(alloc, &docs);
    defer index.deinit(alloc);

    const ranked = try index.rank(alloc, "delta epsilon", 5);
    defer alloc.free(ranked);
    try std.testing.expectEqual(@as(usize, 0), ranked.len);
}

test "bm25 term frequency does not penalize high-tf docs (saturation)" {
    const alloc = std.testing.allocator;
    const docs = [_][]const u8{
        "oom oom oom kubernetes",
        "oom in docker",
    };
    var index = try Index.build(alloc, &docs);
    defer index.deinit(alloc);

    const ranked = try index.rank(alloc, "oom", 2);
    defer alloc.free(ranked);
    try std.testing.expectEqual(@as(usize, 2), ranked.len);
    try std.testing.expect(ranked[0].score >= ranked[1].score);
}

test "rrfFuse boosts docs ranked high on both paths" {
    const alloc = std.testing.allocator;

    const path_a = [_]Ranked{
        .{ .doc_index = 0, .score = 1.0 },
        .{ .doc_index = 1, .score = 0.5 },
    };
    const path_b = [_]Ranked{
        .{ .doc_index = 0, .score = 1.0 },
        .{ .doc_index = 2, .score = 0.5 },
    };

    const fused = try rrfFuse(alloc, &path_a, &path_b);
    defer alloc.free(fused);

    // doc 0 appears in both paths -> highest fused score.
    try std.testing.expectEqual(@as(usize, 0), fused[0].doc_index);
    // docs 1 and 2 tied (single path, rank 2) -> lower index first.
    try std.testing.expectEqual(@as(usize, 1), fused[1].doc_index);
    try std.testing.expectEqual(@as(usize, 2), fused[2].doc_index);
}

test "rrfFuse graceful degrade when expanded path is empty" {
    const alloc = std.testing.allocator;
    const path_a = [_]Ranked{
        .{ .doc_index = 5, .score = 1.0 },
        .{ .doc_index = 3, .score = 0.8 },
    };
    const empty: []const Ranked = &.{};

    const fused = try rrfFuse(alloc, &path_a, empty);
    defer alloc.free(fused);

    try std.testing.expectEqual(@as(usize, 2), fused.len);
    try std.testing.expectEqual(@as(usize, 5), fused[0].doc_index);
    try std.testing.expectEqual(@as(usize, 3), fused[1].doc_index);
}

test "tokenize lowercases and bounds length" {
    const alloc = std.testing.allocator;
    const tokens = try tokenize(alloc, "Zig Build a averylongtokenx abc def");
    defer freeTokens(alloc, tokens);

    try std.testing.expectEqual(@as(usize, 5), tokens.len);
    try std.testing.expectEqualStrings("zig", tokens[0]);
    try std.testing.expectEqualStrings("build", tokens[1]);
    try std.testing.expectEqualStrings("averylongtokenx", tokens[2]);
    try std.testing.expectEqualStrings("abc", tokens[3]);
    try std.testing.expectEqualStrings("def", tokens[4]);
}
