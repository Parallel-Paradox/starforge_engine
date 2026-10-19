//! Niche integer types: integers with one value reserved as an `invalid` sentinel.

const std = @import("std");

/// Integer type of `i` excluding `0`.
pub fn NonZero(comptime I: type) type {
    return NonInt(I, 0);
}

/// Integer type of `i` excluding its maximum value.
pub fn NonMax(comptime I: type) type {
    return NonInt(I, std.math.maxInt(I));
}

/// Generic integer niche: the value `num` of integer type `i` is reserved as `invalid`.
fn NonInt(comptime I: type, comptime num: comptime_int) type {
    if (@typeInfo(I) != .int)
        @compileError("NonInt requires an integer type, got " ++ @typeName(I));

    return enum(I) {
        /// Sentinel value meaning no valid value.
        invalid = num,
        _,

        /// Returns a value built from the raw integer `val`.
        /// Asserts (in safe build modes) that `val` is not the reserved value `num`.
        pub fn from(val: I) @This() {
            std.debug.assert(val != num);
            return @enumFromInt(val);
        }

        /// Returns the raw value of a valid value.
        /// Asserts (in safe build modes) that the value is not `invalid`.
        pub fn get(self: @This()) I {
            std.debug.assert(self != @This().invalid);
            return @intFromEnum(self);
        }

        /// Returns the raw value, or `null` if the value is `invalid`.
        pub fn tryGet(self: @This()) ?I {
            if (self == @This().invalid) return null;
            return @intFromEnum(self);
        }

        /// Returns the next valid value, wrapping around and skipping `invalid`.
        /// Asserts (in safe build modes) that the value is not `invalid`.
        pub fn next(self: @This()) @This() {
            var val = self.get() +% 1;
            if (val == num) val +%= 1;
            return @enumFromInt(val);
        }
    };
}

const expectEqual = std.testing.expectEqual;

test "NonInt from" {
    const T = NonInt(i32, -7);
    const v = T.from(123);
    try expectEqual(123, v.get());
    try expectEqual(123, v.tryGet().?);
}

test "NonInt with signed and unsigned custom sentinel" {
    const Signed = NonInt(i8, -1);
    const sv: Signed = @enumFromInt(3);
    try expectEqual(3, sv.get());
    try expectEqual(null, Signed.invalid.tryGet());

    const Unsigned = NonInt(u8, 42);
    const uv: Unsigned = @enumFromInt(3);
    try expectEqual(3, uv.get());
    try expectEqual(null, Unsigned.invalid.tryGet());
    try expectEqual(42, @intFromEnum(Unsigned.invalid));
}

test "NonInt next skips the invalid value" {
    const T = NonInt(u8, 42);
    try expectEqual(2, T.from(1).next().get());
    try expectEqual(43, T.from(41).next().get());
}

test "NonInt next wraps around and skips the invalid value" {
    const NonZeroU8 = NonInt(u8, 0);
    try expectEqual(1, NonZeroU8.from(255).next().get());
}
