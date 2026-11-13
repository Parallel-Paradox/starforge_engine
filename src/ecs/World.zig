const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const ecs = engine.ecs;
const component = ecs.component;
const ComponentRegistry = component.Registry;
const entity = ecs.entity;
const EntityId = entity.Id;
const EntityRegistry = entity.Registry;
const Change = entity.Entity.Change;
const ArchetypeRegistry = entity.archetype.Registry;
const SparseSetRegistry = entity.sparse_set.Registry;
const ResId = ecs.resource.Id;
const ResourceRegistry = ecs.resource.Registry;
const Bundle = engine.reflect.Bundle;

entity_reg: EntityRegistry,
res_reg: ResourceRegistry,
allocator: Allocator,
io: std.Io,

pub fn init(allocator: Allocator, io: std.Io) @This() {
    return .{
        .entity_reg = EntityRegistry.init(allocator),
        .res_reg = ResourceRegistry.init(allocator),
        .allocator = allocator,
        .io = io,
    };
}

pub fn deinit(self: *@This()) void {
    self.entity_reg.deinit();
    self.res_reg.deinit();
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
    return &self.entity_reg.arche_reg;
}

/// Returns the sparse set registry backing this world.
pub fn sparseReg(self: *@This()) *SparseSetRegistry {
    return &self.entity_reg.sparse_reg;
}

/// Returns the resource registry backing this world.
pub fn resReg(self: *@This()) *ResourceRegistry {
    return &self.res_reg;
}

/// Inserts only if absent, using `Default` for passed types; returns the resource ID.
/// Success consumes a passed value, destroying it through `TypeMeta` if skipped.
/// Skipped types are not constructed; on failure the caller retains the value.
pub fn initResource(self: *@This(), value: anytype) Allocator.Error!ResId {
    return self.res_reg.insertIfAbsent(value);
}

/// Inserts a value or constructs a type through `Default`, replacing any existing
/// resource through `TypeMeta`. Returns the resource ID, preserving it on replacement.
/// Ownership of a passed value transfers only on success.
pub fn insertResource(self: *@This(), value: anytype) Allocator.Error!ResId {
    return self.res_reg.insert(value);
}

/// Borrows a resource, returning null if absent.
pub fn getResource(self: *@This(), comptime T: type) ?*T {
    return self.res_reg.get(T);
}

/// Removes and destroys a resource through `TypeMeta`, returning whether it existed.
pub fn removeResource(self: *@This(), comptime T: type) bool {
    return self.res_reg.remove(T);
}

/// Creates an entity from a struct or tuple of component values.
///
/// Every field type must be a component, or a struct marked as a bundle whose fields are
/// flattened recursively; anything else is a compile error. Component types are registered
/// before the bundle is built. The entity registry default-constructs missing requirements.
///
/// On failure the caller keeps ownership of `fields`; successful type registrations remain.
pub fn addEntity(
    self: *@This(),
    fields: anytype,
) (EntityRegistry.AddBundleError || ComponentRegistry.RegisterError)!EntityId {
    const types = Bundle.flatTypes(@TypeOf(fields));
    comptime {
        for (types) |T| component.assertComponent(T, "addEntity");
    }

    inline for (types) |T| _ = try self.entity_reg.comp_reg.register(T);

    var bundle = try Bundle.init(self.allocator, fields);
    errdefer bundle.releaseStorage();
    return self.entity_reg.addBundle(bundle);
}

pub const ModifyEntityError = EntityRegistry.ModifyError || ComponentRegistry.RegisterError;

/// Applies a typed Entity.Change, consuming insertions only on success.
/// Replaces existing values and ignores absent removals without registering them.
/// May invalidate borrows and iterators.
pub fn modifyEntity(
    self: *@This(),
    comptime Request: type,
    change: Request,
) ModifyEntityError!void {
    if (!self.entity_reg.contains(change.id)) return error.UnknownEntity;
    inline for (Request.insert_types) |T| _ = try self.entity_reg.comp_reg.register(T);

    var remove_ids: [Request.remove_types.len]component.Id = undefined;
    var remove_count: usize = 0;
    inline for (Request.remove_types) |T| {
        if (self.entity_reg.comp_reg.idOf(T)) |id| {
            if (self.entity_reg.comp_reg.getById(id) != null) {
                remove_ids[remove_count] = id;
                remove_count += 1;
            }
        }
    }
    var bundle = try Bundle.init(self.allocator, change.insert);
    errdefer bundle.releaseStorage();
    try self.entity_reg.modify(change.id, bundle, remove_ids[0..remove_count]);
}

/// Destroys the entity and its components, returning whether it was live.
/// Unknown, stale, or already removed ids return false. Allocation failure
/// leaves the entity unchanged. Invalidates affected component borrows and
/// active query iterators; do not call during query iteration.
pub fn removeEntity(self: *@This(), id: EntityId) Allocator.Error!bool {
    return self.entity_reg.remove(id);
}

/// Returns whether `id` identifies a live entity.
pub fn containsEntity(self: *const @This(), id: EntityId) bool {
    return self.entity_reg.contains(id);
}

/// Borrows entity metadata, or returns null if the id is unknown, stale, or retired.
/// Creating another entity may invalidate the pointer.
pub fn getEntity(self: *const @This(), id: EntityId) ?*const entity.Entity {
    return self.entity_reg.get(id);
}

/// Mutably borrows entity metadata, or returns null if the id is unknown, stale, or retired.
/// Creating another entity may invalidate the pointer.
/// Callers must preserve the entity's storage and signature invariants.
pub fn getEntityMut(self: *@This(), id: EntityId) ?*entity.Entity {
    return self.entity_reg.getMut(id);
}

/// Returns the number of live entities, excluding retired slots.
pub fn entityCount(self: *const @This()) usize {
    return self.entity_reg.len();
}

/// Checks for a component without registering its type.
pub fn hasComponent(self: *const @This(), id: EntityId, comptime T: type) bool {
    component.assertComponent(T, "hasComponent");
    const comp_id = self.entity_reg.comp_reg.idOf(T) orelse return false;
    return self.entity_reg.hasComponent(id, comp_id);
}

/// Borrows a component without registering its type; returns null if absent.
/// Storage growth or structural changes may invalidate the pointer.
pub fn getComponent(self: *const @This(), id: EntityId, comptime T: type) ?*const T {
    component.assertComponent(T, "getComponent");
    const comp_id = self.entity_reg.comp_reg.idOf(T) orelse return null;
    const bytes = self.entity_reg.getComponent(id, comp_id) orelse return null;
    return @ptrCast(@alignCast(bytes.ptr));
}

/// Mutably borrows a component without registering its type; returns null if absent.
/// Storage growth or structural changes may invalidate the pointer.
pub fn getComponentMut(self: *@This(), id: EntityId, comptime T: type) ?*T {
    component.assertComponent(T, "getComponentMut");
    const comp_id = self.entity_reg.comp_reg.idOf(T) orelse return null;
    const bytes = self.entity_reg.getComponentMut(id, comp_id) orelse return null;
    return @ptrCast(@alignCast(bytes.ptr));
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

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
    var world = init(allocator, std.testing.io);
    defer world.deinit();
    const readonly: *const @This() = &world;
    try expectEqual(@as(usize, 0), readonly.entityCount());

    const id = try world.addEntity(.{
        Transform{ .position = .{ .x = 3, .y = 4 } },
        Health{ .value = 7 },
    });

    try expectEqual(@as(usize, 1), readonly.entityCount());
    try expect(readonly.containsEntity(id));
    const created = readonly.getEntity(id).?;
    try expect(created.id.eql(id));
    try expect(created.archetype_id.isValid());
    try expectEqual(@as(usize, 1), created.sparse_comps.items.len);
    try expect(world.getEntityMut(id).?.id.eql(id));
    try expect(readonly.hasComponent(id, Position));
    try expect(readonly.hasComponent(id, Health));
    try expectEqual(@as(i32, 3), readonly.getComponent(id, Position).?.x);
    try expectEqual(@as(i32, 4), readonly.getComponent(id, Position).?.y);
    try expectEqual(@as(u32, 7), readonly.getComponent(id, Health).?.value);

    world.getComponentMut(id, Position).?.x = 9;
    world.getComponentMut(id, Health).?.value = 11;
    try expectEqual(@as(i32, 9), readonly.getComponent(id, Position).?.x);
    try expectEqual(@as(u32, 11), readonly.getComponent(id, Health).?.value);

    // A non-component field is a compile error:
    // _ = world.addEntity(.{ @as(u32, 1) });
}

test "modifyEntity accepts typed changes with nested bundles and absent removals" {
    const Missing = struct {
        pub const se_component: TestMark = .{};
    };
    var world = init(std.testing.allocator, std.testing.io);
    defer world.deinit();
    const id = try world.addEntity(.{Health{ .value = 7 }});
    const RequestA = Change(.{ .insert = &.{Transform}, .remove = &.{ Health, Missing } });
    try world.modifyEntity(RequestA, .{
        .id = id,
        .insert = .{Transform{ .position = .{ .x = 1, .y = 2 } }},
    });
    try expectEqual(1, world.getComponent(id, Position).?.x);
    try expect(!world.hasComponent(id, Health));
    try expect(world.compReg().idOf(Missing) == null);

    const RequestB = Change(.{ .insert = &.{Health}, .remove = &.{Transform} });
    const change: RequestB = .{ .id = id, .insert = .{Health{ .value = 9 }} };
    try world.modifyEntity(RequestB, change);
    try expect(!world.hasComponent(id, Position));
    try expectEqual(9, world.getComponent(id, Health).?.value);
    try world.modifyEntity(Change(.{}), .{ .id = id });
    try world.modifyEntity(Change(.{ .remove = &.{Health} }), .{ .id = id });
    try world.modifyEntity(Change(.{ .insert = &.{Position} }), .{
        .id = id,
        .insert = .{Position{ .x = 3, .y = 4 }},
    });
    try expectEqual(1, world.entityCount());
    try expectError(error.UnknownEntity, world.modifyEntity(Change(.{}), .{ .id = .invalid }));
}

test "addEntity delegates requirement completion to the entity registry" {
    const Required = struct {
        pub const se_component: TestMark = .{ .storage = .sparse_set };
        value: u32 = 7,
    };
    const Root = struct {
        pub const se_component: TestMark = .{ .require = &.{Required} };
    };
    const allocator = std.testing.allocator;
    var world = init(allocator, std.testing.io);
    defer world.deinit();

    const id = try world.addEntity(.{Root{}});
    const required = world.compReg().idOf(Required).?;
    try expect(world.entityReg().get(id).?.signature.has(required));
}

test "component access does not register types" {
    var world = init(std.testing.allocator, std.testing.io);
    defer world.deinit();
    const readonly: *const @This() = &world;
    const id = try world.addEntity(.{});

    inline for (.{ Position, Health }) |T| {
        try expect(world.compReg().idOf(T) == null);
        try expect(!readonly.hasComponent(id, T));
        try expect(readonly.getComponent(id, T) == null);
        try expect(world.getComponentMut(id, T) == null);
        try expect(world.compReg().idOf(T) == null);
    }
}

test "component access and modification support zero sized and highly aligned types" {
    inline for (.{ component.Storage.archetype, component.Storage.sparse_set }) |storage| {
        const Tag = struct {
            pub const se_component: TestMark = .{ .storage = storage };
        };
        const Aligned = struct {
            pub const se_component: TestMark = .{ .storage = storage };
            value: u32 align(64),
        };
        var world = init(std.testing.allocator, std.testing.io);
        defer world.deinit();
        const readonly: *const @This() = &world;

        const tag = try world.addEntity(.{Tag{}});
        try expect(readonly.getComponent(tag, Tag) != null);
        world.getComponentMut(tag, Tag).?.* = .{};

        const aligned = try world.addEntity(.{Aligned{ .value = 13 }});
        try expectEqual(@as(u32, 13), readonly.getComponent(aligned, Aligned).?.value);
        world.getComponentMut(aligned, Aligned).?.value = 23;
        try expectEqual(@as(u32, 23), readonly.getComponent(aligned, Aligned).?.value);

        try world.modifyEntity(Change(.{ .insert = &.{Aligned}, .remove = &.{Tag} }), .{
            .id = tag,
            .insert = .{Aligned{ .value = 31 }},
        });
        try expect(!world.hasComponent(tag, Tag));
        try expectEqual(31, world.getComponent(tag, Aligned).?.value);
        try expectEqual(23, world.getComponent(aligned, Aligned).?.value);
    }
}

test "addEntity releases the temporary bundle without disposing copied values" {
    const allocator = std.testing.allocator;
    var world = init(allocator, std.testing.io);
    defer world.deinit();

    var calls: usize = 0;
    var huge: Huge = .{ .calls = &calls };

    // The archetype layout fails after `Bundle.init` has copied the fields.
    try expectError(error.BufferTooLarge, world.addEntity(.{huge}));
    try expect(calls == 0);

    const id = try world.addEntity(.{});
    try expectError(error.BufferTooLarge, world.modifyEntity(Change(.{ .insert = &.{Huge} }), .{
        .id = id,
        .insert = .{huge},
    }));
    try expectEqual(0, world.getEntity(id).?.signature.mask.count());
    try expectEqual(0, calls);

    // The caller still owns the value.
    huge.deinit();
    try expect(calls == 1);
}
