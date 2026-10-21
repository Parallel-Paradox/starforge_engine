pub const base = @import("base");

pub const Parcel = @import("Parcel.zig");
pub const TypeId = @import("TypeId.zig");
pub const TypeMeta = @import("TypeMeta.zig");

test {
    _ = Parcel;
    _ = TypeId;
    _ = TypeMeta;
}
