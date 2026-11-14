//! Map `TypeId` to `ComponentId` and `ComponentMeta`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const component = engine.ecs.component;
const CompId = component.Id;
const CompMeta = component.Meta;
const CompMark = component.Mark;

const reflect = engine.reflect;
const TypeId = reflect.TypeId;

pub const Entry = struct {
    id: CompId = .invalid,
    /// An invalid metadata type id means the entry is only reserved.
    meta: CompMeta = .{},
};

pub const RegisterError = Allocator.Error || TypeId.ValidateError || error{
    /// The type is already registered with different metadata.
    ConflictingMeta,
    /// A requirement is unknown, stale, duplicated, or refers to the component itself.
    InvalidRequirement,
};

pub const UnregisterError = Allocator.Error || error{
    /// Another component still requires this id.
    ComponentRequired,
};

type_to_id: std.AutoHashMapUnmanaged(TypeId, CompId) = .empty,
entries: std.ArrayList(Entry) = .empty,
retired: std.ArrayList(CompId) = .empty,
allocator: Allocator,

pub fn init(allocator: Allocator) @This() {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *@This()) void {
    for (self.entries.items) |*entry| entry.meta.deinit(self.allocator);
    self.type_to_id.deinit(self.allocator);
    self.entries.deinit(self.allocator);
    self.retired.deinit(self.allocator);
}

/// Registers `T` and its requirement closure, returning `T`'s component id.
/// All ids are reserved before metadata is built, so dependency cycles are supported.
/// On failure, existing registrations and reservations are left unchanged.
pub fn register(self: *@This(), comptime T: type) RegisterError!CompId {
    const types = comptime [1]type{T} ++ component.requireClosure(T);
    const entries_len = self.entries.items.len;
    var added: [types.len]TypeId = undefined;
    var added_count: usize = 0;
    errdefer {
        var i = added_count;
        while (i > 0) {
            i -= 1;
            const type_id = added[i];
            const id = self.idOfTypeId(type_id).?;
            const entry = &self.entries.items[id.index.get()];
            _ = self.type_to_id.remove(type_id);
            entry.meta.deinit(self.allocator);
            entry.* = .{};
            // Restore reused ids in reverse reservation order, without allocating.
            if (id.index.get() < entries_len) self.retired.appendAssumeCapacity(id);
        }
        self.entries.shrinkRetainingCapacity(entries_len);
    }

    inline for (types) |U| {
        if (self.idOf(U) == null) {
            const type_id = TypeId.of(U);
            _ = try self.reserve(type_id);
            added[added_count] = type_id;
            added_count += 1;
        }
    }

    var meta_list: [types.len]CompMeta = undefined;
    var meta_count: usize = 0;
    defer for (meta_list[0..meta_count]) |*meta| meta.deinit(self.allocator);
    inline for (types) |U| {
        meta_list[meta_count] = try CompMeta.init(U, self.allocator, self);
        meta_count += 1;
        const entry = self.entries.items[self.idOf(U).?.index.get()];
        if (entry.meta.typeId().isValid() and !entry.meta.eql(meta_list[meta_count - 1])) {
            return RegisterError.ConflictingMeta;
        }
    }

    // Nothing below can fail; publish metadata only after every component is ready.
    inline for (types, 0..) |U, i| {
        const entry = &self.entries.items[self.idOf(U).?.index.get()];
        if (!entry.meta.typeId().isValid()) {
            entry.meta = meta_list[i];
            meta_list[i] = .{};
        }
    }
    return self.idOf(T).?;
}

/// Reserves an id for `type_id`, or returns its existing id.
/// `idOf` and `idOfTypeId` can see reservations; metadata lookup return null until `registerMeta`.
/// Runtime callers can reserve every type first, then register metadata containing cycles.
pub fn reserve(self: *@This(), type_id: TypeId) Allocator.Error!CompId {
    if (self.type_to_id.get(type_id)) |id| return id;

    if (self.retired.items.len > 0) {
        const id = self.retired.getLast();
        try self.type_to_id.put(self.allocator, type_id, id);
        _ = self.retired.pop();
        self.entries.items[id.index.get()] = .{ .id = id };
        return id;
    }

    const id = CompId.init(self.entries.items.len, 0);
    try self.entries.ensureUnusedCapacity(self.allocator, 1);
    try self.type_to_id.ensureUnusedCapacity(self.allocator, 1);

    self.entries.appendAssumeCapacity(.{ .id = id });
    self.type_to_id.putAssumeCapacityNoClobber(type_id, id);
    return id;
}

/// Registers `meta` and returns its component id, or the existing one.
/// Requirements must refer to ids reserved in this registry; metadata may still be pending.
/// Copies the requirement array. The caller retains ownership of `meta` on every path.
pub fn registerMeta(self: *@This(), meta: CompMeta) RegisterError!CompId {
    const type_id = meta.typeId();
    try type_id.validate();
    const own_id = self.idOfTypeId(type_id) orelse CompId.invalid;
    for (meta.require, 0..) |required, i| {
        const index: usize = required.index.tryGet() orelse return RegisterError.InvalidRequirement;
        if (index >= self.entries.items.len) return RegisterError.InvalidRequirement;
        const entry = self.entries.items[index];
        if (!entry.id.eql(required) or required.eql(own_id)) {
            return RegisterError.InvalidRequirement;
        }
        for (meta.require[0..i]) |previous| {
            if (previous.eql(required)) return RegisterError.InvalidRequirement;
        }
    }

    if (self.type_to_id.get(type_id)) |id| {
        const entry = self.entries.items[id.index.get()];
        if (entry.meta.typeId().isValid()) {
            if (!entry.meta.eql(meta)) return RegisterError.ConflictingMeta;
            return id;
        }
    }

    var owned = meta;
    owned.require = try self.allocator.dupe(CompId, meta.require);
    errdefer owned.deinit(self.allocator);
    const id = try self.reserve(type_id);
    self.entries.items[id.index.get()] = .{ .id = id, .meta = owned };
    return id;
}

/// Unregisters `type_id`, retiring its id for reuse.
/// Does nothing if unknown. Rejects ids still required by another component.
pub fn unregister(self: *@This(), type_id: TypeId) UnregisterError!void {
    const id = self.type_to_id.get(type_id) orelse return;
    for (self.entries.items) |entry| {
        for (entry.meta.require) |required| {
            if (required.eql(id)) return UnregisterError.ComponentRequired;
        }
    }
    try self.retired.ensureUnusedCapacity(self.allocator, 1);

    _ = self.type_to_id.remove(type_id);
    self.entries.items[id.index.get()].meta.deinit(self.allocator);
    self.entries.items[id.index.get()] = .{};
    self.retired.appendAssumeCapacity(id.nextGeneration());
}

/// Returns the component id registered or reserved for `T`, or null if unknown.
pub fn idOf(self: *const @This(), comptime T: type) ?CompId {
    return self.idOfTypeId(TypeId.of(T));
}

/// Returns the component id registered or reserved for `type_id`, or null if unknown.
pub fn idOfTypeId(self: *const @This(), type_id: TypeId) ?CompId {
    return self.type_to_id.get(type_id);
}

/// Borrows the metadata for `T`, or returns null if unknown.
pub fn get(self: *const @This(), comptime T: type) ?*const CompMeta {
    return self.getByTypeId(TypeId.of(T));
}

/// Returns borrowed metadata, or null if the id is unknown, stale, or only reserved.
pub fn getById(self: *const @This(), comp_id: CompId) ?*const CompMeta {
    const index: usize = comp_id.index.tryGet() orelse return null;
    if (index >= self.entries.items.len) return null;

    const entry = &self.entries.items[index];
    if (!entry.id.eql(comp_id) or !entry.meta.typeId().isValid()) return null;
    return &entry.meta;
}

/// Borrows the metadata for `type_id`, or returns null if unknown.
pub fn getByTypeId(self: *const @This(), type_id: TypeId) ?*const CompMeta {
    const comp_id = self.idOfTypeId(type_id) orelse return null;
    return self.getById(comp_id);
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;
const checkAllAllocationFailures = std.testing.checkAllAllocationFailures;

const U32 = struct {
    pub const se_component: CompMark = .{};
    value: u32,
};

const I32 = struct {
    pub const se_component: CompMark = .{};
    value: i32,
};

test "registration is idempotent, supports lookup and reuses ids with new generations" {
    var registry = init(std.testing.allocator);
    defer registry.deinit();

    try registry.unregister(TypeId.of(I32));
    try expect(registry.idOf(I32) == null);
    try expect(registry.idOfTypeId(TypeId.of(I32)) == null);
    try expect(registry.idOfTypeId(TypeId.invalid) == null);
    try expect(registry.getById(CompId.invalid) == null);
    try expect(registry.get(I32) == null);

    const id = try registry.register(U32);
    const other = try registry.register(I32);
    try expectEqual(0, id.index.get());
    try expectEqual(1, other.index.get());
    try expectEqual(0, id.generation.get());
    try expect(!id.eql(other));
    try expect(id.eql(try registry.register(U32)));
    try expect(id.eql(registry.idOf(U32).?));
    try expect(id.eql(registry.idOfTypeId(TypeId.of(U32)).?));
    var meta = try CompMeta.init(U32, std.testing.allocator, &registry);
    defer meta.deinit(std.testing.allocator);
    try expect(id.eql(try registry.registerMeta(meta)));
    const stored = registry.getById(id).?;
    try expect(stored == &registry.entries.items[id.index.get()].meta);
    try expect(stored == registry.get(U32).?);
    try expect(stored == registry.getByTypeId(TypeId.of(U32)).?);
    try expect(meta.eql(stored.*));

    try registry.unregister(TypeId.of(U32));
    try expect(registry.idOf(U32) == null);
    try expect(registry.idOfTypeId(TypeId.of(U32)) == null);
    try expect(registry.getById(id) == null);
    try expect(registry.get(U32) == null);
    const reused = try registry.register(U32);
    try expectEqual(id.index.get(), reused.index.get());
    try expectEqual(id.generation.get() + 1, reused.generation.get());
    try expect(!id.eql(reused));
    try expect(registry.getById(id) == null);
    try expect(registry.getById(reused) != null);
}

const Graph = struct {
    const D = struct {
        pub const se_component: CompMark = .{};
    };
    const B = struct {
        pub const se_component: CompMark = .{ .require = &.{D} };
    };
    const C = struct {
        pub const se_component: CompMark = .{ .require = &.{D} };
    };
    const A = struct {
        pub const se_component: CompMark = .{ .require = &.{ B, C } };
    };
};

test "register resolves the full graph but stores only direct requirements" {
    var registry = init(std.testing.allocator);
    defer registry.deinit();

    const a = try registry.register(Graph.A);
    const b = registry.idOf(Graph.B).?;
    const c = registry.idOf(Graph.C).?;
    const d = registry.idOf(Graph.D).?;
    const requirements = registry.getById(a).?.require;
    try expectEqualSlices(CompId, &.{ b, c }, requirements);
    try expectEqualSlices(CompId, &.{d}, registry.getById(b).?.require);
    try expectEqualSlices(CompId, &.{d}, registry.getById(c).?.require);
    try expectEqual(0, registry.getById(d).?.require.len);
    try expectEqual(4, registry.type_to_id.count());

    try expect(a.eql(try registry.register(Graph.A)));
    try expect(requirements.ptr == registry.getById(a).?.require.ptr);
}

test "register supports cycles without exposing incomplete metadata" {
    const Cycle = struct {
        const A = struct {
            pub const se_component: CompMark = .{ .require = &.{B} };
        };
        const B = struct {
            pub const se_component: CompMark = .{ .require = &.{C} };
        };
        const C = struct {
            pub const se_component: CompMark = .{ .require = &.{A} };
        };
    };
    var registry = init(std.testing.allocator);
    defer registry.deinit();

    const a = try registry.reserve(TypeId.of(Cycle.A));
    try expect(registry.getById(a) == null);
    try expect(a.eql(try registry.register(Cycle.A)));
    const b = registry.idOf(Cycle.B).?;
    const c = registry.idOf(Cycle.C).?;
    try expect(registry.getById(a).?.require[0].eql(b));
    try expect(registry.getById(b).?.require[0].eql(c));
    try expect(registry.getById(c).?.require[0].eql(a));
    try expect(b.eql(try registry.register(Cycle.B)));
}

test "runtime registration resolves reserved ids and owns requirement copies" {
    var registry = init(std.testing.allocator);
    defer registry.deinit();

    const a = try registry.reserve(TypeId.of(U32));
    const b = try registry.reserve(TypeId.of(I32));
    try expect(a.eql(try registry.reserve(TypeId.of(U32))));
    try expect(registry.getById(a) == null);
    try expect(registry.get(I32) == null);

    var requirements = [_]CompId{b};
    const meta: CompMeta = .{ .type_meta = reflect.TypeMeta.of(U32), .require = &requirements };
    try expect(a.eql(try registry.registerMeta(meta)));
    try expect(registry.get(I32) == null);
    requirements[0] = a;
    try expect(registry.getById(a).?.require[0].eql(b));
    _ = try registry.registerMeta(.{
        .type_meta = reflect.TypeMeta.of(I32),
        .require = &requirements,
    });
    try expect(registry.getById(b).?.require[0].eql(a));

    requirements[0] = b;
    try expect(a.eql(try registry.registerMeta(meta)));
}

test "registerMeta rejects invalid type ids, requirements and metadata conflicts" {
    var registry = init(std.testing.allocator);
    defer registry.deinit();

    try expectError(error.InvalidAddress, registry.registerMeta(.{}));
    try expectEqual(0, registry.type_to_id.count());
    const a = try registry.reserve(TypeId.of(U32));
    const b = try registry.register(I32);
    var requirements = [_]CompId{ b, b };
    var meta: CompMeta = .{ .type_meta = reflect.TypeMeta.of(U32), .require = &requirements };
    try expectError(RegisterError.InvalidRequirement, registry.registerMeta(meta));
    meta.require = requirements[0..1];
    for ([_]CompId{
        CompId.invalid,
        CompId.init(100, 0),
        CompId.init(b.index.get(), b.generation.get() + 1),
        a,
    }) |invalid| {
        requirements[0] = invalid;
        try expectError(RegisterError.InvalidRequirement, registry.registerMeta(meta));
    }
    try expect(registry.getById(a) == null);

    requirements[0] = b;
    _ = try registry.registerMeta(meta);
    var conflicting = meta;
    conflicting.storage = .sparse_set;
    try expectError(RegisterError.ConflictingMeta, registry.registerMeta(conflicting));
    meta.require = &.{};
    try expectError(RegisterError.ConflictingMeta, registry.registerMeta(meta));
}

test "unregister protects required ids and frees dependency metadata" {
    var registry = init(std.testing.allocator);
    defer registry.deinit();

    _ = try registry.register(Graph.B);
    const old_d = registry.idOf(Graph.D).?;
    try expectError(UnregisterError.ComponentRequired, registry.unregister(TypeId.of(Graph.D)));
    try expect(registry.getById(old_d) != null);
    try registry.unregister(TypeId.of(Graph.B));
    try registry.unregister(TypeId.of(Graph.D));

    _ = try registry.register(Graph.B);
    const new_d = registry.idOf(Graph.D).?;
    try expect(!old_d.eql(new_d));
    const new_b = registry.idOf(Graph.B).?;
    try expect(registry.getById(new_b).?.require[0].eql(new_d));
}

test "register rolls back new reservations on metadata conflicts" {
    var registry = init(std.testing.allocator);
    defer registry.deinit();

    const a = try registry.registerMeta(.{
        .type_meta = reflect.TypeMeta.of(Graph.A),
        .storage = .sparse_set,
    });
    try expectError(RegisterError.ConflictingMeta, registry.register(Graph.A));
    try expectEqual(1, registry.entries.items.len);
    try expectEqual(1, registry.type_to_id.count());
    try expectEqual(component.Storage.sparse_set, registry.getById(a).?.storage);
    try expect(registry.idOf(Graph.B) == null);
    try expect(registry.idOf(Graph.C) == null);
    try expect(registry.idOf(Graph.D) == null);
}

fn testRegisterAllocationFailures(allocator: Allocator) !void {
    var registry = init(allocator);
    defer registry.deinit();

    const Extra = struct {
        pub const se_component: CompMark = .{};
    };
    const existing = try registry.register(U32);
    _ = try registry.register(I32);
    _ = try registry.register(Extra);
    const reserved = try registry.reserve(TypeId.of(Graph.B));
    try registry.unregister(TypeId.of(I32));
    try registry.unregister(TypeId.of(Extra));
    const retired = registry.retired.getLast();
    const first_retired = registry.retired.items[0];
    const entries_len = registry.entries.items.len;

    const a = registry.register(Graph.A) catch |err| {
        try expectEqual(entries_len, registry.entries.items.len);
        try expectEqual(2, registry.type_to_id.count());
        try expectEqual(2, registry.retired.items.len);
        try expect(registry.retired.items[0].eql(first_retired));
        try expect(registry.retired.getLast().eql(retired));
        try expect(registry.getById(existing) != null);
        try expect(registry.idOf(Graph.B).?.eql(reserved));
        try expect(registry.getById(reserved) == null);
        try expect(registry.idOf(Graph.A) == null);
        try expect(registry.idOf(Graph.C) == null);
        try expect(registry.idOf(Graph.D) == null);
        return err;
    };
    try expect(a.eql(retired));
    try expect(registry.getById(reserved) != null);
}

fn testRegisterMetaAllocationFailures(allocator: Allocator) !void {
    var registry = init(allocator);
    defer registry.deinit();

    const dependency = try registry.reserve(TypeId.of(I32));
    var requirements = [_]CompId{dependency};
    const meta: CompMeta = .{ .type_meta = reflect.TypeMeta.of(U32), .require = &requirements };
    const id = registry.registerMeta(meta) catch |err| {
        try expectEqual(1, registry.type_to_id.count());
        try expect(registry.idOf(U32) == null);
        try expect(registry.idOf(I32).?.eql(dependency));
        try expect(registry.getById(dependency) == null);
        try expect(requirements[0].eql(dependency));
        return err;
    };
    try expect(registry.getById(id).?.require[0].eql(dependency));
}

test "allocation failures preserve ready and pending entries, retired id order and borrowed input" {
    try checkAllAllocationFailures(std.testing.allocator, testRegisterAllocationFailures, .{});
    try checkAllAllocationFailures(std.testing.allocator, testRegisterMetaAllocationFailures, .{});
}
