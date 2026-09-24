//! test_time.zig — Standalone test for epoch time calculation and formatting.

const std = @import("std");

pub fn main() void {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);

    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(ts.sec) };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    
    std.debug.print("Time: {d}:{d} Day: {d} Month: {d} Weekday: {d}\n", .{
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        month_day.day_index + 1,
        @intFromEnum(month_day.month),
        (epoch_day.day + 4) % 7,
    });
}
