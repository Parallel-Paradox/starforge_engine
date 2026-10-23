//! Metadata of the component types stored in an archetype.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const engine = @import("engine");
const ecs = engine.ecs;
const CompId = ecs.component.Id;
const CompRegistry = ecs.component.Registry;
const Signature = ecs.entity.Signature;

const reflect = engine.reflect;
const TypeId = reflect.TypeId;
const TypeMeta = reflect.TypeMeta;

/// A sorted list of component IDs in the archetype, used to determine the memory layout.
/// Ordered by alignment descending > size descending > component_id ascending.
columns: std.ArrayList(Entry),
signature: Signature,
/// TypeId -> column index.
id_to_col: std.AutoHashMap(TypeId, usize),

pub const Entry = struct {
    id: CompId,
    meta: TypeMeta,

    pub fn lessThan(_: void, a: Entry, b: Entry) bool {
        const a_align = a.meta.alignment;
        const b_align = b.meta.alignment;
        if (a_align != b_align) return @backingInt(a_align) > @backingInt(b_align);

        const a_size = a.meta.size;
        const b_size = b.meta.size;
        if (a_size != b_size) return a_size > b_size;

        if (a.id.index != b.id.index) return a.id.index.get() < b.id.index.get();

        // Columns hold unique ids, so equal indexes cannot differ by generation.
        std.debug.assert(a.id.generation == b.id.generation);
        return false;
    }
};

/// Builds the metadata of an archetype that stores `unsorted`.
/// The columns are sorted by `Entry.lessThan`, and `signature` holds every id.
///
/// Every id in `unsorted` must be registered in `registry` and appear only once.
pub fn init(
    allocator: Allocator,
    unsorted: []const CompId,
    registry: CompRegistry,
) Allocator.Error!@This() {
    var self: @This() = .{
        .columns = .empty,
        .signature = Signature.init(allocator),
        .id_to_col = .init(allocator),
    };
    errdefer self.deinit(allocator);

    try self.columns.ensureTotalCapacity(allocator, unsorted.len);
    for (unsorted) |id| {
        const comp_meta = registry.getMeta(id) orelse unreachable;
        self.columns.appendAssumeCapacity(.{ .id = id, .meta = comp_meta.type_meta });
    }
    std.mem.sort(Entry, self.columns.items, {}, Entry.lessThan);

    try self.id_to_col.ensureTotalCapacity(@intCast(self.columns.items.len));
    for (self.columns.items, 0..) |column, index| {
        self.id_to_col.putAssumeCapacityNoClobber(column.meta.id, index);
    }

    try self.signature.add(allocator, unsorted);
    return self;
}

/// Releases the columns, the signature and the type lookup table.
pub fn deinit(self: *@This(), allocator: Allocator) void {
    self.columns.deinit(allocator);
    self.signature.deinit(allocator);
    self.id_to_col.deinit();
}

/// The alignment of the archetype buffer: the first column's alignment, since
/// columns are sorted by alignment descending, or 1 when there are no columns.
pub fn alignment(self: @This()) Alignment {
    if (self.columns.items.len == 0) return .@"1";
    return self.columns.items[0].meta.alignment;
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const CompMark = ecs.component.Mark;

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

test "init sorts columns and builds the lookup tables" {
    const allocator = std.testing.allocator;

    var registry = CompRegistry.init(allocator);
    defer registry.deinit();

    const wide = try registry.register(Wide);
    const narrow = try registry.register(Narrow);
    const tag = try registry.register(Tag);

    var meta = try init(allocator, &.{ tag, narrow, wide }, registry);
    defer meta.deinit(allocator);

    // Alignment descending puts the widest type first, the zero-sized tag last.
    try expectEqual(@as(usize, 3), meta.columns.items.len);
    try expectEqual(wide, meta.columns.items[0].id);
    try expectEqual(narrow, meta.columns.items[1].id);
    try expectEqual(tag, meta.columns.items[2].id);

    try expect(meta.columns.items[0].meta.eql(TypeMeta.of(Wide)));
    try expect(meta.columns.items[1].meta.eql(TypeMeta.of(Narrow)));
    try expect(meta.columns.items[2].meta.eql(TypeMeta.of(Tag)));

    try expect(meta.signature.has(wide));
    try expect(meta.signature.has(narrow));
    try expect(meta.signature.has(tag));

    try expectEqual(@as(?usize, 0), meta.id_to_col.get(TypeId.of(Wide)));
    try expectEqual(@as(?usize, 1), meta.id_to_col.get(TypeId.of(Narrow)));
    try expectEqual(@as(?usize, 2), meta.id_to_col.get(TypeId.of(Tag)));

    try expectEqual(std.mem.Alignment.of(Wide), meta.alignment());
}

test "init breaks layout ties by component id" {
    const allocator = std.testing.allocator;

    const First = struct {
        pub const se_component: CompMark = .{};
        value: u32,
    };
    const Second = struct {
        pub const se_component: CompMark = .{};
        value: u32,
    };

    var registry = CompRegistry.init(allocator);
    defer registry.deinit();

    const first = try registry.register(First);
    const second = try registry.register(Second);

    // Same alignment and size, so the ids decide the order.
    var meta = try init(allocator, &.{ second, first }, registry);
    defer meta.deinit(allocator);

    try expectEqual(first, meta.columns.items[0].id);
    try expectEqual(second, meta.columns.items[1].id);
}

test "init of no components has an empty layout" {
    const allocator = std.testing.allocator;

    var registry = CompRegistry.init(allocator);
    defer registry.deinit();

    var meta = try init(allocator, &.{}, registry);
    defer meta.deinit(allocator);

    try expectEqual(@as(usize, 0), meta.columns.items.len);
    try expectEqual(@as(usize, 0), meta.id_to_col.count());
    try expectEqual(@as(usize, 0), meta.signature.mask.count());
    try expectEqual(std.mem.Alignment.@"1", meta.alignment());
}
