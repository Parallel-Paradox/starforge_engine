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

    /// Whether `T` can be converted by `from` (scalars and strings) or `fromArray` (arrays).
    pub fn isConvertible(comptime T: type) bool {
        return tagFor(T) != null or ArrayValue.isConvertibleArray(T);
    }

    /// Wraps the result of `ArrayValue.from` in the `Array` variant.
    pub fn fromArray(allocator: Allocator, val: anytype) ArrayValue.ConvertError!Value {
        return .{ .Array = try ArrayValue.from(allocator, val) };
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
        const info = @typeInfo(ArrayValue).@"union";
        inline for (info.field_names, info.field_types) |field_name, field_type| {
            if (T == field_type) return @unionInit(ArrayValue, field_name, val);
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

    fn isConvertibleArray(comptime T: type) bool {
        const info = @typeInfo(ArrayValue).@"union";
        inline for (info.field_types) |field_type| {
            if (T == field_type) return true;
        }
        return isSequence(T) and Value.tagFor(T) == null and Value.tagFor(std.meta.Elem(T)) != null;
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

/// Errors produced when turning a struct of named fields into attributes.
pub const FormatError = error{
    NotStruct,
    InvalidFieldType,
};

/// Appends each field of `fields` to `list` as an attribute keyed by the field name.
/// `String` and `ArrayList` fields are moved into `list`; `[]const u8` is borrowed.
pub fn appendStruct(
    allocator: Allocator,
    list: *std.ArrayList(@This()),
    fields: anytype,
) (Allocator.Error || FormatError)!void {
    const field_info = switch (@typeInfo(@TypeOf(fields))) {
        .@"struct" => |info| info,
        else => return FormatError.NotStruct,
    };
    inline for (field_info.field_types) |field_type| {
        if (comptime !Value.isConvertible(field_type)) return FormatError.InvalidFieldType;
    }

    inline for (field_info.field_names, field_info.field_types) |field_name, field_type| {
        var value = try toValue(allocator, field_type, @field(fields, field_name));
        errdefer value.deinit(allocator);
        try list.append(allocator, .{ .key = field_name, .value = value });
    }
}

/// Converts a field already validated by `Value.isConvertible`. The conversion errors other
/// than allocation failure are unreachable for such types.
fn toValue(allocator: Allocator, comptime T: type, val: T) Allocator.Error!Value {
    if (comptime Value.tagFor(T) != null) {
        return Value.from(val) catch unreachable;
    }
    return Value.fromArray(allocator, val) catch |err| switch (err) {
        error.InvalidType => unreachable,
        error.OutOfMemory => error.OutOfMemory,
    };
}

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

    try expectEqual(@as(usize, 6), list.items.len);
    try expectEqualStrings("x", list.items[0].key);
    try expectEqual(@as(i64, 1), list.items[0].value.Int);
    try expectEqualStrings("owned", list.items[4].value.String.slice());
    try expectEqual(@as(u64, 3), list.items[5].value.Array.Uint.items[0]);
}

test "appendStruct frees a moved owned value when append fails" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const allocator = failing.allocator();

    var list: std.ArrayList(@This()) = .empty;
    defer list.deinit(allocator);

    const filler: [64]u8 = @splat('a');
    const owned = try String.fromSlice(std.testing.allocator, &filler);
    try expectError(error.OutOfMemory, appendStruct(allocator, &list, .{ .owned = owned }));
}

test "appendStruct rejects non-struct and unsupported fields" {
    const allocator = std.testing.allocator;

    var list: std.ArrayList(@This()) = .empty;
    defer list.deinit(allocator);

    try expectError(FormatError.NotStruct, appendStruct(allocator, &list, @as(i64, 1)));
    try expectError(FormatError.InvalidFieldType, appendStruct(allocator, &list, .{ .x = null }));
    try expectEqual(@as(usize, 0), list.items.len);
}

test "appendStruct builds attributes for event and link lists" {
    const allocator = std.testing.allocator;

    var event_attrs: std.ArrayList(@This()) = .empty;
    defer {
        for (event_attrs.items) |*attr| attr.deinit(allocator);
        event_attrs.deinit(allocator);
    }
    try appendStruct(allocator, &event_attrs, .{ .k = "v" });
    try expectEqual(@as(usize, 1), event_attrs.items.len);

    var link_attrs: std.ArrayList(@This()) = .empty;
    defer link_attrs.deinit(allocator);
    try appendStruct(allocator, &link_attrs, .{ .x = @as(i64, -1) });
    try expectEqual(@as(i64, -1), link_attrs.items[0].value.Int);
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
