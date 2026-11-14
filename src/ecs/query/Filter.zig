//! Compile-time filter descriptions expanded into disjunctive normal form (DNF).
//!
//! `init` resolves the components of a `With`/`Without`/`All`/`Any` tree against a
//! registry and expands it into an OR of terms. Each term is an AND of required and
//! forbidden components, stored as four bit sets indexed by component id index:
//! `with`, `without`, `sparse_with` and `sparse_without`. Judging and conflict checks
//! are word-wise set operations.
//!
//! No terms matches nothing; a single empty term matches everything. Expansion drops
//! contradictory terms, absorbs terms implied by another, and merges terms that differ
//! only in one component's polarity. It is not a full minimization.

const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const ecs = engine.ecs;
const CompReg = ecs.component.Registry;
const CompId = ecs.component.Id;
const Entity = ecs.Entity;

const Word = usize;
const ShiftInt = std.math.Log2Int(Word);
const word_bits = @bitSizeOf(Word);

/// Number of bit sets per term.
const set_count: usize = 4;
const set_with: usize = 0;
const set_without: usize = 1;
const set_sparse_with: usize = 2;
const set_sparse_without: usize = 3;

/// Upper bound on the number of terms a filter may expand into. Expansion simplifies
/// whenever a list fills up, so only filters that stay large after simplification fail.
pub const max_terms = 1024;

pub const InitError = Allocator.Error || error{
    /// The description expands into more than `max_terms` terms.
    FilterTooComplex,
};

/// Terms in one allocation, `set_count * width` words each. The default is a single
/// empty term, which matches everything.
words: []const Word = &.{},
width: usize = 0,
term_count: usize = 1,

/// A filter that owns no terms to check and therefore accepts everything.
pub const empty: @This() = .{};

/// Namespace for filter tree nodes.
pub const Node = struct {
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

        /// Whether any leaf forbids a component. A description without negation can be
        /// satisfied by an entity holding every mentioned component, so two such
        /// descriptions always overlap.
        pub fn hasNegation(comptime self: Spec) bool {
            return comptime switch (self) {
                .leaf => |leaf| !leaf.require,
                .branch => |branch| blk: {
                    for (branch.children) |child| {
                        if (child.hasNegation()) break :blk true;
                    }
                    break :blk false;
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
};

pub const Leaf = struct {
    pub const Spec = struct {
        component: type,
        require: bool,
    };
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

/// Registers every component mentioned by `filter`, so that `init` can resolve them.
/// Registering is idempotent for components that are already registered.
pub fn registerComponents(
    comp_reg: *CompReg,
    comptime filter: anytype,
) CompReg.RegisterError!void {
    const root = (comptime normalizeRoot(filter)) orelse return;
    try registerSpec(comp_reg, root);
}

fn registerSpec(comp_reg: *CompReg, comptime spec: Node.Spec) CompReg.RegisterError!void {
    switch (spec) {
        .leaf => |leaf| _ = try comp_reg.register(leaf.component),
        .branch => |branch| inline for (branch.children) |child| {
            try registerSpec(comp_reg, child);
        },
    }
}

/// Expands `filter` into DNF, snapshotting component ids and storage from `comp_reg`.
/// Panics when a mentioned component is not registered.
pub fn init(
    allocator: Allocator,
    comp_reg: *const CompReg,
    comptime filter: anytype,
) InitError!@This() {
    const root = (comptime normalizeRoot(filter)) orelse return .empty;
    // Ids are indexes into the registry, so its size bounds every bit this filter sets.
    const width = @max(1, (comp_reg.entries.items.len + word_bits - 1) / word_bits);

    var list = try expand(root, allocator, comp_reg, width);
    errdefer list.deinit(allocator);
    return .{
        .words = try list.words.toOwnedSlice(allocator),
        .width = width,
        .term_count = list.count,
    };
}

pub fn deinit(self: @This(), allocator: Allocator) void {
    allocator.free(self.words);
}

/// The four bit sets of one term. All slices have the same length.
pub const Term = struct {
    with: []const Word,
    without: []const Word,
    sparse_with: []const Word,
    sparse_without: []const Word,

    /// Whether no entity can satisfy both terms.
    fn conflicts(a: Term, b: Term) bool {
        return intersects(a.with, b.without) or intersects(b.with, a.without) or
            intersects(a.sparse_with, b.sparse_without) or
            intersects(b.sparse_with, a.sparse_without);
    }

    fn hasSparse(self: Term) bool {
        return !isZero(self.sparse_with) or !isZero(self.sparse_without);
    }
};

pub fn term(self: @This(), index: usize) Term {
    std.debug.assert(index < self.term_count);
    const w = self.width;
    const base = self.words[index * set_count * w ..][0 .. set_count * w];
    return .{
        .with = base[set_with * w ..][0..w],
        .without = base[set_without * w ..][0..w],
        .sparse_with = base[set_sparse_with * w ..][0..w],
        .sparse_without = base[set_sparse_without * w ..][0..w],
    };
}

/// Judges whether every entity in an archetype with signature `sig` matches the
/// filter. A filter without leaves accepts everything.
pub fn judgeArchetype(self: @This(), sig: Entity.Signature) Decision {
    const have = signatureWords(sig);
    var result: Decision = .reject;
    for (0..self.term_count) |i| {
        const t = self.term(i);
        if (!contains(have, t.with) or intersects(have, t.without)) continue;
        if (!t.hasSparse()) return .accept;
        result = .per_entity;
    }
    return result;
}

/// Judges whether an entity whose full component signature is `sig` matches the
/// filter. `sig` must cover the archetype-stored components too, not only sparse
/// ones, because different terms may constrain the same archetype differently.
/// Call only when `judgeArchetype` returned `.per_entity`.
pub fn judgeEntity(self: @This(), sig: Entity.Signature) bool {
    const have = signatureWords(sig);
    for (0..self.term_count) |i| {
        const t = self.term(i);
        if (contains(have, t.with) and !intersects(have, t.without) and
            contains(have, t.sparse_with) and !intersects(have, t.sparse_without))
        {
            return true;
        }
    }
    return false;
}

/// Whether no entity can match both filters. Both filters must be built from the same
/// registry, since bits are only comparable within one id space.
pub fn isDisjoint(self: @This(), other: @This()) bool {
    for (0..self.term_count) |i| {
        const a = self.term(i);
        for (0..other.term_count) |j| {
            if (!a.conflicts(other.term(j))) return false;
        }
    }
    return true;
}

/// A extensible list of terms of a fixed `width`, used while expanding.
const TermList = struct {
    width: usize,
    words: std.ArrayList(Word) = .empty,
    count: usize = 0,

    fn deinit(self: *TermList, allocator: Allocator) void {
        self.words.deinit(allocator);
    }

    fn stride(self: *const TermList) usize {
        return set_count * self.width;
    }

    fn set(self: *const TermList, index: usize, which: usize) []Word {
        return self.words.items[index * self.stride() + which * self.width ..][0..self.width];
    }

    /// Makes room for one more term. A full list is simplified first, and is rejected
    /// when that frees less than half of it, so expansion cannot thrash on filters that
    /// really are that large.
    fn ensureRoom(self: *TermList) InitError!void {
        if (self.count < max_terms) return;
        self.simplify();
        if (self.count > max_terms / 2) return error.FilterTooComplex;
    }

    /// Appends a term with every bit clear and returns its index.
    fn addEmpty(self: *TermList, allocator: Allocator) InitError!usize {
        try self.ensureRoom();
        try self.words.appendNTimes(allocator, 0, self.stride());
        self.count += 1;
        return self.count - 1;
    }

    fn removeLast(self: *TermList) void {
        self.words.shrinkRetainingCapacity(self.words.items.len - self.stride());
        self.count -= 1;
    }

    /// Appends every term of `other`. Both lists hold at most `max_terms` terms, so the
    /// result is simplified before it is judged too large.
    fn appendAll(self: *TermList, allocator: Allocator, other: *const TermList) InitError!void {
        try self.words.appendSlice(allocator, other.words.items);
        self.count += other.count;
        if (self.count > max_terms) {
            self.simplify();
            if (self.count > max_terms) return error.FilterTooComplex;
        }
    }

    /// Appends the conjunction of two terms from other lists, unless it is contradictory.
    fn appendConjunction(
        self: *TermList,
        allocator: Allocator,
        a: *const TermList,
        a_index: usize,
        b: *const TermList,
        b_index: usize,
    ) InitError!void {
        const index = try self.addEmpty(allocator);
        for (0..set_count) |which| {
            const dst = self.set(index, which);
            orInto(dst, a.set(a_index, which));
            orInto(dst, b.set(b_index, which));
        }
        const contradictory = intersects(self.set(index, set_with), self.set(index, set_without)) or
            intersects(self.set(index, set_sparse_with), self.set(index, set_sparse_without));
        if (contradictory) self.removeLast();
    }

    /// Whether every constraint of term `a` is also a constraint of term `b`,
    /// so `b` matches only entities that `a` matches.
    fn absorbs(self: *const TermList, a: usize, b: usize) bool {
        for (0..set_count) |which| {
            if (!contains(self.set(b, which), self.set(a, which))) return false;
        }
        return true;
    }

    /// Whether term `index` is implied by a kept term, or by a later strictly weaker one.
    /// Equal terms keep their first occurrence.
    fn isRedundant(self: *const TermList, index: usize, kept: usize) bool {
        for (0..kept) |other| {
            if (self.absorbs(other, index)) return true;
        }
        for (index + 1..self.count) |other| {
            if (self.absorbs(other, index) and !self.absorbs(index, other)) return true;
        }
        return false;
    }

    /// Drops duplicate terms and terms absorbed by another term, preserving order.
    fn absorb(self: *TermList) void {
        const size = self.stride();
        var kept: usize = 0;
        for (0..self.count) |index| {
            if (self.isRedundant(index, kept)) continue;
            if (kept != index) {
                @memcpy(
                    self.words.items[kept * size ..][0..size],
                    self.words.items[index * size ..][0..size],
                );
            }
            kept += 1;
        }
        self.words.shrinkRetainingCapacity(kept * size);
        self.count = kept;
    }

    /// If terms `a` and `b` are identical except that one component is required by one
    /// and forbidden by the other, returns where that component's bits are. Then
    /// `X and c` or `X and not c` is just `X`.
    fn findFlip(self: *const TermList, a: usize, b: usize) ?Flip {
        var found: ?Flip = null;
        for ([_]usize{ set_with, set_sparse_with }) |required| {
            const forbidden = required + 1;
            const a_required = self.set(a, required);
            const b_required = self.set(b, required);
            const a_forbidden = self.set(a, forbidden);
            const b_forbidden = self.set(b, forbidden);
            for (0..self.width) |word| {
                const required_diff = a_required[word] ^ b_required[word];
                const forbidden_diff = a_forbidden[word] ^ b_forbidden[word];
                // A flipped component changes both sets at the same bit.
                if (required_diff != forbidden_diff) return null;
                if (required_diff == 0) continue;
                if (found != null or @popCount(required_diff) != 1) return null;
                found = .{ .required = required, .word = word, .mask = required_diff };
            }
        }
        return found;
    }

    fn remove(self: *TermList, index: usize) void {
        const size = self.stride();
        const tail = (self.count - index - 1) * size;
        @memmove(
            self.words.items[index * size ..][0..tail],
            self.words.items[(index + 1) * size ..][0..tail],
        );
        self.words.shrinkRetainingCapacity(self.words.items.len - size);
        self.count -= 1;
    }

    /// One pass of merging terms that differ only in one component's polarity.
    /// Returns whether anything changed.
    fn mergeAdjacent(self: *TermList) bool {
        var changed = false;
        var a: usize = 0;
        while (a < self.count) : (a += 1) {
            var b = a + 1;
            while (b < self.count) {
                const flip = self.findFlip(a, b) orelse {
                    b += 1;
                    continue;
                };
                self.set(a, flip.required)[flip.word] &= ~flip.mask;
                self.set(a, flip.required + 1)[flip.word] &= ~flip.mask;
                self.remove(b);
                changed = true;
            }
        }
        return changed;
    }

    /// Absorbs and merges terms until neither changes anything. Every merge removes a
    /// term, so this terminates.
    fn simplify(self: *TermList) void {
        while (true) {
            self.absorb();
            if (!self.mergeAdjacent()) return;
        }
    }
};

const Flip = struct {
    /// The `with` or `sparse_with` set index; the matching forbidden set follows it.
    required: usize,
    word: usize,
    mask: Word,
};

fn expand(
    comptime spec: Node.Spec,
    allocator: Allocator,
    comp_reg: *const CompReg,
    width: usize,
) InitError!TermList {
    switch (spec) {
        .leaf => |leaf| {
            const id = comp_reg.idOf(leaf.component) orelse @panic(
                @typeName(leaf.component) ++ " is not registered in the component registry",
            );
            const sparse = comp_reg.getById(id).?.storage == .sparse_set;
            const which: usize = (if (sparse) set_sparse_with else set_with) +
                @intFromBool(!leaf.require);

            var list: TermList = .{ .width = width };
            errdefer list.deinit(allocator);
            const index = try list.addEmpty(allocator);
            setBit(list.set(index, which), @intCast(id.index.get()));
            return list;
        },
        .branch => |branch| {
            var result: TermList = .{ .width = width };
            errdefer result.deinit(allocator);
            switch (branch.kind) {
                // An empty `Any` has no terms and matches nothing.
                .any => inline for (branch.children) |child| {
                    var part = try expand(child, allocator, comp_reg, width);
                    defer part.deinit(allocator);
                    try result.appendAll(allocator, &part);
                },
                // An empty `All` is one empty term and matches everything.
                .all => {
                    _ = try result.addEmpty(allocator);
                    inline for (branch.children) |child| {
                        var part = try expand(child, allocator, comp_reg, width);
                        defer part.deinit(allocator);

                        var next: TermList = .{ .width = width };
                        errdefer next.deinit(allocator);
                        for (0..result.count) |a| {
                            for (0..part.count) |b| {
                                try next.appendConjunction(allocator, &result, a, &part, b);
                            }
                        }
                        result.deinit(allocator);
                        result = next;
                    }
                },
            }
            result.simplify();
            return result;
        },
    }
}

fn setBit(set: []Word, index: usize) void {
    set[index / word_bits] |= @as(Word, 1) << @as(ShiftInt, @intCast(index % word_bits));
}

fn hasBit(set: []const Word, index: usize) bool {
    const word = index / word_bits;
    if (word >= set.len) return false;
    return (set[word] >> @as(ShiftInt, @intCast(index % word_bits))) & 1 != 0;
}

fn isZero(set: []const Word) bool {
    for (set) |word| {
        if (word != 0) return false;
    }
    return true;
}

/// Whether `have` contains every bit of `need`. Missing words count as zero.
fn contains(have: []const Word, need: []const Word) bool {
    for (need, 0..) |word, i| {
        const present = if (i < have.len) have[i] else 0;
        if (word & ~present != 0) return false;
    }
    return true;
}

/// Whether the sets share a bit. Missing words count as zero.
fn intersects(a: []const Word, b: []const Word) bool {
    for (a[0..@min(a.len, b.len)], b[0..@min(a.len, b.len)]) |x, y| {
        if (x & y != 0) return true;
    }
    return false;
}

fn orInto(dst: []Word, src: []const Word) void {
    std.debug.assert(dst.len == src.len);
    for (dst, src) |*d, s| d.* |= s;
}

/// The words that hold the signature's bits.
fn signatureWords(sig: Entity.Signature) []const Word {
    return sig.mask.masks[0 .. (sig.mask.capacity() + word_bits - 1) / word_bits];
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

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

/// A distinct component type per `n`, for tests that need many components.
fn Marker(comptime n: usize) type {
    return struct {
        pub const se_component: CompMark = .{};
        pub const number = n;
    };
}

fn bitOf(id: CompId) usize {
    return @intCast(id.index.get());
}

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

    // Empty branches stay as one node so they can be told apart from an absent root.
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

test "hasNegation detects forbidden leaves anywhere in a description" {
    try expect(!With(Position).hasNegation());
    try expect(Without(Position).hasNegation());
    try expect(!All(.{ With(Position), Any(.{ With(Velocity), With(Health) }) }).hasNegation());
    try expect(All(.{ With(Position), Any(.{ With(Velocity), Without(Health) }) }).hasNegation());
    try expect(!All(.{}).hasNegation());
}

test "registerComponents registers every mentioned component so init resolves them" {
    const allocator = std.testing.allocator;
    var registry = CompReg.init(allocator);
    defer registry.deinit();

    try registerComponents(&registry, .{});
    try expectEqual(0, registry.entries.items.len);

    const description = .{ With(Position), Any(.{ Without(Velocity), With(Health) }) };
    try registerComponents(&registry, description);
    try registerComponents(&registry, description);
    try expectEqual(3, registry.entries.items.len);

    var filter = try init(allocator, &registry, description);
    defer filter.deinit(allocator);
    try expectEqual(2, filter.term_count);
}

test "init expands descriptions into terms split by storage" {
    const allocator = std.testing.allocator;
    var registry = CompReg.init(allocator);
    defer registry.deinit();

    const position = bitOf(try registry.register(Position));
    const velocity = bitOf(try registry.register(Velocity));
    const health = bitOf(try registry.register(Health));

    var filter = try init(allocator, &registry, .{
        With(Position),
        Any(.{ Without(Velocity), With(Health) }),
    });
    defer filter.deinit(allocator);

    try expectEqual(2, filter.term_count);
    try expectEqual(1, filter.width);

    const first = filter.term(0);
    try expect(hasBit(first.with, position));
    try expect(hasBit(first.without, velocity));
    try expect(isZero(first.sparse_with));
    try expect(isZero(first.sparse_without));

    const second = filter.term(1);
    try expect(hasBit(second.with, position));
    try expect(isZero(second.without));
    try expect(hasBit(second.sparse_with, health));
    try expect(isZero(second.sparse_without));
}

test "init distributes All over Any and drops redundant terms" {
    const allocator = std.testing.allocator;
    var registry = CompReg.init(allocator);
    defer registry.deinit();
    _ = try registry.register(Position);
    _ = try registry.register(Velocity);
    _ = try registry.register(Frozen);
    _ = try registry.register(Health);

    {
        var filter = try init(allocator, &registry, All(.{
            Any(.{ With(Position), With(Velocity) }),
            Any(.{ With(Frozen), With(Health) }),
        }));
        defer filter.deinit(allocator);
        try expectEqual(4, filter.term_count);
    }

    // A term that requires more than another term is absorbed by it.
    {
        var filter = try init(allocator, &registry, Any(.{
            With(Position),
            All(.{ With(Position), With(Velocity) }),
            All(.{ With(Position), Without(Frozen) }),
        }));
        defer filter.deinit(allocator);
        try expectEqual(1, filter.term_count);
        const only = filter.term(0);
        try expect(!isZero(only.with));
        try expect(isZero(only.without));
    }

    // Equal terms collapse into one.
    {
        var filter = try init(allocator, &registry, Any(.{ With(Position), With(Position) }));
        defer filter.deinit(allocator);
        try expectEqual(1, filter.term_count);
    }

    // Contradictory terms are dropped, leaving a filter that matches nothing.
    {
        var filter = try init(allocator, &registry, All(.{ With(Position), Without(Position) }));
        defer filter.deinit(allocator);
        try expectEqual(0, filter.term_count);
    }
    {
        var filter = try init(allocator, &registry, All(.{ With(Health), Without(Health) }));
        defer filter.deinit(allocator);
        try expectEqual(0, filter.term_count);
    }
    {
        var filter = try init(allocator, &registry, Any(.{
            All(.{ With(Position), Without(Position) }),
            With(Velocity),
        }));
        defer filter.deinit(allocator);
        try expectEqual(1, filter.term_count);
    }
}

test "init merges terms that differ only in one component's polarity" {
    const allocator = std.testing.allocator;
    var registry = CompReg.init(allocator);
    defer registry.deinit();
    const position = bitOf(try registry.register(Position));
    const velocity = bitOf(try registry.register(Velocity));
    _ = try registry.register(Frozen);
    _ = try registry.register(Health);

    var empty_sig = Entity.Signature.init(allocator);
    defer empty_sig.deinit(allocator);

    // A or not A is a tautology, for archetype and sparse components alike.
    inline for (.{ Position, Health }) |T| {
        var filter = try init(allocator, &registry, Any(.{ With(T), Without(T) }));
        defer filter.deinit(allocator);
        try expectEqual(1, filter.term_count);
        try expect(isZero(filter.term(0).with) and isZero(filter.term(0).sparse_with));
        try expectEqual(Decision.accept, filter.judgeArchetype(empty_sig));
    }

    // (A and B) or (A and not B) is A.
    {
        var filter = try init(allocator, &registry, Any(.{
            All(.{ With(Position), With(Velocity) }),
            All(.{ With(Position), Without(Velocity) }),
        }));
        defer filter.deinit(allocator);
        try expectEqual(1, filter.term_count);
        const only = filter.term(0);
        try expect(hasBit(only.with, position));
        try expect(!hasBit(only.with, velocity));
        try expect(isZero(only.without));
    }

    // Merging cascades: every combination of three components collapses to a tautology.
    {
        var filter = try init(allocator, &registry, All(.{
            Any(.{ With(Position), Without(Position) }),
            Any(.{ With(Velocity), Without(Velocity) }),
            Any(.{ With(Frozen), Without(Frozen) }),
        }));
        defer filter.deinit(allocator);
        try expectEqual(1, filter.term_count);
        try expectEqual(Decision.accept, filter.judgeArchetype(empty_sig));
    }

    // Terms that differ in more than one component, or in only one side, stay apart.
    {
        var filter = try init(allocator, &registry, Any(.{
            All(.{ With(Position), With(Velocity) }),
            All(.{ Without(Position), Without(Velocity) }),
        }));
        defer filter.deinit(allocator);
        try expectEqual(2, filter.term_count);
    }
    {
        var filter = try init(allocator, &registry, Any(.{
            All(.{ With(Position), With(Velocity) }),
            All(.{ Without(Position), With(Frozen) }),
        }));
        defer filter.deinit(allocator);
        try expectEqual(2, filter.term_count);
    }

    // A merged term can absorb others, and a merge can enable a further merge.
    {
        var filter = try init(allocator, &registry, Any(.{
            All(.{ With(Position), With(Velocity), With(Frozen) }),
            All(.{ With(Position), With(Velocity), Without(Frozen) }),
            All(.{ With(Position), Without(Velocity) }),
        }));
        defer filter.deinit(allocator);
        try expectEqual(1, filter.term_count);
        try expect(hasBit(filter.term(0).with, position));
        try expect(isZero(filter.term(0).without));
    }
}

test "init rejects descriptions that expand beyond max_terms" {
    const allocator = std.testing.allocator;
    var registry = CompReg.init(allocator);
    defer registry.deinit();

    const pairs = 11;
    inline for (0..2 * pairs) |i| _ = try registry.register(Marker(i));

    const alternatives = comptime blk: {
        var out: [pairs]Node.Spec = undefined;
        for (&out, 0..) |*spec, i| {
            spec.* = Any(.{ With(Marker(2 * i)), With(Marker(2 * i + 1)) });
        }
        break :blk out;
    };
    const spec = comptime Branch.spec(.all, &alternatives);
    try expectError(error.FilterTooComplex, init(allocator, &registry, spec));

    // One fewer alternative stays within the bound: 2^10 terms.
    const fewer = comptime Branch.spec(.all, alternatives[0 .. pairs - 1]);
    var filter = try init(allocator, &registry, fewer);
    defer filter.deinit(allocator);
    try expectEqual(max_terms, filter.term_count);
}

test "init simplifies full intermediate lists before rejecting them" {
    const allocator = std.testing.allocator;
    var registry = CompReg.init(allocator);
    defer registry.deinit();
    _ = try registry.register(Marker(0));
    _ = try registry.register(Marker(1));

    // Unsimplified, the cross product of these repeated alternatives would hold 2^12
    // terms, yet it collapses to the two alternatives themselves.
    const either = comptime Any(.{ With(Marker(0)), With(Marker(1)) });
    const factors: [12]Node.Spec = @splat(either);
    const repeated = comptime Branch.spec(.all, &factors);
    var filter = try init(allocator, &registry, repeated);
    defer filter.deinit(allocator);
    try expectEqual(2, filter.term_count);

    // The same holds for a wide `Any` whose children repeat.
    const copies: [600]Node.Spec = @splat(repeated);
    const wide = comptime Branch.spec(.any, &copies);
    var wide_filter = try init(allocator, &registry, wide);
    defer wide_filter.deinit(allocator);
    try expectEqual(2, wide_filter.term_count);
}

test "judgeArchetype combines terms into a decision" {
    const allocator = std.testing.allocator;
    var registry = CompReg.init(allocator);
    defer registry.deinit();

    const position = try registry.register(Position);
    const velocity = try registry.register(Velocity);
    const frozen = try registry.register(Frozen);

    var only_position = Entity.Signature.init(allocator);
    defer only_position.deinit(allocator);
    try only_position.add(allocator, &.{position});

    var only_velocity = Entity.Signature.init(allocator);
    defer only_velocity.deinit(allocator);
    try only_velocity.add(allocator, &.{velocity});

    var position_velocity = Entity.Signature.init(allocator);
    defer position_velocity.deinit(allocator);
    try position_velocity.add(allocator, &.{ position, velocity });

    var position_frozen = Entity.Signature.init(allocator);
    defer position_frozen.deinit(allocator);
    try position_frozen.add(allocator, &.{ position, frozen });

    var unmentioned = Entity.Signature.init(allocator);
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
        try expectEqual(
            if (require) Decision.reject else Decision.accept,
            filter.judgeArchetype(unmentioned),
        );
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

test "judgeArchetype handles signatures wider than the filter" {
    const allocator = std.testing.allocator;
    var registry = CompReg.init(allocator);
    defer registry.deinit();

    const position = try registry.register(Position);

    var has_position = try init(allocator, &registry, With(Position));
    defer has_position.deinit(allocator);
    var lacks_position = try init(allocator, &registry, Without(Position));
    defer lacks_position.deinit(allocator);
    try expectEqual(1, has_position.width);

    // Components registered later land beyond the filter's width.
    var last: CompId = undefined;
    inline for (0..70) |i| last = try registry.register(Marker(i));

    var wide = Entity.Signature.init(allocator);
    defer wide.deinit(allocator);
    try wide.add(allocator, &.{ position, last });
    try expect(bitOf(last) >= word_bits);

    try expectEqual(Decision.accept, has_position.judgeArchetype(wide));
    try expectEqual(Decision.reject, lacks_position.judgeArchetype(wide));
    try expect(has_position.judgeEntity(wide));
    try expect(!lacks_position.judgeEntity(wide));
}

test "judgeEntity checks sparse components on undecided archetypes" {
    const allocator = std.testing.allocator;
    var registry = CompReg.init(allocator);
    defer registry.deinit();

    const position = try registry.register(Position);
    _ = try registry.register(Velocity);
    const health = try registry.register(Health);

    var position_health = Entity.Signature.init(allocator);
    defer position_health.deinit(allocator);
    try position_health.add(allocator, &.{ position, health });

    var position_only = Entity.Signature.init(allocator);
    defer position_only.deinit(allocator);
    try position_only.add(allocator, &.{position});

    inline for (.{ With(Health), Without(Health) }) |spec| {
        var filter = try init(allocator, &registry, spec);
        defer filter.deinit(allocator);
        try expectEqual(1, filter.term_count);
        const only = filter.term(0);
        try expect(isZero(only.with));
        try expect(isZero(only.without));
        try expectEqual(spec.leaf.require, hasBit(only.sparse_with, bitOf(health)));
        try expectEqual(!spec.leaf.require, hasBit(only.sparse_without, bitOf(health)));
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

    // Terms constrain the same archetype differently, so the entity phase rechecks both.
    {
        var filter = try init(allocator, &registry, Any(.{
            All(.{ With(Position), With(Health) }),
            All(.{ Without(Position), Without(Health) }),
        }));
        defer filter.deinit(allocator);
        var neither = Entity.Signature.init(allocator);
        defer neither.deinit(allocator);
        try expect(filter.judgeArchetype(position_only) == .per_entity);
        try expect(filter.judgeArchetype(neither) == .per_entity);
        try expect(filter.judgeEntity(position_health));
        try expect(!filter.judgeEntity(position_only));
        try expect(filter.judgeEntity(neither));
    }
}

test "empty roots and branches preserve logical identities" {
    const allocator = std.testing.allocator;
    var registry = CompReg.init(allocator);
    defer registry.deinit();
    const position = try registry.register(Position);

    var absent = Entity.Signature.init(allocator);
    defer absent.deinit(allocator);
    var present = Entity.Signature.init(allocator);
    defer present.deinit(allocator);
    try present.add(allocator, &.{position});

    {
        var filter = try init(allocator, &registry, .{});
        defer filter.deinit(allocator);
        try expectEqual(1, filter.term_count);
        try expectEqual(Decision.accept, filter.judgeArchetype(absent));
        try expectEqual(Decision.accept, filter.judgeArchetype(present));
        try expect(filter.judgeEntity(absent));
        try expect(filter.judgeEntity(present));
    }

    inline for (
        .{ All(.{}), Any(.{}), With(.{}), Without(.{}) },
        .{ true, false, true, true },
    ) |spec, matches| {
        var filter = try init(allocator, &registry, spec);
        defer filter.deinit(allocator);
        try expectEqual(@intFromBool(matches), filter.term_count);
        const expected: Decision = if (matches) .accept else .reject;
        try expectEqual(expected, filter.judgeArchetype(absent));
        try expectEqual(expected, filter.judgeArchetype(present));
        try expectEqual(matches, filter.judgeEntity(present));
    }

    var filter = try init(allocator, &registry, All(.{
        All(.{}),
        Any(.{ Any(.{}), With(Position) }),
    }));
    defer filter.deinit(allocator);
    try expectEqual(1, filter.term_count);
    try expectEqual(Decision.reject, filter.judgeArchetype(absent));
    try expectEqual(Decision.accept, filter.judgeArchetype(present));
}

test "isDisjoint compares every pair of terms" {
    const allocator = std.testing.allocator;
    var registry = CompReg.init(allocator);
    defer registry.deinit();
    _ = try registry.register(Position);
    _ = try registry.register(Velocity);
    _ = try registry.register(Frozen);
    _ = try registry.register(Health);

    const Case = struct { a: Node.Spec, b: Node.Spec, disjoint: bool };
    const cases = [_]Case{
        .{ .a = With(Position), .b = Without(Position), .disjoint = true },
        .{ .a = With(Health), .b = Without(Health), .disjoint = true },
        .{ .a = With(Position), .b = With(Velocity), .disjoint = false },
        .{ .a = Without(Position), .b = Without(Velocity), .disjoint = false },
        .{ .a = With(Position), .b = With(Position), .disjoint = false },
        .{ .a = All(.{ With(Position), With(Frozen) }), .b = Without(Frozen), .disjoint = true },
        // Every pair of terms must conflict, not just one pair.
        .{
            .a = Any(.{ With(Position), With(Velocity) }),
            .b = Any(.{ Without(Position), With(Frozen) }),
            .disjoint = false,
        },
        .{
            .a = Any(.{ With(Position), With(Velocity) }),
            .b = All(.{ Without(Position), Without(Velocity) }),
            .disjoint = true,
        },
        // Filters that match nothing are disjoint from everything, matching-all from nothing.
        .{ .a = All(.{ With(Position), Without(Position) }), .b = With(Position), .disjoint = true },
        .{ .a = All(.{}), .b = With(Position), .disjoint = false },
        .{ .a = All(.{}), .b = Any(.{}), .disjoint = true },
    };
    inline for (cases) |case| {
        var a = try init(allocator, &registry, case.a);
        defer a.deinit(allocator);
        var b = try init(allocator, &registry, case.b);
        defer b.deinit(allocator);
        try expectEqual(case.disjoint, a.isDisjoint(b));
        try expectEqual(case.disjoint, b.isDisjoint(a));
    }

    // The empty root matches everything.
    var any_position = try init(allocator, &registry, With(Position));
    defer any_position.deinit(allocator);
    try expect(!empty.isDisjoint(any_position));
    try expect(!any_position.isDisjoint(empty));
}
