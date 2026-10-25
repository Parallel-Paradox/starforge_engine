pub const archetype = @import("archetype/mod.zig");
pub const sparse_set = @import("sparse_set/mod.zig");

const engine = @import("engine");

pub const Id = engine.ecs.Id;
pub const Entity = @import("Entity.zig");
pub const Signature = @import("Signature.zig");
pub const Registry = @import("Registry.zig");

test {
    _ = archetype;
    _ = sparse_set;
    _ = Entity;
    _ = Signature;
    _ = Registry;
}
