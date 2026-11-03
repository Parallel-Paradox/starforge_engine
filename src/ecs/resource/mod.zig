//! World-owned resources marked with `se_resource: Mark`.
//! Default construction follows `reflect.Default`: `pub fn default() T`, otherwise
//! struct field defaults. Destruction follows `reflect.TypeMeta`: only a public
//! `fn deinit(self: *T) void` is called automatically; other types are treated as trivial.

const engine = @import("engine");
const World = engine.ecs.World;

pub const Id = engine.ecs.Id;
pub const Registry = @import("Registry.zig");

/// Declare `pub const se_resource: Mark = .{};` in a type to mark it as a resource.
pub const Mark = struct {};

/// Whether `T` declares a resource marker of type `Mark`.
pub fn isResource(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => return false,
    }
    if (comptime @hasDecl(T, "se_resource")) {
        return @TypeOf(T.se_resource) == Mark;
    }
    return false;
}

/// Asserts that `T` is a resource, naming the requiring operation when provided.
pub fn assertResource(comptime T: type, comptime context: ?[]const u8) void {
    if (comptime !isResource(T)) @compileError(
        (context orelse "assertResource") ++ " requires a resource type, got " ++
            @typeName(T) ++ "; declare `pub const se_resource: Mark = .{};`",
    );
}

/// A system parameter borrowing a required resource through `*const T`.
pub fn Res(comptime T: type) type {
    return ResourceParam(T, false);
}

/// A system parameter borrowing a required resource through `*T`.
pub fn ResMut(comptime T: type) type {
    return ResourceParam(T, true);
}

fn ResourceParam(comptime T: type, comptime mutable: bool) type {
    const name = if (mutable) "ResMut" else "Res";
    assertResource(T, name);
    return struct {
        ptr: if (mutable) *T else *const T,

        /// Borrows the current resource without constructing or registering it.
        /// Panics if it is absent. Uses the parameter protocol's default World context.
        pub fn extract(world: *World) error{}!@This() {
            return .{ .ptr = world.getResource(T) orelse @panic(
                name ++ "(" ++ @typeName(T) ++
                    ") requires a resource that is not present in the world",
            ) };
        }
    };
}

test {
    _ = Registry;
}

test "resource parameters borrow shared storage and extract current values" {
    const testing = @import("std").testing;
    const param = engine.ecs.system.param;
    const Counter = struct {
        pub const se_resource: Mark = .{};
        value: u32,
    };
    var world = World.init(testing.allocator);
    defer world.deinit();
    _ = try world.insertResource(Counter{ .value = 1 });

    try testing.expect(param.Context(Res(Counter)) == World);
    try testing.expect(param.Context(ResMut(Counter)) == World);
    const read = try param.extractParam(Res(Counter), &world);
    const write = try param.extractParam(ResMut(Counter), &world);
    try testing.expect(@TypeOf(read.ptr) == *const Counter);
    try testing.expect(@TypeOf(write.ptr) == *Counter);
    try testing.expect(read.ptr == write.ptr);
    try testing.expect(write.ptr == world.getResource(Counter).?);
    write.ptr.value += 1;
    try testing.expectEqual(2, read.ptr.value);

    _ = try world.insertResource(Counter{ .value = 7 });
    inline for (.{ Res(Counter), ResMut(Counter) }) |P| {
        const current = try P.extract(&world);
        try testing.expectEqual(7, current.ptr.value);
    }
    try testing.expect(world.removeResource(Counter));
    _ = try world.insertResource(Counter{ .value = 11 });
    inline for (.{ Res(Counter), ResMut(Counter) }) |P| {
        const current = try P.extract(&world);
        try testing.expectEqual(11, current.ptr.value);
    }
}

test "resource markers must have type Mark" {
    const std = @import("std");
    const Good = struct {
        pub const se_resource: Mark = .{};
    };
    const Wrong = struct {
        pub const se_resource = true;
    };

    assertResource(Good, null);
    try std.testing.expect(!isResource(Wrong));
    try std.testing.expect(!isResource(struct {}));
    try std.testing.expect(!isResource(u32));
}
