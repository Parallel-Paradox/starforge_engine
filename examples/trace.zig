const std = @import("std");
const starforge = @import("starforge");
const trace = starforge.trace;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var default = trace.Tracer.Default.init(allocator, init.io);
    defer default.deinit();
    const tracer = default.tracer();

    var terminal = trace.Subscriber.Terminal{ .level_mask = .all };
    try tracer.subscribe(terminal.subscriber());

    // A span from a previous attempt, linked by the retry below.
    const t = tracer.initTrace();
    var prev = t.initSpan(.{ .name = "http.request", .kind = .client });
    defer prev.deinit();
    prev.start();
    try prev.addAttrs(.{ .attempt = 1 });
    prev.emit();

    var root = t.initSpan(.{ .name = "db.transaction" });
    defer root.deinit();
    root.start();
    try root.addAttrs(.{ .isolation = "serializable" });

    var query = root.initSub(.{ .name = "db.query", .kind = .client });
    defer query.deinit();
    query.start();
    try query.addAttrs(.{ .sql = "SELECT * FROM users", .rows = 3 });

    var query_event = query.initEvent(.{ .name = "cache.miss", .level = .warn });
    defer query_event.deinit();
    query_event.emit();

    inline for (std.meta.tags(trace.Event.Level)) |level| {
        var event = query.initEvent(.{ .name = @tagName(level), .level = level });
        defer event.deinit();
        try event.addAttrs(.{ .level_value = @as(u64, @intFromEnum(level)) });
        event.emit();
    }

    try query.linkTo(prev.trace.id, prev.id, .{ .reason = "retry", .attempt = 1 });
    query.status = .ok;
    query.emit();

    root.status = .err;
    root.emit();
}
