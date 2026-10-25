const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const sparse_set = engine.ecs.entity.sparse_set;
const SparseSetId = sparse_set.Id;
const SparseSet = sparse_set.SparseSet;
const TypeId = engine.reflect.TypeId;
const TypeMeta = engine.reflect.TypeMeta;

pub const Entry = struct {
    id: SparseSetId,
    set: SparseSet,
};

type_to_id: std.AutoHashMapUnmanaged(TypeId, SparseSetId),
entries: std.ArrayList(Entry),
retired: std.ArrayList(SparseSetId),
allocator: Allocator,

/// Creates an empty registry; free it with `deinit`.
pub fn init(allocator: Allocator) @This() {
    return .{
        .type_to_id = .empty,
        .entries = .empty,
        .retired = .empty,
        .allocator = allocator,
    };
}

/// Releases every registered sparse set and the registry's lookup storage.
pub fn deinit(self: *@This()) void {
    for (self.entries.items) |*entry| entry.set.deinit();
    self.type_to_id.deinit(self.allocator);
    self.entries.deinit(self.allocator);
    self.retired.deinit(self.allocator);
}

const expectEqual = std.testing.expectEqual;

test "init starts empty and deinit releases registered sets" {
    const allocator = std.testing.allocator;
    var registry = init(allocator);
    defer registry.deinit();

    try expectEqual(0, registry.type_to_id.count());
    try expectEqual(0, registry.entries.items.len);
    try expectEqual(0, registry.retired.items.len);

    const id = SparseSetId.init(0, 1);
    try registry.type_to_id.put(allocator, TypeId.of(u32), id);

    var set = try SparseSet.initWithCapacity(allocator, TypeMeta.of(u32), 2);
    errdefer set.deinit();
    try registry.entries.append(allocator, .{ .id = id, .set = set });
}
