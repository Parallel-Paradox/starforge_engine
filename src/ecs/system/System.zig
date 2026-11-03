const std = @import("std");

const engine = @import("engine");
const World = engine.ecs.World;

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    run: *const fn (self: *anyopaque, world: *World) anyerror!void,
    deinit: *const fn (self: *anyopaque) void,
};

pub fn deinit(self: *@This()) void {
    self.vtable.deinit(self.ptr);
}
