//! Storage layout information for a component.

const std = @import("std");

const root = @import("root.zig");
const Storage = root.Storage;

const se = root.super.super;
const reflect = se.reflect;
const TypeId = reflect.TypeId;
const TypeMeta = reflect.TypeMeta;

type_meta: TypeMeta,
storage: Storage = .archetype,

/// Builds the metadata of `T`.
/// A `pub const storage` of type `Storage` overrides the default layout.
pub fn of(comptime T: type) @This() {
    return .{
        .type_meta = TypeMeta.of(T),
        .storage = storageOf(T),
    };
}

fn storageOf(comptime T: type) Storage {
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => return .archetype,
    }
    if (!@hasDecl(T, "storage")) return .archetype;

    const custom = T.storage;
    return if (@TypeOf(custom) == Storage) custom else .archetype;
}

/// The unique id of the component type.
pub fn type_id(self: @This()) TypeId {
    return self.type_meta.id;
}

/// The fully qualified name of the component type.
pub fn name(self: @This()) []const u8 {
    return self.type_meta.name;
}

/// The size of the component type in bytes.
pub fn size(self: @This()) usize {
    return self.type_meta.size;
}

/// The alignment of the component type.
pub fn alignment(self: @This()) std.mem.Alignment {
    return self.type_meta.alignment;
}

/// Runs `deinit` on `ptr`, asserting it is a `T`.
pub fn callDeinit(self: @This(), comptime T: type, ptr: *T) void {
    std.debug.assert(self.type_id().eql(TypeId.of(T)));
    self.callDeinitErased(ptr);
}

/// Runs the component's `deinit` on a type-erased pointer.
pub fn callDeinitErased(self: @This(), ptr: *anyopaque) void {
    switch (self.type_meta.need_deinit) {
        .trivial => {},
        .managed => |deinit_fn| deinit_fn(ptr),
    }
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "expose the type metadata" {
    const meta = of(u32);

    try expect(meta.type_id().eql(TypeId.of(u32)));
    try expectEqualStrings("u32", meta.name());
    try expectEqual(@sizeOf(u32), meta.size());
    try expectEqual(std.mem.Alignment.of(u32), meta.alignment());
}

test "callDeinit runs the managed deinit" {
    const Probe = struct {
        calls: *usize,

        pub fn deinit(self: *@This()) void {
            self.calls.* += 1;
        }
    };

    var calls: usize = 0;
    var probe = Probe{ .calls = &calls };
    const meta = of(Probe);

    meta.callDeinit(Probe, &probe);
    meta.callDeinitErased(&probe);
    try expectEqual(2, calls);
}

test "callDeinit is a no-op for trivial types" {
    var value: u32 = 0;
    const meta = of(u32);

    meta.callDeinit(u32, &value);
    meta.callDeinitErased(&value);
    try expectEqual(0, value);
}

test "of resolves the storage layout" {
    try expectEqual(Storage.archetype, of(u32).storage);

    const Sparse = struct {
        pub const storage: Storage = .sparse_set;
    };
    try expectEqual(Storage.sparse_set, of(Sparse).storage);

    const Wrong = struct {
        pub const storage: u8 = 1;
    };
    try expectEqual(Storage.archetype, of(Wrong).storage);
}
