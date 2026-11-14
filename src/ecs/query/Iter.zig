//! Iterates the live entities of a query's cached archetypes.

const std = @import("std");

const engine = @import("engine");
const ecs = engine.ecs;
const State = ecs.query.State;
const Archetype = ecs.Archetype;
const SparseSet = ecs.SparseSet;

/// An entity matched by the query's cached archetypes.
pub const Item = Archetype.Iter.Item;

state: *const State,
/// Index of the cached archetype being walked.
current_index: usize = 0,
/// Iterator over the rest of the current archetype.
iter: Archetype.Iter,

/// Returns the next live entity across the cached archetypes, or null once they
/// are exhausted.
///
/// The iterator may start past the end (see `State.iter`), in which case the
/// archetype iterator is never read.
pub fn next(self: *@This()) ?Item {
    while (self.current_index < self.state.caches.items.len) {
        if (self.iter.next()) |item| return item;

        // Move to the next cached archetype that still exists in the registry.
        while (true) {
            self.current_index += 1;
            if (self.current_index >= self.state.caches.items.len) return null;

            const cached = self.state.caches.items[self.current_index];
            const archetype = self.state.world.archeReg().getById(cached.id) orelse continue;
            self.iter = archetype.iter();
            break;
        }
    }
    return null;
}

/// Returns the entity at the current position, without advancing.
///
/// Asserts that the current position holds an entity.
pub fn get(self: @This()) Item {
    std.debug.assert(self.current_index < self.state.caches.items.len);
    return self.iter.get();
}

/// Returns the cached archetype holding the entity last returned by `next`.
pub fn cache(self: @This()) State.Cache {
    std.debug.assert(self.current_index < self.state.caches.items.len);
    return self.state.caches.items[self.current_index];
}

/// Returns whether `item` passes the query filter.
pub fn accept(self: @This(), item: Item) bool {
    const cached = self.cache();
    if (!cached.needs_entity_filter) return true;

    const target = self.state.world.entityReg().get(item.id.*) orelse return false;
    return self.state.filter.judgeEntity(target.signature);
}

/// Returns the bytes of the column for target field `index` of `item`.
///
/// Asserts that `index` addresses an archetype-stored target field.
pub fn column(self: @This(), item: Item, index: usize) []u8 {
    return item.column(self.cache().columns[index]);
}

/// Returns the sparse set holding the target field at `index`, or null when the
/// set does not exist yet.
///
/// Asserts that `index` is a target field of the query.
pub fn sparseSet(self: @This(), index: usize) ?*SparseSet {
    const targets = self.state.targets orelse unreachable;
    std.debug.assert(index < targets.len);

    const target = targets[index] orelse return null;
    return self.state.world.sparseReg().getById(target.sparse_id);
}
