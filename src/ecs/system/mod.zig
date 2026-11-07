const std = @import("std");

pub const param = @import("param.zig");
pub const schedule = @import("schedule/mod.zig");

pub const Access = @import("Access.zig");
pub const System = @import("System.zig");

const engine = @import("engine");
pub const Id = engine.ecs.Id;

test {
    _ = param;
    _ = schedule;
    _ = Access;
    _ = System;
}
