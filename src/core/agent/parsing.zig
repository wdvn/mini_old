//! Response/text parsing utilities for the agent loop.
//! Extracted from agent.zig: JS code-block extraction, XML tool-tag
//! conversion, and watchdog timeout decision parsing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("../protocol.zig");
const json_mod = @import("../json.zig");
const utils = @import("../utils.zig");
const watchdog_mod = @import("../watchdog.zig");

pub fn extractJsCodeBlock(alloc: Allocator, text: []const u8) ?[]const u8 {
    var search_idx: usize = 0;
    while (search_idx < text.len) {
        const fence_pos = std.mem.indexOfPos(u8, text, search_idx, "```") orelse break;
        const tag_start = fence_pos + 3;
        var tag_end = tag_start;
        while (tag_end < text.len and text[tag_end] != '\n' and text[tag_end] != '\r') : (tag_end += 1) {}
        const lang = std.mem.trim(u8, text[tag_start..tag_end], " \t");

        // Check if language tag is javascript or js
        if (std.ascii.eqlIgnoreCase(lang, "js") or std.ascii.eqlIgnoreCase(lang, "javascript")) {
            var code_start = tag_end;
            if (code_start < text.len and text[code_start] == '\r') code_start += 1;
            if (code_start < text.len and text[code_start] == '\n') code_start += 1;

            if (std.mem.indexOfPos(u8, text, code_start, "```")) |end_pos| {
                const code = text[code_start..end_pos];
                const trimmed = std.mem.trim(u8, code, " \r\n\t");
                if (trimmed.len > 0) {
                    return alloc.dupe(u8, trimmed) catch null;
                }
            }
        }
        search_idx = tag_start;
    }
    return null;
}

fn extractXmlAttr(tag_str: []const u8, attr_name: []const u8) ?[]const u8 {
    var search_buf: [64]u8 = undefined;
    const pat = std.fmt.bufPrint(&search_buf, "{s}=\"", .{attr_name}) catch return null;
    if (std.mem.indexOf(u8, tag_str, pat)) |start_idx| {
        const val_start = start_idx + pat.len;
        if (std.mem.indexOfPos(u8, tag_str, val_start, "\"")) |val_end| {
            return tag_str[val_start..val_end];
        }
    }
    const pat_sq = std.fmt.bufPrint(&search_buf, "{s}='", .{attr_name}) catch return null;
    if (std.mem.indexOf(u8, tag_str, pat_sq)) |start_sq| {
        const val_start = start_sq + pat_sq.len;
        if (std.mem.indexOfPos(u8, tag_str, val_start, "'")) |val_end| {
            return tag_str[val_start..val_end];
        }
    }
    return null;
}

fn findMatchedXmlTag(text: []const u8, tag_start: usize) ?struct { name: []const u8, str: []const u8, end: usize } {
    // PSEUDOCODE: Match known XML tag prefix at tag_start + 1 and find closing '>'.
    const tag_names = [_][]const u8{ "file_read", "glob", "grep", "bash", "file_write", "file_edit", "http_request" };
    var matched_tag: ?[]const u8 = null;
    for (tag_names) |tn| {
        if (std.mem.startsWith(u8, text[tag_start + 1 ..], tn)) {
            matched_tag = tn;
            break;
        }
    }
    const tn = matched_tag orelse return null;
    const tag_end = std.mem.indexOfPos(u8, text, tag_start, ">") orelse return null;
    return .{
        .name = tn,
        .str = text[tag_start .. tag_end + 1],
        .end = tag_end + 1,
    };
}

fn emitJsForXmlTag(alloc: Allocator, js_buf: *utils.BufWriter, tag_name: []const u8, tag_str: []const u8) void {
    // PSEUDOCODE: Extract attributes for tag_name and emit formatted mini.* JavaScript calls.
    if (std.mem.eql(u8, tag_name, "file_read")) {
        const file_path = extractXmlAttr(tag_str, "file") orelse extractXmlAttr(tag_str, "path") orelse "";
        if (file_path.len > 0) {
            const escaped = json_mod.escape(alloc, file_path) catch return;
            defer alloc.free(escaped);
            js_buf.print("console.log('=== file_read: ' + \"{s}\" + ' ===');\nconsole.log(mini.read(\"{s}\"));\n", .{ escaped, escaped }) catch {};
        }
    } else if (std.mem.eql(u8, tag_name, "glob")) {
        const pattern = extractXmlAttr(tag_str, "pattern") orelse "*";
        const path = extractXmlAttr(tag_str, "path") orelse ".";
        const esc_pat = json_mod.escape(alloc, pattern) catch return;
        defer alloc.free(esc_pat);
        const esc_path = json_mod.escape(alloc, path) catch return;
        defer alloc.free(esc_path);
        js_buf.print("console.log('=== glob: ' + \"{s}\" + ' ===');\nconsole.log(JSON.stringify(mini.glob(\"{s}\", \"{s}\")));\n", .{ esc_pat, esc_pat, esc_path }) catch {};
    } else if (std.mem.eql(u8, tag_name, "grep")) {
        const pattern = extractXmlAttr(tag_str, "pattern") orelse "";
        const path = extractXmlAttr(tag_str, "path") orelse ".";
        const esc_pat = json_mod.escape(alloc, pattern) catch return;
        defer alloc.free(esc_pat);
        const esc_path = json_mod.escape(alloc, path) catch return;
        defer alloc.free(esc_path);
        js_buf.print("console.log('=== grep: ' + \"{s}\" + ' ===');\nconsole.log(JSON.stringify(mini.grep(\"{s}\", \"{s}\")));\n", .{ esc_pat, esc_pat, esc_path }) catch {};
    } else if (std.mem.eql(u8, tag_name, "bash")) {
        const cmd = extractXmlAttr(tag_str, "command") orelse extractXmlAttr(tag_str, "cmd") orelse "";
        if (cmd.len > 0) {
            const esc_cmd = json_mod.escape(alloc, cmd) catch return;
            defer alloc.free(esc_cmd);
            js_buf.print("console.log('=== bash: ' + \"{s}\" + ' ===');\nconst r = mini.sh(\"{s}\");\nconsole.log(r.stdout);\nif (r.stderr) console.log('stderr: ' + r.stderr);\n", .{ esc_cmd, esc_cmd }) catch {};
        }
    } else if (std.mem.eql(u8, tag_name, "file_write")) {
        const path = extractXmlAttr(tag_str, "path") orelse extractXmlAttr(tag_str, "file") orelse "";
        const content = extractXmlAttr(tag_str, "content") orelse "";
        if (path.len > 0) {
            const esc_path = json_mod.escape(alloc, path) catch return;
            defer alloc.free(esc_path);
            const esc_content = json_mod.escape(alloc, content) catch return;
            defer alloc.free(esc_content);
            js_buf.print("mini.write(\"{s}\", \"{s}\");\nconsole.log('file written: {s}');\n", .{ esc_path, esc_content, esc_path }) catch {};
        }
    }
}

/// Converts pseudo XML tool tags (<file_read>, <glob>, <grep>, <bash>, <file_write>) into mini.* JS code.
pub fn convertXmlToolTagsToJs(alloc: Allocator, text: []const u8) ?[]const u8 {
    // PSEUDOCODE:
    // 1. Scan text for XML tool tags.
    // 2. Emit corresponding mini.* JS calls into buffer.
    // 3. Return owned JS string or null if no tags matched.
    var js_buf = utils.BufWriter.init(alloc);
    errdefer js_buf.deinit();

    var has_tags = false;
    var pos: usize = 0;

    while (pos < text.len) {
        const tag_start = std.mem.indexOfPos(u8, text, pos, "<") orelse break;
        pos = tag_start + 1;

        const tag = findMatchedXmlTag(text, tag_start) orelse continue;
        pos = tag.end;
        has_tags = true;
        emitJsForXmlTag(alloc, &js_buf, tag.name, tag.str);
    }

    if (!has_tags or js_buf.list.items.len == 0) {
        js_buf.deinit();
        return null;
    }

    return js_buf.toOwnedSlice() catch null;
}

/// Searches for JavaScript code block in Assistant response
pub fn findJsCodeInResponse(alloc: Allocator, response: *const proto.Response) ?[]const u8 {
    for (response.content.items) |block| {
        switch (block) {
            .text => |t| {
                if (extractJsCodeBlock(alloc, t)) |code| return code;
            },
            else => {},
        }
    }
    for (response.content.items) |block| {
        switch (block) {
            .text => |t| {
                if (convertXmlToolTagsToJs(alloc, t)) |code| return code;
            },
            else => {},
        }
    }
    return null;
}

fn parseWaitSeconds(line: []const u8) ?u32 {
    // PSEUDOCODE: Extract optional numeric seconds following "WAIT" in line.
    var word_it = std.mem.tokenizeAny(u8, line, " :,\t*#_`");
    while (word_it.next()) |w| {
        if (!std.ascii.eqlIgnoreCase(w, "wait")) continue;
        const num_str = word_it.next() orelse break;
        const digits_end = for (num_str, 0..) |c, i| {
            if (c < '0' or c > '9') break i;
        } else num_str.len;
        if (digits_end > 0) {
            if (std.fmt.parseInt(u32, num_str[0..digits_end], 10)) |secs| {
                return std.math.clamp(secs, 10, 300);
            } else |_| {}
        }
        break;
    }
    return null;
}

fn extractReasonFromLine(line: []const u8, decision: *watchdog_mod.TimeoutDecision) bool {
    // PSEUDOCODE: If line contains "REASON:" or decision reason is empty, store in reason_buf.
    if (std.ascii.startsWithIgnoreCase(line, "REASON:") or std.ascii.startsWithIgnoreCase(line, "REASON :")) {
        const colon_idx = std.mem.indexOfScalar(u8, line, ':') orelse 0;
        const r = std.mem.trim(u8, line[colon_idx + 1 ..], " \t*#_`");
        const copy_len = @min(r.len, decision.reason_buf.len);
        @memcpy(decision.reason_buf[0..copy_len], r[0..copy_len]);
        decision.reason_len = copy_len;
        return true;
    } else if (decision.reason_len == 0) {
        const copy_len = @min(line.len, decision.reason_buf.len);
        @memcpy(decision.reason_buf[0..copy_len], line[0..copy_len]);
        decision.reason_len = copy_len;
    }
    return false;
}

fn parseDecisionLine(line: []const u8, decision: *watchdog_mod.TimeoutDecision) bool {
    // PSEUDOCODE: Check for KILL or WAIT decisions in line. Return true if decision found.
    if (std.ascii.indexOfIgnoreCase(line, "KILL") != null) {
        if (std.ascii.indexOfIgnoreCase(line, "NOT KILL") == null and
            std.ascii.indexOfIgnoreCase(line, "DON'T KILL") == null and
            std.ascii.indexOfIgnoreCase(line, "DONT KILL") == null)
        {
            decision.should_kill = true;
            return true;
        }
    }
    if (std.ascii.indexOfIgnoreCase(line, "WAIT") != null) {
        decision.should_kill = false;
        if (parseWaitSeconds(line)) |secs| decision.extend_seconds = secs;
        return true;
    }
    return false;
}

/// Parses LLM response into a structured TimeoutDecision.
pub fn parseTimeoutDecision(text: []const u8) watchdog_mod.TimeoutDecision {
    // PSEUDOCODE:
    // 1. Iterate lines looking for decision (KILL/WAIT) then reason.
    // 2. Fall back to default reason if none provided.
    var decision = watchdog_mod.TimeoutDecision{
        .should_kill = false,
        .extend_seconds = 60,
    };
    var line_it = std.mem.splitScalar(u8, text, '\n');
    var found_decision = false;

    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t*#_`");
        if (line.len == 0) continue;

        if (!found_decision) {
            found_decision = parseDecisionLine(line, &decision);
            if (found_decision) continue;
        }

        if (extractReasonFromLine(line, &decision)) break;
    }

    if (decision.reason_len == 0) {
        const default_reason = if (decision.should_kill) "Action declared hung by LLM supervisor" else "Action granted extended execution time by LLM supervisor";
        const copy_len = @min(default_reason.len, decision.reason_buf.len);
        @memcpy(decision.reason_buf[0..copy_len], default_reason[0..copy_len]);
        decision.reason_len = copy_len;
    }

    return decision;
}
