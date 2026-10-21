//! Storage layout information for a component.

const root = @import("root.zig");
const Storage = root.Storage;

const se = root.super.super;
const reflect = se.reflect;
const TypeMeta = reflect.TypeMeta;

type_meta: TypeMeta,
storage: Storage,
