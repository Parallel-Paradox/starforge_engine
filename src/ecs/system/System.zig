const System = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const World = engine.ecs.World;
const TypeMeta = engine.reflect.TypeMeta;
const param = @import("param.zig");
const mod = @import("mod.zig");

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    run: *const fn (self: *anyopaque, world: *World) anyerror!void,
    deinit: *const fn (self: *anyopaque, world: *World) void,
};

pub fn run(self: *@This(), world: *World) anyerror!void {
    return self.vtable.run(self.ptr, world);
}

pub fn deinit(self: *@This(), world: *World) void {
    self.vtable.deinit(self.ptr, world);
}

pub fn Builder(comptime func: anytype) type {
    mod.assertSystem(func);
    const fn_info = @typeInfo(@TypeOf(func)).@"fn";

    return struct {
        /// One slot per `func` parameter, in declaration order: the context the
        /// parameter owns between runs, or `void` when `param.Context` is
        /// `World` and it owns no state.
        pub const ContextList = Blk: {
            var types: [fn_info.param_types.len]type = undefined;
            for (fn_info.param_types, 0..) |maybe_param, i| {
                const P = maybe_param.?; // assertSystem rejects generic parameters.
                const C = param.Context(P);
                types[i] = if (C == World) void else C;
            }
            break :Blk @Tuple(&types);
        };

        ctx_list: ContextList,

        pub fn build(world: *World) Allocator.Error!System {
            const self = try world.allocator.create(@This());
            errdefer world.allocator.destroy(self);

            self.ctx_list = undefined;
            inline for (fn_info.param_types, 0..) |maybe_param, i| {
                const P = maybe_param.?;
                const C = param.Context(P);
                if (C != World) {
                    self.ctx_list[i] = C.init(world);
                }
            }

            return .{ .ptr = self, .vtable = &vtable };
        }

        pub fn run_(self: *anyopaque, world_: *World) anyerror!void {
            const state: *@This() = @ptrCast(@alignCast(self));

            const Args = std.meta.ArgsTuple(@TypeOf(func));
            var args: Args = undefined;
            inline for (fn_info.param_types, 0..) |maybe_param, i| {
                const P = maybe_param.?;
                const C = param.Context(P);
                if (C == World) {
                    args[i] = try param.extractParam(P, world_);
                } else {
                    args[i] = try param.extractParam(P, &state.ctx_list[i]);
                }
            }

            return @call(.auto, func, args);
        }

        pub fn deinit_(self: *anyopaque, world_: *World) void {
            const state: *@This() = @ptrCast(@alignCast(self));

            inline for (fn_info.param_types, 0..) |maybe_param, i| {
                const P = maybe_param.?;
                const C = param.Context(P);
                if (C != World) {
                    if (@hasDecl(C, "deinit")) {
                        state.ctx_list[i].deinit();
                    }
                }
            }

            world_.allocator.destroy(state);
        }

        pub const vtable: VTable = .{
            .run = run_,
            .deinit = deinit_,
        };
    };
}

const expect = std.testing.expect;

/// Counts the lifecycle phases a system observes for one context.
const Probe = struct {
    pub const se_resource: engine.ecs.resource.Mark = .{};
    inits: usize = 0,
    extracts: usize = 0,
    runs: usize = 0,
    deinits: usize = 0,
};

/// A context that records its own construction and destruction.
const ProbeCtx = struct {
    probe: *Probe,

    pub fn init(world: *World) @This() {
        const probe = world.getResource(Probe).?;
        probe.inits += 1;
        return .{ .probe = probe };
    }

    pub fn deinit(self: *@This()) void {
        self.probe.deinits += 1;
    }
};

/// A parameter owning `ProbeCtx`; every extraction is counted.
const ProbeParam = struct {
    probe: *Probe,

    pub const Context = ProbeCtx;

    pub fn extract(ctx: *ProbeCtx) error{}!@This() {
        ctx.probe.extracts += 1;
        return .{ .probe = ctx.probe };
    }
};

/// A parameter with no owned context; it reads straight from `*World`.
const WorldParam = struct {
    pub fn extract(_: *World) error{}!@This() {
        return .{};
    }
};

/// A system function covering every parameter kind: `*World`, a World-context
/// parameter, and one that owns a context.
fn sampleRun(_: *World, _: WorldParam, p: ProbeParam) void {
    p.probe.runs += 1;
}

test "ContextList keeps one slot per parameter, void for World contexts" {
    try expect(Builder(sampleRun).ContextList == @Tuple(&.{ void, void, ProbeCtx }));

    // A scalar argument is rejected by assertSystem:
    // _ = Builder(struct {
    //     fn run(_: u32) void {}
    // }.run);
}

test "build, run and deinit manage the system and its contexts" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    _ = try world.insertResource(Probe{});

    {
        var system = try Builder(sampleRun).build(&world);
        defer system.deinit(&world);

        try system.run(&world);
    }

    const probe = world.getResource(Probe).?;
    try expect(probe.inits == 1);
    try expect(probe.extracts == 1);
    try expect(probe.runs == 1);
    try expect(probe.deinits == 1);
}

test "a system without parameters receives an empty argument list" {
    const NoParams = struct {
        fn run() error{Boom}!void {
            return error.Boom;
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit();

    var system = try Builder(NoParams.run).build(&world);
    defer system.deinit(&world);

    try std.testing.expectError(error.Boom, system.run(&world));
}

test "resource parameters resolve their id during build" {
    const Counter = struct {
        pub const se_resource: engine.ecs.resource.Mark = .{};
        value: u32 = 0,
    };
    const resource = engine.ecs.resource;
    const Mutate = struct {
        fn run(res: resource.ResMut(Counter)) void {
            res.ptr.value += 1;
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit();
    _ = try world.insertResource(Counter{ .value = 3 });

    var system = try Builder(Mutate.run).build(&world);
    defer system.deinit(&world);

    try system.run(&world);
    try expect(world.getResource(Counter).?.value == 4);
}
