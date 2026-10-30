//! Queries: typed iteration over entities matching a component layout and filters.
//!
//! `Query(Item)` yields one item per entity holding every component in `Item`.
//! `QueryF(Item, filters)` narrows the result with `filter` operators.
//!
//! `Item` is a struct or tuple of `*T`, `*const T`, or `EntityId` fields.
//! Tuples are yielded as tuples and destructured by the caller:
//!
//! ```zig
//! var query = try Query(struct { EntityId, *const Position, *Velocity }).extract(&world);
//! defer query.deinit();
//! while (query.next()) |item| {
//!     const id, const position, const velocity = item;
//!     velocity.dx = position.x;
//! }
//! ```
//!
//! A query caches matching archetypes. `reset` applies structural changes from the
//! archetype change log and restarts iteration.
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
const CompId = component.Id;
const entity = ecs.entity;
const EntityId = entity.Id;
const Archetype = entity.archetype.Archetype;
const ArchetypeIter = entity.archetype.Iter;
const ArchetypeId = entity.archetype.Id;
const ArchetypeRegistry = entity.archetype.Registry;
const TypeId = engine.reflect.TypeId;

pub const filter = @import("filter.zig");

pub const State = @import("State.zig");

/// A query over entities holding every component in `Item`, without filters.
/// See `QueryF` for filters.
pub fn Query(comptime I: type) type {
    return QueryF(I, .{});
}

/// A query over entities holding every component in `Item`, narrowed by `filters`.
///
/// `filters` is a tuple of filter types, for example `.{With(Frozen)}`.
/// Call `reset` after structural changes and `deinit` when done.
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
        /// Component ids of the target fields, resolved at extract.
        comp_ids: [comp_types.len]?CompId = undefined,
        /// Cached archetypes matching this query, refreshed by `reset`.
        state: ?State = null,
        /// Column index in the current archetype for each target field.
        columns: [comp_types.len]usize = undefined,
        /// Index of the next cached archetype to inspect.
        next_index: usize = 0,
        /// Iterator over the current archetype; null while seeking one.
        iter: ?ArchetypeIter = null,
        /// Whether entities in the current archetype need sparse-set filter checks.
        needs_entity_filter: bool = false,

        pub const Item = I;

        /// Builds a query over `world` and performs a full state refresh.
        /// Register target components before extracting. Call `deinit` when done.
        pub fn extract(world: *World) Allocator.Error!@This() {
            var self: @This() = .{ .world = world };
            errdefer self.deinit();
            inline for (comp_types, 0..) |maybe, i| {
                if (maybe) |T| self.comp_ids[i] = world.compReg().getByType(T);
            }
            try self.reset();
            return self;
        }

        /// Releases the cached archetype list.
        pub fn deinit(self: *@This()) void {
            if (self.state) |*state| state.deinit(self.world.allocator);
        }

        /// Refreshes the cached archetypes and restarts iteration.
        /// Applies change-log entries incrementally; rebuilds when the query version is
        /// outside the retained log window.
        pub fn reset(self: *@This()) Allocator.Error!void {
            try self.updateState();
            self.next_index = 0;
            self.iter = null;
        }

        /// Returns the next matching entity, or null once every archetype was visited.
        pub fn next(self: *@This()) ?Item {
            while (true) {
                if (self.iter) |*iter| {
                    while (iter.next()) |entity_item| {
                        if (self.buildItem(entity_item)) |item| return item;
                    }
                    self.iter = null;
                }

                if (!self.advance()) return null;
            }
        }

        /// Moves to the next cached archetype.
        fn advance(self: *@This()) bool {
            if (self.state == null) return false;
            const state = &self.state.?;

            while (self.next_index < state.archetypes.items.len) {
                const cached = state.archetypes.items[self.next_index];
                self.next_index += 1;

                const archetype = self.world.archReg().getById(cached.id) orelse continue;
                self.needs_entity_filter = cached.needs_entity_filter;
                self.iter = archetype.iter();
                self.resolveColumns(archetype);
                return true;
            }
            return false;
        }

        /// Resolves the column of each archetype-stored target field in `archetype`.
        fn resolveColumns(self: *@This(), archetype: *Archetype) void {
            inline for (comp_types, 0..) |maybe, i| {
                if (maybe) |T| {
                    if (T.se_component.storage == .archetype) {
                        self.columns[i] = archetype.meta.id_to_col.get(TypeId.of(T)).?;
                    }
                }
            }
        }

        /// Builds the item for `entity_item`, or null when a filter rejects it or a
        /// sparse-set target is missing.
        fn buildItem(self: *@This(), entity_item: ArchetypeIter.Item) ?Item {
            if (comptime has_filters) {
                if (self.needs_entity_filter) {
                    const target = self.world.entityReg().get(entity_item.id) orelse return null;
                    const context: filter.Context = .{
                        .registry = self.world.compReg(),
                        .signature = target.signature,
                    };
                    if (!filter.matchesSparse(filters, context)) return null;
                }
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

        /// Whether `archetype` holds every archetype-stored target component.
        fn accept(self: *const @This(), archetype: *const Archetype) bool {
            const signature = archetype.meta.signature;
            inline for (comp_types, 0..) |maybe, i| {
                if (maybe) |T| {
                    const id = self.comp_ids[i] orelse return false;
                    if (T.se_component.storage == .archetype and !signature.has(id)) return false;
                }
            }
            return true;
        }

        /// Returns the filter decision for `archetype`, or null when it does not match.
        fn classifyArchetype(
            self: *@This(),
            archetype: *const Archetype,
        ) ?filter.ArchetypeDecision {
            if (!self.accept(archetype)) return null;

            if (comptime has_filters) {
                const decision = filter.archetypeDecision(filters, .{
                    .registry = self.world.compReg(),
                    .signature = archetype.meta.signature,
                });
                if (decision == .reject) return null;
                return decision;
            }

            return .accept;
        }

        /// Applies changes since `state.version`, rebuilding when they were evicted.
        fn updateState(self: *@This()) Allocator.Error!void {
            const registry = self.world.archReg();
            const log = &registry.change_log;

            if (self.state == null) return self.rebuildState();
            const state = &self.state.?;

            if (state.version < log.oldest_ver or state.version > log.next_ver) {
                return self.rebuildState();
            }

            var ver = state.version;
            while (ver < log.next_ver) : (ver += 1) {
                const changed = log.get(ver) orelse return self.rebuildState();
                try self.applyChange(registry, changed);
            }
            state.version = log.next_ver;
        }

        /// Rebuilds the cached archetype list from the registry.
        fn rebuildState(self: *@This()) Allocator.Error!void {
            const registry = self.world.archReg();
            const allocator = self.world.allocator;

            if (self.state == null) self.state = State{};
            const state = &self.state.?;

            state.archetypes.clearRetainingCapacity();
            errdefer {
                state.deinit(allocator);
                self.state = null;
            }

            for (registry.entries.items) |*entry| {
                if (!entry.id.isValid()) continue;
                const decision = self.classifyArchetype(&entry.archetype) orelse continue;
                try state.archetypes.append(allocator, .{
                    .id = entry.id,
                    .needs_entity_filter = decision == .per_entity,
                });
            }

            state.version = registry.change_log.next_ver;
        }

        /// Applies one change-log entry to the cached archetype list.
        fn applyChange(
            self: *@This(),
            registry: *ArchetypeRegistry,
            id: ArchetypeId,
        ) Allocator.Error!void {
            const index = id.index.tryGet() orelse return;
            const state = &self.state.?;

            if (index < registry.entries.items.len and
                registry.entries.items[index].id.eql(id))
            {
                const decision =
                    self.classifyArchetype(&registry.entries.items[index].archetype) orelse {
                        state.remove(id);
                        return;
                    };
                try state.insert(self.world.allocator, .{
                    .id = id,
                    .needs_entity_filter = decision == .per_entity,
                });
                return;
            }

            state.remove(id);
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

const With = filter.With;
const Without = filter.Without;
const All = filter.All;
const Any = filter.Any;
const Not = filter.Not;

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
    try expectEqual(0, count(Query(struct { pos: *const Position }), &world));

    const both = try world.addEntity(.{
        Position{ .x = 1, .y = 2 },
        Velocity{ .dx = 3, .dy = 4 },
    });
    const position_only = try world.addEntity(.{Position{ .x = 5, .y = 6 }});

    // A struct target yields one item per matching entity.
    var positions = try Query(struct { id: EntityId, pos: *const Position }).extract(&world);
    defer positions.deinit();
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
    const item = mutable.next().?;
    item.vel.dx = 30;
    item.vel.dy = 40;
    try expectEqual(1, item.pos.x);
    try expect(mutable.next() == null);

    // A tuple target yields the fields in declaration order.
    var tuple = try Query(struct { EntityId, *const Position, *const Velocity }).extract(&world);
    defer tuple.deinit();
    const entity_id, const position, const velocity = tuple.next().?;
    try expect(entity_id.eql(both));
    try expectEqual(1, position.x);
    try expectEqual(30, velocity.dx);
    try expectEqual(40, velocity.dy);
    try expect(tuple.next() == null);

    // Unregistered targets match nothing.
    const Never = struct {
        pub const se_component: CompMark = .{};
    };
    try expectEqual(0, count(Query(struct { never: *const Never }), &world));
}

test "sparse set targets are matched per entity" {
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

    const item = query.next().?;
    try expect(item.id.eql(both));
    try expectEqual(1, item.pos.x);
    try expectEqual(10, item.health.value);
    item.health.value = 11;
    try expect(query.next() == null);

    // Sparse-only targets visit entities across different archetypes.
    var healths = try Query(struct { id: EntityId, health: *const Health }).extract(&world);
    defer healths.deinit();

    const first = healths.next().?;
    try expect(first.id.eql(both));
    try expectEqual(11, first.health.value);

    const second = healths.next().?;
    try expect(second.id.eql(health_only));
    try expectEqual(20, second.health.value);

    try expect(healths.next() == null);

    // Entities without the sparse component remain visible to archetype-only queries.
    try expectEqual(2, count(Query(struct { pos: *const Position }), &world));
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
    var with_velocity = try QueryF(struct { id: EntityId }, .{With(Velocity)}).extract(&world);
    defer with_velocity.deinit();
    try expect(with_velocity.next().?.id.eql(moving));
    try expect(with_velocity.next() == null);

    var without_velocity = try QueryF(struct { id: EntityId }, .{
        Without(Velocity),
    }).extract(&world);
    defer without_velocity.deinit();
    try expect(without_velocity.next().?.id.eql(still));
    try expect(without_velocity.next().?.id.eql(frozen));
    try expect(without_velocity.next() == null);
}

test "filters decide per archetype before checking sparse components per entity" {
    const allocator = std.testing.allocator;
    var world = World.init(allocator);
    defer world.deinit();

    const moving_hurt = try world.addEntity(.{
        Position{ .x = 1, .y = 2 },
        Health{ .value = 10 },
    });
    _ = try world.addEntity(.{Position{ .x = 3, .y = 4 }});
    _ = try world.addEntity(.{
        Velocity{ .dx = 5, .dy = 6 },
        Health{ .value = 20 },
    });
    _ = try world.addEntity(.{Velocity{ .dx = 7, .dy = 8 }});

    // Sparse-only filters match per entity.
    try expectEqual(2, count(QueryF(struct { id: EntityId }, .{With(Health)}), &world));
    try expectEqual(2, count(QueryF(struct { id: EntityId }, .{Without(Health)}), &world));

    // Position accepts the archetype; Health is not checked per entity.
    try expectEqual(3, count(
        QueryF(struct { id: EntityId }, .{Any(.{
            With(Position),
            With(Health),
        })}),
        &world,
    ));

    // Position decides the archetype; Health is checked per entity.
    var with_both = try QueryF(struct { id: EntityId }, .{
        With(.{ Position, Health }),
    }).extract(&world);
    defer with_both.deinit();
    try expect(with_both.next().?.id.eql(moving_hurt));
    try expect(with_both.next() == null);

    var all_both = try QueryF(struct { id: EntityId }, .{All(.{
        With(Position),
        With(Health),
    })}).extract(&world);
    defer all_both.deinit();
    try expect(all_both.next().?.id.eql(moving_hurt));
    try expect(all_both.next() == null);

    // Without(Position) accepts archetypes that lack Position regardless of Health.
    try expectEqual(3, count(
        QueryF(struct { id: EntityId }, .{Any(.{
            Without(Position),
            With(Health),
        })}),
        &world,
    ));
}

test "reset reapplies archetype changes incrementally" {
    const allocator = std.testing.allocator;
    var world = World.init(allocator);
    defer world.deinit();

    _ = try world.addEntity(.{Position{ .x = 1, .y = 2 }});

    var query = try Query(struct { pos: *const Position }).extract(&world);
    defer query.deinit();

    try expectEqual(1, drain(&query));

    // A new matching archetype is picked up by reset.
    const added = try world.addEntity(.{
        Position{ .x = 3, .y = 4 },
        Velocity{ .dx = 5, .dy = 6 },
    });
    try query.reset();
    try expectEqual(2, drain(&query));

    // Removal is picked up incrementally.
    const archetype_id = world.entityReg().get(added).?.archetype_id;
    try world.archReg().remove(archetype_id);
    try query.reset();
    try expectEqual(1, drain(&query));
}

test "reset rebuilds the cache when the change log evicted its version" {
    const allocator = std.testing.allocator;
    var world = World.init(allocator);
    defer world.deinit();

    _ = try world.addEntity(.{Position{ .x = 1, .y = 2 }});

    var query = try Query(struct { pos: *const Position }).extract(&world);
    defer query.deinit();

    const log = &world.archReg().change_log;
    // Simulate an evicted change-log window.
    log.record(ArchetypeId.init(0, 0));
    log.oldest_ver = query.state.?.version + 1;

    try query.reset();
    try expectEqual(1, drain(&query));
    try expectEqual(log.next_ver, query.state.?.version);
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
    while (reread.next()) |item| {
        try expectEqual(0xFF, item.big.bytes[0]);
    }
}

test {
    _ = filter;
}
