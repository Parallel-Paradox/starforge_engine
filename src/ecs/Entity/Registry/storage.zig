const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const ecs = engine.ecs;
const CompId = ecs.component.Id;
const SparseSet = ecs.SparseSet;
const Entity = ecs.Entity;
const reflect = engine.reflect;
const TypeId = reflect.TypeId;
const Self = ecs.Entity.Registry;

/// Returns whether the live entity has the registered component.
/// Unknown, stale, or reserved-only component ids return false.
pub fn hasComponent(self: *const Self, id: Entity.Id, comp_id: CompId) bool {
    const entity = self.get(id) orelse return false;
    _ = self.comp_reg.getById(comp_id) orelse return false;
    return entity.signature.has(comp_id);
}

/// Borrows a component's bytes, or returns null if the entity or component is absent.
/// Unknown, stale, or reserved-only ids return null. Does not create storage.
/// The slice may be invalidated by storage growth or structural changes.
pub fn getComponent(self: *const Self, id: Entity.Id, comp_id: CompId) ?[]const u8 {
    return componentBytes(self, id, comp_id);
}

/// Mutably borrows a component's bytes, or returns null if the entity or component is absent.
/// Unknown, stale, or reserved-only ids return null. Does not create storage.
/// The slice may be invalidated by storage growth or structural changes.
pub fn getComponentMut(self: *Self, id: Entity.Id, comp_id: CompId) ?[]u8 {
    return componentBytes(self, id, comp_id);
}

fn componentBytes(self: *const Self, id: Entity.Id, comp_id: CompId) ?[]u8 {
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

/// Reserves dense storage and sparse index entries before publishing values.
pub fn reserveSparseSet(self: *Self, id: SparseSet.Id, entity_id: Entity.Id) Allocator.Error!void {
    const set = self.sparse_reg.getById(id).?;
    try set.reserve(1);
    try set.sparse_to_dense.ensureTotalCapacity(self.allocator, entity_id.index.get() + 1);
    while (set.sparse_to_dense.items.len <= entity_id.index.get())
        set.sparse_to_dense.appendAssumeCapacity(.invalid);
}

const testing = @import("testing.zig");
const Position = testing.Position;
const Health = testing.Health;
const Probe = testing.Probe;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "component access rejects absent and invalid ids without creating storage" {
    const allocator = std.testing.allocator;
    var registry = Self.init(allocator);
    defer registry.deinit();
    const readonly: *const Self = &registry;
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
