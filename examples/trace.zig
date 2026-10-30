const std = @import("std");
const starforge = @import("starforge");
const trace = starforge.trace;
const Tracer = trace.Tracer.Global;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var default = trace.Tracer.Default.init(allocator, init.io);
    defer default.deinit();

    var terminal = trace.Subscriber.Terminal{ .level_mask = .all };
    try default.tracer().subscribe(terminal.subscriber());
    try Tracer.install(default.tracer());

    // Events outside a scope have no trace or span ID.
    Tracer.info("application.started").emit();

    var prev = Tracer.scope(.{ .name = "http.request", .kind = .client });
    try prev.span.addAttrs(.{ .attempt = 1 });
    const previous = Tracer.transparent.?;
    prev.end();

    var root = Tracer.scope(.{ .name = "db.transaction" });
    try root.span.addAttrs(.{ .isolation = "serializable" });

    var query = Tracer.scope(.{ .name = "db.query", .kind = .client });
    try query.span.addAttrs(.{ .sql = "SELECT * FROM users", .rows = 3 });

    Tracer.warn("cache.miss").emit();

    inline for (comptime std.meta.tags(trace.Event.Level)) |level| {
        const name = comptime @tagName(level);
        var event = @field(Tracer, name)(name);
        errdefer event.deinit();
        try event.addAttrs(.{ .level_value = @as(u64, @backingInt(level)) });
        event.emit();
    }

    try query.span.linkTo(previous.trace_id, previous.span_id, .{
        .reason = "retry",
        .attempt = 1,
    });
    query.span.status = .ok;
    query.end();

    // Ending the query restores the transaction's context.
    Tracer.info("db.query.completed").emit();

    root.span.status = .err;
    root.end();

    Tracer.info("application.finished").emit();
}
