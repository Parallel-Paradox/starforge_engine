//! Trace save a context of the entire life cycle of an operation.

const std = @import("std");

const root = @import("mod.zig");
const Tracer = root.Tracer;
const Event = root.Event;

tracer: Tracer,
id: Id,
flag: Flag,

/// Unique identifier of a trace, backed by a 128-bit integer.
pub const Id = enum(u128) {
    /// Sentinel value meaning no valid trace id.
    invalid = 0,
    _,

    /// Returns the raw 128-bit value of a valid id.
    /// Asserts (in safe build modes) that the id is not `invalid`.
    pub fn get(self: Id) u128 {
        std.debug.assert(self != Id.invalid);
        return @intFromEnum(self);
    }

    /// Returns the raw 128-bit value, or `null` if the id is `invalid`.
    pub fn tryGet(self: Id) ?u128 {
        if (self == Id.invalid) return null;
        return @intFromEnum(self);
    }
};

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
