const std = @import("std");
const ui = @import("../ui.zig");
const inp = @import("./input.zig");
const xit = @import("xit");
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

// the logged-in user's page, or the login form when logged out
pub fn initView(allocator: std.mem.Allocator, session: *ui.Session) !ui.Widget {
    if (session.data.user_id != null) return .{ .user_logout = try View.init(allocator, session) };
    return .{ .user_login = try ui.UserLogin.View.init(allocator, session) };
}

// the user tab's label: the logged-in user's name, or "login"
pub fn tabLabel(session: *const ui.Session) []const u8 {
    if (session.data.user_id == null) return "login";
    return session.data.user_name orelse unreachable;
}

pub const View = struct {
    center: ui.widget.Center,
    session: *ui.Session,
    logout_id: usize,

    pub fn init(allocator: std.mem.Allocator, session: *ui.Session) !View {
        // the form box makes the web renderer post the button to /logout
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
        errdefer box.deinit(allocator);
        box.getFocus().kind = .{ .custom = "form:logout" };

        var button = try wgt.TextBox.init(allocator, "logout", .{ .border_style = .single, .round_corners = true, .wrap_kind = .none });
        errdefer button.deinit(allocator);
        button.getFocus().mode = .all;
        // the renderer distinguishes plain clickables from buttons that
        // should POST to a server route by this kind.
        button.getFocus().kind = .{ .custom = "submit" };
        const logout_id = button.getFocus().id;
        try box.children.put(allocator, logout_id, .{
            .widget = .{ .text_box = button },
            .rect = null,
            .min_size = null,
        });
        box.getFocus().child_id = logout_id;

        return .{
            .center = try ui.widget.Center.init(allocator, .{ .box = box }),
            .session = session,
            .logout_id = logout_id,
        };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.center.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        try self.center.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        _ = allocator;
        switch (key) {
            .enter => try self.logOut(),
            .mouse => |mouse| if (inp.leftClickOn(root_focus, self.logout_id, mouse)) try self.logOut(),
            else => {},
        }
    }

    fn logOut(self: *View) !void {
        self.session.logOut();
        // leave the user tab for the page it belongs to, where the web's
        // /logout redirect also lands
        try self.session.navigate(self.session.data.current_page.pageRoot());
    }

    pub fn clearGrid(self: *View) void {
        self.center.clearGrid();
    }

    pub fn getGrid(self: View) ?Grid {
        return self.center.getGrid();
    }

    pub fn getFocus(self: *View) *Focus {
        return self.center.getFocus();
    }

    pub fn atTop(self: View) bool {
        _ = self;
        return true;
    }
};
