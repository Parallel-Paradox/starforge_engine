//! Generic index/generation id shared by all registries.

const std = @import("std");

const engine = @import("engine");
const NonMax = engine.base.niche.NonMax;
const Tracer = engine.trace.Tracer.Global;

pub const invalid = @This(){};

pub const Index = NonMax(u32);
pub const Generation = NonMax(u32);

index: Index = .invalid,
generation: Generation = .invalid,

/// Builds an id from raw values. Panics in every build mode if `index` exceeds
/// the largest valid index (`maxInt(u32) - 1`). The generation must be valid.
pub fn init(index: usize, generation: u32) @This() {
    if (index >= std.math.maxInt(u32)) @panic("ECS id index exhausted");
    return .{ .index = .from(@intCast(index)), .generation = .from(generation) };
}

/// Returns the same index with its generation incremented. Requires a valid id.
/// Wraps to zero, skipping the invalid sentinel, and warns that old ids may alias.
pub fn nextGeneration(self: @This()) @This() {
    std.debug.assert(self.isValid());
    const generation = self.generation.get();
    if (generation == std.math.maxInt(u32) - 1) {
        Tracer.warn("ECS id generation exhausted; wrapping to zero may revive stale ids").emit();
        return .{ .index = self.index, .generation = .from(0) };
    }
    return .{ .index = self.index, .generation = .from(generation + 1) };
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

test "init accepts the largest valid index" {
    const id = init(std.math.maxInt(u32) - 1, 0);
    try expectEqual(std.math.maxInt(u32) - 1, id.index.get());
    try expect(id.isValid());
}

test "nextGeneration preserves the index and skips the invalid sentinel on wrap" {
    try expect(init(3, 7).nextGeneration().eql(init(3, 8)));
    const last = init(3, std.math.maxInt(u32) - 1);
    const wrapped = last.nextGeneration();
    try expect(wrapped.eql(init(3, 0)));
    try expect(wrapped.isValid());
    try expect(wrapped.nextGeneration().eql(init(3, 1)));
}

test "id built from raw values is valid" {
    try init(3, 7).validate();
    try expect(init(3, 7).isValid());
}
