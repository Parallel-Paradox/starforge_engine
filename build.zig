const std = @import("std");

const base = @import("src/base/build_mod.zig");
const trace = @import("src/trace/build_mod.zig");
const reflect = @import("src/reflect/build_mod.zig");
const ecs = @import("src/ecs/build_mod.zig");

pub const mod_name = "starforge";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_base = base.build(b, target, optimize);
    const build_trace = trace.build(b, target, optimize, &.{
        .{ .name = base.mod_name, .module = build_base.mod },
    });
    const build_reflect = reflect.build(b, target, optimize, &.{
        .{ .name = base.mod_name, .module = build_base.mod },
    });
    const build_ecs = ecs.build(b, target, optimize, &.{
        .{ .name = base.mod_name, .module = build_base.mod },
        .{ .name = trace.mod_name, .module = build_trace.mod },
        .{ .name = reflect.mod_name, .module = build_reflect.mod },
    });

    const mod_starforge = b.addModule(mod_name, .{
        .root_source_file = b.path("src/mod.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = base.mod_name, .module = build_base.mod },
            .{ .name = trace.mod_name, .module = build_trace.mod },
        },
    });

    const test_step = b.step("test", "Run all test suites");
    test_step.dependOn(build_base.test_step);
    test_step.dependOn(build_trace.test_step);
    test_step.dependOn(build_reflect.test_step);
    test_step.dependOn(build_ecs.test_step);

    buildExamples(b, target, optimize, mod_starforge);
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

fn buildExamples(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    mod_starforge: *std.Build.Module,
) void {
    inline for ([_]struct {
        name: []const u8,
        path: []const u8,
    }{
        .{ .name = "trace", .path = "examples/trace.zig" },
    }) |example_config| {
        const name = example_config.name;
        const path = example_config.path;

        const prefix = "example-" ++ name;
        const example_mod = b.addModule(prefix, .{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        example_mod.addImport("starforge", mod_starforge);

        const example = b.addExecutable(.{
            .name = prefix,
            .root_module = example_mod,
        });
        const build_example_cmd = b.addInstallArtifact(example, .{});

        // Add cmd: zig build example-{name}
        const run_step_desc = "Run example: " ++ name;
        const run_step = b.step(prefix, run_step_desc);
        const run_example_cmd = b.addRunArtifact(example);
        run_example_cmd.step.dependOn(&build_example_cmd.step);
        run_step.dependOn(&run_example_cmd.step);
        run_example_cmd.addPassthruArgs();
    }
}
