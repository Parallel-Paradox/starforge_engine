//! Computes the layout of an archetype's buffer, including the offsets of each column array.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const engine = @import("engine");
const Meta = engine.ecs.entity.archetype.Meta;

/// Number of entities (and elements per column array) the buffer can hold.
capacity: usize,
/// Total size of the buffer in bytes, including any padding.
size: usize,
/// Alignment of the buffer allocation: the first (largest-aligned) column's alignment,
/// or 1 when the archetype has no columns.
alignment: Alignment,
/// Byte offset of each column array from the start of the buffer, in `columns` order.
column_offsets: std.ArrayList(usize),

/// 16 KB
pub const max_size_byte = 16 * 1024;

pub const Error = error{
    /// The computed buffer size exceeds max_size_byte.
    BufferTooLarge,
};

/// Builds a layout sized to hold exactly `capacity` entities.
///
/// Columns are packed at the head of the buffer. The total byte size is rounded up to
/// `alignment`, so any slack appears at the tail after the last column array.
///
/// # Errors
///
/// Returns `BufferTooLarge` if the computed buffer size exceeds max_size_byte.
pub fn initWithCapacity(
    allocator: Allocator,
    meta: Meta,
    capacity: usize,
) (Allocator.Error || Error)!@This() {
    const alignment = meta.alignment();
    var self: @This() = .{
        .capacity = capacity,
        .size = 0,
        .alignment = alignment,
        .column_offsets = .empty,
    };
    errdefer self.deinit(allocator);

    try self.column_offsets.ensureTotalCapacity(allocator, meta.columns.items.len);

    var offset: usize = 0;
    for (meta.columns.items) |column| {
        // Columns are sorted by alignment descending, so the previous column's
        // size is already a multiple of this alignment and this is usually a no-op.
        offset = column.meta.alignment.forward(offset);
        if (offset > max_size_byte) return Error.BufferTooLarge;
        self.column_offsets.appendAssumeCapacity(offset);

        const column_size = std.math.mul(usize, column.meta.size, capacity) catch
            return Error.BufferTooLarge;
        offset = std.math.add(usize, offset, column_size) catch
            return Error.BufferTooLarge;
        if (offset > max_size_byte) return Error.BufferTooLarge;
    }

    // Any padding left by the column layout goes at the tail of the buffer.
    self.size = alignment.forward(offset);
    if (self.size > max_size_byte) return Error.BufferTooLarge;
    return self;
}

/// Builds a layout fitting within a `size`-byte budget, holding the largest
/// capacity that fits.
///
/// The recorded `size` keeps the requested `size` exactly. For the layout itself
/// the budget is rounded down to the buffer's alignment.
/// If the archetype has no columns, capacity is treated as unbounded and reported
/// as infinity value of usize.
///
/// # Errors
///
/// Returns `BufferTooLarge` if the computed buffer size exceeds max_size_byte.
pub fn initWithSize(
    allocator: Allocator,
    meta: Meta,
    size: usize,
) (Allocator.Error || Error)!@This() {
    if (size > max_size_byte) return Error.BufferTooLarge;

    const budget = meta.alignment().backward(size);

    // Columns are sorted by alignment descending, so their arrays can be packed
    // without padding: one entity takes exactly the sum of the column sizes.
    var element_size: usize = 0;
    var fits = true;
    for (meta.columns.items) |column| {
        const column_size = column.meta.size;
        if (column_size > budget - element_size) {
            fits = false;
            break;
        }
        element_size += column_size;
    }

    const capacity = if (!fits)
        0
    else if (element_size == 0)
        // No columns, or only zero-sized ones: any number of entities fits.
        std.math.maxInt(usize)
    else
        budget / element_size;

    var self = try initWithCapacity(allocator, meta, capacity);
    self.size = size;
    return self;
}

pub fn deinit(self: *@This(), allocator: Allocator) void {
    self.column_offsets.deinit(allocator);
}

const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;

const CompRegistry = engine.ecs.component.Registry;
const CompId = engine.ecs.component.Id;
const CompMark = engine.ecs.component.Mark;

const Wide = struct {
    pub const se_component: CompMark = .{};
    value: u64,
};

const Narrow = struct {
    pub const se_component: CompMark = .{};
    value: u32,
};

const Tag = struct {
    pub const se_component: CompMark = .{};
};

/// Builds a meta holding `Components`, in registration order.
fn testMeta(allocator: Allocator, comptime Components: []const type) !Meta {
    var registry = CompRegistry.init(allocator);
    defer registry.deinit();

    var ids: [Components.len]CompId = undefined;
    inline for (Components, 0..) |Component, i| {
        ids[i] = try registry.register(Component);
    }
    return Meta.init(allocator, &ids, registry);
}

fn expectLayout(
    layout: @This(),
    capacity: usize,
    size: usize,
    alignment: Alignment,
    offsets: []const usize,
) !void {
    try expectEqual(capacity, layout.capacity);
    try expectEqual(size, layout.size);
    try expectEqual(alignment, layout.alignment);
    try expectEqualSlices(usize, offsets, layout.column_offsets.items);
}

test "initWithCapacity packs columns and enforces the buffer limit" {
    const allocator = std.testing.allocator;

    var meta = try testMeta(allocator, &.{ Tag, Narrow, Wide });
    defer meta.deinit(allocator);

    // One entity: 8 + 4 bytes, padded to 16.
    var one = try initWithCapacity(allocator, meta, 1);
    defer one.deinit(allocator);
    try expectLayout(one, 1, 16, std.mem.Alignment.of(Wide), &.{ 0, 8, 12 });

    // The column arrays scale linearly; 10 entities need 120 bytes.
    var ten = try initWithCapacity(allocator, meta, 10);
    defer ten.deinit(allocator);
    try expectLayout(ten, 10, 120, std.mem.Alignment.of(Wide), &.{ 0, 80, 120 });

    // Zero capacity keeps the columns but gives each array a zero offset.
    var zero = try initWithCapacity(allocator, meta, 0);
    defer zero.deinit(allocator);
    try expectLayout(zero, 0, 0, std.mem.Alignment.of(Wide), &.{ 0, 0, 0 });

    // 1365 * 12 = 16380 rounds up to exactly the 16 KB limit; one more overflows.
    var full = try initWithCapacity(allocator, meta, 1365);
    defer full.deinit(allocator);
    try expectLayout(full, 1365, max_size_byte, std.mem.Alignment.of(Wide), &.{ 0, 10920, 16380 });
    try expectError(Error.BufferTooLarge, initWithCapacity(allocator, meta, 1366));

    // An archetype without columns uses no buffer space.
    var empty_meta = try testMeta(allocator, &.{});
    defer empty_meta.deinit(allocator);
    var empty = try initWithCapacity(allocator, empty_meta, 123);
    defer empty.deinit(allocator);
    try expectLayout(empty, 123, 0, .@"1", &.{});
}

test "initWithSize fits the largest capacity into the aligned budget" {
    const allocator = std.testing.allocator;

    var meta = try testMeta(allocator, &.{ Tag, Narrow, Wide });
    defer meta.deinit(allocator);

    // The 100-byte budget aligns down to 96, which holds eight entities.
    var layout = try initWithSize(allocator, meta, 100);
    defer layout.deinit(allocator);
    try expectLayout(layout, 8, 100, std.mem.Alignment.of(Wide), &.{ 0, 64, 96 });

    // Zero-sized columns consume no budget, so they hold any number of entities.
    var tag_meta = try testMeta(allocator, &.{Tag});
    defer tag_meta.deinit(allocator);
    var tag_layout = try initWithSize(allocator, tag_meta, 100);
    defer tag_layout.deinit(allocator);
    try expectLayout(tag_layout, std.math.maxInt(usize), 100, .@"1", &.{0});

    // The same is true for an archetype without columns.
    var empty_meta = try testMeta(allocator, &.{});
    defer empty_meta.deinit(allocator);
    var empty_layout = try initWithSize(allocator, empty_meta, 100);
    defer empty_layout.deinit(allocator);
    try expectLayout(empty_layout, std.math.maxInt(usize), 100, .@"1", &.{});

    // The requested size must fit the 16 KB limit.
    try expectError(Error.BufferTooLarge, initWithSize(allocator, meta, max_size_byte + 1));
}
