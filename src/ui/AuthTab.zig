const std = @import("std");
const ui = @import("../ui.zig");
const xit = @import("xit");
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

const login_tab_label = "login";

pub const View = struct {
    text_box: wgt.TextBox,
    session: *ui.Session,

    pub fn init(allocator: std.mem.Allocator, session: *ui.Session) !View {
        var text_box = try wgt.TextBox.init(allocator, login_tab_label, .{ .border_style = .single, .round_corners = true, .wrap_kind = .none });
        errdefer text_box.deinit(allocator);
        text_box.getFocus().mode = .all;
        text_box.getFocus().kind = .{ .custom = "ai:/auth" };
        return .{
            .text_box = text_box,
            .session = session,
        };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.text_box.deinit(allocator);
    }

    // the logged-in user's name, or the login label
    fn text(self: *const View) []const u8 {
        if (self.session.data.user_id == null) return login_tab_label;
        return self.session.data.user_name orelse unreachable;
    }

    pub fn minWidth(self: *const View) usize {
        return self.text().len + 2;
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        try self.text_box.setContent(allocator, self.text());
        try self.text_box.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        try self.text_box.input(allocator, key, root_focus);
    }

    pub fn clearGrid(self: *View) void {
        self.text_box.clearGrid();
    }

    pub fn getGrid(self: View) ?Grid {
        return self.text_box.getGrid();
    }

    pub fn getFocus(self: *View) *Focus {
        return self.text_box.getFocus();
    }
};
