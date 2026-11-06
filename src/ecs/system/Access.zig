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

    pub fn conflicts(self: Mode, other: Mode) bool {
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

        pub fn conflicts(comptime self: @This(), comptime other: @This()) bool {
            return self.domain == other.domain and self.target == other.target and
                self.mode.conflicts(other.mode);
        }
    };

    pub fn conflicts(self: Entry, other: Entry) bool {
        return self.domain == other.domain and self.type_id.eql(other.type_id) and
            self.mode.conflicts(other.mode);
    }
};

pub const Group = union(enum) {
    none,
    exclusive,
    shared: struct { entries: []const Entry = &.{} },

    pub fn conflicts(self: Group, other: Group) bool {
        return switch (self) {
            .none => false,
            .exclusive => other != .none,
            .shared => |a| switch (other) {
                .none => false,
                .exclusive => true,
                .shared => |b| blk: {
                    for (a.entries) |lhs| {
                        for (b.entries) |rhs| {
                            if (lhs.conflicts(rhs)) break :blk true;
                        }
                    }
                    break :blk false;
                },
            },
        };
    }
};

/// One parameter's declaration. Missing declarations should resolve to `exclusive`.
pub const Spec = union(enum) {
    none,
    exclusive,
    shared: struct {
        entries: []const Entry.Spec = &.{},
        /// Full query condition, including component requirements implied by its Item.
        /// Only component accesses may eventually be refined by this condition.
        filter: ?Filter.Node.Spec = null,
    },

    pub fn conflicts(comptime self: Spec, comptime other: Spec) bool {
        return comptime self.overlap(other) != null;
    }

    fn overlap(comptime self: Spec, comptime other: Spec) ?struct { ?usize, ?usize } {
        return comptime switch (self) {
            .none => null,
            .exclusive => if (other == .none) null else .{ null, null },
            .shared => |a| switch (other) {
                .none => null,
                .exclusive => .{ null, null },
                .shared => |b| blk: {
                    for (a.entries, 0..) |lhs, i| {
                        for (b.entries, 0..) |rhs, j| {
                            if (lhs.conflicts(rhs)) break :blk .{ i, j };
                        }
                    }
                    break :blk null;
                },
            },
        };
    }
};

/// Locations in the original parameter groups, before any read-access deduplication.
pub const Conflict = struct {
    first: Location,
    second: Location,

    pub const Location = struct {
        param: usize,
        /// Null for group-level exclusive conflicts, which need no payload entry.
        entry: ?usize = null,
    };
};

/// Finds an invalid overlap within or between parameter declarations.
/// Returning locations instead of emitting a compile error lets callers add type names.
pub fn findConflict(comptime specs: []const Spec) ?Conflict {
    return comptime blk: {
        for (specs, 0..) |spec, i| {
            if (spec == .shared) {
                const entries = spec.shared.entries;
                for (entries, 0..) |lhs, a| {
                    for (entries[a + 1 ..], a + 1..) |rhs, b| {
                        if (lhs.conflicts(rhs)) break :blk .{
                            .first = .{ .param = i, .entry = a },
                            .second = .{ .param = i, .entry = b },
                        };
                    }
                }
            }
            for (specs[i + 1 ..], i + 1..) |other, j| {
                if (spec.overlap(other)) |pair| break :blk .{
                    .first = .{ .param = i, .entry = pair[0] },
                    .second = .{ .param = j, .entry = pair[1] },
                };
            }
        }
        break :blk null;
    };
}

/// Conservative pairwise check. Entries borrow caller-owned storage with cached, valid TypeIds.
/// Does not allocate, look up registry ids, or inspect query matching conditions.
pub fn conflicts(self: Access, other: Access) bool {
    for (self.groups) |a| {
        for (other.groups) |b| {
            if (a.conflicts(b)) return true;
        }
    }
    return false;
}

const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;

const read: Entry.Spec = .{ .domain = .component, .target = u32, .mode = .read };
const write: Entry.Spec = .{ .domain = .component, .target = u32, .mode = .write };
const read_spec: Spec = .{ .shared = .{ .entries = &.{read} } };
const write_spec: Spec = .{ .shared = .{ .entries = &.{write} } };

test "entry conflicts require matching domain and type with at least one writer" {
    inline for (.{ u32, i32 }) |T| {
        inline for ([_]Domain{ .component, .resource }) |lhs_domain| {
            inline for ([_]Domain{ .component, .resource }) |rhs_domain| {
                inline for ([_]Mode{ .read, .write }) |lhs_mode| {
                    inline for ([_]Mode{ .read, .write }) |rhs_mode| {
                        const lhs: Entry.Spec = .{
                            .domain = lhs_domain,
                            .target = u32,
                            .mode = lhs_mode,
                        };
                        const rhs: Entry.Spec = .{
                            .domain = rhs_domain,
                            .target = T,
                            .mode = rhs_mode,
                        };
                        const a: Entry = .{
                            .domain = lhs.domain,
                            .type_id = TypeId.of(lhs.target),
                            .mode = lhs.mode,
                        };
                        const b: Entry = .{
                            .domain = rhs.domain,
                            .type_id = TypeId.of(rhs.target),
                            .mode = rhs.mode,
                        };
                        const expected = lhs_domain == rhs_domain and T == u32 and
                            (lhs_mode == .write or rhs_mode == .write);
                        try expectEqual(expected, lhs.conflicts(rhs));
                        try expectEqual(expected, a.conflicts(b));
                        try expectEqual(expected, b.conflicts(a));
                    }
                }
            }
        }
    }
}

test "none exclusive and shared groups follow the same comptime and runtime rules" {
    const reads = [_]Entry{.{ .domain = .component, .type_id = TypeId.of(u32), .mode = .read }};
    const writes = [_]Entry{.{ .domain = .component, .type_id = TypeId.of(u32), .mode = .write }};
    const specs = [_]Spec{ .none, .exclusive, .{ .shared = .{} }, read_spec, write_spec };
    const accesses = [_]Group{
        .none,
        .exclusive,
        .{ .shared = .{} },
        .{ .shared = .{ .entries = &reads } },
        .{ .shared = .{ .entries = &writes } },
    };
    const expected = [5][5]bool{
        .{ false, false, false, false, false },
        .{ false, true, true, true, true },
        .{ false, true, false, false, false },
        .{ false, true, false, false, true },
        .{ false, true, false, true, true },
    };
    inline for (specs, 0..) |a, i| {
        inline for (specs, 0..) |b, j| {
            try expectEqual(expected[i][j], a.conflicts(b));
            const lhs: Access = .{ .groups = accesses[i .. i + 1] };
            const rhs: Access = .{ .groups = accesses[j .. j + 1] };
            try expectEqual(expected[i][j], lhs.conflicts(rhs));
        }
    }
    const empty: Access = .{};
    const reader: Access = .{ .groups = &.{ .none, accesses[3] } };
    const writer: Access = .{ .groups = &.{ .none, accesses[4] } };
    try expectEqual(false, empty.conflicts(writer));
    try expectEqual(false, reader.conflicts(empty));
    try expectEqual(true, reader.conflicts(writer));
    try expectEqual(true, writer.conflicts(reader));
}

test "findConflict reports original parameter and entry locations" {
    try expectEqual(null, comptime findConflict(&.{}));
    try expectEqual(null, comptime findConflict(&.{ .none, .none, read_spec, read_spec }));
    try expectEqual(null, comptime findConflict(&.{ .exclusive, .none }));
    try expectEqual(null, comptime findConflict(&.{
        .{ .shared = .{ .entries = &.{ read, read } } },
    }));

    try expectEqualDeep(@as(?Conflict, .{
        .first = .{ .param = 1, .entry = 1 },
        .second = .{ .param = 1, .entry = 2 },
    }), comptime findConflict(&.{
        .none,
        .{ .shared = .{ .entries = &.{
            .{ .domain = .resource, .target = u32, .mode = .write },
            read,
            write,
        } } },
    }));
    try expectEqualDeep(@as(?Conflict, .{
        .first = .{ .param = 1, .entry = 0 },
        .second = .{ .param = 2, .entry = 0 },
    }), comptime findConflict(&.{ .none, read_spec, write_spec }));
    try expectEqualDeep(@as(?Conflict, .{
        .first = .{ .param = 0 },
        .second = .{ .param = 2 },
    }), comptime findConflict(&.{ .exclusive, .none, .{ .shared = .{} } }));
    try expectEqualDeep(@as(?Conflict, .{
        .first = .{ .param = 0 },
        .second = .{ .param = 1 },
    }), comptime findConflict(&.{ .exclusive, .exclusive }));
}

test "query conditions preserve parameter scopes without relaxing conservative conflicts" {
    const Tag = struct {
        pub const se_component: engine.ecs.component.Mark = .{};
    };
    const a: Spec = .{ .shared = .{
        .entries = &.{write},
        .filter = Filter.With(Tag),
    } };
    const b: Spec = .{ .shared = .{
        .entries = &.{write},
        .filter = Filter.Without(Tag),
    } };
    try expectEqual(Tag, a.shared.filter.?.leaf.component);
    try expectEqual(true, a.shared.filter.?.leaf.require);
    try expectEqual(false, b.shared.filter.?.leaf.require);
    try expectEqual(true, a.conflicts(b));
    try expectEqualDeep(@as(?Conflict, .{
        .first = .{ .param = 0, .entry = 0 },
        .second = .{ .param = 1, .entry = 0 },
    }), comptime findConflict(&.{ a, b }));
}
