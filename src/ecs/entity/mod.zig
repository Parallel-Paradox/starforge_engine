pub const archetype = @import("archetype");
pub const sparse_set = @import("sparse_set");

pub const engine = @import("engine");

pub const Id = engine.ecs.Id;
pub const Entity = @import("Entity.zig");

test {
    _ = archetype;
    _ = sparse_set;
    _ = Entity;
}
