const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const ecs = engine.ecs;
const Id = ecs.Id;

const entity = ecs.entity;
const Signature = entity.Signature;
const ArchetypeId = entity.archetype.Id;
const SparseSetId = entity.sparse_set.Id;

id: Id,
signature: Signature,
archetype_id: ArchetypeId,
archetype_row: usize,
sparse_comps: std.ArrayList(SparseSetId),

/// Creates an entity that belongs to no archetype and has no components.
pub fn init(allocator: Allocator, id: Id) @This() {
    return .{
        .id = id,
        .signature = Signature.init(allocator),
        .archetype_id = .invalid,
        .archetype_row = 0,
        .sparse_comps = .empty,
    };
}

/// Releases the entity's signature and sparse component list.
pub fn deinit(self: *@This(), allocator: Allocator) void {
    self.signature.deinit(allocator);
    self.sparse_comps.deinit(allocator);
}

/// Describes entity modification using compile-time component or marked bundle
/// type lists.
/// Duplicate or overlapping component types are rejected after flattening.
///
/// Use `Change(&.{ Position, Health }, &.{Velocity})` for a homogeneous batch.
/// An empty insertion list defaults `insert` to the empty tuple.
pub fn Change(comptime insert_list: []const type, comptime remove_list: []const type) type {
    const component = ecs.component;
    const Bundle = engine.reflect.Bundle;
    const Insert = @Tuple(insert_list);
    const insert_types = Bundle.flatTypes(Insert);
    const remove_types = Bundle.flatTypes(@Tuple(remove_list));
    for (insert_types, 0..) |T, i| {
        component.assertComponent(T, "Entity.Change insert");
        for (insert_types[0..i]) |U| {
            if (T == U)
                @compileError("Entity.Change inserts component more than once: " ++ @typeName(T));
        }
    }
    for (remove_types, 0..) |T, i| {
        component.assertComponent(T, "Entity.Change remove");
        for (remove_types[0..i]) |U| {
            if (T == U)
                @compileError("Entity.Change removes component more than once: " ++ @typeName(T));
        }
        for (insert_types) |U| {
            if (T == U)
                @compileError("Entity.Change both inserts and removes component: " ++ @typeName(T));
        }
    }

    if (insert_list.len == 0) return struct {
        id: Id,
        insert: Insert = .{},
        comptime remove: []const type = &remove_types,
    };
    return struct {
        id: Id,
        insert: Insert,
        comptime remove: []const type = &remove_types,
    };
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const Position = struct {
    pub const se_component: ecs.component.Mark = .{};
    x: i32,
};

const Velocity = struct {
    pub const se_component: ecs.component.Mark = .{ .storage = .sparse_set };
    dx: i32,
};

const Transform = struct {
    pub const se_bundle: engine.reflect.Bundle.Mark = .{};
    position: Position,
};

test "Change preserves batch values and stores removal types at comptime" {
    const Request = Change(&.{Transform}, &.{Velocity});
    const batch = [_]Request{
        .{ .id = Id.init(0, 0), .insert = .{Transform{ .position = .{ .x = 3 } }} },
        .{ .id = Id.init(1, 0), .insert = .{Transform{ .position = .{ .x = 7 } }} },
    };
    for (batch, [_]i32{ 3, 7 }, 0..) |request, x, i| {
        try expect(request.id.eql(Id.init(@intCast(i), 0)));
        try expectEqual(x, request.insert[0].position.x);
    }
    try expectEqual(1, batch[0].remove.len);
    try expect(batch[0].remove[0] == Velocity);
    try expect(@FieldType(Request, "insert") == @Tuple(&.{Transform}));
    try expectEqual(@sizeOf(struct { id: Id, insert: @Tuple(&.{Transform}) }), @sizeOf(Request));
}

test "Change supports insertion-only requests" {
    const insert: Change(&.{ Position, Velocity }, &.{}) = .{
        .id = Id.init(0, 0),
        .insert = .{ Position{ .x = 3 }, Velocity{ .dx = 7 } },
    };
    try expectEqual(3, insert.insert[0].x);
    try expectEqual(7, insert.insert[1].dx);
    try expectEqual(0, insert.remove.len);
}

test "Change flattens nested removals and defaults to an empty insertion tuple" {
    const Movement = struct {
        pub const se_bundle: engine.reflect.Bundle.Mark = .{};
        transform: Transform,
        velocity: Velocity,
    };
    const remove: Change(&.{}, &.{Movement}) = .{ .id = Id.init(0, 0) };
    try expectEqual(0, remove.insert.len);
    try expectEqual(2, remove.remove.len);
    try expect(remove.remove[0] == Position);
    try expect(remove.remove[1] == Velocity);

    const empty: Change(&.{}, &.{}) = .{ .id = remove.id };
    try expectEqual(0, empty.insert.len);
    try expectEqual(0, empty.remove.len);
}
