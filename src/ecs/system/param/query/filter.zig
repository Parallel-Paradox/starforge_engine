//! Composable filters for `Query`.
//!
//! A filter is a comptime type declaring `pub fn matches(ctx: Context) bool`.
//! `With`, `Without` and `All`/`Any`/`Not` implement this protocol.
//!
//! Built-in operators also declare `archetypeDecision` and `matchesSparse`.
//! `archetypeDecision` inspects archetype-stored components; `matchesSparse`
//! inspects sparse-set components. A filter declaring either must declare both;
//! otherwise queries use `matches`.

const engine = @import("engine");
const component = engine.ecs.component;
const CompId = component.Id;
const CompRegistry = component.Registry;
const Signature = engine.ecs.entity.Signature;

/// The registry and signature a filter inspects.
/// `signature` is an entity signature for `matches` and an archetype signature for
/// `archetypeDecision`.
pub const Context = struct {
    registry: *const CompRegistry,
    signature: Signature,

    /// Whether the current signature holds `T`. Returns false if `T` is not registered.
    pub fn has(self: Context, comptime T: type) bool {
        const id = self.registry.getByType(T) orelse return false;
        return self.signature.has(id);
    }

    /// Whether the current signature holds the component `id`.
    ///
    /// `id` must be valid (not `CompId.invalid`).
    pub fn hasId(self: Context, id: CompId) bool {
        return self.signature.has(id);
    }
};

/// Outcome of evaluating a filter against an archetype signature.
pub const ArchetypeDecision = enum {
    /// Every entity in the archetype matches the filter.
    accept,
    /// No entity in the archetype can match the filter.
    reject,
    /// The archetype signature cannot decide; check each entity signature.
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

    /// Returns a filter's archetype decision. Filters without `archetypeDecision`
    /// return `.per_entity`.
    pub fn of(comptime F: type, ctx: Context) @This() {
        if (comptime @hasDecl(F, "archetypeDecision")) return F.archetypeDecision(ctx);
        return .per_entity;
    }
};

/// Asserts that `filters` is a tuple of filter types.
pub fn validate(comptime filters: anytype) void {
    switch (@typeInfo(@TypeOf(filters))) {
        .@"struct" => |info| if (!info.is_tuple) {
            @compileError("filters must be a tuple, e.g. .{ With(A), Without(B) }");
        },
        else => @compileError("filters must be a tuple, e.g. .{ With(A), Without(B) }"),
    }

    inline for (filters) |F| {
        if (!@hasDecl(F, "matches")) @compileError(
            @typeName(F) ++ " is not a filter: declare pub fn matches(Context) bool",
        );
    }
}

/// Returns true when every filter in `filters` matches `ctx`.
pub fn matches(comptime filters: anytype, ctx: Context) bool {
    validate(filters);
    inline for (filters) |F| {
        if (!F.matches(ctx)) return false;
    }
    return true;
}

/// Returns the archetype decision for a filter tuple.
pub fn archetypeDecision(comptime filters: anytype, ctx: Context) ArchetypeDecision {
    validate(filters);
    var result: ArchetypeDecision = .accept;
    inline for (filters) |F| {
        result = result.all(ArchetypeDecision.of(F, ctx));
    }
    return result;
}

/// Checks the sparse-set parts of a filter tuple. Requires the archetype-level checks
/// to have passed.
pub fn matchesSparse(comptime filters: anytype, ctx: Context) bool {
    validate(filters);
    inline for (filters) |F| {
        switch (ArchetypeDecision.of(F, ctx)) {
            .accept => {},
            .reject => return false,
            .per_entity => {
                if (!sparseOf(F, ctx)) return false;
            },
        }
    }
    return true;
}

/// Returns `F.matchesSparse`, or `F.matches` when `F` lacks the two-stage methods.
fn sparseOf(comptime F: type, ctx: Context) bool {
    if (comptime @hasDecl(F, "matchesSparse") and @hasDecl(F, "archetypeDecision"))
        return F.matchesSparse(ctx);
    return F.matches(ctx);
}

/// Returns the archetype decision for one component requirement.
fn componentDecision(comptime require: bool, ctx: Context, comptime T: type) ArchetypeDecision {
    const id = ctx.registry.getByType(T) orelse
        return if (require) .reject else .accept;
    if (T.se_component.storage == .sparse_set) return .per_entity;

    return if (ctx.signature.has(id) == require) .accept else .reject;
}

/// Checks one sparse-set component requirement. Archetype components always pass.
fn componentSparse(comptime require: bool, ctx: Context, comptime T: type) bool {
    if (T.se_component.storage != .sparse_set) return true;
    return ctx.has(T) == require;
}

/// Matches entities holding every component in `Ts`.
/// `Ts` is a component type or a tuple. An empty tuple matches every entity.
pub fn With(comptime Ts: anytype) type {
    return makeFilter(true, "With", Ts);
}

/// Matches entities holding none of the components in `Ts`.
/// `Ts` is a component type or a tuple.
pub fn Without(comptime Ts: anytype) type {
    return makeFilter(false, "Without", Ts);
}

fn makeFilter(comptime require: bool, comptime operator: []const u8, comptime arg: anytype) type {
    return switch (@typeInfo(@TypeOf(arg))) {
        .type => singleFilter(require, operator, arg),
        .@"struct" => |info| if (info.is_tuple)
            manyFilter(require, operator, arg)
        else
            @compileError(operator ++ " expects a component type or a tuple of them"),
        else => @compileError(operator ++ " expects a component type or a tuple of them"),
    };
}

fn singleFilter(comptime require: bool, comptime operator: []const u8, comptime T: type) type {
    comptime component.assertComponent(T, operator);
    return struct {
        pub fn matches(ctx: Context) bool {
            return ctx.has(T) == require;
        }

        /// Returns this filter's archetype decision.
        pub fn archetypeDecision(ctx: Context) ArchetypeDecision {
            return componentDecision(require, ctx, T);
        }

        /// Checks the sparse-set part. Call only when the archetype decision is
        /// `.per_entity`.
        pub fn matchesSparse(ctx: Context) bool {
            return componentSparse(require, ctx, T);
        }
    };
}

fn manyFilter(comptime require: bool, comptime operator: []const u8, comptime Ts: anytype) type {
    inline for (Ts) |T| {
        comptime component.assertComponent(T, operator);
    }
    return struct {
        pub fn matches(ctx: Context) bool {
            inline for (Ts) |T| {
                if (ctx.has(T) != require) return false;
            }
            return true;
        }

        /// Returns this filter's archetype decision.
        pub fn archetypeDecision(ctx: Context) ArchetypeDecision {
            var result: ArchetypeDecision = .accept;
            inline for (Ts) |T| {
                result = result.all(componentDecision(require, ctx, T));
            }
            return result;
        }

        /// Checks the sparse-set requirements. Call only when the archetype decision is
        /// `.per_entity`.
        pub fn matchesSparse(ctx: Context) bool {
            inline for (Ts) |T| {
                if (!componentSparse(require, ctx, T)) return false;
            }
            return true;
        }
    };
}

/// Matches when every filter in `filters` matches.
pub fn All(comptime filters: anytype) type {
    validate(filters);
    return struct {
        pub fn matches(ctx: Context) bool {
            inline for (filters) |F| {
                if (!F.matches(ctx)) return false;
            }
            return true;
        }

        /// Returns this filter's archetype decision.
        pub fn archetypeDecision(ctx: Context) ArchetypeDecision {
            var result: ArchetypeDecision = .accept;
            inline for (filters) |F| {
                result = result.all(ArchetypeDecision.of(F, ctx));
            }
            return result;
        }

        /// Checks the sparse-set parts not decided by the archetype.
        pub fn matchesSparse(ctx: Context) bool {
            inline for (filters) |F| {
                switch (ArchetypeDecision.of(F, ctx)) {
                    .accept => {},
                    .reject => return false,
                    .per_entity => {
                        if (!sparseOf(F, ctx)) return false;
                    },
                }
            }
            return true;
        }
    };
}

/// Matches when at least one filter in `filters` matches.
pub fn Any(comptime filters: anytype) type {
    validate(filters);
    return struct {
        pub fn matches(ctx: Context) bool {
            inline for (filters) |F| {
                if (F.matches(ctx)) return true;
            }
            return false;
        }

        /// Returns this filter's archetype decision.
        pub fn archetypeDecision(ctx: Context) ArchetypeDecision {
            var result: ArchetypeDecision = .reject;
            inline for (filters) |F| {
                result = result.any(ArchetypeDecision.of(F, ctx));
            }
            return result;
        }

        /// Checks the sparse-set parts not decided by the archetype.
        pub fn matchesSparse(ctx: Context) bool {
            inline for (filters) |F| {
                switch (ArchetypeDecision.of(F, ctx)) {
                    .accept => return true,
                    .reject => {},
                    .per_entity => {
                        if (sparseOf(F, ctx)) return true;
                    },
                }
            }
            return false;
        }
    };
}

/// Matches when `F` does not match.
pub fn Not(comptime F: type) type {
    validate(.{F});
    return struct {
        pub fn matches(ctx: Context) bool {
            return !F.matches(ctx);
        }

        /// Returns this filter's archetype decision.
        pub fn archetypeDecision(ctx: Context) ArchetypeDecision {
            return switch (ArchetypeDecision.of(F, ctx)) {
                .accept => .reject,
                .reject => .accept,
                .per_entity => .per_entity,
            };
        }

        /// Checks the sparse-set part not decided by the archetype.
        pub fn matchesSparse(ctx: Context) bool {
            return switch (ArchetypeDecision.of(F, ctx)) {
                .accept => false,
                .reject => true,
                .per_entity => !sparseOf(F, ctx),
            };
        }
    };
}

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const CompMark = component.Mark;

const Position = struct {
    pub const se_component: CompMark = .{};
    x: i32,
};

const Velocity = struct {
    pub const se_component: CompMark = .{};
    y: i32,
};

const Frozen = struct {
    pub const se_component: CompMark = .{};
};

const Health = struct {
    pub const se_component: CompMark = .{ .storage = .sparse_set };
    value: i32,
};

/// Builds a signature from `ids`.
fn signatureWith(allocator: std.mem.Allocator, ids: []const CompId) !Signature {
    var signature = Signature.init(allocator);
    errdefer signature.deinit(allocator);
    try signature.add(allocator, ids);
    return signature;
}

/// A registry with `Velocity`, `Frozen`, `Health` and `Position` registered, and an
/// entity signature holding only `Position`.
const Setup = struct {
    registry: CompRegistry,
    signature: Signature,

    fn init(allocator: std.mem.Allocator) !Setup {
        var self: Setup = .{
            .registry = CompRegistry.init(allocator),
            .signature = Signature.init(allocator),
        };
        errdefer self.deinit(allocator);

        _ = try self.registry.register(Velocity);
        _ = try self.registry.register(Frozen);
        const position = try self.registry.register(Position);
        _ = try self.registry.register(Health);
        try self.signature.add(allocator, &.{position});

        return self;
    }

    fn deinit(self: *Setup, allocator: std.mem.Allocator) void {
        self.signature.deinit(allocator);
        self.registry.deinit();
    }

    fn context(self: *const Setup) Context {
        return self.contextWith(self.signature);
    }

    fn contextWith(self: *const Setup, signature: Signature) Context {
        return .{ .registry = &self.registry, .signature = signature };
    }
};

test "matches evaluates leaf and composed filters" {
    const allocator = std.testing.allocator;
    var setup = try Setup.init(allocator);
    defer setup.deinit(allocator);
    const ctx = setup.context();

    // Leaf filters.
    try expect(With(Position).matches(ctx));
    try expect(!With(Velocity).matches(ctx));
    try expect(!Without(Position).matches(ctx));
    try expect(Without(Velocity).matches(ctx));
    try expect(With(.{Position}).matches(ctx));
    try expect(!With(.{ Position, Velocity }).matches(ctx));
    try expect(Without(.{ Velocity, Frozen }).matches(ctx));
    try expect(!Without(.{ Velocity, Position }).matches(ctx));
    try expect(With(.{}).matches(ctx));

    // Composed filters and the tuple wrapper.
    try expect(All(.{ With(Position), Without(Velocity) }).matches(ctx));
    try expect(!All(.{ With(Position), With(Velocity) }).matches(ctx));
    try expect(Any(.{ With(Velocity), With(Position) }).matches(ctx));
    try expect(!Any(.{ With(Velocity), With(Frozen) }).matches(ctx));
    try expect(Not(With(Velocity)).matches(ctx));
    try expect(!Not(With(Position)).matches(ctx));
    try expect(matches(.{ With(Position), Without(Velocity) }, ctx));
    try expect(!matches(.{ With(Position), With(Velocity) }, ctx));
    try expect(matches(.{}, ctx));

    try expect(ctx.hasId(setup.registry.getByType(Position).?));
    try expect(!ctx.hasId(setup.registry.getByType(Velocity).?));

    // Unregistered components are absent.
    const Unregistered = struct {
        pub const se_component: CompMark = .{};
    };
    try expect(!With(Unregistered).matches(ctx));
    try expect(Without(Unregistered).matches(ctx));
}

test "archetypeDecision decides from archetype components and defers sparse ones" {
    const allocator = std.testing.allocator;
    var setup = try Setup.init(allocator);
    defer setup.deinit(allocator);

    var archetype = try signatureWith(allocator, &.{setup.registry.getByType(Position).?});
    defer archetype.deinit(allocator);
    const ctx = setup.contextWith(archetype);

    try expectEqual(.accept, With(Position).archetypeDecision(ctx));
    try expectEqual(.reject, With(Velocity).archetypeDecision(ctx));
    try expectEqual(.reject, Without(Position).archetypeDecision(ctx));
    try expectEqual(.accept, Without(Velocity).archetypeDecision(ctx));

    // Sparse components cannot be decided from the archetype signature.
    try expectEqual(.per_entity, With(Health).archetypeDecision(ctx));
    try expectEqual(.per_entity, Without(Health).archetypeDecision(ctx));

    // Mixed filters check the archetype part first.
    try expectEqual(.per_entity, With(.{ Position, Health }).archetypeDecision(ctx));
    try expectEqual(.reject, With(.{ Velocity, Health }).archetypeDecision(ctx));
    try expectEqual(.reject, Without(.{ Position, Health }).archetypeDecision(ctx));
    try expectEqual(.per_entity, Without(.{ Velocity, Health }).archetypeDecision(ctx));

    // `Any` accepts the archetype as soon as one branch matches.
    try expectEqual(.accept, Any(.{ With(Position), With(Health) }).archetypeDecision(ctx));
    try expectEqual(.per_entity, Any(.{ With(Velocity), With(Health) }).archetypeDecision(ctx));
    try expectEqual(.per_entity, Not(With(Health)).archetypeDecision(ctx));
    try expectEqual(.reject, Not(With(Position)).archetypeDecision(ctx));

    // Unregistered components are absent from every entity.
    const Unregistered = struct {
        pub const se_component: CompMark = .{};
    };
    try expectEqual(.reject, With(Unregistered).archetypeDecision(ctx));
    try expectEqual(.accept, Without(Unregistered).archetypeDecision(ctx));

    // The tuple-level wrapper combines the filters like `All`.
    try expectEqual(.accept, archetypeDecision(.{ With(Position), Without(Velocity) }, ctx));
    try expectEqual(.reject, archetypeDecision(.{With(Velocity)}, ctx));
    try expectEqual(.per_entity, archetypeDecision(.{With(Health)}, ctx));
}

test "matchesSparse checks only sparse components" {
    const allocator = std.testing.allocator;
    var setup = try Setup.init(allocator);
    defer setup.deinit(allocator);

    const position = setup.registry.getByType(Position).?;
    const health = setup.registry.getByType(Health).?;

    var with_health = try signatureWith(allocator, &.{ position, health });
    defer with_health.deinit(allocator);
    var without_health = try signatureWith(allocator, &.{position});
    defer without_health.deinit(allocator);

    const ctx_with = setup.contextWith(with_health);
    const ctx_without = setup.contextWith(without_health);

    // Archetype components are assumed satisfied; only sparse components are checked.
    try expect(With(Position).matchesSparse(ctx_without));
    try expect(Without(Velocity).matchesSparse(ctx_without));
    try expect(With(Health).matchesSparse(ctx_with));
    try expect(!With(Health).matchesSparse(ctx_without));
    try expect(!Without(Health).matchesSparse(ctx_with));
    try expect(Without(Health).matchesSparse(ctx_without));

    try expect(With(.{ Position, Health }).matchesSparse(ctx_with));
    try expect(!With(.{ Position, Health }).matchesSparse(ctx_without));
    try expect(Without(.{ Velocity, Health }).matchesSparse(ctx_without));
    try expect(!Without(.{ Velocity, Health }).matchesSparse(ctx_with));

    // Composition consults the archetype decision before running sparse checks.
    try expect(All(.{ With(Position), With(Health) }).matchesSparse(ctx_with));
    try expect(!All(.{ With(Position), With(Health) }).matchesSparse(ctx_without));
    try expect(Any(.{ With(Position), With(Health) }).matchesSparse(ctx_without));
    try expect(Any(.{ With(Velocity), With(Health) }).matchesSparse(ctx_with));
    try expect(!Any(.{ With(Velocity), With(Health) }).matchesSparse(ctx_without));
    try expect(Not(With(Health)).matchesSparse(ctx_without));
    try expect(!Not(With(Health)).matchesSparse(ctx_with));

    // The tuple-level wrapper applies the same sparse checks.
    try expect(matchesSparse(.{ With(Position), With(Health) }, ctx_with));
    try expect(!matchesSparse(.{ With(Position), With(Health) }, ctx_without));
    try expect(matchesSparse(.{Any(.{ With(Position), With(Health) })}, ctx_without));
}
