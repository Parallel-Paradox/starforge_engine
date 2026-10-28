//! Queries: typed iteration over the entities matching a component layout and filters.
//!
//! `Query(target)` yields one item per entity holding every component in `target`;
//! `QueryF(target, filters)` narrows the archetypes further with `filter` operators.
//! The yielded item is `target` itself, with each field addressing the entity's value:
//!
//! ```zig
//! var query = Query(struct {
//!     id: EntityId,
//!     position: *const Position,
//!     velocity: *Velocity,
//! }).extract(&world);
//!
//! while (query.next()) |item| item.velocity.dx += 1;
//! ```
//!
//! Filters are evaluated once per archetype, and every target component is implicitly
//! required. Only archetype-stored components are supported. Items address archetype
//! storage, so they are invalidated by structural changes that grow or move the matched
//! archetype, such as spawning entities or reserving capacity.

const std = @import("std");

const engine = @import("engine");
const ecs = engine.ecs;
const World = ecs.World;
const component = ecs.component;
const CompId = component.Id;
const entity = ecs.entity;
const EntityId = entity.Id;
const Archetype = entity.archetype.Archetype;
const ArchetypeId = entity.archetype.Id;
const TypeId = engine.reflect.TypeId;

pub const filter = @import("filter.zig");

// Filter operators, in scope so tests read like `. { With(A), Without(B) }`.
const With = filter.With;
const Without = filter.Without;
const All = filter.All;
const Any = filter.Any;
const Not = filter.Not;

/// A query over the entities holding every component in `target`, with no extra filters.
///
/// `target` is a struct whose fields are either `*T` (mutable), `*const T` (read-only)
/// for archetype components, or `EntityId`. See `QueryF` for filters.
pub fn Query(comptime target: type) type {
    return QueryF(target, .{});
}

/// A query over the entities holding every component in `target`, narrowed by `filters`.
///
/// `filters` is a tuple of filter types, for example `.{With(Frozen)}`, evaluated
/// once per archetype. A query is single-use state: extract one, walk it with `next`.
pub fn QueryF(comptime target: type, comptime filters: anytype) type {
    validateTarget(target);
    filter.validate(filters);

    const info = @typeInfo(target).@"struct";
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
        world: *World,
        /// Component ids of the target fields, resolved when the query is extracted.
        comp_ids: [comp_types.len]?CompId = undefined,
        /// Column index in the current archetype for each target field.
        columns: [comp_types.len]usize = undefined,
        /// Id of the last archetype inspected; scanning resumes after it.
        next_archetype: ArchetypeId = .invalid,
        /// Id of the archetype under iteration, or `.invalid` while seeking one.
        current: ArchetypeId = .invalid,
        /// Row of the next entity inside `current`.
        row: usize = 0,

        /// The yielded item: `target` with its fields filled in.
        pub const Item = target;

        /// Builds a query over `world`.
        ///
        /// Component ids are resolved once, so register the components before extracting
        /// a query that targets them.
        pub fn extract(world: *World) @This() {
            var self: @This() = .{ .world = world };
            inline for (comp_types, 0..) |maybe, i| {
                if (maybe) |T| self.comp_ids[i] = world.componentRegistry().getByType(T);
            }
            return self;
        }

        /// Returns the next matching entity, or null once every archetype was visited.
        pub fn next(self: *@This()) ?Item {
            while (true) {
                if (self.world.archetypeRegistry().getById(self.current)) |archetype| {
                    if (self.row < archetype.len()) {
                        const row = self.row;
                        self.row += 1;
                        return self.build(archetype, row);
                    }
                    self.current = ArchetypeId.invalid;
                }

                if (!self.advance()) return null;
            }
        }

        /// Moves to the next archetype passing the filters and holding the target.
        fn advance(self: *@This()) bool {
            const registry = self.world.archetypeRegistry();
            const entries = registry.entries.items;
            const start = if (self.next_archetype.index.tryGet()) |index| index + 1 else 0;

            for (entries[start..]) |entry| {
                self.next_archetype = entry.id;

                const archetype = registry.getById(entry.id) orelse continue;
                if (!self.accept(archetype)) continue;

                self.current = entry.id;
                self.row = 0;
                self.enter(archetype);
                return true;
            }
            return false;
        }

        /// Whether `archetype` passes the filters and holds every target component.
        fn accept(self: *@This(), archetype: *Archetype) bool {
            const context: filter.Context = .{
                .registry = self.world.componentRegistry(),
                .signature = archetype.meta.signature,
            };
            if (!filter.matches(filters, context)) return false;

            inline for (comp_types, 0..) |maybe, i| {
                if (maybe != null) {
                    const id = self.comp_ids[i] orelse return false;
                    if (!context.hasId(id)) return false;
                }
            }
            return true;
        }

        /// Resolves the column of each target field in `archetype`.
        fn enter(self: *@This(), archetype: *Archetype) void {
            inline for (comp_types, 0..) |maybe, i| {
                if (maybe) |T| {
                    self.columns[i] = archetype.meta.id_to_col.get(TypeId.of(T)).?;
                }
            }
        }

        /// Builds the item for `row` of `archetype`.
        fn build(self: *@This(), archetype: *Archetype, row: usize) Item {
            var result: Item = undefined;
            inline for (comp_types, field_names, 0..) |maybe, name, i| {
                if (maybe) |T| {
                    @field(result, name) = archetype.typedAt(T, self.columns[i], row).ptr;
                } else {
                    @field(result, name) = archetype.ids.items[row];
                }
            }
            return result;
        }
    };
}

/// Asserts that `target` is a struct of component pointers and `EntityId` fields.
fn validateTarget(comptime target: type) void {
    const info = switch (@typeInfo(target)) {
        .@"struct" => |info| info,
        else => @compileError(
            "Query target must be a struct of pointer fields, got " ++ @typeName(target),
        ),
    };
    if (info.is_tuple) @compileError("Query target must have named fields");
    if (info.field_names.len == 0) @compileError("Query target must declare at least one field");

    inline for (info.field_names, info.field_types) |name, F| {
        if (F != EntityId) validatePointerField(name, F);
    }
}

/// Asserts that `F` is a single-item pointer to an archetype component.
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

    const T = pointer.child;
    component.assertComponent(T, "Query target field `" ++ name ++ "`");
    if (T.se_component.storage != .archetype) @compileError(
        "Query target field `" ++ name ++ "` requires archetype storage, but " ++
            @typeName(T) ++ " uses a sparse set",
    );
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
