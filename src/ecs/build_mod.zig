const std = @import("std");
const root = @import("../../build.zig");

pub const MOD_NAME = "ecs";

pub fn build(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    imports: []const std.Build.Module.Import,
) struct {
    mod: *std.Build.Module,
    test_step: *std.Build.Step,
} {
    const mod = b.addModule(root.MOD_NAME ++ "_" ++ MOD_NAME, .{
        .root_source_file = b.path("src/ecs/mod.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    });

    return .{
        .mod = mod,
        .test_step = root.buildTest(b, MOD_NAME, mod),
    };
}
