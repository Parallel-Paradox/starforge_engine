//! A key-value pair that can be attached to a trace event or span.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const root = @import("mod.zig");
const String = root.base.String;

key: []const u8,
value: Value,

pub fn deinit(self: *@This(), allocator: Allocator) void {
    self.value.deinit(allocator);
}

pub const Value = union(enum) {
    Str: []const u8,
    String: String,
    Int: i64,
    Uint: u64,
    Float: f64,
    Bool: bool,
    Array: ArrayValue,

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        switch (self.*) {
            .String => |*str| str.deinit(allocator),
            .Array => |*array| array.deinit(allocator),
            else => {},
        }
    }

    pub const ConvertError = error{InvalidType};

    /// Returns the variant that a value of type `T` converts to, or `null` if unsupported.
    /// Const byte slices map to `Str`, and `String` maps to `String`.
    pub fn tagFor(comptime T: type) ?std.meta.FieldEnum(Value) {
        if (T == String) return .String;
        return switch (@typeInfo(T)) {
            .bool => .Bool,
            .int => |int| if (int.bits > 64) null else switch (int.signedness) {
                .signed => .Int,
                .unsigned => .Uint,
            },
            .comptime_int => .Int,
            .float => |float| if (float.bits > 64) null else .Float,
            .comptime_float => .Float,
            .pointer => |ptr| if (isConstByteString(ptr)) .Str else null,
            else => null,
        };
    }

    /// The payload element type of the array variant `tag`.
    pub fn ElemOf(comptime tag: std.meta.FieldEnum(Value)) type {
        return switch (tag) {
            .Str => []const u8,
            .String => String,
            .Int => i64,
            .Uint => u64,
            .Float => f64,
            .Bool => bool,
            else => unreachable,
        };
    }

    /// Converts a scalar or string `val` into a `Value`. Const byte slices become `Str` (borrowed).
    /// Arrays are not handled here; use `ArrayValue.from` for them.
    pub fn from(val: anytype) ConvertError!Value {
        if (comptime tagFor(@TypeOf(val)) == null) return ConvertError.InvalidType;
        const tag = comptime tagFor(@TypeOf(val)).?;
        return @unionInit(Value, @tagName(tag), val);
    }

    /// Wraps the result of `ArrayValue.from` in the `Array` variant.
    pub fn fromArray(allocator: Allocator, val: anytype) ArrayValue.ConvertError!Value {
        return .{ .Array = try ArrayValue.from(allocator, val) };
    }

    fn isConstByteString(comptime ptr: std.builtin.Type.Pointer) bool {
        if (!ptr.is_const) return false;
        if (ptr.size == .slice) return ptr.child == u8;
        if (ptr.size == .one) switch (@typeInfo(ptr.child)) {
            .array => |arr| return arr.child == u8,
            else => {},
        };
        return false;
    }

    pub fn writeTo(self: @This(), writer: *Writer) Writer.Error!void {
        switch (self) {
            .Str => |str| {
                try writer.writeAll("&\"");
                try writeEscaped(writer, str);
                try writer.writeByte('"');
            },
            .String => |str| {
                try writer.writeByte('"');
                try writeEscaped(writer, str.slice());
                try writer.writeByte('"');
            },
            .Bool => |b| try writer.writeAll(if (b) "true" else "false"),
            .Array => |array| try array.writeTo(writer),
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
    Str: std.ArrayList([]const u8),
    String: std.ArrayList(String),
    Int: std.ArrayList(i64),
    Uint: std.ArrayList(u64),
    Float: std.ArrayList(f64),
    Bool: std.ArrayList(bool),

    pub const ConvertError = Value.ConvertError || Allocator.Error;

    /// Takes ownership of an `ArrayList` whose element type matches a variant, or copies the
    /// elements of a slice or array (`String` elements are cloned, `[]const u8` elements are
    /// borrowed and must outlive the returned value). The caller must not deinit a list
    /// passed in by value.
    pub fn from(allocator: Allocator, val: anytype) ConvertError!ArrayValue {
        const T = @TypeOf(val);
        inline for (@typeInfo(ArrayValue).@"union".fields) |field| {
            if (T == field.type) return @unionInit(ArrayValue, field.name, val);
        }

        if (comptime !isSequence(T) or Value.tagFor(T) != null) return ConvertError.InvalidType;
        const E = std.meta.Elem(T);
        if (comptime Value.tagFor(E) == null) return ConvertError.InvalidType;
        const tag = comptime Value.tagFor(E).?;

        var list = try std.ArrayList(Value.ElemOf(tag)).initCapacity(allocator, val.len);
        errdefer {
            if (comptime tag == .String) for (list.items) |*str| str.deinit(allocator);
            list.deinit(allocator);
        }
        for (val) |item| list.appendAssumeCapacity(try convertElem(tag, allocator, item));
        return @unionInit(ArrayValue, @tagName(tag), list);
    }

    fn convertElem(
        comptime tag: std.meta.FieldEnum(Value),
        allocator: Allocator,
        item: anytype,
    ) Allocator.Error!Value.ElemOf(tag) {
        return switch (tag) {
            .String => try String.fromSlice(allocator, item.slice()),
            else => @as(Value.ElemOf(tag), item),
        };
    }

    fn isSequence(comptime T: type) bool {
        return switch (@typeInfo(T)) {
            .array => true,
            .pointer => |ptr| ptr.size == .slice or
                (ptr.size == .one and @typeInfo(ptr.child) == .array),
            else => false,
        };
    }

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        switch (self.*) {
            .String => |*string_list| {
                for (string_list.items) |*str| str.deinit(allocator);
                string_list.deinit(allocator);
            },
            inline else => |*list| list.deinit(allocator),
        }
    }

    pub fn writeTo(self: @This(), writer: *Writer) Writer.Error!void {
        switch (self) {
            .Str => |list| try writeList(writer, list.items, .Str),
            .String => |list| try writeList(writer, list.items, .String),
            .Int => |list| try writeList(writer, list.items, .Int),
            .Uint => |list| try writeList(writer, list.items, .Uint),
            .Float => |list| try writeList(writer, list.items, .Float),
            .Bool => |list| try writeList(writer, list.items, .Bool),
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

const expectEqualStrings = std.testing.expectEqualStrings;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

fn expectValueWrites(value: Value, expected: []const u8) !void {
    var output = Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try value.writeTo(&output.writer);
    try expectEqualStrings(expected, output.written());
}

test "value writes scalar values" {
    try expectValueWrites(.{ .Str = "hello" }, "&\"hello\"");
    try expectValueWrites(.{ .Bool = true }, "true");
    try expectValueWrites(.{ .Bool = false }, "false");
    try expectValueWrites(.{ .Int = -42 }, "-42");
    try expectValueWrites(.{ .Uint = 42 }, "42");
    try expectValueWrites(.{ .Float = 3.5 }, "3.5");
}

test "value writes an owned string" {
    var value = Value{ .String = try String.fromSlice(std.testing.allocator, "owned string") };
    defer value.deinit(std.testing.allocator);

    try expectValueWrites(value, "\"owned string\"");
}

test "value writes arrays" {
    const allocator = std.testing.allocator;

    var int_list = try std.ArrayList(i64).initCapacity(allocator, 2);
    try int_list.appendSlice(allocator, &[_]i64{ 1, -2 });
    var int_value = Value{ .Array = .{ .Int = int_list } };
    defer int_value.deinit(allocator);
    try expectValueWrites(int_value, "[1, -2]");

    var uint_list = try std.ArrayList(u64).initCapacity(allocator, 2);
    try uint_list.appendSlice(allocator, &[_]u64{ 1, 42 });
    var uint_value = Value{ .Array = .{ .Uint = uint_list } };
    defer uint_value.deinit(allocator);
    try expectValueWrites(uint_value, "[1, 42]");

    var float_list = try std.ArrayList(f64).initCapacity(allocator, 2);
    try float_list.appendSlice(allocator, &[_]f64{ 1.5, -2.0 });
    var float_value = Value{ .Array = .{ .Float = float_list } };
    defer float_value.deinit(allocator);
    try expectValueWrites(float_value, "[1.5, -2]");

    var bool_list = try std.ArrayList(bool).initCapacity(allocator, 2);
    try bool_list.appendSlice(allocator, &[_]bool{ true, false });
    var bool_value = Value{ .Array = .{ .Bool = bool_list } };
    defer bool_value.deinit(allocator);
    try expectValueWrites(bool_value, "[true, false]");

    var str_list = try std.ArrayList([]const u8).initCapacity(allocator, 2);
    try str_list.appendSlice(allocator, &[_][]const u8{ "first", "second" });
    var string_value = Value{ .Array = .{ .Str = str_list } };
    defer string_value.deinit(allocator);
    try expectValueWrites(string_value, "[&\"first\", &\"second\"]");

    var owned_list = try std.ArrayList(String).initCapacity(allocator, 2);
    try owned_list.append(allocator, try String.fromSlice(allocator, "a,b"));
    try owned_list.append(allocator, try String.fromSlice(allocator, "c"));
    var owned_value = Value{ .Array = .{ .String = owned_list } };
    defer owned_value.deinit(allocator);
    try expectValueWrites(owned_value, "[\"a,b\", \"c\"]");

    const empty_list = try std.ArrayList(i64).initCapacity(allocator, 0);
    var empty_value = Value{ .Array = .{ .Int = empty_list } };
    defer empty_value.deinit(allocator);
    try expectValueWrites(empty_value, "[]");
}

test "value escapes quotes and backslashes" {
    try expectValueWrites(.{ .Str = "a,b[c]d\\e" }, "&\"a,b[c]d\\\\e\"");
    try expectValueWrites(.{ .Str = "say \"hi\"" }, "&\"say \\\"hi\\\"\"");

    var owned = Value{ .String = try String.fromSlice(std.testing.allocator, "x,\"y\"") };
    defer owned.deinit(std.testing.allocator);
    try expectValueWrites(owned, "\"x,\\\"y\\\"\"");
}

test "attribute deinit frees an owned value" {
    var attribute = @This(){
        .key = "greeting",
        .value = .{ .String = try String.fromSlice(std.testing.allocator, "hello") },
    };
    attribute.deinit(std.testing.allocator);
}

test "from converts supported values into variants" {
    const allocator = std.testing.allocator;

    const str_value = try Value.from("hi");
    try expectEqualStrings("hi", str_value.Str);
    const bool_value = try Value.from(true);
    try expectEqual(true, bool_value.Bool);
    const uint_value = try Value.from(@as(u64, 7));
    try expectEqual(@as(u64, 7), uint_value.Uint);
    try expectError(error.InvalidType, Value.from(@as(?i32, null)));

    var list = try Value.fromArray(allocator, &[_]i64{ 1, -2 });
    defer list.deinit(allocator);
    try expectValueWrites(list, "[1, -2]");
}

test "from converts every supported scalar" {
    const i8_value = try Value.from(@as(i8, -3));
    try expectEqual(@as(i64, -3), i8_value.Int);

    const u8_value = try Value.from(@as(u8, 255));
    try expectEqual(@as(u64, 255), u8_value.Uint);

    const u64_value = try Value.from(@as(u64, std.math.maxInt(u64)));
    try expectEqual(@as(u64, std.math.maxInt(u64)), u64_value.Uint);

    const comptime_value = try Value.from(-5);
    try expectEqual(@as(i64, -5), comptime_value.Int);

    const f32_value = try Value.from(@as(f32, 2.5));
    try expectEqual(@as(f64, 2.5), f32_value.Float);

    const float_value = try Value.from(0.25);
    try expectEqual(@as(f64, 0.25), float_value.Float);

    const bool_value = try Value.from(false);
    try expectEqual(false, bool_value.Bool);

    const str_value = try Value.from(@as([]const u8, "x"));
    try expectEqualStrings("x", str_value.Str);
}

test "from takes ownership of a String" {
    const allocator = std.testing.allocator;

    var value = try Value.from(try String.fromSlice(allocator, "a,b"));
    defer value.deinit(allocator);
    try expectValueWrites(value, "\"a,b\"");
}

test "from rejects unsupported types" {
    const Color = enum { red };

    try expectError(error.InvalidType, Value.from(@as(i128, 1)));
    try expectError(error.InvalidType, Value.from(@as(f128, 1.0)));
    try expectError(error.InvalidType, Value.from(@as(u65, 1)));
    try expectError(error.InvalidType, Value.from(Color.red));
    try expectError(error.InvalidType, Value.from(.{ .x = 1 }));
    try expectError(error.InvalidType, Value.from([_]i64{ 1, 2 }));

    var buf = [_]u8{'a'};
    try expectError(error.InvalidType, Value.from(@as([]u8, &buf)));
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
    try list.appendSlice(allocator, &[_]i64{ 3, 4 });

    var value = try Value.fromArray(allocator, list);
    defer value.deinit(allocator);
    try expectValueWrites(value, "[3, 4]");
}

test "ArrayValue.from rejects unsupported sequences" {
    const allocator = std.testing.allocator;

    try expectError(error.InvalidType, ArrayValue.from(allocator, @as(i64, 1)));
    try expectError(error.InvalidType, ArrayValue.from(allocator, [_]?i32{null}));
    try expectError(error.InvalidType, ArrayValue.from(allocator, [_][2]i64{.{ 1, 2 }}));
    try expectError(error.InvalidType, ArrayValue.from(allocator, "abc"));
    try expectError(
        error.InvalidType,
        ArrayValue.from(allocator, std.ArrayList(i128).empty),
    );
}
