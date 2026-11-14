//! Declared accesses scope to the world.
//!
//! A parameter's access is split into component and resource parts. Only component
//! accesses carry a `Filter`: two component accesses to the same type conflict only
//! when their filters can match a common entity. Resources have no entities, so they
//! conflict whenever the type is shared and one side writes.
//!
//! Conflicts are checked in two stages. `findStaticConflict` runs at compile time on
//! `Spec`s and ignores registries, so it reports only conflicts that no filter can
//! remove. `Access` is the runtime view built from a registry, and its checks are exact.

const Access = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const TypeId = engine.reflect.TypeId;
const param = @import("param.zig");
const Filter = engine.ecs.query.Filter;
const CompReg = engine.ecs.component.Registry;

/// One group per parameter, borrowing storage owned by the system instance.
groups: []const Group = &.{},

pub const InitError = Filter.InitError || CompReg.RegisterError;

pub const Mode = enum {
    read,
    write,

    pub fn isConflict(self: Mode, other: Mode) bool {
        return self == .write or other == .write;
    }
};

pub const Entry = struct {
    type_id: TypeId,
    mode: Mode,

    pub const Spec = struct {
        target: type,
        mode: Mode,

        pub fn isConflict(comptime self: @This(), comptime other: @This()) bool {
            return self.target == other.target and self.mode.isConflict(other.mode);
        }
    };

    pub fn isConflict(self: Entry, other: Entry) bool {
        return self.type_id.eql(other.type_id) and self.mode.isConflict(other.mode);
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
    shared: Shared,

    pub const Shared = struct {
        components: Components = .{},
        resources: []const Entry = &.{},

        pub const Components = struct {
            entries: []const Entry = &.{},
            /// The entities the component entries range over; `.empty` matches all.
            filter: Filter = .empty,
        };

        fn isConflict(a: Shared, b: Shared) bool {
            if (entriesConflict(a.resources, b.resources)) return true;
            return entriesConflict(a.components.entries, b.components.entries) and
                !a.components.filter.isDisjoint(b.components.filter);
        }
    };

    pub fn isConflict(self: Group, other: Group) bool {
        return switch (self) {
            .none => false,
            .exclusive => other != .none,
            .shared => |a| switch (other) {
                .none => false,
                .exclusive => true,
                .shared => |b| a.isConflict(b),
            },
        };
    }
};

fn entriesConflict(a: []const Entry, b: []const Entry) bool {
    for (a) |lhs| {
        for (b) |rhs| {
            if (lhs.isConflict(rhs)) return true;
        }
    }
    return false;
}

/// One parameter's declaration. Missing declarations should resolve to `exclusive`.
pub const Spec = union(enum) {
    /// No access.
    none,
    /// Exclusive access to the world, including all components and resources.
    exclusive,
    /// Shared access to the world, but listed entries may conflict with other parameters.
    shared: Shared,

    pub const Shared = struct {
        components: Components = .{},
        resources: []const Entry.Spec = &.{},

        pub const Components = struct {
            entries: []const Entry.Spec = &.{},
            /// Full condition of the entities the entries range over, including
            /// component requirements implied by a query's item. Null matches all.
            filter: ?Filter.Node.Spec = null,
        };

        fn findInternal(comptime self: Shared) ?Pair {
            return comptime findInternalPair(.component, self.components.entries) orelse
                findInternalPair(.resource, self.resources);
        }

        fn findBetween(comptime a: Shared, comptime b: Shared) ?Pair {
            return comptime blk: {
                if (findCrossPair(.resource, a.resources, b.resources)) |pair| break :blk pair;
                // Without negation both filters are satisfiable by one entity holding
                // everything they mention, so they surely overlap. Otherwise only a
                // registry can tell, and the runtime check decides.
                if (hasNegation(a.components.filter) or hasNegation(b.components.filter)) {
                    break :blk null;
                }
                break :blk findCrossPair(.component, a.components.entries, b.components.entries);
            };
        }
    };

    /// Whether the compile-time check reports a conflict. It never reports a conflict
    /// that the exact runtime check would reject, but may miss component conflicts
    /// whose filters need a registry to compare.
    pub fn isConflict(comptime self: Spec, comptime other: Spec) bool {
        return comptime self.findConflict(other) != null;
    }

    fn findConflict(comptime self: Spec, comptime other: Spec) ?Pair {
        return comptime switch (self) {
            .none => null,
            .exclusive => if (other == .none) null else .{ null, null },
            .shared => |a| switch (other) {
                .none => null,
                .exclusive => .{ null, null },
                .shared => |b| a.findBetween(b),
            },
        };
    }
};

fn hasNegation(comptime filter: ?Filter.Node.Spec) bool {
    return comptime if (filter) |root| root.hasNegation() else false;
}

pub const Location = struct {
    param: usize,
    /// Null for group-level exclusive conflicts, which need no payload entry.
    entry: ?Ref = null,

    pub const Kind = enum { component, resource };

    /// An entry in the component or resource list of a parameter's shared access.
    pub const Ref = struct { kind: Kind, index: usize };
};

const Pair = struct { ?Location.Ref, ?Location.Ref };

fn findInternalPair(
    comptime kind: Location.Kind,
    comptime entries: []const Entry.Spec,
) ?Pair {
    return comptime blk: {
        for (entries, 0..) |lhs, a| {
            for (entries[a + 1 ..], a + 1..) |rhs, b| {
                if (lhs.isConflict(rhs)) break :blk .{
                    .{ .kind = kind, .index = a },
                    .{ .kind = kind, .index = b },
                };
            }
        }
        break :blk null;
    };
}

fn findCrossPair(
    comptime kind: Location.Kind,
    comptime lhs_entries: []const Entry.Spec,
    comptime rhs_entries: []const Entry.Spec,
) ?Pair {
    return comptime blk: {
        for (lhs_entries, 0..) |lhs, a| {
            for (rhs_entries, 0..) |rhs, b| {
                if (lhs.isConflict(rhs)) break :blk .{
                    .{ .kind = kind, .index = a },
                    .{ .kind = kind, .index = b },
                };
            }
        }
        break :blk null;
    };
}

/// Locations in the original parameter groups, before any read-access deduplication.
pub const Conflict = struct { Location, Location };

/// Finds a conflict within or between parameter declarations that no filter can remove.
/// Entries inside one parameter always conflict regardless of its filter.
/// Returning locations instead of emitting a compile error lets callers add type names.
pub fn findStaticConflict(comptime specs: []const Spec) ?Conflict {
    return comptime blk: {
        for (specs, 0..) |spec, i| {
            if (spec == .shared) {
                if (spec.shared.findInternal()) |pair| break :blk .{
                    .{ .param = i, .entry = pair[0] },
                    .{ .param = i, .entry = pair[1] },
                };
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

/// Validates a system and collects one access declaration per parameter, in order.
/// Rejects conflicts that no filter can remove; component conflicts between parameters
/// whose filters need a registry to compare are rejected by `System.Builder.build`.
pub fn specOf(comptime func: anytype) []const Spec {
    const info = switch (@typeInfo(@TypeOf(func))) {
        .@"fn" => |info| info,
        else => @compileError(@typeName(@TypeOf(func)) ++ " is not a system function"),
    };

    if (info.is_generic) @compileError("systems must not be generic functions");
    if (info.attrs.varargs) @compileError("systems must not be variadic");

    const specs = comptime blk: {
        var out: [info.param_types.len]Spec = undefined;
        for (info.param_types, 0..) |maybe_param, i| {
            const P = maybe_param orelse @compileError(
                "system function parameters must have concrete types",
            );
            out[i] = param.access(P);
        }
        break :blk out;
    };

    const ret = info.return_type orelse
        @compileError("systems must have a concrete return type");
    switch (@typeInfo(ret)) {
        .void => {},
        .error_union => |err| {
            if (err.payload != void) {
                @compileError("systems must return void or an error union of void");
            }
        },
        else => @compileError("systems must return void or an error union of void"),
    }

    if (comptime findStaticConflict(&specs)) |conflict| {
        const a, const b = conflict;
        const A = info.param_types[a.param].?;
        const B = info.param_types[b.param].?;
        if (a.entry) |a_ref| {
            const b_ref = b.entry.?;
            const entry = switch (a_ref.kind) {
                .component => specs[a.param].shared.components.entries[a_ref.index],
                .resource => specs[a.param].shared.resources[a_ref.index],
            };
            @compileError(std.fmt.comptimePrint(
                "System parameter {d} ({s}) {s} entry {d} conflicts with " ++
                    "parameter {d} ({s}) {s} entry {d}: {s}",
                .{
                    a.param,              @typeName(A), @tagName(a_ref.kind),
                    a_ref.index,          b.param,      @typeName(B),
                    @tagName(b_ref.kind), b_ref.index,  @typeName(entry.target),
                },
            ));
        }
        @compileError(std.fmt.comptimePrint(
            "System parameters {d} ({s}) and {d} ({s}) conflict: exclusive world access",
            .{ a.param, @typeName(A), b.param, @typeName(B) },
        ));
    }
    return &specs;
}

/// Fixed-size storage for runtime access metadata, owning one filter per parameter
/// that declares one. Keep it alive and unmoved while borrowed Access views are in use.
pub fn Storage(comptime specs: []const Spec) type {
    const entry_count = blk: {
        var entries: usize = 0;
        for (specs) |spec| {
            if (spec == .shared) {
                entries += spec.shared.components.entries.len + spec.shared.resources.len;
            }
        }
        break :blk entries;
    };

    return struct {
        groups: [specs.len]Group,
        /// Per shared group, its component entries followed by its resource entries.
        entries: [entry_count]Entry,

        /// Materializes identities and filters, and initializes borrowed slices in place.
        /// Registers the components that filters mention. Returned views may be copied,
        /// but must not outlive `deinit` or mutate their backing storage.
        /// Every filter must be compared against filters built from the same registry.
        pub fn init(
            self: *@This(),
            allocator: Allocator,
            comp_reg: *CompReg,
        ) InitError!Access {
            // `deinit` must be safe on groups that were not built yet.
            for (&self.groups) |*group| group.* = .none;
            errdefer self.deinit(allocator);

            comptime var entry_offset: usize = 0;
            inline for (specs, 0..) |spec, i| {
                self.groups[i] = switch (spec) {
                    .none => .none,
                    .exclusive => .exclusive,
                    .shared => try self.sharedGroup(spec.shared, entry_offset, allocator, comp_reg),
                };
                comptime {
                    if (spec == .shared) {
                        entry_offset += spec.shared.components.entries.len +
                            spec.shared.resources.len;
                    }
                }
            }
            return .{ .groups = &self.groups };
        }

        /// Frees the filters. Views previously returned by `init` become invalid.
        pub fn deinit(self: *@This(), allocator: Allocator) void {
            for (&self.groups) |*group| {
                if (group.* == .shared) group.shared.components.filter.deinit(allocator);
                group.* = .none;
            }
        }

        fn sharedGroup(
            self: *@This(),
            comptime shared: Spec.Shared,
            comptime entry_start: usize,
            allocator: Allocator,
            comp_reg: *CompReg,
        ) InitError!Group {
            const components = shared.components;
            const component_entries = self.entries[entry_start..][0..components.entries.len];
            const resource_start = entry_start + components.entries.len;
            const resource_entries = self.entries[resource_start..][0..shared.resources.len];
            inline for (components.entries, 0..) |entry, i| {
                component_entries[i] = .{ .type_id = TypeId.of(entry.target), .mode = entry.mode };
            }
            inline for (shared.resources, 0..) |entry, i| {
                resource_entries[i] = .{ .type_id = TypeId.of(entry.target), .mode = entry.mode };
            }

            var filter: Filter = .empty;
            if (components.filter != null) {
                const root = comptime components.filter.?;
                try Filter.registerComponents(comp_reg, root);
                filter = try Filter.init(allocator, comp_reg, root);
            }
            return .{ .shared = .{
                .components = .{ .entries = component_entries, .filter = filter },
                .resources = resource_entries,
            } };
        }
    };
}

/// Exact pairwise check. Entries borrow caller-owned storage with cached, valid TypeIds,
/// and filters must come from the same registry. Does not allocate.
pub fn isConflict(self: Access, other: Access) bool {
    for (self.groups) |a| {
        for (other.groups) |b| {
            if (a.isConflict(b)) return true;
        }
    }
    return false;
}

/// Finds two parameters of this access that conflict with each other.
pub fn findSelfConflict(self: Access) ?struct { usize, usize } {
    for (self.groups, 0..) |a, i| {
        for (self.groups[i + 1 ..], i + 1..) |b, j| {
            if (a.isConflict(b)) return .{ i, j };
        }
    }
    return null;
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;

const With = Filter.With;
const Without = Filter.Without;

const Payload = struct {
    pub const se_component: engine.ecs.component.Mark = .{};
    pub const se_resource: engine.ecs.resource.Mark = .{};
};
const Sparse = struct {
    pub const se_component: engine.ecs.component.Mark = .{ .storage = .sparse_set };
};
const Tag = struct {
    pub const se_component: engine.ecs.component.Mark = .{};
};
const Other = struct {
    pub const se_component: engine.ecs.component.Mark = .{};
};

const read: Entry.Spec = .{ .target = u32, .mode = .read };
const write: Entry.Spec = .{ .target = u32, .mode = .write };
const read_spec: Spec = .{ .shared = .{ .components = .{ .entries = &.{read} } } };
const write_spec: Spec = .{ .shared = .{ .components = .{ .entries = &.{write} } } };
const resource_write: Entry.Spec = .{ .target = u32, .mode = .write };
const resource_spec: Spec = .{ .shared = .{ .resources = &.{resource_write} } };

fn filtered(comptime filter: Filter.Node.Spec) Spec {
    return .{ .shared = .{ .components = .{ .entries = &.{write}, .filter = filter } } };
}

/// Builds runtime views for `a` and `b` over one registry and checks them exactly.
fn runtimeConflict(comptime a: Spec, comptime b: Spec) !bool {
    const allocator = std.testing.allocator;
    var registry = CompReg.init(allocator);
    defer registry.deinit();

    var a_storage: Storage(&.{ .none, a }) = undefined;
    var b_storage: Storage(&.{ .none, b }) = undefined;
    const lhs = try a_storage.init(allocator, &registry);
    defer a_storage.deinit(allocator);
    const rhs = try b_storage.init(allocator, &registry);
    defer b_storage.deinit(allocator);

    try expect(lhs.groups.ptr != rhs.groups.ptr);
    const forward = lhs.isConflict(rhs);
    try expectEqual(forward, rhs.isConflict(lhs));
    return forward;
}

test "declared and runtime conflicts agree on access modes kinds and scopes" {
    const empty: Spec = .{ .shared = .{} };
    const different: Spec = .{ .shared = .{ .components = .{ .entries = &.{
        .{ .target = i32, .mode = .write },
    } } } };
    const cases = [_]struct { a: Spec, b: Spec, conflict: bool }{
        .{ .a = .none, .b = .exclusive, .conflict = false },
        .{ .a = .exclusive, .b = .exclusive, .conflict = true },
        .{ .a = .exclusive, .b = read_spec, .conflict = true },
        .{ .a = .exclusive, .b = empty, .conflict = true },
        .{ .a = empty, .b = write_spec, .conflict = false },
        .{ .a = read_spec, .b = read_spec, .conflict = false },
        .{ .a = read_spec, .b = write_spec, .conflict = true },
        .{ .a = write_spec, .b = write_spec, .conflict = true },
        .{ .a = write_spec, .b = resource_spec, .conflict = false },
        .{ .a = resource_spec, .b = resource_spec, .conflict = true },
        .{ .a = write_spec, .b = different, .conflict = false },
        .{ .a = filtered(With(Tag)), .b = filtered(With(Tag)), .conflict = true },
        .{ .a = filtered(With(Tag)), .b = filtered(With(Other)), .conflict = true },
    };
    inline for (cases) |case| {
        try expectEqual(case.conflict, case.a.isConflict(case.b));
        try expectEqual(case.conflict, case.b.isConflict(case.a));
        try expectEqual(case.conflict, try runtimeConflict(case.a, case.b));
    }

    var storage: Storage(&.{}) = undefined;
    var registry = CompReg.init(std.testing.allocator);
    defer registry.deinit();
    const view = try storage.init(std.testing.allocator, &registry);
    defer storage.deinit(std.testing.allocator);
    const exclusive: Access = .{ .groups = &.{.exclusive} };
    try expectEqual(0, @sizeOf(@TypeOf(storage)));
    try expectEqual(0, view.groups.len);
    try expect(!view.isConflict(exclusive));
    try expect(!exclusive.isConflict(view));
}

test "filters let the runtime check clear component conflicts" {
    const with_tag = filtered(With(Tag));
    const without_tag = filtered(Without(Tag));
    const contradiction = filtered(Filter.All(.{ With(Tag), Without(Tag) }));
    const with_other = filtered(With(Other));
    const without_other = filtered(Without(Other));
    const either = filtered(Filter.Any(.{ With(Tag), With(Other) }));

    const cases = [_]struct { a: Spec, b: Spec, conflict: bool }{
        .{ .a = with_tag, .b = without_tag, .conflict = false },
        .{ .a = without_tag, .b = without_tag, .conflict = true },
        .{ .a = write_spec, .b = without_tag, .conflict = true },
        // The filters mention different components, so one entity can match both.
        .{ .a = with_tag, .b = without_other, .conflict = true },
        .{ .a = with_other, .b = without_other, .conflict = false },
        .{ .a = either, .b = without_tag, .conflict = true },
        .{ .a = with_other, .b = filtered(Filter.All(.{ Without(Tag), Without(Other) })), .conflict = false },
        // Nothing matches a contradiction, so it cannot conflict with anything.
        .{ .a = contradiction, .b = write_spec, .conflict = false },
        .{ .a = contradiction, .b = contradiction, .conflict = false },
    };
    inline for (cases) |case| {
        try expectEqual(case.conflict, try runtimeConflict(case.a, case.b));
    }

    // The compile-time check never reports what the runtime check clears.
    inline for (cases) |case| {
        if (comptime case.a.isConflict(case.b)) try expect(case.conflict);
    }
    try expect(!with_tag.isConflict(without_tag));
    try expect(with_tag.isConflict(with_tag));
    try expect(!with_tag.isConflict(without_other));
}

test "findStaticConflict reports original parameter and entry locations" {
    const component = Location.Kind.component;
    const resource = Location.Kind.resource;

    try expectEqual(null, comptime findStaticConflict(&.{}));
    try expectEqual(null, comptime findStaticConflict(&.{ .none, .none, read_spec, read_spec }));
    try expectEqual(null, comptime findStaticConflict(&.{ .exclusive, .none }));
    try expectEqual(null, comptime findStaticConflict(&.{
        .{ .shared = .{ .components = .{ .entries = &.{ read, read } } } },
    }));
    try expectEqual(null, comptime findStaticConflict(&.{
        .{ .shared = .{ .components = .{ .entries = &.{write} }, .resources = &.{resource_write} } },
    }));

    try expectEqualDeep(@as(?Conflict, .{
        .{ .param = 1, .entry = .{ .kind = component, .index = 0 } },
        .{ .param = 1, .entry = .{ .kind = component, .index = 2 } },
    }), comptime findStaticConflict(&.{
        .none,
        .{ .shared = .{ .components = .{ .entries = &.{ read, read, write } } } },
    }));
    try expectEqualDeep(@as(?Conflict, .{
        .{ .param = 0, .entry = .{ .kind = resource, .index = 0 } },
        .{ .param = 0, .entry = .{ .kind = resource, .index = 1 } },
    }), comptime findStaticConflict(&.{
        .{ .shared = .{ .resources = &.{ resource_write, resource_write } } },
    }));
    try expectEqualDeep(@as(?Conflict, .{
        .{ .param = 1, .entry = .{ .kind = component, .index = 0 } },
        .{ .param = 2, .entry = .{ .kind = component, .index = 0 } },
    }), comptime findStaticConflict(&.{ .none, read_spec, write_spec }));
    try expectEqualDeep(@as(?Conflict, .{
        .{ .param = 0, .entry = .{ .kind = resource, .index = 0 } },
        .{ .param = 1, .entry = .{ .kind = resource, .index = 0 } },
    }), comptime findStaticConflict(&.{ resource_spec, resource_spec }));
    try expectEqualDeep(@as(?Conflict, .{
        .{ .param = 0 },
        .{ .param = 2 },
    }), comptime findStaticConflict(&.{ .exclusive, .none, .{ .shared = .{} } }));

    // Filters with negation are left to the runtime check, others always overlap.
    const with_tag = filtered(With(Tag));
    try expectEqual(null, comptime findStaticConflict(&.{ with_tag, filtered(Without(Tag)) }));
    try expect(null != comptime findStaticConflict(&.{ with_tag, with_tag }));
    try expect(null != comptime findStaticConflict(&.{ with_tag, write_spec }));
}

test "storage retains entries and filters in its owner" {
    const allocator = std.testing.allocator;
    const payload_read: Entry.Spec = .{ .target = Payload, .mode = .read };
    const payload_write: Entry.Spec = .{ .target = Payload, .mode = .write };
    const specs = [_]Spec{
        .{ .shared = .{ .components = .{ .entries = &.{payload_read} } } },
        .{ .shared = .{ .components = .{ .entries = &.{
            payload_write,
            .{ .target = Sparse, .mode = .read },
        } } } },
        .{ .shared = .{} },
        .{ .shared = .{ .components = .{ .entries = &.{ payload_read, payload_read } } } },
        .{ .shared = .{ .resources = &.{payload_write} } },
        .{ .shared = .{
            .components = .{ .entries = &.{payload_read}, .filter = With(Sparse) },
            .resources = &.{payload_read},
        } },
    };
    const Owner = struct { storage: Storage(&specs) };
    const owner = try allocator.create(Owner);
    defer allocator.destroy(owner);
    var registry = CompReg.init(allocator);
    defer registry.deinit();

    const access = try owner.storage.init(allocator, &registry);
    defer owner.storage.deinit(allocator);
    const copied_view = access;
    const groups = copied_view.groups;
    try expect(registry.idOf(Sparse) != null);

    const p = TypeId.of(Payload);
    const s = TypeId.of(Sparse);
    const expected_entries = [_]Entry{
        .{ .type_id = p, .mode = .read },
        .{ .type_id = p, .mode = .write },
        .{ .type_id = s, .mode = .read },
        .{ .type_id = p, .mode = .read },
        .{ .type_id = p, .mode = .read },
        .{ .type_id = p, .mode = .write },
        .{ .type_id = p, .mode = .read },
        .{ .type_id = p, .mode = .read },
    };
    try expectEqualDeep(expected_entries, owner.storage.entries);
    try expect(&groups[0] == &owner.storage.groups[0]);

    const component_starts = [_]usize{ 0, 1, 3, 3, 5, 6 };
    const component_lens = [_]usize{ 1, 2, 0, 2, 0, 1 };
    const resource_starts = [_]usize{ 1, 3, 3, 5, 5, 7 };
    const resource_lens = [_]usize{ 0, 0, 0, 0, 1, 1 };
    for (groups, 0..) |group, i| {
        const shared = group.shared;
        try expectEqual(component_lens[i], shared.components.entries.len);
        if (component_lens[i] != 0) {
            try expect(&shared.components.entries[0] == &owner.storage.entries[component_starts[i]]);
        }
        try expectEqual(resource_lens[i], shared.resources.len);
        if (resource_lens[i] != 0) {
            try expect(&shared.resources[0] == &owner.storage.entries[resource_starts[i]]);
        }
    }

    // Only parameters with a filter own terms.
    try expectEqual(0, groups[0].shared.components.filter.words.len);
    const filter = groups[5].shared.components.filter;
    try expectEqual(1, filter.term_count);
    try expect(filter.words.len != 0);
}

test "storage init releases everything when an allocation fails" {
    const Run = struct {
        fn run(allocator: Allocator) !void {
            var registry = CompReg.init(allocator);
            defer registry.deinit();
            var storage: Storage(&.{
                .{ .shared = .{ .components = .{
                    .entries = &.{write},
                    .filter = Filter.All(.{ With(Tag), Filter.Any(.{ With(Other), Without(Sparse) }) }),
                } } },
                filtered(Without(Tag)),
            }) = undefined;
            _ = try storage.init(allocator, &registry);
            storage.deinit(allocator);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Run.run, .{});
}
