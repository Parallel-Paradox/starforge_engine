pub const base = @import("base");
pub const trace = @import("trace");
pub const reflect = @import("reflect");

pub const ComponentId = @import("Id.zig");
pub const ComponentRegistry = @import("component/registry.zig");

test {
    _ = ComponentId;
    _ = ComponentRegistry;
}
