//! plan_integration.zig — Plan state & orchestration extracted from agent.zig
//!
//! Encapsulates all plan-related state (legacy watchdog + RFC-019 structured planning)
//! and orchestration logic that was previously inlined in AgentLoop.
//! This module owns:
//!   - Plan lifecycle (set, clear, detect, restore)
//!   - Progress tracking
//!   - Plan watchdog enforcement (end_turn directive injection)
//!   - Plan detection in response text
//!   - PlanStore initialization/deinitialization

const std = @import("std");
const Allocator = std.mem.Allocator;
const plan_mod = @import("plan.zig");
const plan_parser = @import("plan_parser.zig");
const plan_executor = @import("plan_executor.zig");
const plan_store_mod = @import("plan_store.zig");
const cas_mod = @import("cas.zig");
const config_mod = @import("config.zig");
const utils = @import("utils.zig");
const main = @import("../main.zig");

/// Result of plan watchdog check at end_turn.
pub const WatchdogAction = enum {
    /// Inject directive and continue loop.
    continue_loop,
    /// Watchdog cap reached — clear plan and exit loop.
    exit_loop,
    /// Plan not active or plan-only request — proceed normally.
    no_action,
};

/// Consolidated plan state, previously spread across 14+ fields in AgentLoop.
pub const PlanState = struct {
    alloc: Allocator,

    // -- Legacy plan watchdog state (pre-RFC-019) --

    /// Whether a plan commitment has been detected in model output.
    plan_active: bool = false,
    /// Fixed buffer for plan summary text.
    plan_summary_buf: [160]u8 = undefined,
    /// Length of valid data in plan_summary_buf.
    plan_summary_len: usize = 0,
    /// How many consecutive acts the model emitted text without executing tools.
    plan_procrastination_count: usize = 0,
    /// Maximum allowed procrastination acts before watchdog intervenes.
    plan_procrastination_cap: usize = 2,
    /// Flag indicating that a plan has been requested to break an action loop;
    /// if the model returns text without tool execution, prompts the model to execute step 1.
    plan_execution_pending: bool = false,
    /// Consecutive watchdog directives injected while model keeps answering in text.
    /// Caps at 2 to prevent infinite looping.
    plan_watchdog_retries: usize = 0,
    /// Number of times the agent has prompted the model to formulate a plan
    /// and execute next step to recover from an action loop in the current turn.
    loop_plan_retries: usize = 0,

    // -- RFC-019: Structured Planning System --

    /// Structured plan (replaces plan_active/plan_summary_buf when enabled).
    current_plan: ?plan_mod.Plan = null,
    /// Current step index being executed.
    current_step_idx: usize = 0,
    /// Plan execution context.
    plan_ctx: plan_executor.ExecutionContext = .{},
    /// Plan store for cross-turn persistence.
    plan_store: ?*plan_store_mod.PlanStore = null,
    /// Drift score tracker.
    plan_drift_score: f64 = 0.0,
    /// Enable structured planning (config-gated; default: true, overridable via /plan).
    enable_structured_planning: bool = true,

    // -- Progress tracking --

    /// Progress summary from last act (injected as advisory before each new act).
    progress_summary_buf: [512]u8 = undefined,
    /// Length of valid data in progress_summary_buf.
    progress_summary_len: usize = 0,

    /// Initialize PlanState from config, optionally creating a PlanStore.
    pub fn init(
        alloc: Allocator,
        io: std.Io,
        config: *const config_mod.Config,
        cas_ptr: *cas_mod.CAS,
    ) PlanState {
        var plan_store_ptr: ?*plan_store_mod.PlanStore = null;
        if (config.enable_structured_planning) {
            var plans_path_buf: [512]u8 = undefined;
            const home_dir = utils.getEnvSlice("HOME") orelse ".";
            const plans_dir = config.plans_dir orelse (std.fmt.bufPrint(&plans_path_buf, "{s}/.mini/plans", .{home_dir}) catch ".mini/plans");
            const store = alloc.create(plan_store_mod.PlanStore) catch null;
            if (store) |st| {
                if (plan_store_mod.PlanStore.init(alloc, io, cas_ptr, plans_dir)) |val| {
                    st.* = val;
                    plan_store_ptr = st;
                    main.stderrPrint("[agent] Plan Store initialized at: {s}\n", .{plans_dir});
                } else |e| {
                    main.stderrPrint("[agent] Warning: Failed to init PlanStore: {s}\n", .{@errorName(e)});
                    alloc.destroy(st);
                }
            }
        }

        return .{
            .alloc = alloc,
            .enable_structured_planning = config.enable_structured_planning,
            .plan_store = plan_store_ptr,
        };
    }

    /// Release plan-related resources.
    pub fn deinit(self: *PlanState) void {
        if (self.plan_store) |ps| {
            ps.deinit();
            self.alloc.destroy(ps);
            self.plan_store = null;
        }
        if (self.current_plan) |*p| {
            p.deinit(self.alloc);
            self.current_plan = null;
        }
    }

    // -----------------------------------------------------------------------
    // Plan lifecycle methods (migrated from AgentLoop)
    // -----------------------------------------------------------------------

    pub fn setStructuredPlan(self: *PlanState, plan: plan_mod.Plan) void {
        if (self.current_plan) |*p| {
            p.deinit(self.alloc);
        }
        self.current_plan = plan;
        self.plan_ctx = .{};
        self.plan_drift_score = 0.0;
        self.plan_active = true;
        self.renderPlanDisplay();
    }

    /// Render the structured plan to the terminal UI (RFC-019 user visibility).
    ///
    /// Previously the plan was only reported as a one-line stderr note
    /// ("Structured plan detected: N steps") while step contents were
    /// injected exclusively into LLM history, so the user never saw the
    /// plan in the REPL. This writes the full step list via the active
    /// TurnRenderer when available, falling back to stderr otherwise.
    /// PSEUDOCODE:
    //  1. Skip rendering entirely for subagents (no terminal UI attached)
    //  2. Format header + numbered steps (with optional tool hints)
    //  3. Write through current_renderer if present, else stderrPrint
    pub fn renderPlanDisplay(self: *PlanState) void {
        if (utils.isSubagent()) return;
        const plan = &(self.current_plan orelse return);

        var buf = utils.BufWriter.init(self.alloc);
        errdefer buf.deinit();

        buf.print("📋 Plan ({d} steps):\n", .{plan.stepCount()}) catch return;
        for (plan.steps.items, 0..) |step, i| {
            buf.print("  {d}. {s}", .{ i + 1, step.description }) catch return;
            if (step.tool_hint) |hint| {
                buf.print(" \x1b[90m[{s}]\x1b[0m", .{hint}) catch return;
            }
            buf.writeAll("\n") catch return;
        }

        const display = buf.toOwnedSlice() catch return;
        defer self.alloc.free(display);

        if (main.ui_repl.current_renderer) |r| {
            r.ensureNewline();
            r.write(display);
            r.ensureNewline();
        } else {
            main.stderrPrint("{s}", .{display});
        }
    }

    pub fn setPlan(self: *PlanState, summary: []const u8) void {
        if (!self.plan_active) {
            self.plan_active = true;
            self.plan_procrastination_count = 0;
        }
        const len = @min(summary.len, self.plan_summary_buf.len);
        @memcpy(self.plan_summary_buf[0..len], summary[0..len]);
        self.plan_summary_len = len;

        // RFC-019: If structured planning is enabled, attempt to parse structured plan from summary
        if (self.enable_structured_planning and self.current_plan == null) {
            if (plan_parser.extractStructuredPlan(summary, self.alloc) catch null) |plan| {
                if (plan.stepCount() > 0) {
                    self.setStructuredPlan(plan);
                } else {
                    var mut_p = plan;
                    mut_p.deinit(self.alloc);
                }
            }
        }
    }

    pub fn clearPlan(self: *PlanState) void {
        self.plan_active = false;
        self.plan_summary_len = 0;
        self.plan_procrastination_count = 0;
        self.plan_execution_pending = false;
        if (self.current_plan) |*p| {
            p.deinit(self.alloc);
            self.current_plan = null;
        }
        self.plan_ctx = .{};
        self.plan_drift_score = 0.0;
    }

    pub fn getPlanSummary(self: *const PlanState) []const u8 {
        if (self.plan_summary_len > 0) return self.plan_summary_buf[0..self.plan_summary_len];
        return "active implementation plan";
    }

    /// Update progress summary after an act completes. Caps at progress_summary_buf.
    pub fn updateProgress(self: *PlanState, summary: []const u8) void {
        const len = @min(summary.len, self.progress_summary_buf.len);
        @memcpy(self.progress_summary_buf[0..len], summary[0..len]);
        self.progress_summary_len = len;
    }

    /// Clear progress summary (call at start of each turn).
    pub fn clearProgress(self: *PlanState) void {
        self.progress_summary_len = 0;
    }

    /// Reset all turn-scoped plan state. Called at the start of each turn in executeTurnWorker.
    pub fn resetTurn(self: *PlanState) void {
        self.loop_plan_retries = 0;
        self.plan_execution_pending = false;
        self.plan_watchdog_retries = 0;
        self.clearPlan();
        self.clearProgress();
    }

    // -----------------------------------------------------------------------
    // Plan detection in response text
    // -----------------------------------------------------------------------

    /// Try to detect and activate a structured plan from LLM response text.
    /// Called for each text block in the response.
    pub fn tryDetectPlanInResponse(self: *PlanState, text: []const u8) void {
        if (self.enable_structured_planning) {
            // RFC-019: Canonical structured plan parser
            if (self.current_plan == null) {
                if (plan_parser.extractStructuredPlan(text, self.alloc) catch null) |plan| {
                    if (plan.stepCount() > 0) {
                        self.setStructuredPlan(plan);
                        if (!utils.isSubagent()) {
                            main.stderrPrint("[agent] Structured plan detected: {d} steps\n", .{plan.stepCount()});
                        }
                    } else {
                        var mut_plan = plan;
                        mut_plan.deinit(self.alloc);
                    }
                }
            }
        } else {
            // Legacy plan detection fallback only when structured planning is disabled
            if (detectPlanInText(text)) |plan_summary| {
                self.setPlan(plan_summary);
            }
        }
    }

    /// Try to restore a plan from the persistent PlanStore for the given user request.
    pub fn tryRestoreFromStore(self: *PlanState, user_text: []const u8) void {
        if (self.enable_structured_planning and self.plan_store != null) {
            const req_hash = std.hash.Fnv1a_64.hash(user_text);
            if (self.plan_store.?.restore(req_hash) catch null) |plan| {
                self.setStructuredPlan(plan);
                if (self.current_plan.?.findActiveStepIndex()) |idx| {
                    self.plan_ctx.current_step_idx = idx;
                }
                if (!utils.isSubagent()) {
                    main.stderrPrint("[agent] Plan restored from store: {d} steps\n", .{self.current_plan.?.stepCount()});
                }
            }
        }
    }

    /// Get the tool_hint from the current active plan step, if any.
    pub fn getToolHint(self: *const PlanState) ?[]const u8 {
        if (self.enable_structured_planning and self.current_plan != null) {
            if (self.plan_ctx.current_step_idx < self.current_plan.?.stepCount()) {
                return self.current_plan.?.steps.items[self.plan_ctx.current_step_idx].tool_hint;
            }
        }
        return null;
    }

    // -----------------------------------------------------------------------
    // Progress block builder
    // -----------------------------------------------------------------------

    /// Build the progress checkpoint text block to inject before each act.
    /// Returns owned slice on success, null if no progress to report.
    pub fn buildProgressBlock(self: *PlanState, alloc: Allocator, act_id: usize, config: *const config_mod.Config) ?[]u8 {
        if (self.progress_summary_len == 0 or act_id <= 1) return null;

        var progress_buf = utils.BufWriter.init(alloc);
        errdefer progress_buf.deinit();

        progress_buf.writeAll("[Progress Checkpoint]\n") catch return null;
        progress_buf.print("Previous act ({d}) completed with:\n", .{act_id - 1}) catch return null;

        if (self.enable_structured_planning and self.current_plan != null) {
            const plan = &self.current_plan.?;
            const progress_msg = plan_executor.generateProgressSummary(plan, &self.plan_ctx, alloc) catch return null;
            defer alloc.free(progress_msg);
            progress_buf.writeAll(progress_msg) catch return null;
            progress_buf.writeAll("\n") catch return null;

            if (config.plan_drift_detection and self.plan_drift_score > 0.5) {
                progress_buf.writeAll("⚠️ Drift detected: execution diverged from planned step.\n") catch return null;
                progress_buf.writeAll("Please realign with the active step or update your plan.\n\n") catch return null;
            }
        } else if (self.plan_active and self.plan_summary_len > 0) {
            // Legacy: show plan summary
            progress_buf.writeAll("📋 Plan Status:\n") catch return null;
            progress_buf.writeAll(self.plan_summary_buf[0..self.plan_summary_len]) catch return null;
            progress_buf.writeAll("\n\n") catch return null;
        }

        // Show tools used in previous act
        progress_buf.writeAll("Tools executed:\n") catch return null;
        progress_buf.writeAll(self.progress_summary_buf[0..self.progress_summary_len]) catch return null;
        progress_buf.writeAll("\n\n") catch return null;

        // Directive: ask model to continue with next step
        progress_buf.writeAll("Next step directive: Proceed with executing the active step using the ReAct cycle (Thought -> Action in ```js block). State your rationale, then execute the tool.") catch return null;

        return progress_buf.toOwnedSlice() catch null;
    }

    // -----------------------------------------------------------------------
    // Plan watchdog (end_turn enforcement)
    // -----------------------------------------------------------------------

    /// Check plan watchdog at end_turn. Returns the action the agent loop should take.
    /// If continue_loop, the caller should inject `getWatchdogDirective()` into history.
    pub fn handleEndTurnWatchdog(self: *PlanState, current_user_request: ?[]const u8) WatchdogAction {
        if ((self.plan_active or self.plan_execution_pending) and !isPlanOnlyRequest(current_user_request)) {
            self.plan_watchdog_retries += 1;
            const watchdog_max = 2;
            if (self.plan_watchdog_retries >= watchdog_max) {
                // Cap reached — clear plan and exit
                main.stderrPrint(
                    "\n\x1b[33m[watchdog] ⚠️ Plan Watchdog stopping after {d} consecutive directive injections without tool execution.\x1b[0m\n",
                    .{watchdog_max},
                );
                self.clearPlan();
                self.plan_execution_pending = false;
                self.plan_watchdog_retries = 0;
                return .exit_loop;
            }
            main.stderrPrint(
                "\n\x1b[33m[watchdog] ⚠️ Model emitted text without tool execution while an implementation plan is active. Commanding immediate execution of Step 1...\x1b[0m\n",
                .{},
            );
            return .continue_loop;
        }
        return .no_action;
    }

    /// Build the watchdog directive text to inject into history when handleEndTurnWatchdog returns continue_loop.
    pub fn getWatchdogDirective(self: *PlanState, alloc: Allocator) ?[]u8 {
        var dir_buf = utils.BufWriter.init(alloc);
        dir_buf.print(
            "[Plan Watchdog Directive]: You formulated an active implementation plan ('{s}') but ended your turn with descriptive text only without executing any tools. You MUST now proceed directly to executing Step 1 using tools (e.g. file_edit, bash, etc.). Do not return monologue or explanation without tool actions.",
            .{self.getPlanSummary()},
        ) catch {
            dir_buf.deinit();
            return null;
        };
        self.plan_execution_pending = false;
        return dir_buf.toOwnedSlice() catch null;
    }

    // -----------------------------------------------------------------------
    // CodeAct plan completion check
    // -----------------------------------------------------------------------

    /// Check if a mutating CodeAct script indicates plan completion.
    pub fn checkCodeActPlanCompletion(self: *PlanState, js_code: []const u8, current_user_request: ?[]const u8) void {
        if (self.plan_active and !isPlanOnlyRequest(current_user_request)) {
            if (std.mem.indexOf(u8, js_code, "file_edit") != null or
                std.mem.indexOf(u8, js_code, "file_write") != null or
                std.mem.indexOf(u8, js_code, "write") != null)
            {
                self.clearPlan();
            }
        }
    }

    // -----------------------------------------------------------------------
    // Static helper functions (migrated from AgentLoop)
    // -----------------------------------------------------------------------

    /// Returns true if any step marker ("1.", "1)", "Step 1", "Bước 1",
    /// or a checklist item "- [ ]") appears within the first few lines
    /// starting at `from_offset`. Guards legacy plan detection against
    /// false positives where a heading merely *mentions* "plan" (e.g.
    /// "## Fix plan display") without an actual step list.
    fn hasStepMarkerNearby(text: []const u8, from_offset: usize) bool {
        var it = std.mem.splitScalar(u8, text[from_offset..], '\n');
        var scanned: usize = 0;
        while (it.next()) |raw_line| {
            if (scanned >= 5) break;
            scanned += 1;
            const line = std.mem.trim(u8, raw_line, " \t\r*-#`_");
            if (line.len == 0) continue;
            if (std.mem.startsWith(u8, line, "1.") or std.mem.startsWith(u8, line, "1)") or
                std.ascii.startsWithIgnoreCase(line, "step 1") or
                std.ascii.startsWithIgnoreCase(line, "bước 1") or
                std.mem.startsWith(u8, line, "[ ]"))
            {
                return true;
            }
        }
        return false;
    }

    pub fn detectPlanInText(text: []const u8) ?[]const u8 {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;

            // 1. Markdown heading (# ... ######) containing plan keyword
            if (trimmed[0] == '#') {
                var i: usize = 0;
                while (i < trimmed.len and trimmed[i] == '#') : (i += 1) {}
                if (i <= 6 and i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t')) {
                    const title = std.mem.trim(u8, trimmed[i..], " \t#*`_");
                    if (plan_parser.isPlanHeaderKeyword(title)) {
                        const start = @intFromPtr(trimmed.ptr) - @intFromPtr(text.ptr);
                        if (!hasStepMarkerNearby(text, start)) continue;
                        const end = @min(text.len, start + 120);
                        return std.mem.trim(u8, text[start..end], " \t\r\n`#*");
                    }
                }
                continue;
            }

            // 2. Line label ending with ':' or bold label: "Plan:", "**Plan:**", "Implementation Plan:", "Kế hoạch:"
            const stripped = std.mem.trim(u8, trimmed, " \t*_`");
            if (stripped.len > 0 and (std.mem.endsWith(u8, stripped, ":") or std.mem.startsWith(u8, stripped, "**"))) {
                const title = std.mem.trim(u8, stripped, " \t:*_`");
                if (plan_parser.isPlanHeaderKeyword(title) or
                    std.ascii.startsWithIgnoreCase(title, "step 1") or
                    std.ascii.startsWithIgnoreCase(title, "bước 1"))
                {
                    const start = @intFromPtr(trimmed.ptr) - @intFromPtr(text.ptr);
                    if (!hasStepMarkerNearby(text, start)) continue;
                    const end = @min(text.len, start + 120);
                    return std.mem.trim(u8, text[start..end], " \t\r\n`#*");
                }
            }

            // 3. Explicit action commitment prefix: "I will implement" / "Tôi sẽ implement"
            if (std.ascii.indexOfIgnoreCase(trimmed, "i will implement") != null or
                std.ascii.indexOfIgnoreCase(trimmed, "tôi sẽ implement") != null or
                std.ascii.indexOfIgnoreCase(trimmed, "implementation plan") != null)
            {
                const start = @intFromPtr(trimmed.ptr) - @intFromPtr(text.ptr);
                const end = @min(text.len, start + 120);
                return std.mem.trim(u8, text[start..end], " \t\r\n`#*");
            }
        }
        return null;
    }

    test "agent - plan watchdog false-positive guard" {
        // Heading merely mentioning "plan" without step markers must NOT activate
        // the legacy plan watchdog (previously caused infinite directive loops).
        const false_positive = detectPlanInText(
            "## Hoàn tất: Fix plan không hiển thị trong REPL\nĐã commit và push thay đổi.\n",
        );
        try std.testing.expect(false_positive == null);

        // A real plan header followed by a numbered step list must still activate.
        const true_positive = detectPlanInText(
            "## Plan\n1. Read the file\n2. Apply the fix\n",
        );
        try std.testing.expect(true_positive != null);
    }

    pub fn isPlanOnlyRequest(user_text_opt: ?[]const u8) bool {
        const text = user_text_opt orelse return false;
        // Check for explicit plan-only intent or negation of file edits/mutations
        if (std.ascii.indexOfIgnoreCase(text, "only plan") != null or
            std.ascii.indexOfIgnoreCase(text, "just plan") != null or
            std.ascii.indexOfIgnoreCase(text, "plan only") != null or
            std.ascii.indexOfIgnoreCase(text, "do not edit") != null or
            std.ascii.indexOfIgnoreCase(text, "don't edit") != null or
            std.ascii.indexOfIgnoreCase(text, "do not modify") != null or
            std.ascii.indexOfIgnoreCase(text, "don't modify") != null or
            std.ascii.indexOfIgnoreCase(text, "chỉ lên kế hoạch") != null or
            std.ascii.indexOfIgnoreCase(text, "chỉ lập kế hoạch") != null or
            std.ascii.indexOfIgnoreCase(text, "không sửa") != null or
            std.ascii.indexOfIgnoreCase(text, "không edit") != null)
        {
            return true;
        }
        return false;
    }

};
