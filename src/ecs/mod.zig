pub const component = @import("component/mod.zig");
pub const entity = @import("entity/mod.zig");

pub const Id = @import("Id.zig");

test {
    _ = Id;
    _ = component;
}
