pub const super = @import("../root.zig");

pub const Id = super.Id;
pub const Meta = @import("Meta.zig");
pub const Registry = @import("Registry.zig");
pub const Storage = enum { archetype, sparse_set };
