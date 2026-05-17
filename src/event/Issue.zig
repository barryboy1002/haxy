const std = @import("std");
const evt = @import("../event.zig");
const xit = @import("xit");
const hash = xit.hash;

title: []const u8,
description: []const u8,
tags: []const u8,

pub fn read(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    arena: *std.heap.ArenaAllocator,
    map: DB.HashMap(.read_only),
) !@This() {
    return .{
        .title = try evt.readBytes(DB, hash_kind, arena.allocator(), map, "title"),
        .description = try evt.readBytes(DB, hash_kind, arena.allocator(), map, "description"),
        .tags = try evt.readBytes(DB, hash_kind, arena.allocator(), map, "tags"),
    };
}
