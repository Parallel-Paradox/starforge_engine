//! Compile-time filters compiled into a flat, breadth-first node array.
//!
//! `With`/`Without`/`All`/`Any` build a comptime tree of values; `init` normalizes the
//! root, lays the tree out breadth-first, and snapshots component ids from the
//! registry. Runtime judging then walks `nodes` without touching comptime data.
//!
//! Layout: the root sits at index 0 and every `Branch` owns the contiguous
//! `child_span` of its direct children, so `end - start == child_cnt`.
//!
//! `Node`, `Leaf`, `Branch`, and `Decision` stay public so a runtime builder can
//! assemble a filter directly instead of going through the comptime constructors.

const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const ecs = engine.ecs;
const CompReg = ecs.component.Registry;
const CompId = ecs.component.Id;
const Storage = ecs.component.Storage;
const Signature = ecs.entity.Signature;

/// A filter that owns no nodes and therefore accepts everything.
pub const empty: @This() = .{};

/// Breadth-first nodes; empty when the filter matches everything.
nodes: []Node = &.{},

pub const Node = union(enum) {
    leaf: Leaf,
    branch: Branch,

    /// Compile-time filter description. Component types are resolved against a registry by `init`.
    pub const Spec = union(enum) {
        leaf: Leaf.Spec,
        branch: struct {
            kind: Branch.Kind,
            children: []const Spec,
        },

        pub fn nodeCount(comptime self: Spec) usize {
            return comptime switch (self) {
                .leaf => 1,
                .branch => |branch| blk: {
                    var total: usize = 1;
                    for (branch.children) |child| total += child.nodeCount();
                    break :blk total;
                },
            };
        }
    };
};

/// Outcome of evaluating a filter against an archetype signature.
pub const Decision = enum {
    /// Every entity in the archetype matches the filter.
    accept,
    /// No entity in the archetype can match the filter.
    reject,
    /// The archetype signature cannot decide, check each entity signature in the archetype.
    per_entity,

    /// Combines two decisions with logical AND (`All` semantics).
    pub fn all(self: @This(), other: @This()) @This() {
        if (self == .reject or other == .reject) return .reject;
        if (self == .accept and other == .accept) return .accept;
        return .per_entity;
    }

    /// Combines two decisions with logical OR (`Any` semantics).
    pub fn any(self: @This(), other: @This()) @This() {
        if (self == .accept or other == .accept) return .accept;
        if (self == .reject and other == .reject) return .reject;
        return .per_entity;
    }
};

pub const Leaf = struct {
    comp_id: CompId,
    storage: Storage,
    require: bool,

    pub const Spec = struct {
        component: type,
        require: bool,
    };

    pub fn judgeArchetype(self: @This(), sig: Signature) Decision {
        if (self.storage == .sparse_set) return .per_entity;
        return if (sig.has(self.comp_id) == self.require) .accept else .reject;
    }

    pub fn judgeEntity(self: @This(), sig: Signature) bool {
        if (self.storage != .sparse_set) return true;
        return sig.has(self.comp_id) == self.require;
    }
};

fn leaves(comptime arg: anytype, comptime require: bool) Node.Spec {
    switch (@typeInfo(@TypeOf(arg))) {
        .type => {
            ecs.component.assertComponent(arg, "Filter.Leaf");
            return .{ .leaf = .{ .component = arg, .require = require } };
        },
        .@"struct" => |info| if (info.is_tuple) {
            const children = blk: {
                var out: [arg.len]Node.Spec = undefined;
                for (arg, 0..) |T, i| {
                    if (@TypeOf(T) != type)
                        @compileError("With/Without expects a component type or a tuple of them");
                    out[i] = leaves(T, require);
                }
                break :blk out;
            };
            return Branch.spec(.all, &children);
        },
        else => {},
    }
    @compileError("With/Without expects a component type or a tuple of them");
}

/// Returns a filter description that requires `arg`.
pub fn With(comptime arg: anytype) Node.Spec {
    return leaves(arg, true);
}

/// Returns a filter description that forbids `arg`.
pub fn Without(comptime arg: anytype) Node.Spec {
    return leaves(arg, false);
}

pub const Branch = struct {
    kind: Kind,
    child_span: struct { start: usize, end: usize },

    pub const Kind = enum { all, any };

    pub fn spec(comptime kind: Kind, comptime children: []const Node.Spec) Node.Spec {
        if (children.len == 1) return children[0];
        return .{ .branch = .{ .kind = kind, .children = children } };
    }
};

pub fn All(comptime list: anytype) Node.Spec {
    assertFilters(list, "All");
    return Branch.spec(.all, &specsOf(list));
}

pub fn Any(comptime list: anytype) Node.Spec {
    assertFilters(list, "Any");
    return Branch.spec(.any, &specsOf(list));
}

fn assertFilters(comptime list: anytype, comptime name: []const u8) void {
    const is_tuple = switch (@typeInfo(@TypeOf(list))) {
        .@"struct" => |info| info.is_tuple,
        else => false,
    };
    if (!is_tuple) {
        @compileError(name ++ " must be a tuple, e.g. " ++ name ++ "(.{ With(A), Without(B) })");
    }

    inline for (list) |child| {
        if (@TypeOf(child) != Node.Spec) {
            @compileError(name ++
                " expects Filter descriptions, found a value of type " ++
                @typeName(@TypeOf(child)));
        }
    }
}

fn specsOf(comptime list: anytype) [list.len]Node.Spec {
    var out: [list.len]Node.Spec = undefined;
    for (list, 0..) |child, i| out[i] = child;
    return out;
}

pub fn init(
    allocator: Allocator,
    comp_reg: *const CompReg,
    comptime filter: anytype,
) Allocator.Error!@This() {
    const root = (comptime normalizeRoot(filter)) orelse return initWithCount(allocator, 0);
    const self = try initWithCount(allocator, comptime root.nodeCount());
    const seed = comptime getSeed(root);
    inline for (seed, 0..) |entry, i| {
        self.nodes[i] = switch (entry) {
            .leaf => |leaf| blk: {
                const T = leaf.component;
                const comp_id = comp_reg.idOf(T) orelse @panic(
                    @typeName(T) ++ " is not registered in the component registry",
                );
                const meta = comp_reg.getById(comp_id).?;
                break :blk .{ .leaf = .{
                    .comp_id = comp_id,
                    .storage = meta.storage,
                    .require = leaf.require,
                } };
            },
            .branch => |branch| .{ .branch = branch },
        };
    }
    return self;
}

/// Normalizes a description or root tuple; an empty tuple has no root.
pub fn normalizeRoot(comptime filter: anytype) ?Node.Spec {
    if (@TypeOf(filter) == Node.Spec) return filter;
    switch (@typeInfo(@TypeOf(filter))) {
        .@"struct" => |info| if (info.is_tuple) {
            assertFilters(filter, "init");
            return switch (filter.len) {
                0 => null,
                else => All(filter),
            };
        },
        else => {},
    }
    @compileError("init expects a Filter description or a tuple of Filter descriptions");
}

const Seed = union(enum) {
    leaf: Leaf.Spec,
    branch: Branch,
};

/// Lays out `root` breadth-first: the root sits at index 0 and every branch owns a
/// contiguous `child_span` covering its direct children.
fn getSeed(comptime root: Node.Spec) [root.nodeCount()]Seed {
    var seed: [root.nodeCount()]Seed = undefined;
    var queue: [root.nodeCount()]Node.Spec = undefined;
    var slots: [root.nodeCount()]usize = undefined;
    var head: usize = 0;
    var tail: usize = 1;
    var next_free: usize = 1;

    queue[0] = root;
    slots[0] = 0;

    while (head < tail) : (head += 1) {
        const slot = slots[head];

        switch (queue[head]) {
            .branch => |branch| {
                seed[slot] = .{ .branch = .{
                    .kind = branch.kind,
                    .child_span = .{ .start = next_free, .end = next_free + branch.children.len },
                } };
                for (branch.children) |child| {
                    queue[tail] = child;
                    slots[tail] = next_free;
                    tail += 1;
                    next_free += 1;
                }
            },
            .leaf => |leaf| seed[slot] = .{ .leaf = leaf },
        }
    }

    if (next_free != root.nodeCount())
        @compileError("node count does not match the breadth-first seed layout");

    return seed;
}

/// Judges whether every entity in an archetype with signature `sig` matches the
/// filter. An empty filter (root `.{}`) accepts everything.
pub fn judgeArchetype(self: @This(), sig: Signature) Decision {
    if (self.nodes.len == 0) return .accept;
    return judgeArchetypeAt(self.nodes, 0, sig);
}

/// Judges whether an entity whose full component signature is `sig` matches the
/// filter. `sig` must cover the archetype-stored components too, not only sparse
/// ones. Call only when `judgeArchetype` returned `.per_entity`; archetype-stored
/// leaves are treated as already satisfied.
pub fn judgeEntity(self: @This(), sig: Signature) bool {
    if (self.nodes.len == 0) return true;
    return judgeEntityAt(self.nodes, 0, sig);
}

fn judgeArchetypeAt(nodes: []const Node, index: usize, sig: Signature) Decision {
    switch (nodes[index]) {
        .leaf => |leaf| return leaf.judgeArchetype(sig),
        .branch => |branch| {
            std.debug.assert(branch.child_span.end <= nodes.len);

            var result: Decision = if (branch.kind == .all) .accept else .reject;
            var i = branch.child_span.start;
            while (i < branch.child_span.end) : (i += 1) {
                const child = judgeArchetypeAt(nodes, i, sig);
                result = if (branch.kind == .all) result.all(child) else result.any(child);
                if (branch.kind == .all) {
                    if (result == .reject) return .reject;
                } else if (result == .accept) return .accept;
            }
            return result;
        },
    }
}

fn judgeEntityAt(nodes: []const Node, index: usize, sig: Signature) bool {
    switch (nodes[index]) {
        .leaf => |leaf| return leaf.judgeEntity(sig),
        .branch => |branch| {
            std.debug.assert(branch.child_span.end <= nodes.len);

            // Consult the archetype decision per child so children already accepted or
            // rejected by `sig` are not re-checked through the sparse-only leaf path.
            var i = branch.child_span.start;
            if (branch.kind == .all) {
                while (i < branch.child_span.end) : (i += 1) {
                    switch (judgeArchetypeAt(nodes, i, sig)) {
                        .accept => {},
                        .reject => return false,
                        .per_entity => if (!judgeEntityAt(nodes, i, sig)) return false,
                    }
                }
                return true;
            }

            while (i < branch.child_span.end) : (i += 1) {
                switch (judgeArchetypeAt(nodes, i, sig)) {
                    .accept => return true,
                    .reject => {},
                    .per_entity => if (judgeEntityAt(nodes, i, sig)) return true,
                }
            }
            return false;
        },
    }
}

fn initWithCount(allocator: Allocator, node_cnt: usize) Allocator.Error!@This() {
    return .{ .nodes = try allocator.alloc(Node, node_cnt) };
}

pub fn deinit(self: @This(), allocator: Allocator) void {
    allocator.free(self.nodes);
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
    dx: i32,
};

const Frozen = struct {
    pub const se_component: CompMark = .{};
};

const Health = struct {
    pub const se_component: CompMark = .{ .storage = .sparse_set };
    value: u32,
};

test "filter descriptions collapse single children and normalize root tuples" {
    try expectEqual(1, With(Position).nodeCount());
    try expectEqual(1, Without(Position).nodeCount());

    // Single-element tuples collapse to the element itself.
    try expectEqual(1, With(.{Position}).nodeCount());
    try expectEqual(1, Without(.{Position}).nodeCount());
    try expectEqual(1, All(.{With(Position)}).nodeCount());
    try expectEqual(1, Any(.{With(Position)}).nodeCount());

    const with_both = With(.{ Position, Velocity });
    try expect(with_both.branch.kind == .all);
    try expectEqual(2, with_both.branch.children.len);
    try expectEqual(3, with_both.nodeCount());

    const without_both = Without(.{ Position, Velocity });
    try expect(without_both.branch.kind == .all);
    try expectEqual(3, without_both.nodeCount());
    try expect(!without_both.branch.children[0].leaf.require);
    try expect(!without_both.branch.children[1].leaf.require);

    try expectEqual(3, All(.{ With(Position), Without(Velocity) }).nodeCount());
    try expectEqual(3, Any(.{ With(Position), Without(Velocity) }).nodeCount());

    // Empty branches stay as one node so they can be addressed by a parent span.
    try expectEqual(1, All(.{}).nodeCount());
    try expectEqual(0, All(.{}).branch.children.len);
    try expectEqual(1, Any(.{}).nodeCount());
    try expectEqual(0, Any(.{}).branch.children.len);
    const single = comptime normalizeRoot(.{With(Position)}).?;
    try expect(single.leaf.component == Position);
    try expect(single.leaf.require);

    const pair = comptime normalizeRoot(.{ With(Position), Without(Velocity) }).?;
    try expect(pair.branch.kind == .all);
    try expectEqual(3, pair.nodeCount());

    try expect(comptime normalizeRoot(.{}) == null);
}

test "init fills breadth-first spans and leaves" {
    const allocator = std.testing.allocator;
    var registry = CompReg.init(allocator);
    defer registry.deinit();

    const position = try registry.register(Position);
    const velocity = try registry.register(Velocity);
    const health = try registry.register(Health);

    var filter = try init(allocator, &registry, .{
        With(Position),
        Any(.{ Without(Velocity), With(Health) }),
    });
    defer filter.deinit(allocator);

    try expectEqual(5, filter.nodes.len);

    const root = filter.nodes[0].branch;
    try expect(root.kind == .all);
    try expectEqual(1, root.child_span.start);
    try expectEqual(3, root.child_span.end);

    const first = filter.nodes[1].leaf;
    try expectEqual(position, first.comp_id);
    try expectEqual(Storage.archetype, first.storage);
    try expect(first.require);

    const rest = filter.nodes[2].branch;
    try expect(rest.kind == .any);
    try expectEqual(3, rest.child_span.start);
    try expectEqual(5, rest.child_span.end);

    const second = filter.nodes[3].leaf;
    try expectEqual(velocity, second.comp_id);
    try expect(!second.require);
    const third = filter.nodes[4].leaf;
    try expectEqual(health, third.comp_id);
    try expectEqual(Storage.sparse_set, third.storage);
    try expect(third.require);

    // Every branch span must stay inside the array and cover its direct children.
    for (filter.nodes, 0..) |node, i| {
        switch (node) {
            .leaf => {},
            .branch => |branch| {
                try expect(branch.child_span.start < branch.child_span.end);
                try expect(branch.child_span.end <= filter.nodes.len);
                if (i != 0) try expect(branch.child_span.start > i);
            },
        }
    }
}

test "judgeArchetype combines leaf and branch decisions" {
    const allocator = std.testing.allocator;
    var registry = CompReg.init(allocator);
    defer registry.deinit();

    const position = try registry.register(Position);
    const velocity = try registry.register(Velocity);
    const frozen = try registry.register(Frozen);

    var only_position = Signature.init(allocator);
    defer only_position.deinit(allocator);
    try only_position.add(allocator, &.{position});

    var only_velocity = Signature.init(allocator);
    defer only_velocity.deinit(allocator);
    try only_velocity.add(allocator, &.{velocity});

    var position_velocity = Signature.init(allocator);
    defer position_velocity.deinit(allocator);
    try position_velocity.add(allocator, &.{ position, velocity });

    var position_frozen = Signature.init(allocator);
    defer position_frozen.deinit(allocator);
    try position_frozen.add(allocator, &.{ position, frozen });

    var unmentioned = Signature.init(allocator);
    defer unmentioned.deinit(allocator);

    inline for (.{ With(Position), Without(Position) }) |spec| {
        var filter = try init(allocator, &registry, spec);
        defer filter.deinit(allocator);
        const require = spec.leaf.require;
        try expectEqual(
            if (require) Decision.accept else Decision.reject,
            filter.judgeArchetype(only_position),
        );
        try expectEqual(
            if (require) Decision.reject else Decision.accept,
            filter.judgeArchetype(only_velocity),
        );
        // Archetype-stored leaves are already decided before the entity phase.
        try expect(filter.nodes[0].leaf.judgeEntity(only_position));
        try expect(filter.nodes[0].leaf.judgeEntity(only_velocity));
    }

    {
        var filter = try init(allocator, &registry, All(.{ With(Position), Without(Velocity) }));
        defer filter.deinit(allocator);
        try expect(filter.judgeArchetype(only_position) == .accept);
        try expect(filter.judgeArchetype(position_velocity) == .reject);
    }

    {
        var filter = try init(allocator, &registry, Any(.{ With(Position), With(Velocity) }));
        defer filter.deinit(allocator);
        try expect(filter.judgeArchetype(only_position) == .accept);
        try expect(filter.judgeArchetype(only_velocity) == .accept);
        try expect(filter.judgeArchetype(unmentioned) == .reject);
    }

    {
        var filter = try init(allocator, &registry, .{
            With(Position),
            Any(.{ Without(Velocity), With(Frozen) }),
        });
        defer filter.deinit(allocator);
        try expect(filter.judgeArchetype(position_frozen) == .accept);
        try expect(filter.judgeArchetype(only_position) == .accept);
        try expect(filter.judgeArchetype(position_velocity) == .reject);
    }
}

test "judgeEntity checks sparse components on undecided archetypes" {
    const allocator = std.testing.allocator;
    var registry = CompReg.init(allocator);
    defer registry.deinit();

    const position = try registry.register(Position);
    _ = try registry.register(Velocity);
    const health = try registry.register(Health);

    var position_health = Signature.init(allocator);
    defer position_health.deinit(allocator);
    try position_health.add(allocator, &.{ position, health });

    var position_only = Signature.init(allocator);
    defer position_only.deinit(allocator);
    try position_only.add(allocator, &.{position});

    inline for (.{ With(Health), Without(Health) }) |spec| {
        var filter = try init(allocator, &registry, spec);
        defer filter.deinit(allocator);
        try expectEqual(1, filter.nodes.len);
        try expectEqual(health, filter.nodes[0].leaf.comp_id);
        try expectEqual(Storage.sparse_set, filter.nodes[0].leaf.storage);
        try expectEqual(Decision.per_entity, filter.judgeArchetype(position_only));
        try expectEqual(Decision.per_entity, filter.judgeArchetype(position_health));
        try expectEqual(spec.leaf.require, filter.judgeEntity(position_health));
        try expectEqual(!spec.leaf.require, filter.judgeEntity(position_only));
    }

    {
        var filter = try init(allocator, &registry, All(.{ With(Position), With(Health) }));
        defer filter.deinit(allocator);
        try expect(filter.judgeArchetype(position_only) == .per_entity);
        try expect(filter.judgeEntity(position_health));
        try expect(!filter.judgeEntity(position_only));
    }

    {
        var filter = try init(allocator, &registry, Any(.{ With(Velocity), With(Health) }));
        defer filter.deinit(allocator);
        try expect(filter.judgeArchetype(position_only) == .per_entity);
        try expect(filter.judgeEntity(position_health));
        // Velocity is rejected by the archetype and Health is absent, so this
        // entity must not match even though the archetype is undecided.
        try expect(!filter.judgeEntity(position_only));
    }

    {
        var filter = try init(allocator, &registry, Any(.{ With(Position), With(Health) }));
        defer filter.deinit(allocator);
        try expect(filter.judgeArchetype(position_only) == .accept);
    }
}

test "empty roots and branches preserve logical identities" {
    const allocator = std.testing.allocator;
    var registry = CompReg.init(allocator);
    defer registry.deinit();
    const position = try registry.register(Position);

    var absent = Signature.init(allocator);
    defer absent.deinit(allocator);
    var present = Signature.init(allocator);
    defer present.deinit(allocator);
    try present.add(allocator, &.{position});

    {
        var filter = try init(allocator, &registry, .{});
        defer filter.deinit(allocator);
        try expectEqual(0, filter.nodes.len);
        try expectEqual(Decision.accept, filter.judgeArchetype(absent));
        try expectEqual(Decision.accept, filter.judgeArchetype(present));
        try expect(filter.judgeEntity(absent));
        try expect(filter.judgeEntity(present));
    }

    inline for (.{ All(.{}), Any(.{}), With(.{}), Without(.{}) }) |spec| {
        var filter = try init(allocator, &registry, spec);
        defer filter.deinit(allocator);
        try expectEqual(1, filter.nodes.len);
        const branch = filter.nodes[0].branch;
        try expectEqual(branch.child_span.start, branch.child_span.end);
        const expected: Decision = if (branch.kind == .all) .accept else .reject;
        try expectEqual(expected, filter.judgeArchetype(absent));
        try expectEqual(expected, filter.judgeArchetype(present));
    }

    var filter = try init(allocator, &registry, All(.{
        All(.{}),
        Any(.{ Any(.{}), With(Position) }),
    }));
    defer filter.deinit(allocator);
    try expectEqual(5, filter.nodes.len);
    try expectEqual(Decision.reject, filter.judgeArchetype(absent));
    try expectEqual(Decision.accept, filter.judgeArchetype(present));
}
