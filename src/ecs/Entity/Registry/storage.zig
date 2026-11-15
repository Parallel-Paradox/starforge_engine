const std = @import("std");

const engine = @import("engine");
const ecs = engine.ecs;
const CompId = ecs.component.Id;
const Entity = ecs.Entity;
const SparseSet = ecs.SparseSet;
const reflect = engine.reflect;
const TypeId = reflect.TypeId;
const Bundle = reflect.Bundle;
const Default = reflect.Default;
const Self = ecs.Entity.Registry;

/// Borrows contiguous component ids ordered as archetype ids followed by sparse-set ids.
/// All slices and their component storage must outlive the operation.
/// ids.len must equal archetype.len + sparse_set.len; each id matches its column's position.
pub const Columns = struct {
    ids: []const CompId = &.{},
    archetype: []const []const u8 = &.{},
    sparse_set: []const []const u8 = &.{},
    /// Resolved storage ids, one per sparse component column in the same order.
    sparse_ids: []const SparseSet.Id = &.{},

    pub fn archeCompIds(self: @This()) []const CompId {
        return self.ids[0..self.archetype.len];
    }

    pub fn sparseCompIds(self: @This()) []const CompId {
        return self.ids[self.archetype.len..];
    }

    pub fn getSparseId(self: @This(), id: CompId) ?SparseSet.Id {
        for (self.sparseCompIds(), self.sparse_ids) |candidate, set_id| {
            if (candidate.eql(id)) return set_id;
        }
        return null;
    }

    pub fn get(self: @This(), id: CompId) ?[]const u8 {
        for (self.ids, 0..) |candidate, i| {
            if (candidate.eql(id)) return if (i < self.archetype.len)
                self.archetype[i]
            else
                self.sparse_set[i - self.archetype.len];
        }
        return null;
    }
};

/// Transposes normalized rows and resolves component and sparse-set ids; may allocate.
/// Values are shallow-copied and retain their existing ownership.
/// Successful registrations and empty sparse sets remain if a later operation fails.
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
            if (comptime std.mem.eql(u8, storage, "sparse_set")) {
                const meta = self.comp_reg.getById(result.ids[column]).?;
                result.sparse_ids[i] = (try self.sparse_reg.getOrCreate(meta.type_meta)).id;
            }
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
        else => NormalizedFields(true, @TypeOf(.{})),
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
        sparse_ids: [column_count - archetype_count]SparseSet.Id,

        pub const Descriptors = struct {
            ids: []const CompId,
            sparse_ids: []const SparseSet.Id,
            archetype: [archetype_count][]const u8,
            sparse_set: [column_count - archetype_count][]const u8,

            /// Borrows these descriptor arrays as well as the grouped values and ids.
            pub fn view(self: *const @This()) Columns {
                return .{
                    .ids = self.ids,
                    .sparse_ids = self.sparse_ids,
                    .archetype = &self.archetype,
                    .sparse_set = &self.sparse_set,
                };
            }
        };

        /// Returns inline descriptors borrowing this value; keep grouped data stationary.
        /// Construct the slice view only after the returned descriptor arrays are in place.
        pub fn columns(self: *const @This()) Descriptors {
            var result: Descriptors = undefined;
            result.ids = &self.ids;
            result.sparse_ids = &self.sparse_ids;
            inline for (.{ "archetype", "sparse_set" }) |storage| {
                inline for (@field(self, storage), 0..) |_, i| {
                    @field(result, storage)[i] = std.mem.sliceAsBytes(&@field(self, storage)[i]);
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

/// Flattens component fields and groups values by storage.
/// With defaults enabled, completes requirements and constructs each missing value once.
/// Otherwise includes only explicit components, without requiring default constructors.
/// Explicit values take precedence; duplicate explicit components are compile errors.
pub fn normalize(
    comptime defaults: bool,
    fields: anytype,
) NormalizedFields(defaults, @TypeOf(fields)) {
    const Result = NormalizedFields(defaults, @TypeOf(fields));
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
/// Does nothing for rows normalized with defaults disabled.
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

pub fn NormalizedFields(comptime defaults: bool, comptime Fields: type) type {
    @setEvalBranchQuota(1_000_000);
    const types = Bundle.flatTypes(Fields);
    for (types, 0..) |T, i| {
        ecs.component.assertComponent(T, "normalize");
        if (std.mem.indexOfScalar(type, types[0..i], T) != null)
            @compileError("normalize received duplicate component type: " ++ @typeName(T));
    }
    const split = splitByStorage(if (defaults) expandRequire(&types) else &types);
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

/// Checks registered ids, storage groups, uniqueness and byte lengths.
/// With require_closed enabled, also checks requirement closure across both groups.
/// Empty groups are valid for any row count.
/// Inspects descriptors only; does not check buffer aliasing or component value contents.
pub fn validateColumns(
    self: *const Self,
    comptime require_closed: bool,
    columns: Columns,
    row_count: usize,
) bool {
    if (columns.sparse_ids.len != columns.sparse_set.len) return false;
    if (columns.archetype.len > columns.ids.len or
        columns.sparse_set.len != columns.ids.len - columns.archetype.len) return false;
    for (columns.ids, 0..) |id, i| {
        const meta = self.comp_reg.getById(id) orelse return false;
        const dense = i < columns.archetype.len;
        const storage: ecs.component.Storage = if (dense) .archetype else .sparse_set;
        if (meta.storage != storage) return false;
        if (!dense) {
            const set_id = columns.sparse_ids[i - columns.archetype.len];
            const set = self.sparse_reg.getById(set_id) orelse return false;
            if (!set.meta.eql(meta.type_meta)) return false;
        }
        const data = if (dense)
            columns.archetype[i]
        else
            columns.sparse_set[i - columns.archetype.len];
        const bytes = std.math.mul(usize, meta.type_meta.size, row_count) catch return false;
        if (data.len != bytes) return false;
        for (columns.ids[0..i]) |previous| if (previous.eql(id)) return false;
        if (!require_closed) continue;
        for (meta.require) |required| {
            for (columns.ids) |candidate| {
                if (candidate.eql(required)) break;
            } else return false;
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
        normalize(true, .{
            Position{ .x = 1, .y = 2 }, Probe{ .calls = &calls }, Health{ .value = 3 },
        }),
        normalize(true, .{
            Health{ .value = 6 }, Probe{ .calls = &calls }, Position{ .x = 4, .y = 5 },
        }),
    };
    const original = try group(&registry, batch);
    var copied = original;
    copied.archetype[0][0].x = 9;
    const columns = copied.columns();
    var descriptors = columns;
    const view = descriptors.view();
    try expect(view.ids.ptr == &copied.ids);
    try expect(view.sparse_ids.ptr == &copied.sparse_ids);
    try expect(view.getSparseId(copied.ids[2]).?.eql(copied.sparse_ids[0]));
    try expect(view.getSparseId(copied.ids[0]) == null);
    const set = registry.sparse_reg.getById(view.sparse_ids[0]).?;
    try expect(set.meta.id.eql(TypeId.of(Health)));
    try expectEqual(0, set.len());
    try expect(view.archetype.ptr == &descriptors.archetype);
    try expect(view.sparse_set.ptr == &descriptors.sparse_set);
    try expect(view.archeCompIds()[0].eql(copied.ids[0]));
    try expect(view.sparseCompIds()[0].eql(copied.ids[2]));
    try expect(view.get(copied.ids[0]).?.ptr == columns.archetype[0].ptr);
    try expect(view.get(copied.ids[2]).?.ptr == columns.sparse_set[0].ptr);
    try expect(view.get(.invalid) == null);
    try expectEqual(2, @TypeOf(copied).row_count);
    try expectEqual(2, @TypeOf(copied).archetype_count);
    try expectEqual(3, columns.ids.len);
    try expect(columns.ids[0].eql(registry.comp_reg.idOf(Position).?));
    try expect(columns.ids[1].eql(registry.comp_reg.idOf(Probe).?));
    try expect(columns.ids[2].eql(registry.comp_reg.idOf(Health).?));
    try expectEqual(@intFromPtr(&copied.archetype[0]), @intFromPtr(columns.archetype[0].ptr));
    const positions: []const Position = @alignCast(std.mem.bytesAsSlice(
        Position,
        columns.archetype[0],
    ));
    const health: []const Health = @alignCast(std.mem.bytesAsSlice(Health, columns.sparse_set[0]));
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
    const row = normalize(true, .{ Tag{}, Health{ .value = 7 }, SparseTag{} });
    const grouped = try group(&registry, [_]@TypeOf(row){ row, row });
    const columns = grouped.columns();
    try expectEqual(2, @TypeOf(grouped).row_count);
    try expectEqual(0, columns.archetype[0].len);
    try expectEqual(2 * @sizeOf(Health), columns.sparse_set[0].len);
    try expectEqual(0, columns.sparse_set[1].len);
    try expectEqual(7, grouped.sparse_set[0][1].value);
    const empty = try group(&registry, .{});
    try expectEqual(0, empty.columns().ids.len);
    try expectEqual(0, @TypeOf(empty).row_count);
    const typed_empty = try group(&registry, [0]@TypeOf(row){});
    try expectEqual(0, @TypeOf(typed_empty).row_count);
    try expectEqual(3, typed_empty.columns().ids.len);
    const empty_columns = typed_empty.columns();
    try expectEqual(2, empty_columns.sparse_ids.len);
    for (empty_columns.sparse_ids, columns.sparse_ids) |a, b| try expect(a.eql(b));
    for (empty_columns.archetype) |bytes| try expectEqual(0, bytes.len);
    for (empty_columns.sparse_set) |bytes| try expectEqual(0, bytes.len);
}

test "validateColumns checks shared cyclic requirements across storage groups" {
    const G = RequirementGraph;
    var registry = Self.init(std.testing.allocator);
    defer registry.deinit();
    _ = try registry.comp_reg.register(G.Root);
    const ids = [_]CompId{
        registry.comp_reg.idOf(G.Left).?,   registry.comp_reg.idOf(G.Root).?,
        registry.comp_reg.idOf(G.Shared).?, registry.comp_reg.idOf(G.Right).?,
    };
    const complete: Columns = .{
        .ids = &ids,
        .archetype = &.{ &.{}, &.{}, &.{} },
        .sparse_set = &.{&.{}},
        .sparse_ids = &.{(try registry.sparse_reg.getOrCreate(reflect.TypeMeta.of(G.Right))).id},
    };
    try expect(validateColumns(&registry, true, complete, 0));
    const incomplete = [_]Columns{
        .{
            .ids = &.{ ids[0], ids[1], ids[3] },
            .archetype = &.{ &.{}, &.{} },
            .sparse_set = &.{&.{}},
            .sparse_ids = complete.sparse_ids,
        },
        .{ .ids = ids[0..3], .archetype = complete.archetype },
        .{
            .ids = ids[3..],
            .sparse_set = complete.sparse_set,
            .sparse_ids = complete.sparse_ids,
        },
    };
    for (incomplete) |columns| {
        try expect(!validateColumns(&registry, true, columns, 0));
        try expect(validateColumns(&registry, false, columns, 0));
    }
}

test "validateColumns rejects unknown, stale and reserved column ids" {
    var registry = Self.init(std.testing.allocator);
    defer registry.deinit();
    const position = try registry.comp_reg.register(Position);
    const reserved = try registry.comp_reg.reserve(TypeId.of(Probe));
    const stale = CompId.init(position.index.get(), position.generation.next().get());
    inline for (.{ true, false }) |require_closed| {
        const valid: Columns = .{ .ids = &.{position}, .archetype = &.{&.{}} };
        try expect(validateColumns(&registry, require_closed, valid, 0));
        for ([_]CompId{ .invalid, CompId.init(100, 0), stale, reserved }) |invalid| {
            const columns: Columns = .{ .ids = &.{invalid}, .archetype = &.{&.{}} };
            try expect(!validateColumns(&registry, require_closed, columns, 0));
        }
    }
}

test "validateColumns rejects wrong storage, duplicates, lengths and size overflow" {
    var registry = Self.init(std.testing.allocator);
    defer registry.deinit();
    const position = try registry.comp_reg.register(Position);
    const health = try registry.comp_reg.register(Health);
    const positions = [_]Position{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 } };
    const healths = [_]Health{ .{ .value = 5 }, .{ .value = 6 } };
    const dense = std.mem.sliceAsBytes(&positions);
    const sparse = std.mem.sliceAsBytes(&healths);
    const set_id = (try registry.sparse_reg.getOrCreate(reflect.TypeMeta.of(Health))).id;
    const wrong_set = (try registry.sparse_reg.getOrCreate(reflect.TypeMeta.of(SparseTag))).id;
    const stale_set = SparseSet.Id.init(set_id.index.get(), set_id.generation.next().get());
    const valid: Columns = .{
        .ids = &.{ position, health },
        .archetype = &.{dense},
        .sparse_set = &.{sparse},
        .sparse_ids = &.{set_id},
    };
    const invalid = [_]Columns{
        .{
            .ids = &.{ health, position },
            .archetype = &.{sparse},
            .sparse_set = &.{dense},
            .sparse_ids = &.{set_id},
        },
        .{ .ids = &.{ position, position }, .archetype = &.{ dense, dense } },
        .{
            .ids = &.{ health, health },
            .sparse_set = &.{ sparse, sparse },
            .sparse_ids = &.{ set_id, set_id },
        },
        .{ .ids = &.{position}, .archetype = &.{dense[0 .. dense.len - 1]} },
        .{ .ids = &.{position} },
        .{ .archetype = &.{dense} },
        .{ .ids = &.{position}, .archetype = &.{dense}, .sparse_set = &.{sparse} },
    };
    inline for (.{ true, false }) |require_closed| {
        try expect(validateColumns(&registry, require_closed, valid, 2));
        var bad_sets = valid;
        bad_sets.sparse_ids = &.{};
        try expect(!validateColumns(&registry, require_closed, bad_sets, 2));
        bad_sets.sparse_ids = &.{ set_id, set_id };
        try expect(!validateColumns(&registry, require_closed, bad_sets, 2));
        for ([_]SparseSet.Id{ .invalid, SparseSet.Id.init(100, 0), stale_set, wrong_set }) |id| {
            bad_sets.sparse_ids = &.{id};
            try expect(!validateColumns(&registry, require_closed, bad_sets, 2));
        }
        for (invalid) |columns|
            try expect(!validateColumns(&registry, require_closed, columns, 2));
        for ([_]usize{ 0, 1, 3, std.math.maxInt(usize) }) |count|
            try expect(!validateColumns(&registry, require_closed, valid, count));
        try expect(validateColumns(&registry, require_closed, .{}, 3));
    }
}
test "normalize flattens bundles and preserves explicit component values" {
    const Nested = struct {
        pub const se_bundle: Bundle.Mark = .{};
        position: Position,
        health: Health,
    };
    var calls: usize = 0;
    const normalized = normalize(true, .{
        .nested = Nested{ .position = .{ .x = 3, .y = 4 }, .health = .{ .value = 7 } },
        .probe = Probe{ .calls = &calls },
    });
    try expect(@TypeOf(normalized.archetype) == @Tuple(&.{ Position, Probe }));
    try expect(@TypeOf(normalized.sparse_set) == @Tuple(&.{Health}));
    try expectEqual(Position{ .x = 3, .y = 4 }, normalized.archetype[0]);
    try expectEqual(&calls, normalized.archetype[1].calls);
    try expectEqual(7, normalized.sparse_set[0].value);
    try expectEqual(0, calls);

    const empty = normalize(true, .{});
    try expectEqual(0, empty.archetype.len);
    try expectEqual(0, empty.sparse_set.len);
}

test "normalize without defaults keeps explicit fields and does not construct requirements" {
    const G = RequirementGraph;
    G.Right.calls = 0;
    G.Shared.created = 0;
    const explicit = normalize(false, .{ G.Root{ .value = 5 }, Health{ .value = 7 } });
    try expect(@TypeOf(explicit.archetype) == @Tuple(&.{G.Root}));
    try expect(@TypeOf(explicit.sparse_set) == @Tuple(&.{Health}));
    try expectEqual(5, explicit.archetype[0].value);
    try expectEqual(7, explicit.sparse_set[0].value);
    try expectEqual(0, G.Right.calls);
    try expectEqual(0, G.Shared.created);

    const Root = struct {
        pub const se_component: ecs.component.Mark = .{ .require = &.{Position} };
    };
    const Nested = struct {
        pub const se_bundle: Bundle.Mark = .{};
        root: Root,
        probe: Probe,
    };
    var calls: usize = 0;
    const fields = .{Nested{ .root = .{}, .probe = .{ .calls = &calls } }};
    // Position has no default constructor, but explicit-only normalization must still compile.
    var normalized = normalize(false, fields);
    try expect(@TypeOf(normalized.archetype) == @Tuple(&.{ Root, Probe }));
    try expectEqual(0, normalized.sparse_set.len);
    deinitDefaults(fields, &normalized);
    try expectEqual(0, calls);
    const empty = normalize(false, .{});
    try expectEqual(0, empty.archetype.len + empty.sparse_set.len);
}

test "normalize completes cyclic requirements once and honors explicit overrides" {
    const G = RequirementGraph;
    G.Right.calls = 0;
    G.Shared.created = 0;
    const normalized = normalize(true, .{G.Root{ .value = 5 }});
    try expect(@TypeOf(normalized.archetype) == @Tuple(&.{ G.Root, G.Left, G.Shared }));
    try expect(@TypeOf(normalized.sparse_set) == @Tuple(&.{G.Right}));
    try expectEqual(5, normalized.archetype[0].value);
    try expectEqual(11, normalized.archetype[1].value);
    try expectEqual(22, normalized.sparse_set[0].value);
    try expectEqual(1, G.Shared.created);
    try expectEqual(1, G.Right.calls);

    const overridden = normalize(true, .{ G.Right{ .value = 99 }, G.Root{ .value = 6 } });
    try expectEqual(99, overridden.sparse_set[0].value);
    try expectEqual(1, G.Right.calls);
    _ = normalize(true, .{G.Root{ .value = 7 }});
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
