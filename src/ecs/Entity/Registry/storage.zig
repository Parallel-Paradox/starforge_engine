const std = @import("std");

const engine = @import("engine");
const ecs = engine.ecs;
const CompId = ecs.component.Id;
const Entity = ecs.Entity;
const reflect = engine.reflect;
const TypeId = reflect.TypeId;
const Bundle = reflect.Bundle;
const Default = reflect.Default;
const Self = ecs.Entity.Registry;

pub const Column = struct {
    id: CompId,
    ptr: []const u8,
};

/// Transposes normalized rows into inline column arrays; registration may allocate.
/// Values are shallow-copied and retain their existing ownership.
pub fn group(
    self: *Self,
    batch: anytype,
) ecs.component.Registry.RegisterError!GroupedColumns(@TypeOf(batch)) {
    const Result = GroupedColumns(@TypeOf(batch));
    var result: Result = undefined;
    comptime var column: usize = 0;
    inline for (.{ "archetype", "sparse_set" }) |storage| {
        const Arrays = @FieldType(Result, storage);
        inline for (@typeInfo(Arrays).@"struct".field_types, 0..) |Array, i| {
            const T = @typeInfo(Array).array.child;
            result.ids[column] = try self.comp_reg.register(T);
            inline for (batch, 0..) |row, j| {
                const types = @typeInfo(@TypeOf(@field(row, storage))).@"struct".field_types;
                const index = comptime std.mem.indexOfScalar(type, types, T).?;
                @field(result, storage)[i][j] = @field(row, storage)[index];
            }
            column += 1;
        }
    }
    return result;
}

fn GroupedColumns(comptime Batch: type) type {
    const rows = switch (@typeInfo(Batch)) {
        .@"struct" => |info| if (info.is_tuple)
            info.field_types
        else
            @compileError("group expects a tuple or fixed-size array of normalized rows"),
        .array => |info| &@as([info.len]type, @splat(info.child)),
        else => @compileError("group expects a tuple or fixed-size array of normalized rows"),
    };
    const Row = if (rows.len != 0) rows[0] else switch (@typeInfo(Batch)) {
        .array => |info| info.child,
        else => NormalizedFields(@TypeOf(.{})),
    };
    for (.{ "archetype", "sparse_set" }) |storage| {
        const types = @typeInfo(@FieldType(Row, storage)).@"struct".field_types;
        for (types, 0..) |T, i| {
            ecs.component.assertComponent(T, "group");
            if (!std.mem.eql(u8, @tagName(T.se_component.storage), storage))
                @compileError("group received a component in the wrong storage tuple");
            if (std.mem.indexOfScalar(type, types[0..i], T) != null)
                @compileError("group received duplicate component type: " ++ @typeName(T));
        }
        for (rows) |Other| {
            const other = @typeInfo(@FieldType(Other, storage)).@"struct".field_types;
            if (other.len != types.len)
                @compileError("group rows must contain the same component types");
            for (types) |T| {
                if (std.mem.indexOfScalar(type, other, T) == null)
                    @compileError("group rows must contain the same component types");
            }
        }
    }
    const ArchetypeArrays = ColumnArrays(@FieldType(Row, "archetype"), rows.len);
    const SparseArrays = ColumnArrays(@FieldType(Row, "sparse_set"), rows.len);
    return struct {
        pub const row_count = rows.len;
        pub const archetype_count = @typeInfo(ArchetypeArrays).@"struct".field_types.len;
        pub const column_count = archetype_count +
            @typeInfo(SparseArrays).@"struct".field_types.len;

        archetype: ArchetypeArrays,
        sparse_set: SparseArrays,
        ids: [column_count]CompId,

        /// Views borrow this value; keep it alive and stationary while using them.
        pub fn columns(self: *const @This()) [column_count]Column {
            var result: [column_count]Column = undefined;
            comptime var column: usize = 0;
            inline for (.{ "archetype", "sparse_set" }) |storage| {
                inline for (@field(self, storage), 0..) |_, i| {
                    result[column] = .{
                        .id = self.ids[column],
                        .ptr = std.mem.sliceAsBytes(&@field(self, storage)[i]),
                    };
                    column += 1;
                }
            }
            return result;
        }
    };
}

fn ColumnArrays(comptime Row: type, comptime count: usize) type {
    const info = @typeInfo(Row).@"struct";
    if (!info.is_tuple) @compileError("group storage fields must be component tuples");
    var arrays: [info.field_types.len]type = undefined;
    for (info.field_types, 0..) |T, i| arrays[i] = [count]T;
    return @Tuple(&arrays);
}

/// Flattens component fields, completes requirements, and groups values by storage.
/// Explicit values take precedence; each missing requirement is default-constructed once.
/// Duplicate explicit components and unsupported defaults are compile errors.
pub fn normalize(fields: anytype) NormalizedFields(@TypeOf(fields)) {
    const Result = NormalizedFields(@TypeOf(fields));
    const values = Bundle.flat(fields);
    const types = @typeInfo(@TypeOf(values)).@"struct".field_types;
    var result: Result = undefined;
    inline for (.{ "archetype", "sparse_set" }) |storage| {
        const Tuple = @FieldType(Result, storage);
        inline for (@typeInfo(Tuple).@"struct".field_types, 0..) |T, i| {
            @field(result, storage)[i] = if (comptime std.mem.indexOfScalar(type, types, T)) |index|
                values[index]
            else
                Default.of(T);
        }
    }
    return result;
}

/// Destroys only requirements default-constructed by normalize; explicit values stay borrowed.
/// Pass a mutable pointer to the uncommitted normalized row, and call at most once.
pub fn deinitDefaults(fields: anytype, normalized: anytype) void {
    const explicit = comptime Bundle.flatTypes(@TypeOf(fields));
    inline for (.{ "archetype", "sparse_set" }) |storage| {
        const Tuple = @TypeOf(@field(normalized.*, storage));
        inline for (@typeInfo(Tuple).@"struct".field_types, 0..) |T, i| {
            if (comptime std.mem.indexOfScalar(type, &explicit, T) != null) continue;
            const meta = reflect.TypeMeta.of(T);
            switch (meta.need_deinit) {
                .trivial => {},
                .managed => |deinitFn| deinitFn(&@field(normalized.*, storage)[i]),
            }
        }
    }
}

pub fn NormalizedFields(comptime Fields: type) type {
    const types = Bundle.flatTypes(Fields);
    for (types, 0..) |T, i| {
        ecs.component.assertComponent(T, "normalize");
        if (std.mem.indexOfScalar(type, types[0..i], T) != null)
            @compileError("normalize received duplicate component type: " ++ @typeName(T));
    }
    const split = splitByStorage(expandRequire(&types));
    return struct {
        archetype: @Tuple(split.archetype),
        sparse_set: @Tuple(split.sparse_set),
    };
}

/// Preserves the explicit prefix, then appends unique requirements in discovery order.
pub fn expandRequire(comptime list: []const type) []const type {
    @setEvalBranchQuota(1_000_000);
    var expanded = list;
    for (list) |T| {
        for (ecs.component.requireClosure(T)) |Required| {
            if (std.mem.indexOfScalar(type, expanded, Required) == null)
                expanded = expanded ++ [_]type{Required};
        }
    }
    return expanded;
}

/// Checks registered ids, storage groups, uniqueness, byte lengths and requirement closure.
/// Requirements may cross groups. Empty groups are valid for any row count.
/// Inspects descriptors only; does not check buffer aliasing or component value contents.
pub fn validateColumns(
    self: *const Self,
    archetype_columns: []const Column,
    sparse_columns: []const Column,
    row_count: usize,
) bool {
    const groups = [_][]const Column{ archetype_columns, sparse_columns };
    for (groups, 0..) |columns, group_index| {
        const storage: ecs.component.Storage = if (group_index == 0) .archetype else .sparse_set;
        for (columns, 0..) |column, i| {
            const meta = self.comp_reg.getById(column.id) orelse return false;
            if (meta.storage != storage) return false;
            const bytes = std.math.mul(usize, meta.type_meta.size, row_count) catch return false;
            if (column.ptr.len != bytes) return false;
            for (columns[0..i]) |previous| {
                if (previous.id.eql(column.id)) return false;
            }
            for (meta.require) |required| {
                search: for (groups) |candidates| {
                    for (candidates) |candidate| {
                        if (candidate.id.eql(required)) break :search;
                    }
                } else return false;
            }
        }
    }
    return true;
}

/// Stably partitions component types by their declared storage.
pub fn splitByStorage(comptime list: []const type) struct {
    archetype: []const type,
    sparse_set: []const type,
} {
    var archetype: []const type = &.{};
    var sparse_set: []const type = &.{};
    for (list) |T| {
        switch (T.se_component.storage) {
            .archetype => archetype = archetype ++ [_]type{T},
            .sparse_set => sparse_set = sparse_set ++ [_]type{T},
        }
    }
    return .{ .archetype = archetype, .sparse_set = sparse_set };
}

/// Returns whether the live entity has the registered component.
/// Unknown, stale, or reserved-only component ids return false.
pub fn hasComp(self: *const Self, id: Entity.Id, comp_id: CompId) bool {
    const entity = self.get(id) orelse return false;
    _ = self.comp_reg.getById(comp_id) orelse return false;
    return entity.signature.has(comp_id);
}

/// Borrows a component's bytes, or returns null if the entity or component is absent.
/// Unknown, stale, or reserved-only ids return null. Does not create storage.
/// The slice may be invalidated by storage growth or structural changes.
pub fn getComp(self: *const Self, id: Entity.Id, comp_id: CompId) ?[]const u8 {
    return componentBytes(false, self, id, comp_id);
}

/// Mutably borrows a component's bytes, or returns null if the entity or component is absent.
/// Unknown, stale, or reserved-only ids return null. Does not create storage.
/// The slice may be invalidated by storage growth or structural changes.
pub fn getCompMut(self: *Self, id: Entity.Id, comp_id: CompId) ?[]u8 {
    return componentBytes(true, self, id, comp_id);
}

/// Checks a component type without registering it.
pub fn hasTypedComp(self: *const Self, id: Entity.Id, comptime T: type) bool {
    ecs.component.assertComponent(T, "hasTypedComp");
    const comp_id = self.comp_reg.idOf(T) orelse return false;
    return self.hasComp(id, comp_id);
}

/// Borrows a typed component without registration; null if the entity or component is absent.
/// Storage growth or structural changes may invalidate the pointer.
pub fn getTypedComp(self: *const Self, id: Entity.Id, comptime T: type) ?*const T {
    ecs.component.assertComponent(T, "getTypedComp");
    const comp_id = self.comp_reg.idOf(T) orelse return null;
    const bytes = self.getComp(id, comp_id) orelse return null;
    return @ptrCast(@alignCast(bytes.ptr));
}

/// Mutably borrows a typed component with the same lookup and lifetime rules as getTypedComp.
pub fn getTypedCompMut(self: *Self, id: Entity.Id, comptime T: type) ?*T {
    ecs.component.assertComponent(T, "getTypedCompMut");
    const comp_id = self.comp_reg.idOf(T) orelse return null;
    const bytes = self.getCompMut(id, comp_id) orelse return null;
    return @ptrCast(@alignCast(bytes.ptr));
}

fn componentBytes(
    comptime mutable: bool,
    self: if (mutable) *Self else *const Self,
    id: Entity.Id,
    comp_id: CompId,
) if (mutable) ?[]u8 else ?[]const u8 {
    const entity = self.get(id) orelse return null;
    const meta = self.comp_reg.getById(comp_id) orelse return null;
    if (!entity.signature.has(comp_id)) return null;

    switch (meta.storage) {
        .archetype => {
            if (mutable) {
                const archetype = self.arche_reg.getByIdMut(entity.archetype_id) orelse return null;
                return archetype.getBytesMut(meta.typeId(), entity.archetype_row);
            } else {
                const archetype =
                    self.arche_reg.getById(entity.archetype_id) orelse return null;
                return archetype.getBytes(meta.typeId(), entity.archetype_row);
            }
        },
        .sparse_set => {
            if (mutable) {
                const entry = self.sparse_reg.getByTypeIdMut(meta.typeId()) orelse return null;
                return entry.set.getBytesMut(id);
            } else {
                const entry = self.sparse_reg.getByTypeId(meta.typeId()) orelse return null;
                return entry.set.getBytes(id);
            }
        },
    }
}

const testing = @import("testing.zig");
const Position = testing.Position;
const Health = testing.Health;
const Probe = testing.Probe;
const RequirementGraph = testing.RequirementGraph;
const Tag = testing.Tag;
const SparseTag = testing.SparseTag;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "group transposes reordered normalized rows and borrows the final storage" {
    var registry = Self.init(std.testing.allocator);
    defer registry.deinit();
    var calls: usize = 0;
    const batch = .{
        normalize(.{ Position{ .x = 1, .y = 2 }, Probe{ .calls = &calls }, Health{ .value = 3 } }),
        normalize(.{ Health{ .value = 6 }, Probe{ .calls = &calls }, Position{ .x = 4, .y = 5 } }),
    };
    const original = try group(&registry, batch);
    var copied = original;
    copied.archetype[0][0].x = 9;
    const columns = copied.columns();
    try expectEqual(2, @TypeOf(copied).row_count);
    try expectEqual(2, @TypeOf(copied).archetype_count);
    try expectEqual(3, columns.len);
    try expect(columns[0].id.eql(registry.comp_reg.idOf(Position).?));
    try expect(columns[1].id.eql(registry.comp_reg.idOf(Probe).?));
    try expect(columns[2].id.eql(registry.comp_reg.idOf(Health).?));
    try expectEqual(@intFromPtr(&copied.archetype[0]), @intFromPtr(columns[0].ptr.ptr));
    const positions: []const Position = @alignCast(std.mem.bytesAsSlice(Position, columns[0].ptr));
    const health: []const Health = @alignCast(std.mem.bytesAsSlice(Health, columns[2].ptr));
    try expectEqual(Position{ .x = 9, .y = 2 }, positions[0]);
    try expectEqual(Position{ .x = 4, .y = 5 }, positions[1]);
    try expectEqual(3, health[0].value);
    try expectEqual(6, health[1].value);
    try expectEqual(1, original.archetype[0][0].x);
    try expectEqual(0, calls);
}

test "group supports fixed arrays, empty batches and zero sized columns" {
    var registry = Self.init(std.testing.allocator);
    defer registry.deinit();
    const row = normalize(.{ Tag{}, Health{ .value = 7 }, SparseTag{} });
    const grouped = try group(&registry, [_]@TypeOf(row){ row, row });
    const columns = grouped.columns();
    try expectEqual(2, @TypeOf(grouped).row_count);
    try expectEqual(0, columns[0].ptr.len);
    try expectEqual(2 * @sizeOf(Health), columns[1].ptr.len);
    try expectEqual(0, columns[2].ptr.len);
    try expectEqual(7, grouped.sparse_set[0][1].value);
    const empty = try group(&registry, .{});
    try expectEqual(0, empty.columns().len);
    try expectEqual(0, @TypeOf(empty).row_count);
    const typed_empty = try group(&registry, [0]@TypeOf(row){});
    try expectEqual(0, @TypeOf(typed_empty).row_count);
    try expectEqual(3, typed_empty.columns().len);
    for (typed_empty.columns()) |column| try expectEqual(0, column.ptr.len);
}

test "validateColumns checks shared cyclic requirements across storage groups" {
    const G = RequirementGraph;
    var registry = Self.init(std.testing.allocator);
    defer registry.deinit();
    _ = try registry.comp_reg.register(G.Root);
    // Zero rows isolate dependency checks from byte-length validation.
    const dense = [_]Column{
        .{ .id = registry.comp_reg.idOf(G.Left).?, .ptr = &.{} },
        .{ .id = registry.comp_reg.idOf(G.Root).?, .ptr = &.{} },
        .{ .id = registry.comp_reg.idOf(G.Shared).?, .ptr = &.{} },
    };
    const sparse = [_]Column{.{ .id = registry.comp_reg.idOf(G.Right).?, .ptr = &.{} }};
    try expect(validateColumns(&registry, &dense, &sparse, 0));
    try expect(!validateColumns(&registry, dense[0..2], &sparse, 0));
    try expect(!validateColumns(&registry, &dense, &.{}, 0));
    try expect(!validateColumns(&registry, &.{}, &sparse, 0));
}
test "validateColumns rejects unknown, stale and reserved column ids" {
    var registry = Self.init(std.testing.allocator);
    defer registry.deinit();
    const position = try registry.comp_reg.register(Position);
    const reserved = try registry.comp_reg.reserve(TypeId.of(Probe));
    const stale = CompId.init(position.index.get(), position.generation.next().get());
    try expect(validateColumns(&registry, &.{.{ .id = position, .ptr = &.{} }}, &.{}, 0));
    for ([_]CompId{ .invalid, CompId.init(100, 0), stale, reserved }) |invalid| {
        try expect(!validateColumns(&registry, &.{.{ .id = invalid, .ptr = &.{} }}, &.{}, 0));
    }
}

test "validateColumns rejects wrong storage, duplicates, lengths and size overflow" {
    var registry = Self.init(std.testing.allocator);
    defer registry.deinit();
    const position = try registry.comp_reg.register(Position);
    const health = try registry.comp_reg.register(Health);
    const positions = [_]Position{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 } };
    const healths = [_]Health{ .{ .value = 5 }, .{ .value = 6 } };
    const dense = Column{ .id = position, .ptr = std.mem.sliceAsBytes(&positions) };
    const sparse = Column{ .id = health, .ptr = std.mem.sliceAsBytes(&healths) };
    try expect(validateColumns(&registry, &.{dense}, &.{sparse}, 2));
    try expect(!validateColumns(&registry, &.{sparse}, &.{dense}, 2));
    try expect(!validateColumns(&registry, &.{ dense, dense }, &.{sparse}, 2));
    try expect(!validateColumns(&registry, &.{dense}, &.{ sparse, sparse }, 2));
    for ([_]usize{ 0, 1, 3, std.math.maxInt(usize) }) |count|
        try expect(!validateColumns(&registry, &.{dense}, &.{sparse}, count));
    const truncated = Column{ .id = position, .ptr = dense.ptr[0 .. dense.ptr.len - 1] };
    try expect(!validateColumns(&registry, &.{truncated}, &.{}, 2));
    try expect(validateColumns(&registry, &.{}, &.{}, 3));
}

test "normalize flattens bundles and preserves explicit component values" {
    const Nested = struct {
        pub const se_bundle: Bundle.Mark = .{};
        position: Position,
        health: Health,
    };
    var calls: usize = 0;
    const normalized = normalize(.{
        .nested = Nested{ .position = .{ .x = 3, .y = 4 }, .health = .{ .value = 7 } },
        .probe = Probe{ .calls = &calls },
    });
    try expect(@TypeOf(normalized.archetype) == @Tuple(&.{ Position, Probe }));
    try expect(@TypeOf(normalized.sparse_set) == @Tuple(&.{Health}));
    try expectEqual(Position{ .x = 3, .y = 4 }, normalized.archetype[0]);
    try expectEqual(&calls, normalized.archetype[1].calls);
    try expectEqual(7, normalized.sparse_set[0].value);
    try expectEqual(0, calls);

    const empty = normalize(.{});
    try expectEqual(0, empty.archetype.len);
    try expectEqual(0, empty.sparse_set.len);
}

test "normalize completes cyclic requirements once and honors explicit overrides" {
    const G = RequirementGraph;
    G.Right.calls = 0;
    G.Shared.created = 0;
    const normalized = normalize(.{G.Root{ .value = 5 }});
    try expect(@TypeOf(normalized.archetype) == @Tuple(&.{ G.Root, G.Left, G.Shared }));
    try expect(@TypeOf(normalized.sparse_set) == @Tuple(&.{G.Right}));
    try expectEqual(5, normalized.archetype[0].value);
    try expectEqual(11, normalized.archetype[1].value);
    try expectEqual(22, normalized.sparse_set[0].value);
    try expectEqual(1, G.Shared.created);
    try expectEqual(1, G.Right.calls);

    const overridden = normalize(.{ G.Right{ .value = 99 }, G.Root{ .value = 6 } });
    try expectEqual(99, overridden.sparse_set[0].value);
    try expectEqual(1, G.Right.calls);
    _ = normalize(.{G.Root{ .value = 7 }});
    try expectEqual(2, G.Right.calls);
}
test "component byte access preserves constness and resolves storage through registry lookups" {
    var registry = Self.init(std.testing.allocator);
    defer registry.deinit();
    const id = try registry.add(.{ Position{ .x = 1, .y = 2 }, Health{ .value = 3 } });
    const readonly: *const Self = &registry;
    inline for (.{ Position, Health }) |T| {
        const comp_id = registry.comp_reg.idOf(T).?;
        const bytes = registry.getCompMut(id, comp_id).?;
        const view = readonly.getComp(id, comp_id).?;
        const typed = readonly.getTypedComp(id, T).?;
        const typed_mut = registry.getTypedCompMut(id, T).?;
        try expect(@TypeOf(typed) == *const T);
        try expect(@TypeOf(typed_mut) == *T);
        try expect(readonly.hasTypedComp(id, T));
        try expectEqual(@intFromPtr(bytes.ptr), @intFromPtr(typed_mut));
        try expectEqual(@intFromPtr(view.ptr), @intFromPtr(typed));
        try expect(@TypeOf(bytes) == []u8);
        try expect(@TypeOf(view) == []const u8);
        try expectEqual(@intFromPtr(bytes.ptr), @intFromPtr(view.ptr));
        @memset(bytes, 0);
        for (view) |byte| try expectEqual(0, byte);
    }
    const entity = readonly.get(id).?;
    const archetype = readonly.arche_reg.getById(entity.archetype_id).?;
    try expect(@TypeOf(archetype) == *const ecs.Archetype);
    try expect(archetype.getBytes(TypeId.of(Health), entity.archetype_row) == null);
    try expect(archetype.getBytes(TypeId.of(Position), archetype.len()) == null);
    try expect(readonly.arche_reg.getById(entity.archetype_id.nextGeneration()) == null);
    const entry = readonly.sparse_reg.getByTypeId(TypeId.of(Health)).?;
    try expect(@TypeOf(entry) == *const ecs.SparseSet.Registry.Entry);
    try expect(readonly.sparse_reg.getById(entry.id).? == &entry.set);
    try expect(readonly.sparse_reg.getById(entry.id.nextGeneration()) == null);
    try expect(readonly.sparse_reg.getByTypeId(TypeId.of(Position)) == null);
}

test "component access rejects absent and invalid ids without creating storage" {
    const allocator = std.testing.allocator;
    var registry = Self.init(allocator);
    defer registry.deinit();
    const readonly: *const Self = &registry;
    try expect(!readonly.hasTypedComp(.invalid, Probe));
    try expect(readonly.getTypedComp(.invalid, Probe) == null);
    try expect(registry.getTypedCompMut(.invalid, Probe) == null);
    try expect(registry.comp_reg.idOf(Probe) == null);
    const position_id = try registry.comp_reg.register(Position);
    const health_id = try registry.comp_reg.register(Health);
    const reserved = try registry.comp_reg.reserve(TypeId.of(Probe));
    const empty = try registry.add(.{});
    try expect(!readonly.hasTypedComp(empty, Probe));
    try expect(readonly.getTypedComp(empty, Probe) == null);
    try expect(registry.getTypedCompMut(empty, Probe) == null);

    for ([_]CompId{ position_id, health_id, reserved, .invalid, CompId.init(100, 0) }) |comp_id| {
        try expect(!readonly.hasComp(empty, comp_id));
        try expect(readonly.getComp(empty, comp_id) == null);
        try expect(registry.getCompMut(empty, comp_id) == null);
    }
    try expectEqual(1, registry.arche_reg.entries.items.len);
    try expectEqual(0, registry.sparse_reg.entries.items.len);

    const id = try registry.add(.{
        Position{ .x = 3, .y = 4 },
        Health{ .value = 7 },
    });
    for ([_]CompId{ position_id, health_id }) |comp_id| {
        const stale = CompId.init(comp_id.index.get(), comp_id.generation.next().get());
        try expect(!readonly.hasComp(id, stale));
        try expect(readonly.getComp(id, stale) == null);
        try expect(registry.getCompMut(id, stale) == null);
    }
    const stale = Entity.Id.init(id.index.get(), id.generation.next().get());
    try expect(!readonly.hasTypedComp(stale, Position));
    try expect(readonly.getTypedComp(stale, Position) == null);
    try expect(registry.getTypedCompMut(stale, Position) == null);
    try expect(!readonly.hasComp(stale, position_id));
    try expect(readonly.getComp(stale, position_id) == null);
    try expect(registry.getCompMut(stale, position_id) == null);
}
