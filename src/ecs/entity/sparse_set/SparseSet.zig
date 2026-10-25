const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const AlignedBuffer = engine.base.AlignedBuffer;
const NonMax = engine.base.niche.NonMax;
const TypeMeta = engine.reflect.TypeMeta;
const EntityId = engine.ecs.entity.Id;

pub const DenseId = NonMax(u32);

meta: TypeMeta,
/// `EntityId.index` to `DenseId` mapping.
sparse_to_dense: std.ArrayList(DenseId),
/// Dense data pointer.
ptr: [*]u8,
/// Dense array to sparse entity ids.
entity_ids: std.ArrayList(EntityId),
allocator: Allocator,

/// The number of entities in the sparse set.
pub fn len(self: @This()) usize {
    return self.entity_ids.items.len;
}

/// The capacity of the sparse set.
pub fn capacity(self: @This()) usize {
    return self.entity_ids.capacity;
}

/// Creates an empty sparse set for `meta`. The dense data buffer is allocated
/// when capacity is reserved; free the set with `deinit`.
pub fn init(allocator: Allocator, meta: TypeMeta) Allocator.Error!@This() {
    return .{
        .meta = meta,
        .sparse_to_dense = .empty,
        .ptr = AlignedBuffer.empty(meta.alignment).ptr,
        .entity_ids = .empty,
        .allocator = allocator,
    };
}

/// Runs the `deinit` of every live managed component, then frees the dense data
/// buffer and both index arrays.
pub fn deinit(self: *@This()) void {
    // Destroy each value before releasing the buffer that holds it.
    switch (self.meta.need_deinit) {
        .trivial => {},
        .managed => |deinit_fn| {
            for (0..self.len()) |index| {
                deinit_fn(@ptrCast(self.ptr + index * self.meta.size));
            }
        },
    }

    // `entity_ids.capacity` is the dense capacity, so the dense buffer occupies
    // exactly this many bytes. Rebuild the descriptor to hand it to the allocator.
    const dense_size = self.entity_ids.capacity * self.meta.size;
    var buffer: AlignedBuffer = if (dense_size == 0)
        .empty(self.meta.alignment)
    else
        .{
            .ptr = self.ptr,
            .len = dense_size,
            .alignment = self.meta.alignment,
        };
    buffer.deinit(self.allocator);

    self.sparse_to_dense.deinit(self.allocator);
    self.entity_ids.deinit(self.allocator);
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "init creates an empty sparse set and deinit frees its arrays" {
    const allocator = std.testing.allocator;
    const meta = TypeMeta.of(u32);

    var set = try init(allocator, meta);
    defer set.deinit();

    try expect(set.meta.eql(meta));
    try expectEqual(0, set.len());
    try expectEqual(0, set.capacity());
    try expect(meta.alignment.check(@intFromPtr(set.ptr)));

    // The sparse index owns storage independently of the dense data buffer.
    try set.sparse_to_dense.ensureTotalCapacity(allocator, 4);
}

test "init does not allocate dense storage for a zero-sized type" {
    const allocator = std.testing.allocator;
    const Tag = struct {};

    var set = try init(allocator, TypeMeta.of(Tag));
    defer set.deinit();

    try expectEqual(0, set.len());
    try expectEqual(0, set.capacity());
}

test "deinit destroys live managed components and frees the dense buffer" {
    const allocator = std.testing.allocator;

    const Managed = struct {
        calls: *usize,

        pub fn deinit(self: *@This()) void {
            self.calls.* += 1;
        }
    };

    const meta = TypeMeta.of(Managed);
    var calls: usize = 0;

    var set = try init(allocator, meta);
    // Grow the dense arrays the way `reserve` will: reserve the arrays first,
    // then size the data buffer to the resulting dense capacity.
    try set.sparse_to_dense.ensureTotalCapacity(allocator, 3);
    try set.entity_ids.ensureTotalCapacity(allocator, 3);
    const buffer = try AlignedBuffer.init(
        allocator,
        set.capacity() * meta.size,
        meta.alignment,
    );
    set.ptr = buffer.ptr;

    set.entity_ids.items.len = 3;
    for (0..set.len()) |index| {
        const value: *Managed = @ptrCast(@alignCast(set.ptr + index * meta.size));
        value.* = .{ .calls = &calls };
    }

    set.deinit();
    try expectEqual(3, calls);
}
