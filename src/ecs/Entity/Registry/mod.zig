const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const ecs = engine.ecs;
const ComponentRegistry = ecs.component.Registry;
const Archetype = ecs.Archetype;
const SparseSet = ecs.SparseSet;
const Entity = ecs.Entity;
const reflect = engine.reflect;
const TypeId = reflect.TypeId;

const _add = @import("add.zig");
const _modify = @import("modify.zig");
const _storage = @import("storage.zig");

pub const AddError = _add.AddError;
pub const add = _add.add;
pub const addMany = _add.addMany;
pub const addBatch = _add.addBatch;
pub const addBatchImpl = _add.addBatchImpl;
pub const ModifyError = _modify.ModifyError;
pub const modify = _modify.modify;
pub const hasComponent = _storage.hasComponent;
pub const getComponent = _storage.getComponent;
pub const getComponentMut = _storage.getComponentMut;
pub const group = _storage.group;
pub const validateColumns = _storage.validateColumns;

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

const testing = @import("testing.zig");
const Position = testing.Position;
const Health = testing.Health;
const Probe = testing.Probe;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const TestMark = ecs.component.Mark;

test "empty entity access reports metadata and rejects invalid ids" {
    const allocator = std.testing.allocator;
    var registry = init(allocator);
    defer registry.deinit();

    const readonly: *const @This() = &registry;
    try expect(readonly.isEmpty());
    try expectEqual(0, readonly.len());
    const id = try registry.add(.{});
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
            id.* = try registry.add(.{
                Position{ .x = @intCast(i), .y = 4 },
                Probe{ .calls = &archetype_calls },
                SparseProbe{ .calls = &sparse_calls },
            });
        }
        // The last sparse value belongs to a different archetype.
        const sparse_only = try registry.add(.{SparseProbe{ .calls = &sparse_calls }});
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
        try testing.expectArchetypeValue(archetype, Position, 0, .{ .x = 1, .y = 4 });
        const set = &registry.sparse_reg.getByTypeId(TypeId.of(SparseProbe)).?.set;
        try expectEqual(2, set.len());
        try expect(set.get(SparseProbe, ids[1]) != null);
        try expect(set.get(SparseProbe, sparse_only) != null);

        const reused = try registry.add(.{});
        try expect(reused.eql(ids[0].nextGeneration()));
        try expect(registry.contains(reused));
        try expect(!try registry.remove(ids[0]));
        try expectEqual(3, registry.entities.items.len);
        try expectEqual(0, registry.retired.items.len);
    }
    try expectEqual(2, archetype_calls);
    try expectEqual(3, sparse_calls);
}

test "remove allocation failure preserves the entity and all component values" {
    const allocator = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var calls: usize = 0;
    var registry = init(allocator);
    defer registry.deinit();
    inline for (.{ Probe, Health }) |T| _ = try registry.comp_reg.register(T);
    const id = try registry.add(.{
        Probe{ .calls = &calls }, Health{ .value = 17 },
    });
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

test {
    _ = _add;
    _ = _modify;
    _ = _storage;
}
