pub const param = @import("param.zig");

pub const System = @import("System.zig");

/// Asserts that `func` is a system function: a non-generic, non-variadic
/// function whose parameters satisfy `param.assertParam` and whose return type
/// is `void` or an error union of `void`.
pub fn assertSystem(comptime func: anytype) void {
    const info = switch (@typeInfo(@TypeOf(func))) {
        .@"fn" => |info| info,
        else => @compileError(@typeName(@TypeOf(func)) ++ " is not a system function"),
    };

    if (info.is_generic) @compileError("systems must not be generic functions");
    if (info.attrs.varargs) @compileError("systems must not be variadic");

    inline for (info.param_types) |maybe_param| {
        const P = maybe_param orelse @compileError(
            "system function parameters must have concrete types",
        );
        param.assertParam(P);
    }

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
}

test {
    _ = param;
    _ = System;
}
