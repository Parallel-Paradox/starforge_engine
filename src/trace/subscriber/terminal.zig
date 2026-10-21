const std = @import("std");
const Writer = std.Io.Writer;
const Timestamp = std.Io.Timestamp;

const builtin = @import("builtin");

const root = @import("../mod.zig");
const Trace = root.Trace;
const Span = root.Span;
const Event = root.Event;
const Attribute = root.Attribute;
const Subscriber = root.Subscriber;

const base = root.base;
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
    const io = span.trace.tracer.getIo();

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
    const io = span.trace.tracer.getIo();

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
        writer.print("  -> {s}", .{joinId(link.trace_id, link.span_id)}) catch {};
        if (link.attrs.items.len > 0) {
            writer.writeAll(" ") catch {};
            writeAttributes(writer, link.attrs.items);
        }
        writer.writeByte('\n') catch {};
    }
    terminal.setColor(.reset) catch {};
}

/// Writes `YYYY-MM-DD HH:MM:SS trace_id span_id[ < parent_id]` without colors.
fn writeSpanPrefix(writer: *Writer, span: Span, begin: Timestamp) void {
    const epoch_time = EpochTime.fromUnixTimestamp(begin).toStr();
    const join_id = joinId(span.trace.id, span.id);
    writer.print("{s} {s}", .{ epoch_time, join_id }) catch {};
    if (span.parent_id) |parent| {
        writer.print(" < {s}", .{shortSpanId(parent)}) catch {};
    }
}

/// Returns the first 16 bits of the span id as 4 hex digits.
fn shortSpanId(span_id: Span.Id) [4]u8 {
    const s: u16 = @truncate(span_id.get() >> 48);
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

    const tracer = event.trace.tracer;
    const io = tracer.getIo();

    // prepare stderr writer
    var buffer: [64]u8 = undefined;
    const stderr = io.lockStderr(&buffer, null) catch return;
    defer io.unlockStderr();
    const terminal = stderr.terminal();
    const writer = terminal.writer;

    // HH:MM:SS trace_id-span_id
    terminal.setColor(.dim) catch {};
    const epoch_time = EpochTime.fromUnixTimestamp(event.real_ts).toClockStr();
    const join_id = joinId(event.trace.id, event.span_id);
    writer.print("{s} {s}", .{ epoch_time, join_id }) catch {};
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
fn joinId(trace_id: Trace.Id, span_id: Span.Id) [13]u8 {
    const t: u32 = @truncate(trace_id.get() >> 64);
    const s: u16 = @truncate(span_id.get() >> 48);
    var buf: [13]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{x:0>8}-{x:0>4}", .{ t, s }) catch unreachable;
    return buf;
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
    const joined = joinId(trace_id, span_id);
    try expectEqualStrings("89abcdef-00ff", &joined);
}
