//! World-owned resources marked with `se_resource: Mark`.
//! Default construction follows `reflect.Default`: `pub fn default() T`, otherwise
//! struct field defaults. Destruction follows `reflect.TypeMeta`: only a public
//! `fn deinit(self: *T) void` is called automatically; other types are treated as trivial.

const engine = @import("engine");
const World = engine.ecs.World;
const Access = engine.ecs.system.Access;

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
    const missing = name ++ "(" ++ @typeName(T) ++
        ") requires a resource that is not present in the world";
    assertResource(T, name);
    return struct {
        ptr: if (mutable) *T else *const T,

        pub const access: Access.Spec = .{ .shared = .{ .resources = &.{
            .{ .target = T, .mode = if (mutable) .write else .read },
        } } };

        /// Caches the resource ID so runs skip the type-to-ID hash lookup.
        pub const Context = struct {
            world: *World,
            id: Id,

            pub fn init(world: *World) @This() {
                return .{
                    .world = world,
                    .id = world.resReg().idOf(T) orelse @panic(missing),
                };
            }
        };

        /// Borrows the current resource through the context's cached ID.
        /// Panics if it is absent.
        pub fn extract(ctx: *Context) error{}!@This() {
            const bytes = ctx.world.resReg().getById(ctx.id) orelse @panic(missing);
            const ptr: if (mutable) *T else *const T = @ptrCast(@alignCast(bytes.ptr));
            return .{ .ptr = ptr };
        }
    };
}

test {
    _ = Registry;
}

test "resource parameters cache their id and borrow shared storage" {
    const testing = @import("std").testing;
    const param = engine.ecs.system.param;
    const Counter = struct {
        pub const se_resource: Mark = .{};
        value: u32,
    };
    inline for (
        .{ Res(Counter), ResMut(Counter) },
        [_]Access.Mode{ .read, .write },
    ) |P, mode| {
        const spec = comptime param.access(P);
        try testing.expectEqual(0, spec.shared.components.entries.len);
        try testing.expectEqual(1, spec.shared.resources.len);
        const entry = spec.shared.resources[0];
        try testing.expect(entry.target == Counter);
        try testing.expectEqual(mode, entry.mode);
    }

    var world = World.init(testing.allocator, testing.io);
    defer world.deinit();
    const id = try world.insertResource(Counter{ .value = 1 });

    const ReadCtx = param.Context(Res(Counter));
    const WriteCtx = param.Context(ResMut(Counter));
    try testing.expect(ReadCtx != World);
    try testing.expect(WriteCtx != World);

    var read_ctx = ReadCtx.init(&world);
    var write_ctx = WriteCtx.init(&world);
    try testing.expect(read_ctx.id.eql(id));
    try testing.expect(write_ctx.id.eql(id));

    const read = try param.extractParam(Res(Counter), &read_ctx);
    const write = try param.extractParam(ResMut(Counter), &write_ctx);
    try testing.expect(@TypeOf(read.ptr) == *const Counter);
    try testing.expect(@TypeOf(write.ptr) == *Counter);
    try testing.expect(read.ptr == write.ptr);
    try testing.expect(write.ptr == world.getResource(Counter).?);
    write.ptr.value += 1;
    try testing.expectEqual(2, read.ptr.value);

    // Replacing a resource keeps its id, so cached contexts stay valid.
    _ = try world.insertResource(Counter{ .value = 7 });
    const replaced = try param.extractParam(Res(Counter), &read_ctx);
    try testing.expectEqual(7, replaced.ptr.value);

    // Removing retires the id; a fresh context resolves the reinserted one.
    const stale = read_ctx.id;
    try testing.expect(world.removeResource(Counter));
    _ = try world.insertResource(Counter{ .value = 11 });
    try testing.expect(world.resReg().getById(stale) == null);

    inline for (.{ Res(Counter), ResMut(Counter) }) |P| {
        var ctx = param.Context(P).init(&world);
        const current = try param.extractParam(P, &ctx);
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
