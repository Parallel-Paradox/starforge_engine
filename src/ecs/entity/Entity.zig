const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const ecs = engine.ecs;
const Id = ecs.Id;

const entity = ecs.entity;
const Signature = entity.Signature;
const ArchetypeId = entity.archetype.Id;
const SparseSetId = entity.sparse_set.Id;

id: Id,
signature: Signature,
archetype_id: ArchetypeId,
archetype_row: usize,
sparse_comps: std.ArrayList(SparseSetId),

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
