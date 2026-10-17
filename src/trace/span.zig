//! Span represents a unit of work within a trace. It contains information about the
//! operation being performed, such as its name, start time, end time, attributes, etc.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Timestamp = std.Io.Timestamp;

const root = @import("mod.zig");
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
pub const Id = enum(u64) {
    /// Sentinel value meaning no valid trace id.
    invalid = 0,
    _,

    /// Returns the raw 64-bit value of a valid id.
    /// Asserts (in safe build modes) that the id is not `invalid`.
    pub fn get(self: Id) u64 {
        std.debug.assert(self != Id.invalid);
        return @intFromEnum(self);
    }

    /// Returns the raw 64-bit value, or `null` if the id is `invalid`.
    pub fn tryGet(self: Id) ?u64 {
        if (self == Id.invalid) return null;
        return @intFromEnum(self);
    }
};

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
            .unset => "UNSET",
            .ok => "OK",
            .err => "ERROR",
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

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .internal => "INTERNAL",
            .server => "SERVER",
            .client => "CLIENT",
            .producer => "PRODUCER",
            .consumer => "CONSUMER",
        };
    }
};

pub const Duration = struct {
    begin: Timestamp,
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
};
