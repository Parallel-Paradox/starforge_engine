const std = @import("std");

const base = @import("src/base/build_mod.zig");

pub const MOD_NAME = "starforge";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_base = base.build(b, target, optimize);

    _ = b.addModule(MOD_NAME, .{
        .root_source_file = b.path("src/mod.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = base.MOD_NAME, .module = build_base.mod },
        },
    });

    const test_step = b.step("test", "Run all test suites");
    test_step.dependOn(build_base.test_step);
}

pub fn buildTest(b: *std.Build, comptime name: []const u8, mod: *std.Build.Module) *std.Build.Step {
    const prefix = "test-" ++ name;
    const mod_tests = b.addTest(.{
        .name = prefix,
        .root_module = mod,
    });

    const test_step_desc = "Run tests of " ++ name;
    const test_step = b.step(prefix, test_step_desc);
    const test_mod_cmd = b.addRunArtifact(mod_tests);
    test_step.dependOn(&test_mod_cmd.step);
    return &test_mod_cmd.step;
}
