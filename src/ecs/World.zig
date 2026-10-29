const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const ecs = engine.ecs;
const component = ecs.component;
const ComponentRegistry = component.Registry;
const entity = ecs.entity;
const EntityId = entity.Id;
const EntityRegistry = entity.Registry;
const ArchetypeRegistry = entity.archetype.Registry;
const SparseSetRegistry = entity.sparse_set.Registry;
const Bundle = engine.reflect.Bundle;

entity_reg: EntityRegistry,
allocator: Allocator,

pub fn init(allocator: Allocator) @This() {
    return .{
        .entity_reg = EntityRegistry.init(allocator),
        .allocator = allocator,
    };
}

pub fn deinit(self: *@This()) void {
    self.entity_reg.deinit();
}

/// Returns the component registry backing this world.
pub fn compReg(self: *@This()) *ComponentRegistry {
    return &self.entity_reg.comp_reg;
}

/// Returns the entity registry backing this world.
pub fn entityReg(self: *@This()) *EntityRegistry {
    return &self.entity_reg;
}

/// Returns the archetype registry backing this world.
pub fn archReg(self: *@This()) *ArchetypeRegistry {
    return &self.entity_reg.arch_reg;
}

/// Returns the sparse set registry backing this world.
pub fn sparseReg(self: *@This()) *SparseSetRegistry {
    return &self.entity_reg.sparse_reg;
}

/// Creates an entity from a struct or tuple of component values.
///
/// Every field type must be a component, or a struct marked as a bundle whose fields are
/// flattened recursively; anything else is a compile error. Component types are registered
/// before the bundle is built.
///
/// On failure the caller keeps ownership of `fields`.
pub fn addEntity(
    self: *@This(),
    fields: anytype,
) (EntityRegistry.Error || ComponentRegistry.Error)!EntityId {
    const types = Bundle.flatTypes(@TypeOf(fields));
    comptime {
        for (types) |T| component.assertComponent(T, "addEntity");
    }

    inline for (types) |T| _ = try self.entity_reg.comp_reg.register(T);

    var bundle = try Bundle.init(self.allocator, fields);
    errdefer bundle.releaseStorage();
    return self.addBundle(bundle);
}

/// Creates an entity from an already-built bundle.
///
/// Every component type in `bundle` must already be registered, for example by `addEntity`;
/// otherwise `UnknownComponentType` is returned.
pub fn addBundle(self: *@This(), bundle: Bundle) EntityRegistry.Error!EntityId {
    return self.entity_reg.addBundle(bundle);
}

const expect = std.testing.expect;

const TestMark = component.Mark;

const Position = struct {
    pub const se_component: TestMark = .{};
    x: i32,
    y: i32,
};

const Health = struct {
    pub const se_component: TestMark = .{ .storage = .sparse_set };
    value: u32,
};

const Transform = struct {
    pub const se_bundle: Bundle.Mark = .{};
    position: Position,
};

/// Too large for a single chunk, so creating its archetype fails.
const Huge = struct {
    pub const se_component: TestMark = .{};
    calls: *usize,
    payload: [16 * 1024 + 1]u8 = undefined,

    pub fn deinit(self: *@This()) void {
        self.calls.* += 1;
    }
};

test "addEntity registers components and creates an entity" {
    const allocator = std.testing.allocator;
    var world = init(allocator);
    defer world.deinit();

    const id = try world.addEntity(.{
        Transform{ .position = .{ .x = 3, .y = 4 } },
        Health{ .value = 7 },
    });

    const position_id = world.entity_reg.comp_reg.getByType(Position).?;
    const health_id = world.entity_reg.comp_reg.getByType(Health).?;

    const created = world.entity_reg.get(id).?;
    try expect(created.id.eql(id));
    try expect(created.signature.has(position_id));
    try expect(created.signature.has(health_id));

    // A non-component field is a compile error:
    // _ = world.addEntity(.{ @as(u32, 1) });
}

test "addEntity releases the temporary bundle without disposing copied values" {
    const allocator = std.testing.allocator;
    var world = init(allocator);
    defer world.deinit();

    var calls: usize = 0;
    var huge: Huge = .{ .calls = &calls };

    // The archetype layout fails after `Bundle.init` has copied the fields.
    try std.testing.expectError(error.BufferTooLarge, world.addEntity(.{huge}));
    try expect(calls == 0);

    // The caller still owns the value.
    huge.deinit();
    try expect(calls == 1);
}
