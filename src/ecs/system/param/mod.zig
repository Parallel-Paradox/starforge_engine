const query = @import("query/mod.zig");
pub const Query = query.Query;

const engine = @import("engine");
const World = engine.ecs.World;

/// Extracts a parameter of type `P` from the given `world`.
pub fn extractParam(comptime P: type, world: *World) P {
    if (P == *World) return world;
    return P.extract(world);
}

test {
    _ = query;
}
