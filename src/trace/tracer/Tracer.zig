//! Tracer can be used to create traces and register subscribers.

pub const Default = @import("Default.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const engine = @import("engine");
const Subscriber = engine.trace.Subscriber;
const Trace = engine.trace.Trace;
const Span = engine.trace.Span;
const Event = engine.trace.Event;
const Attribute = engine.trace.Attribute;

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    initTrace: *const fn (self: *anyopaque) Trace,
    initSpan: *const fn (self: *anyopaque, trace: Trace, options: Span.Options) Span,
    initEvent: *const fn (self: *anyopaque, span: Span, options: Event.Options) Event,

    getAllocator: *const fn (self: *anyopaque) Allocator,
    getIo: *const fn (self: *anyopaque) Io,

    listSubscribers: *const fn (self: *anyopaque) *SubscriberList,
    listResources: *const fn (self: *anyopaque) *ResourceList,
};

pub const SubscriberList = struct {
    inner: std.ArrayList(Subscriber),

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        self.inner.deinit(allocator);
    }

    pub fn subscribe(
        self: *@This(),
        allocator: Allocator,
        subscriber: Subscriber,
    ) Allocator.Error!void {
        for (self.inner.items) |item| {
            if (std.meta.eql(item, subscriber)) return;
        }
        try self.inner.append(allocator, subscriber);
    }

    pub fn unsubscribe(self: *@This(), subscriber: Subscriber) void {
        for (self.inner.items, 0..) |item, i| {
            if (std.meta.eql(item, subscriber)) {
                _ = self.inner.swapRemove(i);
                return;
            }
        }
    }
};

/// Resource attributes attached to every trace produced by this tracer.
pub const ResourceList = struct {
    inner: std.ArrayList(Attribute),

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        for (self.inner.items) |*attr| attr.deinit(allocator);
        self.inner.deinit(allocator);
    }

    /// Returns the index of the resource with the given key, or null if absent.
    pub fn tryGetResId(self: *const @This(), key: []const u8) ?usize {
        for (self.inner.items, 0..) |item, i| {
            if (std.mem.eql(u8, item.key, key)) return i;
        }
        return null;
    }

    /// Adds a resource, or replaces the existing one with the same key.
    pub fn set(self: *@This(), allocator: Allocator, resource: Attribute) Allocator.Error!void {
        if (self.tryGetResId(resource.key)) |index| {
            const old = &self.inner.items[index];
            old.deinit(allocator);
            old.* = resource;
            return;
        }
        try self.inner.append(allocator, resource);
    }

    /// Removes the resource with the given key; does nothing if absent.
    pub fn unset(self: *@This(), allocator: Allocator, key: []const u8) void {
        const index = self.tryGetResId(key) orelse return;
        self.inner.items[index].deinit(allocator);
        _ = self.inner.swapRemove(index);
    }
};

/// Creates a new trace.
pub fn initTrace(self: @This()) Trace {
    return self.vtable.initTrace(self.ptr);
}

/// Creates a new span within the given trace.
pub fn initSpan(self: @This(), trace: Trace, options: Span.Options) Span {
    return self.vtable.initSpan(self.ptr, trace, options);
}

/// Creates a new event attached to the given span.
pub fn initEvent(self: @This(), span: Span, options: Event.Options) Event {
    return self.vtable.initEvent(self.ptr, span, options);
}

/// Returns the allocator used by this tracer.
pub fn getAllocator(self: @This()) Allocator {
    return self.vtable.getAllocator(self.ptr);
}

/// Returns the `Io` instance used by this tracer.
pub fn getIo(self: @This()) Io {
    return self.vtable.getIo(self.ptr);
}

/// Registers a subscriber, ignoring it if it is already registered.
pub fn subscribe(self: @This(), subscriber: Subscriber) Allocator.Error!void {
    return self.vtable.listSubscribers(self.ptr).subscribe(self.getAllocator(), subscriber);
}

/// Removes a registered subscriber; does nothing if it is not registered.
pub fn unsubscribe(self: @This(), subscriber: Subscriber) void {
    self.vtable.listSubscribers(self.ptr).unsubscribe(subscriber);
}

/// Returns all registered subscribers.
pub fn listSubscribers(self: @This()) []const Subscriber {
    return self.vtable.listSubscribers(self.ptr).inner.items;
}

/// Notifies every registered subscriber that a span has started.
pub fn startSpan(self: @This(), span: Span) void {
    for (self.listSubscribers()) |subscriber| {
        subscriber.spanStarted(span);
    }
}

/// Delivers a span to every registered subscriber.
pub fn emitSpan(self: @This(), span: Span) void {
    for (self.listSubscribers()) |subscriber| {
        subscriber.spanEmitted(span);
    }
}

/// Delivers an event to every registered subscriber.
pub fn emitEvent(self: @This(), event: Event) void {
    for (self.listSubscribers()) |subscriber| {
        subscriber.eventEmitted(event);
    }
}

/// Adds a resource, or replaces the existing one with the same key.
pub fn setResource(self: @This(), resource: Attribute) Allocator.Error!void {
    return self.vtable.listResources(self.ptr).set(self.getAllocator(), resource);
}

/// Removes the resource with the given key; does nothing if absent.
pub fn unsetResource(self: @This(), key: []const u8) void {
    self.vtable.listResources(self.ptr).unset(self.getAllocator(), key);
}

/// Returns the resource with the given key, or null if absent.
pub fn getResource(self: @This(), key: []const u8) ?*const Attribute {
    for (self.listResources()) |*attr| {
        if (std.mem.eql(u8, attr.key, key)) return attr;
    }
    return null;
}

/// Returns all registered resources.
pub fn listResources(self: @This()) []const Attribute {
    return self.vtable.listResources(self.ptr).inner.items;
}

test {
    _ = Default;
}
