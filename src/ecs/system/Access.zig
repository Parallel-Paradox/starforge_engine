//! Declared accesses scope to the world.

const Access = @This();

const std = @import("std");
const engine = @import("engine");
const TypeId = engine.reflect.TypeId;
const Filter = engine.ecs.query.Filter;

/// One group per parameter, borrowing storage owned by the system instance.
groups: []const Group = &.{},

pub const Domain = enum { component, resource };

pub const Mode = enum {
    read,
    write,

    pub fn isConflict(self: Mode, other: Mode) bool {
        return self == .write or other == .write;
    }
};

pub const Entry = struct {
    domain: Domain,
    type_id: TypeId,
    mode: Mode,

    pub const Spec = struct {
        domain: Domain,
        target: type,
        mode: Mode,

        pub fn isConflict(comptime self: @This(), comptime other: @This()) bool {
            return self.domain == other.domain and self.target == other.target and
                self.mode.isConflict(other.mode);
        }
    };

    pub fn isConflict(self: Entry, other: Entry) bool {
        return self.domain == other.domain and self.type_id.eql(other.type_id) and
            self.mode.isConflict(other.mode);
    }
};

/// Runtime access for one parameter, using cached type identities.
pub const Group = union(enum) {
    /// No access.
    none,
    /// Exclusive access to the world, including all components and resources.
    exclusive,
    /// Shared access to the world, but listed entries may conflict with other parameters.
    /// An empty group still reads world structure and conflicts with exclusive access.
    shared: struct {
        entries: []const Entry = &.{},
        /// Cached query condition; conservative conflict checks do not inspect it.
        filter: ?Condition = null,
    },

    pub fn isConflict(self: Group, other: Group) bool {
        return switch (self) {
            .none => false,
            .exclusive => other != .none,
            .shared => |a| switch (other) {
                .none => false,
                .exclusive => true,
                .shared => |b| isEntriesConflict(a.entries, b.entries),
            },
        };
    }

    fn isEntriesConflict(a: []const Entry, b: []const Entry) bool {
        for (a) |lhs| {
            for (b) |rhs| {
                if (lhs.isConflict(rhs)) return true;
            }
        }
        return false;
    }
};

/// A query condition with cached type identities and filter-local breadth-first spans.
/// Its root is node 0; present conditions always contain at least one node.
pub const Condition = struct {
    nodes: []const Node,

    pub const Node = union(enum) {
        leaf: struct { type_id: TypeId, require: bool },
        branch: Filter.Branch,
    };

    fn init(comptime root: Filter.Node.Spec, nodes: []Node) Condition {
        std.debug.assert(nodes.len == root.nodeCount());
        const seed = comptime Filter.getSeed(root);
        inline for (seed, 0..) |entry, i| {
            nodes[i] = switch (entry) {
                .leaf => |leaf| .{ .leaf = .{
                    .type_id = TypeId.of(leaf.component),
                    .require = leaf.require,
                } },
                .branch => |branch| .{ .branch = branch },
            };
        }
        return .{ .nodes = nodes };
    }
};

/// One parameter's declaration. Missing declarations should resolve to `exclusive`.
pub const Spec = union(enum) {
    /// No access.
    none,
    /// Exclusive access to the world, including all components and resources.
    exclusive,
    /// Shared access to the world, but listed entries may conflict with other parameters.
    shared: struct {
        entries: []const Entry.Spec = &.{},
        /// Full query condition, including component requirements implied by its Item.
        /// Only component accesses may eventually be refined by this condition.
        filter: ?Filter.Node.Spec = null,
    },

    pub fn isConflict(comptime self: Spec, comptime other: Spec) bool {
        return comptime self.findConflict(other) != null;
    }

    fn findConflict(comptime self: Spec, comptime other: Spec) ?struct { ?usize, ?usize } {
        return comptime switch (self) {
            .none => null,
            .exclusive => if (other == .none) null else .{ null, null },
            .shared => |a| findSharedConflict(a.entries, other),
        };
    }

    fn findSharedConflict(
        comptime entries: []const Entry.Spec,
        comptime other: Spec,
    ) ?struct { ?usize, ?usize } {
        if (other == .none) return null;
        if (other == .exclusive) return .{ null, null };
        for (entries, 0..) |lhs, i| {
            for (other.shared.entries, 0..) |rhs, j| {
                if (lhs.isConflict(rhs)) return .{ i, j };
            }
        }
        return null;
    }
};

pub const Location = struct {
    param: usize,
    /// Null for group-level exclusive conflicts, which need no payload entry.
    entry: ?usize = null,
};

/// Locations in the original parameter groups, before any read-access deduplication.
pub const Conflict = struct { Location, Location };

/// Finds a conflict within or between parameter declarations.
/// Returning locations instead of emitting a compile error lets callers add type names.
pub fn findConflict(comptime specs: []const Spec) ?Conflict {
    return comptime blk: {
        for (specs, 0..) |spec, i| {
            if (spec == .shared) {
                const entries = spec.shared.entries;
                for (entries, 0..) |lhs, a| {
                    for (entries[a + 1 ..], a + 1..) |rhs, b| {
                        if (lhs.isConflict(rhs)) break :blk .{
                            .{ .param = i, .entry = a },
                            .{ .param = i, .entry = b },
                        };
                    }
                }
            }
            for (specs[i + 1 ..], i + 1..) |other, j| {
                if (spec.findConflict(other)) |pair| break :blk .{
                    .{ .param = i, .entry = pair[0] },
                    .{ .param = j, .entry = pair[1] },
                };
            }
        }
        break :blk null;
    };
}

/// Fixed-size storage for runtime access metadata.
/// Keep it alive and unmoved while borrowed Access views are in use.
pub fn Storage(comptime specs: []const Spec) type {
    const counts = blk: {
        var entries: usize = 0;
        var nodes: usize = 0;
        for (specs) |spec| {
            if (spec == .shared) {
                entries += spec.shared.entries.len;
                if (spec.shared.filter) |filter| nodes += filter.nodeCount();
            }
        }
        break :blk .{ .entries = entries, .nodes = nodes };
    };

    return struct {
        groups: [specs.len]Group,
        entries: [counts.entries]Entry,
        nodes: [counts.nodes]Condition.Node,

        /// Materializes identities and initializes borrowed slices in place.
        /// Returned views may be copied, but must not outlive or mutate their backing storage.
        pub fn init(self: *@This()) Access {
            comptime var entry_offset: usize = 0;
            comptime var node_offset: usize = 0;
            inline for (specs, 0..) |spec, i| {
                self.groups[i] = switch (spec) {
                    .none => .none,
                    .exclusive => .exclusive,
                    .shared => self.sharedGroup(spec, entry_offset, node_offset),
                };
                comptime {
                    if (spec == .shared) {
                        entry_offset += spec.shared.entries.len;
                        if (spec.shared.filter) |root| node_offset += root.nodeCount();
                    }
                }
            }
            return .{ .groups = &self.groups };
        }

        fn sharedGroup(
            self: *@This(),
            comptime spec: Spec,
            comptime entry_start: usize,
            comptime node_start: usize,
        ) Group {
            const shared = spec.shared;
            const entries = self.entries[entry_start .. entry_start + shared.entries.len];
            inline for (shared.entries, 0..) |entry, i| {
                entries[i] = .{
                    .domain = entry.domain,
                    .type_id = TypeId.of(entry.target),
                    .mode = entry.mode,
                };
            }
            const node_count = comptime if (shared.filter) |root| root.nodeCount() else 0;
            const nodes = self.nodes[node_start .. node_start + node_count];
            return .{ .shared = .{
                .entries = entries,
                .filter = if (shared.filter) |root| Condition.init(root, nodes) else null,
            } };
        }
    };
}

/// Conservative pairwise check. Entries borrow caller-owned storage with cached, valid TypeIds.
/// Does not allocate, look up registry ids, or inspect query matching conditions.
pub fn isConflict(self: Access, other: Access) bool {
    for (self.groups) |a| {
        for (other.groups) |b| {
            if (a.isConflict(b)) return true;
        }
    }
    return false;
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;

const read: Entry.Spec = .{ .domain = .component, .target = u32, .mode = .read };
const write: Entry.Spec = .{ .domain = .component, .target = u32, .mode = .write };
const read_spec: Spec = .{ .shared = .{ .entries = &.{read} } };
const write_spec: Spec = .{ .shared = .{ .entries = &.{write} } };

test "declared and runtime conflicts agree on access modes domains and scopes" {
    const Tag = struct {
        pub const se_component: engine.ecs.component.Mark = .{};
    };
    const empty: Spec = .{ .shared = .{} };
    const resource: Spec = .{ .shared = .{ .entries = &.{
        .{ .domain = .resource, .target = u32, .mode = .write },
    } } };
    const different: Spec = .{ .shared = .{ .entries = &.{
        .{ .domain = .component, .target = i32, .mode = .write },
    } } };
    const with_tag: Spec = .{ .shared = .{
        .entries = &.{write},
        .filter = Filter.With(Tag),
    } };
    const without_tag: Spec = .{ .shared = .{
        .entries = &.{write},
        .filter = Filter.Without(Tag),
    } };
    const cases = [_]struct { a: Spec, b: Spec, conflict: bool }{
        .{ .a = .none, .b = .exclusive, .conflict = false },
        .{ .a = .exclusive, .b = .exclusive, .conflict = true },
        .{ .a = .exclusive, .b = read_spec, .conflict = true },
        .{ .a = .exclusive, .b = empty, .conflict = true },
        .{ .a = empty, .b = write_spec, .conflict = false },
        .{ .a = read_spec, .b = read_spec, .conflict = false },
        .{ .a = read_spec, .b = write_spec, .conflict = true },
        .{ .a = write_spec, .b = write_spec, .conflict = true },
        .{ .a = write_spec, .b = resource, .conflict = false },
        .{ .a = resource, .b = resource, .conflict = true },
        .{ .a = write_spec, .b = different, .conflict = false },
        .{ .a = with_tag, .b = without_tag, .conflict = true },
    };
    inline for (cases) |case| {
        var a: Storage(&.{ .none, case.a }) = undefined;
        var b: Storage(&.{ .none, case.b }) = undefined;
        const lhs = a.init();
        const rhs = b.init();
        try expect(lhs.groups.ptr != rhs.groups.ptr);
        try expectEqual(case.conflict, case.a.isConflict(case.b));
        try expectEqual(case.conflict, case.b.isConflict(case.a));
        try expectEqual(case.conflict, lhs.isConflict(rhs));
        try expectEqual(case.conflict, rhs.isConflict(lhs));
    }
    var storage: Storage(&.{}) = undefined;
    const view = storage.init();
    const exclusive: Access = .{ .groups = &.{.exclusive} };
    try expectEqual(0, @sizeOf(@TypeOf(storage)));
    try expectEqual(0, view.groups.len);
    try expect(!view.isConflict(exclusive));
    try expect(!exclusive.isConflict(view));
}

test "findConflict reports original parameter and entry locations" {
    try expectEqual(null, comptime findConflict(&.{}));
    try expectEqual(null, comptime findConflict(&.{ .none, .none, read_spec, read_spec }));
    try expectEqual(null, comptime findConflict(&.{ .exclusive, .none }));
    try expectEqual(null, comptime findConflict(&.{
        .{ .shared = .{ .entries = &.{ read, read } } },
    }));

    try expectEqualDeep(@as(?Conflict, .{
        .{ .param = 1, .entry = 1 },
        .{ .param = 1, .entry = 2 },
    }), comptime findConflict(&.{
        .none,
        .{ .shared = .{ .entries = &.{
            .{ .domain = .resource, .target = u32, .mode = .write },
            read,
            write,
        } } },
    }));
    try expectEqualDeep(@as(?Conflict, .{
        .{ .param = 1, .entry = 0 },
        .{ .param = 2, .entry = 0 },
    }), comptime findConflict(&.{ .none, read_spec, write_spec }));
    try expectEqualDeep(@as(?Conflict, .{
        .{ .param = 0 },
        .{ .param = 2 },
    }), comptime findConflict(&.{ .exclusive, .none, .{ .shared = .{} } }));
}

test "storage retains entries and local condition spans in its owner" {
    const Payload = struct {
        pub const se_component: engine.ecs.component.Mark = .{};
        pub const se_resource: engine.ecs.resource.Mark = .{};
    };
    const Tag = struct {
        pub const se_component: engine.ecs.component.Mark = .{};
    };
    const Sparse = struct {
        pub const se_component: engine.ecs.component.Mark = .{ .storage = .sparse_set };
    };
    const payload_read: Entry.Spec = .{ .domain = .component, .target = Payload, .mode = .read };
    const specs = [_]Spec{
        .{ .shared = .{ .entries = &.{payload_read}, .filter = Filter.With(Payload) } },
        .{ .shared = .{
            .entries = &.{
                .{ .domain = .component, .target = Payload, .mode = .write },
                .{ .domain = .component, .target = Sparse, .mode = .read },
            },
            .filter = Filter.All(.{
                Filter.With(Payload),
                Filter.Any(.{ Filter.Without(Tag), Filter.With(Sparse) }),
                Filter.All(.{}),
                Filter.Any(.{}),
            }),
        } },
        .{ .shared = .{ .filter = Filter.Any(.{}) } },
        .{ .shared = .{ .entries = &.{ payload_read, payload_read }, .filter = Filter.All(.{}) } },
        .{ .shared = .{ .entries = &.{
            .{ .domain = .resource, .target = Payload, .mode = .write },
        } } },
    };
    const Owner = struct { storage: Storage(&specs) };
    const owner = try std.testing.allocator.create(Owner);
    defer std.testing.allocator.destroy(owner);
    const access = owner.storage.init();
    const copied_view = access;
    const groups = copied_view.groups;
    const p = TypeId.of(Payload);
    const s = TypeId.of(Sparse);
    const expected_entries = [_]Entry{
        .{ .domain = .component, .type_id = p, .mode = .read },
        .{ .domain = .component, .type_id = p, .mode = .write },
        .{ .domain = .component, .type_id = s, .mode = .read },
        .{ .domain = .component, .type_id = p, .mode = .read },
        .{ .domain = .component, .type_id = p, .mode = .read },
        .{ .domain = .resource, .type_id = p, .mode = .write },
    };
    const expected_nodes = [_]Condition.Node{
        .{ .leaf = .{ .type_id = p, .require = true } },
        .{ .branch = .{ .kind = .all, .child_span = .{ .start = 1, .end = 5 } } },
        .{ .leaf = .{ .type_id = p, .require = true } },
        .{ .branch = .{ .kind = .any, .child_span = .{ .start = 5, .end = 7 } } },
        .{ .branch = .{ .kind = .all, .child_span = .{ .start = 7, .end = 7 } } },
        .{ .branch = .{ .kind = .any, .child_span = .{ .start = 7, .end = 7 } } },
        .{ .leaf = .{ .type_id = TypeId.of(Tag), .require = false } },
        .{ .leaf = .{ .type_id = s, .require = true } },
        .{ .branch = .{ .kind = .any, .child_span = .{ .start = 1, .end = 1 } } },
        .{ .branch = .{ .kind = .all, .child_span = .{ .start = 1, .end = 1 } } },
    };
    try expectEqualDeep(expected_entries, owner.storage.entries);
    try expectEqualDeep(expected_nodes, owner.storage.nodes);
    try expect(&groups[0] == &owner.storage.groups[0]);
    for (groups, [_]usize{ 0, 1, 3, 3, 5 }, [_]usize{ 1, 2, 0, 2, 1 }) |group, start, len| {
        const entries = group.shared.entries;
        try expectEqual(len, entries.len);
        if (len != 0) try expect(&entries[0] == &owner.storage.entries[start]);
    }
    inline for (.{ 0, 1, 2, 3 }, .{ 0, 1, 8, 9 }, .{ 1, 7, 1, 1 }) |i, start, len| {
        const nodes = groups[i].shared.filter.?.nodes;
        try expectEqual(len, nodes.len);
        try expect(&nodes[0] == &owner.storage.nodes[start]);
    }
    try expectEqual(null, groups[4].shared.filter);
}
