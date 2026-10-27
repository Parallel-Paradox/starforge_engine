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

/// Returns the entry for the sparse set of `meta`, creating and registering it when needed.
/// The pointer is invalidated when another sparse set is registered.
pub fn getOrCreate(self: *@This(), meta: TypeMeta) Allocator.Error!*Entry {
    const type_id = meta.id;
    if (self.type_to_id.get(type_id)) |id| {
        return &self.entries.items[id.index.get()];
    }

    const allocator = self.allocator;
    try self.entries.ensureUnusedCapacity(allocator, 1);
    try self.type_to_id.ensureUnusedCapacity(allocator, 1);

    const set = try SparseSet.init(allocator, meta);

    const reuse = self.retired.items.len != 0;
    const id = if (reuse)
        self.retired.getLast()
    else
        SparseSetId.init(@intCast(self.entries.items.len), 0);
    if (reuse) _ = self.retired.pop();

    const entry: Entry = .{ .id = id, .set = set };
    if (id.index.get() == self.entries.items.len) {
        self.entries.appendAssumeCapacity(entry);
    } else {
        self.entries.items[id.index.get()] = entry;
    }
    self.type_to_id.putAssumeCapacityNoClobber(type_id, id);
    return &self.entries.items[id.index.get()];
}

const expect = std.testing.expect;
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

test "getOrCreate reuses a set per component type" {
    const allocator = std.testing.allocator;
    var registry = init(allocator);
    defer registry.deinit();

    const first = try registry.getOrCreate(TypeMeta.of(u32));
    const first_id = first.id;
    try expect(first.set.meta.eql(TypeMeta.of(u32)));

    const again = try registry.getOrCreate(TypeMeta.of(u32));
    try expect(first == again);
    try expect(first_id.eql(again.id));

    const other = try registry.getOrCreate(TypeMeta.of(i32));
    try expect(!first_id.eql(other.id));
    try expect(other.set.meta.eql(TypeMeta.of(i32)));
    try expectEqual(2, registry.entries.items.len);
}
