//! Niche integer types: integers with one value reserved as an `invalid` sentinel.

const std = @import("std");

/// Integer type of `i` excluding `0`.
pub fn NonZero(comptime i: type) type {
    return NonInt(i, 0);
}

/// Integer type of `i` excluding its maximum value.
pub fn NonMax(comptime i: type) type {
    return NonInt(i, std.math.maxInt(i));
}

/// Generic integer niche: the value `num` of integer type `i` is reserved as `invalid`.
fn NonInt(comptime i: type, comptime num: comptime_int) type {
    if (@typeInfo(i) != .int)
        @compileError("NonInt requires an integer type, got " ++ @typeName(i));

    return enum(i) {
        /// Sentinel value meaning no valid value.
        invalid = num,
        _,

        /// Returns the raw value of a valid value.
        /// Asserts (in safe build modes) that the value is not `invalid`.
        pub fn get(self: @This()) i {
            std.debug.assert(self != @This().invalid);
            return @intFromEnum(self);
        }

        /// Returns the raw value, or `null` if the value is `invalid`.
        pub fn tryGet(self: @This()) ?i {
            if (self == @This().invalid) return null;
            return @intFromEnum(self);
        }
    };
}

const expectEqual = std.testing.expectEqual;

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
