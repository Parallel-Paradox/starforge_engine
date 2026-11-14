const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const ecs = engine.ecs;
pub const Id = ecs.Id;
const change = @import("change.zig");
pub const Change = change.Change;
pub const Signature = @import("Signature.zig");
pub const Registry = @import("Registry/mod.zig");

const Archetype = ecs.Archetype;
const SparseSet = ecs.SparseSet;

id: Id,
signature: Signature,
archetype_id: Archetype.Id,
archetype_row: usize,
sparse_comps: std.ArrayList(SparseSet.Id),

/// Creates an entity that belongs to no archetype and has no components.
pub fn init(allocator: Allocator, id: Id) @This() {
    return .{
        .id = id,
        .signature = Signature.init(allocator),
        .archetype_id = .invalid,
        .archetype_row = 0,
        .sparse_comps = .empty,
    };
}

/// Releases the entity's signature and sparse component list.
pub fn deinit(self: *@This(), allocator: Allocator) void {
    self.signature.deinit(allocator);
    self.sparse_comps.deinit(allocator);
}

test {
    _ = change;
    _ = Signature;
    _ = Registry;
}
