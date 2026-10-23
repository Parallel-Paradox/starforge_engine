//! A contiguous chunk of memory holding the component data for a set of entities.

const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const archetype = engine.ecs.entity.archetype;
const AlignedBuffer = engine.base.AlignedBuffer;
const Layout = archetype.ChunkLayout;
const Meta = archetype.Meta;

/// The metadata describing the archetype of this chunk, including its columns and their types.
meta: *const Meta,
/// The layout of the chunk's buffer, including offsets and sizes of component columns.
layout: *const Layout,
ptr: [*]u8,
/// The number of valid entities in this chunk.
len: usize = 0,

/// Allocates the chunk's buffer. Free it with `deinit`.
pub fn init(
    allocator: Allocator,
    meta: *const Meta,
    layout: *const Layout,
) Allocator.Error!@This() {
    const buffer = try AlignedBuffer.init(allocator, layout.size, layout.alignment);
    return .{
        .meta = meta,
        .layout = layout,
        // Zero-sized layouts are never allocated; use a non-null, aligned sentinel.
        .ptr = buffer.ptr orelse @ptrFromInt(layout.alignment.toByteUnits()),
    };
}

/// Frees the chunk's buffer and clears its entity count.
pub fn deinit(self: *@This(), allocator: Allocator) void {
    var buffer: AlignedBuffer = .{
        .ptr = if (self.layout.size == 0) null else self.ptr,
        .len = self.layout.size,
        .alignment = self.layout.alignment,
    };
    buffer.deinit(allocator);
    self.len = 0;
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const CompRegistry = engine.ecs.component.Registry;
const CompMark = engine.ecs.component.Mark;

const Wide = struct {
    pub const se_component: CompMark = .{};
    value: u64,
};

test "init allocates the layout buffer and deinit frees it" {
    const allocator = std.testing.allocator;

    var registry = CompRegistry.init(allocator);
    defer registry.deinit();
    const wide = try registry.register(Wide);

    var meta = try Meta.init(allocator, &.{wide}, registry);
    defer meta.deinit(allocator);
    var layout = try Layout.initWithCapacity(allocator, meta, 3);
    defer layout.deinit(allocator);

    var chunk = try init(allocator, &meta, &layout);
    defer chunk.deinit(allocator);

    try expect(chunk.meta == &meta);
    try expect(chunk.layout == &layout);
    try expectEqual(@as(usize, 0), chunk.len);
    try expect(layout.alignment.check(@intFromPtr(chunk.ptr)));

    // The whole layout, including tail padding, is writable.
    @memset(chunk.ptr[0..layout.size], 0xAB);
    for (chunk.ptr[0..layout.size]) |byte| try expectEqual(@as(u8, 0xAB), byte);
}

test "init does not allocate a zero-sized layout" {
    const allocator = std.testing.allocator;

    var registry = CompRegistry.init(allocator);
    defer registry.deinit();
    var meta = try Meta.init(allocator, &.{}, registry);
    defer meta.deinit(allocator);
    var layout = try Layout.initWithCapacity(allocator, meta, 8);
    defer layout.deinit(allocator);

    var chunk = try init(allocator, &meta, &layout);
    defer chunk.deinit(allocator);

    try expectEqual(@as(usize, 0), layout.size);
    try expectEqual(@as(usize, 0), chunk.len);
    try expect(layout.alignment.check(@intFromPtr(chunk.ptr)));
}
