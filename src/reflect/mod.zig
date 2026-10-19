pub const base = @import("base");
pub const trace = @import("trace");

pub const TypeId = @import("type_id.zig");
pub const TypeMeta = @import("type_meta.zig");

test {
    _ = TypeId;
    _ = TypeMeta;
}
