//! Composable filters for `Query`, evaluated against an entity signature.
//!
//! A filter is a comptime type declaring `pub fn matches(ctx: Context) bool`.
//! `With`, `Without` and the `All`/`Any`/`Not` operators implement that protocol,
//! and user-defined filters follow the same rule.

const engine = @import("engine");
const component = engine.ecs.component;
const CompId = component.Id;
const CompRegistry = component.Registry;
const Signature = engine.ecs.entity.Signature;

/// The entity state a filter inspects.
pub const Context = struct {
    registry: *const CompRegistry,
    signature: Signature,

    /// Whether the entity signature holds `T`. Returns false if `T` is not registered.
    pub fn has(self: Context, comptime T: type) bool {
        const id = self.registry.getByType(T) orelse return false;
        return self.signature.has(id);
    }

    /// Whether the entity signature holds the component `id`.
    ///
    /// `id` must be valid (not `CompId.invalid`).
    pub fn hasId(self: Context, id: CompId) bool {
        return self.signature.has(id);
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

/// Matches entities holding every component in `Ts`.
///
/// Accepts a single component type or a tuple of them: `With(A)` or
/// `With(.{ A, B })`. An empty tuple matches every entity.
pub fn With(comptime Ts: anytype) type {
    return makeFilter(true, "With", Ts);
}

/// Matches entities holding none of the components in `Ts`.
///
/// Accepts a single component type or a tuple of them: `Without(A)` or
/// `Without(.{ A, B })`.
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
    };
}

/// Matches when `F` does not match.
pub fn Not(comptime F: type) type {
    validate(.{F});
    return struct {
        pub fn matches(ctx: Context) bool {
            return !F.matches(ctx);
        }
    };
}

const std = @import("std");
const expect = std.testing.expect;
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

/// A registry with `Velocity`, `Frozen` and `Position` registered, and an entity
/// signature holding only `Position`.
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
        try self.signature.add(allocator, &.{position});

        return self;
    }

    fn deinit(self: *Setup, allocator: std.mem.Allocator) void {
        self.signature.deinit(allocator);
        self.registry.deinit();
    }

    fn context(self: *const Setup) Context {
        return .{ .registry = &self.registry, .signature = self.signature };
    }
};

test "With and Without match one or many components" {
    const allocator = std.testing.allocator;
    var setup = try Setup.init(allocator);
    defer setup.deinit(allocator);
    const ctx = setup.context();

    try expect(With(Position).matches(ctx));
    try expect(!With(Velocity).matches(ctx));
    try expect(!Without(Position).matches(ctx));
    try expect(Without(Velocity).matches(ctx));

    // Tuples require every component to be present (or absent).
    try expect(With(.{Position}).matches(ctx));
    try expect(!With(.{ Position, Velocity }).matches(ctx));
    try expect(Without(.{ Velocity, Frozen }).matches(ctx));
    try expect(!Without(.{ Velocity, Position }).matches(ctx));
    try expect(With(.{}).matches(ctx));

    try expect(ctx.hasId(setup.registry.getByType(Position).?));
    try expect(!ctx.hasId(setup.registry.getByType(Velocity).?));

    // An unregistered component is absent from every signature.
    const Unregistered = struct {
        pub const se_component: CompMark = .{};
    };
    try expect(!With(Unregistered).matches(ctx));
    try expect(Without(Unregistered).matches(ctx));
}

test "All, Any and Not compose filters" {
    const allocator = std.testing.allocator;
    var setup = try Setup.init(allocator);
    defer setup.deinit(allocator);
    const ctx = setup.context();

    try expect(All(.{ With(Position), Without(Velocity) }).matches(ctx));
    try expect(!All(.{ With(Position), With(Velocity) }).matches(ctx));

    try expect(Any(.{ With(Velocity), With(Position) }).matches(ctx));
    try expect(!Any(.{ With(Velocity), With(Frozen) }).matches(ctx));

    try expect(Not(With(Velocity)).matches(ctx));
    try expect(!Not(With(Position)).matches(ctx));

    // `matches` applies a whole tuple, and an empty tuple accepts everything.
    try expect(matches(.{ With(Position), Without(Velocity) }, ctx));
    try expect(!matches(.{ With(Position), With(Velocity) }, ctx));
    try expect(matches(.{}, ctx));
}
