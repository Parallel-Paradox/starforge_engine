//! Metadata of the component types stored in an archetype.

const std = @import("std");

const engine = @import("engine");
const CompId = engine.ecs.component.Id;

const reflect = engine.reflect;
const TypeMeta = reflect.TypeMeta;

columns: std.ArrayList(Entry),

pub const Entry = struct {
    id: CompId,
    meta: TypeMeta,
};
