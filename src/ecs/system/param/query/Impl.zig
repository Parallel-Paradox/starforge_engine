//! Runtime state for a query: component ids, cached archetypes, and iteration cursor.

const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const World = engine.ecs.World;
const CompId = engine.ecs.component.Id;
const ArchetypeId = engine.ecs.entity.archetype.Id;
const ArchetypeIter = engine.ecs.entity.archetype.Iter;

pub const Entry = struct {
    id: ArchetypeId,
    /// Whether entities in this archetype need sparse-set filter checks.
    needs_entity_filter: bool = false,
    /// Column index in this archetype for each query target field.
    columns: []usize,
};

/// The world the query iterates.
world: *World,
/// Component ids of the query target fields, or null when unregistered.
comp_ids: []?CompId,
/// Archetypes matching the query.
archetypes: std.ArrayList(Entry) = .empty,
/// Next archetype change-log version to apply.
version: usize = 0,
/// Index of the current cached archetype.
current_index: usize = 0,
/// Iterator over the current archetype; null while seeking one.
iter: ?ArchetypeIter = null,

/// Creates runtime state for a query with `comp_count` target fields.
pub fn init(world: *World, comp_count: usize) Allocator.Error!@This() {
    const comp_ids = try world.allocator.alloc(?CompId, comp_count);
    for (comp_ids) |*id| id.* = null;
    return .{ .world = world, .comp_ids = comp_ids };
}

/// Removes every cached archetype, releasing its cached columns.
pub fn clear(self: *@This()) void {
    for (self.archetypes.items) |entry| self.world.allocator.free(entry.columns);
    self.archetypes.clearRetainingCapacity();
    self.current_index = 0;
    self.iter = null;
}

/// Releases the component ids and cached archetypes, and clears the cursor.
pub fn deinit(self: *@This()) void {
    self.world.allocator.free(self.comp_ids);
    self.clear();
    self.archetypes.deinit(self.world.allocator);
}

/// Appends a cached archetype, copying `columns` into storage owned by `Impl`.
/// A valid archetype id is logged as an addition at most once, so entries never repeat.
pub fn insert(
    self: *@This(),
    id: ArchetypeId,
    needs_entity_filter: bool,
    columns: []const usize,
) Allocator.Error!void {
    const allocator = self.world.allocator;
    const owned = try allocator.dupe(usize, columns);
    errdefer allocator.free(owned);
    try self.archetypes.append(allocator, .{
        .id = id,
        .needs_entity_filter = needs_entity_filter,
        .columns = owned,
    });
}

/// Removes a cached archetype by its full id, including generation, if present.
pub fn remove(self: *@This(), id: ArchetypeId) void {
    for (self.archetypes.items, 0..) |entry, i| {
        if (entry.id.eql(id)) {
            self.world.allocator.free(entry.columns);
            _ = self.archetypes.swapRemove(i);
            return;
        }
    }
}

/// Returns the next entity across the cached archetypes, advancing the cursor.
pub fn next(self: *@This()) ?ArchetypeIter.Item {
    while (true) {
        if (self.iter) |*iter| {
            if (iter.next()) |item| return item;
            self.iter = null;
            self.current_index += 1;
        }

        if (!self.advance()) return null;
    }
}

/// Selects the next cached archetype that still exists in the registry.
fn advance(self: *@This()) bool {
    while (self.current_index < self.archetypes.items.len) {
        const cached = self.archetypes.items[self.current_index];

        const archetype = self.world.archReg().getById(cached.id) orelse {
            self.current_index += 1;
            continue;
        };
        self.iter = archetype.iter();
        return true;
    }
    return false;
}
