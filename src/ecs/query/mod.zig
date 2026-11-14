//! Typed queries over entities and their components.
//!
//! `Query(Item)` selects entities containing every component in `Item`;
//! `QueryF(Item, filters)` adds component-presence filters.
//! `Item` is a struct or tuple of `*T`, `*const T`, and `EntityId` fields.
//!
//! Queries declare component read/write access and reject overlapping fields
//! involving a write. Returned pointers may be invalidated by structural changes.

const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const ecs = engine.ecs;
const World = ecs.World;
const component = ecs.component;
const entity = ecs.entity;
const EntityId = entity.Id;
const ArchetypeId = entity.archetype.Id;
const TypeId = engine.reflect.TypeId;
const Access = ecs.system.Access;

pub const Filter = @import("Filter.zig");
pub const State = @import("State.zig");
pub const Iter = @import("Iter.zig");

/// A query over entities holding every component in `Item`, without filters.
/// See `QueryF` for filters.
pub fn Query(comptime I: type) type {
    return QueryF(I, .{});
}

/// A query over entities holding every component in `Item`, narrowed by `filters`.
///
/// `filters` is a filter description or tuple of descriptions, e.g. `.{With(Frozen)}`.
/// The `Context` owns the cached archetypes; call `extract` at the start of every
/// run to refresh them and start a new iteration.
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

    const comp_count = comptime blk: {
        var total: usize = 0;
        for (comp_types) |T| {
            if (T != null) total += 1;
        }
        break :blk total;
    };
    const metadata = comptime blk: {
        var entries: [comp_count]Access.Entry.Spec = undefined;
        var names: [comp_count][]const u8 = undefined;
        var next: usize = 0;
        for (comp_types, field_types, field_names) |maybe, F, name| {
            if (maybe) |T| {
                entries[next] = .{
                    .target = T,
                    .mode = if (@typeInfo(F).pointer.attrs.@"const") .read else .write,
                };
                names[next] = name;
                next += 1;
            }
        }
        break :blk .{ .entries = entries, .names = names };
    };
    const entries = metadata.entries;
    const access_spec: Access.Spec = .{ .shared = .{ .components = .{
        .entries = &entries,
        .filter = comptime accessFilter(&comp_types, filters),
    } } };
    comptime {
        if (Access.findStaticConflict(&.{access_spec})) |conflict| {
            const a = conflict[0].entry.?.index;
            const b = conflict[1].entry.?.index;
            @compileError(std.fmt.comptimePrint(
                "Query target fields `{s}` and `{s}` have conflicting access to {s}",
                .{ metadata.names[a], metadata.names[b], @typeName(entries[a].target) },
            ));
        }
    }

    return struct {
        pub const Item = I;
        pub const access: Access.Spec = access_spec;

        /// Cached archetypes owned by the system and shared by every iteration
        /// extracted from it.
        pub const Context = State;

        iter: Iter,

        /// Refreshes `ctx`'s cached archetypes and starts a new iteration over
        /// `world`. The first call installs the target layout and filter.
        /// Panics when a target component is not registered. Fails with
        /// `error.FilterTooComplex` when the filter expands beyond `Filter.max_terms`.
        pub fn extract(ctx: *Context) Filter.InitError!@This() {
            if (ctx.targets == null) {
                const world = ctx.world;

                const built = blk: {
                    const targets = try world.allocator.alloc(?State.Target, comp_types.len);
                    errdefer world.allocator.free(targets);

                    inline for (comp_types, 0..) |maybe, i| {
                        targets[i] = if (maybe) |T| .{
                            .id = world.compReg().idOf(T) orelse @panic(
                                @typeName(T) ++ " is not registered in the component registry",
                            ),
                            .type_id = TypeId.of(T),
                            .storage = T.se_component.storage,
                        } else null;
                    }

                    const filter = try Filter.init(world.allocator, world.compReg(), filters);
                    break :blk .{ .targets = targets, .filter = filter };
                };

                // `State` owns `targets` and `filter` from here on.
                ctx.targets = built.targets;
                ctx.filter = built.filter;
                try ctx.rebuild();
            } else {
                try ctx.update();
            }

            return .{ .iter = ctx.iter() };
        }

        /// Returns the next matching entity, or null once every archetype was
        /// visited.
        pub fn next(self: *@This()) ?Item {
            while (self.iter.next()) |entity_item| {
                if (buildItem(&self.iter, entity_item)) |item| return item;
            }
            return null;
        }

        /// Builds the item for `entity_item`, or null when a filter rejects it or a
        /// sparse-set target is missing.
        fn buildItem(iter: *const Iter, entity_item: Iter.Item) ?Item {
            if (!iter.accept(entity_item)) return null;

            var result: Item = undefined;
            inline for (comp_types, field_names, 0..) |maybe, name, i| {
                if (maybe) |T| {
                    if (T.se_component.storage == .archetype) {
                        const bytes = iter.column(entity_item, i);
                        @field(result, name) = @ptrCast(@alignCast(bytes.ptr));
                    } else {
                        const set = iter.sparseSet(i) orelse return null;
                        @field(result, name) = set.get(T, entity_item.id.*) orelse return null;
                    }
                } else {
                    @field(result, name) = entity_item.id.*;
                }
            }
            return result;
        }
    };
}

/// The condition under which a query declares component access: every target component
/// is required, narrowed by the user's filters. Null when it matches every entity.
fn accessFilter(
    comptime comp_types: []const ?type,
    comptime filters: anytype,
) ?Filter.Node.Spec {
    const user = Filter.normalizeRoot(filters);
    const root_count = blk: {
        var total: usize = @intFromBool(user != null);
        for (comp_types) |maybe| total += @intFromBool(maybe != null);
        break :blk total;
    };
    if (root_count == 0) return null;

    const children = blk: {
        var out: [root_count]Filter.Node.Spec = undefined;
        var next: usize = 0;
        for (comp_types) |maybe| {
            if (maybe) |T| {
                out[next] = .{ .leaf = .{ .component = T, .require = true } };
                next += 1;
            }
        }
        if (user) |root| out[next] = root;
        break :blk out;
    };
    return Filter.Branch.spec(.all, &children);
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
    var ctx = Q.Context.init(world);
    defer ctx.deinit();

    var query = Q.extract(&ctx) catch @panic("test query allocation failed");
    return drain(&query);
}

/// Drains a query and returns how many items it yields.
fn drain(query: anytype) usize {
    var visited: usize = 0;
    while (query.next()) |_| visited += 1;
    return visited;
}

test "queries yield target fields and write through pointers" {
    const allocator = std.testing.allocator;
    var world = World.init(allocator, std.testing.io);
    defer world.deinit();

    _ = try world.addEntity(.{Velocity{ .dx = 7, .dy = 8 }});

    const both = try world.addEntity(.{
        Position{ .x = 1, .y = 2 },
        Velocity{ .dx = 3, .dy = 4 },
    });
    const position_only = try world.addEntity(.{Position{ .x = 5, .y = 6 }});

    // A struct target yields one item per matching entity.
    try expectEqual(2, count(Query(struct { pos: *const Position }), &world));

    const ById = Query(struct { id: EntityId, pos: *const Position });
    var by_id_ctx = ById.Context.init(&world);
    defer by_id_ctx.deinit();
    var by_id = try ById.extract(&by_id_ctx);

    const first = by_id.next().?;
    try expect(first.id.eql(both));
    try expectEqual(1, first.pos.x);

    const second = by_id.next().?;
    try expect(second.id.eql(position_only));
    try expectEqual(5, second.pos.x);
    try expect(by_id.next() == null);

    // Mutable targets write into component storage.
    const Mutable = Query(struct { pos: *const Position, vel: *Velocity });
    const Tuple = Query(struct { EntityId, *const Position, *const Velocity });
    inline for (.{ Mutable, Tuple }) |Q| {
        const spec = comptime ecs.system.param.access(Q);
        const entries = spec.shared.components.entries;
        try expectEqual(2, entries.len);
        try expectEqual(0, spec.shared.resources.len);
        inline for (entries, .{ Position, Velocity }, 0..) |entry, T, i| {
            try expect(entry.target == T);
            const mode: Access.Mode = if (Q == Mutable and i == 1) .write else .read;
            try expectEqual(mode, entry.mode);
        }
    }
    var mutable_ctx = Mutable.Context.init(&world);
    defer mutable_ctx.deinit();
    var mutable = try Mutable.extract(&mutable_ctx);

    const item = mutable.next().?;
    item.vel.dx = 30;
    item.vel.dy = 40;
    try expectEqual(1, item.pos.x);
    try expect(mutable.next() == null);

    // A tuple target yields the fields in declaration order.
    var tuple_ctx = Tuple.Context.init(&world);
    defer tuple_ctx.deinit();
    var tuple = try Tuple.extract(&tuple_ctx);

    const entity_id, const position, const velocity = tuple.next().?;
    try expect(entity_id.eql(both));
    try expectEqual(1, position.x);
    try expectEqual(30, velocity.dx);
    try expectEqual(40, velocity.dy);
    try expect(tuple.next() == null);

    // Duplicate reads and EntityIds may alias, but never grant mutable access.
    const Shared = Query(struct { EntityId, *const Position, EntityId, *const Position });
    var shared_ctx = Shared.Context.init(&world);
    defer shared_ctx.deinit();
    var shared = try Shared.extract(&shared_ctx);
    const a, const p, const b, const q = shared.next().?;
    try expect(a.eql(b));
    try expect(p == q);
    try expectEqual(2, Shared.access.shared.components.entries.len);
}

test "sparse components are matched per entity" {
    const allocator = std.testing.allocator;
    var world = World.init(allocator, std.testing.io);
    defer world.deinit();

    const both = try world.addEntity(.{
        Position{ .x = 1, .y = 2 },
        Health{ .value = 10 },
    });
    _ = try world.addEntity(.{Position{ .x = 3, .y = 4 }});
    const health_only = try world.addEntity(.{Health{ .value = 20 }});
    _ = try world.addEntity(.{Velocity{ .dx = 5, .dy = 6 }});

    const WithHealth = Query(struct {
        id: EntityId,
        pos: *const Position,
        health: *Health,
    });
    const spec = comptime ecs.system.param.access(WithHealth);
    try expectEqual(2, spec.shared.components.entries.len);
    try expect(spec.shared.components.entries[1].target == Health);
    try expectEqual(Access.Mode.write, spec.shared.components.entries[1].mode);
    var with_health_ctx = WithHealth.Context.init(&world);
    defer with_health_ctx.deinit();
    var with_health = try WithHealth.extract(&with_health_ctx);

    const item = with_health.next().?;
    try expect(item.id.eql(both));
    try expectEqual(1, item.pos.x);
    try expectEqual(10, item.health.value);
    item.health.value = 11;
    try expect(with_health.next() == null);

    // Sparse-only targets visit entities across different archetypes.
    const Healths = Query(struct { id: EntityId, health: *const Health });
    var healths_ctx = Healths.Context.init(&world);
    defer healths_ctx.deinit();
    var healths = try Healths.extract(&healths_ctx);

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
    const BothRequired = QueryF(struct { id: EntityId }, .{
        With(.{ Position, Health }),
    });
    var both_required_ctx = BothRequired.Context.init(&world);
    defer both_required_ctx.deinit();
    var both_required = try BothRequired.extract(&both_required_ctx);

    try expect(both_required.next().?.id.eql(both));
    try expect(both_required.next() == null);
}

test "filters narrow the archetypes a query visits" {
    const allocator = std.testing.allocator;
    var world = World.init(allocator, std.testing.io);
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
    const WithVelocity = QueryF(struct { id: EntityId }, .{With(Velocity)});
    var with_velocity_ctx = WithVelocity.Context.init(&world);
    defer with_velocity_ctx.deinit();
    var with_velocity = try WithVelocity.extract(&with_velocity_ctx);
    try expect(with_velocity.next().?.id.eql(moving));
    try expect(with_velocity.next() == null);

    const WithoutVelocity = QueryF(struct { id: EntityId }, .{
        Without(Velocity),
    });
    var without_velocity_ctx = WithoutVelocity.Context.init(&world);
    defer without_velocity_ctx.deinit();
    var without_velocity = try WithoutVelocity.extract(&without_velocity_ctx);
    try expect(without_velocity.next().?.id.eql(still));
    try expect(without_velocity.next().?.id.eql(frozen));
    try expect(without_velocity.next() == null);
}

test "filters do not remove declared component access" {
    const Q = QueryF(struct { *Position }, Without(Velocity));
    const components = Q.access.shared.components;
    try expectEqual(Access.Mode.write, components.entries[0].mode);

    // The access condition requires the target components and keeps the user filter.
    const filter = components.filter.?;
    try expect(filter.branch.kind == .all);
    try expectEqual(2, filter.branch.children.len);
    try expect(filter.branch.children[0].leaf.component == Position);
    try expect(filter.branch.children[0].leaf.require);
    try expect(filter.branch.children[1].leaf.component == Velocity);
    try expect(!filter.branch.children[1].leaf.require);

    // Targets alone are a plain requirement, and entity ids alone match everything.
    const Plain = Query(struct { *Position });
    try expect(Plain.access.shared.components.filter.?.leaf.component == Position);
    const Ids = Query(struct { EntityId });
    try expect(Ids.access.shared.components.filter == null);
}

test "extract refreshes the cached archetypes" {
    const allocator = std.testing.allocator;
    var world = World.init(allocator, std.testing.io);
    defer world.deinit();

    _ = try world.addEntity(.{Position{ .x = 1, .y = 2 }});

    const Positions = Query(struct { pos: *const Position });
    var ctx = Positions.Context.init(&world);
    defer ctx.deinit();

    var query = try Positions.extract(&ctx);
    try expectEqual(1, drain(&query));

    // A new matching archetype is picked up incrementally.
    const added = try world.addEntity(.{
        Position{ .x = 3, .y = 4 },
        Velocity{ .dx = 5, .dy = 6 },
    });
    query = try Positions.extract(&ctx);
    try expectEqual(2, drain(&query));

    // Removal is picked up incrementally too.
    const archetype_id = world.entityReg().get(added).?.archetype_id;
    try world.archeReg().remove(archetype_id);
    query = try Positions.extract(&ctx);
    try expectEqual(1, drain(&query));

    // An evicted change-log window forces a full rebuild instead.
    const log = &world.archeReg().change_log;
    log.record(ArchetypeId.init(0, 0));
    log.oldest_ver = ctx.version + 1;

    query = try Positions.extract(&ctx);
    try expectEqual(1, drain(&query));
    try expectEqual(log.next_ver, ctx.version);
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
    var world = World.init(allocator, std.testing.io);
    defer world.deinit();

    for (0..3) |index| {
        var big: Big = undefined;
        @memset(&big.bytes, @intCast(index));
        var small: Small = undefined;
        @memset(&small.bytes, @intCast(index + 10));
        _ = try world.addEntity(.{ big, small });
    }

    const Chunked = Query(struct {
        id: EntityId,
        big: *Big,
        small: *const Small,
    });
    var chunked_ctx = Chunked.Context.init(&world);
    defer chunked_ctx.deinit();
    var chunked = try Chunked.extract(&chunked_ctx);

    var visited: usize = 0;
    while (chunked.next()) |item| : (visited += 1) {
        try expectEqual(visited, item.id.index.get());
        try expectEqual(visited, item.big.bytes[0]);
        try expectEqual(visited + 10, item.small.bytes[0]);
        item.big.bytes[0] = 0xFF;
    }
    try expectEqual(3, visited);

    const Reread = Query(struct { big: *const Big });
    var reread_ctx = Reread.Context.init(&world);
    defer reread_ctx.deinit();
    var reread = try Reread.extract(&reread_ctx);

    while (reread.next()) |item| {
        try expectEqual(0xFF, item.big.bytes[0]);
    }
}

test {
    _ = Filter;
    _ = State;
    _ = Iter;
}
