const std = @import("std");

const engine = @import("engine");

pub const Id = engine.ecs.Id;
pub const Meta = @import("Meta.zig");
pub const Registry = @import("Registry.zig");

/// Storage type for components.
pub const Storage = enum { archetype, sparse_set };

/// Declare `pub const se_component: Mark = .{};` in a type to mark it as a component.
pub const Mark = struct {
    /// Selects layout.
    storage: Storage = .archetype,
    /// Components this one depends on. Cycles are allowed, but self-requires
    /// are not: a component appears at most once per entity, so the closure
    /// terminates.
    require: []const type = &.{},
};

/// Whether `T` is a type marked by `pub const se_component: Mark = .{};`.
pub fn isComponent(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => return false,
    }
    if (comptime @hasDecl(T, "se_component")) {
        return @TypeOf(T.se_component) == Mark;
    }
    return false;
}

/// Asserts that `T` is a component.
///
/// `context` optionally names the operation that requires a component, so the compile
/// error points at the caller; it falls back to `assertComponent` when null.
pub fn assertComponent(comptime T: type, comptime context: ?[]const u8) void {
    const ctx = context orelse "assertComponent";

    if (comptime isComponent(T)) {
        const require = T.se_component.require;
        inline for (require, 0..) |Req, i| {
            if (comptime !isComponent(Req)) @compileError(
                ctx ++ " requires component " ++ @typeName(T) ++
                    "; its `se_component.require` contains " ++ @typeName(Req) ++
                    ", which is not a component",
            );
            if (comptime Req == T) @compileError(
                ctx ++ " requires component " ++ @typeName(T) ++
                    "; its `se_component.require` cannot list itself",
            );
            if (comptime contains(require[0..i], Req)) @compileError(
                ctx ++ " requires component " ++ @typeName(T) ++
                    "; its `se_component.require` lists " ++ @typeName(Req) ++
                    " more than once",
            );
        }
    } else {
        @compileError(
            ctx ++ " requires a component type, got " ++ @typeName(T) ++
                "; declare `pub const se_component: Mark = .{};`",
        );
    }
}

/// Returns every component `T` requires, directly or transitively, in depth-first
/// order. `T` itself is never included, so a cycle back to `T` stops there.
///
/// The slice points at comptime memory and excludes `T` by construction.
pub fn requireClosure(comptime T: type) []const type {
    @setEvalBranchQuota(1_000_000);
    return visit(&.{T}, T)[1..];
}

fn visit(comptime visited: []const type, comptime T: type) []const type {
    assertComponent(T, "requireClosure");
    return visitAt(visited, T, 0);
}

fn visitAt(comptime visited: []const type, comptime T: type, comptime index: usize) []const type {
    if (index == T.se_component.require.len) return visited;

    const Req = T.se_component.require[index];
    if (contains(visited, Req)) return visitAt(visited, T, index + 1);
    return visitAt(visit(visited ++ [1]type{Req}, Req), T, index + 1);
}

fn contains(comptime list: []const type, comptime T: type) bool {
    inline for (list) |x| if (x == T) return true;
    return false;
}

test "assertComponent accepts components and checks their requirements" {
    const Base = struct {
        pub const se_component: Mark = .{};
    };
    const Derived = struct {
        pub const se_component: Mark = .{ .require = &.{Base} };
    };

    assertComponent(Base, null);
    assertComponent(Derived, "Derived");

    // Compile errors:
    // _ = assertComponent(u32, "Probe");
    // const Duplicate = struct {
    //     pub const se_component: Mark = .{ .require = &.{ Base, Base } };
    // };
    // assertComponent(Duplicate, "Duplicate");
    // const Invalid = struct {
    //     pub const se_component: Mark = .{ .require = &.{u32} };
    // };
    // assertComponent(Invalid, "Invalid");
    // const Scope = struct {
    //     const Selfish = struct {
    //         pub const se_component: Mark = .{ .require = &.{Selfish} };
    //     };
    // };
    // assertComponent(Scope.Selfish, "Selfish");
}

const expect = std.testing.expect;

/// Asserts that `T`'s closure contains exactly `expected`, in order.
fn expectClosure(comptime T: type, comptime expected: []const type) !void {
    const got = comptime requireClosure(T);
    try expect(expected.len == got.len);
    inline for (expected, 0..) |want, i| try expect(comptime want == got[i]);
}

test "requireClosure collects transitive requirements once" {
    const D = struct {
        pub const se_component: Mark = .{};
    };
    const B = struct {
        pub const se_component: Mark = .{ .require = &.{D} };
    };
    const C = struct {
        pub const se_component: Mark = .{ .require = &.{D} };
    };
    const A = struct {
        pub const se_component: Mark = .{ .require = &.{ B, C } };
    };

    try expectClosure(D, &.{});
    try expectClosure(B, &.{D});
    try expectClosure(C, &.{D});
    try expectClosure(A, &.{ B, D, C });
}

test "requireClosure terminates on cycles" {
    const Graphs = struct {
        const Pair = struct {
            const A = struct {
                pub const se_component: Mark = .{ .require = &.{B} };
            };
            const B = struct {
                pub const se_component: Mark = .{ .require = &.{A} };
            };
        };

        const Ring = struct {
            const A = struct {
                pub const se_component: Mark = .{ .require = &.{B} };
            };
            const B = struct {
                pub const se_component: Mark = .{ .require = &.{C} };
            };
            const C = struct {
                pub const se_component: Mark = .{ .require = &.{A} };
            };
        };
    };

    try expectClosure(Graphs.Pair.A, &.{Graphs.Pair.B});
    try expectClosure(Graphs.Pair.B, &.{Graphs.Pair.A});
    try expectClosure(Graphs.Ring.A, &.{ Graphs.Ring.B, Graphs.Ring.C });
    try expectClosure(Graphs.Ring.B, &.{ Graphs.Ring.C, Graphs.Ring.A });
    try expectClosure(Graphs.Ring.C, &.{ Graphs.Ring.A, Graphs.Ring.B });
}

test {
    _ = Meta;
    _ = Registry;
}
