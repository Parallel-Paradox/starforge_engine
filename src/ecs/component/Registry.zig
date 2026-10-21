//! Map `TypeId` to `ComponentId` and `ComponentMeta`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const root = @import("root.zig");
const CompId = root.Id;
const CompMeta = root.Meta;

const se = root.super.super;
const reflect = se.reflect;
const TypeId = reflect.TypeId;

type_to_comp: std.AutoHashMapUnmanaged(TypeId, CompId),
meta_entries: std.ArrayList(struct { id: CompId, meta: CompMeta }),
retired_ids: std.ArrayList(CompId),
allocator: Allocator,
