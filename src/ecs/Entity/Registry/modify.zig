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
const TypeMeta = reflect.TypeMeta;
const Default = reflect.Default;
const AlignedBuffer = engine.base.AlignedBuffer;

const Self = ecs.Entity.Registry;
const _storage = @import("storage.zig");
const NormalizedFields = _storage.NormalizedFields;
const normalize = _storage.normalize;
const Column = _storage.Column;

pub const ModifyError = ecs.component.Registry.RegisterError ||
    Archetype.ChunkLayout.Error || Default.Error || error{
    /// A component id is unknown, stale, or has only been reserved.
    UnknownComponentType,
    /// A required component id is unknown, stale, or has only been reserved.
    UnknownRequirement,
    /// A missing required component has no default constructor.
    MissingRequirementDefault,
    /// The entity id is unknown, stale, or retired.
    UnknownEntity,
    /// A component appears more than once in an insertion or removal list.
    DuplicateComponent,
    /// A component is both inserted and removed.
    ConflictingComponentChange,
    /// A removed component is required by a surviving or inserted component.
    RequiredComponentRemoved,
};

/// Each row is .{ entity_id, fields }; explicit component sets must match across rows.
/// All ids must be unique and belong to archetype_id, checked with debug assertions.
/// Fills missing insertion requirements and reports the committed prefix in completed.
pub fn modifyBatch(
    self: *Self,
    archetype_id: Archetype.Id,
    batch: anytype,
    comptime remove: []const type,
    completed: *usize,
) ModifyError!void {
    completed.* = 0;
    if (comptime batch.len == 0) return;

    comptime var types: [batch.len]type = undefined;
    inline for (batch, 0..) |row, i| {
        const info = @typeInfo(@TypeOf(row));
        if (info != .@"struct" or !info.@"struct".is_tuple or
            info.@"struct".field_types.len != 2)
            @compileError("modifyBatch rows must be .{ entity_id, fields } tuples");
        types[i] = NormalizedFields(false, @TypeOf(row[1]));
    }
    var ids: [batch.len]Entity.Id = undefined;
    var normalized: @Tuple(&types) = undefined;
    inline for (batch, 0..) |row, i| {
        ids[i] = row[0];
        normalized[i] = normalize(false, row[1]);
    }
    const grouped = try self.group(normalized);
    const columns = grouped.columns();
    const boundary = @TypeOf(grouped).archetype_count;

    const remove_types = comptime Bundle.flatTypes(@Tuple(remove));
    var remove_ids: [remove_types.len]CompId = undefined;
    var remove_count: usize = 0;
    inline for (remove_types) |T| {
        comptime ecs.component.assertComponent(T, "modifyBatch remove");
        if (self.comp_reg.idOf(T)) |id| {
            if (self.comp_reg.getById(id) != null) {
                remove_ids[remove_count] = id;
                remove_count += 1;
            }
        }
    }
    try self.modifyBatchImpl(
        archetype_id,
        &ids,
        columns[0..boundary],
        columns[boundary..],
        remove_ids[0..remove_count],
        completed,
    );
}

const DenseWrite = struct {
    column: usize,
    meta: TypeMeta,
    input: ?[]const u8,
    default: ?Default = null,
    buffer: AlignedBuffer,
    initialized: usize = 0,
};

const SparseWrite = struct {
    id: CompId,
    set_id: SparseSet.Id,
    input: ?[]const u8,
};

const BatchChange = struct {
    source: Archetype.Id,
    target: Archetype.Id = .invalid,
    copies: std.ArrayList(Archetype.ColumnTransfer) = .empty,
    writes: std.ArrayList(DenseWrite) = .empty,
    drops: std.ArrayList(usize) = .empty,
    sparse: std.ArrayList(SparseWrite) = .empty,
    sparse_removals: std.ArrayList(SparseSet.Id) = .empty,

    fn deinit(self: *@This(), allocator: Allocator, committed: usize) void {
        for (self.writes.items) |*write| {
            if (write.input == null) {
                for (committed..write.initialized) |i| {
                    destroy(write.meta, write.buffer.ptr + i * write.meta.size);
                }
            }
            write.buffer.deinit(allocator);
        }
        self.copies.deinit(allocator);
        self.writes.deinit(allocator);
        self.drops.deinit(allocator);
        self.sparse.deinit(allocator);
        self.sparse_removals.deinit(allocator);
    }
};

const SparseDefault = struct { set_id: SparseSet.Id, value: Parcel };

const PreparedChange = struct {
    entity: Entity,
    defaults: std.ArrayList(SparseDefault) = .empty,

    fn deinit(self: *@This(), allocator: Allocator, committed: bool) void {
        for (self.defaults.items) |*item| {
            if (committed) item.value.releaseStorage(allocator) else item.value.deinit(allocator);
        }
        self.defaults.deinit(allocator);
        self.entity.deinit(allocator);
    }
};

/// Borrows packed columns and unique live ids belonging to archetype_id.
/// Input buffers must not alias ECS storage. Only committed values transfer ownership.
/// Fills requirements of explicit insertions; unrelated existing dependencies are not checked.
/// On failure, commits the prepared prefix and reports its length through completed.
pub fn modifyBatchImpl(
    self: *Self,
    archetype_id: Archetype.Id,
    ids: []const Entity.Id,
    archetype_columns: []const Column,
    sparse_columns: []const Column,
    remove_ids: []const CompId,
    completed: *usize,
) ModifyError!void {
    completed.* = 0;
    assertModifyBatch(self, archetype_id, ids, archetype_columns, sparse_columns);
    if (ids.len == 0) return;

    var plan = try planBatchChange(
        self,
        archetype_id,
        archetype_columns,
        sparse_columns,
        remove_ids,
        ids.len,
    );
    defer plan.deinit(self.allocator, completed.*);

    if (!plan.source.eql(plan.target))
        try self.arche_reg.getByIdMut(plan.target).?.reserve(ids.len);
    for (plan.sparse.items) |step|
        try self.sparse_reg.getByIdMut(step.set_id).?.reserve(ids.len);

    const prepared = try self.allocator.alloc(PreparedChange, ids.len);
    defer self.allocator.free(prepared);
    const rows = try self.allocator.alloc(usize, ids.len);
    defer self.allocator.free(rows);
    var count: usize = 0;
    const failure = prepareBatchPrefix(self, &plan, ids, prepared, rows, &count);
    defer releasePrepared(self.allocator, prepared[0..count], true);
    commitBatchChange(self, &plan, ids[0..count], prepared[0..count], rows[0..count]);
    completed.* = count;
    if (failure) |err| return err;
}

fn assertModifyBatch(
    self: *const Self,
    archetype_id: Archetype.Id,
    ids: []const Entity.Id,
    archetype_columns: []const Column,
    sparse_columns: []const Column,
) void {
    std.debug.assert(self.validateColumns(false, archetype_columns, sparse_columns, ids.len));
    for (ids, 0..) |id, i| {
        std.debug.assert(self.contains(id));
        std.debug.assert(self.get(id).?.archetype_id.eql(archetype_id));
        for (ids[0..i]) |previous| std.debug.assert(!id.eql(previous));
    }
}

fn hasId(ids: anytype, id: @TypeOf(ids[0])) bool {
    for (ids) |item| if (item.eql(id)) return true;
    return false;
}

fn findColumn(columns: []const Column, id: CompId) ?[]const u8 {
    for (columns) |column| if (column.id.eql(id)) return column.ptr;
    return null;
}

fn planBatchChange(
    self: *Self,
    source_id: Archetype.Id,
    archetype_columns: []const Column,
    sparse_columns: []const Column,
    remove_ids: []const CompId,
    count: usize,
) ModifyError!BatchChange {
    const allocator = self.allocator;
    var plan: BatchChange = .{ .source = source_id };
    errdefer plan.deinit(allocator, 0);
    for (remove_ids, 0..) |id, i| {
        if (self.comp_reg.getById(id) == null) return error.UnknownComponentType;
        if (hasId(remove_ids[0..i], id)) return error.DuplicateComponent;
        if (findColumn(archetype_columns, id) != null or findColumn(sparse_columns, id) != null)
            return error.ConflictingComponentChange;
    }

    // Walk only the insertion closure, including dependencies of already-present requirements.
    var required: std.ArrayList(CompId) = .empty;
    defer required.deinit(allocator);
    for (archetype_columns) |column| try required.append(allocator, column.id);
    for (sparse_columns) |column| try required.append(allocator, column.id);
    var cursor: usize = 0;
    while (cursor < required.items.len) : (cursor += 1) {
        const meta = self.comp_reg.getById(required.items[cursor]) orelse
            return error.UnknownRequirement;
        for (meta.require) |id| {
            if (hasId(remove_ids, id)) return error.RequiredComponentRemoved;
            if (!hasId(required.items, id)) try required.append(allocator, id);
        }
    }

    var dense_ids: std.ArrayList(CompId) = .empty;
    defer dense_ids.deinit(allocator);
    const source_meta = self.arche_reg.getById(source_id).?.meta;
    for (source_meta.columns.items, 0..) |column, i| {
        if (!hasId(remove_ids, column.id)) try dense_ids.append(allocator, column.id);
        if (hasId(remove_ids, column.id) or findColumn(archetype_columns, column.id) != null)
            try plan.drops.append(allocator, i);
    }
    for (required.items) |id| {
        const meta = self.comp_reg.getById(id).?;
        switch (meta.storage) {
            .archetype => {
                if (!hasId(dense_ids.items, id)) try dense_ids.append(allocator, id);
            },
            .sparse_set => {
                const set_id = (try self.sparse_reg.getOrCreate(meta.type_meta)).id;
                try plan.sparse.append(allocator, .{
                    .id = id,
                    .set_id = set_id,
                    .input = findColumn(sparse_columns, id),
                });
            },
        }
    }
    for (remove_ids) |id| {
        const meta = self.comp_reg.getById(id).?;
        if (meta.storage == .sparse_set) {
            if (self.sparse_reg.getByTypeId(meta.typeId())) |entry|
                try plan.sparse_removals.append(allocator, entry.id);
        }
    }

    const target = try self.arche_reg.getOrCreate(dense_ids.items, self.comp_reg);
    plan.target = target.id;
    for (target.archetype.meta.columns.items, 0..) |column, i| {
        const input = findColumn(archetype_columns, column.id);
        if (input == null) {
            if (source_meta.id_to_col.get(column.meta.id)) |source_column| {
                try plan.copies.append(allocator, .{ .source = source_column, .target = i });
                continue;
            }
        }
        var write: DenseWrite = .{
            .column = i,
            .meta = column.meta,
            .input = input,
            .buffer = AlignedBuffer.empty(column.meta.alignment),
        };
        if (input == null) {
            write.default = self.comp_reg.getById(column.id).?.default orelse
                return error.MissingRequirementDefault;
            const size = std.math.mul(usize, column.meta.size, count) catch
                return error.OutOfMemory;
            write.buffer = try AlignedBuffer.init(allocator, size, column.meta.alignment);
        }
        errdefer write.buffer.deinit(allocator);
        try plan.writes.append(allocator, write);
    }
    return plan;
}

fn prepareBatchPrefix(
    self: *Self,
    plan: *BatchChange,
    ids: []const Entity.Id,
    prepared: []PreparedChange,
    rows: []usize,
    count: *usize,
) ?ModifyError {
    for (ids, 0..) |id, i| {
        rows[i] = self.get(id).?.archetype_row;
        prepared[i] = prepareEntityChange(self, plan, id, i) catch |err| return err;
        count.* += 1;
    }
    return null;
}

fn prepareEntityChange(
    self: *Self,
    plan: *BatchChange,
    id: Entity.Id,
    offset: usize,
) ModifyError!PreparedChange {
    const allocator = self.allocator;
    const source = self.get(id).?;
    var prepared: PreparedChange = .{ .entity = Entity.init(allocator, id) };
    errdefer prepared.deinit(allocator, false);
    const entity = &prepared.entity;
    try entity.sparse_comps.ensureTotalCapacity(
        allocator,
        source.sparse_comps.items.len + plan.sparse.items.len,
    );
    for (source.sparse_comps.items) |set_id| {
        if (!hasId(plan.sparse_removals.items, set_id))
            entity.sparse_comps.appendAssumeCapacity(set_id);
    }
    for (plan.sparse.items) |step| {
        const set = self.sparse_reg.getByIdMut(step.set_id).?;
        if (set.getBytes(id) != null) continue;
        try set.reserveSparseIndex(id);
        entity.sparse_comps.appendAssumeCapacity(step.set_id);
        if (step.input == null) {
            const meta = self.comp_reg.getById(step.id).?;
            const factory = meta.default orelse return error.MissingRequirementDefault;
            try prepared.defaults.ensureUnusedCapacity(allocator, 1);
            const value = try Parcel.initDefault(allocator, meta.type_meta, factory);
            prepared.defaults.appendAssumeCapacity(.{ .set_id = step.set_id, .value = value });
        }
    }
    const target = self.arche_reg.getById(plan.target).?;
    const base = target.meta.signature;
    if (entity.sparse_comps.items.len == 0) {
        entity.signature = base;
    } else {
        entity.signature = try base.clone(allocator);
        for (entity.sparse_comps.items) |set_id| {
            const set = self.sparse_reg.getById(set_id).?;
            const comp_id = self.comp_reg.idOfTypeId(set.meta.id).?;
            try entity.signature.add(allocator, &.{comp_id});
        }
    }
    entity.archetype_id = plan.target;
    entity.archetype_row = if (plan.source.eql(plan.target))
        source.archetype_row
    else
        target.len() + offset;
    for (plan.writes.items) |*write| {
        if (write.default) |factory| {
            const bytes = (write.buffer.ptr + offset * write.meta.size)[0..write.meta.size];
            try factory.fill(bytes);
            write.initialized += 1;
        }
    }
    return prepared;
}

fn destroy(meta: TypeMeta, ptr: [*]u8) void {
    switch (meta.need_deinit) {
        .trivial => {},
        .managed => |deinit_fn| deinit_fn(ptr),
    }
}

/// All allocation and default construction precedes this point.
fn commitBatchChange(
    self: *Self,
    plan: *const BatchChange,
    ids: []const Entity.Id,
    prepared: []PreparedChange,
    rows: []const usize,
) void {
    if (ids.len == 0) return;
    const source = self.arche_reg.getByIdMut(plan.source).?;
    const target = self.arche_reg.getByIdMut(plan.target).?;
    const migrate = !plan.source.eql(plan.target);
    if (migrate) {
        target.stageEntities(ids);
        target.stageColumnsFromSrc(source, plan.copies.items, rows);
        for (plan.writes.items) |write| {
            const size = ids.len * write.meta.size;
            const bytes = write.input orelse write.buffer.ptr[0..size];
            target.stageColumn(write.column, bytes[0..size]);
        }
        target.commitRows(ids.len);
    }
    for (ids, prepared, 0..) |id, *change, i| {
        const entity = self.getMut(id).?;
        // Prior removals may have moved this entity, so resolve its row again.
        const row = entity.archetype_row;
        for (plan.drops.items) |column|
            destroy(source.meta.columns.items[column].meta, source.at(column, row).data.ptr);
        if (migrate) {
            if (source.swapRemoveWithoutDeinit(row)) |moved|
                self.getMut(moved).?.archetype_row = row;
        } else {
            for (plan.writes.items) |write| {
                const size = write.meta.size;
                @memcpy(target.at(write.column, row).data, write.input.?[i * size ..][0..size]);
            }
        }
        commitSparseChange(self, plan, change, id, i);
        std.mem.swap(Entity, entity, &change.entity);
    }
}

fn commitSparseChange(
    self: *Self,
    plan: *const BatchChange,
    prepared: *const PreparedChange,
    id: Entity.Id,
    row: usize,
) void {
    for (plan.sparse_removals.items) |set_id|
        _ = self.sparse_reg.getByIdMut(set_id).?.remove(id);
    for (plan.sparse.items) |step| {
        const input = step.input orelse continue;
        const set = self.sparse_reg.getByIdMut(step.set_id).?;
        const size = set.meta.size;
        const bytes = input[row * size ..][0..size];
        if (set.getBytesMut(id)) |dest| {
            destroy(set.meta, dest.ptr);
            @memcpy(dest, bytes);
        } else {
            set.appendBatchAssumeCapacity(&.{id}, bytes);
        }
    }
    for (prepared.defaults.items) |item| {
        const set = self.sparse_reg.getByIdMut(item.set_id).?;
        set.appendBatchAssumeCapacity(&.{id}, item.value.bytes());
    }
}

fn releasePrepared(allocator: Allocator, prepared: []PreparedChange, committed: bool) void {
    for (prepared) |*change| change.deinit(allocator, committed);
}

/// Modifies a live entity using registered component ids; replaces existing values
/// and ignores absent removals. Defaults missing requirements and rejects removing needed ones.
/// Consumes `insert` only on success; errors preserve entity values and input ownership.
pub fn modify(
    self: *Self,
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

    var plan = try planModify(self, source, insert_ids, remove_ids);
    defer plan.deinit(allocator);
    var prepared = try prepareModify(self, id, insert, plan);
    var committed = false;
    defer prepared.deinit(allocator, committed);

    commitModify(self, id, plan, &prepared);
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

/// The target storage ids, missing defaults, and component steps.
const ModifyPlan = struct {
    archetype_id: Archetype.Id = .invalid,
    sparse_comps: std.ArrayList(SparseSet.Id) = .empty,
    defaults: std.ArrayList(CompId) = .empty,
    steps: std.array_hash_map.Auto(CompId, ModifyStep) = .{},

    fn deinit(self: *@This(), allocator: Allocator) void {
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
    self: *Self,
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

    var plan: ModifyPlan = .{};
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
    self: *Self,
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
    const target = self.arche_reg.getByIdMut(plan.archetype_id).?;
    try prepared.entity.sparse_comps.appendSlice(allocator, plan.sparse_comps.items);
    if (plan.sparse_comps.items.len == 0) {
        prepared.entity.signature = target.meta.signature;
    } else {
        prepared.entity.signature = try target.meta.signature.clone(allocator);
        for (plan.steps.keys(), plan.steps.values()) |comp_id, step| {
            const location = step.target orelse continue;
            if (location == .sparse_set) try prepared.entity.signature.add(allocator, &.{comp_id});
        }
    }
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
    if (!entity.archetype_id.eql(plan.archetype_id)) try target.reserve(1);
    for (plan.steps.values()) |step| {
        const location = step.target orelse continue;
        if (location != .sparse_set or step.source != null) continue;
        try self.sparse_reg.getByIdMut(location.sparse_set).?.reserveForEntity(id);
    }
    return prepared;
}

fn modifyBytes(
    self: *Self,
    location: ModifyLocation,
    arch: *Archetype,
    row: usize,
    id: Entity.Id,
) []u8 {
    return switch (location) {
        .arche_col => |column| arch.at(column, row).data,
        .sparse_set => |set_id| self.sparse_reg.getByIdMut(set_id).?.getBytesMut(id).?,
    };
}

/// The sole ownership-transfer phase. Must remain allocation-free and infallible.
/// Fetches the current source row on each call, since earlier batch members may fill holes.
fn commitModify(self: *Self, id: Entity.Id, plan: ModifyPlan, prepared: *PreparedModify) void {
    const entity = self.getMut(id).?;
    const source = self.arche_reg.getByIdMut(entity.archetype_id).?;
    const target = self.arche_reg.getByIdMut(plan.archetype_id).?;
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
                    const removed = self.sparse_reg.getByIdMut(set_id).?.remove(id);
                    std.debug.assert(removed);
                },
            }
            continue;
        }
        if (step.source != null and step.value_index != null) {
            switch (step.meta.need_deinit) {
                .trivial => {},
                .managed => |deinit_fn| {
                    deinit_fn(modifyBytes(self, step.source.?, source, row, id).ptr);
                },
            }
        }
        const location = step.target.?;
        if (location == .sparse_set and step.source == null) {
            const set = self.sparse_reg.getByIdMut(location.sparse_set).?;
            const dense = set.len();
            set.entity_ids.appendAssumeCapacity(id);
            set.sparse_to_dense.items[id.index.get()] = .from(@intCast(dense));
        }
        const dest = modifyBytes(self, location, target, target_row, id);
        const bytes = if (step.value_index) |i|
            prepared.parcels.items[i].bytes()
        else
            modifyBytes(self, step.source.?, source, row, id);
        if (dest.len != 0 and dest.ptr != bytes.ptr) @memcpy(dest, bytes);
    }
    if (migrate) {
        if (source.swapRemoveWithoutDeinit(row)) |moved| self.getMut(moved).?.archetype_row = row;
    }
    prepared.entity.archetype_row = target_row;
    std.mem.swap(Entity, entity, &prepared.entity);
}

const testing = @import("testing.zig");
const Position = testing.Position;
const Velocity = testing.Velocity;
const Health = testing.Health;
const Probe = testing.Probe;
const AutoRequirement = testing.AutoRequirement;
const SparseProbe = testing.SparseProbe;
const DenseDefault = testing.DenseDefault;
const RequirementGraph = testing.RequirementGraph;
const SparseTag = testing.SparseTag;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const checkAllAllocationFailures = std.testing.checkAllAllocationFailures;
const TestMark = ecs.component.Mark;

fn testModifyAllocationFailures(allocator: Allocator, migrate: bool) !void {
    const Root = struct {
        pub const se_component: TestMark = .{ .require = &.{ Position, AutoRequirement } };
    };
    AutoRequirement.created = 0;
    AutoRequirement.destroyed = 0;
    var calls = [_]usize{ 0, 0, 0, 0 };
    {
        var registry = Self.init(allocator);
        defer registry.deinit();
        inline for (.{ Position, Velocity, Health, Probe, SparseProbe, Root }) |T|
            _ = try registry.comp_reg.register(T);
        var ids: [2]Entity.Id = undefined;
        for (&ids) |*id| {
            id.* = try registry.add(.{
                Position{ .x = 3, .y = 4 },        Velocity{ .dx = 5, .dy = 6 },
                Health{ .value = 7 },              Probe{ .calls = &calls[0] },
                SparseProbe{ .calls = &calls[2] },
            });
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
            try testing.expectArchetypeValue(arch, Probe, 0, .{ .calls = &calls[0] });
            try testing.expectArchetypeValue(arch, Position, 0, .{ .x = 3, .y = 4 });
            try testing.expectArchetypeValue(arch, Velocity, 0, .{ .dx = 5, .dy = 6 });
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
        try testing.expectArchetypeValue(arch, Probe, changed.archetype_row, .{ .calls = &calls[1] });
        try testing.expectArchetypeValue(arch, Position, changed.archetype_row, .{ .x = 3, .y = 4 });
        const sparse = &registry.sparse_reg.getByTypeId(TypeId.of(SparseProbe)).?.set;
        try expectEqual(&calls[3], sparse.get(SparseProbe, ids[0]).?.calls);
        try expectEqual(!migrate, registry.hasTypedComp(ids[0], Health));
        try expectEqual(migrate, registry.hasTypedComp(ids[0], Root));
        const survivor = registry.get(ids[1]).?;
        try expectEqual(@intFromBool(!migrate), survivor.archetype_row);
        try testing.expectArchetypeValue(
            registry.arche_reg.getById(old_arch).?,
            Probe,
            survivor.archetype_row,
            .{ .calls = &calls[0] },
        );
    }
    try expectEqual([_]usize{ 2, 1, 2, 1 }, calls);
    try expectEqual(AutoRequirement.created, AutoRequirement.destroyed);
}

fn testSharedSignatures(allocator: Allocator) !void {
    var registry = Self.init(allocator);
    defer registry.deinit();
    const position = try registry.comp_reg.register(Position);
    const velocity = try registry.comp_reg.register(Velocity);
    const health = try registry.comp_reg.register(Health);

    var ids: [2]Entity.Id = undefined;
    for (&ids) |*id| {
        id.* = try registry.add(.{Position{ .x = 1, .y = 2 }});
    }
    const original_arch = registry.get(ids[0]).?.archetype_id;
    const shared = registry.arche_reg.getById(original_arch).?.meta.signature;
    for (ids) |id| try expect(registry.get(id).?.signature.mask.masks == shared.mask.masks);
    try expect(shared.has(position));
    try expectError(error.ArchetypeNotEmpty, registry.arche_reg.remove(original_arch));

    const changes = .{
        .{ .insert = .{Health{ .value = 7 }}, .remove = &[_]CompId{} },
        .{ .insert = .{Velocity{ .dx = 3, .dy = 4 }}, .remove = &[_]CompId{} },
        .{ .insert = .{}, .remove = &[_]CompId{health} },
        .{ .insert = .{}, .remove = &[_]CompId{velocity} },
    };
    inline for (changes, 0..) |change, index| {
        const before = registry.get(ids[0]).?.*;
        var insert = try Bundle.init(std.testing.allocator, change.insert);
        registry.modify(ids[0], insert, change.remove) catch |err| {
            insert.deinit();
            const unchanged = registry.get(ids[0]).?;
            try expect(unchanged.signature.mask.masks == before.signature.mask.masks);
            try expect(unchanged.signature.eql(before.signature));
            try expect(unchanged.archetype_id.eql(before.archetype_id));
            try expect(registry.get(ids[1]).?.signature.mask.masks == shared.mask.masks);
            return err;
        };
        const entity = registry.get(ids[0]).?;
        const base = registry.arche_reg.getById(entity.archetype_id).?.meta.signature;
        try expectEqual(index >= 2, entity.signature.mask.masks == base.mask.masks);
        try expect(entity.signature.has(position));
        try expectEqual(index < 2, entity.signature.has(health));
        try expectEqual(index == 1 or index == 2, entity.signature.has(velocity));
        try expect(!base.has(health));
        try expect(!shared.has(health));
        try expect(!shared.has(velocity));
        try expect(registry.get(ids[1]).?.signature.mask.masks == shared.mask.masks);
    }

    try expect(registry.get(ids[0]).?.signature.mask.masks == shared.mask.masks);
    try expect(try registry.remove(ids[0]));
    try expect(registry.get(ids[1]).?.signature.mask.masks == shared.mask.masks);
    try expect(registry.get(ids[1]).?.signature.has(position));
    try expect(try registry.remove(ids[1]));
    try registry.arche_reg.remove(original_arch);
}

test "signature ownership survives sparse changes, migration and allocation failures" {
    try checkAllAllocationFailures(std.testing.allocator, testSharedSignatures, .{});
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
    var registry = Self.init(allocator);
    defer registry.deinit();
    const root = try registry.comp_reg.register(Root);
    const position = registry.comp_reg.idOf(Position).?;
    const id = try registry.add(.{});
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
    try expect(registry.hasComp(id, position));
    try expect(!registry.hasComp(id, root));
    // A no-op still consumes an empty bundle's retained allocation.
    try insert.map.ensureTotalCapacity(allocator, 1);
    try registry.modify(id, insert, &.{});
    insert = .{ .allocator = allocator };
}

test "modify cleans generated defaults when runtime requirement construction fails" {
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
    const id = try registry.add(.{});
    AutoRequirement.created = 0;
    AutoRequirement.destroyed = 0;
    const generated = try registry.comp_reg.register(AutoRequirement);
    const position = try registry.comp_reg.reserve(TypeId.of(Position));
    const broken = try registry.comp_reg.registerMeta(.{
        .type_meta = TypeMeta.of(Broken),
        .default = Default.initWithImpl(u64, Broken.wrongSize),
    });
    _ = try registry.comp_reg.registerMeta(.{
        .type_meta = TypeMeta.of(Root),
        .require = @constCast(&[_]CompId{ generated, position, broken }),
    });
    var insert = try Bundle.init(allocator, .{Root{}});
    defer insert.deinit();
    try expectError(error.UnknownRequirement, registry.modify(id, insert, &.{}));
    _ = try registry.comp_reg.register(Position);
    try expectError(error.MissingRequirementDefault, registry.modify(id, insert, &.{}));
    try expectEqual(0, AutoRequirement.created);
    try insert.insert(Position{ .x = 3, .y = 4 });
    try expectError(error.BufferSizeMismatch, registry.modify(id, insert, &.{}));
    try expectEqual(1, AutoRequirement.created);
    try expectEqual(1, AutoRequirement.destroyed);
    try expectEqual(2, insert.map.count());
    try expectEqual(0, registry.get(id).?.signature.mask.count());
}

test "modifyBatch fills insertion closure even when an existing requirement is not closed" {
    const Root = RequirementGraph.Root;
    const Left = RequirementGraph.Left;
    const Right = RequirementGraph.Right;
    const Shared = RequirementGraph.Shared;
    Right.calls = 0;
    Shared.created = 0;
    Shared.destroyed = 0;
    var registry = Self.init(std.testing.allocator);
    var live = true;
    defer if (live) registry.deinit();
    var ids: [2]Entity.Id = undefined;
    try registry.addBatch(.{ .{Root{ .value = 1 }}, .{Root{ .value = 2 }} }, &ids);
    registry.getTypedCompMut(ids[0], Right).?.value = 91;
    var completed: usize = 999;
    var archetype_id = registry.get(ids[0]).?.archetype_id;
    // Removing a dependency is allowed, even with Root and Left still present.
    try registry.modifyBatch(
        archetype_id,
        .{ .{ ids[0], .{} }, .{ ids[1], .{} } },
        &.{Shared},
        &completed,
    );
    try expectEqual(2, completed);
    try expectEqual(2, Shared.destroyed);
    archetype_id = registry.get(ids[0]).?.archetype_id;
    try registry.modifyBatch(archetype_id, .{.{ ids[1], .{} }}, &.{Right}, &completed);
    // An unrelated insertion leaves the broken dependency alone.
    try registry.modifyBatch(
        archetype_id,
        .{.{ ids[0], .{Health{ .value = 8 }} }},
        &.{},
        &completed,
    );
    try expect(!registry.hasTypedComp(ids[0], Shared));
    try registry.modifyBatch(archetype_id, .{
        .{ ids[0], .{Root{ .value = 11 }} },
        .{ ids[1], .{Root{ .value = 12 }} },
    }, &.{}, &completed);
    try expectEqual(2, completed);
    try expectEqual(3, Right.calls);
    try expectEqual(4, Shared.created);
    try expectEqual(91, registry.getTypedComp(ids[0], Right).?.value);
    try expectEqual(22, registry.getTypedComp(ids[1], Right).?.value);
    for (ids) |id| {
        try expect(registry.hasTypedComp(id, Shared));
        try expectEqual(11, registry.getTypedComp(id, Left).?.value);
    }
    registry.deinit();
    live = false;
    try expectEqual(Shared.created, Shared.destroyed);
}

test "modifyBatch commits only the prefix whose sparse requirements can be constructed" {
    const Root = struct {
        pub const se_component: TestMark = .{ .require = &.{ DenseDefault, Health } };
        value: usize,
    };
    DenseDefault.created = 0;
    DenseDefault.destroyed = 0;
    var registry = Self.init(std.testing.allocator);
    var live = true;
    defer if (live) registry.deinit();
    var ids: [3]Entity.Id = undefined;
    try registry.addMany(.{ .{Health{ .value = 3 }}, .{}, .{Health{ .value = 5 }} }, &ids);
    const source = registry.get(ids[0]).?.archetype_id;
    var completed: usize = 999;
    try expectError(error.MissingRequirementDefault, registry.modifyBatch(source, .{
        .{ ids[0], .{Root{ .value = 11 }} },
        .{ ids[1], .{Root{ .value = 12 }} },
        .{ ids[2], .{Root{ .value = 13 }} },
    }, &.{}, &completed));
    try expectEqual(1, completed);
    try expectEqual(11, registry.getTypedComp(ids[0], Root).?.value);
    try expectEqual(1, registry.getTypedComp(ids[0], DenseDefault).?.value);
    try expectEqual(3, registry.getTypedComp(ids[0], Health).?.value);
    for (ids[1..]) |id| {
        try expect(registry.get(id).?.archetype_id.eql(source));
        try expect(!registry.hasTypedComp(id, Root));
        try expect(!registry.hasTypedComp(id, DenseDefault));
    }
    try expectEqual(5, registry.getTypedComp(ids[2], Health).?.value);
    registry.deinit();
    live = false;
    try expectEqual(DenseDefault.created, DenseDefault.destroyed);
}

test "modifyBatch rejects conflicting changes and missing dense defaults before commit" {
    const Root = struct {
        pub const se_component: TestMark = .{ .require = &.{Position} };
    };
    var registry = Self.init(std.testing.allocator);
    defer registry.deinit();
    const id = try registry.add(.{});
    const source = registry.get(id).?.archetype_id;
    const root = try registry.comp_reg.register(Root);
    const position = registry.comp_reg.idOf(Position).?;
    const values = [_]Root{.{}};
    const columns = [_]Column{.{ .id = root, .ptr = std.mem.sliceAsBytes(&values) }};
    var completed: usize = 999;
    try expectError(
        error.ConflictingComponentChange,
        registry.modifyBatchImpl(source, &.{id}, &columns, &.{}, &.{root}, &completed),
    );
    try expectEqual(0, completed);
    try expectError(
        error.RequiredComponentRemoved,
        registry.modifyBatchImpl(source, &.{id}, &columns, &.{}, &.{position}, &completed),
    );
    try expectError(
        error.MissingRequirementDefault,
        registry.modifyBatchImpl(source, &.{id}, &columns, &.{}, &.{}, &completed),
    );
    try expectError(
        error.DuplicateComponent,
        registry.modifyBatchImpl(source, &.{id}, &.{}, &.{}, &.{ position, position }, &completed),
    );
    try expectError(
        error.UnknownComponentType,
        registry.modifyBatchImpl(source, &.{id}, &.{}, &.{}, &.{.invalid}, &completed),
    );
    try expectEqual(0, completed);
    try expect(registry.get(id).?.archetype_id.eql(source));
    try registry.modifyBatch(source, .{}, &.{}, &completed);
    try expectEqual(0, completed);
    try registry.modifyBatch(source, .{.{ id, .{} }}, &.{Velocity}, &completed);
    try expectEqual(1, completed);
}

test "modifyBatch gathers noncontiguous rows across chunks and repairs swapped entity rows" {
    const Wide = struct {
        pub const se_component: TestMark = .{};
        bytes: [1024]u8 align(64),
    };
    var registry = Self.init(std.testing.allocator);
    var live = true;
    defer if (live) registry.deinit();
    var calls: usize = 0;
    var ids: [40]Entity.Id = undefined;
    for (&ids, 0..) |*id, i| id.* = try registry.add(.{
        Wide{ .bytes = @splat(@intCast(i)) }, Probe{ .calls = &calls },
    });
    const source = registry.get(ids[0]).?.archetype_id;
    var target_ids: [3]Entity.Id = undefined;
    for (&target_ids) |*id| id.* = try registry.add(.{
        Wide{ .bytes = @splat(99) }, Velocity{ .dx = 99, .dy = 0 }, Probe{ .calls = &calls },
    });
    var selected: [27]Entity.Id = undefined;
    var values: [27]Velocity = undefined;
    var expected: [40]?i32 = @splat(null);
    for (&selected, &values, 0..) |*id, *value, i| {
        const index = i * 17 % ids.len;
        id.* = ids[index];
        value.* = .{ .dx = @intCast(i), .dy = 0 };
        expected[index] = value.dx;
    }
    const columns = [_]Column{.{
        .id = registry.comp_reg.idOf(Velocity).?,
        .ptr = std.mem.sliceAsBytes(&values),
    }};
    var completed: usize = 0;
    try registry.modifyBatchImpl(source, &selected, &columns, &.{}, &.{}, &completed);
    try expectEqual(selected.len, completed);
    try expect(registry.arche_reg.getById(source).?.chunks.items.len > 1);
    var batch: [27]struct { Entity.Id, struct { Velocity } } = undefined;
    for (&batch, selected, values) |*row, id, value| row.* = .{ id, .{value} };
    const target = registry.get(selected[0]).?.archetype_id;
    try registry.modifyBatch(target, batch, &.{}, &completed);
    try expectEqual(batch.len, completed);
    for (ids, 0..) |id, i| {
        const entity = registry.get(id).?;
        const archetype = registry.arche_reg.getById(entity.archetype_id).?;
        try expect(archetype.ids.items[entity.archetype_row].eql(id));
        const wide = registry.getTypedComp(id, Wide).?;
        for (wide.bytes) |byte| try expectEqual(i, byte);
        try expectEqual(expected[i] != null, registry.hasTypedComp(id, Velocity));
        if (expected[i]) |value| try expectEqual(value, registry.getTypedComp(id, Velocity).?.dx);
        try expect(entity.signature.mask.masks == archetype.meta.signature.mask.masks);
    }
    for (target_ids) |id| try expectEqual(99, registry.getTypedComp(id, Wide).?.bytes[0]);
    try expectEqual(0, calls);
    registry.deinit();
    live = false;
    try expectEqual(ids.len + target_ids.len, calls);
}

test "modifyBatch releases replacements and removals and returns to shared signatures" {
    var registry = Self.init(std.testing.allocator);
    var live = true;
    defer if (live) registry.deinit();
    var calls: [4]usize = @splat(0);
    SparseTag.destroyed = 0;
    var ids: [2]Entity.Id = undefined;
    for (&ids) |*id| id.* = try registry.add(.{
        Probe{ .calls = &calls[0] }, SparseProbe{ .calls = &calls[1] }, SparseTag{},
    });
    const source = registry.get(ids[0]).?.archetype_id;
    var completed: usize = 0;
    // In-place dense replacement; sparse insertion order may differ between rows.
    try registry.modifyBatch(source, .{
        .{ ids[0], .{ Probe{ .calls = &calls[2] }, SparseProbe{ .calls = &calls[3] } } },
        .{ ids[1], .{ SparseProbe{ .calls = &calls[3] }, Probe{ .calls = &calls[2] } } },
    }, &.{SparseTag}, &completed);
    try expectEqual([_]usize{ 2, 2, 0, 0 }, calls);
    try expectEqual(2, SparseTag.destroyed);
    try registry.modifyBatch(
        source,
        .{ .{ ids[0], .{} }, .{ ids[1], .{} } },
        &.{SparseProbe},
        &completed,
    );
    for (ids) |id| {
        const entity = registry.get(id).?;
        try expectEqual(0, entity.sparse_comps.items.len);
        try expect(entity.signature.mask.masks ==
            registry.arche_reg.getById(source).?.meta.signature.mask.masks);
    }
    try expectEqual([_]usize{ 2, 2, 0, 2 }, calls);
    try registry.modifyBatch(source, .{.{ ids[0], .{} }}, &.{Probe}, &completed);
    try expectEqual([_]usize{ 2, 2, 1, 2 }, calls);
    registry.deinit();
    live = false;
    try expectEqual([_]usize{ 2, 2, 2, 2 }, calls);
}

test "modifyBatch cleans the failed row when a runtime default rejects its storage" {
    const Root = struct {};
    const Broken = struct {
        value: u8,
        var attempts: usize = 0;
        var destroyed: usize = 0;

        fn fill(bytes: []u8) Default.Error!void {
            attempts += 1;
            if (attempts == 2) return error.BufferSizeMismatch;
            bytes[0] = 42;
        }

        pub fn deinit(_: *@This()) void {
            destroyed += 1;
        }
    };
    Broken.attempts = 0;
    Broken.destroyed = 0;
    DenseDefault.created = 0;
    DenseDefault.destroyed = 0;
    AutoRequirement.created = 0;
    AutoRequirement.destroyed = 0;
    var registry = Self.init(std.testing.allocator);
    var live = true;
    defer if (live) registry.deinit();
    var ids: [3]Entity.Id = undefined;
    try registry.addBatch(.{ .{}, .{}, .{} }, &ids);
    const source = registry.get(ids[0]).?.archetype_id;
    const dense = try registry.comp_reg.register(DenseDefault);
    const sparse = try registry.comp_reg.register(AutoRequirement);
    const broken = try registry.comp_reg.reserve(TypeId.of(Broken));
    const root = try registry.comp_reg.registerMeta(.{
        .type_meta = TypeMeta.of(Root),
        .require = @constCast(&[_]CompId{ dense, sparse, broken }),
    });
    const columns = [_]Column{.{ .id = root, .ptr = &.{} }};
    var completed: usize = 999;
    try expectError(
        error.UnknownRequirement,
        registry.modifyBatchImpl(source, &ids, &columns, &.{}, &.{}, &completed),
    );
    try expectEqual(0, completed);
    _ = try registry.comp_reg.registerMeta(.{
        .type_meta = TypeMeta.of(Broken),
        .default = .{ .ptr = Broken.fill },
    });
    try expectError(
        error.BufferSizeMismatch,
        registry.modifyBatchImpl(source, &ids, &columns, &.{}, &.{}, &completed),
    );
    try expectEqual(1, completed);
    try expectEqual(2, DenseDefault.created);
    try expectEqual(1, DenseDefault.destroyed);
    try expectEqual(2, AutoRequirement.created);
    try expectEqual(1, AutoRequirement.destroyed);
    try expect(registry.hasComp(ids[0], root));
    for (ids[1..]) |id| {
        try expect(registry.get(id).?.archetype_id.eql(source));
        try expectEqual(0, registry.get(id).?.signature.mask.count());
    }
    registry.deinit();
    live = false;
    try expectEqual(DenseDefault.created, DenseDefault.destroyed);
    try expectEqual(AutoRequirement.created, AutoRequirement.destroyed);
    try expectEqual(1, Broken.destroyed);
}

test "modifyBatch preserves prefix ownership through every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseFailures, .{true});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseFailures, .{false});
}

fn exerciseFailures(allocator: Allocator, migrate: bool) !void {
    const Root = struct {
        pub const se_component: TestMark = .{ .require = &.{ DenseDefault, AutoRequirement } };
    };
    DenseDefault.created = 0;
    DenseDefault.destroyed = 0;
    AutoRequirement.created = 0;
    AutoRequirement.destroyed = 0;
    var calls: [4]usize = @splat(0);
    var registry = Self.init(allocator);
    var live = true;
    defer if (live) registry.deinit();
    var ids: [3]Entity.Id = undefined;
    for (&ids) |*id| {
        const fields = .{ Probe{ .calls = &calls[0] }, SparseProbe{ .calls = &calls[1] } };
        id.* = if (migrate) try registry.add(fields) else try registry.add(.{Root{}} ++ fields);
    }
    const source = registry.get(ids[0]).?.archetype_id;
    var batch: [3]struct { Entity.Id, struct { Root, Probe, SparseProbe } } = undefined;
    for (&batch, ids) |*row, id| row.* = .{ id, .{
        Root{}, Probe{ .calls = &calls[2] }, SparseProbe{ .calls = &calls[3] },
    } };
    var completed: usize = 999;
    var failure: ?ModifyError = null;
    registry.modifyBatch(source, batch, &.{}, &completed) catch |err| {
        failure = err;
    };
    try expect(completed <= ids.len);
    try expectEqual([_]usize{ completed, completed, 0, 0 }, calls);
    for (ids, 0..) |id, i| {
        const entity = registry.get(id).?;
        const archetype = registry.arche_reg.getById(entity.archetype_id).?;
        try expect(archetype.ids.items[entity.archetype_row].eql(id));
        try expectEqual(i < completed or !migrate, registry.hasTypedComp(id, Root));
        try expectEqual(
            &calls[if (i < completed) 2 else 0],
            registry.getTypedComp(id, Probe).?.calls,
        );
        try expectEqual(
            &calls[if (i < completed) 3 else 1],
            registry.getTypedComp(id, SparseProbe).?.calls,
        );
    }
    const defaults = if (migrate) completed else ids.len;
    try expectEqual(defaults, DenseDefault.created - DenseDefault.destroyed);
    try expectEqual(defaults, AutoRequirement.created - AutoRequirement.destroyed);
    registry.deinit();
    live = false;
    try expectEqual([_]usize{ 3, 3, completed, completed }, calls);
    try expectEqual(DenseDefault.created, DenseDefault.destroyed);
    try expectEqual(AutoRequirement.created, AutoRequirement.destroyed);
    if (failure) |err| return err;
    try expectEqual(ids.len, completed);
}
