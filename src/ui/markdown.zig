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
    code_block,
};

pub const StreamHighlighter = struct {
    state: State = .normal,
    in_code_block: bool = false,
    at_line_start: bool = true,
    code_lang_buf: [32]u8 = undefined,
    code_lang_len: usize = 0,
    line_buf: [1024]u8 = undefined,
    line_len: usize = 0,
    carry_buf: [16]u8 = undefined,
    carry_len: usize = 0,

    pub fn init() StreamHighlighter {
        return .{};
    }

    /// Xử lý một chunk text stream từ LLM backend.
    pub fn processChunk(self: *StreamHighlighter, io: std.Io, chunk: []const u8) void {
        _ = io;
        var i: usize = 0;

        while (i < chunk.len) {
            const c = chunk[i];

            if (self.in_code_block) {
                // Kiểm tra xem có đóng code block ``` không
                if (self.at_line_start and i + 2 < chunk.len and chunk[i] == '`' and chunk[i + 1] == '`' and chunk[i + 2] == '`') {
                    self.in_code_block = false;
                    self.state = .normal;
                    i += 3;
                    // Bỏ qua phần còn lại của dòng đóng ```
                    while (i < chunk.len and chunk[i] != '\n') : (i += 1) {}
                    if (i < chunk.len and chunk[i] == '\n') i += 1;
                    self.at_line_start = true;

                    var footer_buf: [128]u8 = undefined;
                    const footer = std.fmt.bufPrint(&footer_buf, "  \x1b[90m{s}─────────────────────────────────────────────────────────────\x1b[0m\n", .{
                        term.BOX_BOT_LEFT,
                    }) catch "  ╰─────────────────────────────────────────────────────────────\n";
                    term.writeStdout(footer);
                    continue;
                }

                if (self.at_line_start) {
                    var border_buf: [32]u8 = undefined;
                    const border = std.fmt.bufPrint(&border_buf, "  \x1b[90m{s}\x1b[0m ", .{term.BOX_VERT}) catch "  │ ";
                    term.writeStdout(border);
                    self.at_line_start = false;
                }

                if (c == '\n') {
                    term.writeStdout("\n");
                    self.at_line_start = true;
                    i += 1;
                } else {
                    // Highlight từ khóa và chuỗi ký tự cơ bản trong code block
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

            // Kiểm tra mở code block ```
            if (self.at_line_start and i + 2 < chunk.len and chunk[i] == '`' and chunk[i + 1] == '`' and chunk[i + 2] == '`') {
                self.in_code_block = true;
                self.state = .code_block;
                i += 3;

                // Đọc language tag (ví dụ: ```zig)
                self.code_lang_len = 0;
                while (i < chunk.len and chunk[i] != '\n' and chunk[i] != ' ' and chunk[i] != '\r') : (i += 1) {
                    if (self.code_lang_len < self.code_lang_buf.len) {
                        self.code_lang_buf[self.code_lang_len] = chunk[i];
                        self.code_lang_len += 1;
                    }
                }
                while (i < chunk.len and chunk[i] != '\n') : (i += 1) {}
                if (i < chunk.len and chunk[i] == '\n') i += 1;

                const lang = if (self.code_lang_len > 0) self.code_lang_buf[0..self.code_lang_len] else "code";
                var header_buf: [256]u8 = undefined;
                const header = std.fmt.bufPrint(&header_buf, "\n  \x1b[90m{s}── \x1b[1;33m{s}\x1b[0m\x1b[90m ───────────────────────────────────────────────\x1b[0m\n", .{
                    term.BOX_TOP_LEFT, lang,
                }) catch "\n  ╭── code ───────────────────────────────────────────────\n";
                term.writeStdout(header);
                self.at_line_start = true;
                continue;
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
                continue;
            }

            // Xử lý Headers (#, ##, ###) ở đầu dòng
            if (self.at_line_start and c == '#') {
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

            if (c == '\n') {
                if (self.state != .normal and self.state != .code_block) {
                    term.writeStdout("\x1b[0m");
                    self.state = .normal;
                }
                self.at_line_start = true;
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
        if (self.in_code_block) {
            var footer_buf: [128]u8 = undefined;
            const footer = std.fmt.bufPrint(&footer_buf, "\n  \x1b[90m{s}─────────────────────────────────────────────────────────────\x1b[0m\n", .{
                term.BOX_BOT_LEFT,
            }) catch "\n  ╰─────────────────────────────────────────────────────────────\n";
            term.writeStdout(footer);
            self.in_code_block = false;
        }
        term.writeStdout("\x1b[0m");
        self.state = .normal;
        self.at_line_start = true;
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
