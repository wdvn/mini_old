//! testcases/test_media_protocol.zig — Unit tests for Media Protocol.

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

test "media_protocol: JobState parse" {
    try testing.expectEqual(media_proto.JobState.completed, media_proto.JobState.parse("completed"));
    try testing.expectEqual(media_proto.JobState.completed, media_proto.JobState.parse("succeeded"));
    try testing.expectEqual(media_proto.JobState.processing, media_proto.JobState.parse("in_progress"));
    try testing.expectEqual(media_proto.JobState.failed, media_proto.JobState.parse("failed"));
    try testing.expectEqual(media_proto.JobState.queued, media_proto.JobState.parse("unknown_state"));
}

test "media_protocol: coerceLegacySize mappings" {
    const square = media_proto.coerceLegacySize("1024x1024");
    try testing.expectEqual(media_proto.Resolution.res_1k, square.res);
    try testing.expectEqual(media_proto.AspectRatio.ar_1_1, square.aspect);
    try testing.expectEqualStrings("1024x1024", square.raw.?);

    const landscape = media_proto.coerceLegacySize("1536x1024");
    try testing.expectEqual(media_proto.Resolution.res_2k, landscape.res);
    try testing.expectEqual(media_proto.AspectRatio.ar_16_9, landscape.aspect);

    const portrait = media_proto.coerceLegacySize("1024x1536");
    try testing.expectEqual(media_proto.Resolution.res_2k, portrait.res);
    try testing.expectEqual(media_proto.AspectRatio.ar_9_16, portrait.aspect);

    const fallback = media_proto.coerceLegacySize("custom_512x512");
    try testing.expectEqual(media_proto.Resolution.res_1k, fallback.res);
    try testing.expectEqual(media_proto.AspectRatio.ar_1_1, fallback.aspect);
    try testing.expectEqualStrings("custom_512x512", fallback.raw.?);
}

test "media_protocol: coerceLegacySeconds" {
    try testing.expectEqual(@as(u32, 4), media_proto.coerceLegacySeconds(0));
    try testing.expectEqual(@as(u32, 10), media_proto.coerceLegacySeconds(10));
    try testing.expectEqual(@as(u32, 60), media_proto.coerceLegacySeconds(120));
}

test "media_protocol: Non-strict raw aspect ratio & resolution passthrough" {
    // Standard preset case
    const req_preset: media_proto.ImageGenRequest = .{
        .prompt = "test",
        .aspect_ratio = .ar_16_9,
        .resolution = .res_2k,
    };
    try testing.expectEqualStrings("16:9", req_preset.getAspectRatioString().?);
    try testing.expectEqualStrings("2K", req_preset.getResolutionString().?);

    // Custom non-preset raw string case (3:2, 1920x1080)
    const req_custom: media_proto.ImageGenRequest = .{
        .prompt = "test",
        .raw_aspect_ratio = "3:2",
        .raw_resolution = "1920x1080",
    };
    try testing.expectEqualStrings("3:2", req_custom.getAspectRatioString().?);
    try testing.expectEqualStrings("1920x1080", req_custom.getResolutionString().?);
}

