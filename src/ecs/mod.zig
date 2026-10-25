pub const component = @import("component/mod.zig");
pub const entity = @import("entity/mod.zig");

pub const Id = @import("Id.zig");
pub const World = @import("World.zig");

test {
    _ = component;
    _ = entity;
    _ = Id;
    _ = World;
}
