pub const engine = @import("engine");

pub const Id = engine.ecs.Id;
pub const Meta = @import("Meta.zig");
pub const Registry = @import("Registry.zig");

/// Storage type for components.
pub const Storage = enum { archetype, sparse_set };

/// Declare `pub const se_component: Mark = .{};` in a type to mark it as a component.
/// The `storage` field selects its layout.
pub const Mark = struct { storage: Storage = .archetype };

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

test {
    _ = Meta;
    _ = Registry;
}
