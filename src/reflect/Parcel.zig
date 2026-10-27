//! A heap-allocated buffer that owns a single type erased value of any type.

const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const TypeMeta = engine.reflect.TypeMeta;

meta: TypeMeta = .{},
ptr: ?[*]u8 = null,

/// Whether a `Parcel` can store a value of type `T`.
pub fn canStore(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .type,
        .undefined,
        .null,
        .noreturn,
        .enum_literal,
        .@"fn",
        .frame,
        .@"anyframe",
        .@"opaque",
        .spirv,
        => false,
        else => true,
    };
}

/// The type a value of type `T` is stored as. `comptime_int` becomes `isize` and
/// `comptime_float` becomes `f64`; everything else is stored as-is.
pub fn StorageOf(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .comptime_int => isize,
        .comptime_float => f64,
        else => T,
    };
}

/// Moves `value` into heap storage sized and aligned for its type. Free it with `deinit`.
pub fn init(allocator: Allocator, value: anytype) Allocator.Error!@This() {
    const T = @TypeOf(value);
    if (comptime !canStore(T))
        @compileError("Parcel cannot store type " ++ @typeName(T));

    const S = StorageOf(T);
    const meta = TypeMeta.of(S);
    const ptr: [*]u8 = if (meta.size == 0)
        // Non-null so `deinit` still runs the value's deinit; never allocated or freed.
        @ptrFromInt(meta.alignment.toByteUnits())
    else
        allocator.rawAlloc(meta.size, meta.alignment, @returnAddress()) orelse
            return error.OutOfMemory;

    const typed: *S = @ptrCast(@alignCast(ptr));
    typed.* = value;
    return .{ .meta = meta, .ptr = ptr };
}

/// The stored value's bytes, or an empty slice when the parcel is empty.
pub fn bytes(self: *const @This()) []u8 {
    const ptr = self.ptr orelse return &.{};
    return ptr[0..self.meta.size];
}

/// Runs the value's deinit if it needs one, frees its storage, and resets to empty.
pub fn deinit(self: *@This(), allocator: Allocator) void {
    if (self.ptr) |ptr| {
        switch (self.meta.need_deinit) {
            .trivial => {},
            .managed => |deinitFn| deinitFn(ptr),
        }
    }
    self.freeStorage(allocator);
}

/// Frees the storage without running the value's `deinit`, returning the value's ownership to
/// the caller, who must still hold a copy of it.
pub fn releaseStorage(self: *@This(), allocator: Allocator) void {
    self.freeStorage(allocator);
}

/// Moves the stored value out and frees its storage without running its `deinit`, transferring
/// ownership to the caller.
pub fn take(self: *@This(), comptime T: type, allocator: Allocator) T {
    std.debug.assert(self.meta.eql(TypeMeta.of(T)));
    const value: T = @as(*T, @ptrCast(@alignCast(self.ptr.?))).*;
    self.releaseStorage(allocator);
    return value;
}

fn freeStorage(self: *@This(), allocator: Allocator) void {
    if (self.ptr) |ptr| {
        if (self.meta.size != 0)
            allocator.rawFree(ptr[0..self.meta.size], self.meta.alignment, @returnAddress());
    }
    self.* = .{};
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const Probe = struct {
    calls: *usize,

    pub fn deinit(self: *@This()) void {
        self.calls.* += 1;
    }
};

fn expectStored(parcel: @This(), comptime T: type, expected: T) !void {
    const value: *T = @ptrCast(@alignCast(parcel.ptr.?));
    try expectEqual(expected, value.*);
}

test "init stores values under their storage type" {
    const allocator = std.testing.allocator;

    const stored: u64 = 42;
    var typed = try init(allocator, stored);
    defer typed.deinit(allocator);
    try expect(typed.meta.eql(TypeMeta.of(u64)));
    try expectEqual(@sizeOf(u64), typed.meta.size);
    try expectStored(typed, u64, 42);
    try expectEqualSlices(u8, std.mem.asBytes(&stored), typed.bytes());

    var integer = try init(allocator, 42);
    defer integer.deinit(allocator);
    try expect(integer.meta.eql(TypeMeta.of(isize)));
    try expectStored(integer, isize, 42);

    var negative = try init(allocator, -42);
    defer negative.deinit(allocator);
    try expectStored(negative, isize, -42);

    var fraction = try init(allocator, 3.5);
    defer fraction.deinit(allocator);
    try expect(fraction.meta.eql(TypeMeta.of(f64)));
    try expectStored(fraction, f64, 3.5);
}

test "canStore accepts comptime numbers and rejects comptime-only types" {
    try expect(canStore(comptime_int));
    try expect(canStore(comptime_float));
    try expect(!canStore(type));
    try expect(!canStore(@TypeOf(null)));
    try expect(!canStore(noreturn));
}

test "deinit runs the value's deinit, releaseStorage only frees storage" {
    const allocator = std.testing.allocator;
    var calls: usize = 0;

    var disposed = try init(allocator, Probe{ .calls = &calls });
    disposed.deinit(allocator);
    try expectEqual(1, calls);
    try expect(disposed.ptr == null);
    try expectEqual(0, disposed.bytes().len);

    var released = try init(allocator, Probe{ .calls = &calls });
    released.releaseStorage(allocator);
    try expectEqual(1, calls);
    try expect(released.ptr == null);
}

test "take moves the value out without running its deinit" {
    const allocator = std.testing.allocator;
    var calls: usize = 0;
    var parcel = try init(allocator, Probe{ .calls = &calls });

    var value = parcel.take(Probe, allocator);
    try expectEqual(0, calls);
    try expect(parcel.ptr == null);

    value.deinit();
    try expectEqual(1, calls);
}

test "zero-size value owns no memory but still runs its deinit" {
    const allocator = std.testing.allocator;
    const Empty = struct {
        var calls: usize = 0;

        pub fn deinit(self: *@This()) void {
            _ = self;
            calls += 1;
        }
    };

    var parcel = try init(allocator, Empty{});
    try expectEqual(0, parcel.bytes().len);
    parcel.deinit(allocator);

    try expectEqual(1, Empty.calls);
    try expect(parcel.ptr == null);
}
