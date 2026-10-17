//! Subscriber defines the API for consuming trace data.

pub const Terminal = @import("terminal.zig");

const std = @import("std");

const root = @import("../mod.zig");
const Span = root.Span;
const Event = root.Event;

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    spanStarted: *const fn (self: *anyopaque, span: Span) void,
    spanEmitted: *const fn (self: *anyopaque, span: Span) void,
    eventEmitted: *const fn (self: *anyopaque, event: Event) void,
};

pub fn spanStarted(self: @This(), span: Span) void {
    self.vtable.spanStarted(self.ptr, span);
}

pub fn spanEmitted(self: @This(), span: Span) void {
    self.vtable.spanEmitted(self.ptr, span);
}

pub fn eventEmitted(self: @This(), event: Event) void {
    self.vtable.eventEmitted(self.ptr, event);
}

test {
    _ = Terminal;
}
