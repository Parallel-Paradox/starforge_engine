//! Owns one resource per storage `TypeId`, backed by individually allocated parcels.
//! Typed methods normalize comptime integers/floats to `isize`/`f64`; `Id` methods
//! use the supplied storage type id directly.

const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const reflect = engine.reflect;
const TypeId = reflect.TypeId;
const Parcel = reflect.Parcel;

entries: std.AutoHashMapUnmanaged(TypeId, Parcel) = .empty,
allocator: Allocator,

pub fn init(allocator: Allocator) @This() {
    return .{ .allocator = allocator };
}

/// Destroys every resource and frees the registry's storage.
/// Invalidates all borrowed resource pointers.
pub fn deinit(self: *@This()) void {
    var iter = self.entries.valueIterator();
    while (iter.next()) |parcel| parcel.deinit(self.allocator);
    self.entries.deinit(self.allocator);
    self.entries = .empty;
}

/// Stores `value`, destroying any previous resource of its storage type.
/// Transfers ownership only on success; failure leaves the existing resource unchanged.
pub fn insert(self: *@This(), value: anytype) Allocator.Error!void {
    var parcel = try Parcel.init(self.allocator, value);
    errdefer parcel.releaseStorage(self.allocator);

    const entry = try self.entries.getOrPut(self.allocator, parcel.meta.id);
    if (entry.found_existing) entry.value_ptr.deinit(self.allocator);
    entry.value_ptr.* = parcel;
}

/// Whether a resource of `T`'s storage type exists.
pub fn contains(self: *const @This(), comptime T: type) bool {
    return self.containsId(TypeId.of(Parcel.StorageOf(T)));
}

/// Whether a resource keyed by `id` exists.
pub fn containsId(self: *const @This(), id: TypeId) bool {
    return self.entries.contains(id);
}

/// Borrows a resource for reading.
pub fn get(self: *const @This(), comptime T: type) ?*const Parcel.StorageOf(T) {
    const bytes = self.getId(TypeId.of(Parcel.StorageOf(T))) orelse return null;
    return @ptrCast(@alignCast(bytes.ptr));
}

/// Borrows a resource's bytes for reading.
pub fn getId(self: *const @This(), id: TypeId) ?[]const u8 {
    const parcel = self.entries.get(id) orelse return null;
    return parcel.bytes();
}

/// Borrows a resource for writing.
pub fn getMut(self: *@This(), comptime T: type) ?*Parcel.StorageOf(T) {
    const bytes = self.getMutId(TypeId.of(Parcel.StorageOf(T))) orelse return null;
    return @ptrCast(@alignCast(bytes.ptr));
}

/// Borrows a resource's bytes for writing.
pub fn getMutId(self: *@This(), id: TypeId) ?[]u8 {
    const parcel = self.entries.get(id) orelse return null;
    return parcel.bytes();
}

/// Removes and destroys a resource, returning whether it existed.
pub fn remove(self: *@This(), comptime T: type) bool {
    return self.removeId(TypeId.of(Parcel.StorageOf(T)));
}

/// Removes and destroys the resource keyed by `id`, returning whether it existed.
pub fn removeId(self: *@This(), id: TypeId) bool {
    var parcel = self.takeId(id) orelse return false;
    parcel.deinit(self.allocator);
    return true;
}

/// Removes a resource and frees its backing storage without destroying its value.
/// Transfers value ownership to the caller.
pub fn take(self: *@This(), comptime T: type) ?Parcel.StorageOf(T) {
    const S = Parcel.StorageOf(T);
    var parcel = self.takeId(TypeId.of(S)) orelse return null;
    return parcel.take(S, self.allocator);
}

/// Removes a resource, transferring its parcel and value ownership to the caller.
/// Use this registry's allocator to destroy the parcel or take its value.
pub fn takeId(self: *@This(), id: TypeId) ?Parcel {
    return (self.entries.fetchRemove(id) orelse return null).value;
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const checkAllAllocationFailures = std.testing.checkAllAllocationFailures;

const Probe = struct {
    calls: *usize,
    value: u32 = 0,

    pub fn deinit(self: *@This()) void {
        self.calls.* += 1;
    }
};

test "typed and runtime access share resources keyed by type" {
    var registry = init(std.testing.allocator);
    defer registry.deinit();
    const id = TypeId.of(u32);
    const view: *const @This() = &registry;

    try expect(!view.containsId(id));
    try expect(view.get(u32) == null);
    try expect(registry.getMutId(id) == null);
    try expect(registry.take(u32) == null);

    try registry.insert(@as(u32, 7));
    try registry.insert(@as(i32, 11));
    try expect(view.contains(u32));
    try expect(view.containsId(id));
    registry.getMut(u32).?.* = 19;
    const read_bytes = view.getId(id).?;
    try expectEqual(@sizeOf(u32), read_bytes.len);
    const read: *const u32 = @ptrCast(@alignCast(read_bytes.ptr));
    try expectEqual(19, read.*);
    const write_bytes = registry.getMutId(TypeId.of(i32)).?;
    try expectEqual(@sizeOf(i32), write_bytes.len);
    const write: *i32 = @ptrCast(@alignCast(write_bytes.ptr));
    write.* = 23;
    try expectEqual(23, view.get(i32).?.*);

    try expect(registry.removeId(TypeId.of(i32)));
    try expect(!registry.remove(i32));
    try expect(view.getId(TypeId.of(i32)) == null);
    try expect(view.contains(u32));
}

test "replacement, removal and destruction respect resource ownership" {
    const allocator = std.testing.allocator;
    var calls: usize = 0;
    {
        var registry = init(allocator);
        defer registry.deinit();

        try registry.insert(Probe{ .calls = &calls, .value = 1 });
        try registry.insert(Probe{ .calls = &calls, .value = 2 });
        try expectEqual(1, calls);
        try expectEqual(2, registry.get(Probe).?.value);

        var value = registry.take(Probe).?;
        try expect(!registry.contains(Probe));
        try expectEqual(1, calls);
        value.deinit();

        try registry.insert(Probe{ .calls = &calls });
        {
            var parcel = registry.takeId(TypeId.of(Probe)).?;
            defer parcel.deinit(allocator);
            try expect(registry.takeId(TypeId.of(Probe)) == null);
            try expectEqual(2, calls);
        }

        try registry.insert(Probe{ .calls = &calls });
        try expect(registry.remove(Probe));
        try expectEqual(4, calls);
        try registry.insert(Probe{ .calls = &calls });
    }
    try expectEqual(5, calls);
}

fn testInsertAllocationFailures(allocator: Allocator) !void {
    var calls: usize = 0;
    {
        var registry = init(allocator);
        defer registry.deinit();

        for (0..2) |i| {
            var value: Probe = .{ .calls = &calls, .value = @intCast(i) };
            const previous = registry.get(Probe);
            registry.insert(value) catch |err| {
                defer value.deinit();
                try expectEqual(0, calls);
                try expect(previous == registry.get(Probe));
                if (previous) |stored| try expectEqual(0, stored.value);
                return err;
            };
        }
        try expectEqual(1, calls);
    }
    try expectEqual(2, calls);
}

test "failed insertion or replacement preserves ownership and existing resources" {
    try checkAllAllocationFailures(std.testing.allocator, testInsertAllocationFailures, .{});
}
