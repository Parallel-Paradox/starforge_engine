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
const Column = _storage.Column;
const NormalizedFields = _storage.NormalizedFields;
const normalize = _storage.normalize;
const deinitDefaults = _storage.deinitDefaults;

pub const AddError = ecs.component.Registry.RegisterError || Archetype.ChunkLayout.Error;

/// Creates one entity; explicit component ownership transfers only on success.
pub fn add(self: *Self, fields: anytype) AddError!Entity.Id {
    var ids: [1]Entity.Id = undefined;
    try self.addBatch(.{fields}, &ids);
    return ids[0];
}

/// Stops at the first error, retaining earlier entities and leaving remaining ids invalid.
pub fn addMany(self: *Self, many: anytype, ids: []Entity.Id) AddError!void {
    std.debug.assert(many.len == ids.len);
    @memset(ids, .invalid);
    inline for (many, 0..) |fields, i| ids[i] = try self.add(fields);
}

/// Adds rows with identical normalized component sets in one batch.
/// Stops at the first error, retaining committed entities and their output ids.
/// Only rows with valid output ids transfer ownership; remaining ids stay invalid.
pub fn addBatch(self: *Self, batch: anytype, ids: []Entity.Id) AddError!void {
    std.debug.assert(batch.len == ids.len);
    @memset(ids, .invalid);
    if (comptime batch.len == 0) return;

    comptime var types: [batch.len]type = undefined;
    inline for (batch, 0..) |fields, i| {
        types[i] = NormalizedFields(@TypeOf(fields));
    }
    var normalized: @Tuple(&types) = undefined;
    inline for (batch, 0..) |fields, i| normalized[i] = normalize(fields);
    errdefer inline for (batch, 0..) |fields, i| {
        if (ids[i].eql(.invalid))
            deinitDefaults(fields, &normalized[i]);
    };

    const grouped = try self.group(normalized);
    const columns = grouped.columns();
    const boundary = @TypeOf(grouped).archetype_count;
    try self.addBatchImpl(columns[0..boundary], columns[boundary..], ids);
}

/// Borrows packed columns and caller-owned output storage. Inputs must not alias ECS storage.
/// Columns must match their storage group, be unique and contain exactly ids.len values.
/// Registered requirements must be closed across both groups together.
/// On error, preserves committed rows and ids; uncommitted values remain borrowed.
pub fn addBatchImpl(
    self: *Self,
    archetype_columns: []const Column,
    sparse_columns: []const Column,
    ids: []Entity.Id,
) AddError!void {
    @memset(ids, .invalid);
    std.debug.assert(self.validateColumns(archetype_columns, sparse_columns, ids.len));
    if (ids.len == 0) return;

    const allocator = self.allocator;
    const comp_ids = try allocator.alloc(CompId, archetype_columns.len + sparse_columns.len);
    defer allocator.free(comp_ids);
    const dense_count = archetype_columns.len;
    for (archetype_columns, comp_ids[0..dense_count]) |column, *id| id.* = column.id;
    for (sparse_columns, comp_ids[dense_count..]) |column, *id| id.* = column.id;
    const entry = try self.arche_reg.getOrCreate(comp_ids[0..dense_count], self.comp_reg);
    const archetype = &entry.archetype;
    const sparse_ids = try allocator.alloc(SparseSet.Id, sparse_columns.len);
    defer allocator.free(sparse_ids);
    for (sparse_columns, sparse_ids) |column, *id| {
        const meta = self.comp_reg.getById(column.id).?;
        id.* = (try self.sparse_reg.getOrCreate(meta.type_meta)).id;
    }

    const reused = @min(ids.len, self.retired.items.len);
    const old_len = self.entities.items.len;
    const final_len = std.math.add(usize, old_len, ids.len - reused) catch
        return error.OutOfMemory;
    try self.entities.ensureTotalCapacity(allocator, final_len);
    try archetype.reserve(ids.len);
    for (sparse_ids) |id| try self.sparse_reg.getById(id).?.reserve(ids.len);

    // Prepare directly in inactive registry slots; their ids stay invalid until commit.
    // After preparation, publishing the successful prefix cannot fail.
    var prepared: usize = 0;
    var failure: ?Allocator.Error = null;
    for (0..ids.len) |i| {
        const id = if (i < reused)
            self.retired.items[self.retired.items.len - 1 - i]
        else
            Entity.Id.init(old_len + i - reused, 0);
        var entity = prepareBatchEntity(
            self,
            entry,
            comp_ids[dense_count..],
            sparse_ids,
            id,
            i,
        ) catch |err| {
            failure = err;
            break;
        };
        entity.id = .invalid;
        self.entities.allocatedSlice()[id.index.get()] = entity;
        prepared += 1;
    }
    // From here on, all operations are infallible. The output buffer also supplies staged ids.
    for (ids[0..prepared], 0..) |*id, i| {
        id.* = if (i < reused)
            self.retired.items[self.retired.items.len - 1 - i]
        else
            Entity.Id.init(old_len + i - reused, 0);
    }
    commitBatch(self, archetype, archetype_columns, sparse_columns, sparse_ids, ids[0..prepared]);
    self.retired.items.len -= @min(prepared, reused);
    self.entities.items.len = old_len + prepared - @min(prepared, reused);
    if (failure) |err| return err;
}

fn prepareBatchEntity(
    self: *Self,
    entry: *const Archetype.Registry.Entry,
    sparse_components: []const CompId,
    sparse_ids: []const SparseSet.Id,
    id: Entity.Id,
    offset: usize,
) Allocator.Error!Entity {
    var entity = Entity.init(self.allocator, id);
    errdefer entity.deinit(self.allocator);
    try entity.sparse_comps.ensureTotalCapacity(self.allocator, sparse_components.len);
    for (sparse_ids) |set_id| {
        try self.sparse_reg.getById(set_id).?.reserveForEntity(id);
        entity.sparse_comps.appendAssumeCapacity(set_id);
    }
    const base = entry.archetype.meta.signature;
    if (sparse_components.len == 0) {
        entity.signature = base;
    } else {
        entity.signature = try base.clone(self.allocator);
        try entity.signature.add(self.allocator, sparse_components);
    }
    entity.archetype_id = entry.id;
    entity.archetype_row = entry.archetype.len() + offset;
    return entity;
}

/// Publishes a fully prepared prefix without allocation or component destruction.
fn commitBatch(
    self: *Self,
    archetype: *Archetype,
    archetype_columns: []const Column,
    sparse_columns: []const Column,
    sparse_ids: []const SparseSet.Id,
    ids: []const Entity.Id,
) void {
    if (ids.len == 0) return;
    archetype.stageEntities(ids);
    for (archetype_columns) |column| {
        const meta = self.comp_reg.getById(column.id).?;
        const index = archetype.meta.id_to_col.get(meta.typeId()).?;
        const size = meta.type_meta.size;
        archetype.stageColumn(index, column.ptr[0 .. ids.len * size]);
    }
    for (sparse_columns, sparse_ids) |column, set_id| {
        const set = self.sparse_reg.getById(set_id).?;
        const size = set.meta.size;
        set.appendBatchAssumeCapacity(ids, column.ptr[0 .. ids.len * size]);
    }
    archetype.commitRows(ids.len);
    for (ids) |id| self.entities.allocatedSlice()[id.index.get()].id = id;
}

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

    for (sparse_ids) |sparse_id| try self.sparse_reg.getById(sparse_id).?.reserveForEntity(id);
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
const RequirementGraph = testing.RequirementGraph;
const SparseTag = testing.SparseTag;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const checkAllAllocationFailures = std.testing.checkAllAllocationFailures;
const TestMark = ecs.component.Mark;

test "addBatch stages columns, reuses retired ids and preserves input buffers" {
    var registry = Self.init(std.testing.allocator);
    defer registry.deinit();
    const retired = try registry.add(.{ Position{ .x = 0, .y = 0 }, Health{ .value = 0 } });
    try expect(try registry.remove(retired));
    var ids: [3]Entity.Id = undefined;
    const rows = .{
        .{ Position{ .x = 1, .y = 2 }, Health{ .value = 3 } },
        .{ Health{ .value = 6 }, Position{ .x = 4, .y = 5 } },
        .{ Position{ .x = 7, .y = 8 }, Health{ .value = 9 } },
    };
    try registry.addBatch(rows, &ids);
    try expectEqual(3, registry.len());
    try expectEqual(retired.index.get(), ids[0].index.get());
    try expect(!retired.eql(ids[0]));
    for (ids, 0..) |id, i| {
        const entity = registry.get(id).?;
        const archetype = registry.arche_reg.getById(entity.archetype_id).?;
        try testing.expectArchetypeValue(archetype, Position, i, .{
            .x = @intCast(1 + i * 3),
            .y = @intCast(2 + i * 3),
        });
        const set = &registry.sparse_reg.getByTypeId(TypeId.of(Health)).?.set;
        try expectEqual(@as(u32, @intCast(3 + i * 3)), set.get(Health, id).?.value);
        try expect(entity.signature.has(registry.comp_reg.idOf(Health).?));
        try expect(!archetype.meta.signature.has(registry.comp_reg.idOf(Health).?));
    }
    try expectEqual(1, rows[0][0].x);
    try expectEqual(9, rows[2][1].value);
}

test "addMany supports heterogeneous rows, empty entities and shared dense signatures" {
    var registry = Self.init(std.testing.allocator);
    defer registry.deinit();
    var ids: [3]Entity.Id = undefined;
    try registry.addMany(.{ .{}, .{Position{ .x = 1, .y = 2 }}, .{Health{ .value = 3 }} }, &ids);
    for (ids[0..2]) |id| {
        const entity = registry.get(id).?;
        const archetype = registry.arche_reg.getById(entity.archetype_id).?;
        try expectEqual(0, entity.sparse_comps.items.len);
        try expect(entity.signature.eql(archetype.meta.signature));
    }
    try expectEqual(3, registry.len());
    var empty: [0]Entity.Id = .{};
    try registry.addBatch(.{}, &empty);
    try registry.addMany(.{}, &empty);
}

test "addBatch handles every allocation failure without losing component ownership" {
    try checkAllAllocationFailures(std.testing.allocator, exerciseBatchFailures, .{});
}

fn exerciseBatchFailures(allocator: Allocator) !void {
    const Root = struct {
        pub const se_component: TestMark = .{ .require = &.{AutoRequirement} };
        value: usize,
    };
    AutoRequirement.created = 0;
    AutoRequirement.destroyed = 0;
    var calls: [3]usize = @splat(0);
    var registry = Self.init(allocator);
    var live = true;
    defer if (live) registry.deinit();
    const retired = try registry.add(.{});
    try expect(try registry.remove(retired));
    var ids: [3]Entity.Id = undefined;
    var failure: ?AddError = null;
    registry.addBatch(.{
        .{ Root{ .value = 1 }, Probe{ .calls = &calls[0] } },
        .{ Root{ .value = 2 }, Probe{ .calls = &calls[1] } },
        .{ Root{ .value = 3 }, Probe{ .calls = &calls[2] } },
    }, &ids) catch |err| {
        failure = err;
    };
    var committed: usize = 0;
    var invalid_seen = false;
    for (ids) |id| {
        if (id.eql(.invalid)) {
            invalid_seen = true;
            continue;
        }
        try expect(!invalid_seen);
        try expect(registry.contains(id));
        committed += 1;
    }
    try expectEqual(committed, registry.len());
    try expectEqual(1 - @min(committed, 1), registry.retired.items.len);
    if (committed != 0) {
        try expectEqual(retired.index.get(), ids[0].index.get());
        try expect(!retired.eql(ids[0]));
    }
    try expectEqual(AutoRequirement.created - committed, AutoRequirement.destroyed);
    registry.deinit();
    live = false;
    try expectEqual(AutoRequirement.created, AutoRequirement.destroyed);
    for (calls, 0..) |count, i| try expectEqual(@as(usize, @intFromBool(i < committed)), count);
    if (failure) |err| return err;
    try expectEqual(3, committed);
}

test "addMany retains earlier entities when a later archetype is too large" {
    const Huge = struct {
        pub const se_component: TestMark = .{};
        bytes: [Archetype.ChunkLayout.max_size_byte + 1]u8 = @splat(0),
    };
    var registry = Self.init(std.testing.allocator);
    var calls: usize = 0;
    var ids: [3]Entity.Id = undefined;
    try expectError(error.BufferTooLarge, registry.addMany(.{
        .{Probe{ .calls = &calls }},
        .{Huge{}},
        .{Position{ .x = 1, .y = 2 }},
    }, &ids));
    try expect(registry.contains(ids[0]));
    try expect(ids[1].eql(.invalid));
    try expect(ids[2].eql(.invalid));
    try expectEqual(1, registry.len());
    try expectEqual(0, calls);
    registry.deinit();
    try expectEqual(1, calls);
}

test "addBatchImpl borrows runtime columns across chunks with zero sized sparse values" {
    const Wide = struct {
        pub const se_component: TestMark = .{};
        bytes: [1024]u8 align(64),
    };
    SparseTag.destroyed = 0;
    var registry = Self.init(std.testing.allocator);
    var values: [37]Wide = undefined;
    for (&values, 0..) |*value, i| @memset(&value.bytes, @intCast(i));
    const columns = [_]Column{
        .{ .id = try registry.comp_reg.register(SparseTag), .ptr = &.{} },
        .{ .id = try registry.comp_reg.register(Wide), .ptr = std.mem.sliceAsBytes(&values) },
    };
    for (0..2) |batch_index| {
        var ids: [37]Entity.Id = undefined;
        try registry.addBatchImpl(columns[1..], columns[0..1], &ids);
        const archetype = registry.arche_reg.getById(registry.get(ids[0]).?.archetype_id).?;
        const set = &registry.sparse_reg.getByTypeId(TypeId.of(SparseTag)).?.set;
        try expect(archetype.chunks.items.len > 1);
        for (ids, 0..) |id, i| {
            const row = registry.get(id).?.archetype_row;
            const value = archetype.typedAt(Wide, 0, row).ptr;
            try expectEqual(batch_index * ids.len + i, row);
            try expectEqual(values[i], value.*);
            try expectEqual(0, @intFromPtr(value) % 64);
            try expect(set.get(SparseTag, id) != null);
        }
    }
    registry.deinit();
    try expectEqual(74, SparseTag.destroyed);
}

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
