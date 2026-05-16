const std = @import("std");

const bcrypt = std.crypto.pwhash.bcrypt;

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
