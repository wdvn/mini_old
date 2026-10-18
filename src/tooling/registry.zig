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

/// Media generation & vision capability gates
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
    if (std.mem.eql(u8, name, "tool_search")) return executeToolSearch(alloc, input_json);
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
        .description = "Execute JavaScript in an embedded CodeAct QuickJS VM with direct access to the global `mini` object.\n" ++
            "Execution is synchronous (no top-level await, no Promises). Use console.log(...) to output findings into the observation (REQUIRED to receive data).\n" ++
            "Batch multiple operations into a single script whenever possible.\n\n" ++
            "Available global `mini` APIs:\n" ++
            "- File Operations: mini.read(path, offset?, limit?), mini.write(path, content), mini.patch(path, oldStr, newStr, opts?), mini.exists(path), mini.stat(path)\n" ++
            "- Search: mini.glob(pattern, basePath?), mini.grep(pattern, path?, opts?)\n" ++
            "- Shell & Jobs: mini.sh(command), mini.shBackground(command), mini.jobStatus(jobId), mini.jobLogs(jobId, lines?), mini.jobKill(jobId, signal?)\n" ++
            "- Network: mini.http(method, url, opts?) -> { status, body, headers }\n" ++
            "- Reasoning: mini.setThinking(\"low\"|\"medium\"|\"high\"|\"none\"|tokens)\n" ++
            "- Artifacts & Skills: mini.artifact(name, content), mini.skill(name, file_path?), mini.env(name)",
        .input_schema_json =
        \\{"type":"object","properties":{"code":{"type":"string","description":"JavaScript code to execute synchronously in the CodeAct VM. Must use console.log(...) to return outputs in the observation. Accesses the global mini.* API."}},"required":["code"]}
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
        .description = "Inspect available skills (from ~/.mini/skills) and tools. operation=\"list\" lists all, operation=\"detail\" with name=<skill|tool> shows details. Optional file_path loads sub-resources (references/, templates/, scripts/).",
        .input_schema_json =
        \\{"type":"object","properties":{"operation":{"type":"string","enum":["list","detail"],"description":"list or detail"},"name":{"type":"string","description":"Skill or tool name (for detail)"},"file_path":{"type":"string","description":"Optional sub-path relative to skill folder (e.g. 'references/api.md', 'templates/spec.md')"}},"required":[]}
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
    // Meta-tool that materializes deferred tool schemas on demand.
    .{
        .name = "tool_search",
        .description = "Search currently hidden tool schemas by name or keyword. Returns full definitions (name, description, input_schema) of matching deferred tools, which stay visible for the rest of the session. Use this to discover MCP tools, subagent/media/artifact tools before calling them.",
        .input_schema_json =
        \\{"type":"object","properties":{"query":{"type":"string","description":"Tool name or keyword to match against hidden tool names and descriptions"},"limit":{"type":"integer","description":"Max matches to return (default 10)"}},"required":["query"]}
        ,
    },
};

/// Core tool names (always sent to API).
/// file_read / glob / grep intentionally excluded: the model must use bash
/// (cat/sed/find/rg) or CodeAct (mini.read/mini.glob/mini.grep) instead.
/// Internal dispatch for these names is still supported in executeTool().
const core_tools = [_][]const u8{
    "codeact",        "bash",                "file_write",
    "file_edit",      "http_request",        "invoke_subagent",
    "batch_invoke_subagents", "skills",      "session_diagnostics",
    "artifact_write", "artifact_read",       "artifact_list",
    "generate_image", "generate_video",      "image_attach",
};

/// Tools always sent in deferred mode (never hidden behind tool_search).
const essential_tools = [_][]const u8{
    "bash",       "file_write", "file_edit",
    "http_request", "skills",   "tool_search",
};

/// Built-in tools that are hidden until promoted.
const deferred_tools = [_][]const u8{
    "codeact",         "invoke_subagent", "batch_invoke_subagents",
    "session_diagnostics", "artifact_write",  "artifact_read",
    "artifact_list",       "generate_image",  "generate_video",
    "image_attach",
};

/// Grow-only session promotion set, stored in a static buffer.
/// Names are copied inline so the set has no allocator ownership and never
/// outlives the process (callers pass per-turn arenas, which are freed).
const MAX_PROMOTED_TOOLS = 64;
const MAX_PROMOTED_NAME_LEN = 96;
var promoted_tools: [MAX_PROMOTED_TOOLS][MAX_PROMOTED_NAME_LEN]u8 = undefined;
var promoted_tools_len: [MAX_PROMOTED_TOOLS]usize = undefined;
var promoted_count: usize = 0;

/// Deferred tool loading enabled by default (MINI_DEFERRED_TOOLS=0 opts out).
var g_deferred_enabled: bool = true;

/// Enable/disable deferred tool loading for this process.
pub fn setDeferredToolsEnabled(enabled: bool) void {
    while (!g_registry_mutex.tryLock()) {}
    g_deferred_enabled = enabled;
    g_registry_mutex.unlock();
}

/// Current deferred tool loading state.
pub fn isDeferredToolsEnabled() bool {
    while (!g_registry_mutex.tryLock()) {}
    const v = g_deferred_enabled;
    g_registry_mutex.unlock();
    return v;
}

/// Reset the promotion set (tests / fresh session).
pub fn resetPromotedTools() void {
    while (!g_registry_mutex.tryLock()) {}
    promoted_count = 0;
    g_registry_mutex.unlock();
}

/// Number of promoted tools (diagnostics/tests).
pub fn promotedCount() usize {
    while (!g_registry_mutex.tryLock()) {}
    const n = promoted_count;
    g_registry_mutex.unlock();
    return n;
}

/// Promote a tool so its schema stays visible for later acts.
/// Grow-only: repeated or out-of-order calls never reorder or remove entries.
pub fn promoteTool(name: []const u8) void {
    if (name.len == 0 or name.len >= MAX_PROMOTED_NAME_LEN) return;
    const norm = normalizeToolName(name);
    if (norm.len == 0 or norm.len >= MAX_PROMOTED_NAME_LEN) return;
    // Already-visible tools need no promotion entry (keeps the sent list compact).
    if (isEssentialTool(norm)) return;

    while (!g_registry_mutex.tryLock()) {}
    defer g_registry_mutex.unlock();
    for (promoted_tools[0..promoted_count], promoted_tools_len[0..promoted_count]) |buf, len| {
        if (std.mem.eql(u8, buf[0..len], norm)) return;
    }
    if (promoted_count >= MAX_PROMOTED_TOOLS) return;
    @memcpy(promoted_tools[promoted_count][0..norm.len], norm);
    promoted_tools_len[promoted_count] = norm.len;
    promoted_count += 1;
}

/// True when the tool was already promoted this session.
pub fn isToolPromoted(name: []const u8) bool {
    const norm = normalizeToolName(name);
    while (!g_registry_mutex.tryLock()) {}
    defer g_registry_mutex.unlock();
    for (promoted_tools[0..promoted_count], promoted_tools_len[0..promoted_count]) |buf, len| {
        if (std.mem.eql(u8, buf[0..len], norm)) return true;
    }
    return false;
}

/// Tool definitions sent to the model in deferred mode.
/// Essential core first, then promoted tools in first-promotion order (stable prefix).
/// Caller owns the returned slice.
pub fn resolveDeferredTools(alloc: Allocator) []proto.ToolDefinition {
    // PSEUDOCODE:
    // 1. Append permitted essential tools in definition order (stable prefix).
    // 2. Snapshot the promotion set under the registry lock, then release it.
    // 3. Append promoted built-in tools, then promoted MCP tools, both in
    //    first-promotion order so earlier entries are never rewritten.
    var list = std.ArrayListUnmanaged(proto.ToolDefinition).empty;
    errdefer list.deinit(alloc);

    for (definitions) |td| {
        if (!isEssentialTool(td.name)) continue;
        if (!isPermitted(td.name)) continue;
        list.append(alloc, td) catch return &.{};
    }

    var promoted = std.ArrayListUnmanaged([]const u8).empty;
    defer promoted.deinit(alloc);
    while (!g_registry_mutex.tryLock()) {}
    var i: usize = 0;
    while (i < promoted_count) : (i += 1) {
        promoted.append(alloc, promoted_tools[i][0..promoted_tools_len[i]]) catch {};
    }
    const mgr = g_mcp;
    g_registry_mutex.unlock();

    for (promoted.items) |name| {
        var found = false;
        for (definitions) |td| {
            if (std.mem.eql(u8, td.name, name) and isPermitted(td.name)) {
                list.append(alloc, td) catch return &.{};
                found = true;
                break;
            }
        }
        if (found) continue;
        if (mgr) |m| {
            const mcp_tools = m.getToolDefinitions(alloc);
            defer if (mcp_tools.len > 0) alloc.free(mcp_tools);
            for (mcp_tools) |mt| {
                if (std.mem.eql(u8, mt.name, name)) {
                    list.append(alloc, mt) catch return &.{};
                    break;
                }
            }
        }
    }
    return list.toOwnedSlice(alloc) catch &.{};
}

/// True when a tool belongs to the always-sent tier.
pub fn isEssentialTool(name: []const u8) bool {
    for (essential_tools) |et| {
        if (std.mem.eql(u8, name, et)) return true;
    }
    return false;
}

/// True when a built-in tool is hidden behind tool_search.
pub fn isDeferredTool(name: []const u8) bool {
    for (deferred_tools) |dt| {
        if (std.mem.eql(u8, name, dt)) return true;
    }
    return false;
}

/// Search hidden tool schemas (built-in deferred + MCP tools).
/// Returns a JSON array of full definitions ranked by relevance; matched tools are
/// promoted. When nothing matches, returns a JSON object with a hint and a short
/// list of closest tool names.
fn executeToolSearch(alloc: Allocator, input_json: []const u8) ![]u8 {
    // PSEUDOCODE:
    // 1. Read query / limit from input JSON.
    // 2. Collect candidate definitions: built-in deferred tools not sent yet, then MCP tools.
    // 3. Score every candidate (name hit > description hit; word-boundary beats substring);
    //    drop zero scores, sort by score desc, cap by limit.
    // 4. Promote every match so it stays visible for later acts.
    // 5. Zero matches -> hint + closest-candidate tool names (CI Levenshtein <= 3 on names).
    const query = json.findString(input_json, "query") orelse "";
    const limit: usize = blk: {
        const raw = json.findString(input_json, "limit") orelse "10";
        break :blk std.fmt.parseInt(usize, raw, 10) catch 10;
    };

    const Scored = struct { def: proto.ToolDefinition, score: usize };
    var cands: std.ArrayListUnmanaged(proto.ToolDefinition) = .empty;
    defer cands.deinit(alloc);
    var matches: std.ArrayListUnmanaged(Scored) = .empty;
    defer matches.deinit(alloc);

    for (definitions) |td| {
        if (!isDeferredTool(td.name)) continue;
        if (isToolPromoted(td.name)) continue;
        cands.append(alloc, td) catch break;
        const score = toolQueryScore(td, query);
        if (score > 0) matches.append(alloc, .{ .def = td, .score = score }) catch break;
    }

    while (!g_registry_mutex.tryLock()) {}
    const mgr = g_mcp;
    g_registry_mutex.unlock();
    if (mgr) |m| {
        const mcp_tools = m.getToolDefinitions(alloc);
        defer if (mcp_tools.len > 0) alloc.free(mcp_tools);
        for (mcp_tools) |mt| {
            if (isToolPromoted(mt.name)) continue;
            cands.append(alloc, mt) catch break;
            const score = toolQueryScore(mt, query);
            if (score > 0) matches.append(alloc, .{ .def = mt, .score = score }) catch break;
        }
    }

    if (matches.items.len == 0) {
        return toolSearchNoMatch(alloc, query, cands.items);
    }

    // Rank: score desc, name asc as tie-break (insertion sort; lists are short).
    for (1..matches.items.len) |i| {
        var j = i;
        while (j > 0) : (j -= 1) {
            const a = matches.items[j - 1];
            const b = matches.items[j];
            const reorder = b.score > a.score or
                (b.score == a.score and std.mem.lessThan(u8, b.def.name, a.def.name));
            if (!reorder) break;
            const tmp = matches.items[j];
            matches.items[j] = matches.items[j - 1];
            matches.items[j - 1] = tmp;
        }
    }
    const keep = @min(matches.items.len, limit);

    for (matches.items[0..keep]) |sm| promoteTool(sm.def.name);

    var out = utils.BufWriter.init(alloc);
    defer out.deinit();
    try out.writeAll("[");
    for (matches.items[0..keep], 0..) |sm, i| {
        const mt = sm.def;
        if (i > 0) try out.writeAll(",");
        const e_name = try json.escape(alloc, mt.name);
        defer alloc.free(e_name);
        const e_desc = try json.escape(alloc, mt.description);
        defer alloc.free(e_desc);
        try out.print(
            "{{\"name\":\"{s}\",\"description\":\"{s}\",\"input_schema\":{s}}}",
            .{ e_name, e_desc, mt.input_schema_json },
        );
    }
    try out.writeAll("]");
    return alloc.dupe(u8, out.list.items);
}

/// Relevance score of a tool for the query (0 = no match).
/// PSEUDOCODE:
/// 1. Whole query case-insensitive substring: name hit (100) beats description hit (30).
/// 2. Otherwise split the query into tokens and take the strongest token signal:
///    name word-boundary (80) > name substring (60) > description substring (20).
/// 3. Token word-boundary = token appears at a non-alphanumeric boundary in the name,
///    approximated by checking the token and its underscore/hyphen variants.
fn toolQueryScore(td: proto.ToolDefinition, query: []const u8) usize {
    if (query.len == 0) return 0;
    if (containsCI(td.name, query)) return 100;
    var best: usize = 0;
    var tok_it = std.mem.tokenizeAny(u8, query, " \t_");
    while (tok_it.next()) |tok| {
        if (tok.len == 0) continue;
        var s: usize = 0;
        if (containsCI(td.name, tok)) {
            s = if (tokenAtWordBoundaryCI(td.name, tok)) 80 else 60;
        } else if (containsCI(td.description, tok)) {
            s = 20;
        }
        if (s > best) best = s;
    }
    return best;
}

/// True when the token starts at a word boundary inside text (case-insensitive).
/// Boundaries are positions preceded by a non-alphanumeric char (e.g. "_", "-").
fn tokenAtWordBoundaryCI(text: []const u8, token: []const u8) bool {
    if (token.len >= text.len) return containsCI(text, token);
    var i: usize = 0;
    while (i + token.len <= text.len) : (i += 1) {
        if (!containsCI(text[i .. i + token.len], token)) continue;
        const at_start = i == 0;
        const preceded_by_sep = i > 0 and !std.ascii.isAlphanumeric(text[i - 1]);
        if (at_start or preceded_by_sep) return true;
    }
    return false;
}

/// Zero-match response for tool_search: a JSON object with a recovery hint and a
/// short list of closest tool names (case-insensitive Levenshtein distance <= 3).
fn toolSearchNoMatch(alloc: Allocator, query: []const u8, candidates: []const proto.ToolDefinition) ![]u8 {
    // PSEUDOCODE:
    // 1. Rank candidate tool names by CI Levenshtein distance to the query.
    // 2. Keep names within distance 3 (at most 5).
    // 3. Emit {"no_match":true, "hint":"...", "closest_names":[...]} JSON.
    var ranked: std.ArrayListUnmanaged(struct { name: []const u8, dist: u32 }) = .empty;
    defer ranked.deinit(alloc);
    for (candidates) |cd| {
        const d = try levenshteinCICapped(alloc, cd.name, query, 4);
        if (d <= 3) {
            try ranked.append(alloc, .{ .name = cd.name, .dist = d });
        }
    }
    // Insertion sort by (dist, name); skip when list has 0/1 items
    // (1..0 underflows on usize).
    if (ranked.items.len > 1) {
        for (1..ranked.items.len) |i| {
            var j = i;
            while (j > 0) : (j -= 1) {
                const a = ranked.items[j - 1];
                const b = ranked.items[j];
                if (b.dist < a.dist or (b.dist == a.dist and std.mem.lessThan(u8, b.name, a.name))) {
                    const tmp = ranked.items[j];
                    ranked.items[j] = ranked.items[j - 1];
                    ranked.items[j - 1] = tmp;
                } else break;
            }
        }
    }

    var out = utils.BufWriter.init(alloc);
    defer out.deinit();
    try out.writeAll("{\"no_match\":true,\"hint\":\"");
    try out.print("no hidden tool matches '{s}': search by tool-name prefix or keyword, then call the tool by its full name", .{query});
    try out.writeAll("\",\"closest_names\":[");
    const show = @min(ranked.items.len, 5);
    for (ranked.items[0..show], 0..) |r, i| {
        if (i > 0) try out.writeAll(",");
        const e = try json.escape(alloc, r.name);
        defer alloc.free(e);
        try out.print("\"{s}\"", .{e});
    }
    try out.writeAll("]}");
    return alloc.dupe(u8, out.list.items);
}

/// PSEUDOCODE:
/// 1. Fast reject: distance is always >= |a.len - b.len|; if that exceeds cap, return cap + 1.
/// 2. Two-row Levenshtein DP over the two inputs, comparing chars case-insensitively
///    (rows allocated on the heap: both inputs are user-free-text and unbounded).
/// 3. Early-exit as soon as the row minimum exceeds cap (ranking bound only).
fn levenshteinCICapped(alloc: Allocator, a: []const u8, b: []const u8, cap: u32) Allocator.Error!u32 {
    // PSEUDOCODE:
    // 1. If |a.len - b.len| > cap, distance > cap by construction.
    const big = if (a.len >= b.len) a.len else b.len;
    const small = if (a.len >= b.len) b.len else a.len;
    if (big - small > cap) return cap + 1;

    const n = b.len;
    var prev = try alloc.alloc(u32, n + 1);
    defer alloc.free(prev);
    var cur = try alloc.alloc(u32, n + 1);
    defer alloc.free(cur);
    for (0..(n + 1)) |i| prev[i] = @intCast(i);
    var rows: usize = 1;
    while (rows <= a.len) : (rows += 1) {
        cur[0] = @intCast(rows);
        var row_min = cur[0];
        for (1..(n + 1)) |j| {
            const cost: u32 = if (std.ascii.toLower(a[rows - 1]) == std.ascii.toLower(b[j - 1])) 0 else 1;
            const v = @min(@min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + cost);
            cur[j] = v;
            if (v < row_min) row_min = v;
        }
        if (row_min > cap) return cap + 1;
        const t = prev;
        prev = cur;
        cur = t;
    }
    return if (prev[n] > cap) cap + 1 else prev[n];
}

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

/// Check if a tool is an exploration tool that should always remain available.
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

/// Filter relevant definitions for plan-aware tool selection.
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

    // Capability gates for media tools
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

/// Read SKILL.md (or sub-resource) of a skill.
/// Returns null if unable to read.
fn readSkillFile(alloc: Allocator, io: std.Io, skill_path: []const u8) ?[]u8 {
    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, skill_path, .{}) catch return null;
    defer file.close(io);
    const stat = file.stat(io) catch return null;
    if (stat.size == 0 or stat.size > skills_mod.MAX_SKILL_FILE) return null;
    const buf = alloc.alloc(u8, @intCast(stat.size)) catch return null;
    const n = utils.readAll(io, file, buf) catch {
        alloc.free(buf);
        return null;
    };
    return buf[0..n];
}

fn appendSubdirFiles(w: *utils.BufWriter, io: std.Io, dir_path: []const u8, sub: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    var parent = cwd.openDir(io, dir_path, .{}) catch return;
    defer parent.close(io);
    var child = parent.openDir(io, sub, .{ .iterate = true }) catch return;
    defer child.close(io);

    var it = child.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind == .file) {
            try w.print("  - `{s}/{s}`\n", .{ sub, entry.name });
        }
    }
}

fn formatSkillDetail(alloc: Allocator, io: std.Io, s: *const skills_mod.SkillInfo, content: []const u8) ![]u8 {
    var buf = utils.BufWriter.init(alloc);
    errdefer buf.deinit();

    try buf.print("## Skill: {s}\n\nPath: `{s}`\n", .{ s.name, s.path });
    if (s.version) |v| try buf.print("Version: {s}\n", .{v});
    if (s.author) |a| try buf.print("Author: {s}\n", .{a});
    if (s.platforms) |p| try buf.print("Platforms: {s}\n", .{p});
    if (s.requires_tools) |rt| try buf.print("Requires Tools: {s}\n", .{rt});
    try buf.writeAll("\n");

    if (s.has_references or s.has_templates or s.has_scripts) {
        try buf.writeAll("### Available Sub-Resources:\n");
        if (s.has_references) try appendSubdirFiles(&buf, io, s.dir_path, "references");
        if (s.has_templates) try appendSubdirFiles(&buf, io, s.dir_path, "templates");
        if (s.has_scripts) try appendSubdirFiles(&buf, io, s.dir_path, "scripts");
        try buf.writeAll("*(To view any sub-resource, call `skills` with `operation=\"detail\"` and `file_path=\"<relative-path>\"`)*\n\n");
    }

    try buf.writeAll(content);
    return buf.toOwnedSlice();
}

fn executeSkillDetail(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    // PSEUDOCODE:
    // 1. Extract required 'name' argument and optional 'file_path'.
    // 2. Search matched skill in skills_mod.
    // 3. If file_path provided, sanitize sub-path and return sub-resource content.
    // 4. If file_path omitted, return SKILL.md content + sub-resource manifest.
    // 5. Fallback to tool definitions in registry.
    const name = json.findString(input_json, "name") orelse
        return std.fmt.allocPrint(alloc, "Error: 'name' field required for detail operation", .{});
    const file_path = json.findString(input_json, "file_path");

    if (skills_mod.getSkills()) |skills| {
        for (skills) |*s| {
            if (std.mem.eql(u8, s.name, name)) {
                if (file_path) |sub| {
                    if (sub.len > 0) {
                        const target_path = skills_mod.sanitizeSkillSubPath(alloc, s.dir_path, sub) catch {
                            return std.fmt.allocPrint(alloc, "Security error: invalid or unauthorized sub-path '{s}'", .{sub});
                        };
                        defer alloc.free(target_path);
                        if (readSkillFile(alloc, io, target_path)) |content| {
                            defer alloc.free(content);
                            return std.fmt.allocPrint(
                                alloc,
                                "## Skill Resource: {s} ({s})\n\n{s}",
                                .{ s.name, sub, content },
                            );
                        }
                        return std.fmt.allocPrint(alloc, "Resource '{s}' not found in skill '{s}'.", .{ sub, s.name });
                    }
                }
                if (readSkillFile(alloc, io, s.path)) |content| {
                    defer alloc.free(content);
                    return formatSkillDetail(alloc, io, s, content);
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

pub fn executeSkills(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
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
///
/// Thread-safety: this may run on the watchdog/SIGINT thread while the agent
/// worker thread is blocked in readStreaming on the child's pipe fds.
/// Therefore we only signal the child process here; the pipe fds and
/// child.stdin/stdout are NOT touched cross-thread. The worker's read loop
/// bails via signals.isInterrupted() and the pipes are closed exactly once,
/// under the per-server mutex, from shutdown on the owning thread.
pub fn interruptActiveMcp() void {
    signals.setInterrupted(true);
    while (!g_registry_mutex.tryLock()) {}
    const mgr = g_mcp;
    g_registry_mutex.unlock();
    if (mgr) |m| {
        for (m.servers.items) |srv| {
            if (srv.child_pid > 0 and comptime builtin.os.tag != .windows) {
                _ = std.posix.kill(-srv.child_pid, std.posix.SIG.TERM) catch {
                    _ = std.posix.kill(srv.child_pid, std.posix.SIG.TERM) catch {};
                };
            }
        }
    }
}

/// Force kill active MCP server process group with SIGKILL (called on Watchdog escalation).
///
/// Thread-safety: same as interruptActiveMcp — only signal the child from
/// this thread; never touch the pipe fds or child.stdin/stdout cross-thread.
pub fn forceKillActiveMcp() void {
    signals.setInterrupted(true);
    while (!g_registry_mutex.tryLock()) {}
    const mgr = g_mcp;
    g_registry_mutex.unlock();
    if (mgr) |m| {
        for (m.servers.items) |srv| {
            if (srv.child_pid > 0 and comptime builtin.os.tag != .windows) {
                _ = std.posix.kill(-srv.child_pid, std.posix.SIG.KILL) catch {
                    _ = std.posix.kill(srv.child_pid, std.posix.SIG.KILL) catch {};
                };
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

test "registry: executeSkills sub-resource resolution and path traversal" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "skills/test-subres/references");
    try tmp.dir.writeFile(io, .{
        .sub_path = "skills/test-subres/SKILL.md",
        .data =
            \\---
            \\name: test-subres
            \\description: Testing sub resources
            \\---
            \\# Main Guide
        ,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "skills/test-subres/references/spec.md",
        .data = "# Reference Specification Content",
    });

    const real_tmp_path = try tmp.dir.realPathFileAlloc(io, "skills", alloc);
    defer alloc.free(real_tmp_path);

    var env_map = std.process.Environ.Map.init(alloc);
    defer env_map.deinit();
    try env_map.put("MINI_HOME", real_tmp_path[0 .. real_tmp_path.len - "/skills".len]);

    const loaded = skills_mod.loadSkills(alloc, io, &env_map);
    defer skills_mod.deinitSkills();
    try std.testing.expect(loaded >= 1);

    // 1. Query with valid file_path
    const query_valid = "{\"operation\":\"detail\",\"name\":\"test-subres\",\"file_path\":\"references/spec.md\"}";
    const out_valid = try executeSkills(alloc, io, query_valid);
    defer alloc.free(out_valid);
    try std.testing.expect(std.mem.indexOf(u8, out_valid, "Reference Specification Content") != null);

    // 2. Query with path traversal attack
    const query_bad = "{\"operation\":\"detail\",\"name\":\"test-subres\",\"file_path\":\"../secret.txt\"}";
    const out_bad = try executeSkills(alloc, io, query_bad);
    defer alloc.free(out_bad);
    try std.testing.expect(std.mem.indexOf(u8, out_bad, "Security error") != null);
}

