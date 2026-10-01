//! core/plan/store.zig — Persistent plan storage (RFC-019)
//!
//! Stores and restores plans using Content-Addressed Storage (CAS).
//! Enables cross-turn and cross-session plan persistence.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cas_mod = @import("../cas.zig");
const CAS = cas_mod.CAS;
const plan_mod = @import("types.zig");
const Plan = plan_mod.Plan;
const json_mod = @import("../json.zig");
const utils = @import("../utils.zig");

// ---------------------------------------------------------------------------
// Plan Metadata
// ---------------------------------------------------------------------------

/// Metadata stored alongside plan content in metadata.jsonl.
pub const PlanMetadata = struct {
    /// Plan ID.
    plan_id: u64,
    /// Hash of user request (for matching).
    request_hash: u64,
    /// Number of steps in plan.
    steps_count: usize,
    /// Timestamp when plan was created.
    created_at: i64,
    /// Timestamp when plan was last updated.
    updated_at: i64,
    /// CAS hash of plan content.
    content_hash: []const u8,
    /// Whether plan is complete.
    is_complete: bool,
    /// Number of steps completed.
    steps_completed: usize,
    /// Plan lifecycle phase (RFC-024 §3.2).
    phase: []const u8,
};

// ---------------------------------------------------------------------------
// Plan Store
// ---------------------------------------------------------------------------

/// Persistent storage for plans using CAS.
pub const PlanStore = struct {
    cas: *CAS,
    alloc: Allocator,
    io: std.Io,
    plans_dir: []u8,
    metadata_file_path: []u8,

    /// Initialize plan store at the specified directory.
    pub fn init(alloc: Allocator, io: std.Io, cas: *CAS, plans_dir: []const u8) !PlanStore {
        const dir_dup = try alloc.dupe(u8, plans_dir);
        errdefer alloc.free(dir_dup);

        // Create directory if needed
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(io, dir_dup) catch {};

        const meta_path = try std.fs.path.join(alloc, &.{ dir_dup, "metadata.jsonl" });
        errdefer alloc.free(meta_path);

        return PlanStore{
            .cas = cas,
            .alloc = alloc,
            .io = io,
            .plans_dir = dir_dup,
            .metadata_file_path = meta_path,
        };
    }

    /// Deinitialize plan store.
    pub fn deinit(self: *PlanStore) void {
        self.alloc.free(self.plans_dir);
        self.alloc.free(self.metadata_file_path);
    }

    // PSEUDOCODE:
    // 1. Serialize plan to JSON using plan.toJson(self.alloc)
    // 2. Store JSON in CAS to obtain content_hash digest
    // 3. Populate PlanMetadata struct with timestamps and hashes
    // 4. Append serialized metadata record to metadata.jsonl via writeMetadata

    /// Save a plan to storage.
    pub fn save(self: *PlanStore, plan: *Plan) !void {
        const json_bytes = try plan.toJson(self.alloc);
        defer self.alloc.free(json_bytes);

        const content_hash = try self.cas.store(self.io, json_bytes);
        defer self.alloc.free(content_hash);

        const metadata = PlanMetadata{
            .plan_id = plan.id,
            .request_hash = plan.request_hash,
            .steps_count = plan.stepCount(),
            .created_at = plan.created_at,
            .updated_at = utils.milliTimestamp(),
            .content_hash = content_hash,
            .is_complete = plan.isComplete(),
            .steps_completed = plan.completedCount(),
            .phase = @tagName(plan.phase),
        };

        try self.writeMetadata(&metadata);
    }

    // PSEUDOCODE:
    // 1. Read metadata entries from metadata.jsonl
    // 2. Scan newest→oldest for matching request_hash
    // 3. Retrieve JSON from CAS, parse into Plan, return ?Plan

    /// Restore a plan by request hash. Returns null if not found.
    pub fn restore(self: *PlanStore, request_hash: u64) !?Plan {
        const metas = try self.readMetadata();
        defer self.freeMetadata(metas);

        if (metas.len == 0) return null;

        // Scan backwards to prefer the most recent plan for this request
        var idx = metas.len;
        while (idx > 0) {
            idx -= 1;
            if (metas[idx].request_hash == request_hash) {
                const meta = metas[idx];
                const json_bytes = try self.cas.retrieve(self.io, meta.content_hash);
                defer self.alloc.free(json_bytes);

                return try Plan.fromJson(self.alloc, json_bytes);
            }
        }

        return null;
    }

    /// RFC-024 §3.2: restore the newest *running* (non-complete) plan for a
    /// request, so a mid-plan crash revives the in-progress plan rather than a
    /// finished one. Returns null if none.
    pub fn restoreRunning(self: *PlanStore, request_hash: u64) !?Plan {
        const metas = try self.readMetadata();
        defer self.freeMetadata(metas);

        var idx = metas.len;
        while (idx > 0) {
            idx -= 1;
            if (metas[idx].request_hash == request_hash and !metas[idx].is_complete) {
                const meta = metas[idx];
                const json_bytes = try self.cas.retrieve(self.io, meta.content_hash);
                defer self.alloc.free(json_bytes);

                return try Plan.fromJson(self.alloc, json_bytes);
            }
        }

        return null;
    }

    /// List all plans (for debugging/metrics).
    pub fn listPlans(self: *PlanStore) ![]PlanMetadata {
        return try self.readMetadata();
    }

    // -----------------------------------------------------------------------
    // Metadata Management
    // -----------------------------------------------------------------------

    // PSEUDOCODE:
    // 1. Open or create metadata.jsonl file
    // 2. Format JSON metadata line using utils.BufWriter
    // 3. Write to end of file and sync

    /// Append a metadata entry to metadata.jsonl.
    pub fn writeMetadata(self: *PlanStore, meta: *const PlanMetadata) !void {
        const cwd = std.Io.Dir.cwd();
        const file = cwd.openFile(self.io, self.metadata_file_path, .{ .mode = .read_write }) catch |err| {
            if (err == error.FileNotFound) {
                const created = try cwd.createFile(self.io, self.metadata_file_path, .{});
                created.close(self.io);
                return self.writeMetadata(meta);
            }
            return err;
        };
        defer file.close(self.io);

        var bw = utils.BufWriter.init(self.alloc);
        defer bw.deinit();

        const esc_hash = try json_mod.escape(self.alloc, meta.content_hash);
        defer self.alloc.free(esc_hash);

        try bw.print(
            "{{\"plan_id\":{d},\"request_hash\":{d},\"steps_count\":{d},\"created_at\":{d},\"updated_at\":{d},\"content_hash\":\"{s}\",\"is_complete\":{},\"steps_completed\":{d},\"phase\":\"{s}\"}}\n",
            .{
                meta.plan_id,
                meta.request_hash,
                meta.steps_count,
                meta.created_at,
                meta.updated_at,
                esc_hash,
                meta.is_complete,
                meta.steps_completed,
                meta.phase,
            },
        );

        const line = try bw.toOwnedSlice();
        defer self.alloc.free(line);

        const end_offset = try file.length(self.io);
        try file.writePositionalAll(self.io, line, end_offset);
        try file.sync(self.io);
    }

    /// Alias for writeMetadata.
    pub const appendMetadata = writeMetadata;

    // PSEUDOCODE:
    // 1. Open metadata.jsonl (return empty slice if not found)
    // 2. Read entire file contents into buffer
    // 3. Split by newline and parse each line with std.json.parseFromSlice
    // 4. Return array of PlanMetadata

    /// Read all metadata records from metadata.jsonl.
    pub fn readMetadata(self: *PlanStore) ![]PlanMetadata {
        var metas = std.ArrayListUnmanaged(PlanMetadata).empty;
        errdefer {
            for (metas.items) |*m| {
                self.alloc.free(m.content_hash);
                self.alloc.free(m.phase);
            }
            metas.deinit(self.alloc);
        }

        const cwd = std.Io.Dir.cwd();
        const file = cwd.openFile(self.io, self.metadata_file_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                return metas.toOwnedSlice(self.alloc);
            }
            return err;
        };
        defer file.close(self.io);

        const stat = try file.stat(self.io);
        if (stat.size == 0) {
            return metas.toOwnedSlice(self.alloc);
        }

        const buf = try self.alloc.alloc(u8, @intCast(stat.size));
        defer self.alloc.free(buf);

        const n = try utils.readAll(self.io, file, buf);

        var it = std.mem.splitScalar(u8, buf[0..n], '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;

            const parsed = std.json.parseFromSlice(PlanMetadataJson, self.alloc, trimmed, .{ .ignore_unknown_fields = true }) catch continue;
            defer parsed.deinit();

            const meta = PlanMetadata{
                .plan_id = parsed.value.plan_id,
                .request_hash = parsed.value.request_hash,
                .steps_count = parsed.value.steps_count,
                .created_at = parsed.value.created_at,
                .updated_at = parsed.value.updated_at,
                .content_hash = try self.alloc.dupe(u8, parsed.value.content_hash),
                .is_complete = parsed.value.is_complete,
                .steps_completed = parsed.value.steps_completed,
                .phase = try self.alloc.dupe(u8, parsed.value.phase),
            };
            try metas.append(self.alloc, meta);
        }

        return try metas.toOwnedSlice(self.alloc);
    }

    /// Alias for readMetadata.
    pub const loadMetadata = readMetadata;

    /// Free allocated metadata slice and its nested string buffers.
    pub fn freeMetadata(self: *PlanStore, metas: []PlanMetadata) void {
        for (metas) |*m| {
            self.alloc.free(m.content_hash);
            self.alloc.free(m.phase);
        }
        self.alloc.free(metas);
    }
};

// ---------------------------------------------------------------------------
// JSON Representation for Metadata
// ---------------------------------------------------------------------------

const PlanMetadataJson = struct {
    plan_id: u64,
    request_hash: u64,
    steps_count: usize,
    created_at: i64,
    updated_at: i64,
    content_hash: []const u8,
    is_complete: bool,
    steps_completed: usize,
    /// RFC-024 §3.2. Old files without this key parse to the default.
    phase: []const u8 = "proposed",
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "PlanStore - save and restore" {
    const alloc = std.testing.allocator;

    var buf: [256]u8 = undefined;
    const dir = try std.fmt.bufPrint(&buf, "/tmp/mini_planstore_test_{d}", .{std.c.getpid()});
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    var cas = try CAS.init(alloc, std.testing.io, dir);
    defer cas.deinit();

    var store = try PlanStore.init(alloc, std.testing.io, &cas, dir);
    defer store.deinit();

    var plan = try Plan.init(alloc, "Test plan", 0x1234);
    defer plan.deinit(alloc);

    var step1 = try plan_mod.PlanStep.init(alloc, "Step 1", &.{}, "file_read");
    defer step1.deinit(alloc);
    try plan.addStep(alloc, step1);

    try store.save(&plan);

    var restored = (try store.restore(0x1234)) orelse return error.TestExpectedPlan;
    defer restored.deinit(alloc);

    try std.testing.expectEqualStrings("Test plan", restored.task_description);
    try std.testing.expectEqual(1, restored.stepCount());
    try std.testing.expectEqualStrings("Step 1", restored.steps.items[0].description);
}
