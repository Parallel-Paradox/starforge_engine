//! World-owned resources marked with `se_resource: Mark`.
//! Default construction follows `reflect.Default`: `pub fn default() T`, otherwise
//! struct field defaults. Destruction follows `reflect.TypeMeta`: only a public
//! `fn deinit(self: *T) void` is called automatically; other types are treated as trivial.

const engine = @import("engine");

pub const Id = engine.ecs.Id;
pub const Registry = @import("Registry.zig");

/// Declare `pub const se_resource: Mark = .{};` in a type to mark it as a resource.
pub const Mark = struct {};

/// Whether `T` declares a resource marker of type `Mark`.
pub fn isResource(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => return false,
    }
    if (comptime @hasDecl(T, "se_resource")) {
        return @TypeOf(T.se_resource) == Mark;
    }
    return false;
}

/// Asserts that `T` is a resource, naming the requiring operation when provided.
pub fn assertResource(comptime T: type, comptime context: ?[]const u8) void {
    if (comptime !isResource(T)) @compileError(
        (context orelse "assertResource") ++ " requires a resource type, got " ++
            @typeName(T) ++ "; declare `pub const se_resource: Mark = .{};`",
    );
}

test {
    _ = Registry;
}

test "resource markers must have type Mark" {
    const std = @import("std");
    const Good = struct {
        pub const se_resource: Mark = .{};
    };
    const Wrong = struct {
        pub const se_resource = true;
    };

    assertResource(Good, null);
    try std.testing.expect(!isResource(Wrong));
    try std.testing.expect(!isResource(struct {}));
    try std.testing.expect(!isResource(u32));
}
