const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const ecs = engine.ecs;
const CompId = ecs.component.Id;
const Archetype = ecs.Archetype;
const SparseSet = ecs.SparseSet;
const Entity = ecs.Entity;
const reflect = engine.reflect;
const TypeId = reflect.TypeId;
const Parcel = reflect.Parcel;
const Bundle = reflect.Bundle;
const Default = reflect.Default;
const Self = ecs.Entity.Registry;
const _storage = @import("storage.zig");

pub const AddBundleError = AddParcelsError || Default.Error || error{
    /// A required component id is unknown, stale, or has only been reserved.
    UnknownRequirement,
    /// A missing required component has no default constructor.
    MissingRequirementDefault,
};

/// Creates an entity from registered components, default-constructing missing requirements.
/// Explicit values take precedence. Consumes `bundle` only on success.
pub fn addBundle(self: *Self, bundle: Bundle) AddBundleError!Entity.Id {
    const allocator = self.allocator;
    var required: std.array_hash_map.Auto(CompId, void) = .{};
    defer required.deinit(allocator);

    for (bundle.map.values()) |parcel| {
        const id =
            self.comp_reg.idOfTypeId(parcel.meta.id) orelse return error.UnknownComponentType;
        if (self.comp_reg.getById(id) == null) return error.UnknownComponentType;
        try required.put(allocator, id, {});
    }

    // The ordered set doubles as a work queue. Mark on discovery to terminate cycles.
    var index: usize = 0;
    while (index < required.count()) : (index += 1) {
        const meta = self.comp_reg.getById(required.keys()[index]) orelse
            return error.UnknownRequirement;
        for (meta.require) |id| try required.put(allocator, id, {});
    }
    for (required.keys()) |id| {
        const meta = self.comp_reg.getById(id).?;
        if (!bundle.map.contains(meta.typeId()) and meta.default == null)
            return error.MissingRequirementDefault;
    }

    var parcels: std.ArrayList(Parcel) = .empty;
    defer parcels.deinit(allocator);
    try parcels.ensureTotalCapacity(allocator, required.count());
    parcels.appendSliceAssumeCapacity(bundle.map.values());
    const explicit_count = parcels.items.len;
    errdefer for (parcels.items[explicit_count..]) |*parcel| parcel.deinit(allocator);

    for (required.keys()) |id| {
        const meta = self.comp_reg.getById(id).?;
        if (bundle.map.contains(meta.typeId())) continue;
        const parcel = try Parcel.initDefault(allocator, meta.type_meta, meta.default.?);
        parcels.appendAssumeCapacity(parcel);
    }

    const id = try addParcels(self, parcels.items);
    for (parcels.items[explicit_count..]) |*parcel| parcel.releaseStorage(allocator);
    var moved = bundle;
    moved.releaseStorage();
    return id;
}

const AddParcelsError =
    Allocator.Error || Archetype.ChunkLayout.Error || SplitByStorageError;

/// Moves unique, fully resolved component values into storage only on success.
/// Borrows descriptors and buffers; the caller handles their cleanup.
fn addParcels(self: *Self, parcels: []const Parcel) AddParcelsError!Entity.Id {
    const allocator = self.allocator;

    const storage_split_ids = try allocator.alloc(CompId, parcels.len);
    defer allocator.free(storage_split_ids);

    const archetype_count = try splitByStorage(self, parcels, storage_split_ids);
    const archetype_components = storage_split_ids[0..archetype_count];
    const sparse_components = storage_split_ids[archetype_count..];

    const archetype_entry = try self.arche_reg.getOrCreate(archetype_components, self.comp_reg);
    const archetype = &archetype_entry.archetype;

    var entity = try createEntity(self, archetype_entry, sparse_components);
    errdefer entity.deinit(allocator);

    try reserveStorage(self, archetype, entity.id, entity.sparse_comps.items);
    commitEntity(self, entity, archetype);

    storeArchetypeComponents(self, parcels, archetype, entity.archetype_row);
    storeSparseComponents(self, parcels, entity.sparse_comps.items, entity.id);

    return entity.id;
}

const SplitByStorageError = error{UnknownComponentType};

/// Partitions `ids` in place into an archetype prefix and a sparse suffix. Returns the
/// boundary index between them. Sparse ids are filled from the end, so that suffix is in
/// reverse parcel order.
fn splitByStorage(
    self: *const Self,
    parcels: []const Parcel,
    ids: []CompId,
) SplitByStorageError!usize {
    std.debug.assert(ids.len == parcels.len);

    var archetype_end: usize = 0;
    var sparse_start: usize = ids.len;
    for (parcels) |parcel| {
        const meta = self.comp_reg.getByTypeId(parcel.meta.id) orelse
            return error.UnknownComponentType;
        const comp_id = self.comp_reg.idOfTypeId(parcel.meta.id).?;
        switch (meta.storage) {
            .archetype => {
                ids[archetype_end] = comp_id;
                archetype_end += 1;
            },
            .sparse_set => {
                sparse_start -= 1;
                ids[sparse_start] = comp_id;
            },
        }
    }

    std.debug.assert(archetype_end == sparse_start);
    return archetype_end;
}

/// Reserves an entity slot, builds its component bookkeeping, and resolves its sparse sets.
fn createEntity(
    self: *Self,
    archetype: *const Archetype.Registry.Entry,
    sparse_components: []const CompId,
) Allocator.Error!Entity {
    const allocator = self.allocator;
    const id = if (self.retired.items.len != 0)
        self.retired.getLast()
    else
        Entity.Id.init(self.entities.items.len, 0);
    try self.entities.ensureTotalCapacity(allocator, id.index.get() + 1);

    var entity = Entity.init(allocator, id);
    errdefer entity.deinit(allocator);

    try entity.sparse_comps.ensureTotalCapacity(allocator, sparse_components.len);
    for (sparse_components) |comp_id| {
        const meta = self.comp_reg.getById(comp_id).?;
        const set_entry = try self.sparse_reg.getOrCreate(meta.type_meta);
        entity.sparse_comps.appendAssumeCapacity(set_entry.id);
    }
    const base = archetype.archetype.meta.signature;
    if (sparse_components.len == 0) {
        entity.signature = base;
    } else {
        entity.signature = try base.clone(allocator);
        try entity.signature.add(allocator, sparse_components);
    }
    entity.archetype_id = archetype.id;
    entity.archetype_row = archetype.archetype.len();
    return entity;
}

/// Reserves room in the archetype and sparse sets before values leave the parcels.
fn reserveStorage(
    self: *Self,
    archetype: *Archetype,
    id: Entity.Id,
    sparse_ids: []const SparseSet.Id,
) Allocator.Error!void {
    try archetype.reserve(1);

    for (sparse_ids) |sparse_id| try _storage.reserveSparseSet(self, sparse_id, id);
}

/// Publishes the entity and records its row in the archetype. Cannot fail.
fn commitEntity(self: *Self, entity: Entity, archetype: *Archetype) void {
    const index = entity.id.index.get();
    if (index == self.entities.items.len) {
        self.entities.appendAssumeCapacity(entity);
    } else {
        // A retired id replaces an existing slot instead of appending a new one.
        std.debug.assert(index < self.entities.items.len);
        std.debug.assert(self.retired.getLast().eql(entity.id));
        std.debug.assert(self.entities.items[index].id.eql(Entity.Id.invalid));

        self.entities.items[index] = entity;
        _ = self.retired.pop();
    }

    const row = entity.archetype_row;
    archetype.ids.appendAssumeCapacity(entity.id);
    const chunk_index = row / archetype.layout.capacity;
    std.debug.assert(chunk_index < archetype.chunks.items.len);
    archetype.chunks.items[chunk_index].len += 1;
}

/// Copies the parcels' archetype components into `row`. Cannot fail.
fn storeArchetypeComponents(
    self: *const Self,
    parcels: []const Parcel,
    archetype: *Archetype,
    row: usize,
) void {
    for (parcels) |parcel| {
        const meta = self.comp_reg.getByTypeId(parcel.meta.id).?;
        if (meta.storage != .archetype) continue;

        const column = archetype.meta.id_to_col.get(parcel.meta.id).?;
        const dest = archetype.at(column, row).data;
        std.debug.assert(dest.len == parcel.meta.size);
        if (dest.len != 0) @memcpy(dest, parcel.bytes());
    }
}

/// Copies the parcels' sparse components into their dense slots. Cannot fail.
///
/// `splitByStorage` writes sparse ids into the suffix from the end, so `sparse_ids` is in
/// reverse parcel order. `createEntity` resolves the sets in that same order, so walking the
/// parcels backwards here pairs each parcel with the set resolved for it, avoiding another
/// sparse-set lookup.
fn storeSparseComponents(
    self: *Self,
    parcels: []const Parcel,
    sparse_ids: []const SparseSet.Id,
    id: Entity.Id,
) void {
    var index: usize = 0;
    var parcel_index = parcels.len;
    while (parcel_index > 0) {
        parcel_index -= 1;
        const parcel = parcels[parcel_index];
        const meta = self.comp_reg.getByTypeId(parcel.meta.id).?;
        if (meta.storage != .sparse_set) continue;

        // Pair the reverse sparse suffix with parcels walked from the end.
        const set = self.sparse_reg.getById(sparse_ids[index]).?;
        const dense_index = set.len();
        if (set.meta.size != 0) {
            const dest = set.ptr + dense_index * set.meta.size;
            std.debug.assert(set.meta.size == parcel.meta.size);
            @memcpy(dest[0..set.meta.size], parcel.bytes());
        }
        set.entity_ids.appendAssumeCapacity(id);
        set.sparse_to_dense.items[id.index.get()] = .from(@intCast(dense_index));
        index += 1;
    }
    std.debug.assert(index == sparse_ids.len);
}

const testing = @import("testing.zig");
const Position = testing.Position;
const Velocity = testing.Velocity;
const Health = testing.Health;
const Probe = testing.Probe;
const AutoRequirement = testing.AutoRequirement;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const checkAllAllocationFailures = std.testing.checkAllAllocationFailures;
const TestMark = ecs.component.Mark;

test "addBundle stores components and reuses archetype and sparse storage" {
    const allocator = std.testing.allocator;
    var registry = Self.init(allocator);
    defer registry.deinit();
    inline for (.{ Position, Velocity, Health }) |T| _ = try registry.comp_reg.register(T);

    for (0..2) |i| {
        const value: i32 = @intCast(i + 1);
        const id = try registry.addBundle(try .init(allocator, .{
            Position{ .x = value, .y = 4 },
            Velocity{ .dx = value, .dy = 2 },
            Health{ .value = @intCast(value) },
        }));
        const entity = registry.get(id).?;
        try expectEqual(i, id.index.get());
        try expectEqual(i, entity.archetype_row);
        inline for (.{ Position, Velocity, Health }) |T| {
            const comp_id = registry.comp_reg.idOf(T).?;
            try expect(registry.hasComponent(id, comp_id));
            const bytes = registry.getComponent(id, comp_id).?;
            try expectEqual(@sizeOf(T), bytes.len);
            try expect(bytes.ptr == registry.getComponentMut(id, comp_id).?.ptr);
        }
        const archetype = registry.arche_reg.getById(entity.archetype_id).?;
        try testing.expectArchetypeValue(archetype, Position, i, .{ .x = value, .y = 4 });
        try testing.expectArchetypeValue(archetype, Velocity, i, .{ .dx = value, .dy = 2 });
        try expectEqual(
            @as(u32, @intCast(value)),
            registry.sparse_reg.getByTypeId(TypeId.of(Health)).?.set.get(Health, id).?.value,
        );
    }
    try expectEqual(1, registry.arche_reg.entries.items.len);
    try expectEqual(1, registry.sparse_reg.entries.items.len);
}

const RequirementGraph = struct {
    const Root = struct {
        pub const se_component: TestMark = .{ .require = &.{ Left, Right } };
        value: u32,
    };
    const Left = struct {
        pub const se_component: TestMark = .{ .require = &.{Shared} };
        value: u32 align(64) = 11,
    };
    const Right = struct {
        pub const se_component: TestMark = .{ .storage = .sparse_set, .require = &.{Shared} };
        value: u32,
        var calls: usize = 0;

        pub fn default() @This() {
            calls += 1;
            return .{ .value = 22 };
        }
    };
    const Shared = struct {
        pub const se_component: TestMark = .{ .require = &.{Root} };
        var created: usize = 0;
        var destroyed: usize = 0;

        pub fn default() @This() {
            created += 1;
            return .{};
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
            destroyed += 1;
        }
    };
};

test "addBundle completes shared cyclic requirements and preserves explicit values" {
    const G = RequirementGraph;
    G.Right.calls = 0;
    G.Shared.created = 0;
    G.Shared.destroyed = 0;
    {
        const allocator = std.testing.allocator;
        var registry = Self.init(allocator);
        defer registry.deinit();
        _ = try registry.comp_reg.register(G.Root);
        _ = try registry.comp_reg.register(Health);
        _ = try registry.addBundle(try Bundle.init(allocator, .{Health{ .value = 100 }}));

        const first = try registry.addBundle(try Bundle.init(allocator, .{
            G.Root{ .value = 1 },
            Health{ .value = 55 },
        }));
        const second = try registry.addBundle(try Bundle.init(allocator, .{
            G.Root{ .value = 2 },
            G.Left{ .value = 33 },
            G.Right{ .value = 44 },
            Health{ .value = 66 },
        }));
        const a = registry.get(first).?;
        const b = registry.get(second).?;
        inline for (.{ G.Root, G.Left, G.Right, G.Shared, Health }) |T| {
            const id = registry.comp_reg.idOf(T).?;
            try expect(a.signature.has(id));
            try expect(b.signature.has(id));
        }
        const archetype = registry.arche_reg.getById(a.archetype_id).?;
        try testing.expectArchetypeValue(archetype, G.Root, a.archetype_row, .{ .value = 1 });
        try testing.expectArchetypeValue(archetype, G.Left, a.archetype_row, .{});
        try testing.expectArchetypeValue(archetype, G.Left, b.archetype_row, .{ .value = 33 });
        const right = &registry.sparse_reg.getByTypeId(TypeId.of(G.Right)).?.set;
        const health = &registry.sparse_reg.getByTypeId(TypeId.of(Health)).?.set;
        try expectEqual(22, right.get(G.Right, first).?.value);
        try expectEqual(44, right.get(G.Right, second).?.value);
        try expectEqual(55, health.get(Health, first).?.value);
        try expectEqual(66, health.get(Health, second).?.value);
        try expectEqual(1, G.Right.calls);
        try expectEqual(2, G.Shared.created);
        try expectEqual(0, G.Shared.destroyed);
    }
    try expectEqual(2, G.Shared.destroyed);
}

test "addBundle validates runtime requirements and cleans up failed construction" {
    const Root = struct {};
    const Broken = struct {
        value: u8,

        fn wrongSize() u64 {
            return 42;
        }
    };
    const allocator = std.testing.allocator;
    var registry = Self.init(allocator);
    defer registry.deinit();
    AutoRequirement.created = 0;
    AutoRequirement.destroyed = 0;
    var bundle = try Bundle.init(allocator, .{Root{}});
    defer bundle.deinit();
    try expectError(error.UnknownComponentType, registry.addBundle(bundle));
    _ = try registry.comp_reg.reserve(TypeId.of(Root));
    try expectError(error.UnknownComponentType, registry.addBundle(bundle));

    const generated = try registry.comp_reg.register(AutoRequirement);
    const position = try registry.comp_reg.reserve(TypeId.of(Position));
    const broken = try registry.comp_reg.registerMeta(.{
        .type_meta = reflect.TypeMeta.of(Broken),
        .default = Default.initWithImpl(u64, Broken.wrongSize),
    });
    _ = try registry.comp_reg.registerMeta(.{
        .type_meta = reflect.TypeMeta.of(Root),
        .require = @constCast(&[_]CompId{ generated, position, broken }),
    });
    try expectError(error.UnknownRequirement, registry.addBundle(bundle));
    _ = try registry.comp_reg.register(Position);
    try expectError(error.MissingRequirementDefault, registry.addBundle(bundle));
    try expectEqual(0, AutoRequirement.created);

    try bundle.insert(Position{ .x = 3, .y = 4 });
    const ptr = bundle.map.values()[0].ptr;
    try expectError(error.BufferSizeMismatch, registry.addBundle(bundle));
    try expectEqual(1, AutoRequirement.created);
    try expectEqual(1, AutoRequirement.destroyed);
    try expectEqual(2, bundle.map.count());
    try expectEqual(ptr, bundle.map.values()[0].ptr);
    try expectEqual(0, registry.entities.items.len);

    try bundle.insert(Broken{ .value = 7 });
    const id = try registry.addBundle(bundle);
    bundle = .{ .allocator = allocator };
    try expect(registry.get(id).?.signature.has(generated));
    try expectEqual(2, AutoRequirement.created);

    // The same invalid default must leave an existing entity unchanged on modify.
    const empty = try registry.addBundle(try Bundle.init(allocator, .{}));
    var change = try Bundle.init(allocator, .{ Root{}, Position{ .x = 3, .y = 4 } });
    defer change.deinit();
    try expectError(error.BufferSizeMismatch, registry.modify(empty, change, &.{}));
    try expectEqual(0, registry.get(empty).?.signature.mask.count());
    try expectEqual(3, AutoRequirement.created);
    try expectEqual(2, AutoRequirement.destroyed);
}

test "addBundle destroys generated values but preserves input on layout failure" {
    const Huge = struct {
        pub const se_component: TestMark = .{ .require = &.{AutoRequirement} };
        calls: *usize,
        payload: [16 * 1024 + 1]u8 = undefined,

        pub fn deinit(self: *@This()) void {
            self.calls.* += 1;
        }
    };
    const allocator = std.testing.allocator;
    var registry = Self.init(allocator);
    defer registry.deinit();
    _ = try registry.comp_reg.register(Huge);
    AutoRequirement.created = 0;
    AutoRequirement.destroyed = 0;
    var calls: usize = 0;
    var bundle = try Bundle.init(allocator, .{Huge{ .calls = &calls }});
    const ptr = bundle.map.values()[0].ptr;

    try expectError(error.BufferTooLarge, registry.addBundle(bundle));
    try expectEqual(0, calls);
    try expectEqual(1, AutoRequirement.created);
    try expectEqual(1, AutoRequirement.destroyed);
    try expectEqual(0, registry.entities.items.len);
    try expectEqual(ptr, bundle.map.values()[0].ptr);
    bundle.deinit();
    try expectEqual(1, calls);
}

fn testRequirementAllocationFailures(allocator: Allocator) !void {
    const Root = struct {
        pub const se_component: TestMark = .{ .require = &.{AutoRequirement} };
        value: u32 = 9,
    };
    AutoRequirement.created = 0;
    AutoRequirement.destroyed = 0;
    var calls: usize = 0;
    {
        var registry = Self.init(allocator);
        defer registry.deinit();
        _ = try registry.comp_reg.register(Root);
        _ = try registry.comp_reg.register(Probe);
        // Keep the input independent of the failing world allocator.
        var bundle = try Bundle.init(std.testing.allocator, .{ Root{}, Probe{ .calls = &calls } });
        var consumed = false;
        defer if (!consumed) bundle.deinit();
        const ptr = bundle.map.values()[1].ptr;
        const id = registry.addBundle(bundle) catch |err| {
            try expectEqual(0, calls);
            try expectEqual(2, bundle.map.count());
            try expectEqual(ptr, bundle.map.values()[1].ptr);
            try expectEqual(AutoRequirement.created, AutoRequirement.destroyed);
            try expectEqual(0, registry.entities.items.len);
            for (registry.arche_reg.entries.items) |*entry|
                try expectEqual(0, entry.archetype.len());
            for (registry.sparse_reg.entries.items) |*entry| try expectEqual(0, entry.set.len());
            return err;
        };
        consumed = true;
        try expect(registry.get(id).?.signature
            .has(registry.comp_reg.idOf(AutoRequirement).?));
        try expectEqual(0, calls);
        try expectEqual(1, AutoRequirement.created);
        try expectEqual(0, AutoRequirement.destroyed);
    }
    try expectEqual(1, calls);
    try expectEqual(AutoRequirement.created, AutoRequirement.destroyed);
}

test "addBundle preserves input and cleans generated values on every allocation failure" {
    try checkAllAllocationFailures(std.testing.allocator, testRequirementAllocationFailures, .{});
}
