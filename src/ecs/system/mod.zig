const std = @import("std");

pub const param = @import("param.zig");

pub const Access = @import("Access.zig");
pub const System = @import("System.zig");

/// Asserts that `func` is a system function: a non-generic, non-variadic
/// function whose parameters declare compatible access and whose return type
/// is `void` or an error union of `void`.
pub fn assertSystem(comptime func: anytype) void {
    comptime {
        _ = accessSpecs(func);
    }
}

/// Validates a system and collects one access declaration per parameter, in order.
/// Query conditions are retained, but do not relax conservative conflict checks.
pub fn accessSpecs(comptime func: anytype) []const Access.Spec {
    const info = switch (@typeInfo(@TypeOf(func))) {
        .@"fn" => |info| info,
        else => @compileError(@typeName(@TypeOf(func)) ++ " is not a system function"),
    };

    if (info.is_generic) @compileError("systems must not be generic functions");
    if (info.attrs.varargs) @compileError("systems must not be variadic");

    const specs = comptime blk: {
        var out: [info.param_types.len]Access.Spec = undefined;
        for (info.param_types, 0..) |maybe_param, i| {
            const P = maybe_param orelse @compileError(
                "system function parameters must have concrete types",
            );
            out[i] = param.access(P);
        }
        break :blk out;
    };

    const ret = info.return_type orelse
        @compileError("systems must have a concrete return type");
    switch (@typeInfo(ret)) {
        .void => {},
        .error_union => |err| {
            if (err.payload != void) {
                @compileError("systems must return void or an error union of void");
            }
        },
        else => @compileError("systems must return void or an error union of void"),
    }

    if (comptime Access.findConflict(&specs)) |conflict| {
        const a, const b = conflict;
        const A = info.param_types[a.param].?;
        const B = info.param_types[b.param].?;
        if (a.entry) |entry_index| {
            const entry = specs[a.param].shared.entries[entry_index];
            @compileError(std.fmt.comptimePrint(
                "System parameter {d} ({s}) entry {d} conflicts with " ++
                    "parameter {d} ({s}) entry {d}: {s} {s}",
                .{
                    a.param,                @typeName(A),            entry_index,
                    b.param,                @typeName(B),            b.entry.?,
                    @tagName(entry.domain), @typeName(entry.target),
                },
            ));
        }
        @compileError(std.fmt.comptimePrint(
            "System parameters {d} ({s}) and {d} ({s}) conflict: exclusive world access",
            .{ a.param, @typeName(A), b.param, @typeName(B) },
        ));
    }
    return &specs;
}

test {
    _ = param;
    _ = Access;
    _ = System;
}
