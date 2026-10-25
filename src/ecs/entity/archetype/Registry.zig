const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const archetype = engine.ecs.entity.archetype;
const ArchetypeId = archetype.Id;
const Archetype = archetype.Archetype;
const Signature = engine.ecs.entity.Signature;

pub const Entry = struct {
    id: ArchetypeId,
    archetype: Archetype,
};

/// `Signature` -> archetype id.
signature_to_id: Signature.Lookup(ArchetypeId),
entries: std.ArrayList(Entry),
retired: std.ArrayList(ArchetypeId),
allocator: Allocator,

/// Creates an empty registry; free it with `deinit`.
pub fn init(allocator: Allocator) @This() {
    return .{
        .signature_to_id = .empty,
        .entries = .empty,
        .retired = .empty,
        .allocator = allocator,
    };
}

/// Releases every registered archetype and the registry's lookup storage.
pub fn deinit(self: *@This()) void {
    // The map keys point into the archetypes, so drop the map before them.
    self.signature_to_id.deinit(self.allocator);
    for (self.entries.items) |*entry| entry.archetype.deinit();
    self.entries.deinit(self.allocator);
    self.retired.deinit(self.allocator);
}

const expectEqual = std.testing.expectEqual;

const CompRegistry = engine.ecs.component.Registry;

test "init starts empty and deinit releases registered archetypes" {
    const allocator = std.testing.allocator;
    var registry = init(allocator);
    defer registry.deinit();

    try expectEqual(0, registry.signature_to_id.count());
    try expectEqual(0, registry.entries.items.len);
    try expectEqual(0, registry.retired.items.len);

    var components = CompRegistry.init(allocator);
    defer components.deinit();

    const id = ArchetypeId.init(0, 1);
    var arch = try Archetype.init(allocator, &.{}, components);
    errdefer arch.deinit();
    try registry.signature_to_id.put(allocator, arch.meta.signature, id);
    try registry.entries.append(allocator, .{ .id = id, .archetype = arch });
}
