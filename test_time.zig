const std = @import("std");

pub fn main() void {
    var ts: std.posix.timespec = undefined;
    std.posix.clock_gettime(std.posix.CLOCK.REALTIME, &ts) catch unreachable;
    
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(ts.tv_sec) };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    
    std.debug.print("Time: {d}:{d} Day: {d} Month: {d} Weekday: {d}\n", .{
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        month_day.day_index + 1,
        @intFromEnum(month_day.month),
        @intFromEnum(epoch_day.getDayOfWeek()),
    });
}
