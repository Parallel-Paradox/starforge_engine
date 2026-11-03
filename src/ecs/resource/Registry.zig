//! Owns one resource per `TypeId`, backed by individually allocated parcels.
//! Insert marked resource values directly, or pass their types to construct defaults
//! through `reflect.Default`. Values are destroyed through `reflect.TypeMeta`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const resource = engine.ecs.resource;
const reflect = engine.reflect;
const Default = reflect.Default;
const TypeId = reflect.TypeId;
const Parcel = reflect.Parcel;

entries: std.AutoHashMapUnmanaged(TypeId, Parcel) = .empty,
allocator: Allocator,

pub fn init(allocator: Allocator) @This() {
    return .{ .allocator = allocator };
}

/// Destroys every resource through `TypeMeta` and frees the registry's storage.
/// Invalidates all borrowed resource pointers.
pub fn deinit(self: *@This()) void {
    var iter = self.entries.valueIterator();
    while (iter.next()) |parcel| parcel.deinit(self.allocator);
    self.entries.deinit(self.allocator);
    self.entries = .empty;
}

/// Stores a marked resource value, or constructs a passed type with `Default.of`.
/// Replaces and destroys any previous resource through `TypeMeta`.
/// Ownership transfers only on success; failure preserves the old resource
/// and destroys any generated default value.
pub fn insert(self: *@This(), value: anytype) Allocator.Error!void {
    const T = if (@TypeOf(value) == type) value else @TypeOf(value);
    comptime resource.assertResource(T, "Registry.insert");

    if (comptime @TypeOf(value) == type) {
        var default_value = Default.of(T);
        errdefer switch (reflect.TypeMeta.of(T).need_deinit) {
            .trivial => {},
            .managed => |deinitFn| deinitFn(&default_value),
        };
        return self.insert(default_value);
    }

    var parcel = try Parcel.init(self.allocator, value);
    errdefer parcel.releaseStorage(self.allocator);
    try self.insertParcel(parcel);
}

/// Inserts a resource value or constructs a type through `Default` only if absent.
/// Success consumes passed values, destroying skipped ones through `TypeMeta`.
/// Skipped types are not constructed; on failure the caller retains the value.
pub fn insertIfAbsent(self: *@This(), value: anytype) Allocator.Error!void {
    const T = if (@TypeOf(value) == type) value else @TypeOf(value);
    if (!self.contains(T)) return self.insert(value);

    if (comptime @TypeOf(value) != type) {
        var skipped = value;
        switch (reflect.TypeMeta.of(T).need_deinit) {
            .trivial => {},
            .managed => |deinitFn| deinitFn(&skipped),
        }
    }
}

/// Stores a parcel for dynamic or script registration, destroying any previous value.
///
/// WARNING: unchecked metadata; requires exclusive ownership and this registry's allocator.
/// Bypasses `se_resource`. Ownership transfers only on success.
pub fn insertParcel(self: *@This(), parcel: Parcel) Allocator.Error!void {
    const entry = try self.entries.getOrPut(self.allocator, parcel.meta.id);
    if (entry.found_existing) entry.value_ptr.deinit(self.allocator);
    entry.value_ptr.* = parcel;
}

/// Inserts only if absent; otherwise destroys the passed parcel through `TypeMeta`.
///
/// WARNING: see `insertParcel`. Ownership transfers only on success.
pub fn insertParcelIfAbsent(self: *@This(), parcel: Parcel) Allocator.Error!void {
    if (!self.containsId(parcel.meta.id)) return self.insertParcel(parcel);

    var skipped = parcel;
    skipped.deinit(self.allocator);
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

const Probe = struct {
    pub const se_resource: resource.Mark = .{};
    var defaults: usize = 0;
    var destroyed: usize = 0;

    value: u32,

    pub fn default() @This() {
        defaults += 1;
        return .{ .value = 7 };
    }

    pub fn deinit(_: *@This()) void {
        destroyed += 1;
    }
};

test "typed and runtime access share storage" {
    Probe.destroyed = 0;
    var registry = init(std.testing.allocator);
    defer registry.deinit();
    const id = TypeId.of(Probe);
    const view: *const @This() = &registry;

    try expect(!view.containsId(id));
    try expect(view.get(Probe) == null);
    try registry.insert(Probe{ .value = 11 });
    try expect(view.contains(Probe));
    registry.getMut(Probe).?.value = 19;
    const bytes = view.getId(id).?;
    try expectEqual(@sizeOf(Probe), bytes.len);
    const write: *Probe = @ptrCast(@alignCast(registry.getMutId(id).?.ptr));
    write.value += 1;
    try expectEqual(20, view.get(Probe).?.value);

    var parcel = try Parcel.init(registry.allocator, @as(u64, 42));
    registry.insertParcelIfAbsent(parcel) catch |err| {
        parcel.deinit(registry.allocator);
        return err;
    };
    var taken = registry.takeId(TypeId.of(u64)).?;
    defer taken.deinit(registry.allocator);
    try expectEqual(42, taken.take(u64, registry.allocator));
    try expect(registry.takeId(TypeId.of(u64)) == null);
    try expect(registry.removeId(id));
    try expectEqual(1, Probe.destroyed);
    try expect(!registry.remove(Probe));
}

test "insertion modes preserve resource ownership" {
    Probe.defaults = 0;
    Probe.destroyed = 0;
    {
        var registry = init(std.testing.allocator);
        defer registry.deinit();

        try registry.insertIfAbsent(Probe);
        const original = registry.get(Probe).?;
        try registry.insertIfAbsent(Probe);
        try registry.insertIfAbsent(Probe{ .value = 11 });
        var parcel = try Parcel.init(registry.allocator, Probe{ .value = 22 });
        registry.insertParcelIfAbsent(parcel) catch |err| {
            parcel.deinit(registry.allocator);
            return err;
        };
        try expect(registry.get(Probe).? == original);
        try expectEqual(7, original.value);
        try expectEqual(1, Probe.defaults);
        try expectEqual(2, Probe.destroyed);

        try registry.insert(Probe);
        try expectEqual(2, Probe.defaults);
        try expectEqual(3, Probe.destroyed);
        var value = registry.take(Probe).?;
        try expect(!registry.contains(Probe));
        try expectEqual(3, Probe.destroyed);
        value.deinit();
        try registry.insert(Probe{ .value = 33 });
    }
    try expectEqual(5, Probe.destroyed);
}

fn testAllocationFailures(allocator: Allocator) !void {
    inline for (.{ false, true }) |use_default| {
        Probe.defaults = 0;
        Probe.destroyed = 0;
        {
            var registry = init(allocator);
            defer registry.deinit();

            for (0..2) |i| {
                var value: Probe = .{ .value = @intCast(i) };
                const previous = registry.get(Probe);
                const result = if (use_default) registry.insert(Probe) else registry.insert(value);
                result catch |err| {
                    defer if (!use_default) value.deinit();
                    try expect(previous == registry.get(Probe));
                    if (previous) |stored|
                        try expectEqual(if (use_default) @as(u32, 7) else 0, stored.value);
                    if (use_default) {
                        try expectEqual(Probe.defaults, Probe.destroyed + registry.entries.count());
                    } else {
                        try expectEqual(0, Probe.destroyed);
                    }
                    return err;
                };
            }
        }
        try expectEqual(2, Probe.destroyed);
    }
}

test "allocation failures preserve existing resources and clean up owned values" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testAllocationFailures, .{});
}
