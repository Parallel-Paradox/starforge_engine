const std = @import("std");

pub const mod_name = "starforge";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule(mod_name, .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_suites = b.addTest(.{ .name = "test", .root_module = mod });
    const test_step = b.step("test", "Run all test suites");
    const test_cmd = b.addRunArtifact(test_suites);
    test_step.dependOn(&test_cmd.step);

    buildExamples(b, target, optimize, mod);
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
