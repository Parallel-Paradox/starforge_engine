const engine = @import("engine");
const World = engine.ecs.World;

pub const filter = @import("filter.zig");

pub fn Query(comptime _: type) type {
    // TODO
    return struct {
        pub fn extract(_: *World) @This() {
            // TODO
        }
    };
}

test {
    _ = filter;
}
