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

const Self = ecs.Entity.Registry;

pub const ModifyError = Self.AddBundleError || error{
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
    const target = self.arche_reg.getById(plan.archetype_id).?;
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
        try self.sparse_reg.getById(location.sparse_set).?.reserveForEntity(id);
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
        .sparse_set => |set_id| self.sparse_reg.getById(set_id).?.getBytes(id).?,
    };
}

/// The sole ownership-transfer phase. Must remain allocation-free and infallible.
/// Fetches the current source row on each call, since earlier batch members may fill holes.
fn commitModify(self: *Self, id: Entity.Id, plan: ModifyPlan, prepared: *PreparedModify) void {
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
                    deinit_fn(modifyBytes(self, step.source.?, source, row, id).ptr);
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

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const checkAllAllocationFailures = std.testing.checkAllAllocationFailures;
const TestMark = ecs.component.Mark;

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
        var registry = Self.init(allocator);
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
        try expectEqual(!migrate, registry.hasComponent(ids[0], registry.comp_reg.idOf(Health).?));
        try expectEqual(migrate, registry.hasComponent(ids[0], registry.comp_reg.idOf(Root).?));
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
        var bundle = try Bundle.init(std.testing.allocator, .{Position{ .x = 1, .y = 2 }});
        errdefer bundle.deinit();
        id.* = try registry.addBundle(bundle);
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
