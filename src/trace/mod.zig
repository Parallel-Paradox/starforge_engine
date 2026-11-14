pub const Tracer = @import("Tracer/mod.zig");
pub const Subscriber = @import("Subscriber/mod.zig");
pub const Trace = @import("Trace.zig");
pub const Span = @import("Span.zig");
pub const Event = @import("Event.zig");
pub const Attribute = @import("Attribute.zig");

pub const Transparent = struct {
    trace_id: Trace.Id = .invalid,
    span_id: Span.Id = .invalid,
    flag: Trace.Flag = .{},
};

test {
    _ = Tracer;
    _ = Subscriber;
    _ = Attribute;
}
