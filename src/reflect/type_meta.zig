//! Metadata for a type to manage its layout.

const std = @import("std");

const root = @import("mod.zig");
const TypeId = root.TypeId;

id: TypeId = .invalid,
name: []const u8 = "",
size: usize = 0,
alignment: usize = 0,
/// Indicates whether a type requires a deinit implementation to be called.
need_deinit: union(enum) {
    /// Data-only types.
    trivial,
    /// Need to call deinit on the type when it goes out of scope.
    managed: *const fn (self: *anyopaque, ctx: ?*anyopaque) void,
} = .trivial,

/// Builds the metadata of `T`. Types declaring `fn deinit(self: *T) void` are marked as `managed`;
/// other types are `trivial` and can set `need_deinit` manually.
pub fn of(comptime T: type) @This() {
    const Deinit = struct {
        fn call(self: *anyopaque, _: ?*anyopaque) void {
            T.deinit(@ptrCast(@alignCast(self)));
        }
    };

    return .{
        .id = TypeId.of(T),
        .name = @typeName(T),
        .size = @sizeOf(T),
        .alignment = @alignOf(T),
        .need_deinit = if (comptime hasAutoDeinit(T)) .{ .managed = &Deinit.call } else .trivial,
    };
}

/// Whether `T` declares a `deinit` with the signature `fn (self: *T) void`.
fn hasAutoDeinit(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => return false,
    }
    if (!@hasDecl(T, "deinit")) return false;

    const fn_info = switch (@typeInfo(@TypeOf(T.deinit))) {
        .@"fn" => |f| f,
        else => return false,
    };
    return fn_info.params.len == 1 and
        fn_info.params[0].type == *T and
        fn_info.return_type == void;
}

/// Compares two `TypeMeta` for equality with its id.
pub fn eql(self: @This(), other: @This()) bool {
    return self.id.eql(other.id);
}

pub const ValidateError = TypeId.ValidateError || error{
    /// If alignment is greater than 0, it must be a power of two.
    AlignNotPowerOfTwo,
    /// If alignment is greater than 0, it must divide the size evenly.
    SizeNotDivisibleByAlign,
    /// If alignment is 0, size must also be 0 (e.g. for void type).
    SizeNotZeroWithZeroAlign,
};

/// Validates that the TypeMeta has a valid id and a consistent size and alignment.
pub fn validate(self: @This()) ValidateError!void {
    try self.id.validate();

    if (self.alignment == 0) {
        if (self.size != 0) return ValidateError.SizeNotZeroWithZeroAlign;
        return;
    }
    if (!std.math.isPowerOfTwo(self.alignment)) return ValidateError.AlignNotPowerOfTwo;
    if (self.size % self.alignment != 0) return ValidateError.SizeNotDivisibleByAlign;
}

/// Checks if the TypeMeta is valid according to the validate function.
pub fn isValid(self: @This()) bool {
    self.validate() catch return false;
    return true;
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

test "trivial type has no deinit" {
    const meta = of(u32);

    try expect(meta.id.eql(TypeId.of(u32)));
    try expectEqualStrings("u32", meta.name);
    try expectEqual(@sizeOf(u32), meta.size);
    try expectEqual(@alignOf(u32), meta.alignment);
    try expect(std.meta.activeTag(meta.need_deinit) == .trivial);
}

test "type with deinit is managed" {
    const Probe = struct {
        calls: *usize,

        fn deinit(self: *@This()) void {
            self.calls.* += 1;
        }
    };

    var calls: usize = 0;
    var probe = Probe{ .calls = &calls };
    const meta = of(Probe);

    try expect(std.meta.activeTag(meta.need_deinit) == .managed);
    meta.need_deinit.managed(&probe, null);
    try expectEqual(1, calls);
}

test "deinit with another signature is not auto managed" {
    const Needy = struct {
        fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    try expect(std.meta.activeTag(of(Needy).need_deinit) == .trivial);
}

test "meta of a type is valid" {
    try of(u32).validate();
    try expect(of(u32).isValid());
}

test "default meta is invalid" {
    try expect(!(@This(){}).isValid());
}

test "inconsistent size and alignment is invalid" {
    var meta = of(u32);

    meta.alignment = 3;
    try expectError(ValidateError.AlignNotPowerOfTwo, meta.validate());

    meta.alignment = 4;
    meta.size = 6;
    try expectError(ValidateError.SizeNotDivisibleByAlign, meta.validate());

    meta.alignment = 0;
    meta.size = 4;
    try expectError(ValidateError.SizeNotZeroWithZeroAlign, meta.validate());
}
