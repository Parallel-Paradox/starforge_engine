pub const component = @import("component/mod.zig");
pub const entity = @import("entity/mod.zig");
pub const system = @import("system/mod.zig");
pub const query = @import("query/mod.zig");
pub const resource = @import("resource/mod.zig");

pub const Id = @import("Id.zig");
pub const World = @import("World.zig");

test {
    _ = component;
    _ = entity;
    _ = system;
    _ = query;
    _ = resource;
    _ = Id;
    _ = World;
}
