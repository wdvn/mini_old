const std = @import("std");
const unicode = @import("src/ui/unicode.zig");
const history = @import("src/ui/history.zig");

test "unicode: grapheme count VN decomposed" {
    const s = "t\u{0065}\u{0302}\u{0301}t"; // t e + circumflex + acute t
    var it = unicode.GraphemeIterator.init(s);
    var n: usize = 0;
    while (it.next() != null) n += 1;
    try std.testing.expectEqual(@as(usize, 3), n);
}

test "unicode: displayWidth decomposed tet" {
    // t + (e + circumflex + acute = 1 cluster) + t = 3
    try std.testing.expectEqual(@as(usize, 3), unicode.displayWidth("t\u{0065}\u{0302}\u{0301}t"));
}

test "unicode: displayWidth flag emoji" {
    // VN flag = 2 regional indicators -> 1 cluster, width 2
    try std.testing.expectEqual(@as(usize, 2), unicode.displayWidth("\u{1F1FB}\u{1F1F3}"));
}

test "unicode: displayWidth heart + VS16" {
    try std.testing.expectEqual(@as(usize, 2), unicode.displayWidth("\u{2764}\u{FE0F}"));
}

test "unicode: displayWidth skin tone modifier" {
    // 👍 + skin tone = 1 cluster width 2
    try std.testing.expectEqual(@as(usize, 2), unicode.displayWidth("\u{1F44D}\u{1F3FD}"));
}

test "unicode: clusterLenAt mid cluster" {
    // Tại index 1 (byte đầu của combining mark) → cluster bắt đầu ở đó = chính mark (2 byte)
    const s = "a\u{0301}b";
    try std.testing.expectEqual(@as(usize, 2), unicode.clusterLenAt(s, 1));
    // Tại boundary: cluster "a"+mark = 3 byte
    try std.testing.expectEqual(@as(usize, 3), unicode.clusterLenAt(s, 0));
    try std.testing.expectEqual(@as(usize, 1), unicode.clusterLenAt(s, 3));
}

test "unicode: charClass basics" {
    try std.testing.expectEqual(unicode.CharClass.space, unicode.charClass(' '));
    try std.testing.expectEqual(unicode.CharClass.word, unicode.charClass('a'));
    try std.testing.expectEqual(unicode.CharClass.punct, unicode.charClass('.'));
    try std.testing.expectEqual(unicode.CharClass.word, unicode.charClass(0x1EBF)); // ế
}

test "unicode: invalid UTF-8 fallback" {
    // byte không hợp lệ → vẫn iterate không crash, width 1 mỗi cluster
    const s = "\xFF\xFE";
    try std.testing.expectEqual(@as(usize, 2), unicode.displayWidth(s));
}

test "history: cap 500 entries" {
    var h = history.PromptHistory.init(std.testing.allocator);
    defer h.deinit();
    var i: usize = 0;
    while (i < 510) : (i += 1) {
        var buf: [16]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "cmd{d}", .{i});
        try h.add(s);
    }
    try std.testing.expectEqual(@as(usize, 500), h.len());
    try std.testing.expectEqualStrings("cmd509", h.get(499).?);
}

test "history: global dedupe moves to end" {
    var h = history.PromptHistory.init(std.testing.allocator);
    defer h.deinit();
    try h.add("a");
    try h.add("b");
    try h.add("c");
    try h.add("a"); // dedupe: xóa a cũ, đưa lên cuối
    try std.testing.expectEqual(@as(usize, 3), h.len());
    try std.testing.expectEqualStrings("a", h.get(2).?);
    try std.testing.expectEqualStrings("b", h.get(0).?);
}
