//! Trace save a context of the entire life cycle of an operation.

const std = @import("std");

const root = @import("root.zig");
const base = root.base;
const Tracer = root.Tracer;
const Span = root.Span;

tracer: Tracer,
id: Id,
flag: Flag,

/// Unique identifier of a trace, backed by a 128-bit integer.
pub const Id = base.niche.NonZero(u128);

/// Control the behavior of the trace.
pub const Flag = packed struct(u8) {
    /// Indicates whether the trace is sampled or not.
    sampled: bool, // bit 0
    /// Reserved bits for future use. Should be set to 0.
    _reserved: u7 = 0, // bits 1-7

    pub fn fromByte(byte: u8) @This() {
        return @bitCast(byte);
    }

    pub fn toByte(self: @This()) u8 {
        return @bitCast(self);
    }
};

pub fn initSpan(self: @This(), options: Span.Options) Span {
    return self.tracer.initSpan(self, options);
}
