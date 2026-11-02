//! Type-erased default construction with typed creation and caller-provided storage.

const std = @import("std");

/// Writes a fresh value into uninitialized storage of exactly `@sizeOf(T)` bytes,
/// aligned to `@alignOf(T)`. Does not deinit any previous value in the storage.
/// Invalid storage is rejected before the constructor is called.
ptr: *const fn ([]u8) Error!void = undefined,

/// Uses `pub fn default() T` when available, otherwise `T{}` if every struct field
/// has a default value. Returns null when neither construction is supported.
pub fn init(comptime T: type) ?@This() {
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {
            if (@hasDecl(T, "default") and @TypeOf(T.default) == fn () T) {
                return initWithImpl(T, T.default);
            }
        },
        else => return null,
    }

    const info = switch (@typeInfo(T)) {
        .@"struct" => |info| info,
        else => return null,
    };
    inline for (info.field_attrs) |attrs| {
        if (comptime attrs.default_value_ptr == null) return null;
    }

    const Default = struct {
        fn create() T {
            return .{};
        }
    };
    return initWithImpl(T, Default.create);
}

/// Wraps a constructor as the type-erased callback used by `fill`.
pub fn initWithImpl(comptime T: type, comptime default: *const fn () T) @This() {
    const Impl = struct {
        fn fill(dst: []u8) Error!void {
            if (dst.len != @sizeOf(T)) return error.BufferSizeMismatch;
            if (@intFromPtr(dst.ptr) % @alignOf(T) != 0) return error.MisalignedBuffer;
            const value: *T = @ptrCast(@alignCast(dst.ptr));
            value.* = default();
        }
    };
    return .{ .ptr = Impl.fill };
}

/// Creates a fresh default value of `T`. Unsupported types are a compile error.
pub fn of(comptime T: type) T {
    const factory = comptime init(T) orelse
        @compileError("Default.of cannot default-construct " ++ @typeName(T));
    return factory.create(T) catch unreachable;
}

pub const Error = error{
    BufferSizeMismatch,
    MisalignedBuffer,
};

/// Creates a fresh value. `T` must match the type used to initialize this factory;
/// only the storage size and alignment are checked, not the type's identity.
pub fn create(self: @This(), comptime T: type) Error!T {
    var value: T = undefined;
    try self.fill(std.mem.asBytes(&value));
    return value;
}

/// Fills `dst` with a fresh value without deinit-ing any previous value.
/// On a size or alignment error, `dst` is unchanged and the constructor is not called.
pub fn fill(self: @This(), dst: []u8) Error!void {
    try self.ptr(dst);
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;
const expectError = std.testing.expectError;

test "of, create and fill prefer default and construct fresh values" {
    const Value = struct {
        value: usize = 99,
        required: bool,
        var calls: usize = 0;

        pub fn default() @This() {
            calls += 1;
            return .{ .value = calls, .required = true };
        }
    };
    const Choice = enum {
        first,
        second,

        pub fn default() @This() {
            return .second;
        }
    };

    const factory = init(Value).?;
    try expectEqual(0, Value.calls);
    try expectEqualDeep(Value{ .value = 1, .required = true }, of(Value));

    try expectEqualDeep(Value{ .value = 2, .required = true }, try factory.create(Value));

    var value: Value = undefined;
    try factory.fill(std.mem.asBytes(&value));
    try expectEqualDeep(Value{ .value = 3, .required = true }, value);

    try expectEqual(Choice.second, try init(Choice).?.create(Choice));
    try expectEqual(Choice.second, of(Choice));
}

test "of, create and fill use field defaults including empty and aligned structs" {
    const Value = struct {
        count: u32 align(64) = 7,
        enabled: bool = true,
        optional: ?u32 = null,
        comptime tag: u8 = 3,
    };
    const NotFunction = struct {
        value: u32 = 9,
        pub const default = 7;
    };
    const WithArgument = struct {
        value: u32 = 11,

        pub fn default(value: u32) @This() {
            return .{ .value = value };
        }
    };

    inline for (.{ Value, struct {}, NotFunction, WithArgument }) |T| {
        const factory = init(T).?;
        var value: T = undefined;
        try factory.fill(std.mem.asBytes(&value));
        try expectEqualDeep(T{}, value);
        try expectEqualDeep(T{}, try factory.create(T));
        try expectEqualDeep(T{}, of(T));
    }
}

test "init rejects missing field defaults and unsupported constructors" {
    const Partial = struct {
        count: u32 = 7,
        required: bool,
    };
    const Nested = struct {
        inner: struct { count: u32 = 7 },
    };
    const WithArgument = struct {
        value: u32,

        pub fn default(value: u32) @This() {
            return .{ .value = value };
        }
    };
    const WrongReturn = struct {
        value: u32,

        pub fn default() u32 {
            return 7;
        }
    };

    inline for (.{
        Partial,
        Nested,
        WithArgument,
        WrongReturn,
        u32,
        bool,
        void,
        ?u32,
        [0]u8,
        enum { only },
        union { value: u32 },
    }) |T| {
        try expect(init(T) == null);
    }

    // Unsupported types are a compile error:
    // _ = of(Partial);
}

test "initWithImpl wraps an explicit constructor" {
    const Constructor = struct {
        fn make() u32 {
            return 42;
        }
    };

    const factory = initWithImpl(u32, Constructor.make);
    try expectEqual(42, try factory.create(u32));
}

test "create and fill reject invalid storage before calling the constructor" {
    const Value = struct {
        value: u32 align(16),
        var calls: usize = 0;

        pub fn default() @This() {
            calls += 1;
            return .{ .value = 42 };
        }
    };

    const factory = init(Value).?;
    const size = @sizeOf(Value);
    var buffer: [size + @alignOf(Value)]u8 align(@alignOf(Value)) = @splat(0xaa);
    try expectError(error.BufferSizeMismatch, factory.fill(buffer[0 .. size - 1]));
    try expectError(error.BufferSizeMismatch, factory.fill(buffer[0 .. size + 1]));
    try expectError(error.MisalignedBuffer, factory.fill(buffer[1..][0..size]));
    try expectError(error.BufferSizeMismatch, factory.create(u8));
    try expectEqual(0, Value.calls);
    try expectEqualDeep(@as(@TypeOf(buffer), @splat(0xaa)), buffer);
}
