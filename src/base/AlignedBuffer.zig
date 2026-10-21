//! A safe wrapper for runtime-aligned unmanaged buffers.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

ptr: ?[*]u8 = null,
len: usize = 0,
alignment: Alignment = .@"1",

/// Allocates a buffer of `len` bytes aligned to `alignment`. Free it with `deinit`.
pub fn init(allocator: Allocator, len: usize, alignment: Alignment) Allocator.Error!@This() {
    if (len == 0) return .{ .alignment = alignment };

    const ptr = allocator.rawAlloc(len, alignment, @returnAddress()) orelse
        return error.OutOfMemory;
    return .{ .ptr = ptr, .len = len, .alignment = alignment };
}

/// Frees the buffer allocated by `init` with the same allocator and resets to empty.
pub fn deinit(self: *@This(), allocator: Allocator) void {
    if (self.ptr) |ptr| allocator.rawFree(ptr[0..self.len], self.alignment, @returnAddress());
    self.* = .{};
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "init allocates a buffer with the requested length and alignment" {
    const allocator = std.testing.allocator;
    var buf = try init(allocator, 1000, .@"64");

    try expectEqual(1000, buf.len);
    try expect(buf.alignment.check(@intFromPtr(buf.ptr.?)));

    buf.deinit(allocator);
    try expect(buf.ptr == null);
}

test "init honors runtime alignment" {
    const allocator = std.testing.allocator;

    for ([_]usize{ 1, 8, 64, 4096 }) |align_bytes| {
        const alignment = Alignment.fromByteUnits(align_bytes);
        var buf = try init(allocator, 100, alignment);
        defer buf.deinit(allocator);

        try expect(@intFromPtr(buf.ptr.?) % align_bytes == 0);
    }
}

test "zero length buffer owns no memory" {
    const allocator = std.testing.allocator;
    var buf = try init(allocator, 0, .@"8");
    defer buf.deinit(allocator);

    try expect(buf.ptr == null);
    try expectEqual(0, buf.len);
}
