const std = @import("std");
const engine = @import("engine");
const ecs = engine.ecs;
const Archetype = ecs.Archetype;
const reflect = engine.reflect;
const TypeId = reflect.TypeId;
const expectEqual = std.testing.expectEqual;
const TestMark = ecs.component.Mark;

pub const Position = struct {
    pub const se_component: TestMark = .{};
    x: i32,
    y: i32,
};

pub const Velocity = struct {
    pub const se_component: TestMark = .{};
    dx: i32,
    dy: i32,
};

pub const Health = struct {
    pub const se_component: TestMark = .{ .storage = .sparse_set };
    value: u32,
};

pub const Probe = struct {
    pub const se_component: TestMark = .{};
    calls: *usize,

    pub fn deinit(self: *@This()) void {
        self.calls.* += 1;
    }
};

pub const Tag = struct {
    pub const se_component: TestMark = .{};
};

pub const SparseTag = struct {
    pub const se_component: TestMark = .{ .storage = .sparse_set };
    pub var destroyed: usize = 0;

    pub fn deinit(_: *@This()) void {
        destroyed += 1;
    }
};

pub const AutoRequirement = struct {
    pub const se_component: TestMark = .{ .storage = .sparse_set };
    value: u32 = 7,
    pub var created: usize = 0;
    pub var destroyed: usize = 0;

    pub fn default() @This() {
        created += 1;
        return .{};
    }

    pub fn deinit(self: *@This()) void {
        _ = self;
        destroyed += 1;
    }
};

pub fn expectArchetypeValue(
    archetype: *const Archetype,
    comptime T: type,
    row: usize,
    expected: T,
) !void {
    const column = archetype.meta.id_to_col.get(TypeId.of(T)).?;
    try expectEqual(expected, archetype.typedAt(T, column, row).ptr.*);
}

pub const RequirementGraph = struct {
    pub const Root = struct {
        pub const se_component: TestMark = .{ .require = &.{ Left, Right } };
        value: u32,
    };
    pub const Left = struct {
        pub const se_component: TestMark = .{ .require = &.{Shared} };
        value: u32 align(64) = 11,
    };
    pub const Right = struct {
        pub const se_component: TestMark = .{ .storage = .sparse_set, .require = &.{Shared} };
        value: u32,
        pub var calls: usize = 0;

        pub fn default() @This() {
            calls += 1;
            return .{ .value = 22 };
        }
    };
    pub const Shared = struct {
        pub const se_component: TestMark = .{ .require = &.{Root} };
        pub var created: usize = 0;
        pub var destroyed: usize = 0;

        pub fn default() @This() {
            created += 1;
            return .{};
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
            destroyed += 1;
        }
    };
};
