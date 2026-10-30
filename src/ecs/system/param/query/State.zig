//! Cached archetypes for a query, ordered by registry index.

const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const ArchetypeId = engine.ecs.entity.archetype.Id;

pub const Entry = struct {
    id: ArchetypeId,
    /// Whether entities in this archetype need sparse-set filter checks.
    needs_entity_filter: bool = false,
};

/// Archetypes matching the query, ordered by registry index.
archetypes: std.ArrayList(Entry) = .empty,
/// Next archetype change-log version to apply.
version: usize = 0,

/// Releases the cached archetype list.
pub fn deinit(self: *@This(), allocator: Allocator) void {
    self.archetypes.deinit(allocator);
}

/// Inserts or updates a cached archetype, keeping the list ordered by index.
pub fn insert(self: *@This(), allocator: Allocator, entry: Entry) Allocator.Error!void {
    const items = self.archetypes.items;
    const index = entry.id.index.get();

    for (items, 0..) |existing, i| {
        if (existing.id.index == entry.id.index) {
            items[i] = entry;
            return;
        }
        if (existing.id.index.get() > index) {
            try self.archetypes.insert(allocator, i, entry);
            return;
        }
    }

    try self.archetypes.append(allocator, entry);
}

/// Removes a cached archetype by its full id, including generation, if present.
pub fn remove(self: *@This(), id: ArchetypeId) void {
    for (self.archetypes.items, 0..) |entry, i| {
        if (entry.id.eql(id)) {
            _ = self.archetypes.orderedRemove(i);
            return;
        }
    }
}
