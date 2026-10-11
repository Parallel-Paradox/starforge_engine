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
