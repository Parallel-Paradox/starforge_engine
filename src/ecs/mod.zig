pub const component = @import("component/mod.zig");
pub const Entity = @import("Entity/mod.zig");
pub const Archetype = @import("Archetype/mod.zig");
pub const SparseSet = @import("SparseSet/mod.zig");
pub const System = @import("System/mod.zig");
pub const query = @import("query/mod.zig");
pub const resource = @import("resource/mod.zig");

pub const Id = @import("Id.zig");
pub const World = @import("World.zig");

test {
    _ = component;
    _ = Entity;
    _ = Archetype;
    _ = SparseSet;
    _ = System;
    _ = query;
    _ = resource;
    _ = Id;
    _ = World;
}
