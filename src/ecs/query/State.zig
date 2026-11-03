//! Runtime state for a query: filter, target layout, and cached archetypes.
//!
//! Owned by the query parameter's context; iterators borrow it and keep the
//! iteration position.

const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const ecs = engine.ecs;
const World = ecs.World;
const CompId = ecs.component.Id;
const Storage = ecs.component.Storage;
const Signature = ecs.entity.Signature;
const ArchetypeId = ecs.entity.archetype.Id;
const ArchetypeRegistry = ecs.entity.archetype.Registry;
const SparseSetId = ecs.entity.sparse_set.Id;
const Filter = ecs.query.Filter;
const Iter = ecs.query.Iter;
const TypeId = engine.reflect.TypeId;

/// A query target field resolved from its compile-time type.
pub const Target = struct {
    /// Registered id of the component.
    id: CompId,
    /// Component type key used for archetype column and sparse-set lookup.
    type_id: TypeId,
    /// Where the component is stored.
    storage: Storage,
    /// Sparse set id resolved by `update`; invalid when the component is
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
targets: ?[]?Target = null,
/// Compiled filter tree.
filter: Filter = .empty,
/// Archetypes matching the query.
caches: std.ArrayList(Cache) = .empty,
/// Next archetype change-log version to apply.
version: usize = 0,

/// Builds runtime state for `world`.
///
/// The query installs the target layout and filter on its first extraction,
/// which also fills the archetype cache.
pub fn init(world: *World) @This() {
    return .{ .world = world };
}

/// Returns an iterator over the cached archetypes, starting at the first one
/// that still exists in the registry.
///
/// When none can be walked, the iterator starts past the end; `next` then
/// returns null without reading its archetype iterator.
pub fn iter(self: *const @This()) Iter {
    var index: usize = 0;
    while (index < self.caches.items.len) : (index += 1) {
        const cached = self.caches.items[index];
        const archetype = self.world.archReg().getById(cached.id) orelse continue;
        return .{ .state = self, .current_index = index, .iter = archetype.iter() };
    }

    // `current_index` is past the end, which `next` checks before touching `iter`.
    return .{ .state = self, .current_index = self.caches.items.len, .iter = undefined };
}

/// Removes every cached archetype, releasing its cached columns.
pub fn clear(self: *@This()) void {
    for (self.caches.items) |entry| self.world.allocator.free(entry.columns);
    self.caches.clearRetainingCapacity();
}

/// Releases the filter, the target layout and cached archetypes.
pub fn deinit(self: *@This()) void {
    if (self.targets) |targets| {
        self.filter.deinit(self.world.allocator);
        self.world.allocator.free(targets);
        self.targets = null;
        self.filter = .empty;
    }

    self.clear();
    self.caches.deinit(self.world.allocator);
}

/// Refreshes the sparse set ids and the cached archetypes, applying change-log
/// entries incrementally and rebuilding when the version is outside the
/// retained log window.
///
/// Asserts that the target layout was installed (see `Query.extract`).
pub fn update(self: *@This()) Allocator.Error!void {
    const registry = self.world.archReg();
    const log = &registry.change_log;

    if (self.version < log.oldest_ver or self.version > log.next_ver) {
        return self.rebuild();
    }

    self.resolveSparse();

    var ver = self.version;
    while (ver < log.next_ver) : (ver += 1) {
        const changed = log.get(ver) orelse return self.rebuild();
        try self.applyChange(registry, changed);
        self.version = ver + 1;
    }
}

/// Resolves the sparse set id of every sparse-set target field.
fn resolveSparse(self: *@This()) void {
    for (self.targets.?) |*maybe| {
        if (maybe.*) |*target| {
            if (target.storage != .sparse_set) continue;
            target.sparse_id = if (self.world.sparseReg().getByType(target.type_id)) |entry|
                entry.id
            else
                .invalid;
        }
    }
}

/// Rebuilds the cached archetype list from the registry.
///
/// Used on first preparation and whenever the change log no longer covers the
/// version being resumed from.
pub fn rebuild(self: *@This()) Allocator.Error!void {
    self.resolveSparse();

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
    const targets = self.targets.?;
    const columns = try allocator.alloc(usize, targets.len);
    errdefer allocator.free(columns);
    for (columns) |*column| column.* = 0;
    for (targets, 0..) |maybe, i| {
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

/// Returns the filter decision for the archetype with signature `sig`, or null when
/// the signature does not satisfy the query targets or filters.
fn classify(self: *const @This(), sig: Signature) ?Filter.Decision {
    for (self.targets.?) |maybe| {
        const target = maybe orelse continue;
        if (target.storage == .archetype and !sig.has(target.id)) return null;
    }

    const decision = self.filter.judgeArchetype(sig);
    if (decision == .reject) return null;
    return decision;
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
