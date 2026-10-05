//! unicode.zig — UTF-8 utilities for UI: display width, grapheme cluster iteration.
//!
//! Addresses group 1: calculates display width according to East Asian Width,
//! iterates by grapheme cluster (base + combining marks + ZWJ sequences + variation
//! selectors) to prevent cursor misalignment when typing multibyte languages / emojis.

const std = @import("std");

/// UTF-8 byte length of codepoint starting with byte `b` (1..4). Returns 1 if byte is invalid.
pub fn utf8Len(b: u8) usize {
    return switch (b) {
        0b0000_0000...0b0111_1111 => 1,
        0b1100_0000...0b1101_1111 => 2,
        0b1110_0000...0b1110_1111 => 3,
        0b1111_0000...0b1111_0111 => 4,
        else => 1,
    };
}

/// Decode 1 codepoint from the beginning of slice. Returns (codepoint, consumed byte count).
fn decodeAt(s: []const u8) struct { cp: u21, len: usize } {
    if (s.len == 0) return .{ .cp = 0, .len = 0 };
    const n = utf8Len(s[0]);
    if (n > s.len) return .{ .cp = 0xFFFD, .len = s.len };
    const cp = std.unicode.utf8Decode(s[0..n]) catch return .{ .cp = 0xFFFD, .len = n };
    return .{ .cp = cp, .len = n };
}

/// Check if codepoint is a combining mark (Mn/Me/Mf) — zero-width.
fn isCombining(cp: u21) bool {
    return switch (cp) {
        0x0300...0x036F, // Combining Diacritical Marks
        0x0483...0x0489,
        0x0591...0x05BD,
        0x0610...0x061A,
        0x064B...0x065F,
        0x0670,
        0x06D6...0x06DC,
        0x0730...0x074A,
        0x07A6...0x07B0,
        0x0900...0x0903,
        0x093A...0x094F, // Includes Devanagari signs and virama (0x093A...0x094F)
        0x0951...0x0957,
        0x0E31,
        0x0E34...0x0E3A, // Thai vowels
        0x0E47...0x0E4E,
        0x1AB0...0x1AFF,
        0x1DC0...0x1DFF,
        0x20D0...0x20F0,
        0xFE00...0xFE0F, // Variation Selectors (emoji presentation)
        0xFE20...0xFE2F,
        0x101FD,
        0x1D167...0x1D169,
        0x1D17B...0x1D182,
        0x1F3FB...0x1F3FF, // Emoji skin tone modifiers — zero-width per UAX #11
        0xE0100...0xE01EF,
        => true, // Variation Selectors Supplement
        else => false,
    };
}

fn isZWJ(cp: u21) bool {
    return cp == 0x200D;
}

fn isJoinControl(cp: u21) bool {
    return cp == 0x200C or cp == 0x200D;
}

fn isBmpEmojiWide(cp: u21) bool {
    return switch (cp) {
        0x231A...0x231B, // watch, hourglass
        0x23E9...0x23EC,
        0x23F0,
        0x23F3,
        0x25FD...0x25FE,
        0x2614...0x2615,
        0x2648...0x2653,
        0x267F,
        0x2693,
        0x26A1,
        0x26AA...0x26AB,
        0x26BD...0x26BE,
        0x26C4...0x26C5,
        0x26CE,
        0x26D4,
        0x26EA,
        0x26F2...0x26F3,
        0x26F5,
        0x26FA,
        0x26FD,
        0x2705,
        0x270A...0x270B,
        0x2728,
        0x274C,
        0x274E,
        0x2753...0x2755,
        0x2757,
        0x2795...0x2797,
        0x27B0,
        0x27BF,
        0x2B1B...0x2B1C,
        0x2B50,
        0x2B55,
        => true,
        else => false,
    };
}

fn isSmpEmojiPart1(cp: u21) bool {
    return switch (cp) {
        0x1F004,
        0x1F0CF,
        0x1F18E,
        0x1F191...0x1F19A,
        0x1F1E6...0x1F1FF, // regional indicators (flags)
        0x1F201...0x1F202,
        0x1F21A,
        0x1F22F,
        0x1F232...0x1F23A,
        0x1F250...0x1F251,
        0x1F300...0x1F320,
        0x1F32D...0x1F335,
        0x1F337...0x1F37C,
        0x1F37E...0x1F393,
        0x1F3A0...0x1F3CA,
        0x1F3CF...0x1F3D3,
        0x1F3E0...0x1F3F0,
        0x1F3F4,
        0x1F3F8...0x1F43E,
        0x1F440,
        0x1F442...0x1F4FC,
        0x1F4FF...0x1F53D,
        0x1F54B...0x1F54E,
        0x1F550...0x1F567,
        0x1F57A,
        0x1F595...0x1F596,
        0x1F5A4,
        0x1F5FB...0x1F5FF,
        => true,
        else => false,
    };
}

fn isSmpEmojiPart2(cp: u21) bool {
    return switch (cp) {
        0x1F600...0x1F64F,
        0x1F680...0x1F6C5,
        0x1F6CC,
        0x1F6D0...0x1F6D2,
        0x1F6EB...0x1F6EC,
        0x1F6F4...0x1F6F9,
        0x1F910...0x1F93E,
        0x1F940...0x1F970,
        0x1F973...0x1F976,
        0x1F97A,
        0x1F97C...0x1F9A2,
        0x1F9B0...0x1F9B9,
        0x1F9C0...0x1F9C2,
        0x1F9D0...0x1F9FF,
        0x1FA70...0x1FA73,
        0x1FA78...0x1FA7A,
        0x1FA80...0x1FA82,
        0x1FA90...0x1FA95,
        => true,
        else => false,
    };
}

fn isSmpEmojiWide(cp: u21) bool {
    // PSEUDOCODE:
    // 1. Check if codepoint falls in first half of SMP emoji ranges
    // 2. Otherwise check second half of SMP emoji ranges
    return isSmpEmojiPart1(cp) or isSmpEmojiPart2(cp);
}

/// Check if codepoint belongs to emoji group (wide presentation, width 2).
fn isEmojiWide(cp: u21) bool {
    // PSEUDOCODE:
    // 1. If cp is in Basic Multilingual Plane (< 0x10000), check BMP emoji ranges.
    // 2. Otherwise check Supplementary Multilingual Plane emoji ranges.
    if (cp < 0x10000) return isBmpEmojiWide(cp);
    return isSmpEmojiWide(cp);
}

/// East Asian Wide / Fullwidth → width 2.
fn isEastAsianWide(cp: u21) bool {
    return switch (cp) {
        0x1100...0x115F, // Hangul Jamo
        0x2E80...0x303E, // CJK Radicals, Kangxi, CJK Symbols
        0x3041...0x33FF, // Hiragana..CJK Compatibility
        0x3400...0x4DBF, // CJK Ext A
        0x4E00...0x9FFF, // CJK Unified
        0xA000...0xA4CF, // Yi
        0xA960...0xA97F, // Hangul Jamo Extended-A
        0xAC00...0xD7A3, // Hangul Syllables
        0xF900...0xFAFF, // CJK Compatibility Ideographs
        0xFE10...0xFE19, // Vertical forms
        0xFE30...0xFE6F, // CJK Compatibility Forms, Small Form Variants
        0xFF00...0xFF60, // Fullwidth Forms
        0xFFE0...0xFFE6,
        0x1F300...0x1F64F, // emoji overlap (width 2)
        0x1F900...0x1F9FF,
        0x20000...0x2FFFD, // CJK Ext B..
        0x30000...0x3FFFD,
        => true,
        else => false,
    };
}

/// Display width of 1 grapheme cluster (computed from cluster starting with base cp).
pub fn clusterWidth(base_cp: u21) usize {
    if (base_cp == 0) return 0;
    if (isCombining(base_cp)) return 0;
    if (isJoinControl(base_cp)) return 0;
    if (base_cp == 0x200B) return 0; // ZWSP
    if (isEmojiWide(base_cp) or isEastAsianWide(base_cp)) return 2;
    // Control chars displayed as ^X → width 2, but rarely reached here.
    if (base_cp < 0x20 or base_cp == 0x7F) return 0;
    return 1;
}

/// Iterator by grapheme cluster in a UTF-8 slice.
/// Cluster = base + combining marks / ZWJ + next cp / variation selector.
pub const GraphemeIterator = struct {
    s: []const u8,
    i: usize,

    pub fn init(s: []const u8) GraphemeIterator {
        return .{ .s = s, .i = 0 };
    }

    /// Returns next cluster, null when done.
    pub fn next(self: *GraphemeIterator) ?[]const u8 {
        if (self.i >= self.s.len) return null;
        const start = self.i;
        const d = decodeAt(self.s[self.i..]);
        self.i += d.len;

        // Regional indicator pair (flags) = 2 consecutive RIs
        if (d.cp >= 0x1F1E6 and d.cp <= 0x1F1FF) {
            if (self.i < self.s.len) {
                const d2 = decodeAt(self.s[self.i..]);
                if (d2.cp >= 0x1F1E6 and d2.cp <= 0x1F1FF) self.i += d2.len;
            }
            return self.s[start..self.i];
        }

        while (self.i < self.s.len) {
            const peek = decodeAt(self.s[self.i..]);
            if (isCombining(peek.cp)) {
                self.i += peek.len;
                continue;
            }
            if (isZWJ(peek.cp)) {
                // ZWJ + next grapheme belongs to same cluster
                self.i += peek.len;
                if (self.i < self.s.len) {
                    const after = decodeAt(self.s[self.i..]);
                    self.i += after.len;
                    // and combining marks following it
                    continue;
                }
                break;
            }
            break;
        }
        return self.s[start..self.i];
    }
};

/// Display width of entire string.
pub fn displayWidth(s: []const u8) usize {
    var w: usize = 0;
    var it = GraphemeIterator.init(s);
    while (it.next()) |cluster| {
        const d = decodeAt(cluster);
        // VS16 (U+FE0F) in cluster → emoji presentation, promote width to 2 (UAX #11)
        if (containsVS16(cluster[d.len..])) {
            w += 2;
        } else {
            w += clusterWidth(d.cp);
        }
        // ZWJ sequence: cluster contains multiple bases but only counts width of first base
        // (already added above) — portion after ZWJ does not add further width.
    }
    return w;
}

/// Calculate actual display width on terminal, automatically ignoring ANSI escape sequences (colors, cursor control...).
pub fn visibleWidth(s: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b) {
            // Skip ANSI sequence: \x1b[...]
            i += 1;
            if (i < s.len and (s[i] == '[' or s[i] == '(' or s[i] == ')')) {
                i += 1;
                while (i < s.len) : (i += 1) {
                    const c = s[i];
                    if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '~') {
                        i += 1;
                        break;
                    }
                }
            }
            continue;
        }
        const cluster_len = clusterLenAt(s, i);
        const cluster = s[i .. i + cluster_len];
        const d = decodeAt(cluster);
        if (containsVS16(cluster[d.len..])) {
            w += 2;
        } else {
            w += clusterWidth(d.cp);
        }
        i += cluster_len;
    }
    return w;
}

/// Check if slice contains U+FE0F (VS16, encoded UTF-8: EF B8 8F).
fn containsVS16(s: []const u8) bool {
    return std.mem.indexOf(u8, s, "\xEF\xB8\x8F") != null;
}

/// Byte count of grapheme cluster starting at `i` (extended across combining/ZWJ).
pub fn clusterLenAt(s: []const u8, i: usize) usize {
    var it = GraphemeIterator.init(s[i..]);
    const c = it.next() orelse return 1;
    return c.len;
}

/// Check if codepoint belongs to the continuation portion of preceding grapheme cluster
/// (combining mark, join control ZWJ/ZWNJ, variation selector, skin tone modifier).
/// Used when backspacing cursor across cluster: encountering this cp requires continuing leftward.
pub fn isContinuationCp(cp: u21) bool {
    if (isCombining(cp)) return true;
    if (isJoinControl(cp)) return true;
    if (cp == 0x200B) return true; // ZWSP attaches to preceding cluster
    return false;
}

/// Character class used for word motion.
pub const CharClass = enum { space, word, punct };

pub fn charClass(cp: u21) CharClass {
    if (cp == ' ' or cp == '\t' or cp == '\n' or cp == '\r') return .space;
    if (isWordChar(cp)) return .word;
    return .punct;
}

fn isWordChar(cp: u21) bool {
    if (cp < 0x80) {
        return (cp >= 'a' and cp <= 'z') or (cp >= 'A' and cp <= 'Z') or (cp >= '0' and cp <= '9') or cp == '_';
    }
    // Latin Extended, Greek, Cyrillic, CJK... considered words
    return switch (cp) {
        0xC0...0x24F, // Latin Extended
        0x0370...0x03FF, // Greek
        0x0400...0x04FF, // Cyrillic
        0x4E00...0x9FFF,
        0x3040...0x30FF,
        0xAC00...0xD7A3,
        => true,
        else => !isCombining(cp) and !isEmojiWide(cp) and cp >= 0x80,
    };
}

test "displayWidth ASCII" {
    try std.testing.expectEqual(@as(usize, 5), displayWidth("hello"));
}

test "displayWidth Vietnamese" {
    // "tết" = 3 graphemes (t, ế, t), each with width 1 → 3
    try std.testing.expectEqual(@as(usize, 3), displayWidth("t\u{1EBF}t"));
}

test "displayWidth Vietnamese decomposed" {
    // e + circumflex + acute = 1 cluster width 1
    try std.testing.expectEqual(@as(usize, 3), displayWidth("t\u{0065}\u{0302}\u{0301}t"));
}

test "displayWidth CJK" {
    try std.testing.expectEqual(@as(usize, 10), displayWidth("こんにちは"));
}

test "displayWidth emoji VS16 presentation" {
    // ❤ + VS16 → emoji presentation, width 2
    try std.testing.expectEqual(@as(usize, 2), displayWidth("\u{2764}\u{FE0F}"));
}

test "displayWidth emoji skin tone" {
    // 👍 + skin tone modifier = 1 cluster, width 2
    try std.testing.expectEqual(@as(usize, 2), displayWidth("\u{1F44D}\u{1F3FD}"));
}

test "displayWidth flag emoji" {
    // 🇻🇳 = 2 regional indicators = 1 cluster, width 2
    try std.testing.expectEqual(@as(usize, 2), displayWidth("\u{1F1FB}\u{1F1F3}"));
}

test "displayWidth emoji ZWJ family" {
    // family emoji = 4 people joined by ZWJ → width 2 (1 cluster)
    try std.testing.expectEqual(@as(usize, 2), displayWidth("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"));
}

test "grapheme count Vietnamese" {
    // "tết" — ế can be 1 precomposed codepoint or e + marks
    const s1 = "t\u{1EBF}t";
    var it1 = GraphemeIterator.init(s1);
    var n: usize = 0;
    while (it1.next() != null) n += 1;
    try std.testing.expectEqual(@as(usize, 3), n);
}

test "visibleWidth strips ANSI escapes" {
    try std.testing.expectEqual(@as(usize, 6), visibleWidth("\x1b[1;34mYou\x1b[0m > "));
    try std.testing.expectEqual(@as(usize, 5), visibleWidth("\x1b[31mhello\x1b[0m"));
}
