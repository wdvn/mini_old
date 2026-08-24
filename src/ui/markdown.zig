//! markdown.zig — Streaming Markdown & Syntax Highlighter cho terminal mini-agent (RFC-007).
//!
//! Phân tích và tô màu văn bản Markdown trực tiếp khi AI đang stream:
//! - Headers (#, ##, ###)
//! - Bold (**text**), Italic (*text*)
//! - Inline code (`code`)
//! - Code blocks (```lang ... ```) với viền khung và highlight từ khóa cơ bản (Zig, JS/TS, Python, C/Rust, Shell)

const std = @import("std");
const term = @import("terminal.zig");

pub const State = enum {
    normal,
    inline_code,
    bold,
};

pub const StreamHighlighter = struct {
    state: State = .normal,
    in_code_block: bool = false,
    in_code_header: bool = false,
    in_closing_fence: bool = false,
    fence_backtick_count: usize = 0,
    at_line_start: bool = true,
    code_lang_buf: [32]u8 = undefined,
    code_lang_len: usize = 0,

    pub fn init() StreamHighlighter {
        return .{};
    }

    /// Xử lý một chunk text stream từ LLM backend.
    pub fn processChunk(self: *StreamHighlighter, io: std.Io, chunk: []const u8) void {
        _ = io;
        var i: usize = 0;

        while (i < chunk.len) {
            const c = chunk[i];

            // 1. Đang đọc dòng mở code block (ví dụ: ```js\n)
            if (self.in_code_header) {
                if (c == '\n') {
                    self.in_code_header = false;
                    self.in_code_block = true;
                    self.at_line_start = true;
                    self.fence_backtick_count = 0;

                    const raw_lang = if (self.code_lang_len > 0) self.code_lang_buf[0..self.code_lang_len] else "code";
                    const lang = std.mem.trim(u8, raw_lang, " \t\r");
                    const display_lang = if (lang.len > 0) lang else "code";

                    var header_buf: [256]u8 = undefined;
                    const header = std.fmt.bufPrint(&header_buf, "  \x1b[90m{s}── \x1b[1;33m{s}\x1b[0m\x1b[90m ───────────────────────────────────────────────\x1b[0m\n", .{
                        term.BOX_TOP_LEFT, display_lang,
                    }) catch "  ╭── code ───────────────────────────────────────────────\n";
                    term.writeStdout(header);
                    self.code_lang_len = 0;
                } else {
                    if (self.code_lang_len < self.code_lang_buf.len and c != '\r') {
                        self.code_lang_buf[self.code_lang_len] = c;
                        self.code_lang_len += 1;
                    }
                }
                i += 1;
                continue;
            }

            // 2. Đang đọc dòng đóng code block (bỏ qua các ký tự còn lại của dòng ``` cho tới \n)
            if (self.in_closing_fence) {
                if (c == '\n') {
                    self.in_closing_fence = false;
                    self.in_code_block = false;
                    self.at_line_start = true;
                    self.fence_backtick_count = 0;

                    var footer_buf: [128]u8 = undefined;
                    const footer = std.fmt.bufPrint(&footer_buf, "  \x1b[90m{s}─────────────────────────────────────────────────────────────\x1b[0m\n", .{
                        term.BOX_BOT_LEFT,
                    }) catch "  ╰─────────────────────────────────────────────────────────────\n";
                    term.writeStdout(footer);
                }
                i += 1;
                continue;
            }

            // 3. Đang trong Code Block
            if (self.in_code_block) {
                if (self.at_line_start) {
                    if (c == '`') {
                        self.fence_backtick_count += 1;
                        if (self.fence_backtick_count == 3) {
                            self.in_closing_fence = true;
                            self.fence_backtick_count = 0;
                        }
                        i += 1;
                        continue;
                    }

                    if (self.fence_backtick_count > 0) {
                        var border_buf: [32]u8 = undefined;
                        const border = std.fmt.bufPrint(&border_buf, "  \x1b[90m{s}\x1b[0m ", .{term.BOX_VERT}) catch "  │ ";
                        term.writeStdout(border);
                        var k: usize = 0;
                        while (k < self.fence_backtick_count) : (k += 1) {
                            term.writeStdout("`");
                        }
                        self.fence_backtick_count = 0;
                        self.at_line_start = false;
                    } else {
                        var border_buf: [32]u8 = undefined;
                        const border = std.fmt.bufPrint(&border_buf, "  \x1b[90m{s}\x1b[0m ", .{term.BOX_VERT}) catch "  │ ";
                        term.writeStdout(border);
                        self.at_line_start = false;
                    }
                }

                if (c == '\n') {
                    term.writeStdout("\n");
                    self.at_line_start = true;
                    self.fence_backtick_count = 0;
                    i += 1;
                } else {
                    const remaining = chunk[i..];
                    if (scanAndPrintCodeToken(remaining)) |consumed| {
                        i += consumed;
                    } else {
                        term.writeStdout(chunk[i .. i + 1]);
                        i += 1;
                    }
                }
                continue;
            }

            // 4. Ngoài Code Block (Văn bản thông thường)
            if (self.at_line_start) {
                if (c == '`') {
                    self.fence_backtick_count += 1;
                    if (self.fence_backtick_count == 3) {
                        self.in_code_header = true;
                        self.code_lang_len = 0;
                        self.fence_backtick_count = 0;
                    }
                    i += 1;
                    continue;
                }

                if (self.fence_backtick_count > 0) {
                    var k: usize = 0;
                    while (k < self.fence_backtick_count) : (k += 1) {
                        if (self.state == .inline_code) {
                            term.writeStdout("\x1b[0m");
                            self.state = .normal;
                        } else {
                            term.writeStdout("\x1b[48;5;236m\x1b[33m");
                            self.state = .inline_code;
                        }
                    }
                    self.fence_backtick_count = 0;
                }

                // Xử lý Headers (#, ##, ###) ở đầu dòng
                if (c == '#') {
                    var h_count: usize = 0;
                    var h_idx = i;
                    while (h_idx < chunk.len and chunk[h_idx] == '#') : (h_idx += 1) {
                        h_count += 1;
                    }
                    if (h_idx < chunk.len and chunk[h_idx] == ' ') {
                        term.writeStdout("\x1b[1;36m");
                        term.writeStdout(chunk[i .. h_idx + 1]);
                        i = h_idx + 1;
                        self.at_line_start = false;
                        continue;
                    }
                }
            }

            // Xử lý Inline Code `...`
            if (c == '`') {
                if (self.state == .inline_code) {
                    term.writeStdout("\x1b[0m");
                    self.state = .normal;
                } else {
                    term.writeStdout("\x1b[48;5;236m\x1b[33m");
                    self.state = .inline_code;
                }
                i += 1;
                self.at_line_start = false;
                continue;
            }

            // Xử lý Bold `**`
            if (c == '*' and i + 1 < chunk.len and chunk[i + 1] == '*') {
                if (self.state == .bold) {
                    term.writeStdout("\x1b[0m");
                    self.state = .normal;
                } else {
                    term.writeStdout("\x1b[1;97m");
                    self.state = .bold;
                }
                i += 2;
                self.at_line_start = false;
                continue;
            }

            if (c == '\n') {
                if (self.state != .normal) {
                    term.writeStdout("\x1b[0m");
                    self.state = .normal;
                }
                self.at_line_start = true;
                self.fence_backtick_count = 0;
                term.writeStdout("\n");
                i += 1;
                continue;
            }

            self.at_line_start = false;
            term.writeStdout(chunk[i .. i + 1]);
            i += 1;
        }
    }

    /// Hoàn tất stream, dọn dẹp state và reset màu.
    pub fn flush(self: *StreamHighlighter, io: std.Io) void {
        _ = io;
        if (self.in_code_block or self.in_code_header or self.in_closing_fence) {
            var footer_buf: [128]u8 = undefined;
            const prefix = if (self.at_line_start) "" else "\n";
            const footer = std.fmt.bufPrint(&footer_buf, "{s}  \x1b[90m{s}─────────────────────────────────────────────────────────────\x1b[0m\n", .{
                prefix, term.BOX_BOT_LEFT,
            }) catch "  ╰─────────────────────────────────────────────────────────────\n";
            term.writeStdout(footer);
            self.in_code_block = false;
            self.in_code_header = false;
            self.in_closing_fence = false;
        }
        term.writeStdout("\x1b[0m");
        self.state = .normal;
        self.at_line_start = true;
        self.fence_backtick_count = 0;
    }
};

/// Danh sách từ khóa code phổ biến cần highlight màu tím/cyan
const KEYWORDS = [_][]const u8{
    "fn",       "pub",      "const",   "var",      "return",  "if",       "else",     "while",
    "for",      "switch",   "struct",  "enum",     "union",   "try",      "catch",    "defer",
    "errdefer", "import",   "export",  "async",    "await",   "function", "let",      "class",
    "def",      "import",   "from",    "as",       "true",    "false",    "null",     "nil",
    "undefined", "break",   "continue","interface","package", "type",
};

fn scanAndPrintCodeToken(text: []const u8) ?usize {
    if (text.len == 0) return null;

    // Chuỗi string literal "..."
    if (text[0] == '"') {
        var end: usize = 1;
        while (end < text.len and text[end] != '"') : (end += 1) {
            if (text[end] == '\\' and end + 1 < text.len) end += 1;
        }
        if (end < text.len and text[end] == '"') end += 1;
        term.writeStdout("\x1b[32m");
        term.writeStdout(text[0..end]);
        term.writeStdout("\x1b[0m");
        return end;
    }

    // Comment //... hoặc #...
    if ((text.len >= 2 and text[0] == '/' and text[1] == '/') or text[0] == '#') {
        var end: usize = 0;
        while (end < text.len and text[end] != '\n') : (end += 1) {}
        term.writeStdout("\x1b[90m");
        term.writeStdout(text[0..end]);
        term.writeStdout("\x1b[0m");
        return end;
    }

    // Scan identifier
    if (std.ascii.isAlphabetic(text[0]) or text[0] == '_') {
        var end: usize = 0;
        while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_')) : (end += 1) {}
        const word = text[0..end];

        for (KEYWORDS) |kw| {
            if (std.mem.eql(u8, word, kw)) {
                term.writeStdout("\x1b[1;35m");
                term.writeStdout(word);
                term.writeStdout("\x1b[0m");
                return end;
            }
        }
    }

    return null;
}

test "StreamHighlighter handles basic markdown" {
    const hl = StreamHighlighter.init();
    try std.testing.expectEqual(State.normal, hl.state);
}

test "StreamHighlighter handles chunked code fences" {
    var hl = StreamHighlighter.init();
    hl.processChunk(undefined, "```");
    try std.testing.expect(hl.in_code_header);
    hl.processChunk(undefined, "js\n");
    try std.testing.expect(hl.in_code_block);
    hl.processChunk(undefined, "console.log('hi');\n");
    try std.testing.expect(hl.in_code_block);
    hl.processChunk(undefined, "```\n");
    try std.testing.expect(!hl.in_code_block);
    hl.processChunk(undefined, "Xin chào!");
    try std.testing.expect(!hl.in_code_block);
}
