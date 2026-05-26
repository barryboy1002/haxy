const std = @import("std");
const ui = @import("../ui.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const inp = xitui.input;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

pub const Users = @import("./Home/Users.zig");
pub const Repos = @import("./Home/Repos.zig");
pub const Header = @import("./Home/Header.zig");

header: Header,
users: Users,
repos: Repos,

const Self = @This();

pub fn init(
    comptime repo_opts: rp.RepoOpts(.xit),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(.xit, repo_opts),
) !Self {
    const DB = rp.Repo(.xit, repo_opts).DB;

    const history = try DB.ArrayList(.read_only).init(repo.core.db.rootCursor().readOnly());

    const moment_cursor = try history.getCursor(-1) orelse return error.NotFound;
    const moment = try DB.HashMap(.read_only).init(moment_cursor);

    const last_object_id_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, "haxy-last-object-id")) orelse return error.NotFound;
    var last_object_id: [hash.byteLen(repo_opts.hash)]u8 = undefined;
    _ = try last_object_id_cursor.readBytes(&last_object_id);

    const haxy_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, "haxy")) orelse return error.NotFound;
    const haxy = try DB.ArrayList(.read_only).init(haxy_cursor);

    const haxy_moments_cursor = try haxy.getCursor(-1) orelse return error.NotFound;
    const haxy_moments = try DB.HashMap(.read_only).init(haxy_moments_cursor);

    const haxy_moment_cursor = try haxy_moments.getCursor(hash.bytesToInt(repo_opts.hash, &last_object_id)) orelse return error.NotFound;
    const haxy_moment = try DB.HashMap(.read_only).init(haxy_moment_cursor);

    return .{
        .header = Header.init(),
        .users = try Users.init(repo_opts, arena, haxy_moment),
        .repos = try Repos.init(repo_opts, arena, haxy_moment),
    };
}

pub const View = struct {
    box: wgt.Box(ui.Widget),
    data: *const Self,

    const header_index: usize = 0;
    const stack_index: usize = 1;

    pub fn init(allocator: std.mem.Allocator, data: *const Self) !View {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
        errdefer box.deinit();

        {
            var header_view = try Header.View.init(allocator, &data.header);
            errdefer header_view.deinit();
            try box.children.put(allocator, header_view.getFocus().id, .{ .widget = .{ .home_header = header_view }, .rect = null, .min_size = null });
        }

        {
            var stack = wgt.Stack(ui.Widget).init(allocator);
            errdefer stack.deinit();

            {
                var users_view = try Users.View.init(allocator, &data.users);
                errdefer users_view.deinit();
                try stack.children.put(stack.allocator, users_view.getFocus().id, .{ .home_users = users_view });
            }

            {
                var repos_view = try Repos.View.init(allocator, &data.repos);
                errdefer repos_view.deinit();
                try stack.children.put(stack.allocator, repos_view.getFocus().id, .{ .home_repos = repos_view });
            }

            try box.children.put(allocator, stack.getFocus().id, .{ .widget = .{ .stack = stack }, .rect = null, .min_size = null });
        }

        var self = View{
            .box = box,
            .data = data,
        };
        self.getFocus().child_id = box.children.keys()[header_index];
        return self;
    }

    pub fn deinit(self: *View) void {
        self.box.deinit();
    }

    pub fn build(self: *View, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        const header = &self.box.children.values()[header_index].widget.home_header;
        const stack = &self.box.children.values()[stack_index].widget.stack;
        if (header.getSelectedIndex()) |index| {
            stack.getFocus().child_id = stack.children.keys()[index];
        }
        try self.box.build(constraint, root_focus);
    }

    pub fn input(self: *View, key: inp.Key, root_focus: *Focus) !void {
        if (self.getFocus().child_id) |child_id| {
            if (self.box.children.getIndex(child_id)) |current_index| {
                const child = &self.box.children.values()[current_index].widget;
                var index = current_index;

                // arrow up/down (and scroll wheel) move focus between the
                // header and the stack below it, matching radargit's GitUI.
                const Direction = enum { up, down, none };
                const direction: Direction = switch (key) {
                    .arrow_up => .up,
                    .arrow_down => .down,
                    .mouse => |mouse| if (mouse.action == .scroll)
                        (if (mouse.action.scroll == .up) .up else .down)
                    else
                        .none,
                    else => .none,
                };

                switch (direction) {
                    .up => {
                        switch (child.*) {
                            .home_header => {
                                try child.input(key, root_focus);
                            },
                            .stack => {
                                if (child.stack.getSelected()) |selected_widget| {
                                    const at_top = switch (selected_widget.*) {
                                        .home_users => |*v| v.getSelectedIndex() == 0,
                                        .home_repos => |*v| v.getSelectedIndex() == 0,
                                        else => false,
                                    };
                                    if (at_top) {
                                        index = header_index;
                                    } else {
                                        try child.input(key, root_focus);
                                    }
                                }
                            },
                            else => {},
                        }
                    },
                    .down => {
                        switch (child.*) {
                            .home_header => {
                                index = stack_index;
                            },
                            .stack => {
                                try child.input(key, root_focus);
                            },
                            else => {},
                        }
                    },
                    .none => {
                        try child.input(key, root_focus);
                    },
                }

                if (index != current_index) {
                    try root_focus.setFocus(self.box.children.keys()[index]);
                }
            }
        }
    }

    pub fn clearGrid(self: *View) void {
        self.box.clearGrid();
    }

    pub fn getGrid(self: View) ?Grid {
        return self.box.getGrid();
    }

    pub fn getFocus(self: *View) *Focus {
        return self.box.getFocus();
    }
};
