const engine = @import("engine");

pub const Id = engine.ecs.Id;

pub const SparseSet = @import("SparseSet.zig");
pub const Iter = @import("Iter.zig");
pub const Registry = @import("Registry.zig");

test {
    _ = SparseSet;
    _ = Iter;
    _ = Registry;
}
