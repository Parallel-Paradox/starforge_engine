//! Runtime state for a query: filter, target layout, cached archetypes, and cursor.

const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const World = engine.ecs.World;
const CompId = engine.ecs.component.Id;
const Storage = engine.ecs.component.Storage;
const Signature = engine.ecs.entity.Signature;
const ArchetypeId = engine.ecs.entity.archetype.Id;
const ArchetypeIter = engine.ecs.entity.archetype.Iter;
const ArchetypeRegistry = engine.ecs.entity.archetype.Registry;
const SparseSetId = engine.ecs.entity.sparse_set.Id;
const TypeId = engine.reflect.TypeId;

const Filter = @import("Filter.zig");

/// A query target field resolved from its compile-time type.
pub const Target = struct {
    /// Registered id of the component.
    id: CompId,
    /// Component type key used for archetype column and sparse-set lookup.
    type_id: TypeId,
    /// Where the component is stored.
    storage: Storage,
    /// Sparse set id resolved by `reset`; invalid when the component is
    /// archetype-stored or no sparse set exists yet.
    sparse_id: SparseSetId = .invalid,
};

pub const Cache = struct {
    id: ArchetypeId,
    /// Whether entities in this archetype need sparse-set filter checks.
    needs_entity_filter: bool = false,
    /// Column index in this archetype for each query target field.
    columns: []usize,
};

/// The world the query iterates.
world: *World,
/// One entry per query target field; null for `EntityId` fields.
targets: []?Target,
/// Compiled filter tree.
filter: Filter,
/// Archetypes matching the query.
caches: std.ArrayList(Cache) = .empty,
/// Next archetype change-log version to apply.
version: usize = 0,
/// Index of the current cached archetype.
current_index: usize = 0,
/// Iterator over the current archetype; null while seeking one.
iter: ?ArchetypeIter = null,

/// Builds runtime state, taking ownership of `targets` and `filter`.
/// Both must be allocated with `world.allocator`; `deinit` releases them.
/// Call `reset` before iterating to fill the archetype cache.
pub fn init(world: *World, targets: []?Target, filter: Filter) @This() {
    return .{ .world = world, .targets = targets, .filter = filter };
}

/// Removes every cached archetype, releasing its cached columns.
pub fn clear(self: *@This()) void {
    for (self.caches.items) |entry| self.world.allocator.free(entry.columns);
    self.caches.clearRetainingCapacity();
    self.current_index = 0;
    self.iter = null;
}

/// Releases the filter, the target layout and cached archetypes, and clears the cursor.
pub fn deinit(self: *@This()) void {
    self.filter.deinit(self.world.allocator);
    self.world.allocator.free(self.targets);
    self.clear();
    self.caches.deinit(self.world.allocator);
}

/// Refreshes the sparse set ids and the cached archetypes, and restarts iteration.
/// Applies change-log entries incrementally; rebuilds when the query version is
/// outside the retained log window.
pub fn reset(self: *@This()) Allocator.Error!void {
    for (self.targets) |*maybe| {
        if (maybe.*) |*target| {
            if (target.storage != .sparse_set) continue;
            target.sparse_id = if (self.world.sparseReg().getByType(target.type_id)) |entry|
                entry.id
            else
                .invalid;
        }
    }

    try self.updateState();
    self.current_index = 0;
    self.iter = null;
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
    while (self.current_index < self.caches.items.len) {
        const cached = self.caches.items[self.current_index];

        const archetype = self.world.archReg().getById(cached.id) orelse {
            self.current_index += 1;
            continue;
        };
        self.iter = archetype.iter();
        return true;
    }
    return false;
}

/// Returns the filter decision for the archetype with signature `sig`, or null when
/// the signature does not satisfy the query targets or filters.
fn classify(self: *const @This(), sig: Signature) ?Filter.Decision {
    for (self.targets) |maybe| {
        const target = maybe orelse continue;
        if (target.storage == .archetype and !sig.has(target.id)) return null;
    }

    const decision = self.filter.judgeArchetype(sig);
    if (decision == .reject) return null;
    return decision;
}

/// Applies changes since `version`, rebuilding when they were evicted.
fn updateState(self: *@This()) Allocator.Error!void {
    const registry = self.world.archReg();
    const log = &registry.change_log;

    if (self.version < log.oldest_ver or self.version > log.next_ver) {
        return self.rebuildState();
    }

    var ver = self.version;
    while (ver < log.next_ver) : (ver += 1) {
        const changed = log.get(ver) orelse return self.rebuildState();
        try self.applyChange(registry, changed);
        self.version = ver + 1;
    }
}

/// Rebuilds the cached archetype list from the registry.
fn rebuildState(self: *@This()) Allocator.Error!void {
    const registry = self.world.archReg();

    self.clear();
    errdefer {
        self.clear();
        self.version = 0;
    }

    for (registry.entries.items) |*entry| {
        if (!entry.id.isValid()) continue;
        _ = try self.insert(entry);
    }

    self.version = registry.change_log.next_ver;
}

/// Applies one change-log entry to the cached archetype list.
fn applyChange(
    self: *@This(),
    registry: *ArchetypeRegistry,
    id: ArchetypeId,
) Allocator.Error!void {
    const index = id.index.tryGet() orelse return;

    if (index < registry.entries.items.len and
        registry.entries.items[index].id.eql(id))
    {
        const entry = &registry.entries.items[index];
        if (!try self.insert(entry)) self.remove(entry.id);
        return;
    }

    self.remove(id);
}

/// Caches `entry` when it matches the query, resolving the column of each
/// archetype-stored target field. Returns whether the entry was cached.
fn insert(
    self: *@This(),
    entry: *const ArchetypeRegistry.Entry,
) Allocator.Error!bool {
    const archetype = &entry.archetype;
    const decision = self.classify(archetype.meta.signature) orelse return false;

    const allocator = self.world.allocator;
    const columns = try allocator.alloc(usize, self.targets.len);
    errdefer allocator.free(columns);
    for (columns) |*column| column.* = 0;
    for (self.targets, 0..) |maybe, i| {
        const target = maybe orelse continue;
        if (target.storage != .archetype) continue;
        columns[i] = archetype.meta.id_to_col.get(target.type_id).?;
    }

    try self.caches.append(allocator, .{
        .id = entry.id,
        .needs_entity_filter = decision == .per_entity,
        .columns = columns,
    });
    return true;
}

/// Removes a cached archetype by its full id, including generation, if present.
fn remove(self: *@This(), id: ArchetypeId) void {
    for (self.caches.items, 0..) |entry, i| {
        if (entry.id.eql(id)) {
            self.world.allocator.free(entry.columns);
            _ = self.caches.swapRemove(i);
            return;
        }
    }
}
