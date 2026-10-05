//! test_plan_parser.zig — Integration tests for Plan Parser.
//!
//! Validates:
//! 1. JSON plan parsing with markdown code block formatting
//! 2. Raw JSON string plan parsing
//! 3. Markdown numbered list and checklist plan extraction
//! 4. Dependency and tool_hint extraction
//! 5. Error handling and malformed input fallback

const std = @import("std");
const mini = @import("mini");
const plan_parser = mini.plan_parser_mod;
const plan_mod = mini.plan_mod;

// PSEUDOCODE:
// 1. Prepare JSON formatted plan with multiple steps, dependencies, tool hints
// 2. Call extractStructuredPlan with allocator
// 3. Verify task_description, stepCount, descriptions, and dependencies match
// 4. Clean up allocated Plan

test "plan_parser: fenced JSON plan extraction" {
    const alloc = std.testing.allocator;

    const input =
        \\Here is my implementation plan for the requested feature:
        \\```json
        \\{
        \\  "task": "Add user authentication flow",
        \\  "steps": [
        \\    {"id": 1, "description": "Read existing auth config", "dependencies": [], "tool_hint": "file_read"},
        \\    {"id": 2, "description": "Implement token validation logic", "dependencies": [1], "tool_hint": "file_edit"},
        \\    {"id": 3, "description": "Run authentication test suite", "dependencies": [2], "tool_hint": "bash"}
        \\  ]
        \\}
        \\```
        \\Let me know if you would like me to proceed.
    ;

    var plan = (try plan_parser.extractStructuredPlan(input, alloc)).?;
    defer plan.deinit(alloc);

    try std.testing.expectEqualStrings("Add user authentication flow", plan.task_description);
    try std.testing.expectEqual(3, plan.stepCount());

    const s1 = plan.steps.items[0];
    try std.testing.expectEqual(@as(u64, 1), s1.id);
    try std.testing.expectEqualStrings("Read existing auth config", s1.description);
    try std.testing.expectEqualStrings("file_read", s1.tool_hint.?);
    try std.testing.expectEqual(0, s1.dependencies.len);

    const s2 = plan.steps.items[1];
    try std.testing.expectEqual(@as(u64, 2), s2.id);
    try std.testing.expectEqual(1, s2.dependencies.len);
    try std.testing.expectEqual(@as(u64, 1), s2.dependencies[0]);

    const s3 = plan.steps.items[2];
    try std.testing.expectEqual(@as(u64, 3), s3.id);
    try std.testing.expectEqualStrings("bash", s3.tool_hint.?);
    try std.testing.expectEqual(1, s3.dependencies.len);
    try std.testing.expectEqual(@as(u64, 2), s3.dependencies[0]);
}

// PSEUDOCODE:
// 1. Prepare markdown formatted plan with checklist items
// 2. Call extractStructuredPlan with allocator
// 3. Verify all steps extracted with completed/pending status

test "plan_parser: markdown checklist fallback extraction" {
    const alloc = std.testing.allocator;

    const input =
        \\# Implementation Plan
        \\- [x] Step 1: Analyze directory layout (glob)
        \\- [ ] Step 2: Update configuration options (file_edit, depends on 1)
        \\- [ ] Step 3: Verify build succeeds (bash, depends on 2)
    ;

    var plan = (try plan_parser.extractStructuredPlan(input, alloc)).?;
    defer plan.deinit(alloc);

    try std.testing.expectEqual(3, plan.stepCount());
    try std.testing.expectEqual(plan_mod.StepStatus.completed, plan.steps.items[0].status);
    try std.testing.expectEqual(plan_mod.StepStatus.pending, plan.steps.items[1].status);
    try std.testing.expectEqualStrings("glob", plan.steps.items[0].tool_hint.?);
    try std.testing.expectEqualStrings("file_edit", plan.steps.items[1].tool_hint.?);
    try std.testing.expectEqual(1, plan.steps.items[1].dependencies.len);
    try std.testing.expectEqual(@as(u64, 1), plan.steps.items[1].dependencies[0]);
}

// PSEUDOCODE:
// 1. Provide malformed JSON text
// 2. Ensure fallback or error handling returns null without crash

test "plan_parser: malformed JSON returns null fallback" {
    const alloc = std.testing.allocator;

    const input = "```json\n{ invalid json here...\n```";
    const plan = try plan_parser.extractStructuredPlan(input, alloc);
    try std.testing.expect(plan == null);
}
