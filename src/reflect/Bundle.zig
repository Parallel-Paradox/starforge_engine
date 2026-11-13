//! A collection of `Parcel`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const reflect = engine.reflect;
const TypeId = reflect.TypeId;
const Parcel = reflect.Parcel;

/// Declare `pub const se_bundle: Bundle.Mark = .{};` in a struct to mark it as a bundle.
pub const Mark = struct {};

/// Whether `T` is a struct marked by `pub const se_bundle: Bundle.Mark = .{};`.
pub fn isBundle(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"struct" => {},
        else => return false,
    }
    if (comptime @hasDecl(T, "se_bundle")) {
        return @TypeOf(T.se_bundle) == Mark;
    }
    return false;
}

allocator: Allocator,
map: std.array_hash_map.Auto(TypeId, Parcel) = .{},

/// Builds a bundle holding one `Parcel` per field of `fields`, keyed by the field's storage
/// type. `fields` itself does not need to be marked.
///
/// If a field's type is marked with `se_bundle`, that struct is not stored as a value;
/// instead its fields are flattened into this bundle, recursively.
///
/// Non-struct `fields`, unsupported field types, and duplicate storage types are compile
/// errors.
///
/// Field values are copied into new storage, and ownership is consumed only on success: on
/// failure callers must free them (e.g. with `errdefer`). The allocator is stored and used by
/// every later operation on the bundle.
pub fn init(allocator: Allocator, fields: anytype) Allocator.Error!@This() {
    const values = flat(fields);
    comptime {
        const types = @typeInfo(@TypeOf(values)).@"struct".field_types;
        for (types, 0..) |T, i| {
            if (!Parcel.canStore(T)) @compileError("Bundle cannot store type " ++ @typeName(T));
            const S = Parcel.StorageOf(T);
            for (types[i + 1 ..]) |U| {
                if (S == Parcel.StorageOf(U))
                    @compileError("duplicate bundle type: " ++ @typeName(S));
            }
        }
    }

    var bundle: @This() = .{ .allocator = allocator };
    errdefer bundle.releaseStorage();
    try bundle.map.ensureUnusedCapacity(allocator, values.len);
    inline for (values) |value| {
        const parcel = try Parcel.init(allocator, value);
        bundle.map.putAssumeCapacityNoClobber(parcel.meta.id, parcel);
    }
    return bundle;
}

/// Frees every parcel's storage and the map without running the values' deinit, returning
/// their ownership to the caller.
pub fn releaseStorage(self: *@This()) void {
    for (self.map.values()) |*parcel| parcel.releaseStorage(self.allocator);
    self.map.deinit(self.allocator);
    self.map = .{};
}

/// Copies the fields into a tuple, recursively expanding marked bundle structs.
/// Unmarked structs remain values. Field types and traversal order are preserved,
/// including duplicate types. This does not allocate or transfer ownership.
pub fn flat(fields: anytype) Flat(@TypeOf(fields)) {
    var values: Flat(@TypeOf(fields)) = undefined;
    comptime var index: usize = 0;
    const info = @typeInfo(@TypeOf(fields)).@"struct";
    inline for (info.field_names, info.field_types) |name, T| {
        const nested = if (comptime isBundle(T))
            flat(@field(fields, name))
        else
            .{@field(fields, name)};
        inline for (nested) |value| {
            values[index] = value;
            index += 1;
        }
    }
    return values;
}

/// Preserves comptime fields so literals can coexist with runtime values in the tuple.
fn Flat(comptime T: type) type {
    const info = switch (@typeInfo(T)) {
        .@"struct" => |info| info,
        else => @compileError("Bundle expects a struct, found " ++ @typeName(T)),
    };
    var Tuple = @TypeOf(.{});
    for (info.field_types, info.field_attrs) |Field, attrs| {
        const Part = if (isBundle(Field))
            Flat(Field)
        else if (attrs.@"comptime")
            @TypeOf(.{attrs.defaultValue(Field).?})
        else
            @Tuple(&.{Field});
        Tuple = @TypeOf(@as(Tuple, undefined) ++ @as(Part, undefined));
    }
    return Tuple;
}

/// Number of fields `T` contributes once marked structs are flattened.
fn flatCount(comptime T: type) usize {
    return @typeInfo(Flat(T)).@"struct".field_types.len;
}

/// The flattened field types of `T` in traversal order.
pub fn flatTypes(comptime T: type) [flatCount(T)]type {
    return @typeInfo(Flat(T)).@"struct".field_types[0..comptime flatCount(T)].*;
}

/// Deinits every parcel and frees the map, leaving an empty bundle with the same allocator.
pub fn deinit(self: *@This()) void {
    for (self.map.values()) |*parcel| parcel.deinit(self.allocator);
    self.map.deinit(self.allocator);
    self.map = .{};
}

/// Moves every parcel of `other` into `self`, overwriting (and deinit-ing) `self`'s parcel
/// on a type collision.
///
/// Ownership of `other` is consumed only on success: on failure it remains with the caller
/// (`errdefer` it); on success its storage is freed here. Both bundles must use the same
/// allocator.
pub fn merge(self: *@This(), other: @This()) Allocator.Error!void {
    std.debug.assert(other.map.capacity() == 0 or self.map.keys().ptr != other.map.keys().ptr);
    std.debug.assert(std.meta.eql(self.allocator, other.allocator));
    var moved = other;
    try self.map.ensureUnusedCapacity(self.allocator, moved.map.count());
    for (moved.map.values()) |parcel| self.storeAssumeCapacity(parcel);
    moved.map.deinit(moved.allocator);
}

/// Stores a value of any type, overwriting (and deinit-ing) any existing parcel of that type.
///
/// A struct marked with `se_bundle` is flattened and merged like `init`.
///
/// Ownership of the value is consumed only on success: on failure the caller still owns it
/// and must free it (e.g. with `errdefer`).
pub fn insert(self: *@This(), value: anytype) Allocator.Error!void {
    if (comptime isBundle(@TypeOf(value))) {
        var bundle = try init(self.allocator, value);
        errdefer bundle.releaseStorage();
        try self.merge(bundle);
        return;
    }

    var parcel = try Parcel.init(self.allocator, value);
    errdefer parcel.releaseStorage(self.allocator);
    try self.insertParcel(parcel);
}

/// Stores `parcel` keyed by its type, overwriting (and deinit-ing) any existing parcel of that
/// type.
///
/// Ownership of `parcel` is consumed only on success: on failure the caller still owns it and
/// must free it (e.g. with `errdefer`).
pub fn insertParcel(self: *@This(), parcel: Parcel) Allocator.Error!void {
    if (self.map.getPtr(parcel.meta.id) == null)
        try self.map.ensureUnusedCapacity(self.allocator, 1);
    self.storeAssumeCapacity(parcel);
}

/// Stores `parcel` without allocating, replacing and deinit-ing any parcel of the same type.
/// The caller must have ensured capacity for a new key beforehand.
fn storeAssumeCapacity(self: *@This(), parcel: Parcel) void {
    const gop = self.map.getOrPutAssumeCapacity(parcel.meta.id);
    if (gop.found_existing) gop.value_ptr.deinit(self.allocator);
    gop.value_ptr.* = parcel;
}

/// Removes the parcel of type `T` and returns its value. Comptime number types are looked up
/// by their storage type.
pub fn remove(self: *@This(), comptime T: type) ?Parcel.StorageOf(T) {
    const S = Parcel.StorageOf(T);
    var parcel = self.removeId(TypeId.of(S)) orelse return null;
    return parcel.take(S, self.allocator);
}

/// Removes the parcel keyed by `id` and returns it. Ownership of the parcel passes to the
/// caller.
pub fn removeId(self: *@This(), id: TypeId) ?Parcel {
    return (self.map.fetchSwapRemove(id) orelse return null).value;
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

const Probe = struct {
    calls: *usize,

    pub fn deinit(self: *@This()) void {
        self.calls.* += 1;
    }
};

const Inner = struct {
    pub const se_bundle: Mark = .{};
    id: u64,
    ratio: f64,
};

const Outer = struct {
    pub const se_bundle: Mark = .{};
    inner: Inner,
    flag: bool,
};

const Plain = struct {
    count: i32,
};

fn expectStored(bundle: @This(), comptime T: type, expected: T) !void {
    const parcel = bundle.map.get(TypeId.of(T)).?;
    const value: *T = @ptrCast(@alignCast(parcel.ptr.?));
    try expectEqual(expected, value.*);
}

test "init stores fields under their storage type" {
    const allocator = std.testing.allocator;
    var bundle = try init(allocator, .{ .count = 7, .ratio = 0.5, .flag = true });
    defer bundle.deinit();

    try expectEqual(3, bundle.map.count());
    try expectStored(bundle, isize, 7);
    try expectStored(bundle, f64, 0.5);
    try expectStored(bundle, bool, true);

    // Non-struct input is a compile error:
    // _ = init(allocator, 1);
}

test "isBundle detects the se_bundle declaration" {
    try expect(isBundle(Inner));
    try expect(isBundle(Outer));
    try expect(!isBundle(Plain));
    try expect(!isBundle(Mark));
    try expect(!isBundle(u32));
}

test "flat and init flatten marked structs recursively" {
    const allocator = std.testing.allocator;
    const fields = .{
        .outer = Outer{
            .inner = .{ .id = 7, .ratio = 0.5 },
            .flag = true,
        },
        .plain = Plain{ .count = 3 },
    };
    try std.testing.expectEqualDeep(.{ 7, 0.5, true, Plain{ .count = 3 } }, flat(fields));
    try expectEqual(0, flat(.{}).len);
    try std.testing.expectEqualDeep(.{ 1, 2 }, flat(.{ .first = 1, .second = 2 }));

    var bundle = try init(allocator, fields);
    defer bundle.deinit();

    try expectEqual(4, bundle.map.count());
    try expectStored(bundle, u64, 7);
    try expectStored(bundle, f64, 0.5);
    try expectStored(bundle, bool, true);
    try expectStored(bundle, Plain, Plain{ .count = 3 });
}

test "init leaves values to the caller when it fails" {
    const allocator = std.testing.allocator;
    var calls: usize = 0;
    // Growing `map` and the first parcel succeed; the second parcel fails.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 2 });

    var owned = Probe{ .calls = &calls };
    try expectError(error.OutOfMemory, init(failing.allocator(), .{
        .probe = owned,
        .count = 7,
    }));
    try expectEqual(0, calls);

    owned.deinit();
    try expectEqual(1, calls);
}

test "merge moves parcels and overwrites duplicates" {
    const allocator = std.testing.allocator;
    var old_calls: usize = 0;
    var new_calls: usize = 0;
    var self_bundle = try init(allocator, .{
        .count = 1,
        .probe = Probe{ .calls = &old_calls },
    });
    const other = try init(allocator, .{
        .count = 9,
        .ratio = 0.5,
        .probe = Probe{ .calls = &new_calls },
    });

    try self_bundle.merge(other);

    try expectEqual(3, self_bundle.map.count());
    try expectStored(self_bundle, isize, 9);
    try expectEqual(1, old_calls);
    try expectEqual(0, new_calls);

    self_bundle.deinit();
    try expectEqual(1, new_calls);
}

test "merge leaves other to the caller when it fails" {
    const allocator = std.testing.allocator;
    var calls: usize = 0;
    // `other` is built first; growing `self_bundle` then fails.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 2 });
    var self_bundle = try init(failing.allocator(), .{});
    var other = try init(failing.allocator(), .{Probe{ .calls = &calls }});

    try expectError(error.OutOfMemory, self_bundle.merge(other));
    try expectEqual(0, calls);

    other.deinit();
    try expectEqual(1, calls);
}

test "insert stores values and flattens marked structs" {
    const allocator = std.testing.allocator;
    var old_calls: usize = 0;
    var new_calls: usize = 0;
    var bundle = try init(allocator, .{});
    defer bundle.deinit();

    try bundle.insert(7);
    try bundle.insert(8);
    try expectStored(bundle, isize, 8);

    try bundle.insert(Probe{ .calls = &old_calls });
    try bundle.insert(Probe{ .calls = &new_calls });
    try expectEqual(1, old_calls);
    try expectEqual(0, new_calls);

    try bundle.insert(Inner{ .id = 7, .ratio = 0.5 });
    try expectStored(bundle, u64, 7);
    try expectStored(bundle, f64, 0.5);
    try expectEqual(4, bundle.map.count());
}

test "insert leaves the value to the caller when it fails" {
    var calls: usize = 0;
    // The parcel is created; growing `map` fails.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var bundle = try init(failing.allocator(), .{});

    var owned = Probe{ .calls = &calls };
    try expectError(error.OutOfMemory, bundle.insert(owned));
    try expectEqual(0, calls);
    try expectEqual(0, bundle.map.count());

    owned.deinit();
    try expectEqual(1, calls);
}

test "insertParcel leaves the parcel to the caller when it fails" {
    var calls: usize = 0;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var bundle = try init(failing.allocator(), .{});
    var parcel = try Parcel.init(std.testing.allocator, Probe{ .calls = &calls });
    defer parcel.deinit(std.testing.allocator);

    try expectError(error.OutOfMemory, bundle.insertParcel(parcel));
    try expectEqual(0, calls);
    try expectEqual(0, bundle.map.count());
}

test "remove takes the value out and normalizes storage types" {
    const allocator = std.testing.allocator;
    var calls: usize = 0;
    var bundle = try init(allocator, .{});
    defer bundle.deinit();

    try bundle.insert(Probe{ .calls = &calls });
    var probe = bundle.remove(Probe).?;
    try expectEqual(0, calls);
    try expectEqual(0, bundle.map.count());
    try expect(bundle.remove(Probe) == null);

    probe.deinit();
    try expectEqual(1, calls);

    try bundle.insert(-7);
    try expectEqual(-7, bundle.remove(comptime_int).?);
}

test "removeId returns the parcel to the caller" {
    const allocator = std.testing.allocator;
    var calls: usize = 0;
    var bundle = try init(allocator, .{});
    defer bundle.deinit();
    try bundle.insert(Probe{ .calls = &calls });

    var parcel = bundle.removeId(TypeId.of(Probe)).?;
    try expectEqual(0, calls);
    try expectEqual(0, bundle.map.count());

    parcel.deinit(allocator);
    try expectEqual(1, calls);
}
