const std = @import("std");

const engine = @import("engine");
const random = engine.base.random;
const Uuid = engine.base.Uuid;

/// v4 is meant for generating id from truly random or pseudorandom numbers.
/// Generate 128 bits of random data that is used to fill out the UUID fields, version and variant
/// then replace the respective bits.
///
/// https://www.rfc-editor.org/info/rfc9562/#section-5.4
pub const V4 = packed struct {
    // Declared in reverse RFC bit order, see `Uuid`.
    rand_c: u62,
    variant: u2 = Uuid.variant_rfc9562,
    rand_b: u12,
    ver: Uuid.Version = .v4,
    rand_a: u48,

    /// `rand_src` will use `std.Io.randomSecure` if possible.
    ///
    /// Implementations SHOULD utilize a cryptographically secure pseudorandom number generator to
    /// provide values that are both difficult to predict ("unguessable") and have a low likelihood
    /// of collision ("unique").
    ///
    /// https://www.rfc-editor.org/info/rfc9562/#name-unguessability
    pub fn init(rand_src: random.IoSourceSecure) @This() {
        const rand = rand_src.interface();
        return initImpl(rand);
    }

    /// Faster than `init` but less secure. Use only if you have a good reason to do so.
    pub fn initInsecure(rand_src: random.IoSource) @This() {
        const rand = rand_src.interface();
        return initImpl(rand);
    }

    pub fn initImpl(rand: std.Random) @This() {
        const val = rand.int(u128);
        var rv: @This() = @bitCast(val);
        rv.ver = Uuid.Version.v4;
        rv.variant = Uuid.variant_rfc9562;
        return rv;
    }

    pub fn toUuid(self: @This()) Uuid {
        return .{
            .sec_a = self.rand_a,
            .ver = self.ver,
            .sec_b = self.rand_b,
            .variant = self.variant,
            .sec_c = self.rand_c,
        };
    }

    pub fn toU128(self: @This()) u128 {
        return @bitCast(self);
    }

    /// Returns the 16 bytes in network (big-endian) byte order, as laid out by RFC 9562.
    pub fn toBytes(self: @This()) [16]u8 {
        return self.toUuid().toBytes();
    }

    /// Inverse of `toBytes`: interprets `bytes` as network (big-endian) byte order.
    pub fn fromBytes(bytes: [16]u8) @This() {
        return @bitCast(Uuid.fromBytes(bytes));
    }
};

const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

test "toBytes matches RFC 9562 byte layout" {
    const uuid = V4{
        .rand_a = 0x123456789ABC,
        .rand_b = 0xDEF,
        .rand_c = 0x0123456789ABCDEF,
    };
    var expected: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "123456789ABC4DEF8123456789ABCDEF");
    const bytes = uuid.toBytes();
    try expectEqualSlices(u8, &expected, &bytes);
    try expectEqual(@as(u128, 0x123456789ABC4DEF8123456789ABCDEF), uuid.toU128());
}

test "fromBytes is the inverse of toBytes" {
    var bytes: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, "123456789ABC4DEF8123456789ABCDEF");
    try expectEqualSlices(u8, &bytes, &V4.fromBytes(bytes).toBytes());
}

test "call init with Io" {
    const io = std.testing.io;
    _ = V4.init(.{ .io = io });
    _ = V4.initInsecure(.{ .io = io });
}

test "type transfer consistency" {
    const raw: u128 = 0xDEADBEEF_CAFEBABE_01234567_89ABCDEF;
    const raw_bytes: [16]u8 = @bitCast(raw);

    var raw_uuid: V4 = @bitCast(raw);
    raw_uuid.ver = Uuid.Version.v4;
    raw_uuid.variant = Uuid.variant_rfc9562;

    var mock = random.MockSource{
        .buffers = &.{&raw_bytes},
    };
    const uuid = V4.initImpl(mock.interface());

    const uuid_as_layout = uuid.toUuid();
    const uuid_as_u128 = uuid.toU128();
    const uuid_as_str = uuid.toBytes();

    const uuid_from_layout: V4 = @bitCast(uuid_as_layout);
    const uuid_from_u128: V4 = @bitCast(uuid_as_u128);
    const uuid_from_bytes: V4 = V4.fromBytes(uuid_as_str);

    try expectEqual(uuid, raw_uuid);
    try expectEqual(uuid, uuid_from_layout);
    try expectEqual(uuid, uuid_from_u128);
    try expectEqual(uuid, uuid_from_bytes);
}
