const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const ecs = engine.ecs;
const ComponentRegistry = ecs.component.Registry;
const CompId = ecs.component.Id;
const ArchetypeRegistry = ecs.entity.archetype.Registry;
const ArchetypeId = ecs.entity.archetype.Id;
const Archetype = ecs.entity.archetype.Archetype;
const SparseSetRegistry = ecs.entity.sparse_set.Registry;
const SparseSetId = ecs.entity.sparse_set.Id;
const Entity = ecs.entity.Entity;
const EntityId = ecs.entity.Id;

const reflect = engine.reflect;
const TypeId = reflect.TypeId;
const Parcel = reflect.Parcel;
const Bundle = reflect.Bundle;

comp_reg: ComponentRegistry,
arch_reg: ArchetypeRegistry,
sparse_reg: SparseSetRegistry,
entities: std.ArrayList(Entity),
retired: std.ArrayList(EntityId),
allocator: Allocator,

/// Creates an entity registry with empty component, archetype and sparse set
/// registries; free it with `deinit`.
pub fn init(allocator: Allocator) @This() {
    return .{
        .comp_reg = ComponentRegistry.init(allocator),
        .arch_reg = ArchetypeRegistry.init(allocator),
        .sparse_reg = SparseSetRegistry.init(allocator),
        .entities = .empty,
        .retired = .empty,
        .allocator = allocator,
    };
}

/// Releases every entity and all storage owned by the sub-registries.
pub fn deinit(self: *@This()) void {
    const allocator = self.allocator;
    for (self.entities.items) |*entity| entity.deinit(allocator);
    self.entities.deinit(allocator);
    self.retired.deinit(allocator);
    self.sparse_reg.deinit();
    self.arch_reg.deinit();
    self.comp_reg.deinit();
}

pub const Error = Allocator.Error || ecs.entity.archetype.ChunkLayout.Error || error{
    UnknownComponentType,
};

/// Creates an entity holding every value in `bundle`.
///
/// Every parcel's type must already be registered as a component in `comp_reg`;
/// otherwise `UnknownComponentType` is returned. Archetype components are moved into the
/// matching archetype, and sparse components are moved into their registered sparse sets.
///
/// Ownership of the bundle's values is consumed only on success: on failure the caller still
/// owns the bundle and must free it.
pub fn addBundle(self: *@This(), bundle: Bundle) Error!EntityId {
    const allocator = self.allocator;
    const parcels = bundle.map.values();

    const storage_split_ids = try allocator.alloc(CompId, parcels.len);
    defer allocator.free(storage_split_ids);

    const archetype_count = try self.splitByStorage(parcels, storage_split_ids);
    const archetype_components = storage_split_ids[0..archetype_count];
    const sparse_components = storage_split_ids[archetype_count..];

    const archetype_entry = try self.arch_reg.getOrCreate(archetype_components, self.comp_reg);
    const archetype_id = archetype_entry.id;
    const archetype = &archetype_entry.archetype;

    var entity = try self.createEntity(
        storage_split_ids,
        sparse_components,
        archetype_id,
        archetype.len(),
    );
    errdefer entity.deinit(allocator);

    try self.reserveStorage(archetype, entity.id, entity.sparse_comps.items);
    self.commitEntity(entity, archetype);

    self.storeArchetypeComponents(parcels, archetype, entity.archetype_row);
    self.storeSparseComponents(parcels, entity.sparse_comps.items, entity.id);

    var moved = bundle;
    moved.releaseStorage();
    return entity.id;
}

/// Partitions `ids` in place into an archetype prefix and a sparse suffix. Returns the
/// boundary index between them. Sparse ids are filled from the end, so that suffix is in
/// reverse parcel order.
fn splitByStorage(
    self: *const @This(),
    parcels: []const Parcel,
    ids: []CompId,
) Error!usize {
    std.debug.assert(ids.len == parcels.len);

    var archetype_end: usize = 0;
    var sparse_start: usize = ids.len;
    for (parcels) |parcel| {
        const meta = self.comp_reg.getMetaByType(parcel.meta.id) orelse
            return Error.UnknownComponentType;
        const comp_id = self.comp_reg.type_to_id.get(parcel.meta.id).?;
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
    self: *@This(),
    ids: []const CompId,
    sparse_components: []const CompId,
    archetype_id: ArchetypeId,
    archetype_row: usize,
) Error!Entity {
    const allocator = self.allocator;
    const id = if (self.retired.items.len != 0)
        self.retired.getLast()
    else
        EntityId.init(@intCast(self.entities.items.len), 0);
    try self.entities.ensureTotalCapacity(allocator, id.index.get() + 1);

    var entity = Entity.init(allocator, id);
    errdefer entity.deinit(allocator);

    try entity.signature.add(allocator, ids);
    try entity.sparse_comps.ensureTotalCapacity(allocator, sparse_components.len);
    for (sparse_components) |comp_id| {
        const meta = self.comp_reg.getMeta(comp_id).?;
        const set_entry = try self.sparse_reg.getOrCreate(meta.type_meta);
        entity.sparse_comps.appendAssumeCapacity(set_entry.id);
    }
    entity.archetype_id = archetype_id;
    entity.archetype_row = archetype_row;
    return entity;
}

/// Reserves room in the archetype and sparse sets before values leave the bundle.
fn reserveStorage(
    self: *@This(),
    archetype: *Archetype,
    id: EntityId,
    sparse_ids: []const SparseSetId,
) Error!void {
    try archetype.reserve(1);

    const allocator = self.allocator;
    for (sparse_ids) |sparse_id| {
        const set = &self.sparse_reg.entries.items[sparse_id.index.get()].set;
        try set.reserve(1);
        try set.sparse_to_dense.ensureTotalCapacity(allocator, id.index.get() + 1);
        while (set.sparse_to_dense.items.len <= id.index.get())
            set.sparse_to_dense.appendAssumeCapacity(.invalid);
    }
}

/// Publishes the entity and records its row in the archetype. Cannot fail.
fn commitEntity(self: *@This(), entity: Entity, archetype: *Archetype) void {
    const index = entity.id.index.get();
    if (index == self.entities.items.len) {
        self.entities.appendAssumeCapacity(entity);
    } else {
        // A retired id replaces an existing slot instead of appending a new one.
        std.debug.assert(index < self.entities.items.len);
        std.debug.assert(self.retired.getLast().eql(entity.id));
        std.debug.assert(self.entities.items[index].id.eql(EntityId.invalid));

        self.entities.items[index] = entity;
        _ = self.retired.pop();
    }

    const row = entity.archetype_row;
    archetype.ids.appendAssumeCapacity(entity.id);
    const chunk_index = row / archetype.layout.capacity;
    std.debug.assert(chunk_index < archetype.chunks.items.len);
    archetype.chunks.items[chunk_index].len += 1;
}

/// Copies the bundle's archetype components into `row`. Cannot fail.
fn storeArchetypeComponents(
    self: *const @This(),
    parcels: []const Parcel,
    archetype: *Archetype,
    row: usize,
) void {
    for (parcels) |parcel| {
        const meta = self.comp_reg.getMetaByType(parcel.meta.id).?;
        if (meta.storage != .archetype) continue;

        const column = archetype.meta.id_to_col.get(parcel.meta.id).?;
        const dest = archetype.at(column, row).data;
        std.debug.assert(dest.len == parcel.meta.size);
        if (dest.len != 0) @memcpy(dest, parcel.bytes());
    }
}

/// Copies the bundle's sparse components into their dense slots. Cannot fail.
///
/// `splitByStorage` writes sparse ids into the suffix from the end, so `sparse_ids` is in
/// reverse parcel order. `createEntity` resolves the sets in that same order, so walking the
/// parcels backwards here pairs each parcel with the set resolved for it, avoiding another
/// sparse-set lookup.
fn storeSparseComponents(
    self: *@This(),
    parcels: []const Parcel,
    sparse_ids: []const SparseSetId,
    id: EntityId,
) void {
    var index: usize = 0;
    var parcel_index = parcels.len;
    while (parcel_index > 0) {
        parcel_index -= 1;
        const parcel = parcels[parcel_index];
        const meta = self.comp_reg.getMetaByType(parcel.meta.id).?;
        if (meta.storage != .sparse_set) continue;

        // Pair the reverse sparse suffix with parcels walked from the end.
        const set = &self.sparse_reg.entries.items[sparse_ids[index].index.get()].set;
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

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

const TestMark = ecs.component.Mark;

const Position = struct {
    pub const se_component: TestMark = .{};
    x: i32,
    y: i32,
};

const Velocity = struct {
    pub const se_component: TestMark = .{};
    dx: i32,
    dy: i32,
};

const Health = struct {
    pub const se_component: TestMark = .{ .storage = .sparse_set };
    value: u32,
};

const Mana = struct {
    pub const se_component: TestMark = .{ .storage = .sparse_set };
    value: u32,
};

const Plain = struct {
    value: u32,
};

const Probe = struct {
    pub const se_component: TestMark = .{};
    calls: *usize,

    pub fn deinit(self: *@This()) void {
        self.calls.* += 1;
    }
};

fn expectArchetypeValue(
    archetype: *const Archetype,
    comptime T: type,
    row: usize,
    expected: T,
) !void {
    const column = archetype.meta.id_to_col.get(TypeId.of(T)).?;
    try expectEqual(expected, archetype.typedAt(T, column, row).ptr.*);
}

test "addBundle stores components and reuses archetype and sparse storage" {
    const allocator = std.testing.allocator;

    var registry = init(allocator);
    defer registry.deinit();

    const position_id = try registry.comp_reg.register(Position);
    const velocity_id = try registry.comp_reg.register(Velocity);
    const health_id = try registry.comp_reg.register(Health);

    const first = try registry.addBundle(try .init(allocator, .{
        Position{ .x = 3, .y = 4 },
        Velocity{ .dx = 1, .dy = 2 },
        Health{ .value = 11 },
    }));
    const second = try registry.addBundle(try .init(allocator, .{
        Position{ .x = 5, .y = 6 },
        Velocity{ .dx = 3, .dy = 4 },
        Health{ .value = 22 },
    }));

    try expectEqual(0, first.index.get());
    try expectEqual(1, second.index.get());
    try expectEqual(2, registry.entities.items.len);
    try expectEqual(1, registry.arch_reg.entries.items.len);
    try expectEqual(1, registry.sparse_reg.entries.items.len);

    const first_entity = &registry.entities.items[first.index.get()];
    const second_entity = &registry.entities.items[second.index.get()];
    try expect(first_entity.id.eql(first));
    try expect(first_entity.signature.has(position_id));
    try expect(first_entity.signature.has(velocity_id));
    try expect(first_entity.signature.has(health_id));
    try expect(first_entity.archetype_id.eql(second_entity.archetype_id));
    try expectEqual(0, first_entity.archetype_row);
    try expectEqual(1, second_entity.archetype_row);

    try expectEqual(1, first_entity.sparse_comps.items.len);
    try expectEqual(1, second_entity.sparse_comps.items.len);
    try expect(first_entity.sparse_comps.items[0].eql(second_entity.sparse_comps.items[0]));

    const archetype = registry.arch_reg.get(first_entity.archetype_id).?;
    try expectEqual(2, archetype.len());
    try expect(archetype.meta.signature.has(position_id));
    try expect(archetype.meta.signature.has(velocity_id));
    try expect(!archetype.meta.signature.has(health_id));

    try expectArchetypeValue(archetype, Position, 0, .{ .x = 3, .y = 4 });
    try expectArchetypeValue(archetype, Position, 1, .{ .x = 5, .y = 6 });
    try expectArchetypeValue(archetype, Velocity, 0, .{ .dx = 1, .dy = 2 });
    try expectArchetypeValue(archetype, Velocity, 1, .{ .dx = 3, .dy = 4 });

    const sparse_entry = registry.sparse_reg.entries.items[
        first_entity.sparse_comps.items[0].index.get()
    ];
    try expect(sparse_entry.id.eql(first_entity.sparse_comps.items[0]));
    try expectEqual(2, sparse_entry.set.len());
    try expectEqual(0, sparse_entry.set.sparse_to_dense.items[first.index.get()].get());
    try expectEqual(1, sparse_entry.set.sparse_to_dense.items[second.index.get()].get());

    const healths: [*]Health = @ptrCast(@alignCast(sparse_entry.set.ptr));
    try expectEqual(11, healths[0].value);
    try expectEqual(22, healths[1].value);
}

test "addBundle accepts an empty bundle" {
    const allocator = std.testing.allocator;
    var registry = init(allocator);
    defer registry.deinit();

    const id = try registry.addBundle(try .init(allocator, .{}));

    try expectEqual(1, registry.entities.items.len);
    try expectEqual(1, registry.arch_reg.entries.items.len);

    const entity = &registry.entities.items[id.index.get()];
    try expectEqual(0, entity.signature.mask.count());

    const archetype = registry.arch_reg.get(entity.archetype_id).?;
    try expectEqual(0, archetype.meta.columns.items.len);
    try expectEqual(1, archetype.len());
}

test "addBundle rejects types that are not registered components" {
    const allocator = std.testing.allocator;
    var registry = init(allocator);
    defer registry.deinit();
    _ = try registry.comp_reg.register(Position);

    var bundle: Bundle = try .init(allocator, .{
        Position{ .x = 3, .y = 4 },
        Plain{ .value = 7 },
    });
    try expectError(Error.UnknownComponentType, registry.addBundle(bundle));
    bundle.deinit();

    // Validation happens before any entity or storage is created.
    try expectEqual(0, registry.entities.items.len);
    try expectEqual(0, registry.arch_reg.entries.items.len);
    try expectEqual(0, registry.sparse_reg.entries.items.len);
}

test "addBundle takes ownership of managed values" {
    const allocator = std.testing.allocator;
    var calls: usize = 0;

    {
        var registry = init(allocator);
        defer registry.deinit();
        _ = try registry.comp_reg.register(Probe);

        _ = try registry.addBundle(try .init(allocator, .{
            Probe{ .calls = &calls },
        }));

        // The bundle only released its parcel storage; the registry now owns the value.
        try expectEqual(0, calls);
    }
    try expectEqual(1, calls);
}

test "addBundle matches each sparse component to its own set" {
    const allocator = std.testing.allocator;
    var registry = init(allocator);
    defer registry.deinit();
    _ = try registry.comp_reg.register(Health);
    _ = try registry.comp_reg.register(Mana);

    const id = try registry.addBundle(try .init(allocator, .{
        Health{ .value = 11 },
        Mana{ .value = 22 },
    }));

    try expectEqual(2, registry.entities.items[id.index.get()].sparse_comps.items.len);

    const health_set_id = registry.sparse_reg.type_to_id.get(TypeId.of(Health)).?;
    const mana_set_id = registry.sparse_reg.type_to_id.get(TypeId.of(Mana)).?;
    const health_set = &registry.sparse_reg.entries.items[health_set_id.index.get()].set;
    const mana_set = &registry.sparse_reg.entries.items[mana_set_id.index.get()].set;

    const health: *Health = @ptrCast(@alignCast(health_set.ptr));
    const mana: *Mana = @ptrCast(@alignCast(mana_set.ptr));
    try expectEqual(11, health.value);
    try expectEqual(22, mana.value);
}

test "addBundle reuses a retired entity slot" {
    const allocator = std.testing.allocator;
    var registry = init(allocator);
    defer registry.deinit();
    const position_id = try registry.comp_reg.register(Position);

    const first = try registry.addBundle(try .init(allocator, .{
        Position{ .x = 1, .y = 2 },
    }));
    const retired_id = EntityId.init(
        first.index.get(),
        first.generation.next().get(),
    );

    const slot = &registry.entities.items[first.index.get()];
    slot.deinit(allocator);
    slot.id = EntityId.invalid;
    try registry.retired.append(allocator, retired_id);

    const second = try registry.addBundle(try .init(allocator, .{
        Position{ .x = 3, .y = 4 },
    }));

    try expect(second.eql(retired_id));
    try expectEqual(0, registry.retired.items.len);
    try expectEqual(1, registry.entities.items.len);

    const entity = &registry.entities.items[second.index.get()];
    try expect(entity.id.eql(retired_id));
    try expect(entity.signature.has(position_id));
    try expectEqual(1, entity.archetype_row);

    const archetype = registry.arch_reg.get(entity.archetype_id).?;
    try expectArchetypeValue(archetype, Position, 1, .{ .x = 3, .y = 4 });
}
