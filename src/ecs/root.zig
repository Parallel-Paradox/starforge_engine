pub const super = @import("../root.zig");

pub const ComponentId = @import("Id.zig");
pub const ComponentRegistry = @import("component/registry.zig");

test {
    _ = ComponentId;
    _ = ComponentRegistry;
}
