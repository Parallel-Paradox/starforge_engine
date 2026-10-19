//! Generic index/generation id shared by all registries.

const std = @import("std");

const root = @import("mod.zig");
const base = root.base;
const NonMax = base.niche.NonMax;

pub const invalid = @This(){};

index: NonMax(u32) = .invalid,
generation: NonMax(u32) = .invalid,

/// Builds an id from raw values. Asserts (in safe build modes) that neither value is `maxInt(u32)`.
pub fn init(index: u32, generation: u32) @This() {
    return .{ .index = .from(index), .generation = .from(generation) };
}

/// Whether both the index and the generation match.
pub fn eql(self: @This(), other: @This()) bool {
    return self.index == other.index and self.generation == other.generation;
}

pub const ValidateError = error{
    /// The index is the reserved `invalid` value.
    InvalidIndex,
    /// The generation is the reserved `invalid` value.
    InvalidGeneration,
};

/// Validates that neither the index nor the generation is the reserved `invalid` value.
pub fn validate(self: @This()) ValidateError!void {
    if (self.index == .invalid) return ValidateError.InvalidIndex;
    if (self.generation == .invalid) return ValidateError.InvalidGeneration;
}

/// Checks if the id is valid according to the validate function.
pub fn isValid(self: @This()) bool {
    self.validate() catch return false;
    return true;
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

test "init stores the raw index and generation" {
    const id = init(3, 7);

    try expectEqual(3, id.index.get());
    try expectEqual(7, id.generation.get());
}

test "eql requires both index and generation to match" {
    try expect(init(3, 7).eql(init(3, 7)));
    try expect(!init(3, 7).eql(init(4, 7)));
    try expect(!init(3, 7).eql(init(3, 8)));
}

test "default id is invalid" {
    try expect(!invalid.isValid());
    try expectError(ValidateError.InvalidIndex, invalid.validate());
}

test "id with only an invalid generation reports it" {
    const id = @This(){ .index = .from(3) };

    try expectError(ValidateError.InvalidGeneration, id.validate());
    try expect(!id.isValid());
}

test "id built from raw values is valid" {
    try init(3, 7).validate();
    try expect(init(3, 7).isValid());
}
