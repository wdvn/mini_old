//! core/plan/types.zig — Structured Planning System
//!
//! Provides plan data model with step tracking, dependency management,
//! serialization, and validation for multi-step task execution.
//!
//! ## Key Types
//! - `StepStatus` — enum for step lifecycle (pending, active, completed, failed, skipped)
//! - `PlanStep` — individual step with dependencies and tool hints
//! - `Plan` — collection of steps with task description and metadata
//! - `PlanDrift` — deviation between planned and executed actions

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const utils = @import("../utils.zig");

// ---------------------------------------------------------------------------
// Step Status
// ---------------------------------------------------------------------------

/// Status of a plan step.
pub const StepStatus = enum {
    /// Step not yet started.
    pending,
    /// Step currently being executed.
    active,
    /// Step completed successfully.
    completed,
    /// Step failed and will not be retried.
    failed,
    /// Step skipped (dependencies not met or manual skip).
    skipped,
};

/// Parse StepStatus from a string tag.
pub fn parseStepStatus(str: []const u8) StepStatus {
    if (std.mem.eql(u8, str, "active")) return .active;
    if (std.mem.eql(u8, str, "completed")) return .completed;
    if (std.mem.eql(u8, str, "failed")) return .failed;
    if (std.mem.eql(u8, str, "skipped")) return .skipped;
    return .pending;
}

// ---------------------------------------------------------------------------
// Plan Phase
// ---------------------------------------------------------------------------

/// Plan lifecycle phase. `proposed` is the default for a freshly parsed plan;
/// execution guidance is gated on `approved` (advisory).
pub const PlanPhase = enum {
    /// Parsed but not yet user-approved (default).
    proposed,
    /// User has approved (`/plan approve`); steps are now actionable.
    approved,
    /// An approved step is currently in flight.
    executing,
    /// All steps complete.
    complete,
    /// User rejected the plan.
    rejected,
};

/// Parse PlanPhase from a string tag.
pub fn parsePlanPhase(str: []const u8) PlanPhase {
    if (std.mem.eql(u8, str, "approved")) return .approved;
    if (std.mem.eql(u8, str, "executing")) return .executing;
    if (std.mem.eql(u8, str, "complete")) return .complete;
    if (std.mem.eql(u8, str, "rejected")) return .rejected;
    return .proposed;
}

/// Parse VerificationStatus from a string tag.
pub fn parseVerificationStatus(str: []const u8) VerificationStatus {
    if (std.mem.eql(u8, str, "passed")) return .passed;
    if (std.mem.eql(u8, str, "failed")) return .failed;
    if (std.mem.eql(u8, str, "timed_out")) return .timed_out;
    if (std.mem.eql(u8, str, "error")) return .check_error;
    return .skipped;
}

// ---------------------------------------------------------------------------
// Step Verification
// ---------------------------------------------------------------------------

/// Result of running a step's verification check (normative state machine).
/// Only `passed` transitions the step to `.completed`.
pub const VerificationStatus = enum {
    /// No verification field present (legacy behavior).
    skipped,
    /// Check succeeded.
    passed,
    /// Check ran and failed.
    failed,
    /// Check hit its time budget.
    timed_out,
    /// Check errored (bad input, unsupported kind, IO error).
    check_error,
};

/// Kind of acceptance check for a plan step.
pub const VerificationKind = enum { shell, file_exists, file_contains };

/// Optional acceptance check on a plan step. A step is "completed" only when
/// this passes; without it, tool_hint-match completion is unchanged (backward
/// compatible).
pub const StepVerification = struct {
    /// What kind of check to run.
    kind: VerificationKind,
    /// shell: command to run (must exit 0). file_exists: path.
    /// file_contains: "<path> <pattern>" (single leading space separates them).
    value: []const u8,

    pub fn deinit(self: *StepVerification, alloc: Allocator) void {
        alloc.free(self.value);
    }

    pub fn clone(self: *const StepVerification, alloc: Allocator) !StepVerification {
        return .{
            .kind = self.kind,
            .value = try alloc.dupe(u8, self.value),
        };
    }
};

// ---------------------------------------------------------------------------
// Plan Step
// ---------------------------------------------------------------------------

/// A single step in a plan with dependencies and tool hints.
pub const PlanStep = struct {
    /// Unique step ID (auto-assigned during parsing or 1-based index).
    id: u64,
    /// Human-readable description of what this step does.
    description: []const u8,
    /// IDs of prerequisite steps that must complete first.
    dependencies: []const u64,
    /// Current status of this step.
    status: StepStatus = .pending,
    /// Preferred tool for this step (e.g., "file_read", "bash").
    tool_hint: ?[]const u8 = null,
    /// Estimated number of acts needed to complete this step.
    estimated_acts: usize = 1,
    /// Actual acts consumed so far.
    actual_acts: usize = 0,
    /// Timestamp when step was created (milliseconds).
    created_at: i64,
    /// Timestamp when step completed (null if not done).
    completed_at: ?i64 = null,
    /// Optional acceptance check; null = legacy tool_hint completion.
    verification: ?StepVerification = null,
    /// Latest verification result state.
    verification_status: VerificationStatus = .skipped,
    /// "inline" (default) | "subagent" | "parallel:<batch>".
    executor_mode: ?[]const u8 = null,

    // PSEUDOCODE:
    // 1. Allocate copies of description, dependencies, and tool_hint with alloc
    // 2. Return PlanStep with given id and timestamps
    pub fn initWithId(
        alloc: Allocator,
        id: u64,
        description: []const u8,
        dependencies: []const u64,
        tool_hint: ?[]const u8,
    ) !PlanStep {
        const desc = try alloc.dupe(u8, description);
        errdefer alloc.free(desc);
        const deps = try alloc.dupe(u64, dependencies);
        errdefer alloc.free(deps);
        const tool = if (tool_hint) |t| try alloc.dupe(u8, t) else null;
        errdefer if (tool) |t| alloc.free(t);

        return PlanStep{
            .id = id,
            .description = desc,
            .dependencies = deps,
            .status = .pending,
            .tool_hint = tool,
            .estimated_acts = 1,
            .actual_acts = 0,
            .created_at = utils.milliTimestamp(),
            .completed_at = null,
            .verification = null,
            .verification_status = .skipped,
            .executor_mode = null,
        };
    }

    /// Convenience constructor with default id = 1.
    pub fn init(
        alloc: Allocator,
        description: []const u8,
        dependencies: []const u64,
        tool_hint: ?[]const u8,
    ) !PlanStep {
        return initWithId(alloc, 1, description, dependencies, tool_hint);
    }

    // PSEUDOCODE:
    // 1. Duplicate string and slice fields using provided allocator
    // 2. Return freshly cloned PlanStep
    pub fn clone(self: *const PlanStep, alloc: Allocator) !PlanStep {
        const desc = try alloc.dupe(u8, self.description);
        errdefer alloc.free(desc);
        const deps = try alloc.dupe(u64, self.dependencies);
        errdefer alloc.free(deps);
        const tool = if (self.tool_hint) |t| try alloc.dupe(u8, t) else null;
        errdefer if (tool) |t| alloc.free(t);
        const exec = if (self.executor_mode) |em| try alloc.dupe(u8, em) else null;
        errdefer if (exec) |em| alloc.free(em);
        const verif = if (self.verification) |v| try v.clone(alloc) else null;
        errdefer if (verif) |v| v.deinit(alloc);

        return PlanStep{
            .id = self.id,
            .description = desc,
            .dependencies = deps,
            .status = self.status,
            .tool_hint = tool,
            .estimated_acts = self.estimated_acts,
            .actual_acts = self.actual_acts,
            .created_at = self.created_at,
            .completed_at = self.completed_at,
            .verification = verif,
            .verification_status = self.verification_status,
            .executor_mode = exec,
        };
    }

    /// Free all allocated fields.
    pub fn deinit(self: *PlanStep, alloc: Allocator) void {
        alloc.free(self.description);
        alloc.free(self.dependencies);
        if (self.tool_hint) |t| alloc.free(t);
        if (self.executor_mode) |em| alloc.free(em);
        if (self.verification) |v| alloc.free(v.value);
    }
};

// ---------------------------------------------------------------------------
// Plan
// ---------------------------------------------------------------------------

/// A structured plan with multiple steps and dependencies.
pub const Plan = struct {
    /// Unique plan ID.
    id: u64,
    /// Description of the overall task.
    task_description: []const u8,
    /// List of steps to execute.
    steps: std.ArrayListUnmanaged(PlanStep),
    /// Timestamp when plan was created.
    created_at: i64,
    /// Timestamp when plan completed (null if in progress).
    completed_at: ?i64 = null,
    /// ID of parent plan if this is a sub-plan.
    parent_plan_id: ?u64 = null,
    /// Hash of user request for plan matching/restore.
    request_hash: u64,
    /// Lifecycle phase; `proposed` for freshly parsed plans.
    phase: PlanPhase = .proposed,

    /// Initialize a new empty plan.
    pub fn init(alloc: Allocator, task_description: []const u8, request_hash: u64) !Plan {
        const ts = utils.milliTimestamp();

        return Plan{
            .id = @as(u64, @intCast(if (ts > 0) ts else 1)),
            .task_description = try alloc.dupe(u8, task_description),
            .steps = .empty,
            .created_at = ts,
            .completed_at = null,
            .parent_plan_id = null,
            .request_hash = request_hash,
            .phase = .proposed,
        };
    }

    // PSEUDOCODE:
    // 1. Allocate a duplicate of task_description
    // 2. Clone each step using step.clone(alloc)
    // 3. Return cloned Plan
    pub fn clone(self: *const Plan, alloc: Allocator) !Plan {
        var copy = try Plan.init(alloc, self.task_description, self.request_hash);
        errdefer copy.deinit(alloc);
        copy.id = self.id;
        copy.created_at = self.created_at;
        copy.completed_at = self.completed_at;
        copy.parent_plan_id = self.parent_plan_id;
        copy.phase = self.phase;

        for (self.steps.items) |step| {
            try copy.addStep(alloc, step);
        }
        return copy;
    }

    /// Add a step to the plan by duplicating its fields into plan's memory.
    pub fn addStep(self: *Plan, alloc: Allocator, step: PlanStep) !void {
        const desc = try alloc.dupe(u8, step.description);
        errdefer alloc.free(desc);
        const deps = try alloc.dupe(u64, step.dependencies);
        errdefer alloc.free(deps);
        const tool = if (step.tool_hint) |t| try alloc.dupe(u8, t) else null;
        errdefer if (tool) |t| alloc.free(t);
        const exec = if (step.executor_mode) |em| try alloc.dupe(u8, em) else null;
        errdefer if (exec) |em| alloc.free(em);
        const verif = if (step.verification) |v| blk: {
            const val = try alloc.dupe(u8, v.value);
            errdefer alloc.free(val);
            break :blk StepVerification{ .kind = v.kind, .value = val };
        } else null;
        errdefer if (verif) |v| alloc.free(v.value);

        const new_step = PlanStep{
            .id = step.id,
            .description = desc,
            .dependencies = deps,
            .status = step.status,
            .tool_hint = tool,
            .estimated_acts = step.estimated_acts,
            .actual_acts = step.actual_acts,
            .created_at = step.created_at,
            .completed_at = step.completed_at,
            .verification = verif,
            .verification_status = step.verification_status,
            .executor_mode = exec,
        };

        try self.steps.append(alloc, new_step);
    }

    /// Append a step directly, transferring ownership of its allocated fields.
    pub fn addStepOwned(self: *Plan, alloc: Allocator, step: PlanStep) !void {
        try self.steps.append(alloc, step);
    }

    /// Convenience constructor to create and append a step directly to the plan.
    pub fn addStepWithDetails(
        self: *Plan,
        alloc: Allocator,
        id: u64,
        description: []const u8,
        dependencies: []const u64,
        tool_hint: ?[]const u8,
    ) !void {
        const step = try PlanStep.initWithId(alloc, id, description, dependencies, tool_hint);
        try self.addStepOwned(alloc, step);
    }

    /// Free all allocated fields.
    pub fn deinit(self: *Plan, alloc: Allocator) void {
        alloc.free(self.task_description);
        var i: usize = 0;
        while (i < self.steps.items.len) {
            self.steps.items[i].deinit(alloc);
            i += 1;
        }
        self.steps.deinit(alloc);
    }

    /// Get the number of steps in the plan.
    pub fn stepCount(self: *const Plan) usize {
        return self.steps.items.len;
    }

    /// Get the index of the first pending or active step.
    pub fn findActiveStepIndex(self: *const Plan) ?usize {
        var i: usize = 0;
        while (i < self.steps.items.len) : (i += 1) {
            const step = self.steps.items[i];
            if (step.status == .pending or step.status == .active) {
                return i;
            }
        }
        return null;
    }

    /// Dependency-aware ready-set selector. Returns the index of the
    /// first step whose prerequisites are all satisfied (completed/skipped) and
    /// which is not yet finished — replacing the sequential `findActiveStepIndex`
    /// scan in the runtime. A step that is `.active` with unmet deps is left as-is
    /// (never force-completed). Steps whose dependencies cannot be met are
    /// skipped by the caller if all remaining steps are blocked.
    pub fn findReadyStepIndex(self: *const Plan) ?usize {
        var i: usize = 0;
        while (i < self.steps.items.len) : (i += 1) {
            const step = self.steps.items[i];
            if (step.status != .pending and step.status != .active) continue;
            if (self.allDependenciesSatisfied(&step)) {
                return i;
            }
        }
        return null;
    }

    /// Whether every dependency of `step` is completed or skipped. A dependency
    /// id that names no step is treated as satisfied (orphan reference), matching
    /// executePlanStep's lenient behavior.
    pub fn allDependenciesSatisfied(self: *const Plan, step: *const PlanStep) bool {
        for (step.dependencies) |dep_id| {
            for (self.steps.items) |s| {
                if (s.id == dep_id) {
                    if (s.status != .completed and s.status != .skipped) return false;
                }
            }
        }
        return true;
    }

    /// Check if all steps are completed or skipped.
    pub fn isComplete(self: *const Plan) bool {        if (self.steps.items.len == 0) return false;
        var i: usize = 0;
        while (i < self.steps.items.len) {
            const step = self.steps.items[i];
            if (step.status != .completed and step.status != .skipped) {
                return false;
            }
            i += 1;
        }
        return true;
    }

    /// Get count of completed steps.
    pub fn completedCount(self: *const Plan) usize {
        var count: usize = 0;
        var i: usize = 0;
        while (i < self.steps.items.len) {
            if (self.steps.items[i].status == .completed) count += 1;
            i += 1;
        }
        return count;
    }

    fn appendStepMetricsJson(step: PlanStep, alloc: Allocator, buf: *std.ArrayListUnmanaged(u8)) !void {
        var num_buf: [32]u8 = undefined;
        try buf.appendSlice(alloc, ",\"estimated_acts\":");
        try buf.appendSlice(alloc, try std.fmt.bufPrint(&num_buf, "{d}", .{step.estimated_acts}));
        try buf.appendSlice(alloc, ",\"actual_acts\":");
        try buf.appendSlice(alloc, try std.fmt.bufPrint(&num_buf, "{d}", .{step.actual_acts}));
        try buf.appendSlice(alloc, ",\"created_at\":");
        try buf.appendSlice(alloc, try std.fmt.bufPrint(&num_buf, "{d}", .{step.created_at}));

        if (step.completed_at) |cmp_at| {
            try buf.appendSlice(alloc, ",\"completed_at\":");
            try buf.appendSlice(alloc, try std.fmt.bufPrint(&num_buf, "{d}", .{cmp_at}));
        } else {
            try buf.appendSlice(alloc, ",\"completed_at\":null");
        }

        if (step.executor_mode) |em| {
            const esc_em = try json.escape(alloc, em);
            defer alloc.free(esc_em);
            try buf.appendSlice(alloc, ",\"executor_mode\":\"");
            try buf.appendSlice(alloc, esc_em);
            try buf.append(alloc, '"');
        }

        if (step.verification) |v| {
            const esc_v = try json.escape(alloc, v.value);
            defer alloc.free(esc_v);
            try buf.appendSlice(alloc, ",\"verification\":{\"kind\":\"");
            try buf.appendSlice(alloc, @tagName(v.kind));
            try buf.appendSlice(alloc, "\",\"value\":\"");
            try buf.appendSlice(alloc, esc_v);
            try buf.appendSlice(alloc, "\"}");
            try buf.appendSlice(alloc, ",\"verification_status\":\"");
            try buf.appendSlice(alloc, @tagName(step.verification_status));
            try buf.append(alloc, '"');
        }
    }

    fn appendStepJson(step: PlanStep, alloc: Allocator, buf: *std.ArrayListUnmanaged(u8)) !void {
        // PSEUDOCODE: Serialize a single step with id, description, dependencies, status, hints, and metrics.
        var num_buf: [32]u8 = undefined;
        try buf.append(alloc, '{');

        try buf.appendSlice(alloc, "\"id\":");
        try buf.appendSlice(alloc, try std.fmt.bufPrint(&num_buf, "{d}", .{step.id}));

        const esc_desc = try json.escape(alloc, step.description);
        defer alloc.free(esc_desc);
        try buf.appendSlice(alloc, ",\"description\":\"");
        try buf.appendSlice(alloc, esc_desc);
        try buf.append(alloc, '"');

        try buf.appendSlice(alloc, ",\"dependencies\":[");
        for (step.dependencies, 0..) |dep_id, di| {
            if (di > 0) try buf.append(alloc, ',');
            try buf.appendSlice(alloc, try std.fmt.bufPrint(&num_buf, "{d}", .{dep_id}));
        }
        try buf.append(alloc, ']');

        try buf.appendSlice(alloc, ",\"status\":\"");
        try buf.appendSlice(alloc, @tagName(step.status));
        try buf.append(alloc, '"');

        if (step.tool_hint) |th| {
            const esc_th = try json.escape(alloc, th);
            defer alloc.free(esc_th);
            try buf.appendSlice(alloc, ",\"tool_hint\":\"");
            try buf.appendSlice(alloc, esc_th);
            try buf.append(alloc, '"');
        } else {
            try buf.appendSlice(alloc, ",\"tool_hint\":null");
        }

        try appendStepMetricsJson(step, alloc, buf);
        try buf.append(alloc, '}');
    }

    fn appendPlanHeaderJson(self: *const Plan, alloc: Allocator, buf: *std.ArrayListUnmanaged(u8)) !void {
        // PSEUDOCODE: Serialize top-level plan attributes (id, task, hashes, and timestamps).
        var num_buf: [32]u8 = undefined;
        const esc_task = try json.escape(alloc, self.task_description);
        defer alloc.free(esc_task);

        try buf.append(alloc, '{');
        try buf.appendSlice(alloc, "\"id\":");
        try buf.appendSlice(alloc, try std.fmt.bufPrint(&num_buf, "{d}", .{self.id}));
        try buf.appendSlice(alloc, ",\"task\":\"");
        try buf.appendSlice(alloc, esc_task);
        try buf.append(alloc, '"');

        try buf.appendSlice(alloc, ",\"request_hash\":");
        try buf.appendSlice(alloc, try std.fmt.bufPrint(&num_buf, "{d}", .{self.request_hash}));
        try buf.appendSlice(alloc, ",\"created_at\":");
        try buf.appendSlice(alloc, try std.fmt.bufPrint(&num_buf, "{d}", .{self.created_at}));

        if (self.completed_at) |ca| {
            try buf.appendSlice(alloc, ",\"completed_at\":");
            try buf.appendSlice(alloc, try std.fmt.bufPrint(&num_buf, "{d}", .{ca}));
        } else {
            try buf.appendSlice(alloc, ",\"completed_at\":null");
        }

        if (self.parent_plan_id) |pid| {
            try buf.appendSlice(alloc, ",\"parent_plan_id\":");
            try buf.appendSlice(alloc, try std.fmt.bufPrint(&num_buf, "{d}", .{pid}));
        } else {
            try buf.appendSlice(alloc, ",\"parent_plan_id\":null");
        }

        try buf.appendSlice(alloc, ",\"phase\":\"");
        try buf.appendSlice(alloc, @tagName(self.phase));
        try buf.append(alloc, '"');

        try buf.appendSlice(alloc, ",\"steps\":[");
    }

    // PSEUDOCODE:
    // 1. Initialize ArrayList for JSON buffer
    // 2. Write plan-level fields via appendPlanHeaderJson
    // 3. Write steps array via appendStepJson
    // 4. Return toOwnedSlice
    pub fn toJson(self: *const Plan, alloc: Allocator) ![]u8 {
        var buf = std.ArrayListUnmanaged(u8).empty;
        errdefer buf.deinit(alloc);

        try self.appendPlanHeaderJson(alloc, &buf);

        for (self.steps.items, 0..) |step, i| {
            if (i > 0) try buf.append(alloc, ',');
            try appendStepJson(step, alloc, &buf);
        }

        try buf.appendSlice(alloc, "]}");
        return try buf.toOwnedSlice(alloc);
    }

    fn populatePlanMetadata(plan: *Plan, root_obj: std.json.ObjectMap) void {
        // PSEUDOCODE: Extract optional id and timestamps into plan.
        if (root_obj.get("id")) |id_val| {
            if (id_val == .integer and id_val.integer > 0) plan.id = @as(u64, @intCast(id_val.integer));
        }
        if (root_obj.get("created_at")) |ca_val| {
            if (ca_val == .integer) plan.created_at = ca_val.integer;
        }
        if (root_obj.get("completed_at")) |ca_val| {
            if (ca_val == .integer) plan.completed_at = ca_val.integer;
        }
        if (root_obj.get("parent_plan_id")) |pid_val| {
            if (pid_val == .integer and pid_val.integer > 0) plan.parent_plan_id = @as(u64, @intCast(pid_val.integer));
        }
        if (root_obj.get("phase")) |ph_val| {
            if (ph_val == .string) plan.phase = parsePlanPhase(ph_val.string);
        }
    }

    fn populateStepAttributes(alloc: Allocator, step: *PlanStep, s_obj: std.json.ObjectMap) !void {
        if (s_obj.get("status")) |st_val| {
            if (st_val == .string) step.status = parseStepStatus(st_val.string);
        }
        if (s_obj.get("estimated_acts")) |ea_val| {
            if (ea_val == .integer and ea_val.integer > 0) step.estimated_acts = @as(usize, @intCast(ea_val.integer));
        }
        if (s_obj.get("actual_acts")) |aa_val| {
            if (aa_val == .integer and aa_val.integer >= 0) step.actual_acts = @as(usize, @intCast(aa_val.integer));
        }
        if (s_obj.get("created_at")) |sca_val| {
            if (sca_val == .integer) step.created_at = sca_val.integer;
        }
        if (s_obj.get("completed_at")) |scmp_val| {
            if (scmp_val == .integer) step.completed_at = scmp_val.integer;
        }
        if (s_obj.get("executor_mode")) |em_val| {
            if (em_val == .string) {
                step.executor_mode = alloc.dupe(u8, em_val.string) catch step.executor_mode;
            }
        }
        if (s_obj.get("verification_status")) |vs_val| {
            if (vs_val == .string) step.verification_status = parseVerificationStatus(vs_val.string);
        }
        if (s_obj.get("verification")) |v_val| {
            if (try parseVerificationFromJson(alloc, v_val)) |verif| {
                step.verification = verif;
            }
        }
    }

    /// Parse a StepVerification from a JSON object `{"kind": ..., "value": ...}`
    /// or a string shorthand (interpreted as a shell command).
    fn parseVerificationFromJson(alloc: Allocator, v: std.json.Value) !?StepVerification {
        switch (v) {
            .string => |s| {
                if (s.len == 0) return null;
                const val = try alloc.dupe(u8, s);
                errdefer alloc.free(val);
                return StepVerification{ .kind = .shell, .value = val };
            },
            .object => |o| {
                const kind_val = o.get("kind") orelse return null;
                const value_val = o.get("value") orelse return null;
                const kind_str = switch (kind_val) {
                    .string => |s| s,
                    else => return null,
                };
                const value_str = switch (value_val) {
                    .string => |s| s,
                    else => return null,
                };
                if (value_str.len == 0) return null;
                const val = try alloc.dupe(u8, value_str);
                errdefer alloc.free(val);
                const kind: VerificationKind = if (std.mem.eql(u8, kind_str, "file_exists"))
                    .file_exists
                else if (std.mem.eql(u8, kind_str, "file_contains"))
                    .file_contains
                else
                    .shell;
                return StepVerification{ .kind = kind, .value = val };
            },
            else => return null,
        }
    }

    fn parseStepFromJson(alloc: Allocator, item: std.json.Value, fallback_id: u64) !?PlanStep {
        // PSEUDOCODE: Deserialize a single plan step object from JSON value.
        const s_obj = switch (item) {
            .object => |o| o,
            else => return null,
        };
        const desc_val = s_obj.get("description") orelse return null;
        const desc_str = switch (desc_val) {
            .string => |s| s,
            else => return null,
        };

        const step_id: u64 = if (s_obj.get("id")) |sid| switch (sid) {
            .integer => |i| @as(u64, @intCast(if (i >= 0) i else 1)),
            else => fallback_id,
        } else fallback_id;

        var deps_list = std.ArrayListUnmanaged(u64).empty;
        defer deps_list.deinit(alloc);
        if (s_obj.get("dependencies")) |deps_val| {
            if (deps_val == .array) {
                for (deps_val.array.items) |dep_val| {
                    if (dep_val == .integer and dep_val.integer >= 0) {
                        try deps_list.append(alloc, @as(u64, @intCast(dep_val.integer)));
                    }
                }
            }
        }

        const tool_hint: ?[]const u8 = if (s_obj.get("tool_hint")) |th| switch (th) {
            .string => |s| s,
            else => null,
        } else null;

        var step = try PlanStep.initWithId(alloc, step_id, desc_str, deps_list.items, tool_hint);
        errdefer step.deinit(alloc);

        try populateStepAttributes(alloc, &step, s_obj);
        return step;
    }

    // PSEUDOCODE:
    // 1. Parse JSON slice into Value tree
    // 2. Read task string and request_hash
    // 3. Initialize plan, set id, timestamps, parent_plan_id via populatePlanMetadata
    // 4. Iterate over steps array, parse each step object via parseStepFromJson
    // 5. Return reconstructed plan
    pub fn fromJson(alloc: Allocator, json_text: []const u8) !Plan {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
        defer parsed.deinit();

        const root_obj = switch (parsed.value) {
            .object => |o| o,
            else => return error.InvalidPlanFormat,
        };

        const task_val = root_obj.get("task") orelse root_obj.get("task_description") orelse return error.MissingTaskField;
        const task_str = switch (task_val) {
            .string => |s| s,
            else => return error.InvalidTaskField,
        };

        const req_hash: u64 = if (root_obj.get("request_hash")) |rh| switch (rh) {
            .integer => |i| @as(u64, @intCast(if (i >= 0) i else 0)),
            else => 0,
        } else 0;

        var plan = try Plan.init(alloc, task_str, req_hash);
        errdefer plan.deinit(alloc);

        populatePlanMetadata(&plan, root_obj);

        if (root_obj.get("steps")) |steps_val| {
            const step_items = switch (steps_val) {
                .array => |arr| arr.items,
                else => return error.InvalidStepsFormat,
            };

            for (step_items) |item| {
                const fallback_id = @as(u64, @intCast(plan.steps.items.len + 1));
                if (try parseStepFromJson(alloc, item, fallback_id)) |step| {
                    try plan.addStepOwned(alloc, step);
                }
            }
        }

        return plan;
    }
};

// ---------------------------------------------------------------------------
// Plan Drift
// ---------------------------------------------------------------------------

/// Represents deviation between planned and actual execution.
pub const PlanDrift = struct {
    /// ID of the step where drift occurred.
    step_id: u64,
    /// Expected tool name.
    expected_tool: ?[]const u8,
    /// Actual tool name used.
    actual_tool: []const u8,
    /// Drift score from 0.0 (no drift) to 1.0 (complete deviation).
    drift_score: f64,
};

// ---------------------------------------------------------------------------
// Validation Helpers
// ---------------------------------------------------------------------------

// PSEUDOCODE:
// 1. Check if steps list is empty -> valid DAG (true)
// 2. Collect step IDs to check that dependency IDs refer to valid preceding steps
// 3. For each step, run depth-first search tracking current recursion stack
// 4. If any back-edge is hit (rec_stack contains node), report cycle (false)
// 5. Return true if no cycles found

/// Check if a plan has a valid DAG without cycles.
pub fn validateDAG(steps: []const PlanStep) bool {
    var visited = std.AutoHashMap(u64, bool).init(std.heap.page_allocator);
    defer visited.deinit();

    var rec_stack = std.AutoHashMap(u64, bool).init(std.heap.page_allocator);
    defer rec_stack.deinit();

    var i: usize = 0;
    while (i < steps.len) {
        if (!visited.contains(steps[i].id)) {
            if (hasCycle(steps[i].id, steps, &visited, &rec_stack)) {
                return false;
            }
        }
        i += 1;
    }
    return true;
}

/// Check if steps contain any dependency cycles. Returns true if cycles exist.
pub fn checkCycles(steps: []const PlanStep) bool {
    return !validateDAG(steps);
}

fn hasCycle(
    node_id: u64,
    steps: []const PlanStep,
    visited: *std.AutoHashMap(u64, bool),
    rec_stack: *std.AutoHashMap(u64, bool),
) bool {
    visited.put(node_id, true) catch return false;
    rec_stack.put(node_id, true) catch return false;

    // Find the step corresponding to node_id
    var step: ?*const PlanStep = null;
    var i: usize = 0;
    while (i < steps.len) {
        if (steps[i].id == node_id) {
            step = &steps[i];
            break;
        }
        i += 1;
    }

    if (step) |s| {
        var j: usize = 0;
        while (j < s.dependencies.len) {
            const dep_id = s.dependencies[j];
            if (rec_stack.get(dep_id) != null) {
                return true; // Cycle detected
            }
            if (!visited.contains(dep_id)) {
                if (hasCycle(dep_id, steps, visited, rec_stack)) {
                    return true;
                }
            }
            j += 1;
        }
    }

    _ = rec_stack.remove(node_id);
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "PlanStep initialization" {
    const alloc = std.testing.allocator;

    var step = try PlanStep.initWithId(alloc, 1, "Read config file", &.{}, "file_read");
    defer step.deinit(alloc);

    try std.testing.expectEqualStrings("Read config file", step.description);
    try std.testing.expectEqual(.pending, step.status);
    try std.testing.expectEqualStrings("file_read", step.tool_hint.?);
    try std.testing.expectEqual(1, step.id);
}

test "PlanStep clone" {
    const alloc = std.testing.allocator;

    var step = try PlanStep.initWithId(alloc, 42, "Original step", &[_]u64{ 1, 2 }, "bash");
    defer step.deinit(alloc);

    var cloned = try step.clone(alloc);
    defer cloned.deinit(alloc);

    try std.testing.expectEqual(step.id, cloned.id);
    try std.testing.expectEqualStrings(step.description, cloned.description);
    try std.testing.expectEqual(step.dependencies.len, cloned.dependencies.len);
    try std.testing.expectEqualStrings(step.tool_hint.?, cloned.tool_hint.?);
}

test "Plan initialization, step addition, and clone" {
    const alloc = std.testing.allocator;

    var plan = try Plan.init(alloc, "Implement feature", 0x1234);
    defer plan.deinit(alloc);

    try std.testing.expectEqual(0, plan.stepCount());

    var step1 = try PlanStep.initWithId(alloc, 1, "Step 1", &.{}, "file_read");
    defer step1.deinit(alloc);
    try plan.addStep(alloc, step1);

    try std.testing.expectEqual(1, plan.stepCount());
    try std.testing.expectEqualStrings("Step 1", plan.steps.items[0].description);

    var cloned_plan = try plan.clone(alloc);
    defer cloned_plan.deinit(alloc);
    try std.testing.expectEqual(1, cloned_plan.stepCount());
    try std.testing.expectEqualStrings("Implement feature", cloned_plan.task_description);
}

test "Plan completion check" {
    const alloc = std.testing.allocator;

    var plan = try Plan.init(alloc, "Test", 0x5678);
    defer plan.deinit(alloc);

    var step = try PlanStep.initWithId(alloc, 1, "Do thing", &.{}, "bash");
    defer step.deinit(alloc);
    try plan.addStep(alloc, step);

    try std.testing.expect(!plan.isComplete());

    // Mark as completed
    plan.steps.items[0].status = .completed;

    try std.testing.expect(plan.isComplete());
    try std.testing.expectEqual(1, plan.completedCount());
}

test "Plan JSON serialization round-trip" {
    const alloc = std.testing.allocator;

    var plan = try Plan.init(alloc, "Build project with tests", 0xabcd);
    defer plan.deinit(alloc);

    var step1 = try PlanStep.initWithId(alloc, 1, "Compile code", &.{}, "bash");
    defer step1.deinit(alloc);
    try plan.addStep(alloc, step1);

    var step2 = try PlanStep.initWithId(alloc, 2, "Run unit tests", &[_]u64{1}, "bash");
    defer step2.deinit(alloc);
    try plan.addStep(alloc, step2);

    const json_str = try plan.toJson(alloc);
    defer alloc.free(json_str);

    var restored = try Plan.fromJson(alloc, json_str);
    defer restored.deinit(alloc);

    try std.testing.expectEqualStrings("Build project with tests", restored.task_description);
    try std.testing.expectEqual(2, restored.stepCount());
    try std.testing.expectEqualStrings("Compile code", restored.steps.items[0].description);
    try std.testing.expectEqual(0, restored.steps.items[0].dependencies.len);
    try std.testing.expectEqualStrings("Run unit tests", restored.steps.items[1].description);
    try std.testing.expectEqual(1, restored.steps.items[1].dependencies.len);
    try std.testing.expectEqual(1, restored.steps.items[1].dependencies[0]);
}

test "DAG validation - no cycles" {
    const alloc = std.testing.allocator;

    var step1 = try PlanStep.initWithId(alloc, 1, "Step 1", &.{}, null);
    defer step1.deinit(alloc);

    var step2 = try PlanStep.initWithId(alloc, 2, "Step 2", &[_]u64{1}, null);
    defer step2.deinit(alloc);

    var step3 = try PlanStep.initWithId(alloc, 3, "Step 3", &[_]u64{ 1, 2 }, null);
    defer step3.deinit(alloc);

    const steps = [_]PlanStep{ step1, step2, step3 };
    try std.testing.expect(validateDAG(&steps));
    try std.testing.expect(!checkCycles(&steps));
}

test "DAG validation - cycle detected" {
    const alloc = std.testing.allocator;

    var step1 = try PlanStep.initWithId(alloc, 1, "Step 1", &[_]u64{2}, null);
    defer step1.deinit(alloc);

    var step2 = try PlanStep.initWithId(alloc, 2, "Step 2", &[_]u64{1}, null);
    defer step2.deinit(alloc);

    const cyclic_steps = [_]PlanStep{ step1, step2 };
    try std.testing.expect(!validateDAG(&cyclic_steps));
    try std.testing.expect(checkCycles(&cyclic_steps));
}

test "verification + executor_mode + phase JSON round-trip" {
    const alloc = std.testing.allocator;

    var plan = try Plan.init(alloc, "Plan with verification", 0xabcd);
    defer plan.deinit(alloc);
    plan.phase = .approved;

    const ver_value = try alloc.dupe(u8, "zig build test");
    // NOTE: ver_value is now owned by step1.verification and freed by
    // step1.deinit below — do NOT free it separately (double-free).
    var step1 = try PlanStep.initWithId(alloc, 1, "Run build", &.{}, "bash");
    defer step1.deinit(alloc);
    step1.verification = StepVerification{ .kind = .shell, .value = ver_value };
    step1.executor_mode = try alloc.dupe(u8, "inline");
    try plan.addStep(alloc, step1);

    const json_str = try plan.toJson(alloc);
    defer alloc.free(json_str);

    var restored = try Plan.fromJson(alloc, json_str);
    defer restored.deinit(alloc);

    try std.testing.expectEqual(PlanPhase.approved, restored.phase);
    const s = &restored.steps.items[0];
    try std.testing.expect(s.verification != null);
    try std.testing.expectEqual(VerificationKind.shell, s.verification.?.kind);
    try std.testing.expectEqualStrings("zig build test", s.verification.?.value);
    try std.testing.expectEqualStrings("inline", s.executor_mode.?);
}

test "string-shorthand verification parses as shell" {
    const alloc = std.testing.allocator;
    const json_text =
        \\{"task":"t","phase":"proposed","request_hash":1,"steps":[
        \\  {"id":1,"description":"d","verification":"echo ok"}
        \\]}
    ;
    var plan = try Plan.fromJson(alloc, json_text);
    defer plan.deinit(alloc);
    try std.testing.expectEqual(VerificationKind.shell, plan.steps.items[0].verification.?.kind);
}

test "ready-step selector honors dependencies" {
    const alloc = std.testing.allocator;

    var plan = try Plan.init(alloc, "Ready-set", 0x1);
    defer plan.deinit(alloc);

    var s1 = try PlanStep.initWithId(alloc, 1, "one", &.{}, null);
    defer s1.deinit(alloc);
    try plan.addStep(alloc, s1);

    var s2 = try PlanStep.initWithId(alloc, 2, "two", &[_]u64{1}, null);
    defer s2.deinit(alloc);
    try plan.addStep(alloc, s2);

    // Both pending: s1 is ready (no deps), s2 is not (s1 not complete).
    try std.testing.expectEqual(@as(usize, 0), plan.findReadyStepIndex().?);

    plan.steps.items[0].status = .completed;
    try std.testing.expectEqual(@as(usize, 1), plan.findReadyStepIndex().?);

    plan.steps.items[1].status = .completed;
    try std.testing.expect(plan.findReadyStepIndex() == null);
}
