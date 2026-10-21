//! Span represents a unit of work within a trace. It contains information about the
//! operation being performed, such as its name, start time, end time, attributes, etc.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Timestamp = std.Io.Timestamp;

const root = @import("mod.zig");
const base = root.base;
const Trace = root.Trace;
const Event = root.Event;
const Attribute = root.Attribute;

trace: Trace,
id: Id,
parent_id: ?Id = null,
status: Status = .unset,
kind: Kind,
name: []const u8,
/// Locate the span in timeline with `std.Io.Clock.real`.
real_dur: Duration,
/// Measure actual cost with `std.Io.Clock.awake`.
awake_dur: Duration,
/// Relationship between two spans across different traces or services.
links: std.ArrayList(Link) = .empty,
attrs: std.ArrayList(Attribute) = .empty,

/// Unique identifier of a span, backed by a 64-bit integer.
pub const Id = base.niche.NonZero(u64);

/// Status defines the outcome of a span, indicating whether it completed successfully or
/// encountered an error.
pub const Status = enum(i8) {
    /// The span has not yet been completed, and its status is not yet determined.
    unset = 0,
    /// The span completed successfully without any errors.
    ok = 1,
    /// The span encountered an error during its execution.
    err = -1,

    pub fn toStr(self: @This()) []const u8 {
        return switch (self) {
            .err => "error",
            else => @tagName(self),
        };
    }
};

/// Describes the role of a span in a trace.
pub const Kind = enum(u8) {
    /// Internal operation, no cross-process communication.
    internal = 0,
    /// Handles a request (e.g. HTTP/gRPC server). Created on requested, closed on response.
    server = 1,
    /// Sends a request (e.g. HTTP/gRPC client). Created on request, closed on responded.
    client = 2,
    /// Sends an async message. Does not wait for consumption.
    producer = 3,
    /// Processes an async message. May start long after the message was produced.
    consumer = 4,

    pub fn toStr(self: @This()) []const u8 {
        return @tagName(self);
    }
};

/// Options for creating a span.
pub const Options = struct {
    name: []const u8,
    kind: Kind = .internal,
};

pub const Duration = struct {
    begin: ?Timestamp = null,
    end: ?Timestamp = null,
};

/// Link represents a relationship between two spans, allowing for the representation of complex
/// trace structures that are not strictly hierarchical.
pub const Link = struct {
    /// The trace ID of the linked span.
    trace_id: Trace.Id,
    /// The span ID of the linked span.
    span_id: Id,
    /// The attributes associated with the link, providing additional context.
    attrs: std.ArrayList(Attribute) = .empty,

    /// Releases the attributes owned by the link.
    pub fn deinit(self: *@This(), allocator: Allocator) void {
        for (self.attrs.items) |*attr| attr.deinit(allocator);
        self.attrs.deinit(allocator);
    }
};

/// Releases the links and attributes owned by the span.
pub fn deinit(self: *@This()) void {
    const allocator = self.trace.tracer.getAllocator();
    for (self.links.items) |*link| link.deinit(allocator);
    self.links.deinit(allocator);
    for (self.attrs.items) |*attr| attr.deinit(allocator);
    self.attrs.deinit(allocator);
}

/// Records the begin timestamps of the span and notifies subscribers.
pub fn start(self: *@This()) void {
    const io = self.trace.tracer.getIo();
    self.real_dur.begin = Io.Clock.real.now(io);
    self.awake_dur.begin = Io.Clock.awake.now(io);
    self.trace.tracer.startSpan(self.*);
}

/// Records the end timestamps of the span and delivers it to subscribers.
pub fn emit(self: *@This()) void {
    const io = self.trace.tracer.getIo();
    self.real_dur.end = Io.Clock.real.now(io);
    self.awake_dur.end = Io.Clock.awake.now(io);
    self.trace.tracer.emitSpan(self.*);
}

/// Creates a child span within the same trace, linked to this span as its parent.
pub fn initSub(self: *const @This(), options: Options) @This() {
    var sub = self.trace.initSpan(options);
    sub.parent_id = self.id;
    return sub;
}

/// Creates a new event attached to this span.
pub fn initEvent(self: *const @This(), options: Event.Options) Event {
    return self.trace.tracer.initEvent(self.*, options);
}

/// Appends each field of the struct `attrs` as an attribute. See `Attribute.appendStruct`.
pub fn addAttrs(self: *@This(), attrs: anytype) (Allocator.Error || Attribute.FormatError)!void {
    return Attribute.appendStruct(self.trace.tracer.getAllocator(), &self.attrs, attrs);
}

/// Records a link to another span, with the struct `attrs` as its attributes.
pub fn linkTo(
    self: *@This(),
    trace_id: Trace.Id,
    span_id: Id,
    attrs: anytype,
) (Allocator.Error || Attribute.FormatError)!void {
    const allocator = self.trace.tracer.getAllocator();
    var new_link: Link = .{ .trace_id = trace_id, .span_id = span_id };
    errdefer new_link.deinit(allocator);
    try Attribute.appendStruct(allocator, &new_link.attrs, attrs);
    try self.links.append(allocator, new_link);
}

test "link records the target and its attributes" {
    const allocator = std.testing.allocator;
    var default = root.Tracer.Default.init(allocator, std.testing.io);
    defer default.deinit();

    const t = default.tracer();
    var span = t.initSpan(t.initTrace(), .{ .name = "test" });
    defer span.deinit();

    try span.linkTo(span.trace.id, span.id, .{ .k = @as(i64, 7) });
    try std.testing.expectEqual(@as(usize, 1), span.links.items.len);
    try std.testing.expectEqual(span.id, span.links.items[0].span_id);
    try std.testing.expectEqual(@as(i64, 7), span.links.items[0].attrs.items[0].value.int);
}
