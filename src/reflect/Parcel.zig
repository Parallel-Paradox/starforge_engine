//! A heap-allocated buffer that owns a single type erased value of any type.

const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const TypeMeta = engine.reflect.TypeMeta;
const Default = engine.reflect.Default;

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
    const parcel = try allocate(allocator, meta);
    const typed: *S = @ptrCast(@alignCast(parcel.ptr.?));
    typed.* = value;
    return parcel;
}

/// Constructs a fresh value using runtime metadata and a matching default factory.
/// On failure, frees uninitialized storage without running the value's deinit.
pub fn initDefault(
    allocator: Allocator,
    meta: TypeMeta,
    default: Default,
) (Allocator.Error || Default.Error)!@This() {
    var parcel = try allocate(allocator, meta);
    errdefer parcel.releaseStorage(allocator);
    try default.fill(parcel.bytes());
    return parcel;
}

fn allocate(allocator: Allocator, meta: TypeMeta) Allocator.Error!@This() {
    const ptr: [*]u8 = if (meta.size == 0)
        // Non-null so `deinit` still runs the value's deinit; never allocated or freed.
        @ptrFromInt(meta.alignment.toByteUnits())
    else
        allocator.rawAlloc(meta.size, meta.alignment, @returnAddress()) orelse
            return error.OutOfMemory;
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
const expectError = std.testing.expectError;

const Probe = struct {
    value: u32 align(64) = 42,
    var calls: usize = 0;

    pub fn deinit(self: *@This()) void {
        _ = self;
        calls += 1;
    }
};

test "init normalizes storage types and canStore rejects comptime-only types" {
    const allocator = std.testing.allocator;
    inline for (.{
        .{ @as(u64, 42), u64 },
        .{ 42, isize },
        .{ -42, isize },
        .{ 3.5, f64 },
    }) |entry| {
        const S = entry[1];
        const value: S = entry[0];
        var parcel = try init(allocator, entry[0]);
        defer parcel.deinit(allocator);
        try expect(canStore(@TypeOf(entry[0])));
        try expect(parcel.meta.eql(TypeMeta.of(S)));
        try expectEqualSlices(u8, std.mem.asBytes(&value), parcel.bytes());
    }
    try expect(!canStore(type));
    try expect(!canStore(@TypeOf(null)));
    try expect(!canStore(noreturn));
}

test "initDefault constructs aligned values and cleans up mismatched factories" {
    const allocator = std.testing.allocator;
    Probe.calls = 0;
    const meta = TypeMeta.of(Probe);
    var parcel = try initDefault(allocator, meta, Default.init(Probe).?);
    defer parcel.deinit(allocator);
    try expect(parcel.meta.eql(meta));
    try expectEqual(@sizeOf(Probe), parcel.bytes().len);
    try expectEqual(0, @intFromPtr(parcel.ptr.?) % @alignOf(Probe));
    const value: *Probe = @ptrCast(@alignCast(parcel.ptr.?));
    try expectEqual(42, value.value);
    try expectError(
        error.BufferSizeMismatch,
        initDefault(allocator, meta, Default.init(struct {}).?),
    );
    try expectEqual(0, Probe.calls);
    parcel.deinit(allocator);
    try expectEqual(1, Probe.calls);
}

test "deinit disposes while releaseStorage and take transfer ownership" {
    const allocator = std.testing.allocator;
    Probe.calls = 0;
    var disposed = try init(allocator, Probe{});
    disposed.deinit(allocator);
    disposed.deinit(allocator);
    try expectEqual(1, Probe.calls);
    try expect(disposed.ptr == null);
    try expectEqual(0, disposed.bytes().len);

    var released = try init(allocator, Probe{});
    released.releaseStorage(allocator);
    try expectEqual(1, Probe.calls);
    try expect(released.ptr == null);

    var parcel = try init(allocator, Probe{});
    var value = parcel.take(Probe, allocator);
    try expectEqual(42, value.value);
    try expectEqual(1, Probe.calls);
    try expect(parcel.ptr == null);
    value.deinit();
    try expectEqual(2, Probe.calls);
}

test "typed and runtime zero-size values still run deinit exactly once" {
    const allocator = std.testing.allocator;
    const Empty = struct {
        var calls: usize = 0;

        pub fn deinit(self: *@This()) void {
            _ = self;
            calls += 1;
        }
    };
    for ([_]bool{ false, true }) |runtime| {
        Empty.calls = 0;
        var parcel = if (runtime)
            try initDefault(allocator, TypeMeta.of(Empty), Default.init(Empty).?)
        else
            try init(allocator, Empty{});
        defer parcel.deinit(allocator);
        try expect(parcel.ptr != null);
        try expectEqual(0, parcel.bytes().len);
        parcel.deinit(allocator);
        parcel.deinit(allocator);
        try expectEqual(1, Empty.calls);
        try expect(parcel.ptr == null);
    }
}
