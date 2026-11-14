const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const ecs = engine.ecs;
const CompId = ecs.component.Id;
const Archetype = ecs.Archetype;
const SparseSet = ecs.SparseSet;
const Entity = ecs.Entity;
const reflect = engine.reflect;
const TypeId = reflect.TypeId;
const Self = ecs.Entity.Registry;
const _storage = @import("storage.zig");
const Column = _storage.Column;
const NormalizedFields = _storage.NormalizedFields;
const normalize = _storage.normalize;
const deinitDefaults = _storage.deinitDefaults;

pub const AddError = ecs.component.Registry.RegisterError || Archetype.ChunkLayout.Error;

/// Creates one entity; explicit component ownership transfers only on success.
pub fn add(self: *Self, fields: anytype) AddError!Entity.Id {
    var ids: [1]Entity.Id = undefined;
    try self.addBatch(.{fields}, &ids);
    return ids[0];
}

/// Stops at the first error, retaining earlier entities and leaving remaining ids invalid.
pub fn addMany(self: *Self, many: anytype, ids: []Entity.Id) AddError!void {
    std.debug.assert(many.len == ids.len);
    @memset(ids, .invalid);
    inline for (many, 0..) |fields, i| ids[i] = try self.add(fields);
}

/// Adds rows with identical normalized component sets in one batch.
/// Stops at the first error, retaining committed entities and their output ids.
/// Only rows with valid output ids transfer ownership; remaining ids stay invalid.
pub fn addBatch(self: *Self, batch: anytype, ids: []Entity.Id) AddError!void {
    std.debug.assert(batch.len == ids.len);
    @memset(ids, .invalid);
    if (comptime batch.len == 0) return;

    comptime var types: [batch.len]type = undefined;
    inline for (batch, 0..) |fields, i| {
        types[i] = NormalizedFields(@TypeOf(fields));
    }
    var normalized: @Tuple(&types) = undefined;
    inline for (batch, 0..) |fields, i| normalized[i] = normalize(fields);
    errdefer inline for (batch, 0..) |fields, i| {
        if (ids[i].eql(.invalid))
            deinitDefaults(fields, &normalized[i]);
    };

    const grouped = try self.group(normalized);
    const columns = grouped.columns();
    const boundary = @TypeOf(grouped).archetype_count;
    try self.addBatchImpl(columns[0..boundary], columns[boundary..], ids);
}

/// Borrows packed columns and caller-owned output storage. Inputs must not alias ECS storage.
/// Columns must match their storage group, be unique and contain exactly ids.len values.
/// Registered requirements must be closed across both groups together.
/// On error, preserves committed rows and ids; uncommitted values remain borrowed.
pub fn addBatchImpl(
    self: *Self,
    archetype_columns: []const Column,
    sparse_columns: []const Column,
    ids: []Entity.Id,
) AddError!void {
    @memset(ids, .invalid);
    std.debug.assert(self.validateColumns(archetype_columns, sparse_columns, ids.len));
    if (ids.len == 0) return;

    const allocator = self.allocator;
    const comp_ids = try allocator.alloc(CompId, archetype_columns.len + sparse_columns.len);
    defer allocator.free(comp_ids);
    const dense_count = archetype_columns.len;
    for (archetype_columns, comp_ids[0..dense_count]) |column, *id| id.* = column.id;
    for (sparse_columns, comp_ids[dense_count..]) |column, *id| id.* = column.id;
    const entry = try self.arche_reg.getOrCreate(comp_ids[0..dense_count], self.comp_reg);
    const archetype = &entry.archetype;
    const sparse_ids = try allocator.alloc(SparseSet.Id, sparse_columns.len);
    defer allocator.free(sparse_ids);
    for (sparse_columns, sparse_ids) |column, *id| {
        const meta = self.comp_reg.getById(column.id).?;
        id.* = (try self.sparse_reg.getOrCreate(meta.type_meta)).id;
    }

    const reused = @min(ids.len, self.retired.items.len);
    const old_len = self.entities.items.len;
    const final_len = std.math.add(usize, old_len, ids.len - reused) catch
        return error.OutOfMemory;
    try self.entities.ensureTotalCapacity(allocator, final_len);
    try archetype.reserve(ids.len);
    for (sparse_ids) |id| try self.sparse_reg.getById(id).?.reserve(ids.len);

    // Prepare directly in inactive registry slots; their ids stay invalid until commit.
    // After preparation, publishing the successful prefix cannot fail.
    var prepared: usize = 0;
    var failure: ?Allocator.Error = null;
    for (0..ids.len) |i| {
        const id = if (i < reused)
            self.retired.items[self.retired.items.len - 1 - i]
        else
            Entity.Id.init(old_len + i - reused, 0);
        var entity = prepareBatchEntity(
            self,
            entry,
            comp_ids[dense_count..],
            sparse_ids,
            id,
            i,
        ) catch |err| {
            failure = err;
            break;
        };
        entity.id = .invalid;
        self.entities.allocatedSlice()[id.index.get()] = entity;
        prepared += 1;
    }
    // From here on, all operations are infallible. The output buffer also supplies staged ids.
    for (ids[0..prepared], 0..) |*id, i| {
        id.* = if (i < reused)
            self.retired.items[self.retired.items.len - 1 - i]
        else
            Entity.Id.init(old_len + i - reused, 0);
    }
    commitBatch(self, archetype, archetype_columns, sparse_columns, sparse_ids, ids[0..prepared]);
    self.retired.items.len -= @min(prepared, reused);
    self.entities.items.len = old_len + prepared - @min(prepared, reused);
    if (failure) |err| return err;
}

fn prepareBatchEntity(
    self: *Self,
    entry: *const Archetype.Registry.Entry,
    sparse_components: []const CompId,
    sparse_ids: []const SparseSet.Id,
    id: Entity.Id,
    offset: usize,
) Allocator.Error!Entity {
    var entity = Entity.init(self.allocator, id);
    errdefer entity.deinit(self.allocator);
    try entity.sparse_comps.ensureTotalCapacity(self.allocator, sparse_components.len);
    for (sparse_ids) |set_id| {
        try self.sparse_reg.getById(set_id).?.reserveForEntity(id);
        entity.sparse_comps.appendAssumeCapacity(set_id);
    }
    const base = entry.archetype.meta.signature;
    if (sparse_components.len == 0) {
        entity.signature = base;
    } else {
        entity.signature = try base.clone(self.allocator);
        try entity.signature.add(self.allocator, sparse_components);
    }
    entity.archetype_id = entry.id;
    entity.archetype_row = entry.archetype.len() + offset;
    return entity;
}

/// Publishes a fully prepared prefix without allocation or component destruction.
fn commitBatch(
    self: *Self,
    archetype: *Archetype,
    archetype_columns: []const Column,
    sparse_columns: []const Column,
    sparse_ids: []const SparseSet.Id,
    ids: []const Entity.Id,
) void {
    if (ids.len == 0) return;
    archetype.stageEntities(ids);
    for (archetype_columns) |column| {
        const meta = self.comp_reg.getById(column.id).?;
        const index = archetype.meta.id_to_col.get(meta.typeId()).?;
        const size = meta.type_meta.size;
        archetype.stageColumn(index, column.ptr[0 .. ids.len * size]);
    }
    for (sparse_columns, sparse_ids) |column, set_id| {
        const set = self.sparse_reg.getById(set_id).?;
        const size = set.meta.size;
        set.appendBatchAssumeCapacity(ids, column.ptr[0 .. ids.len * size]);
    }
    archetype.commitRows(ids.len);
    for (ids) |id| self.entities.allocatedSlice()[id.index.get()].id = id;
}

const testing = @import("testing.zig");
const Position = testing.Position;
const Velocity = testing.Velocity;
const Health = testing.Health;
const Probe = testing.Probe;
const AutoRequirement = testing.AutoRequirement;
const RequirementGraph = testing.RequirementGraph;
const SparseTag = testing.SparseTag;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const checkAllAllocationFailures = std.testing.checkAllAllocationFailures;
const TestMark = ecs.component.Mark;

test "addBatch stages columns, reuses retired ids and preserves input buffers" {
    var registry = Self.init(std.testing.allocator);
    defer registry.deinit();
    const retired = try registry.add(.{ Position{ .x = 0, .y = 0 }, Health{ .value = 0 } });
    try expect(try registry.remove(retired));
    var ids: [3]Entity.Id = undefined;
    const rows = .{
        .{ Position{ .x = 1, .y = 2 }, Health{ .value = 3 } },
        .{ Health{ .value = 6 }, Position{ .x = 4, .y = 5 } },
        .{ Position{ .x = 7, .y = 8 }, Health{ .value = 9 } },
    };
    try registry.addBatch(rows, &ids);
    try expectEqual(3, registry.len());
    try expectEqual(retired.index.get(), ids[0].index.get());
    try expect(!retired.eql(ids[0]));
    for (ids, 0..) |id, i| {
        const entity = registry.get(id).?;
        const archetype = registry.arche_reg.getById(entity.archetype_id).?;
        try testing.expectArchetypeValue(archetype, Position, i, .{
            .x = @intCast(1 + i * 3),
            .y = @intCast(2 + i * 3),
        });
        const set = &registry.sparse_reg.getByTypeId(TypeId.of(Health)).?.set;
        try expectEqual(@as(u32, @intCast(3 + i * 3)), set.get(Health, id).?.value);
        try expect(entity.signature.has(registry.comp_reg.idOf(Health).?));
        try expect(!archetype.meta.signature.has(registry.comp_reg.idOf(Health).?));
    }
    try expectEqual(1, rows[0][0].x);
    try expectEqual(9, rows[2][1].value);
}

test "addMany supports heterogeneous rows, empty entities and shared dense signatures" {
    var registry = Self.init(std.testing.allocator);
    defer registry.deinit();
    var ids: [3]Entity.Id = undefined;
    try registry.addMany(.{ .{}, .{Position{ .x = 1, .y = 2 }}, .{Health{ .value = 3 }} }, &ids);
    for (ids[0..2]) |id| {
        const entity = registry.get(id).?;
        const archetype = registry.arche_reg.getById(entity.archetype_id).?;
        try expectEqual(0, entity.sparse_comps.items.len);
        try expect(entity.signature.eql(archetype.meta.signature));
    }
    try expectEqual(3, registry.len());
    var empty: [0]Entity.Id = .{};
    try registry.addBatch(.{}, &empty);
    try registry.addMany(.{}, &empty);
}

test "addBatch handles every allocation failure without losing component ownership" {
    try checkAllAllocationFailures(std.testing.allocator, exerciseBatchFailures, .{});
}

fn exerciseBatchFailures(allocator: Allocator) !void {
    const Root = struct {
        pub const se_component: TestMark = .{ .require = &.{AutoRequirement} };
        value: usize,
    };
    AutoRequirement.created = 0;
    AutoRequirement.destroyed = 0;
    var calls: [3]usize = @splat(0);
    var registry = Self.init(allocator);
    var live = true;
    defer if (live) registry.deinit();
    const retired = try registry.add(.{});
    try expect(try registry.remove(retired));
    var ids: [3]Entity.Id = undefined;
    var failure: ?AddError = null;
    registry.addBatch(.{
        .{ Root{ .value = 1 }, Probe{ .calls = &calls[0] } },
        .{ Root{ .value = 2 }, Probe{ .calls = &calls[1] } },
        .{ Root{ .value = 3 }, Probe{ .calls = &calls[2] } },
    }, &ids) catch |err| {
        failure = err;
    };
    var committed: usize = 0;
    var invalid_seen = false;
    for (ids) |id| {
        if (id.eql(.invalid)) {
            invalid_seen = true;
            continue;
        }
        try expect(!invalid_seen);
        try expect(registry.contains(id));
        committed += 1;
    }
    try expectEqual(committed, registry.len());
    try expectEqual(1 - @min(committed, 1), registry.retired.items.len);
    if (committed != 0) {
        try expectEqual(retired.index.get(), ids[0].index.get());
        try expect(!retired.eql(ids[0]));
    }
    try expectEqual(AutoRequirement.created - committed, AutoRequirement.destroyed);
    registry.deinit();
    live = false;
    try expectEqual(AutoRequirement.created, AutoRequirement.destroyed);
    for (calls, 0..) |count, i| try expectEqual(@as(usize, @intFromBool(i < committed)), count);
    if (failure) |err| return err;
    try expectEqual(3, committed);
}

test "addMany retains earlier entities when a later archetype is too large" {
    const Huge = struct {
        pub const se_component: TestMark = .{};
        bytes: [Archetype.ChunkLayout.max_size_byte + 1]u8 = @splat(0),
    };
    var registry = Self.init(std.testing.allocator);
    var calls: usize = 0;
    var ids: [3]Entity.Id = undefined;
    try expectError(error.BufferTooLarge, registry.addMany(.{
        .{Probe{ .calls = &calls }},
        .{Huge{}},
        .{Position{ .x = 1, .y = 2 }},
    }, &ids));
    try expect(registry.contains(ids[0]));
    try expect(ids[1].eql(.invalid));
    try expect(ids[2].eql(.invalid));
    try expectEqual(1, registry.len());
    try expectEqual(0, calls);
    registry.deinit();
    try expectEqual(1, calls);
}

test "addBatchImpl borrows runtime columns across chunks with zero sized sparse values" {
    const Wide = struct {
        pub const se_component: TestMark = .{};
        bytes: [1024]u8 align(64),
    };
    SparseTag.destroyed = 0;
    var registry = Self.init(std.testing.allocator);
    var values: [37]Wide = undefined;
    for (&values, 0..) |*value, i| @memset(&value.bytes, @intCast(i));
    const columns = [_]Column{
        .{ .id = try registry.comp_reg.register(SparseTag), .ptr = &.{} },
        .{ .id = try registry.comp_reg.register(Wide), .ptr = std.mem.sliceAsBytes(&values) },
    };
    for (0..2) |batch_index| {
        var ids: [37]Entity.Id = undefined;
        try registry.addBatchImpl(columns[1..], columns[0..1], &ids);
        const archetype = registry.arche_reg.getById(registry.get(ids[0]).?.archetype_id).?;
        const set = &registry.sparse_reg.getByTypeId(TypeId.of(SparseTag)).?.set;
        try expect(archetype.chunks.items.len > 1);
        for (ids, 0..) |id, i| {
            const row = registry.get(id).?.archetype_row;
            const value = archetype.typedAt(Wide, 0, row).ptr;
            try expectEqual(batch_index * ids.len + i, row);
            try expectEqual(values[i], value.*);
            try expectEqual(0, @intFromPtr(value) % 64);
            try expect(set.get(SparseTag, id) != null);
        }
    }
    registry.deinit();
    try expectEqual(74, SparseTag.destroyed);
}

test "add completes shared cyclic requirements and preserves explicit values" {
    const G = RequirementGraph;
    G.Right.calls = 0;
    G.Shared.created = 0;
    G.Shared.destroyed = 0;
    {
        const allocator = std.testing.allocator;
        var registry = Self.init(allocator);
        defer registry.deinit();
        _ = try registry.comp_reg.register(G.Root);
        _ = try registry.comp_reg.register(Health);
        _ = try registry.add(.{Health{ .value = 100 }});

        const first = try registry.add(.{
            G.Root{ .value = 1 },
            Health{ .value = 55 },
        });
        const second = try registry.add(.{
            G.Root{ .value = 2 },
            G.Left{ .value = 33 },
            G.Right{ .value = 44 },
            Health{ .value = 66 },
        });
        const a = registry.get(first).?;
        const b = registry.get(second).?;
        inline for (.{ G.Root, G.Left, G.Right, G.Shared, Health }) |T| {
            const id = registry.comp_reg.idOf(T).?;
            try expect(a.signature.has(id));
            try expect(b.signature.has(id));
        }
        const archetype = registry.arche_reg.getById(a.archetype_id).?;
        try testing.expectArchetypeValue(archetype, G.Root, a.archetype_row, .{ .value = 1 });
        try testing.expectArchetypeValue(archetype, G.Left, a.archetype_row, .{});
        try testing.expectArchetypeValue(archetype, G.Left, b.archetype_row, .{ .value = 33 });
        const right = &registry.sparse_reg.getByTypeId(TypeId.of(G.Right)).?.set;
        const health = &registry.sparse_reg.getByTypeId(TypeId.of(Health)).?.set;
        try expectEqual(22, right.get(G.Right, first).?.value);
        try expectEqual(44, right.get(G.Right, second).?.value);
        try expectEqual(55, health.get(Health, first).?.value);
        try expectEqual(66, health.get(Health, second).?.value);
        try expectEqual(1, G.Right.calls);
        try expectEqual(2, G.Shared.created);
        try expectEqual(0, G.Shared.destroyed);
    }
    try expectEqual(2, G.Shared.destroyed);
}

test "add destroys generated values but preserves input on layout failure" {
    const Huge = struct {
        pub const se_component: TestMark = .{ .require = &.{AutoRequirement} };
        calls: *usize,
        payload: [16 * 1024 + 1]u8 = undefined,

        pub fn deinit(self: *@This()) void {
            self.calls.* += 1;
        }
    };
    const allocator = std.testing.allocator;
    var registry = Self.init(allocator);
    defer registry.deinit();
    _ = try registry.comp_reg.register(Huge);
    AutoRequirement.created = 0;
    AutoRequirement.destroyed = 0;
    var calls: usize = 0;
    var value = Huge{ .calls = &calls };

    try expectError(error.BufferTooLarge, registry.add(.{value}));
    try expectEqual(0, calls);
    try expectEqual(1, AutoRequirement.created);
    try expectEqual(1, AutoRequirement.destroyed);
    try expectEqual(0, registry.entities.items.len);
    value.deinit();
    try expectEqual(1, calls);
}
