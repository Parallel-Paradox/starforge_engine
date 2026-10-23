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
    return @This(){
        // Impossible to fail since we start with empty bitset.
        .mask = BitSet.initEmpty(allocator, 0) catch unreachable,
    };
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
    return self.hash == other.hash and self.mask.eql(other.mask);
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
pub fn has(self: *const @This(), id: CompId) bool {
    const index = bitIndex(id);
    return index < self.mask.capacity() and self.mask.isSet(index);
}

/// Adds every component ID in `ids` to the signature.
pub fn add(self: *@This(), allocator: Allocator, ids: []const CompId) Allocator.Error!void {
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
/// Always shrink to fit after removing components.
pub fn remove(self: *@This(), allocator: Allocator, ids: []const CompId) Allocator.Error!void {
    const capacity = self.mask.capacity();
    for (ids) |id| {
        const index = bitIndex(id);
        if (index < capacity) self.mask.unset(index);
    }

    // Drop the bits above the highest remaining component.
    const new_len = if (self.mask.findLastSet()) |last_bit| last_bit + 1 else 0;
    try self.mask.resize(allocator, new_len, false);

    self.rehash();
}

/// A hash map that uses signatures as keys and stores values of type T.
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

test "add sets component bits" {
    const allocator = std.testing.allocator;

    var signature = init(allocator);
    defer signature.deinit(allocator);

    const ids = [_]CompId{ CompId.init(0, 1), CompId.init(7, 1), CompId.init(70, 1) };
    try signature.add(allocator, &ids);

    try expect(signature.has(CompId.init(0, 1)));
    try expect(signature.has(CompId.init(7, 1)));
    try expect(signature.has(CompId.init(70, 1)));
    try expect(!signature.has(CompId.init(6, 1)));
    try expect(!signature.has(CompId.init(71, 1)));

    // Adding the same components again changes neither the bits nor the capacity.
    try signature.add(allocator, &ids);
    try expectEqual(@as(usize, 3), signature.mask.count());
    try expectEqual(@as(usize, 71), signature.mask.capacity());
}

test "remove clears bits and shrinks to fit" {
    const allocator = std.testing.allocator;

    var signature = init(allocator);
    defer signature.deinit(allocator);

    const ids = [_]CompId{ CompId.init(3, 1), CompId.init(70, 1) };
    try signature.add(allocator, &ids);
    try expectEqual(@as(usize, 71), signature.mask.capacity());

    const last = [_]CompId{CompId.init(70, 1)};
    try signature.remove(allocator, &last);
    try expect(!signature.has(CompId.init(70, 1)));
    try expect(signature.has(CompId.init(3, 1)));
    try expectEqual(@as(usize, 4), signature.mask.capacity());

    const first = [_]CompId{CompId.init(3, 1)};
    try signature.remove(allocator, &first);
    try expect(!signature.has(CompId.init(3, 1)));
    try expectEqual(@as(usize, 0), signature.mask.capacity());

    // Removing a component the signature does not have is a no-op.
    try signature.remove(allocator, &first);
    try expectEqual(@as(usize, 0), signature.mask.capacity());
}

test "contains and intersects compare component sets" {
    const allocator = std.testing.allocator;

    var all = init(allocator);
    defer all.deinit(allocator);
    const all_ids = [_]CompId{ CompId.init(1, 1), CompId.init(2, 1), CompId.init(70, 1) };
    try all.add(allocator, &all_ids);

    var some = init(allocator);
    defer some.deinit(allocator);
    const some_ids = [_]CompId{ CompId.init(1, 1), CompId.init(70, 1) };
    try some.add(allocator, &some_ids);

    var other = init(allocator);
    defer other.deinit(allocator);
    const other_ids = [_]CompId{CompId.init(2, 1)};
    try other.add(allocator, &other_ids);

    var disjoint = init(allocator);
    defer disjoint.deinit(allocator);
    const disjoint_ids = [_]CompId{CompId.init(5, 1)};
    try disjoint.add(allocator, &disjoint_ids);

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

test "eql and clone track the component set" {
    const allocator = std.testing.allocator;

    var a = init(allocator);
    defer a.deinit(allocator);
    var b = init(allocator);
    defer b.deinit(allocator);

    // Empty signatures hash consistently.
    try expect(a.eql(b));
    try expectEqual(a.hash, b.hash);

    const ids = [_]CompId{ CompId.init(0, 1), CompId.init(3, 1) };
    try a.add(allocator, &ids);
    try b.add(allocator, &ids);
    try expect(a.eql(b));
    try expectEqual(a.hash, b.hash);

    var cloned = try a.clone(allocator);
    defer cloned.deinit(allocator);
    try expect(a.eql(cloned));

    const extra = [_]CompId{CompId.init(4, 1)};
    try cloned.add(allocator, &extra);
    try expect(!a.eql(cloned));
    try expect(!a.has(CompId.init(4, 1)));

    try b.remove(allocator, &ids);
    try expect(!a.eql(b));
    try expect(a.eql(a));
}

test "Lookup maps signatures to values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const Map = Lookup(u32);
    var map: Map = .empty;
    defer map.deinit(allocator);

    var first = init(allocator);
    const first_ids = [_]CompId{ CompId.init(1, 1), CompId.init(70, 1) };
    try first.add(allocator, &first_ids);
    try map.put(allocator, try first.clone(allocator), 10);

    var second = init(allocator);
    const second_ids = [_]CompId{CompId.init(2, 1)};
    try second.add(allocator, &second_ids);
    try map.put(allocator, try second.clone(allocator), 20);

    // An independently built signature with the same components finds the entry.
    var probe = init(allocator);
    const probe_ids = [_]CompId{ CompId.init(70, 1), CompId.init(1, 1) };
    try probe.add(allocator, &probe_ids);

    try expectEqual(@as(?u32, 10), map.get(probe));
    try expectEqual(@as(u32, 2), map.count());

    // Putting an equal key updates the stored value.
    try map.put(allocator, try probe.clone(allocator), 11);
    try expectEqual(@as(u32, 2), map.count());
    try expectEqual(@as(?u32, 11), map.get(probe));

    var missing = init(allocator);
    const missing_ids = [_]CompId{CompId.init(5, 1)};
    try missing.add(allocator, &missing_ids);
    try expectEqual(@as(?u32, null), map.get(missing));

    try expect(map.remove(probe));
    try expectEqual(@as(u32, 1), map.count());
    try expectEqual(@as(?u32, null), map.get(probe));
}
