const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const ecs = engine.ecs;
const ComponentRegistry = ecs.component.Registry;
const CompId = ecs.component.Id;
const Archetype = ecs.Archetype;
const SparseSet = ecs.SparseSet;
const Entity = ecs.Entity;

const reflect = engine.reflect;
const TypeId = reflect.TypeId;
const Parcel = reflect.Parcel;
const Bundle = reflect.Bundle;
const Default = reflect.Default;
const TypeMeta = reflect.TypeMeta;

comp_reg: ComponentRegistry,
arche_reg: Archetype.Registry,
sparse_reg: SparseSet.Registry,
entities: std.ArrayList(Entity),
retired: std.ArrayList(Entity.Id),
allocator: Allocator,

/// Creates an entity registry with empty component, archetype and sparse set
/// registries; free it with `deinit`.
pub fn init(allocator: Allocator) @This() {
    return .{
        .comp_reg = ComponentRegistry.init(allocator),
        .arche_reg = Archetype.Registry.init(allocator),
        .sparse_reg = SparseSet.Registry.init(allocator),
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
    self.arche_reg.deinit();
    self.comp_reg.deinit();
}

/// Returns whether `id` identifies a live entity, including its generation.
pub fn contains(self: *const @This(), id: Entity.Id) bool {
    return self.entityIndex(id) != null;
}

/// Returns the number of live entities, excluding retired slots.
pub fn len(self: *const @This()) usize {
    return self.entities.items.len - self.retired.items.len;
}

/// Returns whether there are no live entities.
pub fn isEmpty(self: *const @This()) bool {
    return self.len() == 0;
}

/// Borrows entity metadata, or returns null if `id` is unknown, stale, or retired.
/// The pointer may be invalidated when another entity is created.
pub fn get(self: *const @This(), id: Entity.Id) ?*const Entity {
    const index = self.entityIndex(id) orelse return null;
    return &self.entities.items[index];
}

/// Mutably borrows entity metadata, or returns null if `id` is unknown, stale, or retired.
/// The pointer may be invalidated when another entity is created.
/// Callers must preserve the entity's storage and signature invariants.
pub fn getMut(self: *@This(), id: Entity.Id) ?*Entity {
    const index = self.entityIndex(id) orelse return null;
    return &self.entities.items[index];
}

/// Destroys a live entity and retires its next-generation id for reuse.
/// Returns false for unknown, stale, or retired ids. On allocation failure,
/// the entity and its components are unchanged. Retains component storage.
/// Invalidates borrows of removed or moved values and active storage iterators.
pub fn remove(self: *@This(), id: Entity.Id) Allocator.Error!bool {
    const index = self.entityIndex(id) orelse return false;
    try self.retired.ensureUnusedCapacity(self.allocator, 1);

    const entity = &self.entities.items[index];
    const row = entity.archetype_row;
    const archetype = self.arche_reg.getById(entity.archetype_id).?;
    if (archetype.swapRemove(row)) |moved| {
        self.getMut(moved).?.archetype_row = row;
    }
    for (entity.sparse_comps.items) |set_id| {
        const removed = self.sparse_reg.getById(set_id).?.remove(id);
        std.debug.assert(removed);
    }

    entity.deinit(self.allocator);
    entity.* = Entity.init(self.allocator, .invalid);
    self.retired.appendAssumeCapacity(id.nextGeneration());
    return true;
}

fn entityIndex(self: *const @This(), id: Entity.Id) ?usize {
    const index = id.index.tryGet() orelse return null;
    if (index >= self.entities.items.len) return null;
    if (!self.entities.items[index].id.eql(id)) return null;
    return index;
}

pub const ModifyError = AddBundleError || error{
    /// The entity id is unknown, stale, or retired.
    UnknownEntity,
    /// A component appears more than once in an insertion or removal list.
    DuplicateComponent,
    /// A component is both inserted and removed.
    ConflictingComponentChange,
    /// A removed component is required by a surviving or inserted component.
    RequiredComponentRemoved,
};

/// Modifies a live entity using registered component ids; replaces existing values
/// and ignores absent removals. Defaults missing requirements and rejects removing needed ones.
/// Consumes `insert` only on success; errors preserve entity values and input ownership.
pub fn modify(
    self: *@This(),
    id: Entity.Id,
    insert: Bundle,
    remove_ids: []const CompId,
) ModifyError!void {
    const source = self.get(id) orelse return error.UnknownEntity;
    if (insert.map.count() == 0 and remove_ids.len == 0) {
        var moved = insert;
        moved.releaseStorage();
        return;
    }
    const allocator = self.allocator;
    const insert_ids = try allocator.alloc(CompId, insert.map.count());
    defer allocator.free(insert_ids);
    for (insert.map.values(), insert_ids) |parcel, *comp_id| {
        comp_id.* = self.comp_reg.idOfTypeId(parcel.meta.id) orelse
            return error.UnknownComponentType;
    }

    var plan = try self.planModify(source, insert_ids, remove_ids);
    defer plan.deinit(allocator);
    var prepared = try self.prepareModify(id, insert, plan);
    var committed = false;
    defer prepared.deinit(allocator, committed);

    self.commitModify(id, plan, &prepared);
    committed = true;
    var moved = insert;
    moved.releaseStorage();
}

/// An archetype column index or sparse set id.
const ModifyLocation = union(enum) {
    arche_col: usize,
    sparse_set: SparseSet.Id,
};

/// A component's metadata, source and target locations, and insertion value index.
const ModifyStep = struct {
    meta: TypeMeta,
    source: ?ModifyLocation = null,
    target: ?ModifyLocation = null,
    value_index: ?usize = null,
    included: bool = true,
};

/// The target signature, storage ids, missing defaults, and component steps.
const ModifyPlan = struct {
    signature: Entity.Signature,
    archetype_id: Archetype.Id = .invalid,
    sparse_comps: std.ArrayList(SparseSet.Id) = .empty,
    defaults: std.ArrayList(CompId) = .empty,
    steps: std.array_hash_map.Auto(CompId, ModifyStep) = .{},

    fn deinit(self: *@This(), allocator: Allocator) void {
        self.signature.deinit(allocator);
        self.sparse_comps.deinit(allocator);
        self.defaults.deinit(allocator);
        self.steps.deinit(allocator);
    }
};

fn containsComp(ids: []const CompId, id: CompId) bool {
    for (ids) |candidate| if (candidate.eql(id)) return true;
    return false;
}

fn planModify(
    self: *@This(),
    source: *const Entity,
    insert_ids: []const CompId,
    remove_ids: []const CompId,
) ModifyError!ModifyPlan {
    const allocator = self.allocator;
    for (remove_ids, 0..) |id, i| {
        _ = self.comp_reg.getById(id) orelse return error.UnknownComponentType;
        if (containsComp(remove_ids[0..i], id)) return error.DuplicateComponent;
        if (containsComp(insert_ids, id)) return error.ConflictingComponentChange;
    }
    for (insert_ids, 0..) |id, i| {
        _ = self.comp_reg.getById(id) orelse return error.UnknownComponentType;
        if (containsComp(insert_ids[0..i], id)) return error.DuplicateComponent;
    }

    var plan: ModifyPlan = .{ .signature = Entity.Signature.init(allocator) };
    errdefer plan.deinit(allocator);
    const source_arch = self.arche_reg.getById(source.archetype_id).?;
    for (source_arch.meta.columns.items, 0..) |column, i| {
        try plan.steps.put(allocator, column.id, .{
            .meta = column.meta,
            .source = .{ .arche_col = i },
            .included = !containsComp(remove_ids, column.id),
        });
    }
    for (source.sparse_comps.items) |set_id| {
        const set = self.sparse_reg.getById(set_id).?;
        const comp_id = self.comp_reg.idOfTypeId(set.meta.id).?;
        try plan.steps.put(allocator, comp_id, .{
            .meta = set.meta,
            .source = .{ .sparse_set = set_id },
            .included = !containsComp(remove_ids, comp_id),
        });
    }
    for (insert_ids, 0..) |comp_id, i| {
        const entry = try plan.steps.getOrPut(allocator, comp_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{ .meta = self.comp_reg.getById(comp_id).?.type_meta };
        }
        entry.value_ptr.value_index = i;
    }

    // The ordered map doubles as a work queue, including existing components so
    // removals cannot break their requirements. Discovery terminates shared cycles.
    var index: usize = 0;
    while (index < plan.steps.count()) : (index += 1) {
        if (!plan.steps.values()[index].included) continue;
        const meta = self.comp_reg.getById(plan.steps.keys()[index]).?;
        for (meta.require) |required| {
            const required_meta = self.comp_reg.getById(required) orelse
                return error.UnknownRequirement;
            if (containsComp(remove_ids, required)) return error.RequiredComponentRemoved;
            const entry = try plan.steps.getOrPut(allocator, required);
            if (!entry.found_existing) entry.value_ptr.* = .{ .meta = required_meta.type_meta };
        }
    }

    var archetype_ids: std.ArrayList(CompId) = .empty;
    defer archetype_ids.deinit(allocator);
    for (plan.steps.keys(), plan.steps.values()) |comp_id, *step| {
        if (!step.included) continue;
        const meta = self.comp_reg.getById(comp_id).?;
        if (step.source == null and step.value_index == null) {
            if (meta.default == null) return error.MissingRequirementDefault;
            step.value_index = insert_ids.len + plan.defaults.items.len;
            try plan.defaults.append(allocator, comp_id);
        }
        try plan.signature.add(allocator, &.{comp_id});
        if (meta.storage == .archetype) try archetype_ids.append(allocator, comp_id);
    }
    plan.archetype_id = (try self.arche_reg.getOrCreate(archetype_ids.items, self.comp_reg)).id;
    const target = self.arche_reg.getById(plan.archetype_id).?;
    for (plan.steps.values()) |*step| {
        if (!step.included) continue;
        switch (self.comp_reg.getByTypeId(step.meta.id).?.storage) {
            .archetype => step.target = .{ .arche_col = target.meta.id_to_col.get(step.meta.id).? },
            .sparse_set => {
                const set_id = (try self.sparse_reg.getOrCreate(step.meta)).id;
                step.target = .{ .sparse_set = set_id };
                try plan.sparse_comps.append(allocator, set_id);
            },
        }
    }
    return plan;
}

/// Per-entity target metadata, explicit and default parcels, and explicit parcel count.
const PreparedModify = struct {
    entity: Entity,
    parcels: std.ArrayList(Parcel),
    explicit_count: usize,

    fn deinit(self: *@This(), allocator: Allocator, committed: bool) void {
        self.entity.deinit(allocator);
        for (self.parcels.items[self.explicit_count..]) |*parcel| {
            if (committed) parcel.releaseStorage(allocator) else parcel.deinit(allocator);
        }
        self.parcels.deinit(allocator);
    }
};

/// Prepares per-entity metadata, default values and capacity. No stored values
/// change ownership here; successfully reserved capacity need not be rolled back.
fn prepareModify(
    self: *@This(),
    id: Entity.Id,
    insert: Bundle,
    plan: ModifyPlan,
) ModifyError!PreparedModify {
    const allocator = self.allocator;
    var prepared: PreparedModify = .{
        .entity = Entity.init(allocator, id),
        .parcels = .empty,
        .explicit_count = 0,
    };
    errdefer prepared.deinit(allocator, false);
    prepared.entity.signature = try plan.signature.clone(allocator);
    try prepared.entity.sparse_comps.appendSlice(allocator, plan.sparse_comps.items);
    prepared.entity.archetype_id = plan.archetype_id;
    const value_count = insert.map.count() + plan.defaults.items.len;
    try prepared.parcels.ensureTotalCapacity(allocator, value_count);
    prepared.parcels.appendSliceAssumeCapacity(insert.map.values());
    prepared.explicit_count = prepared.parcels.items.len;
    for (plan.defaults.items) |comp_id| {
        const meta = self.comp_reg.getById(comp_id).?;
        const parcel = try Parcel.initDefault(allocator, meta.type_meta, meta.default.?);
        prepared.parcels.appendAssumeCapacity(parcel);
    }

    const entity = self.get(id).?;
    const target = self.arche_reg.getById(plan.archetype_id).?;
    if (!entity.archetype_id.eql(plan.archetype_id)) try target.reserve(1);
    for (plan.steps.values()) |step| {
        const location = step.target orelse continue;
        if (location != .sparse_set or step.source != null) continue;
        const set = self.sparse_reg.getById(location.sparse_set).?;
        try set.reserve(1);
        try set.sparse_to_dense.ensureTotalCapacity(allocator, id.index.get() + 1);
        while (set.sparse_to_dense.items.len <= id.index.get())
            set.sparse_to_dense.appendAssumeCapacity(.invalid);
    }
    return prepared;
}

fn modifyBytes(
    self: *@This(),
    location: ModifyLocation,
    arch: *Archetype,
    row: usize,
    id: Entity.Id,
) []u8 {
    return switch (location) {
        .arche_col => |column| arch.at(column, row).data,
        .sparse_set => |set_id| self.sparse_reg.getById(set_id).?.getBytes(id).?,
    };
}

/// The sole ownership-transfer phase. Must remain allocation-free and infallible.
/// Fetches the current source row on each call, since earlier batch members may fill holes.
fn commitModify(self: *@This(), id: Entity.Id, plan: ModifyPlan, prepared: *PreparedModify) void {
    const entity = self.getMut(id).?;
    const source = self.arche_reg.getById(entity.archetype_id).?;
    const target = self.arche_reg.getById(plan.archetype_id).?;
    const migrate = !entity.archetype_id.eql(plan.archetype_id);
    const row = entity.archetype_row;
    const target_row = if (migrate) target.appendUninitAssumeCapacity(id) else row;
    for (plan.steps.values()) |step| {
        if (step.target == null) {
            switch (step.source.?) {
                .arche_col => |column| switch (step.meta.need_deinit) {
                    .trivial => {},
                    .managed => |deinit_fn| deinit_fn(source.at(column, row).data.ptr),
                },
                .sparse_set => |set_id| {
                    const removed = self.sparse_reg.getById(set_id).?.remove(id);
                    std.debug.assert(removed);
                },
            }
            continue;
        }
        if (step.source != null and step.value_index != null) {
            switch (step.meta.need_deinit) {
                .trivial => {},
                .managed => |deinit_fn| {
                    deinit_fn(self.modifyBytes(step.source.?, source, row, id).ptr);
                },
            }
        }
        const location = step.target.?;
        if (location == .sparse_set and step.source == null) {
            const set = self.sparse_reg.getById(location.sparse_set).?;
            const dense = set.len();
            set.entity_ids.appendAssumeCapacity(id);
            set.sparse_to_dense.items[id.index.get()] = .from(@intCast(dense));
        }
        const dest = self.modifyBytes(location, target, target_row, id);
        const bytes = if (step.value_index) |i|
            prepared.parcels.items[i].bytes()
        else
            self.modifyBytes(step.source.?, source, row, id);
        if (dest.len != 0 and dest.ptr != bytes.ptr) @memcpy(dest, bytes);
    }
    if (migrate) {
        if (source.swapRemoveWithoutDeinit(row)) |moved| self.getMut(moved).?.archetype_row = row;
    }
    prepared.entity.archetype_row = target_row;
    std.mem.swap(Entity, entity, &prepared.entity);
}

/// Returns whether the live entity has the registered component.
/// Unknown, stale, or reserved-only component ids return false.
pub fn hasComponent(self: *const @This(), id: Entity.Id, comp_id: CompId) bool {
    const entity = self.get(id) orelse return false;
    _ = self.comp_reg.getById(comp_id) orelse return false;
    return entity.signature.has(comp_id);
}

/// Borrows a component's bytes, or returns null if the entity or component is absent.
/// Unknown, stale, or reserved-only ids return null. Does not create storage.
/// The slice may be invalidated by storage growth or structural changes.
pub fn getComponent(self: *const @This(), id: Entity.Id, comp_id: CompId) ?[]const u8 {
    return self.componentBytes(id, comp_id);
}

/// Mutably borrows a component's bytes, or returns null if the entity or component is absent.
/// Unknown, stale, or reserved-only ids return null. Does not create storage.
/// The slice may be invalidated by storage growth or structural changes.
pub fn getComponentMut(self: *@This(), id: Entity.Id, comp_id: CompId) ?[]u8 {
    return self.componentBytes(id, comp_id);
}

fn componentBytes(self: *const @This(), id: Entity.Id, comp_id: CompId) ?[]u8 {
    const entity = self.get(id) orelse return null;
    const meta = self.comp_reg.getById(comp_id) orelse return null;
    if (!entity.signature.has(comp_id)) return null;

    switch (meta.storage) {
        .archetype => {
            const index = entity.archetype_id.index.tryGet() orelse return null;
            if (index >= self.arche_reg.entries.items.len) return null;
            const entry = &self.arche_reg.entries.items[index];
            if (!entry.id.eql(entity.archetype_id)) return null;
            const column = entry.archetype.meta.id_to_col.get(meta.typeId()) orelse return null;
            return entry.archetype.at(column, entity.archetype_row).data;
        },
        .sparse_set => {
            const set_id = self.sparse_reg.type_to_id.get(meta.typeId()) orelse return null;
            const index = set_id.index.tryGet() orelse return null;
            if (index >= self.sparse_reg.entries.items.len) return null;
            const entry = &self.sparse_reg.entries.items[index];
            if (!entry.id.eql(set_id)) return null;
            return entry.set.getBytes(id);
        },
    }
}

pub const AddBundleError = AddParcelsError || Default.Error || error{
    /// A required component id is unknown, stale, or has only been reserved.
    UnknownRequirement,
    /// A missing required component has no default constructor.
    MissingRequirementDefault,
};

/// Creates an entity from registered components, default-constructing missing requirements.
/// Explicit values take precedence. Consumes `bundle` only on success.
pub fn addBundle(self: *@This(), bundle: Bundle) AddBundleError!Entity.Id {
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

    const id = try self.addParcels(parcels.items);
    for (parcels.items[explicit_count..]) |*parcel| parcel.releaseStorage(allocator);
    var moved = bundle;
    moved.releaseStorage();
    return id;
}

const AddParcelsError =
    Allocator.Error || Archetype.ChunkLayout.Error || SplitByStorageError;

/// Moves unique, fully resolved component values into storage only on success.
/// Borrows descriptors and buffers; the caller handles their cleanup.
fn addParcels(self: *@This(), parcels: []const Parcel) AddParcelsError!Entity.Id {
    const allocator = self.allocator;

    const storage_split_ids = try allocator.alloc(CompId, parcels.len);
    defer allocator.free(storage_split_ids);

    const archetype_count = try self.splitByStorage(parcels, storage_split_ids);
    const archetype_components = storage_split_ids[0..archetype_count];
    const sparse_components = storage_split_ids[archetype_count..];

    const archetype_entry = try self.arche_reg.getOrCreate(archetype_components, self.comp_reg);
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

    return entity.id;
}

const SplitByStorageError = error{UnknownComponentType};

/// Partitions `ids` in place into an archetype prefix and a sparse suffix. Returns the
/// boundary index between them. Sparse ids are filled from the end, so that suffix is in
/// reverse parcel order.
fn splitByStorage(
    self: *const @This(),
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
    self: *@This(),
    ids: []const CompId,
    sparse_components: []const CompId,
    archetype_id: Archetype.Id,
    archetype_row: usize,
) Allocator.Error!Entity {
    const allocator = self.allocator;
    const id = if (self.retired.items.len != 0)
        self.retired.getLast()
    else
        Entity.Id.init(self.entities.items.len, 0);
    try self.entities.ensureTotalCapacity(allocator, id.index.get() + 1);

    var entity = Entity.init(allocator, id);
    errdefer entity.deinit(allocator);

    try entity.signature.add(allocator, ids);
    try entity.sparse_comps.ensureTotalCapacity(allocator, sparse_components.len);
    for (sparse_components) |comp_id| {
        const meta = self.comp_reg.getById(comp_id).?;
        const set_entry = try self.sparse_reg.getOrCreate(meta.type_meta);
        entity.sparse_comps.appendAssumeCapacity(set_entry.id);
    }
    entity.archetype_id = archetype_id;
    entity.archetype_row = archetype_row;
    return entity;
}

/// Reserves room in the archetype and sparse sets before values leave the parcels.
fn reserveStorage(
    self: *@This(),
    archetype: *Archetype,
    id: Entity.Id,
    sparse_ids: []const SparseSet.Id,
) Allocator.Error!void {
    try archetype.reserve(1);

    const allocator = self.allocator;
    for (sparse_ids) |sparse_id| {
        const set = self.sparse_reg.getById(sparse_id).?;
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
    self: *const @This(),
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
    self: *@This(),
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

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const checkAllAllocationFailures = std.testing.checkAllAllocationFailures;

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

test "component access rejects absent and invalid ids without creating storage" {
    const allocator = std.testing.allocator;
    var registry = init(allocator);
    defer registry.deinit();
    const readonly: *const @This() = &registry;
    const position_id = try registry.comp_reg.register(Position);
    const health_id = try registry.comp_reg.register(Health);
    const reserved = try registry.comp_reg.reserve(TypeId.of(Probe));
    const empty = try registry.addBundle(try .init(allocator, .{}));

    for ([_]CompId{ position_id, health_id, reserved, .invalid, CompId.init(100, 0) }) |comp_id| {
        try expect(!readonly.hasComponent(empty, comp_id));
        try expect(readonly.getComponent(empty, comp_id) == null);
        try expect(registry.getComponentMut(empty, comp_id) == null);
    }
    try expectEqual(1, registry.arche_reg.entries.items.len);
    try expectEqual(0, registry.sparse_reg.entries.items.len);

    const id = try registry.addBundle(try .init(allocator, .{
        Position{ .x = 3, .y = 4 },
        Health{ .value = 7 },
    }));
    for ([_]CompId{ position_id, health_id }) |comp_id| {
        const stale = CompId.init(comp_id.index.get(), comp_id.generation.next().get());
        try expect(!readonly.hasComponent(id, stale));
        try expect(readonly.getComponent(id, stale) == null);
        try expect(registry.getComponentMut(id, stale) == null);
    }
    const stale = Entity.Id.init(id.index.get(), id.generation.next().get());
    try expect(!readonly.hasComponent(stale, position_id));
    try expect(readonly.getComponent(stale, position_id) == null);
    try expect(registry.getComponentMut(stale, position_id) == null);
}

test "addBundle stores components and reuses archetype and sparse storage" {
    const allocator = std.testing.allocator;
    var registry = init(allocator);
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
        try expectArchetypeValue(archetype, Position, i, .{ .x = value, .y = 4 });
        try expectArchetypeValue(archetype, Velocity, i, .{ .dx = value, .dy = 2 });
        try expectEqual(
            @as(u32, @intCast(value)),
            registry.sparse_reg.getByTypeId(TypeId.of(Health)).?.set.get(Health, id).?.value,
        );
    }
    try expectEqual(1, registry.arche_reg.entries.items.len);
    try expectEqual(1, registry.sparse_reg.entries.items.len);
}

test "empty entity access reports metadata and rejects invalid ids" {
    const allocator = std.testing.allocator;
    var registry = init(allocator);
    defer registry.deinit();

    const readonly: *const @This() = &registry;
    try expect(readonly.isEmpty());
    try expectEqual(0, readonly.len());
    const id = try registry.addBundle(try .init(allocator, .{}));
    try expect(!readonly.isEmpty());
    try expectEqual(1, readonly.len());
    try expect(readonly.contains(id));
    try expect(@TypeOf(readonly.get(id)) == ?*const Entity);
    try expect(readonly.get(id).? == registry.getMut(id).?);

    try expectEqual(1, registry.entities.items.len);
    try expectEqual(1, registry.arche_reg.entries.items.len);

    const entity = registry.get(id).?;
    try expectEqual(0, entity.signature.mask.count());

    const archetype = registry.arche_reg.getById(entity.archetype_id).?;
    try expectEqual(0, archetype.meta.columns.items.len);
    try expectEqual(1, archetype.len());
    for ([_]Entity.Id{
        .invalid,
        .{ .index = id.index },
        Entity.Id.init(1, 0),
        Entity.Id.init(id.index.get(), 1),
    }) |invalid| {
        try expect(!readonly.contains(invalid));
        try expect(readonly.get(invalid) == null);
        try expect(registry.getMut(invalid) == null);
    }
    try expect(try registry.remove(id));
    try expect(readonly.isEmpty());
    try expectEqual(0, archetype.len());
}

test "remove repairs storage, destroys values once, and retires ids for reuse" {
    const SparseProbe = struct {
        pub const se_component: TestMark = .{ .storage = .sparse_set };
        calls: *usize,

        pub fn deinit(self: *@This()) void {
            self.calls.* += 1;
        }
    };
    const allocator = std.testing.allocator;
    var archetype_calls: usize = 0;
    var sparse_calls: usize = 0;
    {
        var registry = init(allocator);
        defer registry.deinit();
        inline for (.{ Position, Probe, SparseProbe }) |T| _ = try registry.comp_reg.register(T);
        var ids: [2]Entity.Id = undefined;
        for (&ids, 0..) |*id, i| {
            id.* = try registry.addBundle(try .init(allocator, .{
                Position{ .x = @intCast(i), .y = 4 },
                Probe{ .calls = &archetype_calls },
                SparseProbe{ .calls = &sparse_calls },
            }));
        }
        // The last sparse value belongs to a different archetype.
        const sparse_only = try registry.addBundle(
            try .init(allocator, .{SparseProbe{ .calls = &sparse_calls }}),
        );
        try expect(try registry.remove(ids[0]));
        try expectEqual(1, archetype_calls);
        try expectEqual(1, sparse_calls);
        try expectEqual(2, registry.len());
        for ([_]Entity.Id{
            ids[0],
            ids[0].nextGeneration(),
            .invalid,
            Entity.Id.init(100, 0),
        }) |invalid|
            try expect(!try registry.remove(invalid));

        const moved = registry.get(ids[1]).?;
        try expectEqual(0, moved.archetype_row);
        const archetype = registry.arche_reg.getById(moved.archetype_id).?;
        try expectEqual(1, archetype.len());
        try expectArchetypeValue(archetype, Position, 0, .{ .x = 1, .y = 4 });
        const set = &registry.sparse_reg.getByTypeId(TypeId.of(SparseProbe)).?.set;
        try expectEqual(2, set.len());
        try expect(set.get(SparseProbe, ids[1]) != null);
        try expect(set.get(SparseProbe, sparse_only) != null);

        const reused = try registry.addBundle(try .init(allocator, .{}));
        try expect(reused.eql(ids[0].nextGeneration()));
        try expect(registry.contains(reused));
        try expect(!try registry.remove(ids[0]));
        try expectEqual(3, registry.entities.items.len);
        try expectEqual(0, registry.retired.items.len);
    }
    try expectEqual(2, archetype_calls);
    try expectEqual(3, sparse_calls);
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
        var registry = init(allocator);
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
        try expectArchetypeValue(archetype, G.Root, a.archetype_row, .{ .value = 1 });
        try expectArchetypeValue(archetype, G.Left, a.archetype_row, .{});
        try expectArchetypeValue(archetype, G.Left, b.archetype_row, .{ .value = 33 });
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

const AutoRequirement = struct {
    pub const se_component: TestMark = .{ .storage = .sparse_set };
    value: u32 = 7,
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

fn testModifyAllocationFailures(allocator: Allocator, migrate: bool) !void {
    const Root = struct {
        pub const se_component: TestMark = .{ .require = &.{ Position, AutoRequirement } };
    };
    const SparseProbe = struct {
        pub const se_component: TestMark = .{ .storage = .sparse_set };
        calls: *usize,

        pub fn deinit(self: *@This()) void {
            self.calls.* += 1;
        }
    };
    AutoRequirement.created = 0;
    AutoRequirement.destroyed = 0;
    var calls = [_]usize{ 0, 0, 0, 0 };
    {
        var registry = init(allocator);
        defer registry.deinit();
        inline for (.{ Position, Velocity, Health, Probe, SparseProbe, Root }) |T|
            _ = try registry.comp_reg.register(T);
        var ids: [2]Entity.Id = undefined;
        for (&ids) |*id| {
            var initial = try Bundle.init(std.testing.allocator, .{
                Position{ .x = 3, .y = 4 },        Velocity{ .dx = 5, .dy = 6 },
                Health{ .value = 7 },              Probe{ .calls = &calls[0] },
                SparseProbe{ .calls = &calls[2] },
            });
            id.* = registry.addBundle(initial) catch |err| {
                initial.deinit();
                return err;
            };
        }
        const old_arch = registry.get(ids[0]).?.archetype_id;
        var signature = try registry.get(ids[0]).?.signature.clone(std.testing.allocator);
        defer signature.deinit(std.testing.allocator);
        const replacements = .{ Probe{ .calls = &calls[1] }, SparseProbe{ .calls = &calls[3] } };
        var insert = if (migrate)
            try Bundle.init(std.testing.allocator, .{Root{}} ++ replacements)
        else
            try Bundle.init(std.testing.allocator, replacements);
        var consumed = false;
        defer if (!consumed) insert.deinit();
        const remove_ids: []const CompId = if (migrate)
            &.{ registry.comp_reg.idOf(Velocity).?, registry.comp_reg.idOf(Health).? }
        else
            &.{};
        registry.modify(ids[0], insert, remove_ids) catch |err| {
            try expectEqual([_]usize{ 0, 0, 0, 0 }, calls);
            try expectEqual(AutoRequirement.created, AutoRequirement.destroyed);
            const unchanged = registry.get(ids[0]).?;
            try expect(unchanged.signature.eql(signature));
            try expect(unchanged.archetype_id.eql(old_arch));
            try expectEqual(0, unchanged.archetype_row);
            const arch = registry.arche_reg.getById(old_arch).?;
            try expectEqual(2, arch.len());
            try expectArchetypeValue(arch, Probe, 0, .{ .calls = &calls[0] });
            try expectArchetypeValue(arch, Position, 0, .{ .x = 3, .y = 4 });
            try expectArchetypeValue(arch, Velocity, 0, .{ .dx = 5, .dy = 6 });
            const sparse = &registry.sparse_reg.getByTypeId(TypeId.of(SparseProbe)).?.set;
            try expectEqual(&calls[2], sparse.get(SparseProbe, ids[0]).?.calls);
            const health = &registry.sparse_reg.getByTypeId(TypeId.of(Health)).?.set;
            try expectEqual(7, health.get(Health, ids[0]).?.value);
            try expectEqual(@sizeOf(Probe), insert.map.get(TypeId.of(Probe)).?.bytes().len);
            return err;
        };
        consumed = true;
        try expectEqual([_]usize{ 1, 0, 1, 0 }, calls);
        try expectEqual(2, registry.len());
        const changed = registry.get(ids[0]).?;
        try expectEqual(migrate, !changed.archetype_id.eql(old_arch));
        const arch = registry.arche_reg.getById(changed.archetype_id).?;
        try expectArchetypeValue(arch, Probe, changed.archetype_row, .{ .calls = &calls[1] });
        try expectArchetypeValue(arch, Position, changed.archetype_row, .{ .x = 3, .y = 4 });
        const sparse = &registry.sparse_reg.getByTypeId(TypeId.of(SparseProbe)).?.set;
        try expectEqual(&calls[3], sparse.get(SparseProbe, ids[0]).?.calls);
        try expectEqual(!migrate, registry.hasComponent(ids[0], registry.comp_reg.idOf(Health).?));
        try expectEqual(migrate, registry.hasComponent(ids[0], registry.comp_reg.idOf(Root).?));
        const survivor = registry.get(ids[1]).?;
        try expectEqual(@intFromBool(!migrate), survivor.archetype_row);
        try expectArchetypeValue(
            registry.arche_reg.getById(old_arch).?,
            Probe,
            survivor.archetype_row,
            .{ .calls = &calls[0] },
        );
    }
    try expectEqual([_]usize{ 2, 1, 2, 1 }, calls);
    try expectEqual(AutoRequirement.created, AutoRequirement.destroyed);
}

test "modify preserves ownership on every allocation failure during migration or replacement" {
    for ([_]bool{ true, false }) |migrate| {
        try checkAllAllocationFailures(
            std.testing.allocator,
            testModifyAllocationFailures,
            .{migrate},
        );
    }
}

test "modify validates runtime changes and surviving requirements before consuming input" {
    const Root = struct {
        pub const se_component: TestMark = .{ .require = &.{Position} };
    };
    const allocator = std.testing.allocator;
    var registry = init(allocator);
    defer registry.deinit();
    const root = try registry.comp_reg.register(Root);
    const position = registry.comp_reg.idOf(Position).?;
    const id = try registry.addBundle(try Bundle.init(allocator, .{}));
    var insert = try Bundle.init(allocator, .{Root{}});
    defer insert.deinit();
    try expectError(error.UnknownEntity, registry.modify(.invalid, insert, &.{}));
    try expectError(error.UnknownComponentType, registry.modify(id, insert, &.{.invalid}));
    try expectError(
        error.DuplicateComponent,
        registry.modify(id, insert, &.{ position, position }),
    );
    try expectError(error.ConflictingComponentChange, registry.modify(id, insert, &.{root}));
    try expectError(error.MissingRequirementDefault, registry.modify(id, insert, &.{}));
    try expectEqual(1, insert.map.count());
    try expectEqual(0, registry.get(id).?.signature.mask.count());
    try insert.insert(Position{ .x = 8, .y = 9 });
    try registry.modify(id, insert, &.{});
    insert = .{ .allocator = allocator };
    try expectError(error.RequiredComponentRemoved, registry.modify(id, insert, &.{position}));
    try registry.modify(id, insert, &.{root});
    insert = .{ .allocator = allocator };
    try expect(registry.hasComponent(id, position));
    try expect(!registry.hasComponent(id, root));
    // A no-op still consumes an empty bundle's retained allocation.
    try insert.map.ensureTotalCapacity(allocator, 1);
    try registry.modify(id, insert, &.{});
    insert = .{ .allocator = allocator };
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
    var registry = init(allocator);
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
    var registry = init(allocator);
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
        var registry = init(allocator);
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

test "remove allocation failure preserves the entity and all component values" {
    const allocator = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var calls: usize = 0;
    var registry = init(allocator);
    defer registry.deinit();
    inline for (.{ Probe, Health }) |T| _ = try registry.comp_reg.register(T);
    const id = try registry.addBundle(try .init(allocator, .{
        Probe{ .calls = &calls }, Health{ .value = 17 },
    }));
    const archetype = registry.arche_reg.getById(registry.get(id).?.archetype_id).?;

    // Only retirement allocation fails; existing allocations still use the same backing allocator.
    registry.allocator = failing.allocator();
    try expect(!try registry.remove(.invalid));
    try expectError(error.OutOfMemory, registry.remove(id));
    try expectEqual(0, calls);
    try expect(registry.contains(id));
    try expectEqual(1, registry.len());
    try expectEqual(1, archetype.len());
    try expectEqual(0, registry.get(id).?.archetype_row);
    const set = &registry.sparse_reg.getByTypeId(TypeId.of(Health)).?.set;
    try expectEqual(17, set.get(Health, id).?.value);

    registry.allocator = allocator;
    try expect(try registry.remove(id));
    try expectEqual(1, calls);
    try expect(registry.isEmpty());
    try expectEqual(0, archetype.len());
}
