//! Iterates the live entities of a sparse set.

const std = @import("std");

const engine = @import("engine");
const entity = engine.ecs.entity;
const EntityId = entity.Id;
const SparseSet = entity.sparse_set.SparseSet;

set: *const SparseSet,
/// Row of the next entity to yield.
row: usize = 0,

/// An entity yielded by `next`, with access to its component value.
///
/// The row is snapshotted when the item is yielded, so it keeps addressing the
/// same value after the iterator has advanced.
pub const Item = struct {
    id: EntityId,
    /// Row of this entity's value in the dense buffer.
    row: usize,
    /// The sparse set holding this value.
    set: *const SparseSet,

    /// Returns the bytes of this entity's component value.
    ///
    /// Asserts that the set still holds the row.
    pub fn value(item: @This()) []u8 {
        const set = item.set;
        std.debug.assert(item.row < set.len());

        const size = set.meta.size;
        return (set.ptr + item.row * size)[0..size];
    }
};

/// Returns the next live entity, or null once the set is exhausted.
pub fn next(self: *@This()) ?Item {
    if (self.row >= self.set.len()) return null;

    const item: Item = .{
        .id = self.set.entity_ids.items[self.row],
        .row = self.row,
        .set = self.set,
    };
    self.row += 1;
    return item;
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const TypeMeta = engine.reflect.TypeMeta;

test "next returns null for an empty sparse set" {
    const allocator = std.testing.allocator;

    var set = try SparseSet.init(allocator, TypeMeta.of(u32));
    defer set.deinit();

    var it = set.iter();
    try expect(it.next() == null);
}

test "iter visits every entity and exposes its value" {
    const allocator = std.testing.allocator;

    var set = try SparseSet.initWithCapacity(allocator, TypeMeta.of(u32), 4);
    defer set.deinit();

    for (0..3) |index| {
        set.entity_ids.appendAssumeCapacity(EntityId.init(@intCast(index), 1));
    }

    var it = set.iter();
    const first = it.next().?;
    try expect(first.id.eql(EntityId.init(0, 1)));

    var visited: usize = 1;
    while (it.next()) |item| : (visited += 1) {
        try expect(item.id.eql(EntityId.init(@intCast(visited), 1)));
        const ptr: *u32 = @ptrCast(@alignCast(item.value().ptr));
        ptr.* = @intCast(visited + 10);
    }
    try expectEqual(3, visited);
    try expect(it.next() == null);

    // `first` was yielded two calls ago, but its snapshot still addresses row 0.
    const first_ptr: *u32 = @ptrCast(@alignCast(first.value().ptr));
    first_ptr.* = 0xAA;

    const values: [*]u32 = @ptrCast(@alignCast(set.ptr));
    try expectEqual(0xAA, values[0]);
    try expectEqual(11, values[1]);
    try expectEqual(12, values[2]);
}
