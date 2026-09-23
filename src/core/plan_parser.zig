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
const registry = @import("../tooling/registry.zig");

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
fn parseJsonStep(alloc: Allocator, step_val: std.json.Value, fallback_id: u64) !?PlanStep {
    // PSEUDOCODE: Extract step fields (id, description, dependencies, tool_hint, status) from JSON object.
    const step_obj = switch (step_val) {
        .object => |o| o,
        else => return null,
    };

    const desc_val = step_obj.get("description") orelse return null;
    const desc = jsonStr(desc_val);
    if (desc.len == 0) return null;

    var deps_list = std.ArrayListUnmanaged(u64).empty;
    defer deps_list.deinit(alloc);
    if (step_obj.get("dependencies")) |dv| {
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
        else => fallback_id,
    } else fallback_id;

    var step = try PlanStep.initWithId(alloc, step_id, desc, deps_list.items, tool_hint);
    errdefer step.deinit(alloc);

    if (step_obj.get("status")) |st_val| {
        if (st_val == .string) {
            step.status = plan_mod.parseStepStatus(st_val.string);
        }
    }
    return step;
}

pub fn parsePlanJson(text: []const u8, alloc: Allocator) !Plan {
    // PSEUDOCODE:
    // 1. Extract JSON block or use raw text.
    // 2. Parse JSON tree and extract task description.
    // 3. Initialize Plan and parse steps array via parseJsonStep.
    // 4. Validate non-empty plan.
    const json_text = extractJsonBlock(text) orelse text;

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidPlanFormat,
    };

    const task_val = obj.get("task") orelse obj.get("task_description") orelse return error.MissingTaskField;
    const task = jsonStr(task_val);
    if (task.len == 0) return error.MissingTaskField;

    var plan = try Plan.init(alloc, task, std.hash.Fnv1a_64.hash(task));
    errdefer plan.deinit(alloc);

    const steps_val = obj.get("steps") orelse return error.MissingStepsField;
    const steps_arr = switch (steps_val) {
        .array => |a| a.items,
        else => return error.InvalidStepsFormat,
    };

    for (steps_arr) |step_val| {
        if (try parseJsonStep(alloc, step_val, @as(u64, @intCast(plan.stepCount() + 1)))) |step| {
            try plan.addStepOwned(alloc, step);
        }
    }

    if (plan.stepCount() == 0) {
        return error.EmptyPlan;
    }

    return plan;
}

// ---------------------------------------------------------------------------
// Markdown Plan Parser (Fallback)
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Markdown Plan Parser (Structural Header & State Machine)
// ---------------------------------------------------------------------------

// PSEUDOCODE:
// 1. Scan line by line through Markdown text.
// 2. State machine tracks active plan section:
//    - Enters plan section when line is a plan heading (e.g. `## Plan`, `# Implementation Plan`, `**Plan:**`).
//    - Exits plan section when a subsequent non-plan heading (`## Summary`, `## Notes`) is hit.
//    - Self-identifying checklist items (`- [ ]`, `* [ ]`) always qualify as plan steps.
// 3. Inside plan section, extract numbered steps ("1. ", "1) ", "Step 1: ") or checklist items.
// 4. Extract paren tool hints using canonical registry.isBuiltinTool() and dependencies cleanly.
// 5. Return Plan if stepCount > 0, else null.

/// Checks whether a heading or title denotes a plan section.
/// Matches "plan" (with word boundary) or Vietnamese "kế hoạch" / "ke hoach".
pub fn isPlanHeaderKeyword(title: []const u8) bool {
    if (utils.hasWordIgnoreCase(title, "plan")) return true;
    if (std.ascii.indexOfIgnoreCase(title, "kế hoạch") != null or
        std.ascii.indexOfIgnoreCase(title, "ke hoach") != null)
    {
        return true;
    }
    return false;
}

/// Checks whether a line is a Markdown heading (# ... ######).
fn isMarkdownHeading(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] != '#') return false;
    var i: usize = 0;
    while (i < trimmed.len and trimmed[i] == '#') : (i += 1) {}
    return i <= 6 and i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t');
}

/// Returns the title text of a line if it is a Plan Section Header.
/// Matches markdown headings containing a plan keyword (e.g. `## Plan`, `# Implementation Plan`),
/// or bold/plain labels (e.g. `**Plan:**`, `Plan:`, `Implementation Plan:`).
fn extractPlanHeaderTitle(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return null;

    // 1. Markdown heading (# ... ######)
    if (trimmed[0] == '#') {
        var i: usize = 0;
        while (i < trimmed.len and trimmed[i] == '#') : (i += 1) {}
        if (i <= 6 and i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t')) {
            const title = std.mem.trim(u8, trimmed[i..], " \t#*`_");
            if (isPlanHeaderKeyword(title)) {
                return title;
            }
        }
        return null;
    }

    // 2. Bold or plain line label: `**Plan:**`, `Plan:`, `Implementation Plan:`
    const stripped = std.mem.trim(u8, trimmed, " \t*_`");
    if (stripped.len > 0 and (std.mem.endsWith(u8, stripped, ":") or std.mem.startsWith(u8, stripped, "**"))) {
        const title = std.mem.trim(u8, stripped, " \t:*_`");
        if (isPlanHeaderKeyword(title)) {
            return title;
        }
    }

    return null;
}

const StepPrefixResult = struct {
    is_checklist: bool,
    is_completed: bool,
    desc_start: usize,
};

/// Parses step numbering/prefix: checklist, "{d}.", "{d})", "Step {d}:", "Bước {d}:"
fn parseStepPrefix(line: []const u8, step_id: u64) ?StepPrefixResult {
    // Checklist items
    if (std.mem.startsWith(u8, line, "- [ ] ") or std.mem.startsWith(u8, line, "* [ ] ")) {
        return .{ .is_checklist = true, .is_completed = false, .desc_start = 6 };
    }
    if (std.mem.startsWith(u8, line, "- [x] ") or std.mem.startsWith(u8, line, "* [x] ") or
        std.mem.startsWith(u8, line, "- [X] ") or std.mem.startsWith(u8, line, "* [X] "))
    {
        return .{ .is_checklist = true, .is_completed = true, .desc_start = 6 };
    }

    var num_buf: [32]u8 = undefined;

    // "{d}."
    const p1 = std.fmt.bufPrint(&num_buf, "{d}.", .{step_id}) catch "";
    if (p1.len > 0 and std.mem.startsWith(u8, line, p1)) {
        var pos = p1.len;
        while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) : (pos += 1) {}
        return .{ .is_checklist = false, .is_completed = false, .desc_start = pos };
    }

    // "{d})"
    const p2 = std.fmt.bufPrint(&num_buf, "{d})", .{step_id}) catch "";
    if (p2.len > 0 and std.mem.startsWith(u8, line, p2)) {
        var pos = p2.len;
        while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) : (pos += 1) {}
        return .{ .is_checklist = false, .is_completed = false, .desc_start = pos };
    }

    // "Step {d}:" or "Step {d}." or "Step {d} -"
    const p3 = std.fmt.bufPrint(&num_buf, "Step {d}", .{step_id}) catch "";
    if (p3.len > 0 and std.ascii.startsWithIgnoreCase(line, p3)) {
        var pos = p3.len;
        if (pos < line.len and (line[pos] == ':' or line[pos] == '.' or line[pos] == '-')) pos += 1;
        while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) : (pos += 1) {}
        return .{ .is_checklist = false, .is_completed = false, .desc_start = pos };
    }

    return null;
}

/// Parses parenthesized or bracketed metadata in a step description to extract tool hint and dependencies.
fn extractMetadataFromDesc(
    alloc: Allocator,
    raw_desc: []const u8,
    deps_list: *std.ArrayListUnmanaged(u64),
) ?[]const u8 {
    var tool_hint: ?[]const u8 = null;

    var search_start: usize = 0;
    while (search_start < raw_desc.len) {
        const open_idx = std.mem.indexOfAnyPos(u8, raw_desc, search_start, "([") orelse break;
        const close_char: u8 = if (raw_desc[open_idx] == '(') ')' else ']';
        const close_idx = std.mem.indexOfScalarPos(u8, raw_desc, open_idx + 1, close_char) orelse break;

        const content = raw_desc[open_idx + 1 .. close_idx];
        var it = std.mem.splitScalar(u8, content, ',');
        while (it.next()) |token| {
            const trimmed = std.mem.trim(u8, token, " \t");
            if (trimmed.len == 0) continue;

            // Check dependency keywords
            if (parseDependencyIds(trimmed, alloc, deps_list)) {
                continue;
            }

            // Check if token matches a recognized tool in registry
            if (tool_hint == null and registry.isBuiltinTool(trimmed)) {
                tool_hint = registry.normalizeToolName(trimmed);
            }
        }
        search_start = close_idx + 1;
    }

    return tool_hint;
}

fn parseDependencyIds(token: []const u8, alloc: Allocator, deps_list: *std.ArrayListUnmanaged(u64)) bool {
    const dep_keywords = [_][]const u8{
        "depends on", "depend on", "dependencies:", "dependency:", "deps:", "dep:", "after",
    };
    for (dep_keywords) |kw| {
        if (std.ascii.indexOfIgnoreCase(token, kw)) |kw_idx| {
            const remainder = token[kw_idx + kw.len ..];
            const trimmed = std.mem.trim(u8, remainder, " :[]()");
            var it = std.mem.splitScalar(u8, trimmed, ' ');
            while (it.next()) |part| {
                const clean = std.mem.trim(u8, part, " ,;#");
                if (std.fmt.parseInt(u64, clean, 10)) |id| {
                    deps_list.append(alloc, id) catch {};
                } else |_| {}
            }
            return true;
        }
    }
    return false;
}

fn parseMarkdownStep(alloc: Allocator, trimmed: []const u8, step_id: u64, in_plan_section: *bool) !?PlanStep {
    // PSEUDOCODE: Parse step prefix, dependencies, and metadata from a markdown list line.
    const res = parseStepPrefix(trimmed, step_id) orelse return null;
    if (!in_plan_section.* and !res.is_checklist) return null;

    if (res.is_checklist) {
        in_plan_section.* = true;
    }

    const raw_desc = std.mem.trim(u8, trimmed[res.desc_start..], " ");
    if (raw_desc.len == 0) return null;

    var deps_list = std.ArrayListUnmanaged(u64).empty;
    defer deps_list.deinit(alloc);

    const tool_hint = extractMetadataFromDesc(alloc, raw_desc, &deps_list);
    var step = try PlanStep.initWithId(alloc, step_id, raw_desc, deps_list.items, tool_hint);
    errdefer step.deinit(alloc);

    if (res.is_completed) {
        step.status = .completed;
    }
    return step;
}

pub fn parsePlanMarkdown(text: []const u8, alloc: Allocator) !?Plan {
    // PSEUDOCODE:
    // 1. Iterate through lines to locate Plan headings or checklists.
    // 2. Terminate plan section when non-plan heading is encountered.
    // 3. Delegate step parsing to parseMarkdownStep.
    var lines = std.mem.splitScalar(u8, text, '\n');
    var in_plan_section = false;
    var plan = try Plan.init(alloc, "Extracted from Markdown", std.hash.Fnv1a_64.hash(text));
    errdefer plan.deinit(alloc);

    var step_id: u64 = 1;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;

        if (extractPlanHeaderTitle(trimmed)) |title| {
            in_plan_section = true;
            if (std.mem.eql(u8, plan.task_description, "Extracted from Markdown") and title.len > 0) {
                alloc.free(plan.task_description);
                plan.task_description = try alloc.dupe(u8, title);
            }
            continue;
        }

        if (isMarkdownHeading(trimmed)) {
            if (in_plan_section and plan.stepCount() > 0) break;
            in_plan_section = false;
            continue;
        }

        if (try parseMarkdownStep(alloc, trimmed, step_id, &in_plan_section)) |step| {
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

test "parsePlanMarkdown - bare numbered list without plan marker returns null" {
    const alloc = std.testing.allocator;

    const input =
        "Here are two reasons why this happened:\n" ++
        "1. The bug was in connect.py\n" ++
        "2. The file extension check failed\n";

    var plan_opt = try parsePlanMarkdown(input, alloc);
    defer if (plan_opt) |*p| p.deinit(alloc);

    try std.testing.expect(plan_opt == null);
}

test "parsePlanMarkdown - explanation heading does not trigger plan" {
    const alloc = std.testing.allocator;

    const input =
        "## Explanation\n" ++
        "1. The function checks args\n" ++
        "2. It returns early\n";

    var plan_opt = try parsePlanMarkdown(input, alloc);
    defer if (plan_opt) |*p| p.deinit(alloc);

    try std.testing.expect(plan_opt == null);
}

test "parsePlanMarkdown - section termination on subsequent non-plan heading" {
    const alloc = std.testing.allocator;

    const input =
        "## Action Plan\n" ++
        "1. Step one (bash)\n" ++
        "2. Step two (file_edit, depends on 1)\n" ++
        "## Summary of Changes\n" ++
        "1. Point one that is not a plan step\n" ++
        "2. Point two that is not a plan step\n";

    var plan_opt = try parsePlanMarkdown(input, alloc);
    defer if (plan_opt) |*p| p.deinit(alloc);

    try std.testing.expect(plan_opt != null);
    try std.testing.expectEqual(2, plan_opt.?.stepCount());
}

test "parsePlanMarkdown - Step N prefix and bracketed metadata" {
    const alloc = std.testing.allocator;

    const input =
        "### Plan\n" ++
        "Step 1: Inspect module structure [glob]\n" ++
        "Step 2: Apply patch [file_edit, dep: 1]\n";

    var plan_opt = try parsePlanMarkdown(input, alloc);
    defer if (plan_opt) |*p| p.deinit(alloc);

    try std.testing.expect(plan_opt != null);
    try std.testing.expectEqual(2, plan_opt.?.stepCount());
    try std.testing.expectEqualStrings("glob", plan_opt.?.steps.items[0].tool_hint.?);
    try std.testing.expectEqualStrings("file_edit", plan_opt.?.steps.items[1].tool_hint.?);
    try std.testing.expectEqual(1, plan_opt.?.steps.items[1].dependencies.len);
    try std.testing.expectEqual(@as(u64, 1), plan_opt.?.steps.items[1].dependencies[0]);
}

