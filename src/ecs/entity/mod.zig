pub const archetype = @import("archetype/mod.zig");
pub const sparse_set = @import("sparse_set/mod.zig");
pub const change = @import("change.zig");

const engine = @import("engine");

pub const Id = engine.ecs.Id;
pub const Entity = @import("Entity.zig");
pub const Change = change.Change;
pub const Signature = @import("Signature.zig");
pub const Registry = @import("Registry.zig");

test {
    _ = archetype;
    _ = sparse_set;
    _ = change;
    _ = Entity;
    _ = Signature;
    _ = Registry;
}
