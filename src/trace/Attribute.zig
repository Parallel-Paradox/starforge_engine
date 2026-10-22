//! A key-value pair that can be attached to a trace event or span.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const root = @import("root.zig");
const String = root.super.base.String;

key: []const u8,
value: Value,

pub fn deinit(self: *@This(), allocator: Allocator) void {
    self.value.deinit(allocator);
}

pub const Value = union(enum) {
    str: []const u8,
    string: String,
    int: i64,
    uint: u64,
    float: f64,
    bool: bool,
    array: ArrayValue,

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        switch (self.*) {
            .string => |*string| string.deinit(allocator),
            .array => |*array| array.deinit(allocator),
            else => {},
        }
    }

    /// Returns the variant that a value of type `T` converts to, or `null` if unsupported.
    /// Const byte slices map to `str`, and `String` maps to `string`.
    pub fn tagFor(comptime T: type) ?std.meta.FieldEnum(Value) {
        if (T == String) return .string;
        return switch (@typeInfo(T)) {
            .bool => .bool,
            .int => |int| if (int.bits > 64) null else switch (int.signedness) {
                .signed => .int,
                .unsigned => .uint,
            },
            .comptime_int => .int,
            .float => |float| if (float.bits > 64) null else .float,
            .comptime_float => .float,
            .pointer => |ptr| if (isConstByteString(ptr)) .str else null,
            else => null,
        };
    }

    /// The payload element type of the array variant `tag`.
    pub fn ElemOf(comptime tag: std.meta.FieldEnum(Value)) type {
        return switch (tag) {
            .str => []const u8,
            .string => String,
            .int => i64,
            .uint => u64,
            .float => f64,
            .bool => bool,
            else => unreachable,
        };
    }

    /// Converts a scalar or string `val` into a `Value`. Const byte slices become `str` (borrowed).
    /// Arrays are not handled here; use `ArrayValue.from` for them.
    ///
    /// Unsupported types are rejected at compile time.
    pub fn from(val: anytype) Value {
        const T = @TypeOf(val);
        const tag = comptime tagFor(T) orelse @compileError(
            "Attribute.Value.from does not support type " ++ @typeName(T),
        );
        return @unionInit(Value, @tagName(tag), val);
    }

    /// Whether `T` can be converted by `from` (scalars and strings) or `fromArray` (arrays).
    pub fn isConvertible(comptime T: type) bool {
        const info = @typeInfo(ArrayValue).@"union";
        inline for (info.field_types) |field_type| {
            if (T == field_type) return true;
        }
        return tagFor(T) != null or ArrayValue.elemTagFor(T) != null;
    }

    /// Wraps the result of `ArrayValue.from` in the `array` variant.
    pub fn fromArray(allocator: Allocator, val: anytype) Allocator.Error!Value {
        return .{ .array = try ArrayValue.from(allocator, val) };
    }

    fn isConstByteString(comptime ptr: std.lang.Type.Pointer) bool {
        if (!ptr.attrs.@"const") return false;
        if (ptr.size == .slice) return ptr.child == u8;
        if (ptr.size == .one) switch (@typeInfo(ptr.child)) {
            .array => |arr| return arr.child == u8,
            else => {},
        };
        return false;
    }

    pub fn writeTo(self: @This(), writer: *Writer) Writer.Error!void {
        switch (self) {
            .str => |str| {
                try writer.writeAll("&\"");
                try writeEscaped(writer, str);
                try writer.writeByte('"');
            },
            .string => |str| {
                try writer.writeByte('"');
                try writeEscaped(writer, str.slice());
                try writer.writeByte('"');
            },
            .bool => |b| try writer.writeAll(if (b) "true" else "false"),
            .array => |array| try array.writeTo(writer),
            inline else => |val| try writer.print("{d}", .{val}),
        }
    }
};

/// Escapes `\` and `"` so that a quoted string can be read back unambiguously.
fn writeEscaped(writer: *Writer, str: []const u8) Writer.Error!void {
    for (str) |c| {
        switch (c) {
            '\\', '"' => try writer.writeByte('\\'),
            else => {},
        }
        try writer.writeByte(c);
    }
}

/// The element of an array must be the same type, and cannot be another array.
pub const ArrayValue = union(enum) {
    str: std.ArrayList([]const u8),
    string: std.ArrayList(String),
    int: std.ArrayList(i64),
    uint: std.ArrayList(u64),
    float: std.ArrayList(f64),
    bool: std.ArrayList(bool),

    /// Takes ownership of an `ArrayList` whose element type matches a variant, or copies the
    /// elements of a slice (`String` elements are cloned, `[]const u8` elements are
    /// borrowed and must outlive the returned value).
    ///
    /// Ownership of a passed `ArrayList` transfers only on success. On failure the caller
    /// still owns it, so callers should free it in an `errdefer`.
    pub fn from(allocator: Allocator, val: anytype) Allocator.Error!ArrayValue {
        const T = @TypeOf(val);
        const info = @typeInfo(ArrayValue).@"union";
        inline for (info.field_names, info.field_types) |field_name, field_type| {
            if (T == field_type) return @unionInit(ArrayValue, field_name, val);
        }

        const tag = comptime elemTagFor(T) orelse @compileError(
            "Attribute.ArrayValue.from does not support type " ++ @typeName(T),
        );

        var list = try std.ArrayList(Value.ElemOf(tag)).initCapacity(allocator, val.len);
        errdefer {
            if (comptime tag == .string) for (list.items) |*str| str.deinit(allocator);
            list.deinit(allocator);
        }
        for (val) |item| {
            const elem = switch (tag) {
                .string => try String.fromSlice(allocator, item.slice()),
                else => @as(Value.ElemOf(tag), item),
            };
            list.appendAssumeCapacity(elem);
        }
        return @unionInit(ArrayValue, @tagName(tag), list);
    }

    /// The value tag of the elements of a copyable sequence `T`, or `null` if `T` is not one.
    fn elemTagFor(comptime T: type) ?std.meta.FieldEnum(Value) {
        const is_sequence = switch (@typeInfo(T)) {
            .array => true,
            .pointer => |ptr| ptr.size == .slice or
                (ptr.size == .one and @typeInfo(ptr.child) == .array),
            else => false,
        };
        if (comptime !is_sequence) return null;
        if (comptime Value.tagFor(T) != null) return null;
        return Value.tagFor(std.meta.Elem(T));
    }

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        switch (self.*) {
            .string => |*string_list| {
                for (string_list.items) |*str| str.deinit(allocator);
                string_list.deinit(allocator);
            },
            inline else => |*list| list.deinit(allocator),
        }
    }

    pub fn writeTo(self: @This(), writer: *Writer) Writer.Error!void {
        switch (self) {
            .str => |list| try writeList(writer, list.items, .str),
            .string => |list| try writeList(writer, list.items, .string),
            .int => |list| try writeList(writer, list.items, .int),
            .uint => |list| try writeList(writer, list.items, .uint),
            .float => |list| try writeList(writer, list.items, .float),
            .bool => |list| try writeList(writer, list.items, .bool),
        }
    }

    fn writeList(
        writer: *Writer,
        items: anytype,
        comptime value_tag: std.meta.FieldEnum(Value),
    ) Writer.Error!void {
        try writer.writeAll("[");
        for (items, 0..) |item, index| {
            if (index != 0) try writer.writeAll(", ");
            const value = @unionInit(Value, @tagName(value_tag), item);
            try value.writeTo(writer);
        }
        try writer.writeAll("]");
    }
};

/// Adopts each field of `fields` to `list` as an attribute keyed by the field name.
///
/// Non-struct `fields` and field types that cannot be converted are compile errors.
/// Ownership of `fields` is consumed only on success: on failure `fields` is left
/// untouched, so callers that own fields must free them (e.g. with `errdefer`).
/// Borrowed fields like `str` must outlive the given list.
pub fn appendStruct(
    allocator: Allocator,
    list: *std.ArrayList(@This()),
    fields: anytype,
) Allocator.Error!void {
    const field_info = switch (@typeInfo(@TypeOf(fields))) {
        .@"struct" => |info| info,
        else => @compileError(
            "appendStruct expects a struct, found " ++ @typeName(@TypeOf(fields)),
        ),
    };
    inline for (field_info.field_types) |field_type| {
        if (comptime !Value.isConvertible(field_type)) @compileError(
            "appendStruct cannot convert field type " ++ @typeName(field_type),
        );
    }

    const count = field_info.field_names.len;
    try list.ensureUnusedCapacity(allocator, count);

    const start = list.items.len;
    var needs_deinit: [count]bool = undefined;
    var converted: usize = 0;
    errdefer {
        for (list.items[start..], needs_deinit[0..converted]) |*attr, needs| {
            if (needs) attr.value.deinit(allocator);
        }
        list.shrinkRetainingCapacity(start);
    }

    inline for (field_info.field_names, field_info.field_types, 0..) |field_name, field_type, i| {
        const value = try toValue(allocator, field_type, @field(fields, field_name));
        list.appendAssumeCapacity(.{ .key = field_name, .value = value });
        // Moved payloads still belong to `fields` until the whole call succeeds.
        needs_deinit[i] = comptime !movesPayload(field_type);
        converted = i + 1;
    }
}

/// Whether `Value.from` or `ArrayValue.from` moves `T`'s payload instead of copying it.
fn movesPayload(comptime T: type) bool {
    if (T == String) return true;
    const info = @typeInfo(ArrayValue).@"union";
    inline for (info.field_types) |field_type| {
        if (T == field_type) return true;
    }
    return false;
}

/// Converts a field already validated by `Value.isConvertible`, so only allocation can fail.
fn toValue(allocator: Allocator, comptime T: type, val: T) Allocator.Error!Value {
    if (comptime Value.tagFor(T) != null) {
        return Value.from(val);
    }
    return Value.fromArray(allocator, val);
}

const expectEqualStrings = std.testing.expectEqualStrings;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const expect = std.testing.expect;

fn expectValueWrites(value: Value, expected: []const u8) !void {
    var output = Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try value.writeTo(&output.writer);
    try expectEqualStrings(expected, output.written());
}

test "value writes scalar values" {
    try expectValueWrites(.{ .str = "hello" }, "&\"hello\"");
    try expectValueWrites(.{ .bool = true }, "true");
    try expectValueWrites(.{ .bool = false }, "false");
    try expectValueWrites(.{ .int = -42 }, "-42");
    try expectValueWrites(.{ .uint = 42 }, "42");
    try expectValueWrites(.{ .float = 3.5 }, "3.5");
}

test "value writes an owned string" {
    var value = Value{ .string = try String.fromSlice(std.testing.allocator, "owned string") };
    defer value.deinit(std.testing.allocator);

    try expectValueWrites(value, "\"owned string\"");
}

test "value writes arrays" {
    const allocator = std.testing.allocator;

    var int_list = try std.ArrayList(i64).initCapacity(allocator, 2);
    try int_list.appendSlice(allocator, &[_]i64{ 1, -2 });
    var int_value = Value{ .array = .{ .int = int_list } };
    defer int_value.deinit(allocator);
    try expectValueWrites(int_value, "[1, -2]");

    var uint_list = try std.ArrayList(u64).initCapacity(allocator, 2);
    try uint_list.appendSlice(allocator, &[_]u64{ 1, 42 });
    var uint_value = Value{ .array = .{ .uint = uint_list } };
    defer uint_value.deinit(allocator);
    try expectValueWrites(uint_value, "[1, 42]");

    var float_list = try std.ArrayList(f64).initCapacity(allocator, 2);
    try float_list.appendSlice(allocator, &[_]f64{ 1.5, -2.0 });
    var float_value = Value{ .array = .{ .float = float_list } };
    defer float_value.deinit(allocator);
    try expectValueWrites(float_value, "[1.5, -2]");

    var bool_list = try std.ArrayList(bool).initCapacity(allocator, 2);
    try bool_list.appendSlice(allocator, &[_]bool{ true, false });
    var bool_value = Value{ .array = .{ .bool = bool_list } };
    defer bool_value.deinit(allocator);
    try expectValueWrites(bool_value, "[true, false]");

    var str_list = try std.ArrayList([]const u8).initCapacity(allocator, 2);
    try str_list.appendSlice(allocator, &[_][]const u8{ "first", "second" });
    var string_value = Value{ .array = .{ .str = str_list } };
    defer string_value.deinit(allocator);
    try expectValueWrites(string_value, "[&\"first\", &\"second\"]");

    var owned_list = try std.ArrayList(String).initCapacity(allocator, 2);
    try owned_list.append(allocator, try String.fromSlice(allocator, "a,b"));
    try owned_list.append(allocator, try String.fromSlice(allocator, "c"));
    var owned_value = Value{ .array = .{ .string = owned_list } };
    defer owned_value.deinit(allocator);
    try expectValueWrites(owned_value, "[\"a,b\", \"c\"]");

    const empty_list = try std.ArrayList(i64).initCapacity(allocator, 0);
    var empty_value = Value{ .array = .{ .int = empty_list } };
    defer empty_value.deinit(allocator);
    try expectValueWrites(empty_value, "[]");
}

test "value escapes quotes and backslashes" {
    try expectValueWrites(.{ .str = "a,b[c]d\\e" }, "&\"a,b[c]d\\\\e\"");
    try expectValueWrites(.{ .str = "say \"hi\"" }, "&\"say \\\"hi\\\"\"");

    var owned = Value{ .string = try String.fromSlice(std.testing.allocator, "x,\"y\"") };
    defer owned.deinit(std.testing.allocator);
    try expectValueWrites(owned, "\"x,\\\"y\\\"\"");
}

test "attribute deinit frees an owned value" {
    var attribute = @This(){
        .key = "greeting",
        .value = .{ .string = try String.fromSlice(std.testing.allocator, "hello") },
    };
    attribute.deinit(std.testing.allocator);
}

test "from converts supported values into variants" {
    const allocator = std.testing.allocator;

    const str_value = Value.from("hi");
    try expectEqualStrings("hi", str_value.str);
    const bool_value = Value.from(true);
    try expectEqual(true, bool_value.bool);
    const uint_value = Value.from(@as(u64, 7));
    try expectEqual(7, uint_value.uint);
    try expect(!Value.isConvertible(?i32));

    var list = try Value.fromArray(allocator, &[_]i64{ 1, -2 });
    defer list.deinit(allocator);
    try expectValueWrites(list, "[1, -2]");
}

test "from converts every supported scalar" {
    const i8_value = Value.from(@as(i8, -3));
    try expectEqual(-3, i8_value.int);

    const u8_value = Value.from(@as(u8, 255));
    try expectEqual(255, u8_value.uint);

    const u64_value = Value.from(@as(u64, std.math.maxInt(u64)));
    try expectEqual(std.math.maxInt(u64), u64_value.uint);

    const comptime_value = Value.from(-5);
    try expectEqual(-5, comptime_value.int);

    const f32_value = Value.from(@as(f32, 2.5));
    try expectEqual(2.5, f32_value.float);

    const float_value = Value.from(0.25);
    try expectEqual(0.25, float_value.float);

    const bool_value = Value.from(false);
    try expectEqual(false, bool_value.bool);

    const str_value = Value.from(@as([]const u8, "x"));
    try expectEqualStrings("x", str_value.str);
}

test "appendStruct appends each struct field as an attribute" {
    const allocator = std.testing.allocator;

    var list = try std.ArrayList(@This()).initCapacity(allocator, 1);
    defer {
        for (list.items) |*attr| attr.deinit(allocator);
        list.deinit(allocator);
    }

    var num_list = try std.ArrayList(u64).initCapacity(allocator, 1);
    try num_list.append(allocator, 3);

    try appendStruct(allocator, &list, .{
        .x = 1,
        .y = @as(f64, 2.5),
        .name = "hi",
        .ids = [_]i64{ 1, 2 },
        .owned = try String.fromSlice(allocator, "owned"),
        .list = num_list,
    });

    try expectEqual(6, list.items.len);
    try expectEqualStrings("x", list.items[0].key);
    try expectEqual(1, list.items[0].value.int);
    try expectEqualStrings("owned", list.items[4].value.string.slice());
    try expectEqual(3, list.items[5].value.array.uint.items[0]);
}

test "appendStruct leaves fields to the caller when it fails" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const allocator = failing.allocator();

    var list: std.ArrayList(@This()) = .empty;
    defer list.deinit(allocator);

    const filler: [64]u8 = @splat('a');
    var owned = try String.fromSlice(std.testing.allocator, &filler);
    defer owned.deinit(std.testing.allocator);

    try expectError(error.OutOfMemory, appendStruct(allocator, &list, .{ .owned = owned }));
    try expectEqual(0, list.items.len);
}

test "appendStruct frees copies it made when a later field fails" {
    const allocator = std.testing.allocator;

    var list: std.ArrayList(@This()) = .empty;
    defer list.deinit(allocator);

    // Growing `list` and the first array copy succeed; the second copy fails.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 2 });
    try expectError(
        error.OutOfMemory,
        appendStruct(failing.allocator(), &list, .{ .a = [_]i64{ 1, 2 }, .b = [_]i64{ 3, 4 } }),
    );
    try expectEqual(0, list.items.len);
}

test "appendStruct rejects unsupported fields at compile time" {
    // Non-struct values and non-convertible field types are compile errors, e.g.:
    // _ = appendStruct(std.testing.allocator, &list, @as(i64, 1));
    // _ = appendStruct(std.testing.allocator, &list, .{ .x = null });

    try expect(!Value.isConvertible(?i32));
}

test "appendStruct builds attributes for event and link lists" {
    const allocator = std.testing.allocator;

    var event_attrs: std.ArrayList(@This()) = .empty;
    defer {
        for (event_attrs.items) |*attr| attr.deinit(allocator);
        event_attrs.deinit(allocator);
    }
    try appendStruct(allocator, &event_attrs, .{ .k = "v" });
    try expectEqual(1, event_attrs.items.len);

    var link_attrs: std.ArrayList(@This()) = .empty;
    defer link_attrs.deinit(allocator);
    try appendStruct(allocator, &link_attrs, .{ .x = @as(i64, -1) });
    try expectEqual(-1, link_attrs.items[0].value.int);
}

test "from takes ownership of a String" {
    const allocator = std.testing.allocator;

    var value = Value.from(try String.fromSlice(allocator, "a,b"));
    defer value.deinit(allocator);
    try expectValueWrites(value, "\"a,b\"");
}

test "from rejects unsupported types at compile time" {
    const Color = enum { red };

    try expect(Value.tagFor(i128) == null);
    try expect(Value.tagFor(f128) == null);
    try expect(Value.tagFor(u65) == null);
    try expect(Value.tagFor(Color) == null);
    try expect(Value.tagFor(struct { x: i32 }) == null);
    try expect(Value.tagFor([2]i64) == null);
    try expect(Value.tagFor([]u8) == null);

    // The following would fail to compile:
    // _ = Value.from(@as(i128, 1));
    // _ = Value.from(Color.red);
}

test "ArrayValue.from copies slices and arrays of each scalar type" {
    const allocator = std.testing.allocator;

    var ints = try Value.fromArray(allocator, @as([]const u64, &.{ 1, 42 }));
    defer ints.deinit(allocator);
    try expectValueWrites(ints, "[1, 42]");

    var floats = try Value.fromArray(allocator, [_]f64{ 1.5, -2.0 });
    defer floats.deinit(allocator);
    try expectValueWrites(floats, "[1.5, -2]");

    var bools = try Value.fromArray(allocator, [_]bool{ true, false });
    defer bools.deinit(allocator);
    try expectValueWrites(bools, "[true, false]");

    var strs = try Value.fromArray(allocator, [_][]const u8{ "a", "b" });
    defer strs.deinit(allocator);
    try expectValueWrites(strs, "[&\"a\", &\"b\"]");

    var bytes = try Value.fromArray(allocator, [_]u8{ 1, 2 });
    defer bytes.deinit(allocator);
    try expectValueWrites(bytes, "[1, 2]");

    var empty = try Value.fromArray(allocator, &[_]i64{});
    defer empty.deinit(allocator);
    try expectValueWrites(empty, "[]");
}

test "ArrayValue.from clones String elements" {
    const allocator = std.testing.allocator;

    var src = [_]String{try String.fromSlice(allocator, "x")};
    defer {
        for (&src) |*str| str.deinit(allocator);
    }

    var value = try Value.fromArray(allocator, &src);
    defer value.deinit(allocator);
    try expectValueWrites(value, "[\"x\"]");
}

test "ArrayValue.from takes ownership of an ArrayList" {
    const allocator = std.testing.allocator;

    var list = try std.ArrayList(i64).initCapacity(allocator, 2);
    errdefer list.deinit(allocator);
    try list.appendSlice(allocator, &[_]i64{ 3, 4 });

    var value = try Value.fromArray(allocator, list);
    defer value.deinit(allocator);
    try expectValueWrites(value, "[3, 4]");
}

test "ArrayValue.from rejects unsupported sequences at compile time" {
    try expect(!Value.isConvertible([1]?i32));
    try expect(!Value.isConvertible([1][2]i64));
    try expect(!Value.isConvertible(std.ArrayList(i128)));

    // Unsupported inputs are compile errors, e.g.:
    // _ = ArrayValue.from(std.testing.allocator, @as(i64, 1));
    // _ = ArrayValue.from(std.testing.allocator, "abc");
}
