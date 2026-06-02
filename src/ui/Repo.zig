const std = @import("std");
const evt = @import("../event.zig");
const ui = @import("../ui.zig");
const xit = @import("xit");
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const inp = xitui.input;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

pub const Header = @import("./Repo/Header.zig");
pub const Settings = @import("./Settings.zig");
pub const Auth = @import("./Auth.zig");
pub const Quit = @import("./Quit.zig");

header: Header,
repo: evt.Repo,
settings: Settings,
auth: Auth,
quit: Quit,
route_name: ui.RoutablePage.Array(ui.RoutablePage.repo_name_max_len),

const Self = @This();

pub fn init(
    arena: *std.heap.ArenaAllocator,
    haxy_moment: evt.AdminDB.HashMap(.read_only),
    name: ui.RoutablePage.Array(ui.RoutablePage.repo_name_max_len),
) !Self {
    const DB = evt.AdminDB;
    const hash_kind = evt.admin_repo_opts.hash;

    // the route name is "username/reponame"; split it to look the repo up by
    // its owner and name.
    const path = name.slice();
    const slash = std.mem.indexOfScalar(u8, path, '/') orelse return error.NotFound;
    const owner_name = path[0..slash];
    const repo_name = path[slash + 1 ..];

    const repo = (try evt.Repo.readByOwnerAndName(DB, hash_kind, haxy_moment, arena, owner_name, repo_name)) orelse return error.NotFound;

    // resolve the creating user so the header can show their name to the left
    // of the repo title.
    const owner = (try evt.User.readById(DB, hash_kind, haxy_moment, arena, repo.user_id)) orelse return error.NotFound;

    return .{
        .header = try Header.init(arena, repo.name, owner.name),
        .repo = repo,
        .settings = Settings.init(),
        .auth = Auth.init(),
        .quit = Quit.init(),
        .route_name = name,
    };
}

pub const View = struct {
    box: wgt.Box(ui.Widget),
    data: *const Self,
    session: *ui.Session,

    const header_index: usize = 0;
    const stack_index: usize = 1;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var box = wgt.Box(ui.Widget).init(.{ .border_style = null, .rounded_corners = true, .direction = .vert });
        errdefer box.deinit(allocator);

        // build the header first so we can grab the files-tab id for the auth
        // view (it focuses there after login).
        var files_tab_id: usize = undefined;
        {
            var header_view = try Header.View.init(allocator, &data.header, session);
            errdefer header_view.deinit(allocator);
            files_tab_id = header_view.tab_ids.keys()[0];
            try box.children.put(allocator, header_view.getFocus().id, .{ .widget = .{ .repo_header = header_view }, .rect = null, .min_size = null });
        }

        {
            var stack = wgt.Stack(ui.Widget).init();
            errdefer stack.deinit(allocator);

            // files — the default tab. blank for now: an empty list renders
            // nothing below the header.
            {
                var list = try ui.FlowBox.Scroll.init(allocator, .{});
                errdefer list.deinit(allocator);
                try stack.children.put(allocator, list.getFocus().id, .{ .flow_box_scroll = list });
            }

            {
                var settings_view = try Settings.View.init(allocator, &data.settings, session);
                errdefer settings_view.deinit(allocator);
                try stack.children.put(allocator, settings_view.getFocus().id, .{ .home_settings = settings_view });
            }

            {
                var auth_view = try Auth.View.init(allocator, &data.auth, session, files_tab_id);
                errdefer auth_view.deinit(allocator);
                try stack.children.put(allocator, auth_view.getFocus().id, .{ .home_auth = auth_view });
            }

            if (session.is_terminal) {
                var quit_view = try Quit.View.init(allocator, &data.quit, session);
                errdefer quit_view.deinit(allocator);
                try stack.children.put(allocator, quit_view.getFocus().id, .{ .quit = quit_view });
            }

            try box.children.put(allocator, stack.getFocus().id, .{ .widget = .{ .stack = stack }, .rect = null, .min_size = null });
        }

        var self = View{ .box = box, .data = data, .session = session };
        self.getFocus().child_id = box.children.keys()[header_index];
        return self;
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        const header = &self.box.children.values()[header_index].widget.repo_header;
        const stack = &self.box.children.values()[stack_index].widget.stack;

        // each header tab maps 1:1 to a stack child by position. mirror the
        // selection into current_page so the host can push the matching url;
        // all repo tabs share the .repo parent, so this stays on the page
        // rather than navigating.
        if (header.getSelectedIndex()) |index| {
            stack.getFocus().child_id = stack.children.keys()[index];
            const name = self.data.route_name;
            switch (index) {
                1 => self.session.data.current_page = .{ .repo_settings = name },
                2 => self.session.data.current_page = .{ .repo_auth = name },
                // the quit tab is tty-only and not a route, so leave current_page
                // alone (nothing to mirror into the url).
                3 => {},
                else => self.session.data.current_page = .{ .repo = name },
            }
        }
        try self.box.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
        if (self.getFocus().child_id) |child_id| {
            if (self.box.children.getIndex(child_id)) |current_index| {
                const child = &self.box.children.values()[current_index].widget;
                var index = current_index;

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
                            .repo_header => {
                                try child.input(allocator, key, root_focus);
                            },
                            .stack => {
                                if (child.stack.getSelected()) |selected_widget| {
                                    const at_top = switch (selected_widget.*) {
                                        .flow_box_scroll => |*v| v.getSelectedIndex() == 0,
                                        .home_settings => |*v| v.getSelectedIndex() == 0,
                                        .home_auth => |*v| v.getSelectedIndex() == 0,
                                        .quit => |*v| v.getSelectedIndex() == 0,
                                        else => false,
                                    };
                                    if (at_top) {
                                        index = header_index;
                                    } else {
                                        try child.input(allocator, key, root_focus);
                                    }
                                }
                            },
                            else => {},
                        }
                    },
                    .down => {
                        switch (child.*) {
                            .repo_header => {
                                index = stack_index;
                            },
                            .stack => {
                                try child.input(allocator, key, root_focus);
                            },
                            else => {},
                        }
                    },
                    .none => {
                        try child.input(allocator, key, root_focus);
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
