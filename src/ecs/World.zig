const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const ecs = engine.ecs;
const component = ecs.component;
const ComponentRegistry = component.Registry;
const Entity = ecs.Entity;
const Archetype = ecs.Archetype;
const SparseSet = ecs.SparseSet;
const ResId = ecs.resource.Id;
const ResourceRegistry = ecs.resource.Registry;
const Bundle = engine.reflect.Bundle;

entity_reg: Entity.Registry,
res_reg: ResourceRegistry,
allocator: Allocator,
io: std.Io,

pub fn init(allocator: Allocator, io: std.Io) @This() {
    return .{
        .entity_reg = Entity.Registry.init(allocator),
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
pub fn entityReg(self: *@This()) *Entity.Registry {
    return &self.entity_reg;
}

/// Returns the archetype registry backing this world.
pub fn archeReg(self: *@This()) *Archetype.Registry {
    return &self.entity_reg.arche_reg;
}

/// Returns the sparse set registry backing this world.
pub fn sparseReg(self: *@This()) *SparseSet.Registry {
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
/// before storage is prepared. Missing requirements are default-constructed per entity.
///
/// On failure the caller keeps ownership of `fields`; successful type registrations remain.
pub fn addEntity(
    self: *@This(),
    fields: anytype,
) Entity.Registry.AddError!Entity.Id {
    return self.entity_reg.add(fields);
}

/// Creates independent entities in input order, stopping at the first error.
/// Valid output ids identify consumed rows; remaining ids are invalid and inputs stay owned.
pub fn addEntities(
    self: *@This(),
    fields: anytype,
    ids: *[fields.len]Entity.Id,
) Entity.Registry.AddError!void {
    return self.entity_reg.addMany(fields, ids);
}

/// Creates entities with identical normalized component sets using column-wise writes.
/// On error, committed rows remain live; remaining ids are invalid and inputs stay owned.
pub fn addEntityBatch(
    self: *@This(),
    rows: anytype,
    ids: *[rows.len]Entity.Id,
) Entity.Registry.AddError!void {
    return self.entity_reg.addBatch(rows, ids);
}

/// Modifies one entity, consuming insertions only on success.
/// Replaces existing values and ignores absent removals without registering them.
/// May invalidate borrows and iterators.
pub fn modifyEntity(
    self: *@This(),
    id: Entity.Id,
    fields: anytype,
    comptime remove: []const type,
) Entity.Registry.ModifyError!void {
    return self.entity_reg.modify(id, fields, remove);
}

/// Modifies independent .{ entity_id, fields } rows, reporting the successful prefix.
pub fn modifyEntities(
    self: *@This(),
    rows: anytype,
    comptime remove: []const type,
    completed: *usize,
) Entity.Registry.ModifyError!void {
    return self.entity_reg.modifyMany(rows, remove, completed);
}

/// Modifies unique entities in one archetype with matching explicit component sets.
/// On error, only the completed prefix consumes input values.
pub fn modifyEntityBatch(
    self: *@This(),
    archetype_id: Archetype.Id,
    rows: anytype,
    comptime remove: []const type,
    completed: *usize,
) Entity.Registry.ModifyError!void {
    return self.entity_reg.modifyBatch(archetype_id, rows, remove, completed);
}

/// Destroys the entity and its components, returning whether it was live.
/// Unknown, stale, or already removed ids return false. Allocation failure
/// leaves the entity unchanged. Invalidates affected component borrows and
/// active query iterators; do not call during query iteration.
pub fn removeEntity(self: *@This(), id: Entity.Id) Allocator.Error!bool {
    return self.entity_reg.remove(id);
}

/// Returns whether `id` identifies a live entity.
pub fn containsEntity(self: *const @This(), id: Entity.Id) bool {
    return self.entity_reg.contains(id);
}

/// Borrows entity metadata, or returns null if the id is unknown, stale, or retired.
/// Creating another entity may invalidate the pointer.
pub fn getEntity(self: *const @This(), id: Entity.Id) ?*const Entity {
    return self.entity_reg.get(id);
}

/// Mutably borrows entity metadata, or returns null if the id is unknown, stale, or retired.
/// Creating another entity may invalidate the pointer.
/// Callers must preserve the entity's storage and signature invariants.
pub fn getEntityMut(self: *@This(), id: Entity.Id) ?*Entity {
    return self.entity_reg.getMut(id);
}

/// Returns the number of live entities, excluding retired slots.
pub fn entityCount(self: *const @This()) usize {
    return self.entity_reg.len();
}

/// Checks for a registered component id without creating storage.
pub fn hasComp(self: *const @This(), id: Entity.Id, comp_id: component.Id) bool {
    return self.entity_reg.hasComp(id, comp_id);
}

/// Borrows component bytes; storage growth or structural changes may invalidate them.
pub fn getComp(self: *const @This(), id: Entity.Id, comp_id: component.Id) ?[]const u8 {
    return self.entity_reg.getComp(id, comp_id);
}

/// Mutably borrows component bytes with the same lookup and lifetime rules as getComp.
pub fn getCompMut(self: *@This(), id: Entity.Id, comp_id: component.Id) ?[]u8 {
    return self.entity_reg.getCompMut(id, comp_id);
}

/// Checks for a component without registering its type.
pub fn hasTypedComp(self: *const @This(), id: Entity.Id, comptime T: type) bool {
    return self.entity_reg.hasTypedComp(id, T);
}

/// Borrows a component without registering its type; returns null if absent.
/// Storage growth or structural changes may invalidate the pointer.
pub fn getTypedComp(self: *const @This(), id: Entity.Id, comptime T: type) ?*const T {
    return self.entity_reg.getTypedComp(id, T);
}

/// Mutably borrows a component without registering its type; returns null if absent.
/// Storage growth or structural changes may invalidate the pointer.
pub fn getTypedCompMut(self: *@This(), id: Entity.Id, comptime T: type) ?*T {
    return self.entity_reg.getTypedCompMut(id, T);
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
    try expectEqual(0, readonly.entityCount());

    const id = try world.addEntity(.{
        Transform{ .position = .{ .x = 3, .y = 4 } },
        Health{ .value = 7 },
    });

    try expectEqual(@as(usize, 1), readonly.entityCount());
    try expect(readonly.containsEntity(id));
    const created = readonly.getEntity(id).?;
    try expect(created.id.eql(id));
    try expect(created.archetype_id.isValid());
    try expectEqual(1, created.sparse_comps.items.len);
    try expect(world.getEntityMut(id).?.id.eql(id));
    try expect(readonly.hasTypedComp(id, Position));
    try expect(readonly.hasTypedComp(id, Health));
    try expectEqual(3, readonly.getTypedComp(id, Position).?.x);
    try expectEqual(4, readonly.getTypedComp(id, Position).?.y);
    try expectEqual(7, readonly.getTypedComp(id, Health).?.value);
    inline for (.{ Position, Health }) |T| {
        const comp_id = world.compReg().idOf(T).?;
        try expect(readonly.hasComp(id, comp_id));
        const bytes = readonly.getComp(id, comp_id).?;
        const mutable = world.getCompMut(id, comp_id).?;
        try expect(@TypeOf(bytes) == []const u8);
        try expect(@TypeOf(mutable) == []u8);
        try expectEqual(@intFromPtr(bytes.ptr), @intFromPtr(readonly.getTypedComp(id, T).?));
        try expectEqual(@intFromPtr(mutable.ptr), @intFromPtr(world.getTypedCompMut(id, T).?));
    }

    world.getTypedCompMut(id, Position).?.x = 9;
    world.getTypedCompMut(id, Health).?.value = 11;
    try expectEqual(9, readonly.getTypedComp(id, Position).?.x);
    try expectEqual(11, readonly.getTypedComp(id, Health).?.value);

    // A non-component field is a compile error:
    // _ = world.addEntity(.{ @as(u32, 1) });
}

test "modifyEntity accepts nested bundles and absent removals" {
    const Missing = struct {
        pub const se_component: TestMark = .{};
    };
    var world = init(std.testing.allocator, std.testing.io);
    defer world.deinit();
    const id = try world.addEntity(.{Health{ .value = 7 }});
    try world.modifyEntity(
        id,
        .{Transform{ .position = .{ .x = 1, .y = 2 } }},
        &.{ Health, Missing },
    );
    try expectEqual(1, world.getTypedComp(id, Position).?.x);
    try expect(!world.hasTypedComp(id, Health));
    try expect(world.compReg().idOf(Missing) == null);

    try world.modifyEntity(id, .{Health{ .value = 9 }}, &.{Transform});
    try expect(!world.hasTypedComp(id, Position));
    try expectEqual(9, world.getTypedComp(id, Health).?.value);
    try world.modifyEntity(id, .{}, &.{});
    try world.modifyEntity(id, .{}, &.{Health});
    try world.modifyEntity(id, .{Position{ .x = 3, .y = 4 }}, &.{});
    try expectEqual(1, world.entityCount());
    try expectError(error.UnknownEntity, world.modifyEntity(.invalid, .{}, &.{}));
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
        try expect(!readonly.hasTypedComp(id, T));
        try expect(readonly.getTypedComp(id, T) == null);
        try expect(world.getTypedCompMut(id, T) == null);
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
        try expect(readonly.getTypedComp(tag, Tag) != null);
        world.getTypedCompMut(tag, Tag).?.* = .{};

        const aligned = try world.addEntity(.{Aligned{ .value = 13 }});
        try expectEqual(13, readonly.getTypedComp(aligned, Aligned).?.value);
        world.getTypedCompMut(aligned, Aligned).?.value = 23;
        try expectEqual(23, readonly.getTypedComp(aligned, Aligned).?.value);

        try world.modifyEntity(tag, .{Aligned{ .value = 31 }}, &.{Tag});
        try expect(!world.hasTypedComp(tag, Tag));
        try expectEqual(31, world.getTypedComp(tag, Aligned).?.value);
        try expectEqual(23, world.getTypedComp(aligned, Aligned).?.value);
    }
}

test "batch entity helpers store rows and preserve a successful prefix on error" {
    var world = init(std.testing.allocator, std.testing.io);
    defer world.deinit();
    var batch_ids: [2]Entity.Id = undefined;
    try world.addEntityBatch(.{
        .{ Position{ .x = 1, .y = 2 }, Health{ .value = 3 } },
        .{ Health{ .value = 6 }, Position{ .x = 4, .y = 5 } },
    }, &batch_ids);
    try expectEqual(1, world.getTypedComp(batch_ids[0], Position).?.x);
    try expectEqual(6, world.getTypedComp(batch_ids[1], Health).?.value);

    var calls: usize = 0;
    var ids: [3]Entity.Id = undefined;
    try expectError(error.BufferTooLarge, world.addEntities(.{
        .{Health{ .value = 9 }},
        .{Huge{ .calls = &calls }},
        .{},
    }, &ids));
    try expectEqual(9, world.getTypedComp(ids[0], Health).?.value);
    try expect(ids[1].eql(.invalid));
    try expect(ids[2].eql(.invalid));
    try expectEqual(0, calls);
    try expectEqual(3, world.entityCount());
}

test "modifyEntities supports heterogeneous rows and retains the successful prefix" {
    var world = init(std.testing.allocator, std.testing.io);
    defer world.deinit();
    const a = try world.addEntity(.{Health{ .value = 1 }});
    const b = try world.addEntity(.{Position{ .x = 2, .y = 3 }});
    const c = try world.addEntity(.{});
    var calls: usize = 0;
    var huge: Huge = .{ .calls = &calls };
    var completed: usize = 999;
    try expectError(error.BufferTooLarge, world.modifyEntities(.{
        .{ a, .{Position{ .x = 10, .y = 20 }} },
        .{ b, .{Health{ .value = 30 }} },
        .{ c, .{huge} },
        .{ a, .{Position{ .x = 99, .y = 99 }} },
    }, &.{}, &completed));
    try expectEqual(2, completed);
    try expectEqual(10, world.getTypedComp(a, Position).?.x);
    try expectEqual(30, world.getTypedComp(b, Health).?.value);
    try expectEqual(0, world.getEntity(c).?.signature.mask.count());
    try expectEqual(0, calls);
    huge.deinit();
    try expectEqual(1, calls);
    try world.modifyEntities(.{ .{ a, .{} }, .{ b, .{} } }, &.{Health}, &completed);
    try expectEqual(2, completed);
    try expect(!world.hasTypedComp(a, Health));
    try expect(!world.hasTypedComp(b, Health));
    try world.modifyEntities(.{}, &.{}, &completed);
    try expectEqual(0, completed);
    try expectError(error.UnknownEntity, world.modifyEntities(.{
        .{ a, .{Health{ .value = 4 }} },
        .{ Entity.Id.invalid, .{} },
    }, &.{}, &completed));
    try expectEqual(1, completed);
    try expectEqual(4, world.getTypedComp(a, Health).?.value);
}

test "modifyEntityBatch exposes requirement completion and partial success" {
    const Root = struct {
        pub const se_component: TestMark = .{ .require = &.{Health} };
    };
    var world = init(std.testing.allocator, std.testing.io);
    defer world.deinit();
    const a = try world.addEntity(.{Health{ .value = 1 }});
    const b = try world.addEntity(.{});
    const source = world.getEntity(a).?.archetype_id;
    var completed: usize = 999;
    try expectError(error.MissingRequirementDefault, world.modifyEntityBatch(source, .{
        .{ a, .{Root{}} }, .{ b, .{Root{}} },
    }, &.{}, &completed));
    try expectEqual(1, completed);
    try expect(world.hasTypedComp(a, Root));
    try expect(!world.hasTypedComp(b, Root));
    try expectEqual(1, world.getTypedComp(a, Health).?.value);
    try world.modifyEntityBatch(source, .{
        .{ b, .{ Root{}, Health{ .value = 2 } } },
    }, &.{}, &completed);
    try expectEqual(1, completed);
    try expectEqual(2, world.getTypedComp(b, Health).?.value);
    try expect(world.getEntity(a).?.archetype_id.eql(world.getEntity(b).?.archetype_id));
}

test "addEntity and modifyEntity preserve input ownership on layout failure" {
    const allocator = std.testing.allocator;
    var world = init(allocator, std.testing.io);
    defer world.deinit();

    var calls: usize = 0;
    var huge: Huge = .{ .calls = &calls };

    // A failed layout must leave the caller's value owned by the caller.
    try expectError(error.BufferTooLarge, world.addEntity(.{huge}));
    try expect(calls == 0);

    const id = try world.addEntity(.{});
    try expectError(error.BufferTooLarge, world.modifyEntity(id, .{huge}, &.{}));
    try expectEqual(0, world.getEntity(id).?.signature.mask.count());
    try expectEqual(0, calls);

    // The caller still owns the value.
    huge.deinit();
    try expect(calls == 1);
}
