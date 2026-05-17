const std = @import("std");
const evt = @import("../event.zig");
const xit = @import("xit");
const hash = xit.hash;
const bcrypt = std.crypto.pwhash.bcrypt;

name: []const u8,
email: []const u8,
password_hash: []const u8,

pub fn read(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    arena: *std.heap.ArenaAllocator,
    map: DB.HashMap(.read_only),
) !@This() {
    return .{
        .name = try evt.readBytes(DB, hash_kind, arena.allocator(), map, "name"),
        .email = try evt.readBytes(DB, hash_kind, arena.allocator(), map, "email"),
        .password_hash = try evt.readBytes(DB, hash_kind, arena.allocator(), map, "password_hash"),
    };
}

pub const password_hash_max_len = bcrypt.hash_length * 2;

pub fn hashPassword(
    password: []const u8,
    out: []u8,
    io: std.Io,
) ![]const u8 {
    return bcrypt.strHash(password, .{
        .params = bcrypt.Params.owasp,
        .encoding = .phc,
    }, out, io);
}
