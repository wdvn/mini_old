//! registry.zig — Registry and dispatcher for the tool system.
//!
//! Central module routing tool calls from AI to corresponding handlers.
//!
//! ## Execution Flow
//! 1. Agent receives `tool_use` from AI (name + input_json)
//! 2. Agent calls `executeTool(alloc, name, input_json)`
//! 3. Registry validates policy (allowlist/blocklist)
//! 4. Dispatch to corresponding handler
//! 5. If not found → attempt MCP manager
//!
//! ## Policy
//!   - Allowlist: if set, ONLY tools in the list are allowed to execute
//!   - Blocklist: tools in the list are denied
//!   - Allowlist takes precedence over blocklist
//!
//! ## Core tools (always sent to API)
//! bash, file_write, file_edit, http_request, skills
//! (file_read, glob, grep: internal dispatch only, not exposed to the model)
//!
//! ## Extended tools (sent conditionally on keyword matches)
//! See `extended_triggers` below.

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const proto = @import("../core/protocol.zig");
const json = @import("../core/json.zig");
const utils = @import("../core/utils.zig");
const main = @import("../main.zig");
const bash_tool = @import("../tools/bash.zig");
const file_tool = @import("../tools/file.zig");
const glob_tool = @import("../tools/glob.zig");
const grep_tool = @import("../tools/grep.zig");
const http_tool = @import("../tools/http.zig");
const subagent = @import("../tools/subagent.zig");
const batch_subagent = @import("../tools/batch_subagent.zig");
const artifact_tool = @import("../tools/artifact.zig");
const session_diag = @import("../tools/session_diagnostics.zig");
const media_gen_tool = @import("../tools/media_gen.zig");
const mcp_mod = @import("mcp.zig");
const hooks = @import("../core/hooks.zig");
const skills_mod = @import("../core/skills.zig");
const quickjs = @import("../runtime/quickjs_engine.zig");
const signals = @import("../core/signals.zig");

// ---------------------------------------------------------------------------
// Global state (single-threaded)
// ---------------------------------------------------------------------------

/// Mutex protecting registry globals.
pub var g_registry_mutex = std.atomic.Mutex.unlocked;

/// MCP manager — set by main.zig after MCP initialization.
var g_mcp: ?*mcp_mod.McpClientManager = null;

/// Allowlist comma-separated. Null = unlimited.
var g_allowlist: ?[]const u8 = null;

/// Blocklist comma-separated. Null = nothing blocked.
var g_blocklist: ?[]const u8 = null;

/// RFC-011: Media generation & vision capability gates
var g_image_gen_enabled: bool = false;
var g_video_gen_enabled: bool = false;
var g_image_input_enabled: bool = true;

pub fn setMediaConfig(image_gen: bool, video_gen: bool, image_input: bool) void {
    while (!g_registry_mutex.tryLock()) {}
    g_image_gen_enabled = image_gen;
    g_video_gen_enabled = video_gen;
    g_image_input_enabled = image_input;
    g_registry_mutex.unlock();
}

/// Configure MCP manager fallback when no built-in tool matches.
pub fn setMcpManager(m: ?*mcp_mod.McpClientManager) void {
    while (!g_registry_mutex.tryLock()) {}
    g_mcp = m;
    g_registry_mutex.unlock();
}

/// Set policy for tool execution.
/// allowlist and blocklist are pointers to config strings (not copied).
pub fn setPolicy(allowlist: ?[]const u8, blocklist: ?[]const u8) void {
    while (!g_registry_mutex.tryLock()) {}
    g_allowlist = allowlist;
    g_blocklist = blocklist;
    g_registry_mutex.unlock();
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

fn executeToolInternal(alloc: Allocator, io: std.Io, name: []const u8, input_json: []const u8) ![]u8 {
    // Built-in tool dispatch
    if (std.mem.eql(u8, name, "bash")) return bash_tool.executeTool(alloc, io, input_json);
    if (std.mem.eql(u8, name, "file_read")) return file_tool.readTool(alloc, io, input_json);
    if (std.mem.eql(u8, name, "file_write")) return file_tool.writeTool(alloc, io, input_json);
    if (std.mem.eql(u8, name, "file_edit")) return file_tool.editTool(alloc, io, input_json);
    if (std.mem.eql(u8, name, "glob")) return glob_tool.executeTool(alloc, io, input_json);
    if (std.mem.eql(u8, name, "grep")) return grep_tool.executeTool(alloc, io, input_json);
    if (std.mem.eql(u8, name, "http_request")) return http_tool.executeTool(alloc, input_json);
    if (std.mem.eql(u8, name, "invoke_subagent")) return subagent.executeTool(alloc, io, input_json);
    if (std.mem.eql(u8, name, "batch_invoke_subagents")) return batch_subagent.executeTool(alloc, io, input_json);
    if (std.mem.eql(u8, name, "artifact_write")) return artifact_tool.writeTool(alloc, io, input_json);
    if (std.mem.eql(u8, name, "artifact_read")) return artifact_tool.readTool(alloc, io, input_json);
    if (std.mem.eql(u8, name, "artifact_list")) return artifact_tool.listTool(alloc, io, input_json);
    if (std.mem.eql(u8, name, "session_diagnostics")) return session_diag.executeTool(alloc, io, input_json);
    if (std.mem.eql(u8, name, "generate_image")) return media_gen_tool.generateImageTool(alloc, io, input_json);
    if (std.mem.eql(u8, name, "generate_video")) return media_gen_tool.generateVideoTool(alloc, io, input_json);
    if (std.mem.eql(u8, name, "image_attach")) return media_gen_tool.attachImageTool(alloc, io, input_json);
    if (std.mem.eql(u8, name, "skills")) return executeSkills(alloc, io, input_json);
    if (std.mem.eql(u8, name, "codeact")) return executeCodeActTool(alloc, io, input_json);

    // Common LLM alias fallback normalization
    if (std.mem.eql(u8, name, "read") or std.mem.eql(u8, name, "read_file")) return file_tool.readTool(alloc, io, input_json);
    if (std.mem.eql(u8, name, "write") or std.mem.eql(u8, name, "write_file")) return file_tool.writeTool(alloc, io, input_json);
    if (std.mem.eql(u8, name, "edit") or std.mem.eql(u8, name, "edit_file")) return file_tool.editTool(alloc, io, input_json);
    if (std.mem.eql(u8, name, "sh") or std.mem.eql(u8, name, "shell") or std.mem.eql(u8, name, "terminal")) return bash_tool.executeTool(alloc, io, input_json);

    // MCP fallback: names follow "server__toolname" format
    while (!g_registry_mutex.tryLock()) {}
    const mgr = g_mcp;
    g_registry_mutex.unlock();
    if (mgr) |m| {
        if (m.callTool(name, input_json)) |result| return result;
    }

    return std.fmt.allocPrint(
        alloc,
        "Tool does not exist: '{s}'. Use 'skills' tool to view available tools.",
        .{name},
    );
}

fn executeCodeActTool(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    const code = json.findString(input_json, "code") orelse return error.MissingCodeArgument;
    const engine = try quickjs.Engine.init(alloc, io);
    defer engine.deinit();

    var res = try engine.eval(code, "agent_codeact.js");
    defer res.deinit();

    var out_buf = utils.BufWriter.init(alloc);
    defer out_buf.deinit();

    if (!res.is_error) {
        try out_buf.writeAll("[CodeAct Execution Output]\n");
        if (res.stdout.len > 0) {
            try out_buf.print("stdout:\n{s}\n", .{res.stdout});
        }
        if (res.return_value_json) |ret| {
            try out_buf.print("return value:\n{s}\n", .{ret});
        }
        if (res.stdout.len == 0 and res.return_value_json == null) {
            try out_buf.writeAll("(Code executed successfully with no output)\n");
        }
        return alloc.dupe(u8, out_buf.list.items);
    } else {
        return std.fmt.allocPrint(
            alloc,
            "[CodeAct Error]: {s}\n{s}",
            .{ res.error_message orelse "JS execution error", res.stdout },
        );
    }
}

/// Execute tool by name.
/// Returns string result. Caller must free.
pub fn executeTool(alloc: Allocator, io: std.Io, name: []const u8, input_json: []const u8) ![]u8 {
    // Policy check
    if (!isPermitted(name)) {
        const err_msg = try std.fmt.allocPrint(alloc, "Tool '{s}' is denied by current policy.", .{name});
        hooks.dispatch(alloc, io, .{
            .event = "post-tool-use",
            .tool_name = name,
            .input_json = input_json,
            .tool_result = err_msg,
            .is_error = true,
        });
        return err_msg;
    }

    hooks.dispatch(alloc, io, .{
        .event = "pre-tool-use",
        .tool_name = name,
        .input_json = input_json,
    });

    var is_error = false;
    // PSEUDOCODE:
    // 1. Execute tool handler
    // 2. If Interrupted error or signals.isInterrupted(), propagate error.Interrupted immediately
    // 3. Otherwise wrap error message and dispatch post-tool-use hook
    const res = executeToolInternal(alloc, io, name, input_json) catch |e| blk: {
        if (e == error.Interrupted or signals.isInterrupted()) {
            return error.Interrupted;
        }
        is_error = true;
        break :blk try std.fmt.allocPrint(alloc, "Tool error: {s}", .{@errorName(e)});
    };
    if (signals.isInterrupted()) {
        alloc.free(res);
        return error.Interrupted;
    }

    hooks.dispatch(alloc, io, .{
        .event = "post-tool-use",
        .tool_name = name,
        .input_json = input_json,
        .tool_result = res,
        .is_error = is_error,
    });

    return res;
}

// ---------------------------------------------------------------------------
// Tool metadata
// ---------------------------------------------------------------------------

pub const definitions = [_]proto.ToolDefinition{
    .{
        .name = "codeact",
        .description = "Execute JavaScript in an embedded CodeAct VM with mini.* global API (mini.sh, mini.read, mini.write, mini.patch, mini.http, mini.sessions, mini.sessionDetail, mini.sessionKill, mini.setThinking). Use for automating complex multi-step logic or data processing.",
        .input_schema_json =
        \\{"type":"object","properties":{"code":{"type":"string","description":"JavaScript code to execute in CodeAct VM"}},"required":["code"]}
        ,
    },
    .{
        .name = "bash",
        .description = "Execute shell commands via /bin/sh. Returns stdout and stderr. CWD is the project root. Dangerous commands (rm -rf /, dd, shutdown...) are blocked.",
        .input_schema_json =
        \\{"type":"object","properties":{"command":{"type":"string","description":"Shell command to execute"}},"required":["command"]}
        ,
    },
    // NOTE: file_read removed from exposed tool list — force the model to use
    // bash (cat/sed/awk) or CodeAct (mini.read) instead. Internal dispatch is kept.
    .{
        .name = "file_write",
        .description = "Write or overwrite entire file content. Automatically creates parent directories if needed. Do NOT use for small partial edits (use file_edit).",
        .input_schema_json =
        \\{"type":"object","properties":{"path":{"type":"string","description":"File path to write"},"content":{"type":"string","description":"Full file content"}},"required":["path","content"]}
        ,
    },
    .{
        .name = "file_edit",
        .description = "Edit part of a file by replacing old_string with new_string. old_string must be unique in the file, or use replace_all=true.",
        .input_schema_json =
        \\{"type":"object","properties":{"path":{"type":"string","description":"File path to edit"},"old_string":{"type":"string","description":"Exact substring to replace"},"new_string":{"type":"string","description":"Replacement text"},"replace_all":{"type":"boolean","description":"Replace all occurrences (default: false)"}},"required":["path","old_string","new_string"]}
        ,
    },
    // NOTE: glob and grep removed from exposed tool list — force the model to
    // use bash (find/rg) or CodeAct (mini.glob/mini.grep) instead. Internal
    // dispatch is kept.
    .{
        .name = "http_request",
        .description = "Send HTTP/HTTPS requests. Supports GET, POST, PUT, DELETE, PATCH. Returns status code, headers, and response body.",
        .input_schema_json =
        \\{"type":"object","properties":{"url":{"type":"string","description":"Full URL (e.g. https://api.example.com/data)"},"method":{"type":"string","enum":["GET","POST","PUT","DELETE","PATCH"],"description":"HTTP method (default: GET)"},"headers":{"type":"object","description":"JSON object with headers (e.g. {\"Content-Type\": \"application/json\"})"},"body":{"type":"string","description":"Request body (for POST, PUT, PATCH)"}},"required":["url"]}
        ,
    },
    .{
        .name = "invoke_subagent",
        .description = "Spawn a subagent to perform a complex task (divide-and-conquer). Best for directory exploration, multifile refactorings, or long action sequences.",
        .input_schema_json =
        \\{"type":"object","properties":{"task":{"type":"string","description":"Detailed task for subagent"}},"required":["task"]}
        ,
    },
    .{
        .name = "batch_invoke_subagents",
        .description = "Spawn multiple subagents in parallel to process independent tasks. Ideal for batch processing workflows.",
        .input_schema_json =
        \\{"type":"object","properties":{"tasks":{"type":"array","items":{"type":"string"},"description":"List of tasks for parallel subagents"}},"required":["tasks"]}
        ,
    },
    .{
        .name = "skills",
        .description = "Inspect available skills (from ~/.mini/skills) and tools. operation=\"list\" lists all, operation=\"detail\" with name=<skill|tool> shows details. Skills are pre-written guidelines (SKILL.md); tools are executable functions.",
        .input_schema_json =
        \\{"type":"object","properties":{"operation":{"type":"string","enum":["list","detail"],"description":"list or detail"},"name":{"type":"string","description":"Skill or tool name (for detail)"}},"required":[]}
        ,
    },
    .{
        .name = "session_diagnostics",
        .description = "Query process status, subagents, and session logs (Event Sourcing Journal in ~/.mini/sessions). Inspect process liveness, REPL vs Subagent mode, executed acts, operational state, or terminate hanging processes.",
        .input_schema_json =
        \\{"type":"object","properties":{"operation":{"type":"string","enum":["list","detail","kill"],"description":"list (session list), detail (session detail by PID), kill (stop process)"},"pid":{"type":"integer","description":"PID of mini-agent or subagent process"},"signal":{"type":"string","description":"Signal for kill (default: SIGTERM or SIGKILL)"}},"required":["operation"]}
        ,
    },
    .{
        .name = "artifact_write",
        .description = "Create or update an independent artifact (plan, walkthrough, markdown, html, svg, code diff, mockup). Automatically saves to session artifacts and triggers live preview hooks.",
        .input_schema_json =
        \\{"type":"object","properties":{"name":{"type":"string","description":"Artifact filename (e.g., plan.md, walkthrough.md, preview.html, diagram.svg)"},"content":{"type":"string","description":"Artifact content"},"title":{"type":"string","description":"Short title for artifact"},"type":{"type":"string","enum":["markdown","html","svg","code","diff","text"],"description":"Artifact type (default: markdown)"},"summary":{"type":"string","description":"Brief summary of artifact content"},"user_facing":{"type":"string","enum":["true","false"],"description":"true if intended for user presentation"}},"required":["name","content"]}
        ,
    },
    .{
        .name = "artifact_read",
        .description = "Read content of a saved artifact in the current session by name.",
        .input_schema_json =
        \\{"type":"object","properties":{"name":{"type":"string","description":"Name of artifact to read (e.g., plan.md)"}},"required":["name"]}
        ,
    },
    .{
        .name = "artifact_list",
        .description = "List all artifacts along with metadata and paths in the current session.",
        .input_schema_json =
        \\{"type":"object","properties":{},"required":[]}
        ,
    },
    .{
        .name = "generate_image",
        .description = "Generate an image from a text prompt using OpenAI Images API or compatible provider, saving to the media output directory.",
        .input_schema_json =
        \\{"type":"object","properties":{"prompt":{"type":"string","description":"Detailed image description / prompt"},"size":{"type":"string","enum":["1024x1024","1536x1024","1024x1536","auto"],"description":"Image dimensions (default: 1024x1024)"},"filename":{"type":"string","description":"Optional sanitized target filename"},"model":{"type":"string","description":"Optional image model"}},"required":["prompt"]}
        ,
    },
    .{
        .name = "generate_video",
        .description = "Generate a video from a text prompt using OpenAI Sora or compatible provider with async polling, saving to media output directory.",
        .input_schema_json =
        \\{"type":"object","properties":{"prompt":{"type":"string","description":"Detailed video description / prompt"},"seconds":{"type":"integer","description":"Duration in seconds (default: 4)"},"filename":{"type":"string","description":"Optional sanitized target filename"},"model":{"type":"string","description":"Optional video model"}},"required":["prompt"]}
        ,
    },
    .{
        .name = "image_attach",
        .description = "Attach a local image file to the conversation for multi-turn inspection and vision loop-back.",
        .input_schema_json =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Path to local image file to attach"}},"required":["path"]}
        ,
    },
};

/// Core tool names (always sent to API).
/// file_read / glob / grep intentionally excluded: the model must use bash
/// (cat/sed/find/rg) or CodeAct (mini.read/mini.glob/mini.grep) instead.
/// Internal dispatch for these names is still supported in executeTool().
const core_tools = [_][]const u8{
    "bash",           "file_write",          "file_edit",
    "http_request",   "invoke_subagent",     "batch_invoke_subagents",
    "skills",         "session_diagnostics", "artifact_write",
    "artifact_read",  "artifact_list",       "generate_image",
    "generate_video", "image_attach",
};

/// Keyword triggers for extended tools (sent conditionally).
const Trigger = struct {
    tool: []const u8,
    keywords: []const []const u8,
};

const extended_triggers = [_]Trigger{
    // None in this minimal version.
    // Add here when introducing new extended tools.
};

// ---------------------------------------------------------------------------
// Tool selection
// ---------------------------------------------------------------------------

/// Buffer for filtered tool list (module-level, single-threaded safe).
var filtered_buf: [definitions.len + 64]proto.ToolDefinition = undefined;

/// Return all tool definitions.
pub fn getDefinitions() []const proto.ToolDefinition {
    return &definitions;
}

/// Return tool definitions relevant to user message.
/// Core tools are always included. Extended tools are added on keyword match.
/// MCP tools are appended if McpManager is available.
pub fn getRelevantDefinitions(alloc: Allocator, user_text: []const u8) []const proto.ToolDefinition {
    var count: usize = 0;

    // Core tools (subject to policy)
    for (&definitions) |*td| {
        if (!isCoreTool(td.name)) continue;
        if (!isPermitted(td.name)) continue;
        filtered_buf[count] = td.*;
        count += 1;
    }

    // Extended tools by keyword
    for (&extended_triggers) |*t| {
        for (t.keywords) |kw| {
            if (containsCI(user_text, kw)) {
                // Find definition
                for (&definitions) |*td| {
                    if (std.mem.eql(u8, td.name, t.tool) and isPermitted(td.name)) {
                        filtered_buf[count] = td.*;
                        count += 1;
                        break;
                    }
                }
                break;
            }
        }
    }

    // MCP tools
    while (!g_registry_mutex.tryLock()) {}
    const mgr = g_mcp;
    g_registry_mutex.unlock();
    if (mgr) |m| {
        const mcp_tools = m.getToolDefinitions(alloc);
        defer if (mcp_tools.len > 0) alloc.free(mcp_tools);
        for (mcp_tools) |mt| {
            if (count >= filtered_buf.len) break;
            filtered_buf[count] = mt;
            count += 1;
        }
    }

    return filtered_buf[0..count];
}

pub fn isCoreTool(name: []const u8) bool {
    for (&core_tools) |ct| {
        if (std.mem.eql(u8, name, ct)) return true;
    }
    return false;
}

// PSEUDOCODE:
// 1. Normalize tool name
// 2. Return true if tool is in exploration tool set (file_read, read, grep, glob, skills)
// 3. Otherwise return false

/// Check if a tool is an exploration tool that should always remain available (RFC-019).
pub fn isExplorationTool(name: []const u8) bool {
    const norm = normalizeToolName(name);
    return std.mem.eql(u8, norm, "file_read") or
        std.mem.eql(u8, norm, "grep") or
        std.mem.eql(u8, norm, "glob") or
        std.mem.eql(u8, norm, "skills");
}

// PSEUDOCODE:
// 1. If tool_hint is null, return all_defs directly
// 2. Iterate through all_defs
// 3. Keep exploration tools and tool matching normalized tool_hint
// 4. Return filtered list (or all_defs if empty)

/// Filter relevant definitions for plan-aware tool selection (RFC-019).
/// Exploration tools always remain available. If tool_hint is provided, preferred tool is kept.
pub fn filterDefinitionsForPlan(
    alloc: Allocator,
    all_defs: []const proto.ToolDefinition,
    tool_hint: ?[]const u8,
) []const proto.ToolDefinition {
    if (tool_hint == null) return all_defs;
    const hint = tool_hint.?;
    const norm_hint = normalizeToolName(hint);

    var filtered = std.ArrayListUnmanaged(proto.ToolDefinition).empty;
    errdefer filtered.deinit(alloc);

    for (all_defs) |td| {
        const norm_td = normalizeToolName(td.name);
        if (isExplorationTool(norm_td) or std.mem.eql(u8, norm_td, norm_hint)) {
            filtered.append(alloc, td) catch continue;
        }
    }

    if (filtered.items.len == 0) return all_defs;
    return filtered.toOwnedSlice(alloc) catch all_defs;
}

/// Match policy entry (trimmed) with tool name.
/// Entry ending in '*' -> wildcard prefix match on prefix before '*'.
/// Regular entry -> exact match.
fn matchesEntry(entry_trimmed: []const u8, name: []const u8) bool {
    // Wildcard prefix: entry = "mcp*" matches all names starting with "mcp"
    if (entry_trimmed.len > 0 and entry_trimmed[entry_trimmed.len - 1] == '*') {
        return std.mem.startsWith(u8, name, entry_trimmed[0 .. entry_trimmed.len - 1]);
    }
    return std.mem.eql(u8, entry_trimmed, name);
}

pub fn normalizeToolName(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "read") or std.mem.eql(u8, name, "read_file")) return "file_read";
    if (std.mem.eql(u8, name, "write") or std.mem.eql(u8, name, "write_file")) return "file_write";
    if (std.mem.eql(u8, name, "edit") or std.mem.eql(u8, name, "edit_file")) return "file_edit";
    if (std.mem.eql(u8, name, "sh") or std.mem.eql(u8, name, "shell") or std.mem.eql(u8, name, "terminal")) return "bash";
    return name;
}

/// Check if a name is a known built-in tool or recognized alias.
pub fn isBuiltinTool(name: []const u8) bool {
    const norm = normalizeToolName(name);
    if (std.mem.eql(u8, norm, "file_read") or
        std.mem.eql(u8, norm, "glob") or
        std.mem.eql(u8, norm, "grep"))
    {
        return true;
    }
    for (definitions) |td| {
        if (std.mem.eql(u8, norm, td.name)) return true;
    }
    return false;
}

pub fn isPermitted(name: []const u8) bool {
    // Block subagent calls if depth limit reached to avoid infinite recursion (Leaf Worker Pattern)
    if (std.mem.eql(u8, name, "invoke_subagent") or std.mem.eql(u8, name, "batch_invoke_subagents")) {
        const cur_depth = subagent.getCurrentDepth();
        const max_depth = subagent.getMaxDepth();
        if (cur_depth >= max_depth) return false;
    }

    // RFC-011: Capability gates for media tools
    if (std.mem.eql(u8, name, "generate_image")) {
        if (!g_image_gen_enabled) return false;
    }
    if (std.mem.eql(u8, name, "generate_video")) {
        if (!g_video_gen_enabled) return false;
    }
    if (std.mem.eql(u8, name, "image_attach")) {
        if (!g_image_input_enabled) return false;
    }

    const norm_name = normalizeToolName(name);

    while (!g_registry_mutex.tryLock()) {}
    const allow_list = g_allowlist;
    g_registry_mutex.unlock();
    if (allow_list) |l| {
        // Allowlist: ONLY allow listed tools
        var it = std.mem.splitScalar(u8, l, ',');
        while (it.next()) |entry| {
            const tr = std.mem.trim(u8, entry, " \t");
            const norm_entry = normalizeToolName(tr);
            if (matchesEntry(tr, name) or matchesEntry(norm_entry, norm_name)) return true;
        }
        return false; // not in allowlist
    }
    while (!g_registry_mutex.tryLock()) {}
    const block_list = g_blocklist;
    g_registry_mutex.unlock();
    if (block_list) |bl| {
        var it = std.mem.splitScalar(u8, bl, ',');
        while (it.next()) |entry| {
            const tr = std.mem.trim(u8, entry, " \t");
            const norm_entry = normalizeToolName(tr);
            if (matchesEntry(tr, name) or matchesEntry(norm_entry, norm_name)) return false;
        }
    }
    return true;
}

fn containsCI(text: []const u8, kw: []const u8) bool {
    if (kw.len > text.len) return false;
    var i: usize = 0;
    while (i + kw.len <= text.len) : (i += 1) {
        var match = true;
        for (0..kw.len) |j| {
            if (std.ascii.toLower(text[i + j]) != std.ascii.toLower(kw[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Skills tool (lists skills from ~/.mini/skills + tools)
// ---------------------------------------------------------------------------

/// Read SKILL.md (or RULES.md) of a skill.
/// Returns null if unable to read.
fn readSkillFile(alloc: Allocator, io: std.Io, skill_path: []const u8) ?[]u8 {
    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, skill_path, .{}) catch return null;
    defer file.close(io);
    const stat = file.stat(io) catch return null;
    if (stat.size == 0 or stat.size > 128 * 1024) return null;
    const buf = alloc.alloc(u8, @intCast(stat.size)) catch return null;
    const n = utils.readAll(io, file, buf) catch {
        alloc.free(buf);
        return null;
    };
    return buf[0..n];
}

fn executeSkillDetail(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    // PSEUDOCODE:
    // 1. Extract required 'name' argument.
    // 2. Search matched skill file in ~/.mini/skills and return content.
    // 3. Fallback to tool definitions in registry.
    const name = json.findString(input_json, "name") orelse
        return std.fmt.allocPrint(alloc, "Error: 'name' field required for detail operation", .{});

    if (skills_mod.getSkills()) |skills| {
        for (skills) |s| {
            if (std.mem.eql(u8, s.name, name)) {
                if (readSkillFile(alloc, io, s.path)) |content| {
                    defer alloc.free(content);
                    return std.fmt.allocPrint(
                        alloc,
                        "## Skill: {s}\n\nPath: `{s}`\n\n{s}",
                        .{ s.name, s.path, content },
                    );
                }
                return std.fmt.allocPrint(alloc, "Skill '{s}' exists but could not read `{s}`.", .{ s.name, s.path });
            }
        }
    }

    for (&definitions) |*td| {
        if (std.mem.eql(u8, td.name, name)) {
            return std.fmt.allocPrint(
                alloc,
                "## Tool: {s}\n\n{s}\n\n**Schema:**\n```json\n{s}\n```",
                .{ td.name, td.description, td.input_schema_json },
            );
        }
    }
    return std.fmt.allocPrint(alloc, "Skill or tool '{s}' not found.", .{name});
}

fn appendMcpToolsList(w: *utils.BufWriter) !void {
    // PSEUDOCODE: Lock registry mutex, inspect registered MCP tools, and print active list.
    while (!g_registry_mutex.tryLock()) {}
    const mgr = g_mcp;
    g_registry_mutex.unlock();

    if (mgr) |m| {
        if (m.servers.items.len > 0) {
            try w.writeAll("\n## MCP Tools\n\n");
            for (m.servers.items) |*server| {
                for (server.tools.items) |t| {
                    try w.print("  ✓ **{s}** — {s}\n", .{ t.prefixed_name, t.description });
                }
            }
        }
    }
}

fn executeSkillList(alloc: Allocator) ![]u8 {
    // PSEUDOCODE:
    // 1. Print discovered skills from ~/.mini/skills.
    // 2. Print built-in tools with permission status.
    // 3. Print MCP tools via appendMcpToolsList.
    var buf = utils.BufWriter.init(alloc);
    errdefer buf.deinit();
    const w = &buf;

    if (skills_mod.getSkills()) |skills| {
        try w.writeAll("## Skills (~/.mini/skills)\n\n");
        try w.writeAll("Skill = conventions/instructions (SKILL.md). Use 'skills' operation=detail to view content, or file_read directly.\n\n");
        for (skills) |s| {
            try w.print("  📄 **{s}** — {s}\n  ↳ `{s}`\n", .{ s.name, s.description, s.path });
        }
        try w.writeAll("\n");
    }

    try w.writeAll("## Tools\n\n");
    for (&definitions) |*td| {
        const permitted = isPermitted(td.name);
        const status = if (permitted) "✓" else "✗";
        try w.print("  {s} **{s}** — {s}\n", .{ status, td.name, td.description });
    }
    try appendMcpToolsList(w);
    return buf.toOwnedSlice();
}

fn executeSkills(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    // PSEUDOCODE:
    // 1. Determine requested operation (detail vs list).
    // 2. Dispatch to dedicated sub-handler.
    const operation = json.findString(input_json, "operation") orelse "list";
    if (std.mem.eql(u8, operation, "detail")) {
        return executeSkillDetail(alloc, io, input_json);
    }
    return executeSkillList(alloc);
}

/// Interrupt active bash process (called on Watchdog timeout or SIGINT).
pub fn interruptActiveBash() void {
    bash_tool.interruptCurrent();
}

/// Force kill active bash process group with SIGKILL (called on Watchdog escalation).
pub fn forceKillActiveBash() void {
    bash_tool.forceKillCurrent();
}

/// Interrupt active MCP server (called on Watchdog timeout or SIGINT).
pub fn interruptActiveMcp() void {
    signals.setInterrupted(true);
    while (!g_registry_mutex.tryLock()) {}
    const mgr = g_mcp;
    g_registry_mutex.unlock();
    if (mgr) |m| {
        for (m.servers.items) |*srv| {
            if (srv.child_pid > 0) {
                if (comptime builtin.os.tag != .windows) {
                    _ = std.posix.kill(-srv.child_pid, std.posix.SIG.TERM) catch {
                        _ = std.posix.kill(srv.child_pid, std.posix.SIG.TERM) catch {};
                    };
                }
                // Null child pipes BEFORE closing so child.wait cleanup
                // doesn't try to re-close already-closed fds (BADF panic).
                srv.child.stdin = null;
                srv.child.stdout = null;
                srv.stdin_file.close(main.g_io);
                srv.stdout_file.close(main.g_io);
            }
        }
    }
}

/// Force kill active MCP server process group with SIGKILL (called on Watchdog escalation).
pub fn forceKillActiveMcp() void {
    signals.setInterrupted(true);
    while (!g_registry_mutex.tryLock()) {}
    const mgr = g_mcp;
    g_registry_mutex.unlock();
    if (mgr) |m| {
        for (m.servers.items) |*srv| {
            if (srv.child_pid > 0) {
                if (comptime builtin.os.tag != .windows) {
                    _ = std.posix.kill(-srv.child_pid, std.posix.SIG.KILL) catch {
                        _ = std.posix.kill(srv.child_pid, std.posix.SIG.KILL) catch {};
                    };
                }
                // Null child pipes BEFORE closing so child.wait cleanup
                // doesn't try to re-close already-closed fds (BADF panic).
                srv.child.stdin = null;
                srv.child.stdout = null;
                srv.stdin_file.close(main.g_io);
                srv.stdout_file.close(main.g_io);
            }
        }
    }
}

test "codeact as native tool: codeact in registry" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // Verify codeact definition exists in built-in definitions
    var found_def = false;
    for (definitions) |td| {
        if (std.mem.eql(u8, td.name, "codeact")) {
            found_def = true;
            try std.testing.expect(std.mem.indexOf(u8, td.description, "CodeAct") != null);
            break;
        }
    }
    try std.testing.expect(found_def);

    // Test executeTool with codeact
    const input_json =
        \\{"code":"console.log('Hello from codeact native tool'); 10 + 20;"}
    ;

    const output = try executeTool(alloc, io, "codeact", input_json);
    defer alloc.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "[CodeAct Execution Output]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Hello from codeact native tool") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "30") != null);
}

test "registry: subagent depth limit permission" {
    // Depth 0: allow invoke_subagent
    try std.testing.expect(isPermitted("invoke_subagent"));
    try std.testing.expect(isPermitted("batch_invoke_subagents"));

    // Set depth = 2 (max): automatically block
    const env_map = main.getEnvironMap();
    if (env_map == null) return error.SkipZigTest;

    const em = env_map.?;
    const prev_depth = em.get("MINI_SUBAGENT_DEPTH");
    const prev_max = em.get("MINI_MAX_SUBAGENT_DEPTH");

    em.put("MINI_SUBAGENT_DEPTH", "2") catch {};
    em.put("MINI_MAX_SUBAGENT_DEPTH", "2") catch {};
    defer {
        if (prev_depth) |v| em.put("MINI_SUBAGENT_DEPTH", v) catch {} else em.put("MINI_SUBAGENT_DEPTH", "0") catch {};
        if (prev_max) |v| em.put("MINI_MAX_SUBAGENT_DEPTH", v) catch {} else em.put("MINI_MAX_SUBAGENT_DEPTH", "0") catch {};
    }

    try std.testing.expect(!isPermitted("invoke_subagent"));
    try std.testing.expect(!isPermitted("batch_invoke_subagents"));
}

test "registry: plan-aware tool filtering" {
    const alloc = std.testing.allocator;

    try std.testing.expect(isExplorationTool("file_read"));
    try std.testing.expect(isExplorationTool("grep"));
    try std.testing.expect(isExplorationTool("glob"));
    try std.testing.expect(isExplorationTool("skills"));
    try std.testing.expect(!isExplorationTool("bash"));
    try std.testing.expect(!isExplorationTool("file_edit"));

    const sample_defs = [_]proto.ToolDefinition{
        .{ .name = "bash", .description = "run bash", .input_schema_json = "{}" },
        .{ .name = "file_read", .description = "read file", .input_schema_json = "{}" },
        .{ .name = "file_edit", .description = "edit file", .input_schema_json = "{}" },
        .{ .name = "grep", .description = "search code", .input_schema_json = "{}" },
    };

    // With tool_hint = "file_edit": keep file_read, grep (exploration) + file_edit (hint)
    const filtered = filterDefinitionsForPlan(alloc, &sample_defs, "file_edit");
    defer if (filtered.ptr != sample_defs[0..].ptr) alloc.free(filtered);

    try std.testing.expectEqual(3, filtered.len);
    var has_bash = false;
    for (filtered) |td| {
        if (std.mem.eql(u8, td.name, "bash")) has_bash = true;
    }
    try std.testing.expect(!has_bash);
}
