//! Default tracer implementation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const root = @import("../mod.zig");
const base = root.base;
const Tracer = root.Tracer;
const Trace = root.Trace;
const Span = root.Span;
const Event = root.Event;
const Subscriber = root.Subscriber;
const Attribute = root.Attribute;
const SubscriberList = Tracer.SubscriberList;
const ResourceList = Tracer.ResourceList;

allocator: Allocator,
io: Io,
subscribers: SubscriberList = .{ .inner = .empty },
resources: ResourceList = .{ .inner = .empty },

pub fn init(allocator: Allocator, io: Io) @This() {
    return .{ .allocator = allocator, .io = io };
}

pub fn deinit(self: *@This()) void {
    self.resources.deinit(self.allocator);
    self.subscribers.deinit(self.allocator);
}

/// Returns a `Tracer` backed by this instance; `self` must outlive it.
pub fn tracer(self: *@This()) Tracer {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable: Tracer.VTable = .{
    .initTrace = initTrace,
    .initSpan = initSpan,
    .initEvent = initEvent,
    .getAllocator = getAllocator,
    .getIo = getIo,
    .listSubscribers = listSubscribers,
    .listResources = listResources,
};

fn this(ptr: *anyopaque) *@This() {
    return @ptrCast(@alignCast(ptr));
}

fn initTrace(ptr: *anyopaque) Trace {
    const self = this(ptr);
    const id: u128 = if (base.Uuid.V7.init(.{ .io = self.io })) |v7|
        v7.toU128()
    else |_|
        base.Uuid.V4.init(.{ .io = self.io }).toU128();
    return .{
        .tracer = self.tracer(),
        .id = @enumFromInt(id),
        .flag = .{ .sampled = true },
    };
}

fn initSpan(ptr: *anyopaque, trace: Trace) Span {
    const self = this(ptr);
    const rand_src = base.random.IoSource{ .io = self.io };
    // Force the low bit so the id is never `Span.Id.invalid` (0).
    const id = rand_src.interface().int(u64) | 1;
    return .{
        .trace = trace,
        .id = @enumFromInt(id),
        .kind = .internal,
        .name = "",
        .real_dur = .{},
        .awake_dur = .{},
    };
}

fn initEvent(ptr: *anyopaque, span: Span) Event {
    const self = this(ptr);
    return .{
        .trace = span.trace,
        .span_id = span.id,
        .level = .info,
        .name = "",
        .real_ts = Io.Clock.real.now(self.io),
    };
}

fn getAllocator(ptr: *anyopaque) Allocator {
    return this(ptr).allocator;
}

fn getIo(ptr: *anyopaque) Io {
    return this(ptr).io;
}

fn listSubscribers(ptr: *anyopaque) *SubscriberList {
    return &this(ptr).subscribers;
}

fn listResources(ptr: *anyopaque) *ResourceList {
    return &this(ptr).resources;
}

test "span ids are never invalid" {
    var default = Tracer.Default.init(std.testing.allocator, std.testing.io);
    defer default.deinit();

    const t = default.tracer();
    for (0..64) |_| {
        const span = t.initSpan(t.initTrace());
        try std.testing.expect(span.id.tryGet() != null);
        try std.testing.expectEqual(@as(u64, 1), span.id.get() & 1);
    }
}

test "trace ids use UUID v7 version bits" {
    var default = Tracer.Default.init(std.testing.allocator, std.testing.io);
    defer default.deinit();

    const trace = default.tracer().initTrace();
    try std.testing.expect(trace.id.tryGet() != null);
    const uuid: base.Uuid = @bitCast(trace.id.get());
    try std.testing.expectEqual(base.Uuid.Version.v7, uuid.ver);
}
