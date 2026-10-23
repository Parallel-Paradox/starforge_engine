//! A signature is a set of component IDs that describes the components an entity has.

const std = @import("std");
const Allocator = std.mem.Allocator;
const BitSet = std.DynamicBitSetUnmanaged;

const engine = @import("engine");
const CompId = engine.ecs.component.Id;

/// Each component ID corresponds to a bit in the signature's bitset.
mask: BitSet,
/// A hash of the signature's bitset, used for fast equality checks and hashmap.
hash: u64 = 0,

pub fn init(allocator: Allocator) @This() {
    var self: @This() = .{
        // Impossible to fail since we start with empty bitset.
        .mask = BitSet.initEmpty(allocator, 0) catch unreachable,
    };
    self.rehash();
    return self;
}

pub fn deinit(self: *@This(), allocator: Allocator) void {
    self.mask.deinit(allocator);
    self.hash = 0;
}

pub fn clone(self: *const @This(), allocator: Allocator) Allocator.Error!@This() {
    return @This(){
        .mask = try self.mask.clone(allocator),
        .hash = self.hash,
    };
}

/// The bit that holds `id` in the mask.
fn bitIndex(id: CompId) usize {
    return @intCast(id.index.get());
}

/// The number of mask words that hold `bit_length` bits.
fn maskCount(bit_length: usize) usize {
    const bits = @bitSizeOf(BitSet.MaskInt);
    return (bit_length + bits - 1) / bits;
}

fn rehash(self: *@This()) void {
    const hasher = std.hash.Wyhash.hash;
    const last_bit = self.mask.findLastSet() orelse {
        self.hash = hasher(0, "");
        return;
    };
    const last_mask = last_bit / @bitSizeOf(BitSet.MaskInt);
    self.hash = hasher(0, std.mem.sliceAsBytes(self.mask.masks[0 .. last_mask + 1]));
}

pub fn eql(self: @This(), other: @This()) bool {
    if (self.hash != other.hash) return false;

    const self_last = self.mask.findLastSet() orelse return other.mask.findLastSet() == null;
    const other_last = other.mask.findLastSet() orelse return false;
    if (self_last != other_last) return false;

    const num_masks = maskCount(self_last + 1);
    for (self.mask.masks[0..num_masks], other.mask.masks[0..num_masks]) |a, b| {
        if (a != b) return false;
    }
    return true;
}

/// Whether this signature contains every component in `other`.
pub fn contains(self: @This(), other: @This()) bool {
    const other_last = other.mask.findLastSet() orelse return true;
    const self_last = self.mask.findLastSet() orelse return false;
    if (other_last > self_last) return false;

    const num_masks = maskCount(other_last + 1);
    for (self.mask.masks[0..num_masks], other.mask.masks[0..num_masks]) |mask, other_mask| {
        if (other_mask & ~mask != 0) return false;
    }
    return true;
}

/// Whether this signature and `other` share at least one component.
pub fn intersects(self: @This(), other: @This()) bool {
    const common_len = @min(self.mask.capacity(), other.mask.capacity());
    const num_masks = maskCount(common_len);
    for (self.mask.masks[0..num_masks], other.mask.masks[0..num_masks]) |mask, other_mask| {
        if (mask & other_mask != 0) return true;
    }
    return false;
}

/// Whether this signature has the component `id`.
/// `id` must be valid (not `CompId.invalid`).
pub fn has(self: @This(), id: CompId) bool {
    const index = bitIndex(id);
    return index < self.mask.capacity() and self.mask.isSet(index);
}

/// Adds every component ID in `ids` to the signature.
/// Every id in `ids` must be valid (not `CompId.invalid`).
pub fn add(self: *@This(), allocator: Allocator, ids: []const CompId) Allocator.Error!void {
    if (ids.len == 0) return;

    const capacity = self.mask.capacity();
    var new_len = capacity;
    for (ids) |id| {
        new_len = @max(new_len, bitIndex(id) + 1);
    }
    if (new_len > capacity) {
        try self.mask.resize(allocator, new_len, false);
    }

    for (ids) |id| self.mask.set(bitIndex(id));

    self.rehash();
}

/// Removes every component ID in `ids` from the signature.
/// Every id in `ids` must be valid (not `CompId.invalid`).
/// The mask keeps its capacity; removing never shrinks it.
pub fn remove(self: *@This(), ids: []const CompId) void {
    if (ids.len == 0) return;

    const capacity = self.mask.capacity();
    for (ids) |id| {
        const index = bitIndex(id);
        if (index < capacity) self.mask.unset(index);
    }

    self.rehash();
}

/// A hash map that uses signatures as keys and stores values of type T.
///
/// The map does not own its keys: it never frees or updates the bitset a key
/// holds. Store a `clone` and keep it alive and unchanged for as long as the
/// entry exists.
pub fn Lookup(comptime T: type) type {
    const Signature = @This();

    const Context = struct {
        pub fn hash(_: @This(), key: Signature) u64 {
            return key.hash;
        }

        pub fn eql(_: @This(), a: Signature, b: Signature) bool {
            return a.eql(b);
        }
    };

    return std.HashMapUnmanaged(Signature, T, Context, std.hash_map.default_max_load_percentage);
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// Builds component ids with generation 1 from the given component indexes.
fn compIds(comptime indexes: []const u32) [indexes.len]CompId {
    var result: [indexes.len]CompId = undefined;
    for (indexes, 0..) |index, i| {
        result[i] = CompId.init(index, 1);
    }
    return result;
}

/// Initializes a signature that holds the components at `indexes`.
fn initWith(allocator: Allocator, comptime indexes: []const u32) Allocator.Error!@This() {
    var signature = init(allocator);
    errdefer signature.deinit(allocator);

    const components = compIds(indexes);
    try signature.add(allocator, &components);
    return signature;
}

test "add sets component bits" {
    const allocator = std.testing.allocator;

    var signature = try initWith(allocator, &.{ 0, 7, 70 });
    defer signature.deinit(allocator);

    try expect(signature.has(CompId.init(0, 1)));
    try expect(signature.has(CompId.init(7, 1)));
    try expect(signature.has(CompId.init(70, 1)));
    try expect(!signature.has(CompId.init(6, 1)));
    try expect(!signature.has(CompId.init(71, 1)));

    // Adding existing components is a no-op.
    const again = compIds(&.{ 0, 7, 70 });
    try signature.add(allocator, &again);
    try expectEqual(@as(usize, 3), signature.mask.count());
}

test "remove clears bits" {
    const allocator = std.testing.allocator;

    var signature = try initWith(allocator, &.{ 3, 70 });
    defer signature.deinit(allocator);

    const high = compIds(&.{70});
    signature.remove(&high);
    try expect(!signature.has(CompId.init(70, 1)));
    try expect(signature.has(CompId.init(3, 1)));

    const remaining = compIds(&.{3});
    signature.remove(&remaining);
    try expect(!signature.has(CompId.init(3, 1)));

    // Removing a component the signature does not have is a no-op.
    signature.remove(&remaining);
    try expectEqual(@as(usize, 0), signature.mask.count());
}

test "contains and intersects compare component sets" {
    const allocator = std.testing.allocator;

    var all = try initWith(allocator, &.{ 1, 2, 70 });
    defer all.deinit(allocator);
    var some = try initWith(allocator, &.{ 1, 70 });
    defer some.deinit(allocator);
    var other = try initWith(allocator, &.{2});
    defer other.deinit(allocator);
    var disjoint = try initWith(allocator, &.{5});
    defer disjoint.deinit(allocator);

    var empty = init(allocator);
    defer empty.deinit(allocator);

    try expect(all.contains(all));
    try expect(all.contains(some));
    try expect(!some.contains(all));
    try expect(all.contains(other));
    try expect(all.contains(empty));
    try expect(!empty.contains(all));

    try expect(all.intersects(some));
    try expect(all.intersects(other));
    try expect(!some.intersects(other));
    try expect(!all.intersects(disjoint));
    try expect(!all.intersects(empty));
}

test "eql and clone compare component sets" {
    const allocator = std.testing.allocator;

    var empty = init(allocator);
    defer empty.deinit(allocator);

    var a = try initWith(allocator, &.{ 0, 3 });
    defer a.deinit(allocator);
    var b = try initWith(allocator, &.{ 3, 0 });
    defer b.deinit(allocator);

    // Component order does not matter.
    try expect(a.eql(b));
    try expectEqual(a.hash, b.hash);

    // Mask capacity does not matter either.
    var wide = try initWith(allocator, &.{ 0, 3, 70 });
    defer wide.deinit(allocator);
    const high = compIds(&.{70});
    wide.remove(&high);
    try expect(a.eql(wide));
    try expectEqual(a.hash, wide.hash);

    // Clearing a signature makes it equal to a fresh one.
    const both = compIds(&.{ 0, 3 });
    a.remove(&both);
    try expect(empty.eql(a));
    try expectEqual(empty.hash, a.hash);

    // A clone is independent of its source.
    var cloned = try b.clone(allocator);
    defer cloned.deinit(allocator);
    try expect(b.eql(cloned));
    const extra = compIds(&.{4});
    try cloned.add(allocator, &extra);
    try expect(!b.eql(cloned));
    try expect(!b.has(CompId.init(4, 1)));
}

test "Lookup maps signatures to values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const Map = Lookup(u32);
    var map: Map = .empty;
    defer map.deinit(allocator);

    const first = try initWith(allocator, &.{ 1, 70 });
    try map.put(allocator, try first.clone(allocator), 10);

    const second = try initWith(allocator, &.{2});
    try map.put(allocator, try second.clone(allocator), 20);

    // The same components in a different order find the same entry.
    const probe = try initWith(allocator, &.{ 70, 1 });

    try expectEqual(@as(?u32, 10), map.get(probe));
    try expectEqual(@as(u32, 2), map.count());

    // Putting an equal key updates the value in place.
    try map.put(allocator, try probe.clone(allocator), 11);
    try expectEqual(@as(u32, 2), map.count());
    try expectEqual(@as(?u32, 11), map.get(probe));

    const missing = try initWith(allocator, &.{5});
    try expectEqual(@as(?u32, null), map.get(missing));

    try expect(map.remove(probe));
    try expectEqual(@as(u32, 1), map.count());
    try expectEqual(@as(?u32, null), map.get(probe));
}
