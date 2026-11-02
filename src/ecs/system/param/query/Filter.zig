//! Compile-time filters compiled into a flat, breadth-first node array.
//!
//! `With`/`Without`/`All`/`Any` build a comptime tree of types; `init` normalizes the
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

pub const Node = union(enum) { leaf: Leaf, branch: Branch };

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
    vtable: *const VTable,

    pub const VTable = struct {
        judgeArchetype: *const fn (comp_id: CompId, storage: Storage, sig: Signature) Decision,
        judgeEntity: *const fn (comp_id: CompId, storage: Storage, sig: Signature) bool,
    };

    pub fn judgeArchetype(self: @This(), sig: Signature) Decision {
        return self.vtable.judgeArchetype(self.comp_id, self.storage, sig);
    }

    pub fn judgeEntity(self: @This(), sig: Signature) bool {
        return self.vtable.judgeEntity(self.comp_id, self.storage, sig);
    }

    fn Builder(comptime T: type, comptime require: bool) type {
        comptime engine.ecs.component.assertComponent(T, "Filter.Leaf");

        return struct {
            pub const child_cnt: usize = 0;
            pub const node_cnt: usize = 1;

            fn _judgeArchetype(comp_id: CompId, storage: Storage, sig: Signature) Decision {
                if (storage == .sparse_set) return .per_entity;
                return if (sig.has(comp_id) == require) .accept else .reject;
            }

            fn _judgeEntity(comp_id: CompId, storage: Storage, sig: Signature) bool {
                if (storage != .sparse_set) return true;
                return sig.has(comp_id) == require;
            }

            pub const vtable: VTable = .{
                .judgeArchetype = &_judgeArchetype,
                .judgeEntity = &_judgeEntity,
            };

            pub fn node(comp_reg: *const CompReg) Node {
                const comp_id = comp_reg.getByType(T) orelse @panic(
                    @typeName(T) ++ " is not registered in the component registry",
                );
                const meta = comp_reg.getMeta(comp_id).?;
                return Node{ .leaf = .{
                    .comp_id = comp_id,
                    .storage = meta.storage,
                    .vtable = &vtable,
                } };
            }
        };
    }
};

fn Leaves(comptime arg: anytype, comptime require: bool) type {
    switch (@typeInfo(@TypeOf(arg))) {
        .type => return Leaf.Builder(arg, require),
        .@"struct" => |info| if (info.is_tuple) {
            const leaves = blk: {
                var out: [arg.len]type = undefined;
                inline for (arg, 0..) |T, i| out[i] = Leaf.Builder(T, require);
                break :blk out;
            };
            return Branch.Builder(.all, &leaves);
        },
        else => {},
    }
    @compileError("With/Without expects a component type or a tuple of them");
}

/// Returns the node type that requires `arg`.
pub fn With(comptime arg: anytype) type {
    return Leaves(arg, true);
}

/// Returns the node type that forbids `arg`.
pub fn Without(comptime arg: anytype) type {
    return Leaves(arg, false);
}

pub const Branch = struct {
    kind: Kind,
    child_span: struct { start: usize, end: usize },

    pub const Kind = enum { all, any };

    fn Builder(comptime kind_: Kind, comptime children_: []const type) type {
        if (children_.len == 1) return children_[0];

        return struct {
            pub const kind: Kind = kind_;
            pub const children: []const type = children_;
            pub const child_cnt: usize = children_.len;
            pub const node_cnt: usize = blk: {
                var total: usize = 1;
                for (children_) |child| total += child.node_cnt;
                break :blk total;
            };
        };
    }
};

pub fn All(comptime list: anytype) type {
    assertFilters(list, "All");
    return Branch.Builder(.all, &typesOf(list));
}

pub fn Any(comptime list: anytype) type {
    assertFilters(list, "Any");
    return Branch.Builder(.any, &typesOf(list));
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
        if (comptime @TypeOf(child) != type) {
            @compileError(name ++
                " expects Filter types, found a value of type " ++ @typeName(@TypeOf(child)));
        } else if (comptime !@hasDecl(child, "node_cnt")) {
            @compileError(name ++ " expects Filter types, " ++ @typeName(child) ++ " is not one");
        }
    }
}

fn typesOf(comptime list: anytype) [list.len]type {
    var out: [list.len]type = undefined;
    inline for (list, 0..) |child, i| out[i] = child;
    return out;
}

pub fn init(
    allocator: Allocator,
    comp_reg: *const CompReg,
    comptime filter: anytype,
) Allocator.Error!@This() {
    const Root = comptime NormalizeRoot(filter);

    // A root that matches everything owns no nodes. Zero-length allocations and
    // frees are no-ops, so this stays off the heap.
    if (comptime Root.node_cnt == 0) return initWithCount(allocator, 0);

    const self = try initWithCount(allocator, Root.node_cnt);
    const seed = comptime getSeed(Root);
    for (seed, 0..) |entry, i| {
        self.nodes[i] = switch (entry) {
            .leaf => |leaf| leaf(comp_reg),
            .branch => |branch| .{ .branch = branch },
        };
    }
    return self;
}

const Empty = struct {
    pub const node_cnt: usize = 0;
    pub const child_cnt: usize = 0;
    pub const children: [0]type = .{};
};

fn NormalizeRoot(comptime filter: anytype) type {
    switch (@typeInfo(@TypeOf(filter))) {
        .type => {
            if (comptime !@hasDecl(filter, "node_cnt"))
                @compileError("init expects a Filter type, got " ++ @typeName(filter));
            return filter;
        },
        .@"struct" => |info| if (info.is_tuple) {
            assertFilters(filter, "init");
            return switch (filter.len) {
                0 => Empty,
                1 => filter[0], // .{With(A)} -> With(A)
                else => All(filter), // .{F1, F2} -> All
            };
        },
        else => {},
    }
    @compileError("init expects a Filter type or a tuple of Filter types");
}

const Seed = union(enum) {
    leaf: *const fn (*const CompReg) Node,
    branch: Branch,
};

/// Lays out `Root` breadth-first: the root sits at index 0 and every branch owns a
/// contiguous `child_span`, so spans are always `end - start == child_cnt`.
fn getSeed(comptime Root: type) [Root.node_cnt]Seed {
    var seed: [Root.node_cnt]Seed = undefined;
    var queue: [Root.node_cnt]type = undefined;
    var slots: [Root.node_cnt]usize = undefined;
    var head: usize = 0;
    var tail: usize = 1;
    var next_free: usize = 1;

    queue[0] = Root;
    slots[0] = 0;

    while (head < tail) : (head += 1) {
        const T = queue[head];
        const slot = slots[head];

        if (comptime @hasDecl(T, "kind")) {
            seed[slot] = .{ .branch = .{
                .kind = T.kind,
                .child_span = .{ .start = next_free, .end = next_free + T.child_cnt },
            } };
            inline for (T.children) |child| {
                queue[tail] = child;
                slots[tail] = next_free;
                tail += 1;
                next_free += 1;
            }
        } else {
            seed[slot] = .{ .leaf = &T.node };
        }
    }

    if (next_free != Root.node_cnt)
        @compileError("node_cnt does not match the breadth-first seed layout");

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

test "filter types report collapsed node counts" {
    try expectEqual(1, With(Position).node_cnt);
    try expectEqual(1, Without(Position).node_cnt);

    // Single-element tuples collapse to the element itself.
    try expectEqual(1, With(.{Position}).node_cnt);
    try expectEqual(1, Without(.{Position}).node_cnt);
    try expectEqual(1, All(.{With(Position)}).node_cnt);
    try expectEqual(1, Any(.{With(Position)}).node_cnt);

    const WithBoth = With(.{ Position, Velocity });
    try expect(WithBoth.kind == .all);
    try expectEqual(2, WithBoth.child_cnt);
    try expectEqual(3, WithBoth.node_cnt);

    const WithoutBoth = Without(.{ Position, Velocity });
    try expect(WithoutBoth.kind == .all);
    try expectEqual(3, WithoutBoth.node_cnt);

    try expectEqual(3, All(.{ With(Position), Without(Velocity) }).node_cnt);
    try expectEqual(3, Any(.{ With(Position), Without(Velocity) }).node_cnt);

    // Empty branches stay as one node so they can be addressed by a parent span.
    try expectEqual(1, All(.{}).node_cnt);
    try expectEqual(0, All(.{}).child_cnt);
    try expectEqual(1, Any(.{}).node_cnt);
    try expectEqual(0, Any(.{}).child_cnt);

    try expectEqual(0, Empty.node_cnt);
}

test "root tuples collapse and expand" {
    const Single = NormalizeRoot(.{With(Position)});
    try expect(Single == With(Position));

    const Pair = NormalizeRoot(.{ With(Position), Without(Velocity) });
    try expect(Pair.kind == .all);
    try expectEqual(3, Pair.node_cnt);

    const None = NormalizeRoot(.{});
    try expect(None == Empty);
}

test "init fills breadth-first spans and leaves" {
    const allocator = std.testing.allocator;
    var registry = CompReg.init(allocator);
    defer registry.deinit();

    const position = try registry.register(Position);
    const velocity = try registry.register(Velocity);
    const frozen = try registry.register(Frozen);

    var filter = try init(allocator, &registry, .{
        With(Position),
        Any(.{ Without(Velocity), With(Frozen) }),
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
    try expect(first.vtable == &With(Position).vtable);

    const rest = filter.nodes[2].branch;
    try expect(rest.kind == .any);
    try expectEqual(3, rest.child_span.start);
    try expectEqual(5, rest.child_span.end);

    const second = filter.nodes[3].leaf;
    try expectEqual(velocity, second.comp_id);
    try expect(second.vtable == &Without(Velocity).vtable);
    try expectEqual(frozen, filter.nodes[4].leaf.comp_id);

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

test "empty root owns no nodes" {
    const allocator = std.testing.allocator;
    var registry = CompReg.init(allocator);
    defer registry.deinit();

    var filter = try init(allocator, &registry, .{});
    defer filter.deinit(allocator);

    try expectEqual(0, filter.nodes.len);
}

test "leaf nodes snapshot component storage" {
    const allocator = std.testing.allocator;
    var registry = CompReg.init(allocator);
    defer registry.deinit();

    const health = try registry.register(Health);

    var filter = try init(allocator, &registry, With(Health));
    defer filter.deinit(allocator);

    try expectEqual(1, filter.nodes.len);
    try expectEqual(health, filter.nodes[0].leaf.comp_id);
    try expectEqual(Storage.sparse_set, filter.nodes[0].leaf.storage);
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

    {
        var filter = try init(allocator, &registry, With(Position));
        defer filter.deinit(allocator);
        try expect(filter.judgeArchetype(only_position) == .accept);
        try expect(filter.judgeArchetype(only_velocity) == .reject);
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

    {
        var filter = try init(allocator, &registry, With(Health));
        defer filter.deinit(allocator);
        try expect(filter.judgeArchetype(position_only) == .per_entity);
        try expect(filter.judgeEntity(position_health));
        try expect(!filter.judgeEntity(position_only));
    }

    {
        var filter = try init(allocator, &registry, Without(Health));
        defer filter.deinit(allocator);
        try expect(filter.judgeArchetype(position_only) == .per_entity);
        try expect(!filter.judgeEntity(position_health));
        try expect(filter.judgeEntity(position_only));
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

test "empty filter matches every archetype and entity" {
    const allocator = std.testing.allocator;
    var registry = CompReg.init(allocator);
    defer registry.deinit();

    var sig = Signature.init(allocator);
    defer sig.deinit(allocator);

    var filter = try init(allocator, &registry, .{});
    defer filter.deinit(allocator);

    try expect(filter.judgeArchetype(sig) == .accept);
    try expect(filter.judgeEntity(sig));
}
