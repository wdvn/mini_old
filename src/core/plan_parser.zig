//! plan_parser.zig — Extract structured plans from LLM output (RFC-019)
//!
//! Parses JSON or Markdown formatted plans from LLM responses.
//! Supports both structured JSON and fallback Markdown formats (numbered lists, task lists).

const std = @import("std");
const Allocator = std.mem.Allocator;
const plan_mod = @import("plan.zig");
const Plan = plan_mod.Plan;
const PlanStep = plan_mod.PlanStep;
const utils = @import("utils.zig");

// ---------------------------------------------------------------------------
// JSON Plan Parser
// ---------------------------------------------------------------------------

// PSEUDOCODE:
// 1. Extract JSON text from code block if fenced (```json ... ```)
// 2. Parse using std.json.parseFromSlice(std.json.Value)
// 3. Extract task description and request hash
// 4. Extract steps array and initialize PlanStep for each entry
// 5. Add steps to Plan using addStepOwned and return plan

/// Expected JSON structure:
/// {
///   "task": "Implement feature X",
///   "steps": [
///     {"id": 1, "description": "Read config", "dependencies": [], "tool_hint": "file_read"},
///     {"id": 2, "description": "Write code", "dependencies": [1], "tool_hint": "file_edit"}
///   ]
/// }
pub fn parsePlanJson(text: []const u8, alloc: Allocator) !Plan {
    const json_text = extractJsonBlock(text) orelse text;

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidPlanFormat,
    };

    // Extract task description
    const task_val = obj.get("task") orelse obj.get("task_description") orelse return error.MissingTaskField;
    const task = jsonStr(task_val);
    if (task.len == 0) return error.MissingTaskField;

    // Initialize plan
    var plan = try Plan.init(alloc, task, std.hash.Fnv1a_64.hash(task));
    errdefer plan.deinit(alloc);

    // Extract steps array
    const steps_val = obj.get("steps") orelse return error.MissingStepsField;
    const steps_arr = switch (steps_val) {
        .array => |a| a.items,
        else => return error.InvalidStepsFormat,
    };

    // Parse each step
    for (steps_arr) |step_val| {
        const step_obj = switch (step_val) {
            .object => |o| o,
            else => continue,
        };

        const desc_val = step_obj.get("description") orelse continue;
        const desc = jsonStr(desc_val);
        if (desc.len == 0) continue;

        const deps_val = step_obj.get("dependencies");
        var deps_list = std.ArrayListUnmanaged(u64).empty;
        defer deps_list.deinit(alloc);

        if (deps_val) |dv| {
            if (dv == .array) {
                for (dv.array.items) |dep_val| {
                    if (dep_val == .integer and dep_val.integer >= 0) {
                        try deps_list.append(alloc, @as(u64, @intCast(dep_val.integer)));
                    }
                }
            }
        }

        const tool_hint: ?[]const u8 = if (step_obj.get("tool_hint")) |th| switch (th) {
            .string => |s| s,
            else => null,
        } else null;

        const step_id: u64 = if (step_obj.get("id")) |sid| switch (sid) {
            .integer => |i| @as(u64, @intCast(if (i >= 0) i else 1)),
            else => @as(u64, @intCast(plan.stepCount() + 1)),
        } else @as(u64, @intCast(plan.stepCount() + 1));

        var step = try PlanStep.initWithId(alloc, step_id, desc, deps_list.items, tool_hint);
        errdefer step.deinit(alloc);

        if (step_obj.get("status")) |st_val| {
            if (st_val == .string) {
                step.status = plan_mod.parseStepStatus(st_val.string);
            }
        }

        try plan.addStepOwned(alloc, step);
    }

    if (plan.stepCount() == 0) {
        return error.EmptyPlan;
    }

    return plan;
}

// ---------------------------------------------------------------------------
// Markdown Plan Parser (Fallback)
// ---------------------------------------------------------------------------

// PSEUDOCODE:
// 1. Locate plan section marker ("## Plan", "# Plan", "Plan:", etc.)
// 2. Iterate lines in section using SplitIterator
// 3. Match numbered items ("1. ", "1) ") or markdown task items ("- [ ]", "* [ ]")
// 4. Parse step description, tool hint in parentheses (e.g. "(bash)", "(file_read)")
// 5. Parse dependencies if mentioned (e.g. "depends on 1" or "[depends on 1, 2]")
// 6. Return plan with parsed steps, or null if no valid steps found

pub fn parsePlanMarkdown(text: []const u8, alloc: Allocator) !?Plan {
    const markers = [_][]const u8{
        "## Plan",
        "# Plan",
        "## Implementation Plan",
        "# Implementation Plan",
        "Plan:",
        "Kế hoạch:",
    };

    var start_idx: ?usize = null;
    for (markers) |m| {
        if (std.mem.indexOf(u8, text, m)) |idx| {
            start_idx = idx;
            break;
        }
    }

    const section = if (start_idx) |idx| text[idx..] else text;
    var lines = std.mem.splitScalar(u8, section, '\n');

    var plan = try Plan.init(alloc, "Extracted from Markdown", std.hash.Fnv1a_64.hash(section));
    errdefer plan.deinit(alloc);

    var step_id: u64 = 1;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;

        var num_buf1: [16]u8 = undefined;
        const p1 = std.fmt.bufPrint(&num_buf1, "{d}.", .{step_id}) catch "";
        var num_buf2: [16]u8 = undefined;
        const p2 = std.fmt.bufPrint(&num_buf2, "{d})", .{step_id}) catch "";

        var is_step = false;
        var desc_start: usize = 0;

        if (p1.len > 0 and std.mem.startsWith(u8, trimmed, p1)) {
            is_step = true;
            desc_start = p1.len;
        } else if (p2.len > 0 and std.mem.startsWith(u8, trimmed, p2)) {
            is_step = true;
            desc_start = p2.len;
        } else if (std.mem.startsWith(u8, trimmed, "- [ ] ") or std.mem.startsWith(u8, trimmed, "* [ ] ")) {
            is_step = true;
            desc_start = 6;
        } else if (std.mem.startsWith(u8, trimmed, "- [x] ") or std.mem.startsWith(u8, trimmed, "* [x] ")) {
            is_step = true;
            desc_start = 6;
        }

        if (is_step) {
            const raw_desc = std.mem.trim(u8, trimmed[desc_start..], " ");
            if (raw_desc.len == 0) continue;

            // Check for tool hint in parentheses: "(file_read)" or "(file_edit, depends on 1)"
            var tool_hint: ?[]const u8 = null;
            if (std.mem.indexOf(u8, raw_desc, "(")) |pi| {
                if (std.mem.indexOf(u8, raw_desc[pi..], ")")) |close_rel| {
                    var hint = raw_desc[pi + 1 .. pi + close_rel];
                    if (std.mem.indexOf(u8, hint, ",")) |comma_idx| {
                        hint = std.mem.trim(u8, hint[0..comma_idx], " ");
                    }
                    if (std.mem.startsWith(u8, hint, "file_") or
                        std.mem.startsWith(u8, hint, "bash") or
                        std.mem.startsWith(u8, hint, "grep") or
                        std.mem.startsWith(u8, hint, "glob") or
                        std.mem.startsWith(u8, hint, "http"))
                    {
                        tool_hint = hint;
                    }
                }
            }

            // Check for dependencies: "(depends on 1)" or "[depends on 1, 2]"
            var deps_list = std.ArrayListUnmanaged(u64).empty;
            defer deps_list.deinit(alloc);

            const dep_marker = "depends on ";
            if (std.mem.indexOf(u8, raw_desc, dep_marker)) |d_idx| {
                const after_marker = raw_desc[d_idx + dep_marker.len ..];
                const end_pos = std.mem.indexOfAny(u8, after_marker, "])\n") orelse after_marker.len;
                const dep_ids_str = std.mem.trim(u8, after_marker[0..end_pos], " []");

                var it = std.mem.splitScalar(u8, dep_ids_str, ',');
                while (it.next()) |id_str| {
                    const trimmed_id = std.mem.trim(u8, id_str, " ");
                    if (std.fmt.parseInt(u64, trimmed_id, 10)) |num| {
                        try deps_list.append(alloc, num);
                    } else |_| {}
                }
            }

            var step = try PlanStep.initWithId(alloc, step_id, raw_desc, deps_list.items, tool_hint);
            errdefer step.deinit(alloc);

            if (std.mem.startsWith(u8, trimmed, "- [x] ") or std.mem.startsWith(u8, trimmed, "* [x] ")) {
                step.status = .completed;
            }

            try plan.addStepOwned(alloc, step);
            step_id += 1;
        }
    }

    if (plan.stepCount() == 0) {
        plan.deinit(alloc);
        return null;
    }

    return plan;
}

// ---------------------------------------------------------------------------
// Main Entry Point
// ---------------------------------------------------------------------------

/// Extract structured plan from LLM output text.
/// Tries JSON first, falls back to Markdown parsing.
/// Returns null if no plan found.
pub fn extractStructuredPlan(text: []const u8, alloc: Allocator) !?Plan {
    // 1. Try fenced JSON first
    if (std.mem.indexOf(u8, text, "```json") != null) {
        if (parsePlanJson(text, alloc)) |plan| {
            return plan;
        } else |_| {}
    }

    // 2. Try raw JSON object
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "{") and std.mem.endsWith(u8, trimmed, "}")) {
        if (parsePlanJson(trimmed, alloc)) |plan| {
            return plan;
        } else |_| {}
    }

    // 3. Fallback to Markdown
    return parsePlanMarkdown(text, alloc);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Extract JSON block from text (handles ```json ... ``` wrappers).
fn extractJsonBlock(text: []const u8) ?[]const u8 {
    const start_marker = "```json";
    const end_marker = "```";

    const start = std.mem.indexOf(u8, text, start_marker) orelse return null;
    const after_start = start + start_marker.len;

    var content_start = after_start;
    if (content_start < text.len and text[content_start] == '\r') content_start += 1;
    if (content_start < text.len and text[content_start] == '\n') content_start += 1;

    const end = std.mem.indexOf(u8, text[content_start..], end_marker) orelse return null;
    return text[content_start .. content_start + end];
}

/// Extract string value from JSON object field.
fn jsonStr(v: std.json.Value) []const u8 {
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parsePlanJson - basic structure" {
    const alloc = std.testing.allocator;

    const input = "{\n" ++
        "  \"task\": \"Implement pagination\",\n" ++
        "  \"steps\": [\n" ++
        "    {\"id\": 1, \"description\": \"Read UserList.tsx\", \"dependencies\": [], \"tool_hint\": \"file_read\"},\n" ++
        "    {\"id\": 2, \"description\": \"Add pagination state\", \"dependencies\": [1], \"tool_hint\": \"file_edit\"}\n" ++
        "  ]\n" ++
        "}";

    var plan = try parsePlanJson(input, alloc);
    defer plan.deinit(alloc);

    try std.testing.expectEqual(2, plan.stepCount());
    try std.testing.expectEqualStrings("Implement pagination", plan.task_description);
    try std.testing.expectEqualStrings("Read UserList.tsx", plan.steps.items[0].description);
    try std.testing.expectEqualStrings("file_read", plan.steps.items[0].tool_hint.?);
}

test "parsePlanJson - missing fields returns error" {
    const alloc = std.testing.allocator;
    const input = "{\"task\": \"test\"}"; // Missing steps
    try std.testing.expectError(error.MissingStepsField, parsePlanJson(input, alloc));
}

test "parsePlanMarkdown - basic parsing" {
    const alloc = std.testing.allocator;

    const input =
        "## Plan\n" ++
        "1. Read config file (file_read)\n" ++
        "2. Implement feature (depends on 1, file_edit)\n" ++
        "3. Run tests (depends on 2, bash)\n";

    var plan_opt = try parsePlanMarkdown(input, alloc);
    defer if (plan_opt) |*p| p.deinit(alloc);

    try std.testing.expect(plan_opt != null);
    try std.testing.expectEqual(3, plan_opt.?.stepCount());
}

test "extractStructuredPlan - JSON priority" {
    const alloc = std.testing.allocator;

    const input =
        "```json\n" ++
        "{\n" ++
        "  \"task\": \"Test\",\n" ++
        "  \"steps\": [\n" ++
        "    {\"description\": \"Step 1\", \"dependencies\": [], \"tool_hint\": \"bash\"}\n" ++
        "  ]\n" ++
        "}\n" ++
        "```";

    var plan = (try extractStructuredPlan(input, alloc)).?;
    defer plan.deinit(alloc);

    try std.testing.expectEqual(1, plan.stepCount());
}

test "extractStructuredPlan - markdown fallback" {
    const alloc = std.testing.allocator;

    const input =
        "Here's my plan:\n" ++
        "## Plan\n" ++
        "1. First step (file_read)\n" ++
        "2. Second step (file_edit)\n";

    var plan_opt = try extractStructuredPlan(input, alloc);
    defer if (plan_opt) |*p| p.deinit(alloc);

    try std.testing.expect(plan_opt != null);
    try std.testing.expectEqual(2, plan_opt.?.stepCount());
}
