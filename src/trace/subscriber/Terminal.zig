const std = @import("std");
const Writer = std.Io.Writer;
const Timestamp = std.Io.Timestamp;

const builtin = @import("builtin");

const engine = @import("engine");
const Trace = engine.trace.Trace;
const Span = engine.trace.Span;
const Event = engine.trace.Event;
const Attribute = engine.trace.Attribute;
const Subscriber = engine.trace.Subscriber;

const base = engine.base;
const EpochTime = base.EpochTime;

level_mask: LevelMask,

pub const LevelMask = packed struct(u8) {
    trace: bool = false,
    debug: bool = switch (builtin.mode) {
        .debug => true,
        else => false,
    },
    info: bool = switch (builtin.mode) {
        .debug, .safe => true,
        else => false,
    },
    warn: bool = true,
    err: bool = true,
    fatal: bool = true,
    _reserved: u2 = 0,

    pub const all: LevelMask = @bitCast(@as(u8, std.math.maxInt(u8)));
    pub const none: LevelMask = @bitCast(@as(u8, 0));

    pub fn filter(self: LevelMask, level: Event.Level) bool {
        return switch (level) {
            .trace => self.trace,
            .debug => self.debug,
            .info => self.info,
            .warn => self.warn,
            .err => self.err,
            .fatal => self.fatal,
        };
    }
};

/// Returns a `Subscriber` backed by this instance; `self` must outlive it.
pub fn subscriber(self: *@This()) Subscriber {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable: Subscriber.VTable = .{
    .spanStarted = spanStarted,
    .spanEmitted = spanEmitted,
    .eventEmitted = eventEmitted,
};

fn this(ptr: *anyopaque) *@This() {
    return @ptrCast(@alignCast(ptr));
}

/// ┌ YYYY-MM-DD HH:MM:SS trace_id-span_id < parent_id kind name
fn spanStarted(_: *anyopaque, span: Span) void {
    const tracer = span.trace.tracer orelse return;
    const io = tracer.getIo();

    // prepare stderr writer
    var buffer: [64]u8 = undefined;
    const stderr = io.lockStderr(&buffer, null) catch return;
    defer io.unlockStderr();
    const terminal = stderr.terminal();
    const writer = terminal.writer;

    const begin = span.real_dur.begin orelse return;

    // ┌ YYYY-MM-DD HH:MM:SS trace_id-span_id < parent_id
    terminal.setColor(.dim) catch {};
    writer.writeAll("┌ ") catch {};
    writeSpanPrefix(writer, span, begin);
    terminal.setColor(.reset) catch {};

    // kind name
    writer.print(" {s} {s}\n", .{ span.kind.toStr(), span.name }) catch {};
}

/// └ YYYY-MM-DD HH:MM:SS trace_id-span_id < parent_id status name duration
///   attributes
///   -> trace_id span_id attributes
fn spanEmitted(_: *anyopaque, span: Span) void {
    const tracer = span.trace.tracer orelse return;
    const io = tracer.getIo();

    // prepare stderr writer
    var buffer: [64]u8 = undefined;
    const stderr = io.lockStderr(&buffer, null) catch return;
    defer io.unlockStderr();
    const terminal = stderr.terminal();
    const writer = terminal.writer;

    const begin = span.real_dur.begin orelse return;

    // └ YYYY-MM-DD HH:MM:SS trace_id span_id < parent_id
    terminal.setColor(.dim) catch {};
    writer.writeAll("└ ") catch {};
    writeSpanPrefix(writer, span, begin);
    terminal.setColor(.reset) catch {};

    // status name duration
    writer.writeByte(' ') catch {};
    terminal.setColor(switch (span.status) {
        .unset => .dim,
        .ok => .green,
        .err => .red,
    }) catch {};
    writer.print("{s}", .{span.status.toStr()}) catch {};
    terminal.setColor(.reset) catch {};
    writer.print(" {s} ", .{span.name}) catch {};
    terminal.setColor(.dim) catch {};
    writeDur(writer, spanDurationMs(span));
    terminal.setColor(.reset) catch {};
    writer.writeByte('\n') catch {};

    // attributes
    if (span.attrs.items.len > 0) {
        writer.writeAll("  ") catch {};
        writeAttributes(writer, span.attrs.items);
        writer.writeByte('\n') catch {};
    }

    // -> trace_id span_id attributes
    terminal.setColor(.dim) catch {};
    for (span.links.items) |link| {
        var id_buffer: [13]u8 = undefined;
        const join_id = joinId(&id_buffer, link.trace_id, link.span_id);
        writer.writeAll("  ->") catch {};
        if (join_id.len > 0) {
            writer.print(" {s}", .{join_id}) catch {};
        }
        if (link.attrs.items.len > 0) {
            writer.writeAll(" ") catch {};
            writeAttributes(writer, link.attrs.items);
        }
        writer.writeByte('\n') catch {};
    }
    terminal.setColor(.reset) catch {};
}

/// Writes `YYYY-MM-DD HH:MM:SS[ trace_id-span_id][ < parent_id]` without colors,
/// omitting invalid IDs and their separators.
fn writeSpanPrefix(writer: *Writer, span: Span, begin: Timestamp) void {
    const utc_time = EpochTime.fromUnixTimestamp(begin);
    const epoch_time = (utc_time.toLocal() catch utc_time).toStr();
    var id_buffer: [13]u8 = undefined;
    const join_id = joinId(&id_buffer, span.trace.id, span.id);
    writer.print("{s}", .{epoch_time}) catch {};
    if (join_id.len > 0) {
        writer.print(" {s}", .{join_id}) catch {};
    }
    if (span.parent_id) |parent| {
        if (shortSpanId(parent)) |short_id| {
            writer.print(" < {s}", .{short_id}) catch {};
        }
    }
}

/// Returns the first 16 bits of a valid span id as 4 hex digits, or null.
fn shortSpanId(span_id: Span.Id) ?[4]u8 {
    const id = span_id.tryGet() orelse return null;
    const s: u16 = @truncate(id >> 48);
    var buf: [4]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{x:0>4}", .{s}) catch unreachable;
    return buf;
}

/// Duration of the span measured with the awake clock, in milliseconds.
fn spanDurationMs(span: Span) i96 {
    const begin = span.awake_dur.begin orelse return 0;
    const end = span.awake_dur.end orelse return 0;
    return @divTrunc(begin.durationTo(end).toNanoseconds(), std.time.ns_per_ms);
}

/// HH:MM:SS trace_id-span_id ● level name attributes
fn eventEmitted(ptr: *anyopaque, event: Event) void {
    const self = this(ptr);

    if (!self.level_mask.filter(event.level)) {
        return;
    }

    const tracer = event.trace.tracer orelse return;
    const io = tracer.getIo();

    // prepare stderr writer
    var buffer: [64]u8 = undefined;
    const stderr = io.lockStderr(&buffer, null) catch return;
    defer io.unlockStderr();
    const terminal = stderr.terminal();
    const writer = terminal.writer;

    // HH:MM:SS trace_id-span_id
    terminal.setColor(.dim) catch {};
    const utc_time = EpochTime.fromUnixTimestamp(event.real_ts);
    const epoch_time = (utc_time.toLocal() catch utc_time).toClockStr();
    var id_buffer: [13]u8 = undefined;
    const join_id = joinId(&id_buffer, event.trace.id, event.span_id);
    writer.print("{s}", .{epoch_time}) catch {};
    if (join_id.len > 0) {
        writer.print(" {s}", .{join_id}) catch {};
    }
    terminal.setColor(.reset) catch {};

    // level
    terminal.setColor(switch (event.level) {
        .trace => .dim,
        .debug => .reset,
        .info => .green,
        .warn => .yellow,
        .err => .red,
        .fatal => .bright_red,
    }) catch {};
    if (event.level == .fatal) {
        terminal.setColor(.bold) catch {};
    }
    writer.print(" ● {s:<5}", .{event.level.toStr()}) catch {};
    terminal.setColor(.reset) catch {};

    if (event.level == .trace) {
        terminal.setColor(.dim) catch {};
    }

    // name
    writer.print(" {s} ", .{event.name}) catch {};

    // attributes
    if (event.attrs.items.len > 0) {
        writeAttributes(writer, event.attrs.items);
    }
    writer.writeByte('\n') catch {};
    terminal.setColor(.reset) catch {};
}

/// Joins 32 bits of the trace id starting at `rand_a` (bit 64, so the low 16 bits of
/// `unix_ts_ms` are included) with the first 16 bits of the span id.
/// Invalid IDs are omitted; the hyphen is written only when both IDs are valid.
/// The returned slice borrows buf.
fn joinId(buf: *[13]u8, trace_id: Trace.Id, span_id: Span.Id) []const u8 {
    if (trace_id.tryGet()) |trace_id_value| {
        const t: u32 = @truncate(trace_id_value >> 64);
        if (span_id.tryGet()) |span_id_value| {
            const s: u16 = @truncate(span_id_value >> 48);
            return std.fmt.bufPrint(buf, "{x:0>8}-{x:0>4}", .{ t, s }) catch unreachable;
        }
        return std.fmt.bufPrint(buf, "{x:0>8}", .{t}) catch unreachable;
    }
    if (span_id.tryGet()) |span_id_value| {
        const s: u16 = @truncate(span_id_value >> 48);
        return std.fmt.bufPrint(buf, "{x:0>4}", .{s}) catch unreachable;
    }
    return buf[0..0];
}

/// Format a duration in milliseconds as the largest applicable unit cascade:
/// `{ms}ms`, `{s}s{ms}ms`, `{m}m{s}s{ms}ms`, `{h}h{m}m{s}s{ms}ms`, `{d}d{h}h{m}m{s}s{ms}ms`.
/// Days are the largest unit; no carry happens beyond days.
fn writeDur(writer: *Writer, dur_ms: anytype) void {
    const s_ms = 1000;
    const m_ms = 60 * s_ms;
    const h_ms = 60 * m_ms;
    const d_ms = 24 * h_ms;

    var remaining = dur_ms;
    const d = @divFloor(remaining, d_ms);
    remaining = @mod(remaining, d_ms);
    const h = @divFloor(remaining, h_ms);
    remaining = @mod(remaining, h_ms);
    const m = @divFloor(remaining, m_ms);
    remaining = @mod(remaining, m_ms);
    const s = @divFloor(remaining, s_ms);
    const ms = @mod(remaining, s_ms);

    if (d > 0) {
        writer.print("{d}d{d}h{d}m{d}s{d}ms", .{ d, h, m, s, ms }) catch {};
    } else if (h > 0) {
        writer.print("{d}h{d}m{d}s{d}ms", .{ h, m, s, ms }) catch {};
    } else if (m > 0) {
        writer.print("{d}m{d}s{d}ms", .{ m, s, ms }) catch {};
    } else if (s > 0) {
        writer.print("{d}s{d}ms", .{ s, ms }) catch {};
    } else {
        writer.print("{d}ms", .{ms}) catch {};
    }
}

fn writeAttributes(writer: *Writer, attrs: []const Attribute) void {
    writer.writeAll("{ ") catch {};
    for (attrs, 0..) |attr, i| {
        if (i != 0) writer.writeAll(", ") catch {};
        writer.writeAll(attr.key) catch {};
        writer.writeAll(": ") catch {};
        attr.value.writeTo(writer) catch {};
    }
    writer.writeAll(" }") catch {};
}

const expectEqualStrings = std.testing.expectEqualStrings;

test "joinId takes 32 bits from rand_a upward and 16 bits of span id" {
    const trace_id = Trace.Id.from(0x01234567_89abcdef_fedcba98_76543210);
    const span_id = Span.Id.from(0x00ff_aabb_ccdd_eeff);
    var buffer: [13]u8 = undefined;
    const joined = joinId(&buffer, trace_id, span_id);
    try expectEqualStrings("89abcdef-00ff", joined);
}

test "joinId omits invalid IDs and unnecessary separators" {
    const cases = [_]struct {
        trace_id: Trace.Id,
        span_id: Span.Id,
        expected: []const u8,
    }{
        .{ .trace_id = .invalid, .span_id = .invalid, .expected = "" },
        .{
            .trace_id = Trace.Id.from(0x01234567_89abcdef_fedcba98_76543210),
            .span_id = .invalid,
            .expected = "89abcdef",
        },
        .{
            .trace_id = .invalid,
            .span_id = Span.Id.from(0x00ff_aabb_ccdd_eeff),
            .expected = "00ff",
        },
        .{
            .trace_id = Trace.Id.from(1),
            .span_id = Span.Id.from(1),
            .expected = "00000000-0000",
        },
    };
    for (cases) |case| {
        var buffer: [13]u8 = undefined;
        try expectEqualStrings(case.expected, joinId(&buffer, case.trace_id, case.span_id));
    }
}

test "shortSpanId omits invalid IDs" {
    try std.testing.expect(shortSpanId(.invalid) == null);
    const short_id = shortSpanId(Span.Id.from(0x00ff_aabb_ccdd_eeff)).?;
    try expectEqualStrings("00ff", &short_id);
}

test "writeSpanPrefix uses local time and omits invalid IDs without extra separators" {
    var default = engine.trace.Tracer.Default.init(std.testing.allocator, std.testing.io);
    defer default.deinit();
    const t = default.tracer();
    var span = t.initSpan(t.initTrace(), .{ .name = "test" });
    defer span.deinit();
    span.trace.id = .invalid;
    span.id = .invalid;
    span.parent_id = .invalid;

    var output = Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    const begin = Timestamp.fromNanoseconds(1_704_164_645 * std.time.ns_per_s);
    writeSpanPrefix(&output.writer, span, begin);
    const utc_time = EpochTime.fromUnixTimestamp(begin);
    const expected = (utc_time.toLocal() catch utc_time).toStr();
    try expectEqualStrings(&expected, output.written());
}
