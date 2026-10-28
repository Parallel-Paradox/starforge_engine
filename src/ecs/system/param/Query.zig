const engine = @import("engine");
const World = engine.ecs.World;

pub fn Query(comptime _: type) type {
    // TODO
    return struct {
        pub fn extract(_: *World) @This() {
            // TODO
        }
    };
}
