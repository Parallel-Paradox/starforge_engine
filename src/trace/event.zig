//! Event is a single point in time that occurred during the execution of a Span.
//! It can be used to record significant occurrences, such as errors, warnings, or any other
//! noteworthy events that happen during the span's lifetime.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Timestamp = std.Io.Timestamp;

const root = @import("mod.zig");
const Trace = root.Trace;
const Span = root.Span;
const Attribute = root.Attribute;

trace: Trace,
span_id: Span.Id,
level: Level,
name: []const u8,
real_ts: Timestamp,
attrs: std.ArrayList(Attribute) = .empty,

/// Level defines the severity of an event. It is used to filter events based on their importance.
pub const Level = enum(u8) {
    /// Detailed information for diagnosing problems.
    trace = 0,
    /// Debug information for development.
    debug = 1,
    /// Confirmation that things are working as expected.
    info = 2,
    /// An indication that something unexpected happened, or indicative of some problem in the near
    /// future (e.g. 'disk space low'). The program is still working as expected.
    warn = 3,
    /// Due to a more serious problem, the program has not been able to work as expected.
    err = 4,
    /// A serious error, indicating that the program may not be able to continue.
    /// This level is used for unrecoverable errors that require immediate attention and may lead to
    /// termination.
    fatal = 5,

    pub fn toStr(self: @This()) []const u8 {
        return switch (self) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
            .fatal => "FATAL",
        };
    }
};

/// Options for creating an event.
pub const Options = struct {
    name: []const u8,
    level: Level = .info,
};

/// Releases the attributes owned by the event.
pub fn deinit(self: *@This()) void {
    const allocator = self.trace.tracer.getAllocator();
    for (self.attrs.items) |*attr| attr.deinit(allocator);
    self.attrs.deinit(allocator);
}

/// Appends each field of the struct `attrs` as an attribute. See `Attribute.appendStruct`.
pub fn addAttrs(self: *@This(), attrs: anytype) (Allocator.Error || Attribute.FormatError)!void {
    return Attribute.appendStruct(self.trace.tracer.getAllocator(), &self.attrs, attrs);
}

/// Delivers the event to every registered subscriber.
pub fn emit(self: *const @This()) void {
    self.trace.tracer.emitEvent(self.*);
}
