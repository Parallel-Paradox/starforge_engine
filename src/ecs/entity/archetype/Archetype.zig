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

/// Total number of entities all chunks can hold, saturating at `usize`'s maximum.
pub fn capacity(self: @This()) usize {
    return self.layout.capacity * self.chunks.items.len;
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

/// Returns an iterator over the live entities, in the order they were added.
pub fn iter(self: *@This()) Iter {
    return .{ .archetype = self };
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
