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
const Columns = _storage.Columns;

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
    /// A removed component belongs to the insertion requirement closure.
    RequiredComponentRemoved,
};

/// Modifies one live entity, consuming explicit values only on success.
/// Completes insertion requirements and ignores absent removals.
pub fn modify(
    self: *Self,
    id: Entity.Id,
    fields: anytype,
    comptime remove: []const type,
) ModifyError!void {
    if (!self.contains(id)) return error.UnknownEntity;
    var completed: usize = 0;
    try self.modifyBatch(.{.{ id, fields }}, remove, &completed);
}

/// Processes .{ entity_id, fields } rows independently, stopping at the first error.
/// Archetypes and component sets may differ; only the completed prefix consumes values.
pub fn modifyMany(
    self: *Self,
    many: anytype,
    comptime remove: []const type,
    completed: *usize,
) ModifyError!void {
    completed.* = 0;
    inline for (many) |row| {
        try self.modify(row[0], row[1], remove);
        completed.* += 1;
    }
}

/// Each row is .{ entity_id, fields }; explicit component sets must match across rows.
/// All ids must be unique, live and belong to one archetype, checked with debug assertions.
/// Fills missing insertion requirements and reports the committed prefix in completed.
pub fn modifyBatch(
    self: *Self,
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
        &ids,
        columns.view(),
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

/// Borrows packed columns and unique live ids belonging to one archetype.
/// The first entity determines the source archetype; debug assertions check the whole batch.
/// Input buffers must not alias ECS storage. Only committed values transfer ownership.
/// Fills requirements of explicit insertions; unrelated existing dependencies are not checked.
/// On failure, commits the prepared prefix and reports its length through completed.
pub fn modifyBatchImpl(
    self: *Self,
    ids: []const Entity.Id,
    columns: Columns,
    remove_ids: []const CompId,
    completed: *usize,
) ModifyError!void {
    completed.* = 0;
    std.debug.assert(self.validateColumns(false, columns, ids.len));
    if (ids.len == 0) return;
    std.debug.assert(self.contains(ids[0]));
    const archetype_id = self.get(ids[0]).?.archetype_id;
    assertModifyBatch(self, archetype_id, ids);

    var plan = try planBatchChange(
        self,
        archetype_id,
        columns,
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
) void {
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

fn planBatchChange(
    self: *Self,
    source_id: Archetype.Id,
    columns: Columns,
    remove_ids: []const CompId,
    count: usize,
) ModifyError!BatchChange {
    const allocator = self.allocator;
    var plan: BatchChange = .{ .source = source_id };
    errdefer plan.deinit(allocator, 0);
    for (remove_ids, 0..) |id, i| {
        if (self.comp_reg.getById(id) == null) return error.UnknownComponentType;
        if (hasId(remove_ids[0..i], id)) return error.DuplicateComponent;
        if (hasId(columns.ids, id))
            return error.ConflictingComponentChange;
    }

    // Walk only the insertion closure, including dependencies of already-present requirements.
    var required: std.ArrayList(CompId) = .empty;
    defer required.deinit(allocator);
    try required.appendSlice(allocator, columns.ids);
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
        if (hasId(remove_ids, column.id) or columns.get(column.id) != null)
            try plan.drops.append(allocator, i);
    }
    for (required.items) |id| {
        const meta = self.comp_reg.getById(id).?;
        switch (meta.storage) {
            .archetype => {
                if (!hasId(dense_ids.items, id)) try dense_ids.append(allocator, id);
            },
            .sparse_set => {
                const set_id = columns.getSparseId(id) orelse
                    (try self.sparse_reg.getOrCreate(meta.type_meta)).id;
                try plan.sparse.append(allocator, .{
                    .id = id,
                    .set_id = set_id,
                    .input = columns.get(id),
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
        const input = columns.get(column.id);
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
const TestMark = ecs.component.Mark;

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
    // Removing a dependency is allowed, even with Root and Left still present.
    try registry.modifyBatch(
        .{ .{ ids[0], .{} }, .{ ids[1], .{} } },
        &.{Shared},
        &completed,
    );
    try expectEqual(2, completed);
    try expectEqual(2, Shared.destroyed);
    try registry.modifyBatch(.{.{ ids[1], .{} }}, &.{Right}, &completed);
    // An unrelated insertion leaves the broken dependency alone.
    try registry.modifyBatch(
        .{.{ ids[0], .{Health{ .value = 8 }} }},
        &.{},
        &completed,
    );
    try expect(!registry.hasTypedComp(ids[0], Shared));
    try registry.modifyBatch(.{
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
    try expectError(error.MissingRequirementDefault, registry.modifyBatch(.{
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
    const columns: Columns = .{ .ids = &.{root}, .archetype = &.{std.mem.sliceAsBytes(&values)} };
    var completed: usize = 999;
    try expectError(
        error.ConflictingComponentChange,
        registry.modifyBatchImpl(&.{id}, columns, &.{root}, &completed),
    );
    try expectEqual(0, completed);
    try expectError(
        error.RequiredComponentRemoved,
        registry.modifyBatchImpl(&.{id}, columns, &.{position}, &completed),
    );
    try expectError(
        error.MissingRequirementDefault,
        registry.modifyBatchImpl(&.{id}, columns, &.{}, &completed),
    );
    try expectError(
        error.DuplicateComponent,
        registry.modifyBatchImpl(&.{id}, .{}, &.{ position, position }, &completed),
    );
    try expectError(
        error.UnknownComponentType,
        registry.modifyBatchImpl(&.{id}, .{}, &.{.invalid}, &completed),
    );
    try expectEqual(0, completed);
    try expect(registry.get(id).?.archetype_id.eql(source));
    try registry.modifyBatch(.{}, &.{}, &completed);
    try expectEqual(0, completed);
    completed = 999;
    try registry.modifyBatchImpl(&.{}, .{}, &.{}, &completed);
    try expectEqual(0, completed);
    try registry.modifyBatch(.{.{ id, .{} }}, &.{Velocity}, &completed);
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
    const columns: Columns = .{
        .ids = &.{registry.comp_reg.idOf(Velocity).?},
        .archetype = &.{std.mem.sliceAsBytes(&values)},
    };
    var completed: usize = 0;
    try registry.modifyBatchImpl(&selected, columns, &.{}, &completed);
    try expectEqual(selected.len, completed);
    try expect(registry.arche_reg.getById(source).?.chunks.items.len > 1);
    var batch: [27]struct { Entity.Id, struct { Velocity } } = undefined;
    for (&batch, selected, values) |*row, id, value| row.* = .{ id, .{value} };
    try registry.modifyBatch(batch, &.{}, &completed);
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
    try registry.modifyBatch(.{
        .{ ids[0], .{ Probe{ .calls = &calls[2] }, SparseProbe{ .calls = &calls[3] } } },
        .{ ids[1], .{ SparseProbe{ .calls = &calls[3] }, Probe{ .calls = &calls[2] } } },
    }, &.{SparseTag}, &completed);
    try expectEqual([_]usize{ 2, 2, 0, 0 }, calls);
    try expectEqual(2, SparseTag.destroyed);
    try registry.modifyBatch(
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
    try registry.modifyBatch(.{.{ ids[0], .{} }}, &.{Probe}, &completed);
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
    const columns: Columns = .{ .ids = &.{root}, .archetype = &.{&.{}} };
    var completed: usize = 999;
    try expectError(
        error.UnknownRequirement,
        registry.modifyBatchImpl(&ids, columns, &.{}, &completed),
    );
    try expectEqual(0, completed);
    _ = try registry.comp_reg.registerMeta(.{
        .type_meta = TypeMeta.of(Broken),
        .default = .{ .ptr = Broken.fill },
    });
    try expectError(
        error.BufferSizeMismatch,
        registry.modifyBatchImpl(&ids, columns, &.{}, &completed),
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
    var batch: [3]struct { Entity.Id, struct { Root, Probe, SparseProbe } } = undefined;
    for (&batch, ids) |*row, id| row.* = .{ id, .{
        Root{}, Probe{ .calls = &calls[2] }, SparseProbe{ .calls = &calls[3] },
    } };
    var completed: usize = 999;
    var failure: ?ModifyError = null;
    registry.modifyBatch(batch, &.{}, &completed) catch |err| {
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
