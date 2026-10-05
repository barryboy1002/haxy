const std = @import("std");
const evt = @import("../event.zig");
const xit = @import("xit");
const hash = xit.hash;

// what the grant gives access to, held in the same user repo
target_id: []const u8,
// who it gives access to
user_id: []const u8,
role: evt.Repo.Role,

// what the db stores: the event's data plus the commit-derived fields
pub const Record = struct {
    event: Self,
    removed: bool = false,
    created_order: u64 = 0,
    updated_order: u64 = 0,
};

const Self = @This();

// the moment keys `evt.merge` reads and writes for this kind
pub const merge_policy: evt.MergePolicy = .target_wins;
pub const record_map_key = "event-id->grant";
pub const all_id_set_key = "grant-id-set";
pub const target_to_grant_id_set_key = "target->grant-id-set";

// the id of the one grant a user can hold on a target
pub fn idOf(target_id: []const u8, user_id: []const u8) [evt.event_id_size]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(target_id);
    hasher.update(user_id);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return digest[0..evt.event_id_size].*;
}

// only what the event says about itself is checked. a grant naming a missing
// target or user is inert.
fn validate(event_id: *const [evt.event_id_size]u8, record: Record) !void {
    if (record.event.target_id.len != evt.event_id_size) return error.InvalidTargetId;
    if (record.event.user_id.len != evt.event_id_size) return error.InvalidUserId;
    if (!std.mem.eql(u8, event_id, &idOf(record.event.target_id, record.event.user_id))) return error.InvalidGrantId;
}

pub fn consume(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_write),
    event_id: *const [evt.event_id_size]u8,
    record_maybe: ?Record,
    arena: *std.heap.ArenaAllocator,
    _: ?[]const u8,
) !void {
    const grant_key = hash.hashInt(hash_kind, event_id);
    const records = try DB.HashMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, record_map_key)));
    const by_target = try DB.HashMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, target_to_grant_id_set_key)));

    var existing_maybe: ?Record = null;
    const existing_cursor_maybe = try records.getCursor(grant_key);
    if (existing_cursor_maybe) |cursor| {
        existing_maybe = try evt.read(Record, DB, hash_kind, arena, try DB.HashMap(.read_only).init(cursor));
    }

    var record = record_maybe orelse try evt.removedRecord(Record, DB, hash_kind, haxy_moment.readOnly(), existing_maybe);

    if (!record.removed) try validate(event_id, record);

    if (existing_maybe) |existing| {
        // updates preserve the original creation metadata
        record.created_order = existing.created_order;
    }

    const grant_cursor = try records.putCursor(grant_key);
    try evt.upsert(Record, DB, hash_kind, try DB.HashMap(.read_write).init(grant_cursor), record);
    try evt.indexEvent(DB, hash_kind, haxy_moment, event_id, .grant, existing_maybe, record);

    const order_key = evt.orderKeyDesc(record.created_order, event_id);

    // the id set retains removed records so merges can carry removals
    if (existing_cursor_maybe == null) {
        const ids = try DB.SortedSet(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, all_id_set_key)));
        try ids.put(&order_key);
    }

    // the id fixes the target, so a grant never moves between sets
    const target_grants = try DB.SortedSet(.read_write).init(try by_target.putCursor(hash.hashInt(hash_kind, record.event.target_id)));
    if (record.removed) {
        _ = try target_grants.remove(&order_key);
    } else {
        try target_grants.put(&order_key);
    }
}

// the role a user was granted on a target, or null without an active grant
pub fn readRole(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_only),
    arena: *std.heap.ArenaAllocator,
    target_id: []const u8,
    user_id: []const u8,
) !?evt.Repo.Role {
    const Granted = struct { event: struct { role: evt.Repo.Role }, removed: bool };
    const grant = (try evt.readRecordSubset(Self, Granted, DB, hash_kind, haxy_moment, arena, &idOf(target_id, user_id))) orelse return null;
    return if (grant.removed) null else grant.event.role;
}

// a target's active grants, newest first
pub fn readByTarget(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_only),
    arena: *std.heap.ArenaAllocator,
    target_id: []const u8,
) ![]const Self {
    var grants: std.ArrayList(Self) = .empty;
    const by_target_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, target_to_grant_id_set_key)) orelse return grants.items;
    const by_target = try DB.HashMap(.read_only).init(by_target_cursor);
    const target_grants_cursor = try by_target.getCursor(hash.hashInt(hash_kind, target_id)) orelse return grants.items;
    const target_grants = try DB.SortedSet(.read_only).init(target_grants_cursor);

    var iter = try target_grants.iteratorFromIndex(0);
    while (try iter.next()) |kv_cursor| {
        const grant_id = try evt.readOrderKeyId(DB, kv_cursor);
        const grant = (try evt.readRecordSubset(Self, struct { event: Self }, DB, hash_kind, haxy_moment, arena, &grant_id)) orelse continue;
        try grants.append(arena.allocator(), grant.event);
    }
    return grants.items;
}
