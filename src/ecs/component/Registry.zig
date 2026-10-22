//! Map `TypeId` to `ComponentId` and `ComponentMeta`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const root = @import("root.zig");
const CompId = root.Id;
const CompMeta = root.Meta;

const se = root.super.super;
const reflect = se.reflect;
const TypeId = reflect.TypeId;

pub const Entry = struct {
    id: CompId = .invalid,
    meta: CompMeta = .{},
};

pub const RegisterError = Allocator.Error || error{
    /// The type is already registered with different metadata.
    ConflictingMeta,
};

type_to_comp: std.AutoHashMapUnmanaged(TypeId, CompId) = .empty,
meta_entries: std.ArrayList(Entry) = .empty,
retired_ids: std.ArrayList(CompId) = .empty,
allocator: Allocator,

pub fn init(allocator: Allocator) @This() {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *@This()) void {
    self.type_to_comp.deinit(self.allocator);
    self.meta_entries.deinit(self.allocator);
    self.retired_ids.deinit(self.allocator);
}

/// Registers `T` and returns its component id, or the existing one.
pub fn register(self: *@This(), comptime T: type) RegisterError!CompId {
    return self.registerMeta(CompMeta.of(T));
}

/// Registers `meta` and returns its component id, or the existing one.
pub fn registerMeta(self: *@This(), meta: CompMeta) RegisterError!CompId {
    const type_id = meta.typeId();
    if (self.type_to_comp.get(type_id)) |id| {
        if (!self.meta_entries.items[id.index.get()].meta.eql(meta)) {
            return RegisterError.ConflictingMeta;
        }
        return id;
    }

    if (self.retired_ids.items.len > 0) {
        const id = self.retired_ids.getLast();
        try self.type_to_comp.put(self.allocator, type_id, id);
        _ = self.retired_ids.pop();
        self.meta_entries.items[id.index.get()] = .{ .id = id, .meta = meta };
        return id;
    }

    const id = CompId.init(@intCast(self.meta_entries.items.len), 1);
    try self.meta_entries.ensureUnusedCapacity(self.allocator, 1);
    try self.type_to_comp.ensureUnusedCapacity(self.allocator, 1);

    self.meta_entries.appendAssumeCapacity(.{ .id = id, .meta = meta });
    self.type_to_comp.putAssumeCapacityNoClobber(type_id, id);
    return id;
}

/// Unregisters `type_id`, retiring its id for reuse.
/// Does nothing if not registered.
pub fn unregister(self: *@This(), type_id: TypeId) Allocator.Error!void {
    const id = self.type_to_comp.get(type_id) orelse return;
    try self.retired_ids.ensureUnusedCapacity(self.allocator, 1);

    _ = self.type_to_comp.remove(type_id);
    self.meta_entries.items[id.index.get()] = .{};
    self.retired_ids.appendAssumeCapacity(.{
        .index = id.index,
        .generation = id.generation.next(),
    });
}

/// Returns the metadata registered for `comp_id`, or null if it is unknown.
pub fn getMeta(self: *const @This(), comp_id: CompId) ?CompMeta {
    const index: usize = comp_id.index.tryGet() orelse return null;
    if (index >= self.meta_entries.items.len) return null;

    const entry = self.meta_entries.items[index];
    if (!entry.id.eql(comp_id)) return null;
    return entry.meta;
}

/// Returns the metadata registered for `type_id`, or null if it is unknown.
pub fn getMetaByType(self: *const @This(), type_id: TypeId) ?CompMeta {
    const comp_id = self.type_to_comp.get(type_id) orelse return null;
    return self.getMeta(comp_id);
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

const U32 = struct {
    pub const se_component: root.Mark = .{};
    value: u32,
};

const I32 = struct {
    pub const se_component: root.Mark = .{};
    value: i32,
};

test "register assigns one id per type" {
    var registry = init(std.testing.allocator);
    defer registry.deinit();

    const first = try registry.register(U32);
    const second = try registry.register(I32);

    try expectEqual(0, first.index.get());
    try expectEqual(1, second.index.get());
    try expectEqual(1, first.generation.get());

    try expect(first.eql(try registry.register(U32)));
    try expect(first.eql(try registry.registerMeta(CompMeta.of(U32))));
    try expect(!first.eql(second));
}

test "unregister retires the id for reuse" {
    var registry = init(std.testing.allocator);
    defer registry.deinit();

    try registry.unregister(TypeId.of(I32));

    const first = try registry.register(U32);
    try registry.unregister(TypeId.of(U32));

    const second = try registry.register(U32);
    try expectEqual(first.index.get(), second.index.get());
    try expectEqual(first.generation.get() + 1, second.generation.get());
    try expect(!first.eql(second));
}

test "getMeta looks up by component id and type id" {
    var registry = init(std.testing.allocator);
    defer registry.deinit();

    const id = try registry.register(U32);
    const meta = CompMeta.of(U32);

    try expect(meta.eql(registry.getMeta(id).?));
    try expect(meta.eql(registry.getMetaByType(TypeId.of(U32)).?));

    try expect(registry.getMeta(CompId.invalid) == null);
    try expect(registry.getMetaByType(TypeId.of(I32)) == null);

    try registry.unregister(TypeId.of(U32));
    try expect(registry.getMeta(id) == null);
    try expect(registry.getMetaByType(TypeId.of(U32)) == null);

    const reused = try registry.register(U32);
    try expect(registry.getMeta(id) == null);
    try expect(registry.getMeta(reused) != null);
}

test "registerMeta rejects conflicting metadata" {
    var registry = init(std.testing.allocator);
    defer registry.deinit();

    const meta = CompMeta.of(U32);
    _ = try registry.registerMeta(meta);

    var conflicting = meta;
    conflicting.storage = .sparse_set;

    try expectError(RegisterError.ConflictingMeta, registry.registerMeta(conflicting));
}
