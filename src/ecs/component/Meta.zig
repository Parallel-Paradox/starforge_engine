//! Storage layout information for a component.

const std = @import("std");

const mod = @import("mod.zig");
const Storage = mod.Storage;
const Mark = mod.Mark;

const engine = @import("engine");
const reflect = engine.reflect;
const TypeId = reflect.TypeId;
const TypeMeta = reflect.TypeMeta;

type_meta: TypeMeta = .{},
storage: Storage = .archetype,

/// Builds the metadata of the component `T`.
/// `T` must declare `pub const se_component: Mark = .{};`.
pub fn of(comptime T: type) @This() {
    comptime mod.assertComponent(T, "Meta.of");
    return .{
        .type_meta = TypeMeta.of(T),
        .storage = T.se_component.storage,
    };
}

/// The unique id of the component type.
pub fn typeId(self: @This()) TypeId {
    return self.type_meta.id;
}

/// Whether both meta describe the same type and storage layout.
pub fn eql(self: @This(), other: @This()) bool {
    return self.typeId().eql(other.typeId()) and self.storage == other.storage;
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
    std.debug.assert(self.typeId().eql(TypeId.of(T)));
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

const Position = struct {
    pub const se_component: Mark = .{};
    x: i32,
    y: i32,
};

const Velocity = struct {
    pub const se_component: Mark = .{};
    dx: f32,
    dy: f32,
};

const Sparse = struct {
    pub const se_component: Mark = .{ .storage = .sparse_set };
    value: u32,
};

test "expose the type metadata" {
    const meta = of(Position);

    try expect(meta.typeId().eql(TypeId.of(Position)));
    try expectEqualStrings(@typeName(Position), meta.name());
    try expectEqual(@sizeOf(Position), meta.size());
    try expectEqual(std.mem.Alignment.of(Position), meta.alignment());
}

test "eql compares the type and storage" {
    const meta = of(Position);
    var custom = meta;
    custom.storage = .sparse_set;

    try expect(meta.eql(of(Position)));
    try expect(!meta.eql(of(Velocity)));
    try expect(!meta.eql(custom));
}

test "isComponent detects the se_component declaration" {
    try expect(mod.isComponent(Position));
    try expect(mod.isComponent(Sparse));
    try expect(!mod.isComponent(u32));
    try expect(!mod.isComponent(Mark));
}

test "callDeinit runs the managed deinit" {
    const Probe = struct {
        pub const se_component: Mark = .{};
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
    const Trivial = struct {
        pub const se_component: Mark = .{};
        value: u32,
    };

    var value = Trivial{ .value = 0 };
    const meta = of(Trivial);

    meta.callDeinit(Trivial, &value);
    meta.callDeinitErased(&value);
    try expectEqual(0, value.value);
}

test "of reads the storage layout from the mark" {
    try expectEqual(Storage.archetype, of(Position).storage);
    try expectEqual(Storage.sparse_set, of(Sparse).storage);

    // A missing or mistyped mark is a compile error:
    // _ = of(u32);
    // _ = of(struct { pub const se_component: u8 = 1; });
}
