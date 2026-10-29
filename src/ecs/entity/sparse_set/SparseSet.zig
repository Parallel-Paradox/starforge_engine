const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const AlignedBuffer = engine.base.AlignedBuffer;
const NonMax = engine.base.niche.NonMax;
const TypeMeta = engine.reflect.TypeMeta;
const TypeId = engine.reflect.TypeId;
const EntityId = engine.ecs.entity.Id;
const Iter = engine.ecs.entity.sparse_set.Iter;

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

/// Returns an iterator over the live entities, in dense storage order.
pub fn iter(self: *@This()) Iter {
    return .{ .set = self };
}

/// Returns the bytes of the value stored for `id`, or null if the set lacks it.
pub fn getBytes(self: @This(), id: EntityId) ?[]u8 {
    const row = self.denseIndex(id) orelse return null;
    return (self.ptr + row * self.meta.size)[0..self.meta.size];
}

/// Returns the typed value stored for `id`, or null if the set lacks it.
pub fn get(self: @This(), comptime T: type, id: EntityId) ?*T {
    std.debug.assert(self.meta.id.eql(TypeId.of(T)));
    const bytes = self.getBytes(id) orelse return null;
    return @ptrCast(@alignCast(bytes.ptr));
}

/// Returns the dense row holding `id`, or null if the set lacks it.
fn denseIndex(self: @This(), id: EntityId) ?usize {
    const index = id.index.tryGet() orelse return null;
    if (index >= self.sparse_to_dense.items.len) return null;

    const dense = self.sparse_to_dense.items[index].tryGet() orelse return null;
    const row: usize = @intCast(dense);
    if (row >= self.len()) return null;
    if (!self.entity_ids.items[row].eql(id)) return null;
    return row;
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

/// Creates an empty sparse set with room for at least `requested` entities.
pub fn initWithCapacity(
    allocator: Allocator,
    meta: TypeMeta,
    requested: usize,
) Allocator.Error!@This() {
    var self = try init(allocator, meta);
    errdefer self.deinit();

    try self.reserve(requested);
    return self;
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

    const dense_size = self.capacity() * self.meta.size;
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

/// Ensures the dense buffer can hold at least `additional` more elements beyond
/// `self.len()`, growing the allocation by doubling if needed.
pub fn reserve(self: *@This(), additional: usize) Allocator.Error!void {
    const required = std.math.add(usize, self.len(), additional) catch
        return error.OutOfMemory;
    const old_capacity = self.capacity();
    if (required <= old_capacity) return;

    var new_capacity = if (old_capacity == 0) required else old_capacity;
    while (new_capacity < required) new_capacity = new_capacity *| 2;

    const old_size = old_capacity * self.meta.size;
    const live_size = self.len() * self.meta.size;
    const new_size = std.math.mul(usize, new_capacity, self.meta.size) catch
        return error.OutOfMemory;

    const allocator = self.allocator;
    var new_buffer = try AlignedBuffer.init(allocator, new_size, self.meta.alignment);
    errdefer new_buffer.deinit(allocator);

    // Values move with their bytes and are not destroyed during relocation.
    if (live_size != 0) @memcpy(new_buffer.ptr[0..live_size], self.ptr[0..live_size]);

    // Grow the ids to exactly the capacity covered by the new buffer, so
    // `capacity()` and the allocation length stay in sync.
    try self.entity_ids.ensureTotalCapacityPrecise(allocator, new_capacity);

    var old_buffer: AlignedBuffer = if (old_size == 0)
        .empty(self.meta.alignment)
    else
        .{ .ptr = self.ptr, .len = old_size, .alignment = self.meta.alignment };
    old_buffer.deinit(allocator);

    self.ptr = new_buffer.ptr;
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

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

test "initWithCapacity reserves an aligned dense buffer" {
    const allocator = std.testing.allocator;
    const meta = TypeMeta.of(u64);

    var set = try initWithCapacity(allocator, meta, 3);
    defer set.deinit();

    try expectEqual(0, set.len());
    try expectEqual(3, set.capacity());
    try expect(meta.alignment.check(@intFromPtr(set.ptr)));

    // The whole reserved range is writable.
    const bytes = set.capacity() * meta.size;
    @memset(set.ptr[0..bytes], 0xAB);
    for (set.ptr[0..bytes]) |byte| try expectEqual(0xAB, byte);
}

test "reserve doubles capacity, preserves values, and skips needless growth" {
    const allocator = std.testing.allocator;
    const meta = TypeMeta.of(u32);

    var set = try initWithCapacity(allocator, meta, 2);
    defer set.deinit();

    set.entity_ids.appendAssumeCapacity(EntityId.init(0, 1));
    set.entity_ids.appendAssumeCapacity(EntityId.init(1, 1));

    const old_ptr = set.ptr;
    const values: [*]u32 = @ptrCast(@alignCast(set.ptr));
    values[0] = 7;
    values[1] = 9;

    try set.reserve(1);

    try expectEqual(4, set.capacity());
    try expectEqual(2, set.len());
    try expect(set.ptr != old_ptr);
    const grown: [*]u32 = @ptrCast(@alignCast(set.ptr));
    try expectEqualSlices(u32, &[_]u32{ 7, 9 }, grown[0..2]);

    // One more element still fits in the doubled capacity; no reallocation.
    const grown_ptr = set.ptr;
    try set.reserve(1);
    try expectEqual(4, set.capacity());
    try expectEqual(grown_ptr, set.ptr);
}

test "reserve relocates managed values and deinit destroys every live value" {
    const allocator = std.testing.allocator;

    const Managed = struct {
        calls: *usize,

        pub fn deinit(self: *@This()) void {
            self.calls.* += 1;
        }
    };

    const meta = TypeMeta.of(Managed);
    var calls: usize = 0;

    {
        var set = try initWithCapacity(allocator, meta, 1);
        defer set.deinit();

        set.entity_ids.appendAssumeCapacity(EntityId.init(0, 1));
        const first: *Managed = @ptrCast(@alignCast(set.ptr));
        first.* = .{ .calls = &calls };

        try set.reserve(1);
        try expectEqual(2, set.capacity());

        // The old buffer was released without destroying the moved value.
        try expectEqual(0, calls);
        const moved: *Managed = @ptrCast(@alignCast(set.ptr));
        try expectEqual(&calls, moved.calls);

        set.entity_ids.appendAssumeCapacity(EntityId.init(1, 1));
        const second: *Managed = @ptrCast(@alignCast(set.ptr + meta.size));
        second.* = .{ .calls = &calls };
    }

    // deinit destroys both the relocated value and the later one.
    try expectEqual(2, calls);
}

test "initWithCapacity grows zero-sized types without a dense allocation" {
    const allocator = std.testing.allocator;
    const Tag = struct {};

    const meta = TypeMeta.of(Tag);
    var set = try initWithCapacity(allocator, meta, 4);
    defer set.deinit();

    try expectEqual(0, set.len());
    try expectEqual(4, set.capacity());
    try expect(meta.alignment.check(@intFromPtr(set.ptr)));

    for (0..4) |index| {
        set.entity_ids.appendAssumeCapacity(EntityId.init(@intCast(index), 1));
    }
    try set.reserve(1);

    try expectEqual(8, set.capacity());
    try expectEqual(4, set.len());
    try expect(meta.alignment.check(@intFromPtr(set.ptr)));
}

test "get returns the value for an entity and null when absent" {
    const allocator = std.testing.allocator;

    var set = try initWithCapacity(allocator, TypeMeta.of(u32), 2);
    defer set.deinit();

    try set.sparse_to_dense.ensureTotalCapacity(allocator, 2);
    set.sparse_to_dense.appendAssumeCapacity(.from(0));
    set.sparse_to_dense.appendAssumeCapacity(.invalid);

    set.entity_ids.appendAssumeCapacity(EntityId.init(0, 1));
    set.entity_ids.appendAssumeCapacity(EntityId.init(1, 1));

    const values: [*]u32 = @ptrCast(@alignCast(set.ptr));
    values[0] = 7;

    try expectEqual(7, set.get(u32, EntityId.init(0, 1)).?.*);

    const bytes = set.getBytes(EntityId.init(0, 1)).?;
    try expectEqual(@as(usize, @sizeOf(u32)), bytes.len);
    try expectEqual(7, @as(*u32, @ptrCast(@alignCast(bytes.ptr))).*);

    // An unwritten dense entry, a stale generation, and an out-of-range index are absent.
    try expect(set.get(u32, EntityId.init(1, 1)) == null);
    try expect(set.get(u32, EntityId.init(0, 2)) == null);
    try expect(set.get(u32, EntityId.init(2, 1)) == null);
    try expect(set.getBytes(EntityId.init(1, 1)) == null);
}
