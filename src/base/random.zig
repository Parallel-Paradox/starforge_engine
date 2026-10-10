const std = @import("std");

/// Implement `std.Random` interface using `std.Io` as the source of randomness. It will use
/// `std.Io.random` by default.
///
/// See also `IoSourceSecure`.
pub const IoSource = std.Random.IoSource;

/// Implement `std.Random` interface using `std.Io` as the source of randomness. It will use
/// `std.Io.randomSecure` first and fallback to `std.Io.random` if failed.
///
/// **This implementation doesn't guarantee cryptographic security!** The fallback to
/// `std.Io.random` happens silently inside `fill`, and `std.Io.random` is not cryptographically
/// secure. The caller cannot detect when this happens.
///
/// Use `randomSecure` directly if you need strict cryptographic security.
///
/// Based on `std.Random.IoSource` implementation.
pub const IoSourceSecure = struct {
    io: std.Io,

    pub fn interface(self: *const @This()) std.Random {
        return .{
            .ptr = @constCast(self),
            .fillFn = fill,
        };
    }

    fn fill(ptr: *anyopaque, buffer: []u8) void {
        const self: *const @This() = @ptrCast(@alignCast(ptr));
        self.io.randomSecure(buffer) catch {
            self.io.random(buffer);
        };
    }
};

/// Implement `std.Random` interface using mocked buffer. Useful for testing purposes.
pub const MockSource = struct {
    buffers: []const []const u8,
    index: usize = 0,

    pub fn interface(self: *@This()) std.Random {
        return .{
            .ptr = self,
            .fillFn = fill,
        };
    }

    fn fill(ptr: *anyopaque, buffer: []u8) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        @memcpy(buffer, self.buffers[self.index]);
        self.index += 1;
        self.index %= self.buffers.len;
    }
};

test "IoSource fills buffer with random bytes" {
    const src = IoSource{ .io = std.testing.io };
    const rand = src.interface();

    var buf: [32]u8 = @splat(0);
    rand.bytes(&buf);
    try std.testing.expect(!std.mem.allEqual(u8, &buf, 0));
}

test "IoSourceSecure fills buffer with random bytes" {
    const src = IoSourceSecure{ .io = std.testing.io };
    const rand = src.interface();

    var buf: [32]u8 = @splat(0);
    rand.bytes(&buf);
    try std.testing.expect(!std.mem.allEqual(u8, &buf, 0));
}

test "MockSource returns buffers in order and wraps around" {
    const buffers = [_][]const u8{ "fish", "bird", "tree" };
    var src = MockSource{ .buffers = &buffers };
    const rand = src.interface();

    var buf: [4]u8 = undefined;
    const expected = [_][]const u8{ "fish", "bird", "tree", "fish" };
    for (expected) |want| {
        rand.bytes(&buf);
        try std.testing.expectEqualSlices(u8, want, &buf);
    }
    try std.testing.expectEqual(@as(usize, 1), src.index);
}

test "MockSource index advances on each fill" {
    const buffers = [_][]const u8{ &.{ 1, 2 }, &.{ 3, 4 } };
    var src = MockSource{ .buffers = &buffers };
    const rand = src.interface();

    var buf: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), src.index);
    rand.bytes(&buf);
    try std.testing.expectEqual(@as(usize, 1), src.index);
    rand.bytes(&buf);
    try std.testing.expectEqual(@as(usize, 0), src.index);
}
