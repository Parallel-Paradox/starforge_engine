//! A family of chunks sharing one `meta` and one `layout`, storing entities of the same
//! component set in contiguous buffers.
//!
//! Entities are spread across chunks; capacity grows on demand by doubling the first
//! chunk or appending new chunks, see `reserve`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const ecs = engine.ecs;
const CompId = ecs.component.Id;
const CompRegistry = ecs.component.Registry;
const EntityId = ecs.entity.Id;

const TypeId = engine.reflect.TypeId;

const archetype = ecs.entity.archetype;
const Meta = archetype.Meta;
const Layout = archetype.ChunkLayout;
const Chunk = archetype.Chunk;
const Iter = archetype.Iter;

/// The metadata describing the component columns shared by every chunk.
meta: *Meta,
/// The layout of a single chunk, which is shared by every chunk.
layout: *Layout,
chunks: std.ArrayList(Chunk) = .empty,
ids: std.ArrayList(EntityId) = .empty,
allocator: Allocator,

/// Creates an empty archetype backed by a single chunk whose layout holds exactly
/// one entity; the chunk grows on demand via `reserve`.
///
/// # Errors
///
/// Returns `BufferTooLarge` if a single entity's bytes (all columns) exceed `max_size_byte`.
pub fn init(
    allocator: Allocator,
    unsorted: []const CompId,
    registry: CompRegistry,
) (Allocator.Error || Layout.Error)!@This() {
    const meta = try allocator.create(Meta);
    errdefer allocator.destroy(meta);
    meta.* = try Meta.init(allocator, unsorted, registry);
    errdefer meta.deinit(allocator);

    const layout = try allocator.create(Layout);
    errdefer allocator.destroy(layout);
    layout.* = try Layout.initWithCapacity(allocator, meta.*, 1);
    errdefer layout.deinit(allocator);

    var chunks: std.ArrayList(Chunk) = .empty;
    errdefer chunks.deinit(allocator);
    try chunks.ensureTotalCapacity(allocator, 1);
    chunks.appendAssumeCapacity(try Chunk.init(allocator, meta, layout));

    return .{
        .meta = meta,
        .layout = layout,
        .chunks = chunks,
        .ids = .empty,
        .allocator = allocator,
    };
}

pub fn deinit(self: *@This()) void {
    const allocator = self.allocator;
    for (self.chunks.items) |*chunk| chunk.deinit(allocator);
    self.chunks.deinit(allocator);
    self.ids.deinit(allocator);
    self.layout.deinit(allocator);
    allocator.destroy(self.layout);
    self.meta.deinit(allocator);
    allocator.destroy(self.meta);
}

/// Number of live entities across all chunks.
pub fn len(self: @This()) usize {
    return self.ids.items.len;
}

/// Number of entity slots backed by both component storage and id storage.
pub fn capacity(self: @This()) usize {
    return @min(self.layout.capacity * self.chunks.items.len, self.ids.capacity);
}

/// Appends an entity id and returns its uninitialized row without allocating.
/// Call `reserve` first to ensure both row and id capacity.
///
/// The row is immediately live. The caller must initialize every column before
/// reading it or running destructors, and must not leave it partially initialized
/// on an error path. No component constructors or destructors are called.
pub fn appendUninitAssumeCapacity(self: *@This(), id: EntityId) usize {
    const row = self.len();
    std.debug.assert(row < self.capacity());
    const chunk = &self.chunks.items[row / self.layout.capacity];
    std.debug.assert(chunk.len == row % self.layout.capacity);

    self.ids.appendAssumeCapacity(id);
    chunk.len += 1;
    return row;
}

/// Returns the component storage for `row` in `column` and the row's entity id.
pub fn at(self: @This(), column: usize, row: usize) struct { data: []u8, id: EntityId } {
    std.debug.assert(column < self.meta.columns.items.len);
    std.debug.assert(row < self.len());

    const chunk_index = row / self.layout.capacity;
    const row_in_chunk = row % self.layout.capacity;
    const chunk = self.chunks.items[chunk_index];
    const column_meta = self.meta.columns.items[column].meta;
    const offset = self.layout.column_offsets.items[column] + row_in_chunk * column_meta.size;

    return .{
        .data = (chunk.ptr + offset)[0..column_meta.size],
        .id = self.ids.items[row],
    };
}

/// Returns the typed component value for `row` in `column` and the row's entity id.
///
/// Asserts that `T` is the component type stored in `column`.
pub fn typedAt(self: @This(), T: type, column: usize, row: usize) struct { ptr: *T, id: EntityId } {
    const result = self.at(column, row);
    std.debug.assert(self.meta.columns.items[column].meta.id.eql(TypeId.of(T)));
    return .{
        .ptr = @ptrCast(@alignCast(result.data.ptr)),
        .id = result.id,
    };
}

/// Destroys `row` and fills its slot with the last entity without destroying
/// the moved values. Returns that entity's id, or null if `row` was last.
/// Retains all chunks and their buffers. Asserts that `row` is live.
pub fn swapRemove(self: *@This(), row: usize) ?EntityId {
    std.debug.assert(row < self.len());
    const per_chunk = self.layout.capacity;
    const removed_chunk = &self.chunks.items[row / per_chunk];

    for (self.meta.columns.items, self.layout.column_offsets.items) |column, offset| {
        const removed_ptr = removed_chunk.ptr + offset + (row % per_chunk) * column.meta.size;
        switch (column.meta.need_deinit) {
            .trivial => {},
            .managed => |deinit_fn| deinit_fn(@ptrCast(removed_ptr)),
        }
    }
    return self.swapRemoveWithoutDeinit(row);
}

/// Removes `row` without destroying its components, filling its slot with the
/// last entity. Returns that entity's id, or null if `row` was last.
///
/// The caller must first transfer ownership or destroy every component in `row`.
/// The old last row's bytes cease to own values after the move. Retains all
/// capacity, allocates nothing, and asserts that `row` is live.
pub fn swapRemoveWithoutDeinit(self: *@This(), row: usize) ?EntityId {
    std.debug.assert(row < self.len());
    const last = self.len() - 1;
    const per_chunk = self.layout.capacity;
    const last_chunk = &self.chunks.items[last / per_chunk];

    if (row != last) {
        const removed_chunk = &self.chunks.items[row / per_chunk];
        for (self.meta.columns.items, self.layout.column_offsets.items) |column, offset| {
            if (column.meta.size == 0) continue;
            const removed_ptr = removed_chunk.ptr + offset + (row % per_chunk) * column.meta.size;
            const last_ptr = last_chunk.ptr + offset + (last % per_chunk) * column.meta.size;
            @memcpy(removed_ptr[0..column.meta.size], last_ptr[0..column.meta.size]);
        }
    }

    const moved = if (row != last) self.ids.items[last] else null;
    _ = self.ids.swapRemove(row);
    last_chunk.len -= 1;
    return moved;
}

/// Returns an iterator over the live entities, in dense storage order.
pub fn iter(self: *@This()) Iter {
    return .{ .archetype = self };
}

/// Returns an iterator positioned at the first unused slot, for `nextStorage`.
/// Reserve capacity before iterating. Publish initialized slots with `commitRows`.
pub fn iterUnused(self: *@This()) Iter {
    const row = self.len();
    return .{
        .archetype = self,
        .row = row,
        .chunk_index = row / self.layout.capacity,
        .row_in_chunk = row % self.layout.capacity,
    };
}

/// Reserves capacity for at least `additional` more entities.
///
/// While only the first chunk exists, its buffer size is doubled (capped at the
/// maximum buffer size); once the first chunk can no longer grow, new chunks sharing
/// its layout are appended until the requested capacity is covered.
pub fn reserve(self: *@This(), additional: usize) Allocator.Error!void {
    const required = self.len() + additional;
    try self.ids.ensureTotalCapacity(self.allocator, required);

    var cap = self.capacity();
    if (cap >= required) return;

    // A single chunk may grow, doubling until it fits or reaches the buffer
    // limit. Once it cannot grow any further, new chunks take over.
    if (self.chunks.items.len == 1) {
        if (try self.growFirstChunk(additional)) return;
        cap = self.capacity();
    }

    const per_chunk = self.layout.capacity;
    std.debug.assert(per_chunk > 0);

    // Round up without overflowing on a `missing + per_chunk - 1` sum.
    const missing = required - cap;
    const new_chunks = missing / per_chunk + @intFromBool(missing % per_chunk != 0);

    const allocator = self.allocator;
    try self.chunks.ensureUnusedCapacity(allocator, new_chunks);
    for (0..new_chunks) |_| {
        const chunk = try Chunk.init(allocator, self.meta, self.layout);
        self.chunks.appendAssumeCapacity(chunk);
    }
}

/// Returns `true` if the grown chunk alone has enough room; `false` if the maximum
/// buffer size was reached first and the caller must append more chunks.
fn growFirstChunk(self: *@This(), additional: usize) Allocator.Error!bool {
    const required = self.len() + additional;
    if (self.layout.capacity >= required) return true;

    const allocator = self.allocator;

    var cap = self.layout.capacity;
    var size = self.layout.size;
    var grew = false;

    // Reset one scratch layout in place for each attempt so its `column_offsets`
    // allocation is reused instead of initializing a new layout every time.
    var new_layout: Layout = .{
        .capacity = 0,
        .size = 0,
        .alignment = self.meta.alignment(),
        .column_offsets = .empty,
    };
    var owns_new_layout = true;
    defer if (owns_new_layout) new_layout.deinit(allocator);

    while (cap < required) {
        if (size * 2 < Layout.max_size_byte) {
            new_layout.resetCapacity(
                allocator,
                self.meta.*,
                cap * 2,
            ) catch |err| switch (err) {
                error.BufferTooLarge => unreachable, // Branch condition guarantees this fits.
                else => |e| return e,
            };
        } else {
            // Drop the tail slack and make every maximum-sized chunk 16 KB.
            new_layout.resetSize(
                allocator,
                self.meta.*,
                Layout.max_size_byte,
            ) catch |err| switch (err) {
                error.BufferTooLarge => unreachable, // Branch condition guarantees this fits.
                else => |e| return e,
            };
        }

        if (new_layout.capacity <= cap) break;
        cap = new_layout.capacity;
        size = new_layout.size;
        grew = true;
    }

    const fits = cap >= required;
    if (!grew) return fits;

    var new_chunk = try Chunk.init(allocator, self.meta, &new_layout);
    errdefer new_chunk.deinit(allocator);

    // Column arrays are stored separately, so each live column range can be
    // copied independently into the corresponding array of the new buffer.
    const old_chunk = &self.chunks.items[0];
    for (
        self.meta.columns.items,
        old_chunk.layout.column_offsets.items,
        new_chunk.layout.column_offsets.items,
    ) |column, old_offset, new_offset| {
        const bytes = column.meta.size * old_chunk.len;
        if (bytes == 0) continue;
        @memcpy(
            new_chunk.ptr[new_offset..][0..bytes],
            old_chunk.ptr[old_offset..][0..bytes],
        );
    }
    const old_len = old_chunk.len;

    // The live values now belong to the new chunk, so release the old buffer
    // without running their deinit a second time.
    old_chunk.len = 0;
    old_chunk.deinit(allocator);
    self.layout.deinit(allocator);
    self.layout.* = new_layout;
    owns_new_layout = false;
    new_chunk.layout = self.layout;
    new_chunk.len = old_len;
    self.chunks.items[0] = new_chunk;

    return fits;
}

/// Copies ids into the first unused rows without publishing them.
///
/// # Unsafe
///
/// Reserve capacity first, then initialize all columns before `commitRows`.
/// The source must not overlap the destination.
pub fn stageEntities(self: *@This(), entities: []const EntityId) void {
    const row = self.len();
    std.debug.assert(entities.len <= self.capacity() - row);
    @memcpy(self.ids.allocatedSlice()[row..][0..entities.len], entities);
}

/// Copies packed component values into a column's first unused rows.
/// Managed values remain caller-owned until their rows are published.
///
/// # Unsafe
///
/// Reserve capacity first. Bytes must contain whole values and must not overlap
/// the destination.
pub fn stageColumn(self: *@This(), column: usize, bytes: []const u8) void {
    std.debug.assert(column < self.meta.columns.items.len);
    const size = self.meta.columns.items[column].meta.size;
    if (size == 0) {
        std.debug.assert(bytes.len == 0);
        return;
    }

    const start = self.len();
    std.debug.assert(bytes.len % size == 0);
    std.debug.assert(bytes.len / size <= self.capacity() - start);

    const offset = self.layout.column_offsets.items[column];
    var row = start;
    var remaining = bytes;
    while (remaining.len != 0) {
        const chunk = &self.chunks.items[row / self.layout.capacity];
        const row_in_chunk = row % self.layout.capacity;
        const count = @min(remaining.len / size, self.layout.capacity - row_in_chunk);
        const byte_count = count * size;
        const dest = chunk.ptr + offset + row_in_chunk * size;
        @memcpy(dest[0..byte_count], remaining[0..byte_count]);
        row += count;
        remaining = remaining[byte_count..];
    }
}

/// Publishes `added` rows.
///
/// # Unsafe
///
/// The caller must initialize every ID and column in the `added` unused slots
/// before calling.
pub fn commitRows(self: *@This(), added: usize) void {
    var row = self.len();
    std.debug.assert(added <= self.capacity() - row);
    var remaining = added;
    while (remaining != 0) {
        const chunk = &self.chunks.items[row / self.layout.capacity];
        const row_in_chunk = row % self.layout.capacity;
        std.debug.assert(chunk.len == row_in_chunk);
        const count = @min(remaining, self.layout.capacity - row_in_chunk);
        chunk.len += count;
        row += count;
        remaining -= count;
    }
    self.ids.items.len = row;
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const CompMark = ecs.component.Mark;

const Wide = struct {
    pub const se_component: CompMark = .{};
    value: u64,
};

test "init creates metadata, a one-entity layout and one chunk" {
    const allocator = std.testing.allocator;

    var registry = CompRegistry.init(allocator);
    defer registry.deinit();
    const wide = try registry.register(Wide);

    var arch = try init(allocator, &.{wide}, registry);
    defer arch.deinit();

    try expectEqual(1, arch.meta.columns.items.len);
    try expectEqual(1, arch.layout.capacity);
    try expectEqual(1, arch.chunks.items.len);
    try expectEqual(0, arch.ids.items.len);

    const chunk = arch.chunks.items[0];
    try expectEqual(chunk.meta, arch.meta);
    try expectEqual(chunk.layout, arch.layout);
    try expectEqual(0, chunk.len);
    try expect(arch.layout.alignment.check(@intFromPtr(chunk.ptr)));
}

test "init of no components creates an empty chunk" {
    const allocator = std.testing.allocator;

    var registry = CompRegistry.init(allocator);
    defer registry.deinit();

    var arch = try init(allocator, &.{}, registry);
    defer arch.deinit();

    try expectEqual(0, arch.meta.columns.items.len);
    try expectEqual(1, arch.layout.capacity);
    try expectEqual(0, arch.layout.size);
    try expectEqual(1, arch.chunks.items.len);
    try expectEqual(0, arch.chunks.items[0].len);
}

test "reserve grows the first chunk by doubling" {
    const allocator = std.testing.allocator;

    var registry = CompRegistry.init(allocator);
    defer registry.deinit();
    const wide = try registry.register(Wide);

    var arch = try init(allocator, &.{wide}, registry);
    defer arch.deinit();

    // One entity already fits in the initial chunk.
    try arch.reserve(1);
    try expectEqual(1, arch.layout.capacity);
    try expectEqual(1, arch.chunks.items.len);
    try expect(arch.ids.capacity >= 1);

    try arch.reserve(2);
    try expectEqual(2, arch.layout.capacity);
    try expectEqual(1, arch.chunks.items.len);
    try expect(arch.ids.capacity >= 2);

    // The capacity keeps doubling until it covers the request.
    try arch.reserve(3);
    try expectEqual(4, arch.layout.capacity);
    try expectEqual(1, arch.chunks.items.len);
    try expect(arch.ids.capacity >= 4);

    const chunk = arch.chunks.items[0];
    try expectEqual(chunk.layout, arch.layout);
    try expect(arch.layout.alignment.check(@intFromPtr(chunk.ptr)));
}

test "reserve moves the live data into the grown chunk" {
    const allocator = std.testing.allocator;

    const Narrow = struct {
        pub const se_component: CompMark = .{};
        value: u32,
    };

    var registry = CompRegistry.init(allocator);
    defer registry.deinit();
    const wide = try registry.register(Wide);
    const narrow = try registry.register(Narrow);

    var arch = try init(allocator, &.{ narrow, wide }, registry);
    defer arch.deinit();

    try arch.ids.append(allocator, EntityId.init(0, 1));
    arch.chunks.items[0].len = 1;

    // Columns are sorted by alignment, so `Wide` comes before `Narrow`.
    const wide_ptr = arch.typedAt(Wide, 0, 0).ptr;
    const narrow_ptr = arch.typedAt(Narrow, 1, 0).ptr;
    wide_ptr.* = .{ .value = 0xDEADBEEF };
    narrow_ptr.* = .{ .value = 0x1234 };

    try arch.reserve(7);
    try expectEqual(8, arch.layout.capacity);
    try expectEqual(1, arch.chunks.items.len);

    const grown = &arch.chunks.items[0];
    try expectEqual(grown.layout, arch.layout);
    try expectEqual(1, grown.len);
    try expectEqual(1, arch.len());

    const moved_wide = arch.typedAt(Wide, 0, 0).ptr;
    const moved_narrow = arch.typedAt(Narrow, 1, 0).ptr;
    try expectEqual(0xDEADBEEF, moved_wide.value);
    try expectEqual(0x1234, moved_narrow.value);
}

test "reserve appends chunks once the first chunk reaches the buffer limit" {
    const allocator = std.testing.allocator;

    var registry = CompRegistry.init(allocator);
    defer registry.deinit();
    const wide = try registry.register(Wide);

    var arch = try init(allocator, &.{wide}, registry);
    defer arch.deinit();

    // A 16 KB buffer holds 2048 eight-byte entities; the next chunk covers the rest.
    try arch.reserve(2049);
    try expectEqual(2048, arch.layout.capacity);
    try expectEqual(Layout.max_size_byte, arch.layout.size);
    try expectEqual(2, arch.chunks.items.len);
    for (arch.chunks.items) |chunk| {
        try expectEqual(chunk.layout, arch.layout);
        try expectEqual(0, chunk.len);
        try expect(arch.layout.alignment.check(@intFromPtr(chunk.ptr)));
    }

    // Existing chunks already cover the request.
    try arch.reserve(4096);
    try expectEqual(2, arch.chunks.items.len);

    try arch.reserve(4097);
    try expectEqual(3, arch.chunks.items.len);
}

test "reserve caps the first chunk at the largest capacity that fits" {
    const allocator = std.testing.allocator;

    const Twelve = struct {
        pub const se_component: CompMark = .{};
        bytes: [12]u8,
    };

    var registry = CompRegistry.init(allocator);
    defer registry.deinit();
    const twelve = try registry.register(Twelve);

    var arch = try init(allocator, &.{twelve}, registry);
    defer arch.deinit();

    // 16384 / 12 = 1365, which is not a power of two.
    try arch.reserve(1300);
    try expectEqual(1365, arch.layout.capacity);
    try expectEqual(Layout.max_size_byte, arch.layout.size);
    try expectEqual(1, arch.chunks.items.len);

    // The first chunk cannot grow past 1365, so one more chunk is appended.
    try arch.reserve(1366);
    try expectEqual(1365, arch.layout.capacity);
    try expectEqual(2, arch.chunks.items.len);
}

test "reserve grows a zero-sized layout without allocating a buffer" {
    const allocator = std.testing.allocator;

    var registry = CompRegistry.init(allocator);
    defer registry.deinit();

    var arch = try init(allocator, &.{}, registry);
    defer arch.deinit();

    try arch.reserve(5);
    try expectEqual(8, arch.layout.capacity);
    try expectEqual(0, arch.layout.size);
    try expectEqual(1, arch.chunks.items.len);
    try expect(arch.layout.alignment.check(@intFromPtr(arch.chunks.items[0].ptr)));
}

test "growing relocates managed values without running their deinit" {
    const allocator = std.testing.allocator;

    const Managed = struct {
        pub const se_component: CompMark = .{};
        calls: *usize,

        pub fn deinit(self: *@This()) void {
            self.calls.* += 1;
        }
    };

    var registry = CompRegistry.init(allocator);
    defer registry.deinit();
    const managed = try registry.register(Managed);

    var calls: usize = 0;
    {
        var arch = try init(allocator, &.{managed}, registry);
        defer arch.deinit();

        try arch.ids.append(allocator, EntityId.init(0, 1));
        arch.chunks.items[0].len = 1;
        const value = arch.typedAt(Managed, 0, 0).ptr;
        value.* = .{ .calls = &calls };

        try arch.reserve(1);
        try expectEqual(2, arch.layout.capacity);
        try expectEqual(1, arch.chunks.items[0].len);

        // The old chunk was released without destroying the moved value.
        try expectEqual(0, calls);
        const moved = arch.typedAt(Managed, 0, 0).ptr;
        try expectEqual(moved.calls, &calls);
    }

    // The final chunk still owns the value and destroys it exactly once.
    try expectEqual(1, calls);
}

test "at locates a column value and id across chunks" {
    const allocator = std.testing.allocator;

    const Half = struct {
        pub const se_component: CompMark = .{};
        bytes: [Layout.max_size_byte / 2]u8,
    };

    var registry = CompRegistry.init(allocator);
    defer registry.deinit();
    const half = try registry.register(Half);

    var arch = try init(allocator, &.{half}, registry);
    defer arch.deinit();

    // Each chunk holds two entities, so row 2 starts the second chunk.
    try arch.reserve(3);
    try expectEqual(2, arch.layout.capacity);
    try expectEqual(2, arch.chunks.items.len);

    for (0..3) |index| {
        try arch.ids.append(allocator, EntityId.init(@intCast(index), 1));
    }
    arch.chunks.items[0].len = 2;
    arch.chunks.items[1].len = 1;

    const first = arch.at(0, 0);
    const second = arch.at(0, 1);
    const third = arch.at(0, 2);

    try expect(first.id.eql(EntityId.init(0, 1)));
    try expect(second.id.eql(EntityId.init(1, 1)));
    try expect(third.id.eql(EntityId.init(2, 1)));
    try expectEqual(@sizeOf(Half), first.data.len);
    try expectEqual(@sizeOf(Half), third.data.len);

    try expectEqual(arch.chunks.items[0].ptr, first.data.ptr);
    try expectEqual(arch.chunks.items[0].ptr + @sizeOf(Half), second.data.ptr);
    try expectEqual(arch.chunks.items[1].ptr, third.data.ptr);

    @memset(first.data, 0xAA);
    @memset(second.data, 0xCC);
    @memset(third.data, 0xBB);
    try expectEqual(0xAA, arch.chunks.items[0].ptr[0]);
    try expectEqual(0xCC, arch.chunks.items[0].ptr[@sizeOf(Half)]);
    try expectEqual(0xBB, arch.chunks.items[1].ptr[0]);
}

test "swapRemove moves every column and retains storage through the last removal" {
    const allocator = std.testing.allocator;
    const Narrow = struct {
        pub const se_component: CompMark = .{};
        value: u32,
    };

    var registry = CompRegistry.init(allocator);
    defer registry.deinit();
    const wide = try registry.register(Wide);
    const narrow = try registry.register(Narrow);
    var arch = try init(allocator, &.{ wide, narrow }, registry);
    defer arch.deinit();
    try arch.reserve(3);

    for (0..3) |index| {
        arch.ids.appendAssumeCapacity(EntityId.init(@intCast(index), 7));
        arch.typedAt(Wide, 0, index).ptr.* = .{ .value = 10 + index };
        arch.typedAt(Narrow, 1, index).ptr.* = .{ .value = @intCast(20 + index) };
        arch.chunks.items[0].len += 1;
    }
    const old_capacity = arch.capacity();
    const old_ids_capacity = arch.ids.capacity;
    const old_ptr = arch.chunks.items[0].ptr;

    try expect(arch.swapRemove(1).?.eql(EntityId.init(2, 7)));
    try expectEqual(2, arch.len());
    try expectEqual(2, arch.chunks.items[0].len);
    try expectEqual(10, arch.typedAt(Wide, 0, 0).ptr.value);
    try expectEqual(12, arch.typedAt(Wide, 0, 1).ptr.value);
    try expectEqual(22, arch.typedAt(Narrow, 1, 1).ptr.value);
    try expect(arch.ids.items[1].eql(EntityId.init(2, 7)));

    try expect(arch.swapRemove(1) == null);
    try expectEqual(1, arch.len());
    try expect(arch.swapRemove(0) == null);
    try expectEqual(0, arch.len());
    try expectEqual(0, arch.chunks.items[0].len);
    try expectEqual(old_capacity, arch.capacity());
    try expectEqual(old_ids_capacity, arch.ids.capacity);
    try expectEqual(1, arch.chunks.items.len);
    try expectEqual(old_ptr, arch.chunks.items[0].ptr);
}

test "row removal across chunks transfers or destroys each managed component once" {
    const allocator = std.testing.allocator;
    const Large = struct {
        pub const se_component: CompMark = .{};
        calls: *usize,
        bytes: [Layout.max_size_byte / 2 - 2 * @sizeOf(*usize)]u8,

        pub fn deinit(self: *@This()) void {
            self.calls.* += 1;
        }
    };
    const Other = struct {
        pub const se_component: CompMark = .{};
        calls: *usize,

        pub fn deinit(self: *@This()) void {
            self.calls.* += 1;
        }
    };

    var registry = CompRegistry.init(allocator);
    defer registry.deinit();
    const large = try registry.register(Large);
    const other = try registry.register(Other);
    var large_calls = [_]usize{ 0, 0, 0 };
    var other_calls = [_]usize{ 0, 0, 0 };
    {
        var arch = try init(allocator, &.{ large, other }, registry);
        defer arch.deinit();
        var dest = try init(allocator, &.{other}, registry);
        defer dest.deinit();
        try dest.reserve(1);
        // Two entities fit per chunk; retain a third, entirely unused chunk too.
        try arch.reserve(5);
        try expectEqual(2, arch.layout.capacity);
        try expectEqual(3, arch.chunks.items.len);
        const large_column = arch.meta.id_to_col.get(TypeId.of(Large)).?;
        const other_column = arch.meta.id_to_col.get(TypeId.of(Other)).?;
        for ([_]usize{ 1, 0, 2 }) |count| {
            const start = arch.len();
            var ids: [2]EntityId = undefined;
            var large_values: [2]Large = undefined;
            var other_values: [2]Other = undefined;
            for (start..start + count, 0..) |index, staged| {
                ids[staged] = EntityId.init(@intCast(index), 1);
                large_values[staged].calls = &large_calls[index];
                @memset(&large_values[staged].bytes, @intCast(index + 10));
                other_values[staged] = .{ .calls = &other_calls[index] };
            }
            arch.stageEntities(ids[0..count]);
            arch.stageColumn(large_column, std.mem.sliceAsBytes(large_values[0..count]));
            arch.stageColumn(other_column, std.mem.sliceAsBytes(other_values[0..count]));
            try expectEqual(start, arch.len());
            var live_rows: usize = 0;
            for (arch.chunks.items) |chunk| live_rows += chunk.len;
            try expectEqual(start, live_rows);
            arch.commitRows(count);
            try expectEqual(start + count, arch.len());
        }
        try expectEqual(3, arch.len());
        try expectEqual(2, arch.chunks.items[0].len);
        try expectEqual(1, arch.chunks.items[1].len);
        const old_capacity = arch.capacity();
        const old_ptrs = [_][*]u8{
            arch.chunks.items[0].ptr,
            arch.chunks.items[1].ptr,
            arch.chunks.items[2].ptr,
        };

        // Keep Other in the destination and explicitly destroy the removed Large.
        const row = dest.appendUninitAssumeCapacity(arch.ids.items[0]);
        dest.typedAt(Other, 0, row).ptr.* = arch.typedAt(Other, other_column, 0).ptr.*;
        arch.typedAt(Large, large_column, 0).ptr.deinit();
        try expect(arch.swapRemoveWithoutDeinit(0).?.eql(EntityId.init(2, 1)));
        try expect(dest.ids.items[row].eql(EntityId.init(0, 1)));
        try expectEqual(&other_calls[0], dest.typedAt(Other, 0, row).ptr.calls);
        try expectEqual(2, arch.len());
        try expectEqual(2, arch.chunks.items[0].len);
        try expectEqual(0, arch.chunks.items[1].len);
        try expectEqual(0, arch.chunks.items[2].len);
        try expectEqual([_]usize{ 1, 0, 0 }, large_calls);
        try expectEqual([_]usize{ 0, 0, 0 }, other_calls);
        const moved = arch.typedAt(Large, large_column, 0);
        try expect(moved.id.eql(EntityId.init(2, 1)));
        try expectEqual(&large_calls[2], moved.ptr.calls);
        for (moved.ptr.bytes) |byte| try expectEqual(12, byte);
        try expectEqual(&other_calls[2], arch.typedAt(Other, other_column, 0).ptr.calls);

        try expect(arch.swapRemove(1) == null);
        try expectEqual(1, arch.chunks.items[0].len);
        try expectEqual([_]usize{ 1, 1, 0 }, large_calls);
        try expectEqual([_]usize{ 0, 1, 0 }, other_calls);
        try expectEqual(old_capacity, arch.capacity());
        try expectEqual(3, arch.chunks.items.len);
        for (arch.chunks.items, old_ptrs) |chunk, ptr| try expectEqual(ptr, chunk.ptr);
    }
    // Teardown owns only the moved survivor, not its old bytes in the empty chunk.
    try expectEqual([_]usize{ 1, 1, 1 }, large_calls);
    try expectEqual([_]usize{ 1, 1, 1 }, other_calls);
}

test "row operations support a component-free archetype" {
    const allocator = std.testing.allocator;
    var registry = CompRegistry.init(allocator);
    defer registry.deinit();
    var arch = try init(allocator, &.{}, registry);
    defer arch.deinit();
    try arch.reserve(2);
    try expectEqual(0, arch.appendUninitAssumeCapacity(EntityId.init(4, 1)));
    try expectEqual(1, arch.appendUninitAssumeCapacity(EntityId.init(5, 1)));
    try expectEqual(2, arch.chunks.items[0].len);

    try expect(arch.swapRemoveWithoutDeinit(0).?.eql(EntityId.init(5, 1)));
    try expect(arch.ids.items[0].eql(EntityId.init(5, 1)));
    try expectEqual(1, arch.chunks.items[0].len);
    try expect(arch.swapRemove(0) == null);
    try expectEqual(0, arch.len());
    try expectEqual(0, arch.chunks.items[0].len);
    try expectEqual(2, arch.capacity());
}

test "row removal destroys zero-sized managed values once including teardown" {
    const allocator = std.testing.allocator;
    const ManagedTag = struct {
        pub const se_component: CompMark = .{};
        var calls: usize = 0;

        pub fn deinit(_: *@This()) void {
            calls += 1;
        }
    };
    ManagedTag.calls = 0;
    try expectEqual(0, @sizeOf(ManagedTag));
    var registry = CompRegistry.init(allocator);
    defer registry.deinit();
    const tag = try registry.register(ManagedTag);
    {
        var arch = try init(allocator, &.{tag}, registry);
        defer arch.deinit();
        try arch.reserve(3);
        var ids: [3]EntityId = undefined;
        for (&ids, 0..) |*id, index| {
            id.* = EntityId.init(@intCast(index), 1);
        }
        arch.stageEntities(&ids);
        arch.stageColumn(0, &.{});
        try expectEqual(0, arch.len());
        try expectEqual(0, arch.chunks.items[0].len);
        try expectEqual(0, ManagedTag.calls);
        arch.commitRows(3);
        try expectEqual(0, arch.layout.size);
        try expectEqual(3, arch.len());
        try expectEqual(3, arch.chunks.items[0].len);

        arch.typedAt(ManagedTag, 0, 1).ptr.deinit();
        try expect(arch.swapRemoveWithoutDeinit(1).?.eql(EntityId.init(2, 1)));
        try expectEqual(1, ManagedTag.calls);
        try expectEqual(2, arch.chunks.items[0].len);
        try expect(arch.swapRemove(1) == null);
        try expectEqual(2, ManagedTag.calls);
        try expectEqual(1, arch.chunks.items[0].len);
    }
    try expectEqual(3, ManagedTag.calls);
}
