//! A heap-allocated buffer that owns a single type erased value of any type.

const std = @import("std");
const Allocator = std.mem.Allocator;

const root = @import("root.zig");
const TypeMeta = root.TypeMeta;

meta: TypeMeta = .{},
ptr: ?[*]u8 = null,

/// Moves `value` into heap storage sized and aligned for its type. Free it with `deinit`.
pub fn init(allocator: Allocator, value: anytype) Allocator.Error!@This() {
    const T = @TypeOf(value);
    const meta = TypeMeta.of(T);
    const ptr: [*]u8 = if (meta.size == 0)
        // Non-null so `deinit` still runs the value's deinit; never allocated or freed.
        @ptrFromInt(meta.alignment.toByteUnits())
    else
        allocator.rawAlloc(meta.size, meta.alignment, @returnAddress()) orelse
            return error.OutOfMemory;

    const typed: *T = @ptrCast(@alignCast(ptr));
    typed.* = value;
    return .{ .meta = meta, .ptr = ptr };
}

/// Runs the value's deinit if it needs one, frees its storage, and resets to empty.
pub fn deinit(self: *@This(), allocator: Allocator) void {
    const ptr = self.ptr orelse return;

    switch (self.meta.need_deinit) {
        .trivial => {},
        .managed => |deinitFn| deinitFn(ptr, null),
    }
    if (self.meta.size != 0)
        allocator.rawFree(ptr[0..self.meta.size], self.meta.alignment, @returnAddress());
    self.* = .{};
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "init moves the value into owned storage" {
    const allocator = std.testing.allocator;
    var parcel = try init(allocator, @as(u64, 42));
    defer parcel.deinit(allocator);

    const value: *u64 = @ptrCast(@alignCast(parcel.ptr.?));
    try expectEqual(42, value.*);
    try expect(parcel.meta.eql(TypeMeta.of(u64)));
    try expectEqual(@sizeOf(u64), parcel.meta.size);
}

test "deinit runs the value's deinit before freeing" {
    const allocator = std.testing.allocator;
    const Probe = struct {
        calls: *usize,

        pub fn deinit(self: *@This()) void {
            self.calls.* += 1;
        }
    };

    var calls: usize = 0;
    var parcel = try init(allocator, Probe{ .calls = &calls });
    parcel.deinit(allocator);

    try expectEqual(1, calls);
    try expect(parcel.ptr == null);
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
    parcel.deinit(allocator);

    try expectEqual(1, Empty.calls);
    try expect(parcel.ptr == null);
}
