const std = @import("std");

const src_files = [_][]const u8{
    "aabb.c",             "arena_allocator.c", "bitset.c",         "block_allocator.c",
    "body.c",             "broad_phase.c",     "capsule.c",        "compound.c",
    "constraint_graph.c", "contact.c",         "contact_solver.c", "convex_manifold.c",
    "core.c",             "distance.c",        "distance_joint.c", "dynamic_tree.c",
    "height_field.c",     "hull.c",            "id_pool.c",        "island.c",
    "joint.c",            "manifold.c",        "math_functions.c", "mesh.c",
    "mesh_contact.c",     "motor_joint.c",     "mover.c",          "mover_joint.c",
    "name_cache.c",       "parallel_for.c",    "parallel_joint.c", "physics_world.c",
    "pogo_joint.c",       "prismatic_joint.c", "recording.c",      "replay.c",
    "revolute_joint.c",   "scheduler.c",       "sensor.c",         "shape.c",
    "simd.c",             "solver.c",          "solver_set.c",     "sphere.c",
    "spherical_joint.c",  "table.c",           "timer.c",          "triangle_manifold.c",
    "types.c",            "weld_joint.c",      "wheel_joint.c",    "wide4.c",
    "wide8.c",            "world_snapshot.c",
};

pub const Artifact = struct {
    lib: *std.Build.Step.Compile,
    mod: *std.Build.Module,
    include_dir: std.Build.LazyPath,
    double_precision: bool,

    /// Attach the artifact to a module to import C static library with `@import("box3d")`.
    pub fn attach(self: Artifact, mod: *std.Build.Module) void {
        mod.addImport("box3d", self.mod);
        mod.linkLibrary(self.lib);
        if (self.double_precision) mod.addCMacro("BOX3D_DOUBLE_PRECISION", "1");
    }
};

pub fn build(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) Artifact {
    const dep = b.dependency("box3d", .{});
    const include_dir = dep.path("include");
    const src_dir = dep.path("src");

    const double_precision = b.option(
        bool,
        "box3d-double-precision",
        "Enable double precision for large worlds in Box3D (default: false).",
    ) orelse false;

    const disable_simd = b.option(
        bool,
        "box3d-disable-simd",
        "Disable SIMD math (slower) in Box3D (default: false).",
    ) orelse false;

    const validate = b.option(
        bool,
        "box3d-validate",
        "Enable heavy validation in Box3D (default: true). Only take effect in Debug builds.",
    ) orelse true;

    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, &.{ "-std=gnu17", "-ffp-contract=off" }) catch @panic("OOM");

    if (optimize != .debug) {
        flags.append(b.allocator, "-DNDEBUG") catch @panic("OOM");
    } else if (validate) {
        flags.append(b.allocator, "-DBOX3D_VALIDATE") catch @panic("OOM");
    }

    if (disable_simd) flags.append(b.allocator, "-DBOX3D_DISABLE_SIMD") catch @panic("OOM");
    if (double_precision) flags.append(b.allocator, "-DBOX3D_DOUBLE_PRECISION") catch @panic("OOM");

    const c_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_mod.addCSourceFiles(.{
        .root = src_dir,
        .files = &src_files,
        .flags = flags.items,
    });
    c_mod.addIncludePath(include_dir); // PUBLIC
    c_mod.addIncludePath(src_dir); // PRIVATE

    const os = target.result.os.tag;
    if (os != .windows and !os.isDarwin() and os != .emscripten and os != .wasi) {
        c_mod.linkSystemLibrary("m", .{});
    }

    const lib = b.addLibrary(.{
        .name = "box3d",
        .root_module = c_mod,
        .linkage = .static,
    });

    const tc = b.addTranslateC(.{
        .root_source_file = dep.path("include/box3d/box3d.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    tc.addIncludePath(include_dir);
    if (double_precision) tc.defineCMacro("BOX3D_DOUBLE_PRECISION", null);

    return .{
        .lib = lib,
        .mod = tc.createModule(),
        .include_dir = include_dir,
        .double_precision = double_precision,
    };
}
