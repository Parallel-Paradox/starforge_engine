const engine = @import("engine");

pub const Id = engine.ecs.Id;

pub const Meta = @import("Meta.zig");
pub const ChunkLayout = @import("ChunkLayout.zig");
pub const Chunk = @import("Chunk.zig");
pub const Archetype = @import("Archetype.zig");
pub const Iter = @import("Iter.zig");
pub const Registry = @import("Registry.zig");

test {
    _ = Meta;
    _ = ChunkLayout;
    _ = Chunk;
    _ = Archetype;
    _ = Iter;
    _ = Registry;
}
