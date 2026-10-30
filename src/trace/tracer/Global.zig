//! Global tracer with implicitly inherited span context.
//!
//! The backend is shared, but the current context belongs to each thread.
//! Cross-thread work must capture and attach its context explicitly.
//! Scopes and contexts must be unwound once, in reverse order on the same thread.
//! Thread-local context does not automatically follow interleaved async tasks.
//! Before a backend is installed, spans and events are allocation-free no-ops.

const std = @import("std");

const engine = @import("engine");
const Transparent = engine.trace.Transparent;
const Tracer = engine.trace.Tracer;
const Trace = engine.trace.Trace;
const Span = engine.trace.Span;
const Event = engine.trace.Event;

var impl: ?Tracer = null;

/// Copy to propagate context to another thread; use attach/scope to change it.
pub threadlocal var transparent: ?Transparent = null;

/// Owns a started span and its installed context.
pub const Scope = struct {
    span: Span,
    context: Context,

    /// Emits and releases the completed span, then restores the previous context.
    /// Must be called exactly once, normally with defer.
    pub fn end(self: *@This()) void {
        self.span.emit();
        self.context.detach();
    }
};

/// Restores borrowed context without owning or ending any span.
pub const Context = struct {
    previous: ?Transparent,

    pub fn detach(self: @This()) void {
        transparent = self.previous;
    }
};

pub const Error = error{AlreadyInstalled};

/// Borrows a backend for the remaining lifetime of Global usage. Install before
/// starting workers; installation must not race with other Global operations.
/// The allocator, Io and subscribers must support concurrent use. Configure the
/// backend before installation and do not mutate its configuration during use.
pub fn install(backend: Tracer) Error!void {
    if (impl != null) return error.AlreadyInstalled;
    impl = backend;
}

/// Returns the installed backend, or null when tracing is disabled.
pub fn tracer() ?Tracer {
    return impl;
}

/// Installs borrowed context, saving the previous value for detach.
/// Passing null isolates subsequent work; a new trace is created lazily by scope.
pub fn attach(value: ?Transparent) Context {
    const context: Context = .{ .previous = transparent };
    transparent = value;
    return context;
}

/// Starts a child span, or a new trace's root span when no context is installed.
/// The name is borrowed until the scope ends. Do not copy an active scope or
/// call its span's lifecycle methods directly.
pub fn scope(options: Span.Options) Scope {
    const backend = tracer() orelse return .{
        .span = (Trace{}).initSpan(options),
        .context = .{ .previous = transparent },
    };
    const parent = transparent;
    const current_trace: Trace = if (parent) |value| .{
        .tracer = backend,
        .id = value.trace_id,
        .flag = value.flag,
    } else backend.initTrace();

    var span = backend.initSpan(current_trace, options);
    if (parent) |value| {
        span.parent_id = if (value.span_id == .invalid) null else value.span_id;
    }

    const context = attach(.{
        .trace_id = span.trace.id,
        .span_id = span.id,
        .flag = span.trace.flag,
    });
    span.start();
    return .{ .span = span, .context = context };
}

/// Level-specific event constructors. Capture context now, without emitting or
/// changing it. Without context, both IDs are invalid. Calling emit consumes and
/// releases the event; use deinit only to discard it without emitting. Its name
/// remains borrowed until consumption.
pub fn trace(name: []const u8) Event {
    return initEvent(name, .trace);
}

pub fn debug(name: []const u8) Event {
    return initEvent(name, .debug);
}

pub fn info(name: []const u8) Event {
    return initEvent(name, .info);
}

pub fn warn(name: []const u8) Event {
    return initEvent(name, .warn);
}

pub fn err(name: []const u8) Event {
    return initEvent(name, .err);
}

pub fn fatal(name: []const u8) Event {
    return initEvent(name, .fatal);
}

fn initEvent(name: []const u8, level: Event.Level) Event {
    const backend = tracer();
    const current = transparent orelse Transparent{};
    // Ambient context retains identity only, not a span for Tracer.initEvent.
    return .{
        .trace = .{
            .tracer = backend,
            .id = current.trace_id,
            .flag = current.flag,
        },
        .span_id = current.span_id,
        .level = level,
        .name = name,
        .real_ts = if (backend) |value| std.Io.Clock.real.now(value.getIo()) else .zero,
    };
}
