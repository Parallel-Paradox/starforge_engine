const std = @import("std");

/// UUID generator implementing RFC 9562 (obsoletes RFC 4122)
///
/// RFC 9562: https://www.rfc-editor.org/rfc/rfc9562
pub const Uuid = packed struct {
    // Zig packed structs lay out fields from the least significant bit, so fields are declared
    // in reverse of the RFC 9562 bit order to keep `@bitCast` to `u128` matching the RFC layout.
    sec_c: u62,
    variant: u2 = VARIANT,
    sec_b: u12,
    ver: Version,
    sec_a: u48,

    // TODO Implement other versions of UUID when needed.

    /// The variant field determines the layout of the UUID.
    /// https://www.rfc-editor.org/info/rfc9562/#variant_field
    pub const VARIANT: u2 = 0b10;

    pub const Version = enum(u4) {
        v4 = 0b0100,
        v7 = 0b0111,
    };

    pub const V4 = @import("v4.zig").V4;
    pub const V7 = @import("v7.zig").V7;

    pub fn toU128(self: @This()) u128 {
        return @bitCast(self);
    }

    /// Returns the 16 bytes in network (big-endian) byte order, as laid out by RFC 9562.
    pub fn toBytes(self: @This()) [16]u8 {
        return @bitCast(std.mem.nativeToBig(u128, self.toU128()));
    }

    /// Inverse of `toBytes`: interprets `bytes` as network (big-endian) byte order.
    pub fn fromBytes(bytes: [16]u8) @This() {
        return @bitCast(std.mem.bigToNative(u128, @bitCast(bytes)));
    }
};

test {
    _ = Uuid.V4;
    _ = Uuid.V7;
}
