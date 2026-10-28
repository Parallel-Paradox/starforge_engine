const engine = @import("engine");

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

/// Asserts that `T` is a component.
///
/// `context` optionally names the operation that requires a component, so the compile
/// error points at the caller; it falls back to `assertComponent` when null.
pub fn assertComponent(comptime T: type, comptime context: ?[]const u8) void {
    if (comptime !isComponent(T)) @compileError(
        (context orelse "assertComponent") ++ " requires a component type, got " ++
            @typeName(T) ++ "; declare `pub const se_component: Mark = .{};`",
    );
}

test "assertComponent takes an optional context" {
    const Probe = struct {
        pub const se_component: Mark = .{};
    };

    assertComponent(Probe, null);
    assertComponent(Probe, "Probe");
}

test {
    _ = Meta;
    _ = Registry;
}
