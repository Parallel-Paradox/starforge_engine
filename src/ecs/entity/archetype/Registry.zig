const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const archetype = engine.ecs.entity.archetype;
const ArchetypeId = archetype.Id;
const Archetype = archetype.Archetype;
const Layout = archetype.ChunkLayout;
const Signature = engine.ecs.entity.Signature;
const CompId = engine.ecs.component.Id;
const CompRegistry = engine.ecs.component.Registry;

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

/// Returns the archetype registered for `id`, or null if it is unknown.
/// The pointer is invalidated when another archetype is registered.
pub fn get(self: *@This(), id: ArchetypeId) ?*Archetype {
    const index = id.index.tryGet() orelse return null;
    if (index >= self.entries.items.len) return null;

    const entry = &self.entries.items[index];
    if (!entry.id.eql(id)) return null;
    return &entry.archetype;
}

/// Returns the entry for the archetype storing exactly `ids`, creating and registering it
/// when needed. Every id must be registered in `components`.
/// The pointer is invalidated when another archetype is registered.
pub fn getOrCreate(
    self: *@This(),
    ids: []const CompId,
    components: CompRegistry,
) (Allocator.Error || Layout.Error)!*Entry {
    var signature = Signature.init(self.allocator);
    defer signature.deinit(self.allocator);
    try signature.add(self.allocator, ids);

    if (self.signature_to_id.get(signature)) |id| {
        return &self.entries.items[id.index.get()];
    }

    const allocator = self.allocator;
    try self.entries.ensureUnusedCapacity(allocator, 1);
    try self.signature_to_id.ensureUnusedCapacity(allocator, 1);

    const arch = try Archetype.init(allocator, ids, components);

    const reuse = self.retired.items.len != 0;
    const id = if (reuse)
        self.retired.getLast()
    else
        ArchetypeId.init(@intCast(self.entries.items.len), 0);
    if (reuse) _ = self.retired.pop();

    const entry: Entry = .{ .id = id, .archetype = arch };
    if (id.index.get() == self.entries.items.len) {
        self.entries.appendAssumeCapacity(entry);
    } else {
        self.entries.items[id.index.get()] = entry;
    }
    self.signature_to_id.putAssumeCapacityNoClobber(arch.meta.signature, id);
    return &self.entries.items[id.index.get()];
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const CompMark = engine.ecs.component.Mark;

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

test "getOrCreate reuses an archetype for the same component set" {
    const allocator = std.testing.allocator;

    const Position = struct {
        pub const se_component: CompMark = .{};
        x: i32,
    };
    const Velocity = struct {
        pub const se_component: CompMark = .{};
        y: i32,
    };

    var components = CompRegistry.init(allocator);
    defer components.deinit();
    const position = try components.register(Position);
    const velocity = try components.register(Velocity);

    var registry = init(allocator);
    defer registry.deinit();

    const empty = (try registry.getOrCreate(&.{}, components)).id;
    const first = (try registry.getOrCreate(&.{position}, components)).id;
    const again = (try registry.getOrCreate(&.{position}, components)).id;
    const both = (try registry.getOrCreate(&.{ velocity, position }, components)).id;

    try expect(first.eql(again));
    try expect(!first.eql(both));
    try expect(!empty.eql(first));
    try expectEqual(3, registry.entries.items.len);
    try expectEqual(1, registry.get(first).?.meta.columns.items.len);
    try expectEqual(2, registry.get(both).?.meta.columns.items.len);
}

test "get returns a registered archetype and rejects unknown ids" {
    const allocator = std.testing.allocator;
    var components = CompRegistry.init(allocator);
    defer components.deinit();

    var registry = init(allocator);
    defer registry.deinit();

    const entry = try registry.getOrCreate(&.{}, components);
    const id = entry.id;
    try expectEqual(0, entry.archetype.len());
    try expect(registry.get(id) != null);
    try expectEqual(0, registry.get(id).?.len());

    try expect(registry.get(ArchetypeId.init(0, 2)) == null);
    try expect(registry.get(ArchetypeId.init(1, 1)) == null);
    try expect(registry.get(ArchetypeId.invalid) == null);
}
