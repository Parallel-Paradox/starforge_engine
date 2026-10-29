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

/// Ring buffer of archetype changes. Consumers compare it with `entries[id.index].id`:
/// equal means the archetype added, different means it was removed.
pub const ChangeLog = struct {
    const capacity = 1024;

    /// Archetype ids indexed by change version modulo `capacity`.
    buf: [capacity]ArchetypeId = @splat(ArchetypeId.invalid),
    /// Version of the oldest change still retained in `buf`.
    oldest_ver: usize = 0,
    /// Version of the next change to be recorded (the exclusive end).
    next_ver: usize = 0,

    /// Records `id` as the change at `next_ver` and advances the version, evicting the
    /// oldest entry once the buffer is full.
    pub fn record(self: *@This(), id: ArchetypeId) void {
        self.buf[self.next_ver % capacity] = id;
        self.next_ver +%= 1;

        if (self.next_ver > capacity) {
            self.oldest_ver = self.next_ver - capacity;
        }
    }

    /// Returns the change recorded at `ver`, or null if it has not been recorded yet or
    /// has already been evicted.
    pub fn get(self: *const @This(), ver: usize) ?ArchetypeId {
        if (ver < self.oldest_ver or ver >= self.next_ver) return null;
        return self.buf[ver % capacity];
    }
};

/// `Signature` -> archetype id.
signature_to_id: Signature.Lookup(ArchetypeId),
entries: std.ArrayList(Entry),
retired: std.ArrayList(ArchetypeId),
change_log: ChangeLog = .{},
allocator: Allocator,

/// Creates an empty registry; free it with `deinit`.
pub fn init(allocator: Allocator) @This() {
    return .{
        .signature_to_id = .empty,
        .entries = .empty,
        .retired = .empty,
        .change_log = .{},
        .allocator = allocator,
    };
}

/// Releases every registered archetype and the registry's lookup storage.
pub fn deinit(self: *@This()) void {
    // The map keys point into the archetypes, so drop the map before them.
    self.signature_to_id.deinit(self.allocator);
    for (self.entries.items) |*entry| {
        // Removed slots are already disposed and marked with an invalid id.
        if (entry.id.isValid()) entry.archetype.deinit();
    }
    self.entries.deinit(self.allocator);
    self.retired.deinit(self.allocator);
}

/// Returns the archetype registered for `id`, or null if it is unknown.
/// The pointer is invalidated when another archetype is registered.
pub fn getById(self: *@This(), id: ArchetypeId) ?*Archetype {
    const index = id.index.tryGet() orelse return null;
    if (index >= self.entries.items.len) return null;

    const entry = &self.entries.items[index];
    if (!entry.id.eql(id)) return null;
    return &entry.archetype;
}

/// Returns the entry for the archetype storing exactly `signature`, or null if it is
/// unknown. The pointer is invalidated when another archetype is registered.
pub fn getBySig(self: *@This(), signature: Signature) ?*Entry {
    const id = self.signature_to_id.get(signature) orelse return null;
    const index = id.index.tryGet() orelse return null;
    if (index >= self.entries.items.len) return null;

    const entry = &self.entries.items[index];
    if (!entry.id.eql(id)) return null;
    return entry;
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

    if (self.getBySig(signature)) |entry| return entry;

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

    self.change_log.record(id);
    return &self.entries.items[id.index.get()];
}

/// Removes the archetype registered for `id`, retiring its id for reuse and releasing its
/// storage. Does nothing if `id` is unknown.
///
/// # Errors
///
/// Returns an allocator error if the retired-id list cannot grow.
pub fn remove(self: *@This(), id: ArchetypeId) Allocator.Error!void {
    const index = id.index.tryGet() orelse return;
    if (index >= self.entries.items.len) return;

    const entry = &self.entries.items[index];
    if (!entry.id.eql(id)) return;

    try self.retired.ensureUnusedCapacity(self.allocator, 1);

    // The map key points into the archetype, so drop the entry before freeing it.
    _ = self.signature_to_id.remove(entry.archetype.meta.signature);
    entry.archetype.deinit();

    // An invalid id no longer matches the logged change, which marks this slot as a
    // removal for change-log consumers, and lets `deinit` skip the freed archetype.
    entry.id = .invalid;
    self.retired.appendAssumeCapacity(.{
        .index = id.index,
        .generation = id.generation.next(),
    });

    self.change_log.record(id);
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const CompMark = engine.ecs.component.Mark;

const Position = struct {
    pub const se_component: CompMark = .{};
    x: i32,
};

const Velocity = struct {
    pub const se_component: CompMark = .{};
    y: i32,
};

const Registry = @This();

/// A registry with `Position` and `Velocity` registered as components.
const Fixture = struct {
    components: CompRegistry,
    registry: Registry,
    position: CompId,
    velocity: CompId,

    fn init(allocator: Allocator) !Fixture {
        var components = CompRegistry.init(allocator);
        errdefer components.deinit();
        const position = try components.register(Position);
        const velocity = try components.register(Velocity);
        return .{
            .components = components,
            .registry = Registry.init(allocator),
            .position = position,
            .velocity = velocity,
        };
    }

    fn deinit(self: *Fixture) void {
        self.registry.deinit();
        self.components.deinit();
    }
};

test "init starts empty and deinit releases registered archetypes" {
    const allocator = std.testing.allocator;
    var registry = init(allocator);
    defer registry.deinit();

    try expectEqual(0, registry.signature_to_id.count());
    try expectEqual(0, registry.entries.items.len);
    try expectEqual(0, registry.retired.items.len);
    try expectEqual(0, registry.change_log.oldest_ver);
    try expectEqual(0, registry.change_log.next_ver);
    try expect(registry.change_log.get(0) == null);

    var components = CompRegistry.init(allocator);
    defer components.deinit();

    const id = (try registry.getOrCreate(&.{}, components)).id;
    try expectEqual(1, registry.entries.items.len);
    try expectEqual(0, registry.change_log.oldest_ver);
    try expectEqual(1, registry.change_log.next_ver);
    try expect(registry.change_log.get(0).?.eql(id));
    try expect(registry.change_log.get(1) == null);
}

test "getOrCreate registers, reuses, and looks up archetypes" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();

    const registry = &fixture.registry;

    // Unknown ids and signatures are not found.
    var unknown = Signature.init(allocator);
    defer unknown.deinit(allocator);
    try unknown.add(allocator, &.{fixture.velocity});
    try expect(registry.getBySig(unknown) == null);
    try expect(registry.getById(ArchetypeId.init(0, 0)) == null);
    try expect(registry.getById(ArchetypeId.invalid) == null);

    const empty_id = (try registry.getOrCreate(&.{}, fixture.components)).id;
    try expectEqual(0, registry.getById(empty_id).?.len());

    const first = try registry.getOrCreate(&.{fixture.position}, fixture.components);
    const first_id = first.id;
    try expectEqual(1, first.archetype.meta.columns.items.len);
    try expect(registry.getBySig(first.archetype.meta.signature).? == first);

    // Reusing an existing archetype does not log a new change.
    const again = try registry.getOrCreate(&.{fixture.position}, fixture.components);
    try expectEqual(2, registry.change_log.next_ver);
    try expect(again == first);
    try expect(again.id.eql(first_id));

    const both_id = (try registry.getOrCreate(
        &.{ fixture.velocity, fixture.position },
        fixture.components,
    )).id;
    try expectEqual(3, registry.entries.items.len);
    try expectEqual(3, registry.change_log.next_ver);
    try expectEqual(0, registry.change_log.oldest_ver);
    try expect(!both_id.eql(first_id));
    try expectEqual(2, registry.getById(both_id).?.meta.columns.items.len);
}

test "remove releases an archetype, retires its id, and logs the removal" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();

    const registry = &fixture.registry;

    const old_id = (try registry.getOrCreate(&.{fixture.position}, fixture.components)).id;
    try registry.remove(old_id);

    // The removal is logged under the old id, which the cleared slot no longer matches.
    try expectEqual(2, registry.change_log.next_ver);
    const removal = registry.change_log.get(1).?;
    try expect(removal.eql(old_id));
    try expect(!registry.entries.items[removal.index.get()].id.eql(removal));
    try expect(registry.getById(old_id) == null);
    try expectEqual(0, registry.signature_to_id.count());
    try expectEqual(1, registry.retired.items.len);
    try expect(registry.retired.items[0].index == old_id.index);
    try expect(registry.retired.items[0].generation == old_id.generation.next());

    // Removing it again, or removing unknown ids, is a no-op.
    try registry.remove(old_id);
    try registry.remove(ArchetypeId.invalid);
    try registry.remove(ArchetypeId.init(42, 0));
    try expectEqual(2, registry.change_log.next_ver);
    try expectEqual(1, registry.retired.items.len);

    // The retired index is reused with a new generation and logged as an addition.
    const new_id = (try registry.getOrCreate(&.{fixture.velocity}, fixture.components)).id;
    try expectEqual(3, registry.change_log.next_ver);
    try expect(registry.change_log.get(2).?.eql(new_id));
    try expect(new_id.index == old_id.index);
    try expect(!new_id.eql(old_id));
    try expect(registry.getById(old_id) == null);
    try expect(registry.getById(new_id) != null);

    // Removed slots are skipped by deinit.
    try registry.remove(new_id);
    try expect(registry.getById(new_id) == null);
}

test "change log wraps and evicts the oldest versions" {
    var log: ChangeLog = .{};

    for (0..ChangeLog.capacity + 3) |index| {
        log.record(ArchetypeId.init(@intCast(index), 0));
    }

    try expectEqual(ChangeLog.capacity + 3, log.next_ver);
    try expectEqual(3, log.oldest_ver);

    // Version 1024 overwrote slot 0; version 3 is now the oldest retained event.
    try expect(log.buf[0].eql(ArchetypeId.init(ChangeLog.capacity, 0)));
    try expect(log.buf[3].eql(ArchetypeId.init(3, 0)));

    // Evicted versions are no longer readable, while the retained range is.
    try expect(log.get(0) == null);
    try expect(log.get(2) == null);
    try expect(log.get(3).?.eql(ArchetypeId.init(3, 0)));
    try expect(log.get(ChangeLog.capacity + 2).?.eql(ArchetypeId.init(ChangeLog.capacity + 2, 0)));
    try expect(log.get(ChangeLog.capacity + 3) == null);
}
