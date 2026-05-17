const std = @import("std");
const evt = @import("../event.zig");
const xit = @import("xit");
const hash = xit.hash;

user_id: []const u8,
name: []const u8,
enable_issue: bool,

pub fn read(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    arena: *std.heap.ArenaAllocator,
    map: DB.HashMap(.read_only),
) !@This() {
    return .{
        .user_id = try evt.readBytes(DB, hash_kind, arena.allocator(), map, "user_id"),
        .name = try evt.readBytes(DB, hash_kind, arena.allocator(), map, "name"),
        .enable_issue = try evt.readBool(DB, hash_kind, map, "enable_issue"),
    };
}
