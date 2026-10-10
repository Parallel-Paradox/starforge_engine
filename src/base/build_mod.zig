const std = @import("std");
const root = @import("../../build.zig");

pub const MOD_NAME = "base";

pub fn build(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) struct {
    mod: *std.Build.Module,
    test_step: *std.Build.Step,
} {
    const mod = b.addModule(root.MOD_NAME ++ "_" ++ MOD_NAME, .{
        .root_source_file = b.path("src/base/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    return .{
        .mod = mod,
        .test_step = root.buildTest(b, MOD_NAME, mod),
    };
}
