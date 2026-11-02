const std = @import("std");

pub const query = @import("query/mod.zig");

const engine = @import("engine");
const World = engine.ecs.World;

/// The storage a parameter keeps between extractions; `void` when it needs
/// none, including for parameters that are not declarations-bearing types.
pub fn Context(comptime P: type) type {
    switch (@typeInfo(P)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {
            return if (@hasDecl(P, "Context")) P.Context else void;
        },
        else => return void,
    }
}

/// Extracts a parameter of type `P` from the given `world`.
pub fn extractParam(comptime P: type, world: *World, ctx: *Context(P)) !P {
    if (P == *World) return world;
    return P.extract(world, ctx);
}

test {
    _ = query;
}

test "Context is void for parameters without one" {
    try std.testing.expect(Context(*World) == void);
    try std.testing.expect(Context(struct {}) == void);
}
