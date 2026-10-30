//! Trace save a context of the entire life cycle of an operation.

const std = @import("std");

const engine = @import("engine");
const base = engine.base;
const Tracer = engine.trace.Tracer;
const Span = engine.trace.Span;

/// A null backend disables tracing, including attribute and link allocation.
tracer: ?Tracer = null,
id: Id = .invalid,
flag: Flag = .{ .sampled = false },

/// Unique identifier of a trace, backed by a 128-bit integer.
pub const Id = base.niche.NonZero(u128);

/// Control the behavior of the trace.
pub const Flag = packed struct(u8) {
    /// Indicates whether the trace is sampled or not.
    sampled: bool = true, // bit 0
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
    const tracer = self.tracer orelse return .{
        .trace = self,
        .id = .invalid,
        .kind = options.kind,
        .name = options.name,
        .real_dur = .{},
        .awake_dur = .{},
    };
    return tracer.initSpan(self, options);
}
