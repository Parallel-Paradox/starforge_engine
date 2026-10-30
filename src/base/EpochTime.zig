//! A timestamp expressed in terms of the year, month, day, hours, minutes, and seconds.
//! This is a more human-readable representation of time compared to the raw timestamp.

const std = @import("std");
const builtin = @import("builtin");
const Year = std.time.epoch.Year;
const Month = std.time.epoch.Month;

year: Year,
month: Month,
day: u5,
hours: u5,
minutes: u6,
seconds: u6,

const Timestamp = std.Io.Timestamp;

/// Initialize a new `EpochTime` from a Unix epoch timestamp in seconds.
/// The minimum value for the timestamp is 0 (1970-01-01 00:00:00).
pub fn fromUnixTimestamp(timestamp: Timestamp) @This() {
    const secs_raw: i64 = timestamp.toSeconds();
    const secs: u64 = if (secs_raw >= 0) @intCast(secs_raw) else 0;
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = secs };

    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch_secs.getDaySeconds();

    return .{
        .year = year_day.year,
        .month = month_day.month,
        .day = month_day.day_index + 1,
        .hours = day_secs.getHoursIntoDay(),
        .minutes = day_secs.getMinutesIntoHour(),
        .seconds = day_secs.getSecondsIntoMinute(),
    };
}

pub const LocalError = error{
    InvalidTime,
    TimeOutOfRange,
    LocalTimeUnavailable,
    UnsupportedPlatform,
};

/// Converts a UTC calendar time to the system's local time without changing self.
/// The result must not be passed to toLocal again: EpochTime has no timezone tag.
/// POSIX targets require libc; timezone rules are applied for the input date.
pub fn toLocal(self: @This()) LocalError!@This() {
    try self.validate();

    if (builtin.os.tag == .windows) {
        // SystemTime conversion supports years 1601 through 30827.
        if (self.year < 1601 or self.year > 30827) return error.TimeOutOfRange;
        const utc: Windows.SystemTime = .{
            .year = self.year,
            .month = @backingInt(self.month),
            .day = self.day,
            .hours = self.hours,
            .minutes = self.minutes,
            .seconds = self.seconds,
        };
        var local: Windows.SystemTime = undefined;
        if (Windows.SystemTimeToTzSpecificLocalTimeEx(null, &utc, &local) == 0)
            return error.LocalTimeUnavailable;
        return .{
            .year = local.year,
            .month = @fromBackingInt(@intCast(local.month)),
            .day = @intCast(local.day),
            .hours = @intCast(local.hours),
            .minutes = @intCast(local.minutes),
            .seconds = @intCast(local.seconds),
        };
    } else if (has_posix_local_time) {
        const seconds = std.math.cast(Posix.Time, self.utcSeconds()) orelse
            return error.TimeOutOfRange;
        var local: Posix.Tm = undefined;
        if (Posix.localtime_r(&seconds, &local) == null) return error.LocalTimeUnavailable;
        const year = std.math.cast(Year, @as(i64, local.year) + 1900) orelse
            return error.TimeOutOfRange;
        return .{
            .year = year,
            .month = @fromBackingInt(@intCast(local.month + 1)),
            .day = @intCast(local.day),
            .hours = @intCast(local.hours),
            .minutes = @intCast(local.minutes),
            .seconds = @intCast(local.seconds),
        };
    } else {
        return error.UnsupportedPlatform;
    }
}

fn validate(self: @This()) !void {
    if (self.day == 0 or self.day > std.time.epoch.getDaysInMonth(self.year, self.month) or
        self.hours > 23 or self.minutes > 59 or self.seconds > 59)
        return error.InvalidTime;
}

/// Signed arithmetic also preserves dates before 1970, unlike fromUnixTimestamp.
fn utcSeconds(self: @This()) i64 {
    const previous_year = @as(i64, self.year) - 1;
    var days = 365 * previous_year + @divFloor(previous_year, 4) -
        @divFloor(previous_year, 100) + @divFloor(previous_year, 400) - 719162;
    var month: u4 = 1;
    while (month < @backingInt(self.month)) : (month += 1) {
        days += std.time.epoch.getDaysInMonth(self.year, @fromBackingInt(month));
    }
    days += @as(i64, self.day) - 1;
    return days * std.time.s_per_day + @as(i64, self.hours) * std.time.s_per_hour +
        @as(i64, self.minutes) * std.time.s_per_min + self.seconds;
}

const has_posix_local_time = builtin.os.tag.isDarwin() or switch (builtin.os.tag) {
    .linux, .freebsd, .openbsd, .netbsd, .dragonfly => true,
    else => false,
};

const Posix = struct {
    const Time = if (builtin.target.isMuslLibC()) i64 else std.c.time_t;

    // These POSIX libc share the struct tm layout, including the two extensions.
    const Tm = extern struct {
        seconds: c_int,
        minutes: c_int,
        hours: c_int,
        day: c_int,
        month: c_int,
        year: c_int,
        week_day: c_int,
        year_day: c_int,
        is_dst: c_int,
        utc_offset: c_long,
        zone: ?[*:0]const u8,
    };

    // 32-bit musl redirects time APIs to their time64 symbols in <time.h>.
    const localtime_r = @extern(*const fn (*const Time, *Tm) callconv(.c) ?*Tm, .{
        .name = if (builtin.target.isMuslLibC() and @sizeOf(usize) == 4)
            "__localtime64_r"
        else
            "localtime_r",
        .library_name = "c",
    });
};

const Windows = struct {
    const SystemTime = extern struct {
        year: u16,
        month: u16,
        week_day: u16 = 0,
        day: u16,
        hours: u16,
        minutes: u16,
        seconds: u16,
        milliseconds: u16 = 0,
    };

    extern "kernel32" fn SystemTimeToTzSpecificLocalTimeEx(
        timezone: ?*const anyopaque,
        utc: *const SystemTime,
        local: *SystemTime,
    ) callconv(.winapi) c_int;
};

const BufPrintError = std.fmt.BufPrintError;

/// Transfer the `EpochTime` into a human-readable string format: "YYYY-MM-DD HH:MM:SS".
pub fn toStr(self: @This()) [19]u8 {
    var buffer: [19]u8 = undefined;
    _ = std.fmt.bufPrint(
        &buffer,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}",
        .{ self.year, self.month, self.day, self.hours, self.minutes, self.seconds },
    ) catch unreachable;
    return buffer;
}

pub fn toDateStr(self: @This()) [10]u8 {
    var buffer: [10]u8 = undefined;
    _ = std.fmt.bufPrint(
        &buffer,
        "{d:0>4}-{d:0>2}-{d:0>2}",
        .{ self.year, self.month, self.day },
    ) catch unreachable;
    return buffer;
}

pub fn toClockStr(self: @This()) [8]u8 {
    var buffer: [8]u8 = undefined;
    _ = std.fmt.bufPrint(
        &buffer,
        "{d:0>2}:{d:0>2}:{d:0>2}",
        .{ self.hours, self.minutes, self.seconds },
    ) catch unreachable;
    return buffer;
}

const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

test "fromUnixTimestamp converts Unix epoch" {
    const time = fromUnixTimestamp(.zero);

    try expectEqual(1970, time.year);
    try expectEqual(Month.jan, time.month);
    try expectEqual(1, time.day);
    try expectEqual(0, time.hours);
    try expectEqual(0, time.minutes);
    try expectEqual(0, time.seconds);
}

test "fromUnixTimestamp clamps negative timestamps" {
    const time = fromUnixTimestamp(Timestamp.fromNanoseconds(-1));

    try expectEqual(1970, time.year);
    try expectEqual(Month.jan, time.month);
    try expectEqual(1, time.day);
    try expectEqual(0, time.hours);
    try expectEqual(0, time.minutes);
    try expectEqual(0, time.seconds);
}

test "fromUnixTimestamp converts date and time" {
    const timestamp = Timestamp.fromNanoseconds(1_704_164_645 * std.time.ns_per_s);
    const time = fromUnixTimestamp(timestamp);

    try expectEqual(2024, time.year);
    try expectEqual(Month.jan, time.month);
    try expectEqual(2, time.day);
    try expectEqual(3, time.hours);
    try expectEqual(4, time.minutes);
    try expectEqual(5, time.seconds);
}

test "utcSeconds preserves UTC dates including dates before the epoch" {
    const timestamps = [_]i64{ 0, 1_704_164_645, 951_782_400, 4_107_542_400 };
    for (timestamps) |seconds| {
        const utc = fromUnixTimestamp(
            Timestamp.fromNanoseconds(@as(i96, seconds) * std.time.ns_per_s),
        );
        try expectEqual(seconds, utc.utcSeconds());
    }
    const before_epoch: @This() = .{
        .year = 1969,
        .month = .dec,
        .day = 31,
        .hours = 23,
        .minutes = 59,
        .seconds = 59,
    };
    try expectEqual(-1, before_epoch.utcSeconds());
}

test "toLocal returns a valid time without modifying the UTC input" {
    if (builtin.os.tag != .windows and !has_posix_local_time) return error.SkipZigTest;
    const utc = fromUnixTimestamp(Timestamp.fromNanoseconds(1_704_164_645 * std.time.ns_per_s));
    const local = try utc.toLocal();
    try local.validate();
    try expectEqualStrings("2024-01-02 03:04:05", &utc.toStr());
}

test "toLocal rejects invalid calendar fields" {
    const valid = fromUnixTimestamp(Timestamp.fromNanoseconds(1_704_164_645 * std.time.ns_per_s));
    var invalid = valid;
    invalid.day = 0;
    try expectError(error.InvalidTime, invalid.toLocal());
    invalid = valid;
    invalid.month = .feb;
    invalid.day = 30;
    try expectError(error.InvalidTime, invalid.toLocal());
    invalid = valid;
    invalid.year = 2023;
    invalid.month = .feb;
    invalid.day = 29;
    try expectError(error.InvalidTime, invalid.toLocal());
    invalid = valid;
    invalid.hours = 24;
    try expectError(error.InvalidTime, invalid.toLocal());
    invalid = valid;
    invalid.minutes = 60;
    try expectError(error.InvalidTime, invalid.toLocal());
    invalid = valid;
    invalid.seconds = 60;
    try expectError(error.InvalidTime, invalid.toLocal());
}

test "toLocal applies process TZ rules and daylight saving transitions" {
    if (!has_posix_local_time) return error.SkipZigTest;
    // Run this test in separate processes with these TZ values; never mutate
    // the process environment while other tests may be using timezone of libc.
    const tz = std.mem.sliceTo(std.c.getenv("TZ") orelse return error.SkipZigTest, 0);
    const cases = [_]struct { tz: []const u8, seconds: i64, expected: []const u8 }{
        .{ .tz = "UTC0", .seconds = 1_704_164_645, .expected = "2024-01-02 03:04:05" },
        .{ .tz = "JST-9", .seconds = 1_704_164_645, .expected = "2024-01-02 12:04:05" },
        .{ .tz = "JST-9", .seconds = 1_704_066_300, .expected = "2024-01-01 08:45:00" },
        .{ .tz = "JST-9", .seconds = 1_709_250_300, .expected = "2024-03-01 08:45:00" },
        .{ .tz = "NST3:30", .seconds = 1_704_164_645, .expected = "2024-01-01 23:34:05" },
        .{ .tz = "NST3:30", .seconds = 0, .expected = "1969-12-31 20:30:00" },
        .{ .tz = "NPT-5:45", .seconds = 1_704_164_645, .expected = "2024-01-02 08:49:05" },
        .{
            .tz = "EST5EDT,M3.2.0/2,M11.1.0/2",
            .seconds = 1_710_053_999,
            .expected = "2024-03-10 01:59:59",
        },
        .{
            .tz = "EST5EDT,M3.2.0/2,M11.1.0/2",
            .seconds = 1_710_054_000,
            .expected = "2024-03-10 03:00:00",
        },
        .{
            .tz = "EST5EDT,M3.2.0/2,M11.1.0/2",
            .seconds = 1_730_613_599,
            .expected = "2024-11-03 01:59:59",
        },
        .{
            .tz = "EST5EDT,M3.2.0/2,M11.1.0/2",
            .seconds = 1_730_613_600,
            .expected = "2024-11-03 01:00:00",
        },
    };
    var matched = false;
    for (cases) |case| {
        if (!std.mem.eql(u8, tz, case.tz)) continue;
        matched = true;
        const utc = fromUnixTimestamp(
            Timestamp.fromNanoseconds(@as(i96, case.seconds) * std.time.ns_per_s),
        );
        const local = try utc.toLocal();
        try expectEqualStrings(case.expected, &local.toStr());
    }
    if (!matched) return error.SkipZigTest;
}

test "toStr formats date and time" {
    const time = @This(){
        .year = 2024,
        .month = .jan,
        .day = 2,
        .hours = 3,
        .minutes = 4,
        .seconds = 5,
    };
    const printed = time.toStr();
    try expectEqualStrings("2024-01-02 03:04:05", &printed);
}
