//! Type-erased system owning parameter contexts and immutable access metadata.

const System = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const World = engine.ecs.World;
const TypeId = engine.reflect.TypeId;
const Access = @import("Access.zig");
const param = @import("param.zig");
const mod = @import("mod.zig");

ptr: *anyopaque,
vtable: *const VTable,
/// Borrows immutable metadata stored in the instance behind `ptr`.
access: Access,

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
    const specs = comptime mod.accessSpecs(func);
    const fn_info = @typeInfo(@TypeOf(func)).@"fn";

    return struct {
        pub const access_specs: []const Access.Spec = specs;

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

        world: *World,
        ctx_list: ContextList,
        access_storage: Access.Storage(specs),

        pub fn build(world: *World) Allocator.Error!System {
            const self = try world.allocator.create(@This());
            errdefer world.allocator.destroy(self);

            self.world = world;
            self.ctx_list = undefined;
            inline for (fn_info.param_types, 0..) |maybe_param, i| {
                const P = maybe_param.?;
                const C = param.Context(P);
                if (C != World) {
                    self.ctx_list[i] = C.init(world);
                }
            }

            return .{
                .ptr = self,
                .vtable = &vtable,
                .access = self.access_storage.init(),
            };
        }

        pub fn run_(self: *anyopaque, world_: *World) anyerror!void {
            const state: *@This() = @ptrCast(@alignCast(self));
            std.debug.assert(state.world == world_);

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
            std.debug.assert(state.world == world_);

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
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

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
    pub const access: Access.Spec = .{ .shared = .{ .entries = &.{
        .{ .domain = .resource, .target = Probe, .mode = .write },
    } } };

    pub fn extract(ctx: *ProbeCtx) error{}!@This() {
        ctx.probe.extracts += 1;
        return .{ .probe = ctx.probe };
    }
};

/// A stateless parameter whose extraction needs no shared world data.
const WorldParam = struct {
    pub const access: Access.Spec = .none;

    pub fn extract(_: *World) error{}!@This() {
        return .{};
    }
};

/// Covers builtin injection, a stateless parameter, and an owned context.
fn sampleRun(_: Allocator, _: WorldParam, p: ProbeParam) void {
    p.probe.runs += 1;
}

test "ContextList keeps one slot per parameter, void for World contexts" {
    try expect(Builder(sampleRun).ContextList == @Tuple(&.{ void, void, ProbeCtx }));

    // A scalar argument is rejected by assertSystem:
    // _ = Builder(struct {
    //     fn run(_: u32) void {}
    // }.run);
}

test "system contexts and access survive runs and extraction failures" {
    var world = World.init(std.testing.allocator, std.testing.io);
    defer world.deinit();
    _ = try world.insertResource(Probe{});

    {
        var system = try Builder(sampleRun).build(&world);
        defer system.deinit(&world);

        const view = system.access;
        try expect(view.groups[0] == .none);
        try expect(view.groups[1] == .none);
        const entry = view.groups[2].shared.entries[0];
        try expect(entry.type_id.eql(TypeId.of(Probe)));
        try expectEqual(Access.Domain.resource, entry.domain);
        try expectEqual(Access.Mode.write, entry.mode);
        const state: *Builder(sampleRun) = @ptrCast(@alignCast(system.ptr));
        try expect(&view.groups[0] == &state.access_storage.groups[0]);
        try system.run(&world);
        try system.run(&world);
        try expect(view.groups.ptr == system.access.groups.ptr);
        try expect(view.groups[2].shared.entries[0].type_id.eql(entry.type_id));
    }

    const Failing = struct {
        pub const Context = ProbeCtx;
        pub const access = ProbeParam.access;

        pub fn extract(ctx: *Context) error{Stopped}!@This() {
            ctx.probe.extracts += 1;
            return error.Stopped;
        }
    };
    const After = struct {
        pub const access: Access.Spec = .none;

        pub fn extract(_: *World) error{}!@This() {
            @panic("later parameters must not be extracted after an error");
        }
    };
    const FailRun = struct {
        fn run(_: Failing, _: After) void {
            @panic("the system function must not run after an extraction error");
        }
    };
    {
        var system = try Builder(FailRun.run).build(&world);
        defer system.deinit(&world);
        const view = system.access;
        try expectError(error.Stopped, system.run(&world));
        try expect(view.groups[0].shared.entries[0].type_id.eql(TypeId.of(Probe)));
    }
    const probe = world.getResource(Probe).?;
    try expect(probe.inits == 2);
    try expect(probe.extracts == 3);
    try expect(probe.runs == 2);
    try expect(probe.deinits == 2);
}

test "a system without parameters receives an empty argument list" {
    const NoParams = struct {
        fn run() error{Boom}!void {
            return error.Boom;
        }
    };

    var world = World.init(std.testing.allocator, std.testing.io);
    defer world.deinit();

    var system = try Builder(NoParams.run).build(&world);
    defer system.deinit(&world);

    try expectEqual(0, system.access.groups.len);
    try expectError(error.Boom, system.run(&world));
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
    const Read = struct {
        fn run(a: resource.Res(Counter), b: resource.Res(Counter)) !void {
            try expect(a.ptr == b.ptr);
        }
    };

    var world = World.init(std.testing.allocator, std.testing.io);
    defer world.deinit();
    _ = try world.insertResource(Counter{ .value = 3 });

    var system = try Builder(Mutate.run).build(&world);
    defer system.deinit(&world);
    var a = try Builder(Read.run).build(&world);
    defer a.deinit(&world);
    var b = try Builder(Read.run).build(&world);
    defer b.deinit(&world);
    try expect(!a.access.isConflict(b.access));
    try expect(a.access.isConflict(system.access));
    try expect(system.access.isConflict(a.access));
    try expect(system.access.isConflict(system.access));
    try expect(a.access.groups.ptr != b.access.groups.ptr);
    try a.run(&world);
    try system.run(&world);
    try b.run(&world);
    try expect(world.getResource(Counter).?.value == 4);
}

test "built systems expose conservative component resource and exclusive conflicts" {
    const query = engine.ecs.query;
    const resource = engine.ecs.resource;
    const EntityId = engine.ecs.entity.Id;
    const Data = struct {
        pub const se_component: engine.ecs.component.Mark = .{};
        pub const se_resource: resource.Mark = .{};
        value: u32 = 1,
    };
    const Sparse = struct {
        pub const se_component: engine.ecs.component.Mark = .{ .storage = .sparse_set };
    };
    const Tag = struct {
        pub const se_component: engine.ecs.component.Mark = .{};
    };
    const Unknown = struct {
        pub fn extract(_: *World) error{}!@This() {
            return .{};
        }
    };
    const ReadQuery = query.Query(struct { EntityId, *const Data, *const Sparse });
    const Functions = struct {
        fn read(_: ReadQuery) void {}
        fn write(items: query.Query(struct { *Data })) void {
            var values = items;
            while (values.next()) |item| item[0].value += 1;
        }
        fn withTag(_: query.QueryF(struct { *Data }, query.Filter.With(Tag))) void {}
        fn withoutTag(_: query.QueryF(struct { *Data }, query.Filter.Without(Tag))) void {}
        fn ids(_: query.Query(struct { EntityId })) void {}
        fn res(_: resource.ResMut(Data)) void {}
        fn exclusive(_: *World, _: Allocator, _: std.Io) void {}
        fn local(_: Allocator, _: std.Io) void {}
        fn unknown(_: Unknown) void {}
        fn mixed(_: resource.ResMut(Data), _: ReadQuery) void {}
    };
    const Kind = enum {
        read,
        write,
        with_tag,
        without_tag,
        ids,
        res,
        exclusive,
        local,
        unknown,
        mixed,
    };
    const functions = .{
        Functions.read,    Functions.write, Functions.withTag,   Functions.withoutTag,
        Functions.ids,     Functions.res,   Functions.exclusive, Functions.local,
        Functions.unknown, Functions.mixed,
    };
    var world = World.init(std.testing.allocator, std.testing.io);
    defer world.deinit();
    _ = try world.insertResource(Data{});
    const first = try world.addEntity(.{ Data{}, Sparse{}, Tag{} });

    var systems: [functions.len]System = undefined;
    var built: usize = 0;
    defer {
        for (systems[0..built]) |*system| system.deinit(&world);
    }
    inline for (functions, 0..) |func, i| {
        systems[i] = try Builder(func).build(&world);
        built += 1;
    }
    const cases = [_]struct { a: Kind, b: Kind, conflict: bool }{
        .{ .a = .read, .b = .read, .conflict = false },
        .{ .a = .read, .b = .write, .conflict = true },
        .{ .a = .write, .b = .write, .conflict = true },
        .{ .a = .with_tag, .b = .without_tag, .conflict = true },
        .{ .a = .write, .b = .res, .conflict = false },
        .{ .a = .read, .b = .res, .conflict = false },
        .{ .a = .ids, .b = .write, .conflict = false },
        .{ .a = .ids, .b = .exclusive, .conflict = true },
        .{ .a = .res, .b = .exclusive, .conflict = true },
        .{ .a = .exclusive, .b = .exclusive, .conflict = true },
        .{ .a = .exclusive, .b = .local, .conflict = false },
        .{ .a = .unknown, .b = .read, .conflict = true },
        .{ .a = .unknown, .b = .unknown, .conflict = true },
        .{ .a = .unknown, .b = .local, .conflict = false },
        .{ .a = .mixed, .b = .read, .conflict = false },
        .{ .a = .mixed, .b = .res, .conflict = true },
        .{ .a = .mixed, .b = .write, .conflict = true },
    };
    for (cases) |case| {
        const a = systems[@backingInt(case.a)].access;
        const b = systems[@backingInt(case.b)].access;
        try expectEqual(case.conflict, a.isConflict(b));
        try expectEqual(case.conflict, b.isConflict(a));
    }
    const reader = systems[@backingInt(Kind.read)].access.groups[0].shared;
    try expectEqual(2, reader.entries.len);
    try expect(reader.entries[1].type_id.eql(TypeId.of(Sparse)));
    const ids = systems[@backingInt(Kind.ids)].access.groups[0].shared;
    try expectEqual(0, ids.entries.len);
    try expectEqual(1, ids.filter.?.nodes.len);
    const with_tag = systems[@backingInt(Kind.with_tag)].access.groups[0].shared;
    const without_tag = systems[@backingInt(Kind.without_tag)].access.groups[0].shared;
    try expect(with_tag.filter.?.nodes[2].leaf.type_id.eql(TypeId.of(Tag)));
    try expect(with_tag.filter.?.nodes[2].leaf.require);
    try expect(!without_tag.filter.?.nodes[2].leaf.require);
    try expect(systems[@backingInt(Kind.unknown)].access.groups[0] == .exclusive);
    for (&systems) |*system| try system.run(&world);
    try expect(reader.entries[1].type_id.eql(TypeId.of(Sparse)));

    // A second run must refresh the writer's cache to include a new archetype.
    const second = try world.addEntity(.{ Data{ .value = 10 }, Sparse{} });
    try systems[@backingInt(Kind.write)].run(&world);
    const ReadBack = query.Query(struct { EntityId, *const Data });
    var ctx = ReadBack.Context.init(&world);
    defer ctx.deinit();
    var values = try ReadBack.extract(&ctx);
    var count: usize = 0;
    while (values.next()) |item| {
        if (item[0].eql(first)) {
            try expectEqual(3, item[1].value);
        } else {
            try expect(item[0].eql(second));
            try expectEqual(11, item[1].value);
        }
        count += 1;
    }
    try expectEqual(2, count);
}
