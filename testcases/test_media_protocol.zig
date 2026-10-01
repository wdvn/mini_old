//! testcases/test_media_protocol.zig — Unit tests for RFC-027 Media Protocol.

const std = @import("std");
const testing = std.testing;
const mini = @import("mini");
const media_proto = mini.media_protocol;

test "media_protocol: AspectRatio parse and asString" {
    try testing.expectEqual(media_proto.AspectRatio.ar_1_1, media_proto.AspectRatio.parse("1:1").?);
    try testing.expectEqual(media_proto.AspectRatio.ar_16_9, media_proto.AspectRatio.parse("16:9").?);
    try testing.expectEqual(media_proto.AspectRatio.ar_9_16, media_proto.AspectRatio.parse("9:16").?);
    try testing.expectEqual(media_proto.AspectRatio.ar_4_3, media_proto.AspectRatio.parse("4:3").?);
    try testing.expectEqual(media_proto.AspectRatio.ar_3_4, media_proto.AspectRatio.parse("3:4").?);
    try testing.expectEqual(media_proto.AspectRatio.ar_21_9, media_proto.AspectRatio.parse("21:9").?);
    try testing.expectEqualStrings("16:9", media_proto.AspectRatio.ar_16_9.asString());
    try testing.expect(media_proto.AspectRatio.parse("invalid_ratio") == null);
}

test "media_protocol: Resolution parse and asString" {
    try testing.expectEqual(media_proto.Resolution.res_1k, media_proto.Resolution.parse("1K").?);
    try testing.expectEqual(media_proto.Resolution.res_2k, media_proto.Resolution.parse("2k").?);
    try testing.expectEqual(media_proto.Resolution.res_1080p, media_proto.Resolution.parse("1080p").?);
    try testing.expectEqual(media_proto.Resolution.res_720p, media_proto.Resolution.parse("720P").?);
    try testing.expectEqual(media_proto.Resolution.res_4k, media_proto.Resolution.parse("4k").?);
    try testing.expectEqualStrings("2K", media_proto.Resolution.res_2k.asString());
    try testing.expect(media_proto.Resolution.parse("invalid_res") == null);
}

test "media_protocol: coerceLegacySize mappings" {
    const square = media_proto.coerceLegacySize("1024x1024");
    try testing.expectEqual(media_proto.Resolution.res_1k, square.res);
    try testing.expectEqual(media_proto.AspectRatio.ar_1_1, square.aspect);

    const landscape = media_proto.coerceLegacySize("1536x1024");
    try testing.expectEqual(media_proto.Resolution.res_2k, landscape.res);
    try testing.expectEqual(media_proto.AspectRatio.ar_16_9, landscape.aspect);

    const portrait = media_proto.coerceLegacySize("1024x1536");
    try testing.expectEqual(media_proto.Resolution.res_2k, portrait.res);
    try testing.expectEqual(media_proto.AspectRatio.ar_9_16, portrait.aspect);

    const fallback = media_proto.coerceLegacySize("unknown");
    try testing.expectEqual(media_proto.Resolution.res_1k, fallback.res);
    try testing.expectEqual(media_proto.AspectRatio.ar_1_1, fallback.aspect);
}
