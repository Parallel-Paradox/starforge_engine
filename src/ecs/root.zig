pub const super = @import("../root.zig");

pub const component = @import("component/root.zig");

pub const Id = @import("Id.zig");

test {
    _ = Id;
    _ = component;
}
