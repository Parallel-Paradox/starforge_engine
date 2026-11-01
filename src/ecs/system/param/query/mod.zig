//! Queries: typed iteration over entities matching a component layout and filters.
//!
//! `Query(Item)` yields one item per entity holding every component in `Item`.
//! `QueryF(Item, filters)` narrows the result with `Filter` operators.
//!
//! `Item` is a struct or tuple of `*T`, `*const T`, or `EntityId` fields.
//! Tuples are yielded as tuples and destructured by the caller:
//!
//! ```zig
//! var query = try Query(struct { EntityId, *const Position, *Velocity }).extract(&world);
//! defer query.deinit();
//! try query.reset();
//! while (query.next()) |item| {
//!     const id, const position, const velocity = item;
//!     velocity.dx = position.x;
//! }
//! ```
//!
//! A query caches matching archetypes. `reset` must be called before iterating and
//! after structural changes; it applies the archetype change log and restarts iteration.
//!
//! Filters are evaluated per archetype, then per entity when undecided. Every target
//! component is implicitly required. Items point into component storage and are
//! invalidated by structural changes that grow or move it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const ecs = engine.ecs;
const World = ecs.World;
const component = ecs.component;
const entity = ecs.entity;
const EntityId = entity.Id;
const ArchetypeIter = entity.archetype.Iter;
const ArchetypeId = entity.archetype.Id;
const TypeId = engine.reflect.TypeId;

pub const Filter = @import("Filter.zig");

pub const State = @import("State.zig");

/// A query over entities holding every component in `Item`, without filters.
/// See `QueryF` for filters.
pub fn Query(comptime I: type) type {
    return QueryF(I, .{});
}

/// A query over entities holding every component in `Item`, narrowed by `filters`.
///
/// `filters` is a tuple of filter types, for example `.{With(Frozen)}`.
/// Call `reset` before iterating and after structural changes; call `deinit` when done.
pub fn QueryF(comptime I: type, comptime filters: anytype) type {
    validateTarget(I);

    const info = @typeInfo(I).@"struct";
    const field_names = info.field_names;
    const field_types = info.field_types;

    // The component type of each target field, or null for an `EntityId` field.
    const comp_types: [field_types.len]?type = blk: {
        var types: [field_types.len]?type = undefined;
        for (field_types, 0..) |F, i| {
            types[i] = if (F == EntityId) null else @typeInfo(F).pointer.child;
        }
        break :blk types;
    };

    return struct {
        /// Runtime state: filter, target layout, archetype cache, and cursor.
        state: State,

        pub const Item = I;

        /// Builds a query over `world`. Call `reset` before `next`, and `deinit` when done.
        /// Panics when a target component is not registered.
        pub fn extract(world: *World) Allocator.Error!@This() {
            const targets = try world.allocator.alloc(?State.Target, comp_types.len);
            inline for (comp_types, 0..) |maybe, i| {
                targets[i] = if (maybe) |T| .{
                    .id = world.compReg().getByType(T) orelse @panic(
                        @typeName(T) ++ " is not registered in the component registry",
                    ),
                    .type_id = TypeId.of(T),
                    .storage = T.se_component.storage,
                } else null;
            }

            const filter = Filter.init(world.allocator, world.compReg(), filters) catch |err| {
                world.allocator.free(targets);
                return err;
            };

            // `State` owns `targets` and `filter` from here on.
            return .{ .state = State.init(world, targets, filter) };
        }

        /// Releases the filter tree, target layout, and cached archetypes.
        pub fn deinit(self: *@This()) void {
            self.state.deinit();
        }

        /// Refreshes the sparse set ids and cached archetypes, and restarts iteration.
        pub fn reset(self: *@This()) Allocator.Error!void {
            try self.state.reset();
        }

        /// Returns the next matching entity, or null once every archetype was visited.
        /// Call `reset` at least once before the first call.
        pub fn next(self: *@This()) ?Item {
            while (self.state.next()) |entity_item| {
                if (self.buildItem(entity_item)) |item| return item;
            }
            return null;
        }

        /// Builds the item for `entity_item`, or null when a filter rejects it or a
        /// sparse-set target is missing.
        fn buildItem(self: *@This(), entity_item: ArchetypeIter.Item) ?Item {
            const state = &self.state;
            const cached = state.caches.items[state.current_index];

            if (cached.needs_entity_filter) {
                const target = state.world.entityReg().get(entity_item.id) orelse return null;
                if (!state.filter.judgeEntity(target.signature)) return null;
            }

            var result: Item = undefined;
            inline for (comp_types, field_names, 0..) |maybe, name, i| {
                if (maybe) |T| {
                    if (T.se_component.storage == .archetype) {
                        const bytes = entity_item.column(cached.columns[i]);
                        @field(result, name) = @ptrCast(@alignCast(bytes.ptr));
                    } else {
                        const sparse_id = state.targets[i].?.sparse_id;
                        const set = state.world.sparseReg().getById(sparse_id) orelse return null;
                        @field(result, name) = set.get(T, entity_item.id) orelse return null;
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

const With = Filter.With;
const Without = Filter.Without;
const All = Filter.All;
const Any = Filter.Any;

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
    var query = Q.extract(world) catch @panic("test query allocation failed");
    defer query.deinit();
    query.reset() catch @panic("test query reset failed");
    return drain(&query);
}

/// Drains a query instance and returns how many items it yielded.
fn drain(query: anytype) usize {
    var visited: usize = 0;
    while (query.next()) |_| visited += 1;
    return visited;
}

test "queries yield target fields and write through pointers" {
    const allocator = std.testing.allocator;
    var world = World.init(allocator);
    defer world.deinit();

    _ = try world.addEntity(.{Velocity{ .dx = 7, .dy = 8 }});

    const both = try world.addEntity(.{
        Position{ .x = 1, .y = 2 },
        Velocity{ .dx = 3, .dy = 4 },
    });
    const position_only = try world.addEntity(.{Position{ .x = 5, .y = 6 }});

    // A struct target yields one item per matching entity.
    try expectEqual(2, count(Query(struct { pos: *const Position }), &world));
    var positions = try Query(struct { id: EntityId, pos: *const Position }).extract(&world);
    defer positions.deinit();
    try positions.reset();
    const first = positions.next().?;
    try expect(first.id.eql(both));
    try expectEqual(1, first.pos.x);
    const second = positions.next().?;
    try expect(second.id.eql(position_only));
    try expectEqual(5, second.pos.x);
    try expect(positions.next() == null);

    // Mutable targets write into component storage.
    var mutable = try Query(struct { pos: *const Position, vel: *Velocity }).extract(&world);
    defer mutable.deinit();
    try mutable.reset();
    const item = mutable.next().?;
    item.vel.dx = 30;
    item.vel.dy = 40;
    try expectEqual(1, item.pos.x);
    try expect(mutable.next() == null);

    // A tuple target yields the fields in declaration order.
    var tuple = try Query(struct { EntityId, *const Position, *const Velocity }).extract(&world);
    defer tuple.deinit();
    try tuple.reset();
    const entity_id, const position, const velocity = tuple.next().?;
    try expect(entity_id.eql(both));
    try expectEqual(1, position.x);
    try expectEqual(30, velocity.dx);
    try expectEqual(40, velocity.dy);
    try expect(tuple.next() == null);
}

test "sparse components are matched per entity" {
    const allocator = std.testing.allocator;
    var world = World.init(allocator);
    defer world.deinit();

    const both = try world.addEntity(.{
        Position{ .x = 1, .y = 2 },
        Health{ .value = 10 },
    });
    _ = try world.addEntity(.{Position{ .x = 3, .y = 4 }});
    const health_only = try world.addEntity(.{Health{ .value = 20 }});
    _ = try world.addEntity(.{Velocity{ .dx = 5, .dy = 6 }});

    var query = try Query(struct {
        id: EntityId,
        pos: *const Position,
        health: *Health,
    }).extract(&world);
    defer query.deinit();
    try query.reset();

    const item = query.next().?;
    try expect(item.id.eql(both));
    try expectEqual(1, item.pos.x);
    try expectEqual(10, item.health.value);
    item.health.value = 11;
    try expect(query.next() == null);

    // Sparse-only targets visit entities across different archetypes.
    var healths = try Query(struct { id: EntityId, health: *const Health }).extract(&world);
    defer healths.deinit();
    try healths.reset();

    const first = healths.next().?;
    try expect(first.id.eql(both));
    try expectEqual(11, first.health.value);

    const second = healths.next().?;
    try expect(second.id.eql(health_only));
    try expectEqual(20, second.health.value);

    try expect(healths.next() == null);

    // Entities without the sparse component remain visible to archetype-only queries.
    try expectEqual(2, count(Query(struct { pos: *const Position }), &world));

    // A sparse filter is decided per entity, not per archetype.
    try expectEqual(2, count(QueryF(struct { id: EntityId }, .{With(Health)}), &world));
    try expectEqual(2, count(QueryF(struct { id: EntityId }, .{Without(Health)}), &world));

    // An archetype-stored match decides the whole archetype before the sparse check.
    try expectEqual(3, count(
        QueryF(struct { id: EntityId }, .{Any(.{
            With(Position),
            With(Health),
        })}),
        &world,
    ));

    // `Without` accepts the archetypes that lack Position regardless of Health.
    try expectEqual(3, count(
        QueryF(struct { id: EntityId }, .{Any(.{
            Without(Position),
            With(Health),
        })}),
        &world,
    ));

    // An archetype-stored and a sparse requirement together narrow to one entity.
    var both_required = try QueryF(struct { id: EntityId }, .{
        With(.{ Position, Health }),
    }).extract(&world);
    defer both_required.deinit();
    try both_required.reset();
    try expect(both_required.next().?.id.eql(both));
    try expect(both_required.next() == null);
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

    // `With` yields the moving entity, `Without` yields the other two in archetype order.
    var with_velocity = try QueryF(struct { id: EntityId }, .{With(Velocity)}).extract(&world);
    defer with_velocity.deinit();
    try with_velocity.reset();
    try expect(with_velocity.next().?.id.eql(moving));
    try expect(with_velocity.next() == null);

    var without_velocity = try QueryF(struct { id: EntityId }, .{
        Without(Velocity),
    }).extract(&world);
    defer without_velocity.deinit();
    try without_velocity.reset();
    try expect(without_velocity.next().?.id.eql(still));
    try expect(without_velocity.next().?.id.eql(frozen));
    try expect(without_velocity.next() == null);
}

test "reset refreshes the cached archetypes" {
    const allocator = std.testing.allocator;
    var world = World.init(allocator);
    defer world.deinit();

    _ = try world.addEntity(.{Position{ .x = 1, .y = 2 }});

    var query = try Query(struct { pos: *const Position }).extract(&world);
    defer query.deinit();
    try query.reset();
    try expectEqual(1, drain(&query));

    // A new matching archetype is picked up incrementally.
    const added = try world.addEntity(.{
        Position{ .x = 3, .y = 4 },
        Velocity{ .dx = 5, .dy = 6 },
    });
    try query.reset();
    try expectEqual(2, drain(&query));

    // Removal is picked up incrementally too.
    const archetype_id = world.entityReg().get(added).?.archetype_id;
    try world.archReg().remove(archetype_id);
    try query.reset();
    try expectEqual(1, drain(&query));

    // An evicted change-log window forces a full rebuild instead.
    const log = &world.archReg().change_log;
    log.record(ArchetypeId.init(0, 0));
    log.oldest_ver = query.state.version + 1;

    try query.reset();
    try expectEqual(1, drain(&query));
    try expectEqual(log.next_ver, query.state.version);
}

/// 6000 + 2000 bytes per entity. A chunk holds two entities; the third opens a second.
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

    var query = try Query(struct {
        id: EntityId,
        big: *Big,
        small: *const Small,
    }).extract(&world);
    defer query.deinit();
    try query.reset();

    var visited: usize = 0;
    while (query.next()) |item| : (visited += 1) {
        try expectEqual(@as(u32, @intCast(visited)), item.id.index.get());
        try expectEqual(@as(u8, @intCast(visited)), item.big.bytes[0]);
        try expectEqual(@as(u8, @intCast(visited + 10)), item.small.bytes[0]);
        item.big.bytes[0] = 0xFF;
    }
    try expectEqual(3, visited);

    var reread = try Query(struct { big: *const Big }).extract(&world);
    defer reread.deinit();
    try reread.reset();
    while (reread.next()) |item| {
        try expectEqual(0xFF, item.big.bytes[0]);
    }
}

test {
    _ = Filter;
    _ = State;
}
