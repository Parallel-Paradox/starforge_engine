//! Queries: typed iteration over entities matching a component layout and filters.
//!
//! `Query(Item)` yields one item per entity holding every component in `Item`;
//! `QueryF(Item, filters)` further narrows archetypes with `filter` operators.
//!
//! `Item` is a struct or tuple whose fields are `*T` (mutable), `*const T`
//! (read-only), or `EntityId`. The yielded item is `Item` itself, so tuples are
//! destructured by the caller:
//!
//! ```zig
//! var query = Query(struct { EntityId, *const Position, *Velocity }).extract(&world);
//! while (query.next()) |item| {
//!     const id, const position, const velocity = item;
//!     velocity.dx = position.x;
//! }
//! ```
//!
//! Filters run per entity against the entity's signature, which includes both archetype
//! and sparse-set components. Every target component is implicitly required. Items point
//! into component storage and are invalidated by structural changes that grow or move it.

const std = @import("std");

const engine = @import("engine");
const ecs = engine.ecs;
const World = ecs.World;
const component = ecs.component;
const CompId = component.Id;
const entity = ecs.entity;
const EntityId = entity.Id;
const Archetype = entity.archetype.Archetype;
const ArchetypeIter = entity.archetype.Iter;
const ArchetypeId = entity.archetype.Id;
const TypeId = engine.reflect.TypeId;

pub const filter = @import("filter.zig");

// Filter operators, in scope so tests read like `. { With(A), Without(B) }`.
const With = filter.With;
const Without = filter.Without;
const All = filter.All;
const Any = filter.Any;
const Not = filter.Not;

/// A query over the entities holding every component in `Item`, with no extra filters.
///
/// `Item` is a struct or tuple whose fields are either `*T` (mutable), `*const T`
/// (read-only) for archetype or sparse-set components, or `EntityId`. A tuple `Item` is
/// yielded as a tuple, so callers destructure it themselves. See `QueryF` for filters.
pub fn Query(comptime I: type) type {
    return QueryF(I, .{});
}

/// A query over the entities holding every component in `Item`, narrowed by `filters`.
///
/// `filters` is a tuple of filter types, for example `.{With(Frozen)}`, evaluated
/// against each entity's signature. A query is single-use state: extract one, walk it
/// with `next`.
pub fn QueryF(comptime I: type, comptime filters: anytype) type {
    validateTarget(I);
    filter.validate(filters);

    const info = @typeInfo(I).@"struct";
    const field_names = info.field_names;
    const field_types = info.field_types;
    const has_filters = @typeInfo(@TypeOf(filters)).@"struct".field_names.len != 0;

    // The component type of each target field, or null for an `EntityId` field.
    const comp_types: [field_types.len]?type = blk: {
        var types: [field_types.len]?type = undefined;
        for (field_types, 0..) |F, i| {
            types[i] = if (F == EntityId) null else @typeInfo(F).pointer.child;
        }
        break :blk types;
    };

    return struct {
        world: *World,
        /// Component ids of the target fields, resolved when the query is extracted.
        comp_ids: [comp_types.len]?CompId = undefined,
        /// Column index in the current archetype for each target field.
        columns: [comp_types.len]usize = undefined,
        /// Id of the last archetype inspected; scanning resumes after it.
        next_archetype: ArchetypeId = .invalid,
        /// Iterator over the archetype under iteration, or null while seeking one.
        iter: ?ArchetypeIter = null,

        pub const Item = I;

        /// Builds a query over `world`.
        ///
        /// Component ids are resolved once, so register the components before extracting
        /// a query that targets them.
        pub fn extract(world: *World) @This() {
            var self: @This() = .{ .world = world };
            inline for (comp_types, 0..) |maybe, i| {
                if (maybe) |T| self.comp_ids[i] = world.compReg().getByType(T);
            }
            return self;
        }

        /// Returns the next matching entity, or null once every archetype was visited.
        pub fn next(self: *@This()) ?Item {
            while (true) {
                if (self.iter) |*iter| {
                    while (iter.next()) |entity_item| {
                        if (self.build(entity_item)) |item| return item;
                    }
                    self.iter = null;
                }

                if (!self.advance()) return null;
            }
        }

        /// Moves to the next archetype holding the archetype-stored target components.
        fn advance(self: *@This()) bool {
            const entries = self.world.archReg().entries.items;
            const start = if (self.next_archetype.index.tryGet()) |index| index + 1 else 0;

            for (entries[start..]) |*entry| {
                self.next_archetype = entry.id;

                const archetype = &entry.archetype;
                if (!self.accept(archetype)) continue;

                self.iter = archetype.iter();
                self.enter(archetype);
                return true;
            }
            return false;
        }

        /// Whether `archetype` holds every archetype-stored target component.
        fn accept(self: *@This(), archetype: *Archetype) bool {
            const signature = archetype.meta.signature;
            inline for (comp_types, 0..) |maybe, i| {
                if (maybe) |T| {
                    const id = self.comp_ids[i] orelse return false;
                    if (T.se_component.storage == .archetype and !signature.has(id)) return false;
                }
            }
            return true;
        }

        /// Resolves the column of each archetype-stored target field in `archetype`.
        fn enter(self: *@This(), archetype: *Archetype) void {
            inline for (comp_types, 0..) |maybe, i| {
                if (maybe) |T| {
                    if (T.se_component.storage == .archetype) {
                        self.columns[i] = archetype.meta.id_to_col.get(TypeId.of(T)).?;
                    }
                }
            }
        }

        /// Builds the item for `entity_item`, or null when a filter rejects the entity
        /// or it lacks a sparse-set target component.
        fn build(self: *@This(), entity_item: ArchetypeIter.Item) ?Item {
            if (comptime has_filters) {
                const target = self.world.entityReg().get(entity_item.id) orelse return null;
                const context: filter.Context = .{
                    .registry = self.world.compReg(),
                    .signature = target.signature,
                };
                if (!filter.matches(filters, context)) return null;
            }

            var result: Item = undefined;
            inline for (comp_types, field_names, 0..) |maybe, name, i| {
                if (maybe) |T| {
                    if (T.se_component.storage == .archetype) {
                        const bytes = entity_item.column(self.columns[i]);
                        @field(result, name) = @ptrCast(@alignCast(bytes.ptr));
                    } else {
                        const entry = self.world.sparseReg().getByType(TypeId.of(T)) orelse
                            return null;
                        @field(result, name) = entry.set.get(T, entity_item.id) orelse
                            return null;
                    }
                } else {
                    @field(result, name) = entity_item.id;
                }
            }
            return result;
        }
    };
}

/// Asserts that `Item` is a struct or tuple of component pointers and `EntityId` fields.
fn validateTarget(comptime Item: type) void {
    const info = switch (@typeInfo(Item)) {
        .@"struct" => |info| info,
        else => @compileError(
            "Query target must be a struct or tuple of pointer fields, got " ++ @typeName(Item),
        ),
    };
    if (info.field_names.len == 0) @compileError("Query target must declare at least one field");

    inline for (info.field_names, info.field_types) |name, F| {
        if (F != EntityId) validatePointerField(name, F);
    }
}

/// Asserts that `F` is a single-item pointer to a component.
fn validatePointerField(comptime name: []const u8, comptime F: type) void {
    const pointer = switch (@typeInfo(F)) {
        .pointer => |pointer| pointer,
        else => @compileError(
            "Query target field `" ++ name ++ "` must be a component pointer or EntityId",
        ),
    };
    if (pointer.size != .one) @compileError(
        "Query target field `" ++ name ++ "` must be a single-item pointer",
    );

    component.assertComponent(pointer.child, "Query target field `" ++ name ++ "`");
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const CompMark = component.Mark;

const Position = struct {
    pub const se_component: CompMark = .{};
    x: i32,
    y: i32,
};

const Velocity = struct {
    pub const se_component: CompMark = .{};
    dx: i32,
    dy: i32,
};

const Frozen = struct {
    pub const se_component: CompMark = .{};
};

const Health = struct {
    pub const se_component: CompMark = .{ .storage = .sparse_set };
    value: u32,
};

/// Counts the items a query type yields over `world`.
fn count(comptime Q: type, world: *World) usize {
    var query = Q.extract(world);
    var visited: usize = 0;
    while (query.next()) |_| visited += 1;
    return visited;
}

test "a query visits the entities holding its target components" {
    const allocator = std.testing.allocator;
    var world = World.init(allocator);
    defer world.deinit();

    const both = try world.addEntity(.{
        Position{ .x = 1, .y = 2 },
        Velocity{ .dx = 3, .dy = 4 },
    });
    const position_only = try world.addEntity(.{Position{ .x = 5, .y = 6 }});
    _ = try world.addEntity(.{Velocity{ .dx = 7, .dy = 8 }});

    var query = Query(struct {
        id: EntityId,
        pos: *const Position,
    }).extract(&world);

    const first = query.next().?;
    try expect(first.id.eql(both));
    try expectEqual(1, first.pos.x);

    const second = query.next().?;
    try expect(second.id.eql(position_only));
    try expectEqual(5, second.pos.x);

    try expect(query.next() == null);
}

test "mutable target fields write into component storage" {
    const allocator = std.testing.allocator;
    var world = World.init(allocator);
    defer world.deinit();

    const id = try world.addEntity(.{
        Position{ .x = 1, .y = 2 },
        Velocity{ .dx = 3, .dy = 4 },
    });

    var query = Query(struct {
        pos: *const Position,
        vel: *Velocity,
    }).extract(&world);

    const item = query.next().?;
    item.vel.dx = 30;
    item.vel.dy = 40;
    try expectEqual(1, item.pos.x);
    try expect(query.next() == null);

    // A second query observes the values written through the first one.
    var reread = Query(struct {
        id: EntityId,
        vel: *const Velocity,
    }).extract(&world);

    const written = reread.next().?;
    try expect(written.id.eql(id));
    try expectEqual(30, written.vel.dx);
    try expectEqual(40, written.vel.dy);
}

test "tuple targets are yielded for callers to destructure" {
    const allocator = std.testing.allocator;
    var world = World.init(allocator);
    defer world.deinit();

    const id = try world.addEntity(.{
        Position{ .x = 1, .y = 2 },
        Velocity{ .dx = 3, .dy = 4 },
    });
    _ = try world.addEntity(.{Position{ .x = 5, .y = 6 }});

    var query = Query(struct { EntityId, *const Position, *Velocity }).extract(&world);
    const item = query.next().?;
    const entity_id, const position, const velocity = item;
    try expect(entity_id.eql(id));
    try expectEqual(1, position.x);
    try expectEqual(3, velocity.dx);

    velocity.dx = 30;
    try expect(query.next() == null);

    var reread = Query(struct { *const Velocity }).extract(&world);
    try expectEqual(30, reread.next().?[0].dx);
}

test "sparse set components are matched per entity and visible to filters" {
    const allocator = std.testing.allocator;
    var world = World.init(allocator);
    defer world.deinit();

    const both = try world.addEntity(.{
        Position{ .x = 1, .y = 2 },
        Health{ .value = 10 },
    });
    const position_only = try world.addEntity(.{Position{ .x = 3, .y = 4 }});
    const health_only = try world.addEntity(.{Health{ .value = 20 }});
    const velocity_only = try world.addEntity(.{Velocity{ .dx = 5, .dy = 6 }});

    var query = Query(struct {
        id: EntityId,
        pos: *const Position,
        health: *Health,
    }).extract(&world);

    const item = query.next().?;
    try expect(item.id.eql(both));
    try expectEqual(1, item.pos.x);
    try expectEqual(10, item.health.value);
    item.health.value = 11;
    try expect(query.next() == null);

    // Sparse-only targets visit entities across different archetypes.
    var healths = Query(struct { id: EntityId, health: *const Health }).extract(&world);

    const first = healths.next().?;
    try expect(first.id.eql(both));
    try expectEqual(11, first.health.value);

    const second = healths.next().?;
    try expect(second.id.eql(health_only));
    try expectEqual(20, second.health.value);

    try expect(healths.next() == null);

    // Entities without the sparse component remain visible to archetype-only queries.
    try expectEqual(2, count(Query(struct { pos: *const Position }), &world));

    // Filters inspect the entity signature, so sparse components match per entity.
    var with_health = QueryF(struct { id: EntityId }, .{With(Health)}).extract(&world);
    try expect(with_health.next().?.id.eql(both));
    try expect(with_health.next().?.id.eql(health_only));
    try expect(with_health.next() == null);

    var without_health = QueryF(struct { id: EntityId }, .{Without(Health)}).extract(&world);
    try expect(without_health.next().?.id.eql(position_only));
    try expect(without_health.next().?.id.eql(velocity_only));
    try expect(without_health.next() == null);
}

test "filters narrow the archetypes a query visits" {
    const allocator = std.testing.allocator;
    var world = World.init(allocator);
    defer world.deinit();

    const moving = try world.addEntity(.{
        Position{ .x = 1, .y = 2 },
        Velocity{ .dx = 3, .dy = 4 },
    });
    const still = try world.addEntity(.{Position{ .x = 5, .y = 6 }});
    const frozen = try world.addEntity(.{
        Position{ .x = 7, .y = 8 },
        Frozen{},
    });

    try expectEqual(3, count(Query(struct { pos: *const Position }), &world));

    try expectEqual(1, count(
        QueryF(struct { pos: *const Position }, .{With(Velocity)}),
        &world,
    ));
    try expectEqual(2, count(
        QueryF(struct { pos: *const Position }, .{Without(Velocity)}),
        &world,
    ));
    try expectEqual(2, count(
        QueryF(struct { pos: *const Position }, .{All(.{
            With(Position),
            Without(Frozen),
        })}),
        &world,
    ));
    try expectEqual(2, count(
        QueryF(struct { pos: *const Position }, .{Any(.{
            With(Velocity),
            With(Frozen),
        })}),
        &world,
    ));
    try expectEqual(2, count(
        QueryF(struct { pos: *const Position }, .{Not(With(Velocity))}),
        &world,
    ));

    // `With` yields the moving entity, `Without` yields the other two in archetype order.
    var with_velocity = QueryF(struct { id: EntityId }, .{With(Velocity)}).extract(&world);
    try expect(with_velocity.next().?.id.eql(moving));
    try expect(with_velocity.next() == null);

    var without_velocity = QueryF(struct { id: EntityId }, .{
        Without(Velocity),
    }).extract(&world);
    try expect(without_velocity.next().?.id.eql(still));
    try expect(without_velocity.next().?.id.eql(frozen));
    try expect(without_velocity.next() == null);
}

test "queries are empty without matching archetypes" {
    const allocator = std.testing.allocator;
    var world = World.init(allocator);
    defer world.deinit();

    try expectEqual(0, count(Query(struct { pos: *const Position }), &world));

    _ = try world.addEntity(.{Velocity{ .dx = 1, .dy = 2 }});
    try expectEqual(0, count(Query(struct { pos: *const Position }), &world));

    // A component that is not registered is absent from every archetype.
    const Never = struct {
        pub const se_component: CompMark = .{};
    };
    try expectEqual(0, count(Query(struct { never: *const Never }), &world));
}

/// 6000 + 2000 bytes per entity, so a chunk holds two entities and the third
/// opens a second chunk.
const Big = struct {
    pub const se_component: CompMark = .{};
    bytes: [6000]u8,
};

const Small = struct {
    pub const se_component: CompMark = .{};
    bytes: [2000]u8,
};

test "queries walk every chunk of an archetype" {
    const allocator = std.testing.allocator;
    var world = World.init(allocator);
    defer world.deinit();

    for (0..3) |index| {
        var big: Big = undefined;
        @memset(&big.bytes, @intCast(index));
        var small: Small = undefined;
        @memset(&small.bytes, @intCast(index + 10));
        _ = try world.addEntity(.{ big, small });
    }

    var query = Query(struct {
        id: EntityId,
        big: *Big,
        small: *const Small,
    }).extract(&world);

    var visited: usize = 0;
    while (query.next()) |item| : (visited += 1) {
        try expectEqual(@as(u32, @intCast(visited)), item.id.index.get());
        try expectEqual(@as(u8, @intCast(visited)), item.big.bytes[0]);
        try expectEqual(@as(u8, @intCast(visited + 10)), item.small.bytes[0]);
        item.big.bytes[0] = 0xFF;
    }
    try expectEqual(3, visited);

    var reread = Query(struct { big: *const Big }).extract(&world);
    while (reread.next()) |item| {
        try expectEqual(0xFF, item.big.bytes[0]);
    }
}

test {
    _ = filter;
}
