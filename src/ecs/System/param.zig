const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const World = engine.ecs.World;
const query = engine.ecs.query;
const System = engine.ecs.System;

/// The storage a parameter keeps between extractions; `World` when it needs
/// none, including for parameters that are not declarations-bearing types.
///
/// A parameter's declared `Context` must provide `init(*World)` returning itself.
pub fn Context(comptime P: type) type {
    if (P == Allocator or P == std.Io) return World;
    switch (@typeInfo(P)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {
            if (@hasDecl(P, "Context")) {
                assertContext(P.Context);
                return P.Context;
            }
        },
        else => {},
    }
    return World;
}

/// Asserts that the context type `C` declares `init(*World)` returning it.
fn assertContext(comptime C: type) void {
    if (!@hasDecl(C, "init")) {
        @compileError(@typeName(C) ++ " must declare init(*World)");
    }

    switch (@typeInfo(@TypeOf(C.init))) {
        .@"fn" => |info| {
            if (info.param_types.len != 1) {
                @compileError(@typeName(C) ++ ".init must take a single *World");
            }
            const param = info.param_types[0] orelse
                @compileError(@typeName(C) ++ ".init must take a *World");
            if (param != *World) {
                @compileError(@typeName(C) ++ ".init must take a *World");
            }

            const ret = info.return_type orelse
                @compileError(@typeName(C) ++ ".init must return " ++ @typeName(C));
            if (ret != C) {
                @compileError(@typeName(C) ++ ".init must return " ++ @typeName(C));
            }
        },
        else => @compileError(@typeName(C) ++ ".init must be a function"),
    }
}

/// Asserts that `P` is a valid system parameter.
///
/// `*World`, `Allocator`, and `Io` are accepted directly. Other parameters must
/// provide `extract`. Declared contexts must satisfy `assertContext`, and access
/// declarations must have type `System.Access.Spec`.
pub fn assertParam(comptime P: type) void {
    if (P == *World or P == Allocator or P == std.Io) return;

    const has_extract = switch (@typeInfo(P)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(P, "extract"),
        else => false,
    };
    if (!has_extract) {
        @compileError(@typeName(P) ++ " is not a system parameter; " ++
            "expected *World, Allocator, Io, or a type declaring `extract`");
    }

    if (@hasDecl(P, "Context")) assertContext(P.Context);
    if (@hasDecl(P, "access")) {
        if (@TypeOf(P.access) != System.Access.Spec) {
            @compileError(@typeName(P) ++ ".access must have type System.Access.Spec");
        }
    }
}

/// Returns a parameter's comptime access declaration without extracting it.
/// Missing declarations are exclusive; `.none` must be declared explicitly.
pub fn access(comptime P: type) System.Access.Spec {
    assertParam(P);
    if (P == *World) return .exclusive;
    if (P == Allocator or P == std.Io) return .none;
    if (@hasDecl(P, "access")) return P.access;
    return .exclusive;
}

/// Extracts a parameter of type `P` from its context `ctx`.
/// Allocator and Io are copied from the World. Parallel execution requires both
/// implementations to support concurrent use; caller-owned data is not synchronized.
pub fn extractParam(comptime P: type, ctx: *Context(P)) !P {
    if (P == *World) return ctx;
    if (P == Allocator) return ctx.allocator;
    if (P == std.Io) return ctx.io;
    return P.extract(ctx);
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "Context is World for builtins and parameters without one" {
    inline for (.{ *World, Allocator, std.Io, struct {} }) |P| {
        try expect(Context(P) == World);
    }
}

test "query contexts satisfy the Context contract" {
    const Q = query.Query(struct { engine.ecs.Entity.Id });
    try expect(Context(Q) == query.State);
    const spec = comptime access(Q);
    try expectEqual(0, spec.shared.components.entries.len);
    const exclusive: System.Access.Spec = .exclusive;
    try expect(spec.isConflict(exclusive));
}

test "Context returns a declared context built by init" {
    const Good = struct {
        pub const Context = struct {
            value: u32 = 0,

            pub fn init(_: *World) @This() {
                return .{};
            }
        };
    };

    try expect(Context(Good) == Good.Context);
}

test "access validates declarations and defaults undeclared parameters to exclusive" {
    const Extract = struct {
        pub fn extract(_: *World) error{}!@This() {
            return .{};
        }
    };
    const Local = struct {
        pub const access: System.Access.Spec = .none;

        pub fn extract(_: *World) error{}!@This() {
            return .{};
        }
    };
    const Declared = struct {
        pub const access: System.Access.Spec = .{ .shared = .{ .resources = &.{
            .{ .target = u32, .mode = .write },
        } } };

        pub fn extract(_: *World) error{}!@This() {
            @panic("reading access must not extract the parameter");
        }
    };

    inline for (.{ *World, Extract }) |P| {
        try expect(access(P) == .exclusive);
    }
    inline for (.{ Allocator, std.Io, Local }) |P| {
        try expect(access(P) == .none);
    }
    const declared = comptime access(Declared);
    try expectEqual(0, declared.shared.components.entries.len);
    try expectEqual(1, declared.shared.resources.len);
    const entry = declared.shared.resources[0];
    try expect(entry.target == u32);
    try expectEqual(System.Access.Mode.write, entry.mode);

    // Compile errors: invalid parameter or incorrectly typed access declaration.
    // assertParam(u32);
    // const Wrong = struct {
    //     pub const access = .none;
    //     pub const extract = Extract.extract;
    // };
    // assertParam(Wrong);
}

test "builtins borrow the World and inject allocator and Io by value" {
    var world = World.init(std.testing.allocator, std.testing.io);
    defer world.deinit();

    try expect(try extractParam(*World, &world) == &world);
    const allocator = try extractParam(Allocator, &world);
    const io = try extractParam(std.Io, &world);
    try expectEqual(world.allocator, allocator);
    try expectEqual(world.io, io);

    const Run = struct {
        fn run(injected_allocator: Allocator, injected_io: std.Io) !void {
            try expectEqual(std.testing.allocator, injected_allocator);
            try expectEqual(std.testing.io, injected_io);
            const bytes = try injected_allocator.alloc(u8, 16);
            defer injected_allocator.free(bytes);
            injected_io.random(bytes);
        }
    };
    var system = try engine.ecs.System.Builder(Run.run).build(&world);
    defer system.deinit(&world);
    try system.run(&world);
}
