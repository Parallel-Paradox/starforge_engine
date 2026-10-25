const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const ecs = engine.ecs;
const ComponentRegistry = ecs.component.Registry;
const ArchetypeRegistry = ecs.entity.archetype.Registry;
const SparseSetRegistry = ecs.entity.sparse_set.Registry;
const Entity = ecs.entity.Entity;
const EntityId = ecs.entity.Id;

comp_reg: ComponentRegistry,
arch_reg: ArchetypeRegistry,
sparse_reg: SparseSetRegistry,
entities: std.ArrayList(Entity),
retired: std.ArrayList(EntityId),
allocator: Allocator,

/// Creates an entity registry with empty component, archetype and sparse set
/// registries; free it with `deinit`.
pub fn init(allocator: Allocator) @This() {
    return .{
        .comp_reg = ComponentRegistry.init(allocator),
        .arch_reg = ArchetypeRegistry.init(allocator),
        .sparse_reg = SparseSetRegistry.init(allocator),
        .entities = .empty,
        .retired = .empty,
        .allocator = allocator,
    };
}

/// Releases every entity and all storage owned by the sub-registries.
pub fn deinit(self: *@This()) void {
    const allocator = self.allocator;
    for (self.entities.items) |*entity| entity.deinit(allocator);
    self.entities.deinit(allocator);
    self.retired.deinit(allocator);
    self.sparse_reg.deinit();
    self.arch_reg.deinit();
    self.comp_reg.deinit();
}
