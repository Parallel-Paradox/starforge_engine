const std = @import("std");
const root = @import("../../build.zig");

pub const mod_name = "base";

pub fn build(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) struct {
    mod: *std.Build.Module,
    test_step: *std.Build.Step,
} {
    const mod = b.addModule(root.mod_name ++ "_" ++ mod_name, .{
        .root_source_file = b.path("src/base/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    return .{
        .mod = mod,
        .test_step = root.buildTest(b, mod_name, mod),
    };
}
