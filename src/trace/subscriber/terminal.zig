const std = @import("std");

const root = @import("../mod.zig");
const Span = root.Span;
const Event = root.Event;

fn this(ptr: *anyopaque) *@This() {
    return @ptrCast(@alignCast(ptr));
}

fn recvSpan(ptr: *anyopaque, _: Span) void {
    _ = this(ptr);
    // TODO
}

fn recvEvent(ptr: *anyopaque, _: Event) void {
    _ = this(ptr);

    // prepare stderr writer

    // TODO
}
