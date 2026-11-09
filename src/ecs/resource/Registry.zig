//! Owns one resource per `TypeId`, backed by individually allocated parcels.
//! Insert marked resource values directly, or pass their types to construct defaults
//! through `reflect.Default`. Values are destroyed through `reflect.TypeMeta`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const resource = engine.ecs.resource;
const ResId = resource.Id;
const reflect = engine.reflect;
const Default = reflect.Default;
const TypeId = reflect.TypeId;
const Parcel = reflect.Parcel;

pub const Entry = struct {
    id: ResId = .invalid,
    parcel: Parcel = .{},
};

type_to_id: std.AutoHashMapUnmanaged(TypeId, ResId) = .empty,
entries: std.ArrayList(Entry) = .empty,
retired: std.ArrayList(ResId) = .empty,
allocator: Allocator,

pub fn init(allocator: Allocator) @This() {
    return .{ .allocator = allocator };
}

/// Destroys every resource through `TypeMeta` and frees the registry's storage.
/// Invalidates all borrowed resource pointers.
pub fn deinit(self: *@This()) void {
    for (self.entries.items) |*entry| entry.parcel.deinit(self.allocator);
    self.type_to_id.deinit(self.allocator);
    self.entries.deinit(self.allocator);
    self.retired.deinit(self.allocator);
    self.type_to_id = .empty;
    self.entries = .empty;
    self.retired = .empty;
}

/// Stores a marked resource value, or constructs a passed type with `Default.of`.
/// Replaces and destroys any previous resource through `TypeMeta`.
/// Ownership transfers only on success; failure preserves the old resource
/// and destroys any generated default value.
pub fn insert(self: *@This(), value: anytype) Allocator.Error!ResId {
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
    return self.insertParcel(parcel);
}

/// Inserts a value or constructs a type through `Default` only if absent.
/// Success consumes passed values, destroying skipped ones through `TypeMeta`.
/// Skipped types are not constructed; on failure the caller retains the value.
pub fn insertIfAbsent(self: *@This(), value: anytype) Allocator.Error!ResId {
    const T = if (@TypeOf(value) == type) value else @TypeOf(value);
    const id = self.idOf(T) orelse return self.insert(value);

    if (comptime @TypeOf(value) != type) {
        var skipped = value;
        switch (reflect.TypeMeta.of(T).need_deinit) {
            .trivial => {},
            .managed => |deinitFn| deinitFn(&skipped),
        }
    }
    return id;
}

/// Stores a parcel for dynamic or script registration, returning its resource ID.
/// Replaces and destroys any previous value without changing its ID.
///
/// WARNING: unchecked metadata; requires exclusive ownership and this registry's allocator.
/// Bypasses `se_resource`. Ownership transfers only on success.
pub fn insertParcel(self: *@This(), parcel: Parcel) Allocator.Error!ResId {
    if (self.idOfTypeId(parcel.meta.id)) |id| {
        const entry = &self.entries.items[id.index.get()];
        entry.parcel.deinit(self.allocator);
        entry.parcel = parcel;
        return id;
    }

    if (self.retired.items.len > 0) {
        const id = self.retired.getLast();
        try self.type_to_id.put(self.allocator, parcel.meta.id, id);
        _ = self.retired.pop();
        self.entries.items[id.index.get()] = .{ .id = id, .parcel = parcel };
        return id;
    }

    const id = ResId.init(self.entries.items.len, 0);
    try self.entries.ensureUnusedCapacity(self.allocator, 1);
    try self.type_to_id.ensureUnusedCapacity(self.allocator, 1);
    // Every slot may be retired; reserving here keeps removal allocation-free.
    try self.retired.ensureTotalCapacity(self.allocator, self.entries.items.len + 1);

    self.entries.appendAssumeCapacity(.{ .id = id, .parcel = parcel });
    self.type_to_id.putAssumeCapacityNoClobber(parcel.meta.id, id);
    return id;
}

/// Returns the resource ID, inserting if absent or destroying the passed parcel if present.
///
/// WARNING: see `insertParcel`. Ownership transfers only on success.
pub fn insertParcelIfAbsent(self: *@This(), parcel: Parcel) Allocator.Error!ResId {
    const id = self.idOfTypeId(parcel.meta.id) orelse return self.insertParcel(parcel);

    var skipped = parcel;
    skipped.deinit(self.allocator);
    return id;
}

/// Whether a resource of `T`'s storage type exists.
pub fn contains(self: *const @This(), comptime T: type) bool {
    return self.containsTypeId(TypeId.of(Parcel.StorageOf(T)));
}

/// Whether a resource keyed by `id` exists.
pub fn containsTypeId(self: *const @This(), id: TypeId) bool {
    return self.type_to_id.contains(id);
}

/// Whether `id` refers to a live resource in this registry.
pub fn containsResId(self: *const @This(), id: ResId) bool {
    return self.indexOf(id) != null;
}

/// Returns the resource ID for `T`, or null if absent.
pub fn idOf(self: *const @This(), comptime T: type) ?ResId {
    return self.idOfTypeId(TypeId.of(T));
}

/// Returns the resource ID for `type_id`, or null if absent.
pub fn idOfTypeId(self: *const @This(), type_id: TypeId) ?ResId {
    return self.type_to_id.get(type_id);
}

/// Borrows a mutable resource, or returns null if absent.
pub fn get(self: *@This(), comptime T: type) ?*T {
    const bytes = self.getByTypeId(TypeId.of(T)) orelse return null;
    return @ptrCast(@alignCast(bytes.ptr));
}

/// Borrows the resource bytes for `type_id`, or returns null if absent.
pub fn getByTypeId(self: *@This(), type_id: TypeId) ?[]u8 {
    return self.getById(self.idOfTypeId(type_id) orelse return null);
}

/// Borrows mutable resource bytes, returning null for unknown or stale IDs.
pub fn getById(self: *@This(), id: ResId) ?[]u8 {
    return self.entries.items[self.indexOf(id) orelse return null].parcel.bytes();
}

/// Removes and destroys a resource, returning whether it existed.
pub fn remove(self: *@This(), comptime T: type) bool {
    return self.removeByTypeId(TypeId.of(Parcel.StorageOf(T)));
}

/// Removes and destroys the resource keyed by `id`, returning whether it existed.
pub fn removeByTypeId(self: *@This(), id: TypeId) bool {
    return self.removeByResId(self.type_to_id.get(id) orelse return false);
}

/// Removes and destroys a resource by ID, returning false for unknown or stale IDs.
pub fn removeByResId(self: *@This(), id: ResId) bool {
    var parcel = self.takeByResId(id) orelse return false;
    parcel.deinit(self.allocator);
    return true;
}

/// Removes a resource and frees its backing storage without destroying its value.
/// Transfers value ownership to the caller.
pub fn take(self: *@This(), comptime T: type) ?Parcel.StorageOf(T) {
    const S = Parcel.StorageOf(T);
    var parcel = self.takeByTypeId(TypeId.of(S)) orelse return null;
    return parcel.take(S, self.allocator);
}

/// Removes a resource, transferring its parcel and value ownership to the caller.
/// Use this registry's allocator to destroy the parcel or take its value.
pub fn takeByTypeId(self: *@This(), id: TypeId) ?Parcel {
    return self.takeByResId(self.type_to_id.get(id) orelse return null);
}

/// Takes a parcel by resource ID, retiring the ID without destroying the value.
/// Returns null for unknown or stale IDs. The caller owns the returned parcel.
pub fn takeByResId(self: *@This(), id: ResId) ?Parcel {
    const index = self.indexOf(id) orelse return null;
    const entry = &self.entries.items[index];
    const parcel = entry.parcel;
    _ = self.type_to_id.remove(parcel.meta.id);
    entry.* = .{};
    self.retired.appendAssumeCapacity(id.nextGeneration());
    return parcel;
}

fn indexOf(self: *const @This(), id: ResId) ?usize {
    const index = id.index.tryGet() orelse return null;
    if (index >= self.entries.items.len) return null;
    if (!self.entries.items[index].id.eql(id)) return null;
    return index;
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const checkAllAllocationFailures = std.testing.checkAllAllocationFailures;

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

test "typed, runtime and generation ID access share storage and reject stale IDs" {
    Probe.destroyed = 0;
    var reg = init(std.testing.allocator);
    defer reg.deinit();
    const type_id = TypeId.of(Probe);

    try expect(!reg.containsTypeId(type_id));
    try expect(reg.get(Probe) == null);
    try expect(reg.getByTypeId(type_id) == null);
    try expect(reg.idOf(Probe) == null);
    const id = try reg.insert(Probe{ .value = 11 });
    const found = reg.get(Probe).?;
    try expect(id.eql(reg.idOf(Probe).?));
    try expect(id.eql(reg.idOfTypeId(type_id).?));
    try expect(reg.containsResId(id));
    found.value = 19;
    const bytes = reg.getByTypeId(type_id).?;
    try expect(bytes.ptr == reg.getById(id).?.ptr);
    try expectEqual(@sizeOf(Probe), bytes.len);
    const write: *Probe = @ptrCast(@alignCast(bytes.ptr));
    write.value += 1;
    try expectEqual(20, reg.get(Probe).?.value);
    try expect(reg.getById(.invalid) == null);
    try expect(reg.getById(ResId.init(@intCast(reg.entries.items.len), 0)) == null);
    try expect(reg.getById(ResId.init(id.index.get(), id.generation.next().get())) == null);

    try expect(reg.removeByTypeId(type_id));
    try expectEqual(1, Probe.destroyed);
    try expect(reg.getByTypeId(type_id) == null);
    try expect(reg.idOfTypeId(type_id) == null);
    try expect(!reg.containsResId(id));
    try expect(!reg.remove(Probe));

    var parcel = try Parcel.init(reg.allocator, @as(u64, 42));
    const reused = reg.insertParcelIfAbsent(parcel) catch |err| {
        parcel.deinit(reg.allocator);
        return err;
    };
    try expect(reused.eql(reg.idOf(u64).?));
    try expectEqual(id.index, reused.index);
    try expectEqual(id.generation.next(), reused.generation);
    try expectEqual(1, reg.entries.items.len);
    try expect(reg.getById(id) == null);
    try expect(reg.takeByResId(id) == null);
    try expect(!reg.removeByResId(id));
    try expectEqual(42, reg.get(u64).?.*);
    var taken = reg.takeByResId(reused).?;
    defer taken.deinit(reg.allocator);
    try expectEqual(42, taken.take(u64, reg.allocator));
    try expect(reg.takeByTypeId(TypeId.of(u64)) == null);
    try expect(!reg.removeByResId(reused));
}

test "insertion modes preserve resource ownership" {
    Probe.defaults = 0;
    Probe.destroyed = 0;
    {
        var registry = init(std.testing.allocator);
        defer registry.deinit();

        const id = try registry.insertIfAbsent(Probe);
        const original = registry.get(Probe).?;
        try expect(id.eql(try registry.insertIfAbsent(Probe)));
        try expect(id.eql(try registry.insertIfAbsent(Probe{ .value = 11 })));
        var parcel = try Parcel.init(registry.allocator, Probe{ .value = 22 });
        const skipped_id = registry.insertParcelIfAbsent(parcel) catch |err| {
            parcel.deinit(registry.allocator);
            return err;
        };
        try expect(id.eql(skipped_id));
        try expect(registry.get(Probe).? == original);
        try expect(id.eql(registry.idOf(Probe).?));
        try expectEqual(7, original.value);
        try expectEqual(1, Probe.defaults);
        try expectEqual(2, Probe.destroyed);

        try expect(id.eql(try registry.insert(Probe)));
        try expect(id.eql(registry.idOf(Probe).?));
        try expectEqual(2, Probe.defaults);
        try expectEqual(3, Probe.destroyed);
        var value = registry.take(Probe).?;
        try expect(!registry.contains(Probe));
        try expect(!registry.containsResId(id));
        try expectEqual(3, Probe.destroyed);
        value.deinit();
        const reused = try registry.insert(Probe{ .value = 33 });
        try expectEqual(id.index, reused.index);
        try expectEqual(id.generation.next(), reused.generation);
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

            for (0..3) |i| {
                if (i == 2) {
                    var taken = registry.take(Probe).?;
                    taken.deinit();
                }
                var value: Probe = .{ .value = @intCast(i) };
                const previous = registry.get(Probe);
                const previous_id = registry.idOf(Probe);

                const entries_len = registry.entries.items.len;
                const retired_len = registry.retired.items.len;
                const retired_id = if (retired_len > 0)
                    registry.retired.getLast()
                else
                    ResId.invalid;
                const destroyed = Probe.destroyed;
                const result = if (use_default) registry.insert(Probe) else registry.insert(value);
                _ = result catch |err| {
                    defer if (!use_default) value.deinit();
                    try expectEqual(previous, registry.get(Probe));
                    try expectEqual(previous_id, registry.idOf(Probe));
                    try expectEqual(entries_len, registry.entries.items.len);
                    try expectEqual(retired_len, registry.retired.items.len);
                    if (retired_len > 0) try expect(retired_id.eql(registry.retired.getLast()));
                    if (previous) |stored|
                        try expectEqual(if (use_default) @as(u32, 7) else 0, stored.value);
                    if (use_default) {
                        try expectEqual(
                            Probe.defaults,
                            Probe.destroyed + registry.type_to_id.count(),
                        );
                    } else {
                        try expectEqual(destroyed, Probe.destroyed);
                    }
                    return err;
                };
            }

            const stored = registry.get(Probe).?;
            const id = registry.idOf(Probe).?;
            inline for (1..10) |len| {
                var parcel = try Parcel.init(allocator, @as([len]u8, @splat(0)));
                const count = registry.type_to_id.count();
                const entries_len = registry.entries.items.len;
                const inserted_id = registry.insertParcel(parcel) catch |err| {
                    defer parcel.deinit(allocator);
                    try expectEqual(count, registry.type_to_id.count());
                    try expectEqual(entries_len, registry.entries.items.len);
                    try expect(registry.get([len]u8) == null);
                    try expectEqual(stored, registry.get(Probe).?);
                    try expect(id.eql(registry.idOf(Probe).?));
                    return err;
                };
                try expect(inserted_id.eql(registry.idOf([len]u8).?));
                try expectEqual(stored, registry.get(Probe).?);
                try expect(id.eql(registry.idOf(Probe).?));
            }
        }
        try expectEqual(3, Probe.destroyed);
    }
}

test "allocation failures preserve slots, IDs and value ownership" {
    try checkAllAllocationFailures(std.testing.allocator, testAllocationFailures, .{});
}
