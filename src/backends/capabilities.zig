//! capabilities.zig — Model capabilities cache and lookup (/models).
//!
//! Provides:
//! - normalizeModelAlias: normalizes model names (strips '~' prefix, variant suffix, or '~' after provider)
//! - ModelCapability: parses and caches supported_efforts, mandatory reasoning, max_tokens
//! - CapabilityCache: thread-safe cache for /models capability queries

const std = @import("std");
const Allocator = std.mem.Allocator;
const json_mod = @import("../core/json.zig");
const http_lib = @import("../lib/http_request.zig");

/// Normalizes model alias by stripping '~' prefixes or variant suffixes.
/// Handles:
/// - "~gpt-4o" -> "gpt-4o"
/// - "o3-mini~high" -> "o3-mini"
/// - "openai/~o3-mini" -> "openai/o3-mini"
/// - "~openai/gpt-4o" -> "openai/gpt-4o"
pub fn normalizeModelAlias(model: []const u8) []const u8 {
    // PSEUDOCODE:
    // 1. If starts with '~', strip it.
    // 2. If contains "/~", return prefix up to '/' + substring after "/~".
    // 3. If contains trailing '~' suffix, strip everything from '~' onwards.
    var m = model;
    if (std.mem.startsWith(u8, m, "~")) {
        m = m[1..];
    }
    if (std.mem.indexOf(u8, m, "/~")) |idx| {
        // We have a provider prefix like "openai/~model".
        // Strip the '~' after the slash by adjusting to model part if callers only look for base,
        // or stripping '~' from the rest. For in-place slicing, if starts with provider/~,
        // the effective base model after provider is m[idx + 2..].
        // But matching might compare full "openai/model" or just "model".
        // If idx + 2 < m.len, we can check suffix on m[idx + 2..].
        m = m[idx + 2..];
    }
    if (std.mem.indexOfScalar(u8, m, '~')) |idx| {
        m = m[0..idx];
    }
    return m;
}

pub const ModelCapability = struct {
    id: []const u8,
    supports_reasoning: bool = false,
    reasoning_mandatory: bool = false,
    supported_efforts: []const []const u8 = &.{},
    max_tokens: ?u32 = null,
    reasoning_max_tokens: ?u32 = null,

    /// Clip requested effort into supported efforts.
    /// If supported_efforts is empty, returns original requested effort.
    /// If requested is "none" and reasoning_mandatory is true, returns lowest available effort (or default "low").
    pub fn clipEffort(self: ModelCapability, requested: ?[]const u8) ?[]const u8 {
        // PSEUDOCODE:
        // 1. If requested is "none" and reasoning_mandatory is true, return supported_efforts[0] or "low".
        // 2. If requested matches an entry in supported_efforts, return it.
        // 3. If requested doesn't match and supported_efforts is non-empty, return supported_efforts[0].
        // 4. Otherwise return requested.
        if (requested) |req| {
            if (std.mem.eql(u8, req, "none")) {
                if (self.reasoning_mandatory) {
                    if (self.supported_efforts.len > 0) return self.supported_efforts[0];
                    return "low";
                }
                return "none";
            }
            if (self.supported_efforts.len > 0) {
                for (self.supported_efforts) |supp| {
                    if (std.mem.eql(u8, supp, req)) return supp;
                }
                return self.supported_efforts[0];
            }
            return req;
        } else if (self.reasoning_mandatory) {
            if (self.supported_efforts.len > 0) return self.supported_efforts[0];
            return "low";
        }
        return null;
    }

    /// Validates and guards reasoning.max_tokens vs max_tokens.
    /// For Anthropic: strict < (`reasoning.max_tokens < max_tokens`).
    /// For others: <= (`reasoning.max_tokens <= max_tokens`).
    pub fn guardReasoningMaxTokens(reasoning_max: u32, max_tokens: u32, is_anthropic: bool) u32 {
        // PSEUDOCODE:
        // 1. If is_anthropic and reasoning_max >= max_tokens:
        //    clamp strictly below max_tokens.
        // 2. Otherwise if reasoning_max > max_tokens:
        //    clamp to max_tokens.
        if (is_anthropic) {
            if (reasoning_max >= max_tokens) {
                if (max_tokens > 1024) return max_tokens - 1024;
                if (max_tokens > 1) return max_tokens - 1;
                return 1;
            }
        } else {
            if (reasoning_max > max_tokens) {
                return max_tokens;
            }
        }
        return reasoning_max;
    }
};

/// Parses model capability from /models JSON string.
pub fn parseModelCapabilityFromJson(alloc: Allocator, json_str: []const u8, target_model: []const u8) ?ModelCapability {
    // PSEUDOCODE:
    // 1. Normalize target_model alias.
    // 2. Parse JSON document using std.json.
    // 3. Find matching model object in "data" array by comparing normalized "id".
    // 4. Extract reasoning / supported_efforts / mandatory fields.
    const norm_target = normalizeModelAlias(target_model);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_str, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    const data_val = root.object.get("data") orelse return null;
    if (data_val != .array) return null;

    for (data_val.array.items) |item| {
        if (item != .object) continue;
        const id_val = item.object.get("id") orelse continue;
        if (id_val != .string) continue;

        const norm_id = normalizeModelAlias(id_val.string);
        if (!std.mem.eql(u8, norm_id, norm_target) and !std.mem.endsWith(u8, norm_id, norm_target)) continue;

        var mandatory = false;
        var supports_reasoning = false;
        var max_tokens: ?u32 = null;
        var reasoning_max: ?u32 = null;
        var efforts_list = std.ArrayList([]const u8).empty;
        errdefer efforts_list.deinit(alloc);

        if (item.object.get("max_tokens")) |mt| {
            if (mt == .integer and mt.integer > 0) max_tokens = @intCast(mt.integer);
        }

        // Check top-level supported_efforts
        if (item.object.get("supported_efforts")) |se| {
            if (se == .array) {
                supports_reasoning = true;
                for (se.array.items) |eff| {
                    if (eff == .string) {
                        const dup = alloc.dupe(u8, eff.string) catch continue;
                        efforts_list.append(alloc, dup) catch {};
                    }
                }
            }
        }

        // Check nested "reasoning" object
        if (item.object.get("reasoning")) |r| {
            if (r == .object) {
                supports_reasoning = true;
                if (r.object.get("mandatory")) |man| {
                    if (man == .bool) mandatory = man.bool;
                }
                if (r.object.get("max_tokens")) |rmt| {
                    if (rmt == .integer and rmt.integer > 0) reasoning_max = @intCast(rmt.integer);
                }
                if (r.object.get("supported_efforts")) |se| {
                    if (se == .array and efforts_list.items.len == 0) {
                        for (se.array.items) |eff| {
                            if (eff == .string) {
                                const dup = alloc.dupe(u8, eff.string) catch continue;
                                efforts_list.append(alloc, dup) catch {};
                            }
                        }
                    }
                }
            }
        }

        const id_dup = alloc.dupe(u8, id_val.string) catch return null;
        return ModelCapability{
            .id = id_dup,
            .supports_reasoning = supports_reasoning,
            .reasoning_mandatory = mandatory,
            .supported_efforts = efforts_list.toOwnedSlice(alloc) catch &.{},
            .max_tokens = max_tokens,
            .reasoning_max_tokens = reasoning_max,
        };
    }

    return null;
}

pub const CapabilityCache = struct {
    alloc: Allocator,
    mu: std.atomic.Mutex = .unlocked,
    entries: std.StringHashMapUnmanaged(ModelCapability) = .empty,

    pub fn init(alloc: Allocator) CapabilityCache {
        return .{
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *CapabilityCache) void {
        while (!self.mu.tryLock()) {}
        defer self.mu.unlock();
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            if (entry.value_ptr.id.len > 0) self.alloc.free(entry.value_ptr.id);
            for (entry.value_ptr.supported_efforts) |eff| self.alloc.free(eff);
            if (entry.value_ptr.supported_efforts.len > 0) self.alloc.free(entry.value_ptr.supported_efforts);
        }
        self.entries.deinit(self.alloc);
    }

    pub fn get(self: *CapabilityCache, model: []const u8) ?ModelCapability {
        const norm = normalizeModelAlias(model);
        while (!self.mu.tryLock()) {}
        defer self.mu.unlock();
        return self.entries.get(norm);
    }

    pub fn put(self: *CapabilityCache, model: []const u8, cap: ModelCapability) !void {
        const norm = normalizeModelAlias(model);
        while (!self.mu.tryLock()) {}
        defer self.mu.unlock();
        if (self.entries.fetchRemove(norm)) |old| {
            self.alloc.free(old.key);
            if (old.value.id.len > 0) self.alloc.free(old.value.id);
            for (old.value.supported_efforts) |eff| self.alloc.free(eff);
            if (old.value.supported_efforts.len > 0) self.alloc.free(old.value.supported_efforts);
        }
        const key_dup = try self.alloc.dupe(u8, norm);
        errdefer self.alloc.free(key_dup);
        try self.entries.put(self.alloc, key_dup, cap);
    }
};

var g_cache: ?CapabilityCache = null;
var g_cache_mu: std.atomic.Mutex = .unlocked;

pub fn getGlobalCache(alloc: Allocator) *CapabilityCache {
    while (!g_cache_mu.tryLock()) {}
    defer g_cache_mu.unlock();
    if (g_cache == null) {
        g_cache = CapabilityCache.init(alloc);
    }
    return &g_cache.?;
}

pub fn deinitGlobalCache() void {
    while (!g_cache_mu.tryLock()) {}
    defer g_cache_mu.unlock();
    if (g_cache) |*c| {
        c.deinit();
        g_cache = null;
    }
}

/// Fetch or lookup model capability from global cache or /models HTTP endpoint.
pub fn fetchOrLookupCapability(
    alloc: Allocator,
    io: std.Io,
    base_url: []const u8,
    api_key: []const u8,
    api_header: []const u8,
    model_id: []const u8,
) ?ModelCapability {
    // PSEUDOCODE:
    // 1. Check in-memory global cache.
    // 2. If not found and base_url is present, construct /models URL and fetch via http_lib.
    // 3. If response is 200, parse capability and store in cache.
    // 4. Return found or default capability.
    const cache = getGlobalCache(alloc);
    if (cache.get(model_id)) |c| return c;

    if (base_url.len == 0) return null;

    // Construct /models URL from base_url
    var url_buf: [512]u8 = undefined;
    const models_url: []const u8 = blk: {
        var clean = base_url;
        if (std.mem.endsWith(u8, clean, "/chat/completions")) {
            clean = clean[0 .. clean.len - "/chat/completions".len];
        } else if (std.mem.endsWith(u8, clean, "/responses")) {
            clean = clean[0 .. clean.len - "/responses".len];
        }
        if (std.mem.endsWith(u8, clean, "/")) {
            clean = clean[0 .. clean.len - 1];
        }
        break :blk std.fmt.bufPrint(&url_buf, "{s}/models", .{clean}) catch return null;
    };

    var headers_json_buf: [512]u8 = undefined;
    const headers_json: ?[]const u8 = if (api_key.len > 0) blk: {
        if (std.mem.eql(u8, api_header, "Authorization")) {
            break :blk std.fmt.bufPrint(&headers_json_buf, "{{\"Authorization\":\"Bearer {s}\"}}", .{api_key}) catch null;
        } else {
            break :blk std.fmt.bufPrint(&headers_json_buf, "{{\"{s}\":\"{s}\"}}", .{ api_header, api_key }) catch null;
        }
    } else null;

    var resp = http_lib.fetch(alloc, io, .{
        .url = models_url,
        .method = "GET",
        .headers_json = headers_json,
        .timeout_s = 5,
    }) catch {
        if (alloc.dupe(u8, model_id)) |id_dup| {
            cache.put(model_id, .{ .id = id_dup }) catch self_err: {
                alloc.free(id_dup);
                break :self_err;
            };
        } else |_| {}
        return null;
    };
    defer resp.deinit(alloc);

    if (resp.status != 200) {
        if (alloc.dupe(u8, model_id)) |id_dup| {
            cache.put(model_id, .{ .id = id_dup }) catch self_err: {
                alloc.free(id_dup);
                break :self_err;
            };
        } else |_| {}
        return null;
    }

    if (parseModelCapabilityFromJson(alloc, resp.body, model_id)) |cap| {
        cache.put(model_id, cap) catch {};
        return cap;
    }

    if (alloc.dupe(u8, model_id)) |id_dup| {
        cache.put(model_id, .{ .id = id_dup }) catch self_err: {
            alloc.free(id_dup);
            break :self_err;
        };
    } else |_| {}
    return null;
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "capabilities: normalizeModelAlias strips prefixes and suffixes" {
    try std.testing.expectEqualStrings("gpt-4o", normalizeModelAlias("~gpt-4o"));
    try std.testing.expectEqualStrings("o3-mini", normalizeModelAlias("o3-mini~high"));
    try std.testing.expectEqualStrings("o3-mini", normalizeModelAlias("openai/~o3-mini"));
    try std.testing.expectEqualStrings("openai/gpt-4o", normalizeModelAlias("~openai/gpt-4o"));
    try std.testing.expectEqualStrings("o1", normalizeModelAlias("o1~medium"));
    try std.testing.expectEqualStrings("gpt-4o-mini", normalizeModelAlias("gpt-4o-mini"));
}

test "capabilities: clipEffort respects supported_efforts and mandatory" {
    const supp = [_][]const u8{ "low", "medium", "high" };

    // 1. Non-mandatory
    const cap_opt = ModelCapability{
        .id = "mock-opt",
        .supports_reasoning = true,
        .reasoning_mandatory = false,
        .supported_efforts = &supp,
    };
    try std.testing.expectEqualStrings("high", cap_opt.clipEffort("high").?);
    try std.testing.expectEqualStrings("low", cap_opt.clipEffort("unsupported").?);
    try std.testing.expectEqualStrings("none", cap_opt.clipEffort("none").?);
    try std.testing.expect(cap_opt.clipEffort(null) == null);

    // 2. Mandatory
    const cap_man = ModelCapability{
        .id = "mock-man",
        .supports_reasoning = true,
        .reasoning_mandatory = true,
        .supported_efforts = &supp,
    };
    try std.testing.expectEqualStrings("medium", cap_man.clipEffort("medium").?);
    try std.testing.expectEqualStrings("low", cap_man.clipEffort("none").?);
    try std.testing.expectEqualStrings("low", cap_man.clipEffort(null).?);
}

test "capabilities: guardReasoningMaxTokens enforces Anthropic and OpenAI constraints" {
    // Anthropic: strictly < max_tokens
    try std.testing.expectEqual(@as(u32, 3072), ModelCapability.guardReasoningMaxTokens(4096, 4096, true));
    try std.testing.expectEqual(@as(u32, 2000), ModelCapability.guardReasoningMaxTokens(2000, 4096, true));
    try std.testing.expectEqual(@as(u32, 3072), ModelCapability.guardReasoningMaxTokens(5000, 4096, true));

    // OpenAI: <= max_tokens
    try std.testing.expectEqual(@as(u32, 4096), ModelCapability.guardReasoningMaxTokens(4096, 4096, false));
    try std.testing.expectEqual(@as(u32, 4096), ModelCapability.guardReasoningMaxTokens(5000, 4096, false));
    try std.testing.expectEqual(@as(u32, 2048), ModelCapability.guardReasoningMaxTokens(2048, 4096, false));
}

test "capabilities: parseModelCapabilityFromJson extracts model fields" {
    const alloc = std.testing.allocator;
    const json_str =
        \\{
        \\  "object": "list",
        \\  "data": [
        \\    {
        \\      "id": "gpt-4o",
        \\      "max_tokens": 4096
        \\    },
        \\    {
        \\      "id": "o3-mini",
        \\      "max_tokens": 8192,
        \\      "reasoning": {
        \\        "mandatory": true,
        \\        "max_tokens": 4096,
        \\        "supported_efforts": ["low", "medium", "high"]
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    // Matching o3-mini via alias
    const cap = parseModelCapabilityFromJson(alloc, json_str, "~o3-mini~high");
    try std.testing.expect(cap != null);
    defer {
        alloc.free(cap.?.id);
        for (cap.?.supported_efforts) |eff| alloc.free(eff);
        alloc.free(cap.?.supported_efforts);
    }
    try std.testing.expectEqualStrings("o3-mini", cap.?.id);
    try std.testing.expect(cap.?.reasoning_mandatory);
    try std.testing.expectEqual(@as(?u32, 8192), cap.?.max_tokens);
    try std.testing.expectEqual(@as(?u32, 4096), cap.?.reasoning_max_tokens);
    try std.testing.expectEqual(@as(usize, 3), cap.?.supported_efforts.len);
}

test "capabilities: CapabilityCache put, get, and deinit leak-free" {
    const alloc = std.testing.allocator;
    var cache = CapabilityCache.init(alloc);
    defer cache.deinit();

    const id1 = try alloc.dupe(u8, "o3-mini");
    const eff = try alloc.alloc([]const u8, 1);
    eff[0] = try alloc.dupe(u8, "low");

    try cache.put("o3-mini", .{
        .id = id1,
        .supports_reasoning = true,
        .reasoning_mandatory = true,
        .supported_efforts = eff,
    });

    const found = cache.get("~o3-mini");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("o3-mini", found.?.id);

    // Overwrite with new entry (verifies fetchRemove doesn't leak old entry)
    const id2 = try alloc.dupe(u8, "o3-mini");
    try cache.put("~o3-mini", .{
        .id = id2,
        .supports_reasoning = false,
        .supported_efforts = &.{},
    });

    const updated = cache.get("o3-mini");
    try std.testing.expect(updated != null);
    try std.testing.expect(!updated.?.supports_reasoning);
}

