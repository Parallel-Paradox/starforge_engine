//! Subscriber defines the API for consuming trace data.

pub const Terminal = @import("terminal.zig");

const std = @import("std");

const root = @import("../mod.zig");
const Span = root.Span;
const Event = root.Event;

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    recvSpan: *const fn (self: *anyopaque, span: Span) void,
    recvEvent: *const fn (self: *anyopaque, event: Event) void,
};

pub fn recvSpan(self: @This(), span: Span) void {
    self.vtable.recvSpan(self.ptr, span);
}

pub fn recvEvent(self: @This(), event: Event) void {
    self.vtable.recvEvent(self.ptr, event);
}

test {
    _ = Terminal;
}
