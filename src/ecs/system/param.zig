const std = @import("std");

const engine = @import("engine");
const World = engine.ecs.World;
const query = engine.ecs.query;

/// The storage a parameter keeps between extractions; `World` when it needs
/// none, including for parameters that are not declarations-bearing types.
///
/// A parameter that declares `Context` must also declare `init(*World)`,
/// returning that context type, so the system can build it.
pub fn Context(comptime P: type) type {
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
/// `*World` is accepted directly. Every other parameter must provide
/// `extract`, and a parameter declaring `Context` must also satisfy
/// `assertContext`.
pub fn assertParam(comptime P: type) void {
    if (P == *World) return;

    const has_extract = switch (@typeInfo(P)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(P, "extract"),
        else => false,
    };
    if (!has_extract) {
        @compileError(@typeName(P) ++ " is not a system parameter; " ++
            "expected *World or a type declaring `extract`");
    }

    if (@hasDecl(P, "Context")) assertContext(P.Context);
}

/// Extracts a parameter of type `P` from its context `ctx`.
pub fn extractParam(comptime P: type, ctx: *Context(P)) !P {
    if (P == *World) return ctx;
    return P.extract(ctx);
}

test "Context is World for parameters without one" {
    try std.testing.expect(Context(*World) == World);
    try std.testing.expect(Context(struct {}) == World);
}

test "query contexts satisfy the Context contract" {
    const Q = query.Query(struct { engine.ecs.entity.Id });
    try std.testing.expect(Context(Q) == query.State);
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

    try std.testing.expect(Context(Good) == Good.Context);
}

test "assertParam accepts system parameters" {
    const Q = query.Query(struct { engine.ecs.entity.Id });
    const Extract = struct {
        pub fn extract(_: *World) error{}!@This() {
            return .{};
        }
    };

    assertParam(*World);
    assertParam(Q);
    assertParam(Extract);

    // A scalar is not a system parameter:
    // assertParam(u32);
}
