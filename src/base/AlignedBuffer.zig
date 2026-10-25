//! A safe wrapper for runtime-aligned unmanaged buffers.
//!
//! An empty buffer owns no memory: `len == 0` and `ptr` is a non-null pointer
//! aligned to `alignment` that must never be dereferenced.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// The buffer pointer. When `len == 0`, this is an aligned sentinel that must
/// never be dereferenced.
ptr: [*]u8,
/// The number of allocated bytes. Zero means the buffer owns no memory.
len: usize = 0,
/// The alignment of the allocation and of the empty sentinel pointer.
alignment: Alignment = .@"1",

/// Returns an empty buffer whose sentinel pointer is aligned to `alignment`.
pub fn empty(alignment: Alignment) @This() {
    return .{
        .ptr = @ptrFromInt(alignment.toByteUnits()),
        .alignment = alignment,
    };
}

/// Allocates a buffer of `len` bytes aligned to `alignment`. Free it with `deinit`.
pub fn init(allocator: Allocator, len: usize, alignment: Alignment) Allocator.Error!@This() {
    if (len == 0) return empty(alignment);

    const ptr = allocator.rawAlloc(len, alignment, @returnAddress()) orelse
        return error.OutOfMemory;
    return .{ .ptr = ptr, .len = len, .alignment = alignment };
}

/// Frees the buffer allocated by `init` with the same allocator and resets it
/// to an empty buffer with the same alignment.
pub fn deinit(self: *@This(), allocator: Allocator) void {
    if (self.len != 0) allocator.rawFree(self.ptr[0..self.len], self.alignment, @returnAddress());
    self.* = empty(self.alignment);
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "init allocates a buffer with the requested length and alignment" {
    const allocator = std.testing.allocator;
    var buf = try init(allocator, 1000, .@"64");

    try expectEqual(1000, buf.len);
    try expect(buf.alignment.check(@intFromPtr(buf.ptr)));

    buf.deinit(allocator);
    try expectEqual(0, buf.len);
    try expect(buf.alignment.check(@intFromPtr(buf.ptr)));
}

test "init honors runtime alignment" {
    const allocator = std.testing.allocator;

    for ([_]usize{ 1, 8, 64, 4096 }) |align_bytes| {
        const alignment = Alignment.fromByteUnits(align_bytes);
        var buf = try init(allocator, 100, alignment);
        defer buf.deinit(allocator);

        try expect(@intFromPtr(buf.ptr) % align_bytes == 0);
    }
}

test "empty returns an aligned sentinel without owning memory" {
    for ([_]usize{ 1, 8, 64, 4096 }) |align_bytes| {
        const alignment = Alignment.fromByteUnits(align_bytes);
        const buf = empty(alignment);

        try expectEqual(0, buf.len);
        try expectEqual(align_bytes, buf.alignment.toByteUnits());
        try expect(alignment.check(@intFromPtr(buf.ptr)));
    }
}

test "zero length buffer owns no memory" {
    const allocator = std.testing.allocator;
    var buf = try init(allocator, 0, .@"8");
    defer buf.deinit(allocator);

    try expectEqual(0, buf.len);
    try expectEqual(8, buf.alignment.toByteUnits());
    try expect(buf.alignment.check(@intFromPtr(buf.ptr)));
}
