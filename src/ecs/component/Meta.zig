//! Type, storage layout, direct requirements and default construction information for a component.

const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");

const mod = engine.ecs.component;
const Storage = mod.Storage;
const Mark = mod.Mark;
const Registry = mod.Registry;
const Id = mod.Id;

const reflect = engine.reflect;
const TypeId = reflect.TypeId;
const TypeMeta = reflect.TypeMeta;
const Default = reflect.Default;

pub const Error = Registry.RegisterError;

type_meta: TypeMeta = .{},
storage: Storage = .archetype,
/// Owned direct requirement IDs in declaration order; freed by `deinit`.
require: []Id = &.{},
/// Null when the component cannot be default-constructed.
default: ?Default = null,

/// Builds owned metadata of the component `T`; release it with `deinit`.
/// `T` must declare `pub const se_component: Mark = .{};`.
/// Reuses registered or reserved requirement IDs and registers missing types.
/// Successful dependency registrations remain in `comp_reg` if a later step fails.
pub fn init(
    comptime T: type,
    allocator: Allocator,
    comp_reg: *Registry,
) Error!@This() {
    comptime mod.assertComponent(T, "Meta.init");
    const require = try allocator.alloc(Id, T.se_component.require.len);
    errdefer allocator.free(require);
    inline for (T.se_component.require, 0..) |Req, i| {
        require[i] = comp_reg.getByType(Req) orelse try comp_reg.register(Req);
    }
    return .{
        .type_meta = TypeMeta.of(T),
        .storage = T.se_component.storage,
        .require = require,
        .default = Default.init(T),
    };
}

/// Frees owned requirements with the allocator used by `init` and resets metadata.
/// Do not call this on borrowed metadata returned by a registry.
pub fn deinit(self: *@This(), allocator: Allocator) void {
    allocator.free(self.require);
    self.* = .{};
}

/// The unique id of the component type.
pub fn typeId(self: @This()) TypeId {
    return self.type_meta.id;
}

/// Compares type, storage and ordered requirement IDs; ignores default construction.
pub fn eql(self: @This(), other: @This()) bool {
    if (!self.typeId().eql(other.typeId()) or self.storage != other.storage or
        self.require.len != other.require.len) return false;
    for (self.require, other.require) |a, b| {
        if (!a.eql(b)) return false;
    }
    return true;
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
const expectEqualDeep = std.testing.expectEqualDeep;
const checkAllAllocationFailures = std.testing.checkAllAllocationFailures;

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

const Middle = struct {
    pub const se_component: Mark = .{ .require = &.{Velocity} };
};

const Dependent = struct {
    pub const se_component: Mark = .{ .storage = .sparse_set, .require = &.{ Position, Middle } };
    value: u32 = 7,
};

test "init exposes type, storage and default construction metadata" {
    const Custom = struct {
        pub const se_component: Mark = .{};
        value: u32,

        pub fn default() @This() {
            return .{ .value = 42 };
        }
    };
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();
    var position = try init(Position, allocator, &registry);
    defer position.deinit(allocator);
    var dependent = try init(Dependent, allocator, &registry);
    defer dependent.deinit(allocator);
    var custom = try init(Custom, allocator, &registry);
    defer custom.deinit(allocator);

    try expect(position.typeId().eql(TypeId.of(Position)));
    try std.testing.expectEqualStrings(@typeName(Position), position.name());
    try expectEqual(@sizeOf(Position), position.size());
    try expectEqual(std.mem.Alignment.of(Position), position.alignment());
    try expectEqual(Storage.archetype, position.storage);
    try expect(position.default == null);
    try expectEqual(Storage.sparse_set, dependent.storage);
    try expectEqual(7, (try dependent.default.?.create(Dependent)).value);
    try expectEqual(42, (try custom.default.?.create(Custom)).value);
}

test "init resolves direct requirements, reuses ids and deinit resets metadata" {
    inline for (.{ false, true }) |registered| {
        const allocator = std.testing.allocator;
        var registry = Registry.init(allocator);
        defer registry.deinit();
        const position = if (registered)
            try registry.register(Position)
        else
            try registry.reserve(TypeId.of(Position));
        var meta = try init(Dependent, allocator, &registry);
        defer meta.deinit(allocator);

        const middle = registry.getByType(Middle).?;
        const velocity = registry.getByType(Velocity).?;
        try std.testing.expectEqualSlices(Id, &.{ position, middle }, meta.require);
        try expectEqual(registered, registry.getMeta(position) != null);
        try expect(registry.getMeta(middle).?.require[0].eql(velocity));
        try expect(registry.getMeta(velocity) != null);
        try expect(registry.getByType(Dependent) == null);
        try expectEqual(3, registry.type_to_id.count());
        meta.deinit(allocator);
        try expectEqualDeep(@This(){}, meta);
    }
}

test "eql compares type, storage and ordered requirement contents but ignores defaults" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();
    var first = try init(Dependent, allocator, &registry);
    defer first.deinit(allocator);
    var second = try init(Dependent, allocator, &registry);
    defer second.deinit(allocator);

    try expect(first.require.ptr != second.require.ptr);
    try expect(first.eql(second));
    var changed = first;
    changed.default = null;
    try expect(first.eql(changed));
    changed.type_meta.id = TypeId.of(Position);
    try expect(!first.eql(changed));
    changed = first;
    changed.storage = .archetype;
    try expect(!first.eql(changed));
    changed = first;
    changed.require = first.require[0..1];
    try expect(!first.eql(changed));
    std.mem.swap(Id, &second.require[0], &second.require[1]);
    try expect(!first.eql(second));
    second.require[0] = first.require[0];
    try expect(!first.eql(second));
}

test "callDeinit handles managed and trivial components" {
    const Probe = struct {
        pub const se_component: Mark = .{};
        calls: *usize,

        pub fn deinit(self: *@This()) void {
            self.calls.* += 1;
        }
    };
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();
    var managed = try init(Probe, allocator, &registry);
    defer managed.deinit(allocator);
    var trivial = try init(Position, allocator, &registry);
    defer trivial.deinit(allocator);

    var calls: usize = 0;
    var probe: Probe = .{ .calls = &calls };
    managed.callDeinit(Probe, &probe);
    managed.callDeinitErased(&probe);
    try expectEqual(2, calls);
    var position: Position = .{ .x = 1, .y = 2 };
    trivial.callDeinit(Position, &position);
    trivial.callDeinitErased(&position);
    try expectEqualDeep(Position{ .x = 1, .y = 2 }, position);
}

test "init registers cyclic requirements" {
    const Cycle = struct {
        const A = struct {
            pub const se_component: Mark = .{ .require = &.{B} };
        };
        const B = struct {
            pub const se_component: Mark = .{ .require = &.{A} };
        };
    };
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();
    var meta = try init(Cycle.A, allocator, &registry);
    defer meta.deinit(allocator);

    const a = registry.getByType(Cycle.A).?;
    const b = registry.getByType(Cycle.B).?;
    try expect(meta.require[0].eql(b));
    try expect(meta.eql(registry.getMeta(a).?));
    try expect(registry.getMeta(b).?.require[0].eql(a));
    try expectEqual(2, registry.type_to_id.count());
}

fn testInitAllocationFailures(allocator: Allocator) !void {
    var registry = Registry.init(allocator);
    defer registry.deinit();
    var meta = init(Dependent, allocator, &registry) catch |err| {
        inline for (.{ Position, Middle, Velocity }) |Req| {
            if (registry.getByType(Req)) |id| try expect(registry.getMeta(id) != null);
        }
        return err;
    };
    defer meta.deinit(allocator);

    try expect(meta.require[0].eql(registry.getByType(Position).?));
    try expect(meta.require[1].eql(registry.getByType(Middle).?));
    try expect(registry.getMetaByType(TypeId.of(Velocity)) != null);
}

test "init cleans up when allocating or registering requirements fails" {
    try checkAllAllocationFailures(std.testing.allocator, testInitAllocationFailures, .{});
}
