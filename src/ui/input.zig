const xit = @import("xit");
const xitui = xit.xitui;
const Key = xitui.input.Key;

/// the vertical direction of a navigation key press, including mouse scroll
pub const Direction = enum { up, down, none };

pub fn vertDirection(key: Key) Direction {
    return switch (key) {
        .arrow_up => .up,
        .arrow_down => .down,
        .mouse => |mouse| if (mouse.action == .scroll)
            (if (mouse.action.scroll == .up) .up else .down)
        else
            .none,
        else => .none,
    };
}

/// how many rows a navigation key press moves the selection (negative is up),
/// or null if the key doesn't move the selection. `count` is the row count,
/// so home/end jump past either end and get clamped by the caller.
pub fn rowDelta(key: Key, count: isize) ?isize {
    switch (key) {
        .arrow_up => return -1,
        .arrow_down => return 1,
        .page_up => return -10,
        .page_down => return 10,
        .home => return -count,
        .end => return count,
        .mouse => |mouse| switch (mouse.action) {
            .scroll => |dir| return if (dir == .up) -1 else 1,
            else => {},
        },
        else => {},
    }
    return null;
}
