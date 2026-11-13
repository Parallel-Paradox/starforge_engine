//! Iterates the entity slots of an archetype, one entity at a time.

const std = @import("std");

const engine = @import("engine");
const entity = engine.ecs.entity;
const EntityId = entity.Id;
const Archetype = entity.archetype.Archetype;

archetype: *Archetype,
/// Global row of the next entity to yield.
row: usize = 0,
/// Index of the chunk holding the next entity.
chunk_index: usize = 0,
/// Row of the next entity inside `chunk_index`.
row_in_chunk: usize = 0,

/// A slot with access to its component columns and id. Unused slots must be
/// initialized before reading. Storage growth or row removal invalidates the item.
pub const Item = struct {
    id: *EntityId,
    /// Index of the chunk holding this entity.
    chunk_index: usize,
    /// Row of this entity inside `chunk_index`.
    row_in_chunk: usize,
    /// The archetype holding this entity.
    archetype: *Archetype,

    /// Returns the bytes of column `val` for this entity.
    ///
    /// Asserts that `val` is a column index of the archetype.
    pub fn column(item: @This(), val: usize) []u8 {
        const archetype = item.archetype;
        std.debug.assert(val < archetype.meta.columns.items.len);
        std.debug.assert(item.chunk_index < archetype.chunks.items.len);
        std.debug.assert(item.row_in_chunk < archetype.layout.capacity);

        const size = archetype.meta.columns.items[val].meta.size;
        const offset = archetype.layout.column_offsets.items[val] + item.row_in_chunk * size;
        const chunk = archetype.chunks.items[item.chunk_index];

        return (chunk.ptr + offset)[0..size];
    }
};

/// Returns the next live entity, or null once the live entities are exhausted.
pub fn next(self: *@This()) ?Item {
    if (self.row >= self.archetype.len()) return null;
    return self.nextStorage();
}

/// Returns the next allocated slot, bounded by capacity.
pub fn nextStorage(self: *@This()) ?Item {
    if (self.row >= self.archetype.capacity()) return null;

    const item: Item = .{
        .id = &self.archetype.ids.allocatedSlice()[self.row],
        .chunk_index = self.chunk_index,
        .row_in_chunk = self.row_in_chunk,
        .archetype = self.archetype,
    };

    // Move the cursor past the yielded entity, rolling over into the next chunk.
    self.row += 1;
    self.row_in_chunk += 1;
    if (self.row_in_chunk == self.archetype.layout.capacity) {
        self.row_in_chunk = 0;
        self.chunk_index += 1;
    }

    return item;
}

/// Returns the item at the current position, without advancing.
///
/// Asserts that the current row is live.
pub fn get(self: @This()) Item {
    std.debug.assert(self.row < self.archetype.len());

    return .{
        .id = &self.archetype.ids.items[self.row],
        .chunk_index = self.chunk_index,
        .row_in_chunk = self.row_in_chunk,
        .archetype = self.archetype,
    };
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const CompRegistry = engine.ecs.component.Registry;
const CompMark = engine.ecs.component.Mark;

/// 6000 + 2000 bytes per entity, so a chunk holds two entities (16000 <= 16 KB)
/// and a third entity opens a new chunk.
const Big = struct {
    pub const se_component: CompMark = .{};
    bytes: [6000]u8,
};

const Small = struct {
    pub const se_component: CompMark = .{};
    bytes: [2000]u8,
};

test "next returns null for an empty archetype" {
    const allocator = std.testing.allocator;

    var registry = CompRegistry.init(allocator);
    defer registry.deinit();

    var arch = try Archetype.init(allocator, &.{}, registry);
    defer arch.deinit();

    var it = arch.iter();
    try expect(it.next() == null);
    try expect(it.nextStorage() == null);

    try arch.reserve(1);
    var unused = arch.iterUnused();
    unused.nextStorage().?.id.* = EntityId.init(0, 1);
    try expect(unused.nextStorage() == null);
    try expectEqual(0, arch.len());
    try expectEqual(0, arch.chunks.items[0].len);
}

test "iter visits live and unused slots across chunks and exposes their columns" {
    const allocator = std.testing.allocator;

    var registry = CompRegistry.init(allocator);
    defer registry.deinit();
    const big = try registry.register(Big);
    const small = try registry.register(Small);

    var arch = try Archetype.init(allocator, &.{ small, big }, registry);
    defer arch.deinit();

    // Component capacity grows to four, but only three ids have storage.
    try arch.ids.ensureTotalCapacityPrecise(allocator, 3);
    try arch.reserve(3);
    try expectEqual(2, arch.layout.capacity);
    try expectEqual(2, arch.chunks.items.len);
    try expectEqual(3, arch.ids.capacity);
    try expectEqual(3, arch.capacity());

    _ = arch.appendUninitAssumeCapacity(EntityId.init(0, 1));
    @memset(arch.at(0, 0).data, 0);
    @memset(arch.at(1, 0).data, 0);
    var unused = arch.iterUnused();
    try expect(unused.next() == null);
    var filled: usize = 1;
    while (unused.nextStorage()) |item| : (filled += 1) {
        try expectEqual(filled / 2, item.chunk_index);
        try expectEqual(filled % 2, item.row_in_chunk);
        try expectEqual(&arch.ids.allocatedSlice()[filled], item.id);
        item.id.* = EntityId.init(@intCast(filled), 1);
        @memset(item.column(0), 0);
        @memset(item.column(1), 0);
    }
    try expectEqual(3, filled);
    try expect(unused.nextStorage() == null);
    try expectEqual(1, arch.len());
    try expectEqual(1, arch.chunks.items[0].len);
    try expectEqual(0, arch.chunks.items[1].len);

    arch.ids.items.len = 2;
    arch.chunks.items[0].len = 2;
    var boundary = arch.iterUnused();
    const last = boundary.nextStorage().?;
    try expectEqual(1, last.chunk_index);
    try expectEqual(0, last.row_in_chunk);
    try expect(last.id.eql(EntityId.init(2, 1)));
    arch.ids.items.len = filled;
    arch.chunks.items[1].len = 1;

    // Columns are packed by size, so `Big` is column 0 and `Small` is column 1.
    const big_offset = arch.layout.column_offsets.items[0];
    const small_offset = arch.layout.column_offsets.items[1];
    try expectEqual(0, big_offset);
    try expectEqual(2 * @sizeOf(Big), small_offset);

    var it = arch.iter();
    const first = it.next().?;
    try expect(first.id.eql(EntityId.init(0, 1)));

    var visited: usize = 1;
    while (it.next()) |item| : (visited += 1) {
        try expect(item.id.eql(EntityId.init(@intCast(visited), 1)));
        item.column(0)[0] = @intCast(visited + 1);
        item.column(1)[0] = @intCast(visited + 10);
    }
    try expectEqual(3, visited);
    try expect(it.next() == null);

    // `first` was yielded two calls ago, but its snapshot still addresses row 0.
    first.column(0)[0] = 0xAA;
    first.column(1)[0] = 0xBB;

    try expectEqual(0xAA, arch.chunks.items[0].ptr[big_offset]);
    try expectEqual(0xBB, arch.chunks.items[0].ptr[small_offset]);
    try expectEqual(2, arch.chunks.items[0].ptr[big_offset + @sizeOf(Big)]);
    try expectEqual(11, arch.chunks.items[0].ptr[small_offset + @sizeOf(Small)]);
    try expectEqual(3, arch.chunks.items[1].ptr[big_offset]);
    try expectEqual(12, arch.chunks.items[1].ptr[small_offset]);
}
